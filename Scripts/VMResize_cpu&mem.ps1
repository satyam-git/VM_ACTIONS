param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# ---------- Site to Cluster IP mapping ----------
$siteMap = @{
    "Bangalore" = "192.168.136.50"
    "Chennai"   = "10.0.0.10"
    "Pune"      = "10.0.0.20"   # Update with your actual IP
}

$siteName = $data.s1
if (-not $siteMap.ContainsKey($siteName)) {
    throw "Site '$siteName' not found in mapping. Available: $($siteMap.Keys -join ', ')"
}
$ClusterIP = $siteMap[$siteName]

# Common CPU & memory (apply to all VMs)
$RequestedCPU = [int]$data.c1
$RequestedMemGB = [int]$data.m1

# Parse VM list and delay list
$vmNames = ($data.v1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
$delays = ($data.d1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

if ($vmNames.Count -eq 0) {
    throw "No VM names provided."
}

# If delays list is shorter, pad with '0'
while ($delays.Count -lt $vmNames.Count) {
    $delays += '0'
}

# Function that resizes a single VM – this will run inside a background job
function Resize-VM {
    param(
        [string]$VMName,
        [int]$Delay,
        [string]$ClusterIP,
        [string]$PE_User,
        [string]$PE_Pass,
        [int]$RequestedCPU,
        [int]$RequestedMemGB
    )

    # Load Nutanix module inside the job (each job needs its own)
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
    }

    # Connect to cluster
    $Pass = $PE_Pass | ConvertTo-SecureString -AsPlainText -Force
    Connect-NTNXCluster -Server $ClusterIP -UserName $PE_User -Password $Pass -AcceptInvalidSSLCerts | Out-Null

    Write-Host "[$VMName] Starting resize process..."

    # Find VM
    $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
    if (-not $VM) {
        Write-Host "[$VMName] ERROR: VM not found. Skipping."
        Disconnect-NTNXCluster -Servers $ClusterIP
        return
    }

    $CurrentCPU = [int]$VM.numVcpus
    $CurrentMemGB = [int]($VM.memoryMb / 1024)

    # Determine final values
    $FinalCPU = if ($RequestedCPU -gt 0) { $RequestedCPU } else { $CurrentCPU }
    $TempMem = if ($RequestedMemGB -gt 0) { $RequestedMemGB } else { $CurrentMemGB }
    $FinalMemGB = if ($TempMem -lt 1) { 1 } else { $TempMem }

    # Skip if no change
    if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
        Write-Host "[$VMName] No change needed. Skipping."
        Disconnect-NTNXCluster -Servers $ClusterIP
        return
    }

    # Apply the delay (runs concurrently because each job has its own timeline)
    if ($Delay -gt 0) {
        Write-Host "[$VMName] Waiting $Delay minutes..."
        Start-Sleep -Seconds ($Delay * 60)
    }

    # Two‑strike shutdown
    Write-Host "[$VMName] Attempt 1: ACPI shutdown..."
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 40
    $CheckVM = Get-NTNXVM -Vmid $VM.uuid
    if ($CheckVM.powerState -eq "ON") {
        Write-Host "[$VMName] VM still ON. Attempt 2: ACPI shutdown again..."
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 20
    }

    # Resize and power on
    Write-Host "[$VMName] Applying: $FinalCPU CPU, $FinalMemGB GB RAM."
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $FinalCPU -MemoryMb ($FinalMemGB * 1024) -ErrorAction Stop | Out-Null
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

    Disconnect-NTNXCluster -Servers $ClusterIP
    Write-Host "[$VMName] SUCCESS: Resize completed."
}

# ---- Main: Start each VM resize as a background job ----
$jobs = @()
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $vmName = $vmNames[$i]
    $delay = [int]$delays[$i]

    # Pass all required parameters to the job
    $jobParams = @{
        VMName = $vmName
        Delay = $delay
        ClusterIP = $ClusterIP
        PE_User = $env:PE_USER
        PE_Pass = $env:PE_PASS
        RequestedCPU = $RequestedCPU
        RequestedMemGB = $RequestedMemGB
    }

    Write-Host "Starting background job for VM: $vmName"
    $job = Start-Job -ScriptBlock ${function:Resize-VM} -ArgumentList @(
        $jobParams.VMName,
        $jobParams.Delay,
        $jobParams.ClusterIP,
        $jobParams.PE_User,
        $jobParams.PE_Pass,
        $jobParams.RequestedCPU,
        $jobParams.RequestedMemGB
    )
    $jobs += $job
}

# Wait for all jobs to complete and collect output
Write-Host "`nWaiting for all VMs to finish processing (delays run concurrently)..."
$results = $jobs | ForEach-Object {
    $job = $_
    $output = Receive-Job -Job $job -Wait -AutoRemoveJob
    $output
}

# Display all output from all jobs
$results | ForEach-Object { Write-Host $_ }

Write-Host "`n===== All VM resize jobs completed ====="
