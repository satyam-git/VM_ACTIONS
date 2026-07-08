param($JsonInputs)
Write-Output "--- NUTANIX AUTOMATION DEBUG LOGS ---"

# Support both parameter passing and direct environment variable reading for maximum robustness
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

function Initialize-Nutanix {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
    }
}

$siteMap = @{ "Bangalore" = "192.168.136.50"; "Pune" = "10.0.0.20"; "Chennai" = "10.0.0.10" }
$siteName = [string]$data.s1
$vmInput = [string]$data.v1
$op = [string]$data.op # 1=Create, 2=Delete, 3=Restore
$snapInput = [string]$data.sn1
$delayInput = [string]$data.d1

# Split comma-separated inputs
$vmNames = @()
if ($vmInput -and $vmInput.Trim() -ne "") {
    $vmNames = @($vmInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}
$snapNames = @()
if ($snapInput -and $snapInput.Trim() -ne "") {
    $snapNames = @($snapInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

# Split delays – values are interpreted as MINUTES
$delayMinutes = [System.Collections.Generic.List[int]]::new()
if ($delayInput -and $delayInput.Trim() -ne "") {
    $parts = $delayInput.Split(",")
    foreach ($part in $parts) {
        $trimmed = $part.Trim()
        if ($trimmed -ne "") {
            $parsedVal = 0
            if ([int]::TryParse($trimmed, [ref]$parsedVal)) {
                [void]$delayMinutes.Add($parsedVal)
            }
        }
    }
}
Write-Output "List of parsed delays (in minutes): $($delayMinutes -join ', ')"

if ($vmNames.Count -eq 0) {
    Write-Error "No VM names provided."
    exit 1
}

# Pre-initialize Nutanix on the host thread to ensure assemblies/types are registered and cached
try {
    Initialize-Nutanix
} catch {
    Write-Warning "Failed to pre-load Nutanix snap-in on host thread: $($_.Exception.Message)"
}

# Create a custom InitialSessionState and pre-register/import the Nutanix snap-in
# so that all Runspaces created by the pool inherit the loaded snap-in by default in a thread-safe manner.
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$warning = $null
try {
    $iss.ImportPSSnapIn("NutanixCmdletsPSSnapin", [ref]$warning)
} catch {
    Write-Warning "Failed to pre-import Nutanix snap-in into InitialSessionState: $($_.Exception.Message)"
}

# Define the worker script block which will run in parallel threads.
# Using param() block lets Invoke-Command bind parameters perfectly and thread-safely.
$workerBlock = {
    param($siteIp, $user, $pass, $vmName, $snapName, $op, $delayMinutes)
    
    function Write-NtnxLog($msg) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Output "[$timestamp] [VM: $vmName] $msg"
    }
    
    Write-NtnxLog "Background worker initialized. Site IP: $siteIp, Action Op: $op, Delay (minutes): $delayMinutes"

    # Robust, thread-safe dynamic check to verify if the Nutanix snap-in cmdlets
    # are actually loaded and visible in the current Runspace session.
    try {
        if (-not (Get-Command Connect-NTNXCluster -ErrorAction SilentlyContinue)) {
            Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
        }
    } catch {
        Write-NtnxLog "Failed to load Nutanix snap-in inside background worker thread: $($_.Exception.Message)"
        return
    }

    # Convert minutes to seconds for the sleep
    $delaySec = $delayMinutes * 60
    if ($delaySec -gt 0) {
        Write-NtnxLog "Delaying execution by $delayMinutes minutes ($delaySec seconds)..."
        Start-Sleep -Seconds $delaySec
        Write-NtnxLog "Delay completed. Resuming operation."
    } else {
        Write-NtnxLog "Starting execution immediately."
    }

    $workerStatus = "Successful"
    $errorMessage = ""

    try {
        Write-NtnxLog "Connecting to Prism Element on $siteIp..."
        $creds = [System.Security.SecureString]::new()
        foreach ($c in $pass.ToCharArray()) { $creds.AppendChar($c) }
        Connect-NTNXCluster -Server $siteIp -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        Write-NtnxLog "Connected successfully."

        Write-NtnxLog "Locating target VM..."
        $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$vmName' was not found on cluster."
        }
        Write-NtnxLog "VM found with UUID: $($vm.uuid). PowerState: $($vm.powerState)"

        switch ($op) {
            "1" { # CREATE
                Write-NtnxLog "Creating snapshot '$snapName'..."
                $spec = New-NTNXObject -Name SnapshotSpecDTO
                $spec.vmUuid = $vm.uuid
                $spec.snapshotName = $snapName
                New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
                Write-NtnxLog "SUCCESS: Created snapshot '$snapName'"
            }
            "2" { # DELETE
                Write-NtnxLog "Searching for snapshot '$snapName'..."
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { throw "Snapshot '$snapName' not found." }
                Write-NtnxLog "Deleting snapshot '$snapName'..."
                Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-NtnxLog "SUCCESS: Deleted snapshot '$snapName'"
            }
            "3" { # RESTORE
                Write-NtnxLog "Searching for snapshot '$snapName'..."
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { throw "Snapshot '$snapName' not found." }

                if ($vm.powerState -eq "ON") {
                    Write-NtnxLog "VM is currently powered ON. Initiating ACPI graceful shutdown..."
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                    
                    $isOff = $false
                    # Try up to 10 shutdown verification cycles (30s interval each)
                    for($attempt = 1; $attempt -le 10; $attempt++) {
                        Write-NtnxLog "Waiting 30 seconds to validate VM power status (Attempt $attempt/10)..."
                        Start-Sleep -Seconds 30
                        
                        $checkVm = Get-NTNXVM -Vmid $vm.uuid
                        if ($checkVm.powerState -eq "OFF") { 
                            $isOff = $true
                            Write-NtnxLog "VM shutdown validated. PowerState is OFF."
                            break 
                        }
                        
                        if ($attempt -lt 10) {
                            Write-NtnxLog "VM is still ON. Re-triggering ACPI graceful shutdown..."
                            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                        }
                    }
                    if (-not $isOff) { throw "VM failed to shut down after multiple ACPI graceful shutdown triggers." }
                }

                Write-NtnxLog "Waiting 60 seconds to allow the hypervisor to release disk locks..."
                Start-Sleep -Seconds 60

                Write-NtnxLog "Restoring VM state from snapshot '$snapName'..."
                Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-NtnxLog "Reverted block-storage states cleanly."

                Write-NtnxLog "Powering VM back ON..."
                Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
                Write-NtnxLog "SUCCESS: Restore completed and powered ON successfully."
            }
        }
    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -like "*was not found on cluster*") {
            $workerStatus = "VM Not Found"
        } elseif ($errorMessage -like "*Snapshot*not found*") {
            $workerStatus = "Snapshot Name not Found"
        } else {
            $workerStatus = "failed"
        }
        Write-NtnxLog "CRITICAL FAILURE: $errorMessage"
    } finally {
        # Do not call Disconnect-NTNXCluster here to avoid cross-thread connection interference in the shared process space.
        # Connection cleanup will be handled at the very end of the main thread.
        
        $actionName = switch ($op) {
            "1" { "create" }
            "2" { "delete" }
            "3" { "restore" }
            default { "unknown" }
        }

        # Output the structural results object as PSCustomObject with keys matching the requested exact column names
        [PSCustomObject]@{
            "VM Name"       = $vmName
            "Snapshot Name" = $snapName
            "Action"        = $actionName
            "Status"        = $workerStatus
            "Error"         = $errorMessage
        }
    }
}

$runspaces = @()
# Create the RunspacePool using the standard 2-argument signature (min, max).
# This avoids passing $Host or $iss which can cause sequential host-synchronization locks.
# By setting both min and max runspaces to the VM count, we guarantee that all VM threads execute in parallel.
$pool = [RunspaceFactory]::CreateRunspacePool([int]$vmNames.Count, [int]$vmNames.Count)
$pool.Open()

for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $vmName = $vmNames[$i]
    $snapName = if ($i -lt $snapNames.Count) { $snapNames[$i] } else { "$vmName-snapshot" }
    
    # Determine delay in MINUTES
    $delayMin = 0
    if ($delayMinutes.Count -eq 0) {
        $delayMin = 20   # Default 20 minutes
    } elseif ($delayMinutes.Count -eq 1) {
        $delayMin = $delayMinutes[0]
    } else {
        if ($i -lt $delayMinutes.Count) {
            $delayMin = $delayMinutes[$i]
        } else {
            $delayMin = $delayMinutes[$delayMinutes.Count - 1]
        }
    }
    Write-Output "Allocated VM '$vmName' delay: $delayMin minutes."

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    
    # Execute the worker ScriptBlock directly on the PowerShell instance.
    # This completely bypasses the Invoke-Command cmdlet, avoiding all host-routing or stream-serialization locks.
    # Parameters are passed positionally using AddArgument to bind to the script block's param() definition.
    [void]$ps.AddScript($workerBlock)
    [void]$ps.AddArgument($siteMap[$siteName])
    [void]$ps.AddArgument($env:PE_USER)
    [void]$ps.AddArgument($env:PE_PASS)
    [void]$ps.AddArgument($vmName)
    [void]$ps.AddArgument($snapName)
    [void]$ps.AddArgument($op)
    [void]$ps.AddArgument($delayMin)

    $handle = $ps.BeginInvoke()
    
    $runspaces += [PSCustomObject]@{
        PowerShell = $ps
        Handle     = $handle
        VMName     = $vmName
    }
}

Write-Output "Dispatched parallel thread-workers for $($vmNames.Count) VMs."
Write-Output "Waiting for parallel execution threads to complete..."

$hasErrors = $false
$resultsList = @()
$completedRunspaces = @{}
$completedCount = 0

while ($completedCount -lt $runspaces.Count) {
    foreach ($r in $runspaces) {
        if (-not $completedRunspaces[$r.VMName] -and $r.Handle.IsCompleted) {
            Write-Output "`n======================================================================"
            Write-Output "LOG STREAM: VM '$($r.VMName)'"
            Write-Output "======================================================================"
            
            # Retrieve standard output and check for the PSCustomObject result
            $output = $r.PowerShell.EndInvoke($r.Handle)
            foreach ($line in $output) {
                if ($line -is [System.Management.Automation.PSCustomObject] -and $null -ne $line.PSObject.Properties['VM Name']) {
                    $resultsList += $line
                } else {
                    Write-Output $line
                }
            }

            # Retrieve errors
            if ($r.PowerShell.Streams.Error.Count -gt 0) {
                $hasErrors = $true
                foreach ($err in $r.PowerShell.Streams.Error) {
                    Write-Error "[VM: $($r.VMName)] $err"
                }
            }
            
            $r.PowerShell.Dispose()
            $completedRunspaces[$r.VMName] = $true
            $completedCount++
        }
    }
    Start-Sleep -Seconds 1
}

$pool.Close()
$pool.Dispose()

# Cleanup connections at the very end of the main script
try {
    Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
} catch {
    $null = $_
}

# Create table matching screenshot exactly: VM Name | Snapshot Name | Action | Status
Write-Output "`n===== EXECUTED RESULTS ====="
$formatTable = $resultsList | Format-Table -Property "VM Name", "Snapshot Name", "Action", "Status" -AutoSize | Out-String
Write-Output $formatTable

# Write to GITHUB_STEP_SUMMARY as an elegant Markdown table matching the screenshot
if ($env:GITHUB_STEP_SUMMARY) {
    try {
        $summary = @"
### Nutanix VM Snapshot Report

| VM Name | Snapshot Name | Action | Status |
| :--- | :--- | :--- | :--- |
"@
        foreach ($res in $resultsList) {
            # Normalize Status to exactly match capitalization/look from screenshot
            # "Successful" (Capitalized), "failed" (Lowercase), "VM Not Found"
            $statusStr = if ($res.Status -eq "Successful") {
                "Successful"
            } elseif ($res.Status -eq "VM Not Found") {
                "VM Not Found"
            } elseif ($res.Status -eq "Snapshot Name not Found") {
                "Snapshot Name not Found"
            } else {
                "failed"
            }
            $summary += "`n| $($res.'VM Name') | $($res.'Snapshot Name') | $($res.Action) | $statusStr |"
        }

        # Check if there are any failed records to add details block
        $failures = $resultsList | Where-Object { $_.Status -ne "Successful" }
        if ($failures) {
            $summary += "`n`n### Failure Details`n"
            foreach ($fail in $failures) {
                $summary += "- **$($fail.'VM Name')**: $($fail.Error)`n"
            }
        }
        
        $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
        Write-Output "`nSuccessfully appended report to GITHUB_STEP_SUMMARY."
    } catch {
        Write-Warning "Failed to write to GITHUB_STEP_SUMMARY: $($_.Exception.Message)"
    }
}

# If we had any errors or any task failed, exit with 1
$failedTasksCount = ($resultsList | Where-Object { $_.Status -ne "Successful" }).Count
if ($hasErrors -or $failedTasksCount -gt 0) {
    exit 1
}
