param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# ---------- Configuration ----------
$MAX_RUNTIME_MINUTES = 15          # Global timeout: if script runs longer, force exit
$VM_TIMEOUT_SECONDS = 300          # Max time per VM (including shutdown + resize)

# Site mapping
$siteMap = @{
    "Bangalore" = "192.168.136.50"
    "Chennai"   = "10.0.0.10"
    "Pune"      = "10.0.0.20"
}

$siteName = $data.s1
if (-not $siteMap.ContainsKey($siteName)) {
    throw "Site '$siteName' not found."
}
$ClusterIP = $siteMap[$siteName]
$RequestedCPU = [int]$data.c1
$RequestedMemGB = [int]$data.m1

# Parse VM list and delays
$vmNames = ($data.v1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
$delaysInput = ($data.d1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

if ($vmNames.Count -eq 0) { throw "No VM names." }

# Normalise delays
if ($delaysInput.Count -eq 0) { $delaysInput = @('0') }
if ($delaysInput.Count -eq 1) {
    $delays = @($delaysInput[0]) * $vmNames.Count
} elseif ($delaysInput.Count -eq $vmNames.Count) {
    $delays = $delaysInput
} elseif ($delaysInput.Count -gt $vmNames.Count) {
    $delays = $delaysInput[0..($vmNames.Count-1)]
} else {
    $lastDelay = $delaysInput[-1]
    $delays = $delaysInput + (@($lastDelay) * ($vmNames.Count - $delaysInput.Count))
}
$delays = $delays | ForEach-Object { [int]$_ }

# Build schedule
$startTime = Get-Date
$schedule = @()
for ($i=0; $i -lt $vmNames.Count; $i++) {
    $dueTime = $startTime.AddMinutes($delays[$i])
    $schedule += [PSCustomObject]@{
        VMName = $vmNames[$i]
        Delay  = $delays[$i]
        DueTime = $dueTime
        Processed = $false
    }
}

Write-Host "`n===== Schedule ====="
$schedule | ForEach-Object { Write-Host "$($_.VMName) : delay $($_.Delay) min, due at $($_.DueTime.ToString('HH:mm:ss'))" }
Write-Host "Start time: $($startTime.ToString('HH:mm:ss'))`n"

# ---------- Global watchdog (forcibly exit after MAX_RUNTIME_MINUTES) ----------
$watchdogJob = Start-Job -ScriptBlock {
    param($maxMin)
    Start-Sleep -Seconds ($maxMin * 60)
    Write-Host "WATCHDOG: Maximum runtime exceeded. Exiting script."
    # Force exit the main process (this script)
    [Environment]::Exit(1)
} -ArgumentList $MAX_RUNTIME_MINUTES

# ---------- Helper: run a command with timeout ----------
function Invoke-WithTimeout {
    param(
        [ScriptBlock]$ScriptBlock,
        [int]$TimeoutSeconds = 60,
        [string]$ErrorMessage = "Command timed out"
    )
    $job = Start-Job -ScriptBlock $ScriptBlock
    if ($job | Wait-Job -Timeout $TimeoutSeconds) {
        $result = Receive-Job -Job $job -AutoRemoveJob
        return $result
    } else {
        Stop-Job -Job $job -Force
        Remove-Job -Job $job -Force
        Write-Host "ERROR: $ErrorMessage"
        return $null
    }
}

# ---------- Process each VM ----------
foreach ($item in $schedule) {
    # Wait until due time (if delay > 0)
    if ($item.Delay -gt 0) {
        $now = Get-Date
        if ($item.DueTime -gt $now) {
            $waitSec = ($item.DueTime - $now).TotalSeconds
            Write-Host "Waiting $([math]::Round($waitSec,1)) seconds for $($item.VMName) (delay $($item.Delay) min)..."
            Start-Sleep -Seconds $waitSec
        }
    }

    Write-Host "`n----- Processing VM: $($item.VMName) (delay $($item.Delay) min) -----"

    # Launch a new PowerShell process for each VM, with a VM‑level timeout
    $vmScript = @"
param(`$ClusterIP, `$VMName, `$RequestedCPU, `$RequestedMemGB, `$PE_User, `$PE_Pass)

# Load snapin and connect
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}
`$Pass = `$PE_Pass | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server `$ClusterIP -UserName `$PE_User -Password `$Pass -AcceptInvalidSSLCerts | Out-Null

# Get VM
`$VM = Get-NTNXVM | Where-Object { `$_.vmName -eq `$VMName }
if (-not `$VM) {
    Write-Host "[`$VMName] ERROR: VM not found."
    Disconnect-NTNXCluster -Servers `$ClusterIP
    exit 1
}

`$CurrentCPU = [int]`$VM.numVcpus
`$CurrentMemGB = [int](`$VM.memoryMb / 1024)

`$FinalCPU = if (`$RequestedCPU -gt 0) { `$RequestedCPU } else { `$CurrentCPU }
`$TempMem = if (`$RequestedMemGB -gt 0) { `$RequestedMemGB } else { `$CurrentMemGB }
`$FinalMemGB = if (`$TempMem -lt 1) { 1 } else { `$TempMem }

if (`$FinalCPU -eq `$CurrentCPU -and `$FinalMemGB -eq `$CurrentMemGB) {
    Write-Host "[`$VMName] No change needed."
    Disconnect-NTNXCluster -Servers `$ClusterIP
    exit 0
}

# Shutdown attempts with force fallback
Write-Host "[`$VMName] ACPI shutdown (attempt 1)..."
Set-NTNXVMPowerState -Vmid `$VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 40
`$CheckVM = Get-NTNXVM -Vmid `$VM.uuid
if (`$CheckVM.powerState -eq "ON") {
    Write-Host "[`$VMName] ACPI shutdown (attempt 2)..."
    Set-NTNXVMPowerState -Vmid `$VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 20
}
`$CheckVM = Get-NTNXVM -Vmid `$VM.uuid
if (`$CheckVM.powerState -eq "ON") {
    Write-Host "[`$VMName] Force power OFF."
    Set-NTNXVMPowerState -Vmid `$VM.uuid -Transition OFF -ErrorAction Stop | Out-Null
    Start-Sleep -Seconds 10
}

# Resize and power on
Write-Host "[`$VMName] Applying: `$FinalCPU CPU, `$FinalMemGB GB RAM."
Set-NTNXVirtualMachine -Vmid `$VM.uuid -NumVcpus `$FinalCPU -MemoryMb (`$FinalMemGB * 1024) -ErrorAction Stop | Out-Null
Set-NTNXVMPowerState -Vmid `$VM.uuid -Transition ON -ErrorAction Stop | Out-Null

Disconnect-NTNXCluster -Servers `$ClusterIP
Write-Host "[`$VMName] SUCCESS."
exit 0
"@

    # Write the VM script to a temp file (to pass to powershell.exe)
    $tempScript = [System.IO.Path]::GetTempFileName() + ".ps1"
    $vmScript | Out-File -FilePath $tempScript -Encoding ASCII

    # Build arguments
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`" " +
            "`"$ClusterIP`" `"$($item.VMName)`" `"$RequestedCPU`" `"$RequestedMemGB`" `"$env:PE_USER`" `"$env:PE_PASS`""

    # Launch the process and wait with timeout
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $args -PassThru -NoNewWindow
    $timedOut = $proc.WaitForExit($VM_TIMEOUT_SECONDS * 1000)  # milliseconds

    if (-not $timedOut) {
        Write-Host "[$($item.VMName)] TIMEOUT: VM processing exceeded $VM_TIMEOUT_SECONDS seconds. Killing process."
        $proc.Kill()
        $proc.WaitForExit()
    } else {
        $exitCode = $proc.ExitCode
        Write-Host "[$($item.VMName)] Process finished with exit code $exitCode."
    }

    # Clean up temp file
    Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
    $item.Processed = $true
}

# ---------- Cleanup ----------
Stop-Job -Job $watchdogJob -Force -ErrorAction SilentlyContinue
Remove-Job -Job $watchdogJob -Force -ErrorAction SilentlyContinue
Write-Host "`n===== All VMs processed (or attempted) ====="
