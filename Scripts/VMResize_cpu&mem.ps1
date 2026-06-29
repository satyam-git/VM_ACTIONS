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

# Common CPU & memory
$RequestedCPU = [int]$data.c1
$RequestedMemGB = [int]$data.m1

# Parse VM list and delay list
$vmNames = ($data.v1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
$delays = ($data.d1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

if ($vmNames.Count -eq 0) {
    throw "No VM names provided."
}
# Pad delays with '0' if needed
while ($delays.Count -lt $vmNames.Count) {
    $delays += '0'
}

# ---------- Load Nutanix snapin once ----------
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

# Connect to cluster once (all VMs on same site)
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

# ---------- Build a schedule for each VM ----------
$schedule = @()
$startTime = Get-Date
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $delayMin = [int]$delays[$i]
    $dueTime = $startTime.AddMinutes($delayMin)
    $schedule += [PSCustomObject]@{
        VMName    = $vmNames[$i]
        Delay     = $delayMin
        DueTime   = $dueTime
        Processed = $false
    }
}

# ---------- Function to resize a single VM ----------
function Resize-VM {
    param($VMName)

    Write-Host "[$VMName] Starting resize..."

    $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
    if (-not $VM) {
        Write-Host "[$VMName] ERROR: VM not found. Skipping."
        return
    }

    $CurrentCPU = [int]$VM.numVcpus
    $CurrentMemGB = [int]($VM.memoryMb / 1024)

    $FinalCPU = if ($RequestedCPU -gt 0) { $RequestedCPU } else { $CurrentCPU }
    $TempMem = if ($RequestedMemGB -gt 0) { $RequestedMemGB } else { $CurrentMemGB }
    $FinalMemGB = if ($TempMem -lt 1) { 1 } else { $TempMem }

    if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
        Write-Host "[$VMName] No change needed. Skipping."
        return
    }

    # Two‑strike shutdown
    Write-Host "[$VMName] Attempt 1: ACPI shutdown..."
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 40
    $CheckVM = Get-NTNXVM -Vmid $VM.uuid
    if ($CheckVM.powerState -eq "ON") {
        Write-Host "[$VMName] Attempt 2: ACPI shutdown again..."
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 20
    }

    # Resize and power on
    Write-Host "[$VMName] Applying: $FinalCPU CPU, $FinalMemGB GB RAM."
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $FinalCPU -MemoryMb ($FinalMemGB * 1024) -ErrorAction Stop | Out-Null
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

    Write-Host "[$VMName] SUCCESS: Resize completed."
}

# ---------- Main scheduling loop ----------
Write-Host "`nDelays started at: $($startTime.ToString('HH:mm:ss'))"
$remaining = $schedule | Where-Object { -not $_.Processed }
while ($remaining.Count -gt 0) {
    # Find the earliest due time among remaining VMs
    $next = $remaining | Sort-Object DueTime | Select-Object -First 1
    $now = Get-Date
    if ($next.DueTime -gt $now) {
        $waitSeconds = ($next.DueTime - $now).TotalSeconds
        if ($waitSeconds -gt 0) {
            Write-Host "Waiting $([math]::Round($waitSeconds, 1)) seconds until next VM is due..."
            Start-Sleep -Seconds $waitSeconds
        }
    }
    # Now process all VMs whose DueTime <= current time (including the one we just waited for)
    $dueNow = $remaining | Where-Object { $_.DueTime -le (Get-Date) }
    foreach ($item in $dueNow) {
        Write-Host "`n----- Processing VM: $($item.VMName) (delay was $($item.Delay) min) -----"
        Resize-VM -VMName $item.VMName
        $item.Processed = $true
    }
    # Refresh remaining list
    $remaining = $schedule | Where-Object { -not $_.Processed }
}

Disconnect-NTNXCluster -Servers $ClusterIP
Write-Host "`n===== All VMs processed successfully ====="
