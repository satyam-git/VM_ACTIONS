# [UTF-8 with BOM Encoding]
# Nutanix VM Snapshot Orchestration Script
# Handles high-performance, asynchronous parallel snapshot operations on multiple VMs on Prism Element.

param(
    [string]$JsonInputs
)

$siteMap = @{
    "Bangalore" = "10.150.22.10"
    "Pune"      = "10.160.22.10"
    "Chennai"   = "10.170.22.10"
}

# Parse JSON Inputs dynamically with robust failbacks
$siteName = "None"
$vmNames = @()
$snapNames = @()
$op = "1"
$delayMinutes = @()

if ($JsonInputs) {
    try {
        $parsed = ConvertFrom-Json $JsonInputs
        
        if ($parsed.s1) { $siteName = $parsed.s1 }
        
        if ($parsed.v1 -and $parsed.v1 -ne "none") {
            $vmNames = $parsed.v1.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        }
        
        if ($parsed.sn1 -and $parsed.sn1 -ne "none") {
            $snapNames = $parsed.sn1.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        }
        
        if ($parsed.op) { $op = $parsed.op }
        
        if ($parsed.d1 -and $parsed.d1 -ne "none") {
            $delayMinutes = $parsed.d1.Split(",") | ForEach-Object { [int]$_.Trim() }
        }
    } catch {
        Write-Warning "Failed parsing JSON input: $($_.Exception.Message)"
    }
}

# Assert basic runtime validation parameters
if ($siteName -eq "None" -or -not $siteMap.ContainsKey($siteName)) {
    Write-Error "CRITICAL: A valid target site must be selected ($($siteMap.Keys -join ', '))."
    exit 1
}
if ($vmNames.Count -eq 0) {
    Write-Error "CRITICAL: No VM Names were provided."
    exit 1
}

$siteIp = $siteMap[$siteName]
Write-Output "Parsed inputs: Site = $siteName ($siteIp), VMs = $($vmNames -join ', '), Snapshot Names = $($snapNames -join ', '), Op = $op, Delays (minutes) = $($delayMinutes -join ', ')"

# Dynamically import the required module or snap-in safely
try {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
    }
} catch {
    Write-Error "NutanixCmdletsPSSnapin is not loaded and could not be found: $($_.Exception.Message)"
    exit 1
}

# Thread Worker Block definition for parallel runspaces
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
        if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
            Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
        }
    } catch {
        Write-NtnxLog "Failed to load Nutanix snap-in inside background worker thread: $($_.Exception.Message)"
        return
    }

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
            $workerStatus = "vm not found"
        } elseif ($errorMessage -like "*Snapshot*not found*") {
            $workerStatus = "Snapshot not found"
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
            # "Successful" (Capitalized), "failed" (Lowercase), "vm not found", "Snapshot not found"
            $statusStr = if ($res.Status -eq "Successful") {
                "Successful"
            } elseif ($res.Status -eq "vm not found" -or $res.Status -eq "VM Not Found") {
                "vm not found"
            } elseif ($res.Status -eq "Snapshot not found" -or $res.Status -eq "Snapshot Name not Found" -or $res.Status -eq "Snapshot not Found") {
                "Snapshot not found"
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
