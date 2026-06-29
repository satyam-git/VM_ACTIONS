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

# Parse VM list
$vmNames = ($data.v1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($vmNames.Count -eq 0) {
    throw "No VM names provided."
}

# ---------- ENHANCED DELAY HANDLING (single delay replication) ----------
$delaysInput = ($data.d1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

# If no delays given, default to '0'
if ($delaysInput.Count -eq 0) {
    $delaysInput = @('0')
}

# If only one delay value, replicate it to ALL VMs
if ($delaysInput.Count -eq 1 -and $vmNames.Count -gt 1) {
    $delaysInput = @($delaysInput[0]) * $vmNames.Count
}
else {
    # If fewer delays than VMs (but more than 1), pad with zeros
    while ($delaysInput.Count -lt $vmNames.Count) {
        $delaysInput += '0'
    }
}

# If more delays than VMs, truncate
if ($delaysInput.Count -gt $vmNames.Count) {
    $delaysInput = $delaysInput[0..($vmNames.Count-1)]
}

# ---------- SAFETY: cap delays at 60 minutes (optional) ----------
$MAX_DELAY_MINUTES = 60
for ($i = 0; $i -lt $delaysInput.Count; $i++) {
    $val = [int]$delaysInput[$i]
    if ($val -gt $MAX_DELAY_MINUTES) {
        Write-Warning "Delay of $val minutes exceeds cap of $MAX_DELAY_MINUTES. Capping to $MAX_DELAY_MINUTES."
        $delaysInput[$i] = $MAX_DELAY_MINUTES.ToString()
    }
}

# Build schedule (due time = now + delay in minutes)
$startTime = Get-Date
$schedule = @()
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $delayMin = [int]$delaysInput[$i]
    $dueTime = $startTime.AddMinutes($delayMin)
    $schedule += [PSCustomObject]@{
        VMName    = $vmNames[$i]
        Delay     = $delayMin
        DueTime   = $dueTime
        Processed = $false
    }
}

# ---------- Print schedule for debugging ----------
Write-Host "`n===== Schedule ====="
$schedule | ForEach-Object {
    Write-Host "$($_.VMName) : delay $($_.Delay) min, due at $($_.DueTime.ToString('HH:mm:ss'))"
}
Write-Host "Start time: $($startTime.ToString('HH:mm:ss'))`n"

# ---------- Load Nutanix snapin and connect once ----------
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

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

# ---------- Process all VMs with delay 0 immediately ----------
$immediate = $schedule | Where-Object { $_.Delay -eq 0 -and -not $_.Processed }
foreach ($item in $immediate) {
    Write-Host "`n----- Processing VM: $($item.VMName) (delay 0) -----"
    Resize-VM -VMName $item.VMName
    $item.Processed = $true
}

# ---------- Process delayed VMs in order of their due time ----------
$delayed = $schedule | Where-Object { $_.Delay -gt 0 -and -not $_.Processed } | Sort-Object DueTime
foreach ($item in $delayed) {
    $now = Get-Date
    if ($item.DueTime -gt $now) {
        $waitSeconds = ($item.DueTime - $now).TotalSeconds
        if ($waitSeconds -gt 0) {
            Write-Host "Waiting $([math]::Round($waitSeconds, 1)) seconds for $($item.VMName) (delay $($item.Delay) min)..."
            Start-Sleep -Seconds $waitSeconds
        }
    }
    Write-Host "`n----- Processing VM: $($item.VMName) (delay $($item.Delay) min) -----"
    Resize-VM -VMName $item.VMName
    $item.Processed = $true
}

Disconnect-NTNXCluster -Servers $ClusterIP
Write-Host "`n===== All VMs processed successfully ====="
