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
$delaysInput = ($data.d1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

if ($vmNames.Count -eq 0) {
    throw "No VM names provided."
}

# ---------- Enhanced delay processing ----------
if ($delaysInput.Count -eq 0) {
    $delaysInput = @('0')
}

if ($delaysInput.Count -eq 1) {
    # Single delay -> apply to all VMs
    $delays = @($delaysInput[0]) * $vmNames.Count
} elseif ($delaysInput.Count -eq $vmNames.Count) {
    $delays = $delaysInput
} elseif ($delaysInput.Count -gt $vmNames.Count) {
    $delays = $delaysInput[0..($vmNames.Count-1)]
} else {
    # Fewer delays than VMs -> pad with the last delay value
    $lastDelay = $delaysInput[-1]
    $delays = $delaysInput + (@($lastDelay) * ($vmNames.Count - $delaysInput.Count))
}

$delays = $delays | ForEach-Object { [int]$_ }

# Build schedule
$startTime = Get-Date
$schedule = @()
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $delayMin = $delays[$i]
    $dueTime = $startTime.AddMinutes($delayMin)
    $schedule += [PSCustomObject]@{
        VMName    = $vmNames[$i]
        Delay     = $delayMin
        DueTime   = $dueTime
        Processed = $false
    }
}

# ---------- Print schedule ----------
Write-Host "`n===== Schedule ====="
$schedule | ForEach-Object {
    Write-Host "$($_.VMName) : delay $($_.Delay) min, due at $($_.DueTime.ToString('HH:mm:ss'))"
}
Write-Host "Start time: $($startTime.ToString('HH:mm:ss'))`n"

# ---------- Load Nutanix snapin and connect ----------
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

# ---------- Function to resize a single VM with timeout ----------
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

    # ---------- Shutdown with force fallback ----------
    Write-Host "[$VMName] Attempt 1: ACPI shutdown..."
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 40

    $CheckVM = Get-NTNXVM -Vmid $VM.uuid
    if ($CheckVM.powerState -eq "ON") {
        Write-Host "[$VMName] VM still ON. Attempt 2: ACPI shutdown again..."
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 20
    }

    # Check again; if still ON, force power off
    $CheckVM = Get-NTNXVM -Vmid $VM.uuid
    if ($CheckVM.powerState -eq "ON") {
        Write-Host "[$VMName] VM still ON after two ACPI attempts. Forcing power OFF..."
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition OFF -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 10
    }

    # ---------- Resize with timeout (max 2 minutes) ----------
    Write-Host "[$VMName] Applying: $FinalCPU CPU, $FinalMemGB GB RAM."
    $resizeJob = Start-Job -ScriptBlock {
        param($uuid, $cpu, $mem)
        Set-NTNXVirtualMachine -Vmid $uuid -NumVcpus $cpu -MemoryMb $mem -ErrorAction Stop | Out-Null
    } -ArgumentList $VM.uuid, $FinalCPU, ($FinalMemGB * 1024)

    $jobCompleted = $resizeJob | Wait-Job -Timeout 120
    if ($jobCompleted) {
        Receive-Job -Job $resizeJob
    } else {
        Write-Host "[$VMName] ERROR: Resize operation timed out after 2 minutes. Stopping job."
        Stop-Job -Job $resizeJob
        Remove-Job -Job $resizeJob
        return
    }
    Remove-Job -Job $resizeJob

    # ---------- Power ON ----------
    Write-Host "[$VMName] Powering ON..."
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

    Write-Host "[$VMName] SUCCESS: Resize completed."
}

# ---------- Process immediate VMs (delay 0) ----------
$immediate = $schedule | Where-Object { $_.Delay -eq 0 -and -not $_.Processed }
foreach ($item in $immediate) {
    Write-Host "`n----- Processing VM: $($item.VMName) (delay 0) -----"
    Resize-VM -VMName $item.VMName
    $item.Processed = $true
}

# ---------- Process delayed VMs in order ----------
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
