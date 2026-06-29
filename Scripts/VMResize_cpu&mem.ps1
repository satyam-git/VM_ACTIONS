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

# Load Nutanix module once
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

# Connect to cluster once (assuming all VMs are on the same cluster)
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

# Function to resize a single VM
function Resize-VM {
    param(
        [string]$VMName,
        [int]$Delay
    )

    Write-Host "`n===== Processing VM: $VMName ====="

    # Find VM
    $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
    if (-not $VM) {
        Write-Host "ERROR: VM '$VMName' not found. Skipping."
        return
    }

    $CurrentCPU = [int]$VM.numVcpus
    $CurrentMemGB = [int]($VM.memoryMb / 1024)

    # Determine final values (if requested <=0, keep current)
    $FinalCPU = if ($RequestedCPU -gt 0) { $RequestedCPU } else { $CurrentCPU }
    $TempMem = if ($RequestedMemGB -gt 0) { $RequestedMemGB } else { $CurrentMemGB }
    $FinalMemGB = if ($TempMem -lt 1) { 1 } else { $TempMem }

    # Skip if no change
    if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
        Write-Host "No change needed for '$VMName'. Skipping."
        return
    }

    # Delay (only if change is needed)
    if ($Delay -gt 0) {
        Write-Host "Waiting $Delay minutes before resizing '$VMName'..."
        Start-Sleep -Seconds ($Delay * 60)
    }

    # Two‑strike shutdown
    Write-Host "Attempt 1: ACPI shutdown..."
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 40
    $CheckVM = Get-NTNXVM -Vmid $VM.uuid
    if ($CheckVM.powerState -eq "ON") {
        Write-Host "Attempt 2: ACPI shutdown again..."
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 20
    }

    # Resize and power on
    Write-Host "Applying: $FinalCPU CPU, $FinalMemGB GB RAM."
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $FinalCPU -MemoryMb ($FinalMemGB * 1024) -ErrorAction Stop | Out-Null
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

    Write-Host "SUCCESS: '$VMName' resized."
}

# Process all VMs
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $vmName = $vmNames[$i]
    $delay = [int]$delays[$i]
    Resize-VM -VMName $vmName -Delay $delay
}

Disconnect-NTNXCluster -Servers $ClusterIP
Write-Host "`n===== All VMs processed successfully ====="
