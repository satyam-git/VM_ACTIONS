param($JsonInputs)
Write-Output "--- NUTANIX AUTOMATION DEBUG LOGS ---"

# Support both parameter passing and direct environment variable reading
$rawJson = $JsonInputs
if (-not $rawJson -or $rawJson.Trim() -eq "") {
    if ($env:INPUTS_JSON -and $env:INPUTS_JSON.Trim() -ne "") {
        $rawJson = $env:INPUTS_JSON
    }
}

Write-Output "Raw JSON input received: $rawJson"
$data = $rawJson | ConvertFrom-Json
Write-Output "Parsed s1 (Site): $($data.s1)"
Write-Output "Parsed v1 (VMs): $($data.v1)"
Write-Output "Parsed op (Op): $($data.op)"
Write-Output "Parsed sn1 (Snaps): $($data.sn1)"
Write-Output "Parsed d1 (Delays): $($data.d1)"

$siteMap = @{ "Bangalore" = "192.168.136.50"; "Pune" = "10.0.0.20"; "Chennai" = "10.0.0.10" }
$siteName = [string]$data.s1
$vmInput = [string]$data.v1
$op = [string]$data.op
$snapInput = [string]$data.sn1
$delayInput = [string]$data.d1

# Split inputs
$vmNames = @()
if ($vmInput -and $vmInput.Trim() -ne "") {
    $vmNames = @($vmInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}
$snapNames = @()
if ($snapInput -and $snapInput.Trim() -ne "") {
    $snapNames = @($snapInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

# Parse delays
$delays = [System.Collections.Generic.List[int]]::new()
if ($delayInput -and $delayInput.Trim() -ne "") {
    $parts = $delayInput.Split(",")
    foreach ($part in $parts) {
        $trimmed = $part.Trim()
        if ($trimmed -ne "") {
            $parsedVal = 0
            if ([int]::TryParse($trimmed, [ref]$parsedVal)) {
                [void]$delays.Add($parsedVal)
            }
        }
    }
}
Write-Output "List of parsed delays: $($delays -join ', ')"

if ($vmNames.Count -eq 0) {
    Write-Error "No VM names provided."
    exit 1
}

# Pre-load the Nutanix snap-in on the main thread to avoid per-worker initialization overhead
function Initialize-Nutanix {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
    }
    # Force full initialization by invoking a dummy command
    $null = Get-Command Connect-NTNXCluster -ErrorAction SilentlyContinue
}

try {
    Initialize-Nutanix
} catch {
    Write-Warning "Failed to pre-load Nutanix snap-in: $($_.Exception.Message)"
}

# Create an InitialSessionState that imports the snap-in – shared by all runspaces
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$warning = $null
try {
    $iss.ImportPSSnapIn("NutanixCmdletsPSSnapin", [ref]$warning)
} catch {
    Write-Warning "Failed to import Nutanix snap-in into InitialSessionState: $($_.Exception.Message)"
}

# Mutex name to serialize snap-in loading, just in case any worker still needs to load it
$mutexName = "Global\NutanixSnapinLoadMutex"

# -----------------------------------------------------------------
# WORKER SCRIPT BLOCK – now uses $workflowStart and sleeps in ms
# -----------------------------------------------------------------
$workerScript = {
    param($siteIp, $user, $pass, $vmName, $snapName, $op, $workflowStartUtc, $delaySec)

    function Write-Log($msg) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Output "[$timestamp] [VM: $vmName] $msg"
    }

    Write-Log "Worker started. Scheduled delay: $delaySec seconds from workflow start."

    # Ensure the snap-in is loaded (should already be present from ISS, but guard)
    if (-not (Get-Command Connect-NTNXCluster -ErrorAction SilentlyContinue)) {
        Write-Log "Snap-in not found, attempting to load with mutex..."
        $mutex = $null
        try {
            $mutex = [System.Threading.Mutex]::OpenExisting($mutexName)
        } catch {
            $mutex = [System.Threading.Mutex]::new($false, $mutexName)
        }
        $mutex.WaitOne() | Out-Null
        try {
            Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
            Write-Log "Snap-in loaded successfully."
        } catch {
            Write-Error "Failed to load Nutanix snap-in: $($_.Exception.Message)"
            $mutex.ReleaseMutex()
            $mutex.Dispose()
            return
        }
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }

    # 1. Connect to Prism
    try {
        Write-Log "Connecting to Prism Element on $siteIp..."
        $creds = ConvertTo-SecureString $pass -AsPlainText -Force
        Connect-NTNXCluster -Server $siteIp -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        Write-Log "Connected successfully."
    } catch {
        Write-Error "Connection failed: $($_.Exception.Message)"
        return
    }

    # 2. Get VM
    try {
        Write-Log "Locating target VM..."
        $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$vmName' was not found on cluster."
        }
        Write-Log "VM found with UUID: $($vm.uuid). PowerState: $($vm.powerState)"
    } catch {
        Write-Error "VM lookup failed: $($_.Exception.Message)"
        Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
        return
    }

    # 3. For Delete/Restore, get snapshot UUID
    $snap = $null
    if ($op -in @("2", "3")) {
        try {
            Write-Log "Searching for snapshot '$snapName'..."
            $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
            if (-not $snap) {
                throw "Snapshot '$snapName' not found for VM '$vmName'."
            }
            Write-Log "Snapshot found with UUID: $($snap.uuid)"
        } catch {
            Write-Error "Snapshot lookup failed: $($_.Exception.Message)"
            Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
            return
        }
    }

    # 4. Wait until the scheduled time (workflow start + delay)
    $now = [DateTime]::UtcNow
    $elapsedMs = ($now - $workflowStartUtc).TotalMilliseconds
    $remainingMs = ($delaySec * 1000) - $elapsedMs
    if ($remainingMs -gt 0) {
        Write-Log "Elapsed since workflow start: $([math]::Round($elapsedMs/1000, 2)) sec. Waiting $([math]::Round($remainingMs, 0)) ms..."
        Start-Sleep -Milliseconds ([int]$remainingMs)
        Write-Log "Scheduled time reached. Proceeding with operation."
    } else {
        Write-Warning "Scheduled time has already passed (elapsed $([math]::Round($elapsedMs/1000, 2)) sec, delay $delaySec sec). Proceeding immediately."
    }

    # 5. Perform the final operation
    try {
        switch ($op) {
            "1" { # CREATE
                Write-Log "Creating snapshot '$snapName'..."
                $spec = New-NTNXObject -Name SnapshotSpecDTO
                $spec.vmUuid = $vm.uuid
                $spec.snapshotName = $snapName
                New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
                Write-Log "SUCCESS: Created snapshot '$snapName'"
            }
            "2" { # DELETE
                Write-Log "Deleting snapshot '$snapName'..."
                Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Log "SUCCESS: Deleted snapshot '$snapName'"
            }
            "3" { # RESTORE
                Write-Log "Restoring VM from snapshot '$snapName'..."
                if ($vm.powerState -eq "ON") {
                    Write-Log "VM is powered ON. Initiating ACPI graceful shutdown..."
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                    $isOff = $false
                    for ($attempt = 1; $attempt -le 10; $attempt++) {
                        Write-Log "Waiting 30 seconds for shutdown (Attempt $attempt/10)..."
                        Start-Sleep -Seconds 30
                        $checkVm = Get-NTNXVM -Vmid $vm.uuid
                        if ($checkVm.powerState -eq "OFF") {
                            $isOff = $true
                            Write-Log "VM shutdown validated."
                            break
                        }
                        if ($attempt -lt 10) {
                            Write-Log "VM still ON, re‑triggering ACPI shutdown..."
                            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                        }
                    }
                    if (-not $isOff) {
                        throw "VM failed to shut down after multiple attempts."
                    }
                }

                Write-Log "Waiting 60 seconds for hypervisor to release locks..."
                Start-Sleep -Seconds 60

                Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Log "Block storage reverted."

                Write-Log "Powering VM ON..."
                Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
                Write-Log "SUCCESS: Restore completed."
            }
        }
    } catch {
        Write-Error "CRITICAL FAILURE during operation: $($_.Exception.Message)"
    } finally {
        Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
    }
}

# -----------------------------------------------------------------
# Launch runspaces – all workers share the same workflow start time
# -----------------------------------------------------------------
$runspaces = @()
$pool = [RunspaceFactory]::CreateRunspacePool(1, $vmNames.Count, $iss, $Host)
$pool.Open()

$workflowStart = [DateTime]::UtcNow  # Single timestamp for all workers

for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $vmName = $vmNames[$i]
    $snapName = if ($i -lt $snapNames.Count) { $snapNames[$i] } else { "$vmName-snapshot" }

    # Determine delay
    $delay = 0
    if ($delays.Count -eq 0) {
        $delay = 20
    } elseif ($delays.Count -eq 1) {
        $delay = $delays[0]
    } else {
        if ($i -lt $delays.Count) {
            $delay = $delays[$i]
        } else {
            $delay = $delays[$delays.Count - 1]
        }
    }
    Write-Output "VM '$vmName' scheduled delay: $delay seconds from workflow start."

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool

    # Execute the script block directly – no Invoke-Command wrapper
    [void]$ps.AddScript($workerScript.ToString())

    # Pass arguments as an array to the script block
    $argsList = @(
        $siteMap[$siteName],
        $env:PE_USER,
        $env:PE_PASS,
        $vmName,
        $snapName,
        $op,
        $workflowStart,
        $delay
    )
    [void]$ps.AddArgument($argsList)

    $handle = $ps.BeginInvoke()

    $runspaces += [PSCustomObject]@{
        PowerShell = $ps
        Handle     = $handle
        VMName     = $vmName
    }
}

Write-Output "Dispatched all workers. Waiting for completion..."

while ($true) {
    $active = $runspaces | Where-Object { -not $_.Handle.IsCompleted }
    if ($active.Count -eq 0) { break }
    Start-Sleep -Milliseconds 300
}

Write-Output "All workers completed."

# Collect results
$hasErrors = $false
foreach ($r in $runspaces) {
    Write-Output "`n======================================================================"
    Write-Output "LOG STREAM: VM '$($r.VMName)'"
    Write-Output "======================================================================"

    $output = $r.PowerShell.EndInvoke($r.Handle)
    foreach ($line in $output) {
        Write-Output $line
    }

    if ($r.PowerShell.Streams.Error.Count -gt 0) {
        $hasErrors = $true
        foreach ($err in $r.PowerShell.Streams.Error) {
            Write-Error "[VM: $($r.VMName)] $err"
        }
    }

    $r.PowerShell.Dispose()
}

$pool.Close()
$pool.Dispose()

if ($hasErrors) {
    exit 1
}
