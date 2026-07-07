[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$JsonInputs
)

Write-Output "--- NUTANIX AUTOMATION DEBUG LOGS ---"
Write-Output "Raw JSON input received: $JsonInputs"

# Parse inputs
try {
    $inputs = ConvertFrom-Json $JsonInputs
} catch {
    Write-Error "Failed to parse JSON inputs: $($_.Exception.Message)"
    exit 1
}

$siteName = $inputs.s1
$vmsInput = $inputs.v1
$op       = $inputs.op
$snapsInput = $inputs.sn1
$delaysInput = $inputs.d1

Write-Output "Parsed s1 (Site): $siteName"
Write-Output "Parsed v1 (VMs): $vmsInput"
Write-Output "Parsed op (Op): $op"
Write-Output "Parsed sn1 (Snaps): $snapsInput"
Write-Output "Parsed d1 (Delays): $delaysInput"

# Site to Cluster IP mapping
$siteIpMap = @{
    "Bangalore" = "10.10.10.10" # Replace with actual Bangalore PRISM IP
    "Pune"      = "10.20.20.20" # Replace with actual Pune PRISM IP
    "Chennai"   = "10.30.30.30" # Replace with actual Chennai PRISM IP
}

$siteIp = $siteIpMap[$siteName]
if (-not $siteIp) {
    Write-Error "Site name '$siteName' does not map to a configured Cluster IP."
    exit 1
}

# Credentials
$user = $env:PE_USER
$pass = $env:PE_PASS

if (-not $user -or -not $pass) {
    Write-Error "Prism Element credentials (PE_USER, PE_PASS) are missing from the environment."
    exit 1
}

# Helper to load snap-in
function Initialize-Nutanix {
    if (!(Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction Stop
    }
}

# Parse comma-separated variables
$vmNames = [System.Collections.Generic.List[string]]::new()
if ($vmsInput -and $vmsInput -ne "none") {
    foreach ($v in $vmsInput.Split(',')) {
        $trimmed = $v.Trim()
        if ($trimmed) { [void]$vmNames.Add($trimmed) }
    }
}

$snapNames = [System.Collections.Generic.List[string]]::new()
if ($snapsInput -and $snapsInput -ne "none") {
    foreach ($s in $snapsInput.Split(',')) {
        $trimmed = $s.Trim()
        if ($trimmed) { [void]$snapNames.Add($trimmed) }
    }
}

$delayMinutes = [System.Collections.Generic.List[int]]::new()
if ($delaysInput -and $delaysInput -ne "none") {
    foreach ($d in $delaysInput.Split(',')) {
        $trimmed = $d.Trim()
        if ($trimmed) {
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
$workerBlock = {
    param($siteIp, $user, $pass, $vmName, $snapName, $op, $delayMinutes)
    
    function Write-Log($msg) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Output "[$timestamp] [VM: $vmName] $msg"
    }
    
    Write-Log "Background worker initialized. Site IP: $siteIp, Action Op: $op, Delay (minutes): $delayMinutes"

    # Robust, thread-safe dynamic check to verify if the Nutanix snap-in cmdlets
    # are actually loaded and visible in the current Runspace session.
    try {
        if (-not (Get-Command Connect-NTNXCluster -ErrorAction SilentlyContinue)) {
            Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
        }
    } catch {
        Write-Log "Failed to load Nutanix snap-in inside background worker thread: $($_.Exception.Message)"
        return
    }

    # Convert minutes to seconds for the sleep
    $delaySec = $delayMinutes * 60
    if ($delaySec -gt 0) {
        Write-Log "Delaying execution by $delayMinutes minutes ($delaySec seconds)..."
        Start-Sleep -Seconds $delaySec
        Write-Log "Delay completed. Resuming operation."
    } else {
        Write-Log "Starting execution immediately."
    }

    $workerStatus = "Successful"
    $errorMessage = ""

    try {
        Write-Log "Connecting to Prism Element on $siteIp..."
        $creds = [System.Security.SecureString]::new()
        foreach ($c in $pass.ToCharArray()) { $creds.AppendChar($c) }
        Connect-NTNXCluster -Server $siteIp -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        Write-Log "Connected successfully."

        Write-Log "Locating target VM..."
        $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$vmName' was not found on cluster."
        }
        Write-Log "VM found with UUID: $($vm.uuid). PowerState: $($vm.powerState)"

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
                Write-Log "Searching for snapshot '$snapName'..."
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { throw "Snapshot '$snapName' not found." }
                Write-Log "Deleting snapshot '$snapName'..."
                Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Log "SUCCESS: Deleted snapshot '$snapName'"
            }
            "3" { # RESTORE
                Write-Log "Searching for snapshot '$snapName'..."
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { throw "Snapshot '$snapName' not found." }

                if ($vm.powerState -eq "ON") {
                    Write-Log "VM is currently powered ON. Initiating ACPI graceful shutdown..."
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                    
                    $isOff = $false
                    # Try up to 10 shutdown verification cycles (30s interval each)
                    for($attempt = 1; $attempt -le 10; $attempt++) {
                        Write-Log "Waiting 30 seconds to validate VM power status (Attempt $attempt/10)..."
                        Start-Sleep -Seconds 30
                        
                        $checkVm = Get-NTNXVM -Vmid $vm.uuid
                        if ($checkVm.powerState -eq "OFF") { 
                            $isOff = $true
                            Write-Log "VM shutdown validated. PowerState is OFF."
                            break 
                        }
                        
                        if ($attempt -lt 10) {
                            Write-Log "VM is still ON. Re-triggering ACPI graceful shutdown..."
                            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                        }
                    }
                    if (-not $isOff) { throw "VM failed to shut down after multiple ACPI graceful shutdown triggers." }
                }

                Write-Log "Waiting 60 seconds to allow the hypervisor to release disk locks..."
                Start-Sleep -Seconds 60

                Write-Log "Restoring VM state from snapshot '$snapName'..."
                Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Log "Reverted block-storage states cleanly."

                Write-Log "Powering VM back ON..."
                Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
                Write-Log "SUCCESS: Restore completed and powered ON successfully."
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
        Write-Log "CRITICAL FAILURE: $errorMessage"
    } finally {
        try {
            Disconnect-NTNXCluster -ErrorAction SilentlyContinue | Out-Null
        } catch {}
        
        # Output a clean structured tracking block back to the parent stream
        [PSCustomObject]@{
            VMName       = $vmName
            Status       = $workerStatus
            ErrorMessage = $errorMessage
        }
    }
}

$runspaces = @()
# Create the RunspacePool using the 2-argument signature (min, max).
# This avoids passing $iss or $Host, which eliminates host-synchronization locks and ensures true parallel execution.
$pool = [RunspaceFactory]::CreateRunspacePool([int]$vmNames.Count, [int]$vmNames.Count)
$pool.Open()

for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $currentVmName = $vmNames[$i]
    
    # Sequential fallback indexing for snapshots and delays if counts don't match perfectly
    $currentSnapName = if ($i -lt $snapNames.Count) { $snapNames[$i] } else { $snapNames[$snapNames.Count - 1] }
    $currentDelay = if ($i -lt $delayMinutes.Count) { $delayMinutes[$i] } else { 0 }
    
    Write-Output "Queueing independent thread for VM: $currentVmName | Snapshot: $currentSnapName | Delay: $currentDelay minutes"
    
    $powershell = [PowerShell]::Create()
    $powershell.RunspacePool = $pool
    
    # Bind parameters safely
    [void]$powershell.AddScript($workerBlock)
    [void]$powershell.AddArgument($siteIp)
    [void]$powershell.AddArgument($user)
    [void]$powershell.AddArgument($pass)
    [void]$powershell.AddArgument($currentVmName)
    [void]$powershell.AddArgument($currentSnapName)
    [void]$powershell.AddArgument($op)
    [void]$powershell.AddArgument($currentDelay)
    
    $handle = $powershell.BeginInvoke()
    
    $runspaces += [PSCustomObject]@{
        PowerShellObj = $powershell
        Handle        = $handle
        VMName        = $currentVmName
    }
}

# Wait asynchronously for all background threads to complete, retrieving and logging messages immediately
Write-Output "Successfully launched all independent tasks. Monitoring execution streams..."
$completedCount = 0
$resultsTable = [System.Collections.Generic.List[PSCustomObject]]::new()

while ($completedCount -lt $runspaces.Count) {
    Start-Sleep -Seconds 5
    foreach ($r in $runspaces) {
        if ($r.Handle -and $r.Handle.IsCompleted) {
            # Retrieve output and dispose resources
            $outputs = $r.PowerShellObj.EndInvoke($r.Handle)
            
            # Print verbose logs produced inside the thread
            $streams = $r.PowerShellObj.Streams
            if ($streams.Verbose) {
                foreach ($v in $streams.Verbose) { Write-Output "[VERBOSE] $v" }
            }
            if ($streams.Error) {
                foreach ($err in $streams.Error) { Write-Output "[ERROR] $err" }
            }
            
            # Extract final status
            if ($outputs) {
                foreach ($out in $outputs) {
                    if ($out.VMName) {
                        $resultsTable.Add($out)
                    }
                }
            } else {
                $resultsTable.Add([PSCustomObject]@{
                    VMName       = $r.VMName
                    Status       = "failed"
                    ErrorMessage = "No structured response returned from thread execution."
                })
            }
            
            # Clear handle to avoid processing again
            $r.Handle = $null
            $r.PowerShellObj.Dispose()
            $completedCount++
        }
    }
}

# Clean up pool
$pool.Close()
$pool.Dispose()

# Display final summary table
Write-Output "`n=================================================="
Write-Output "             FINAL EXECUTION SUMMARY              "
Write-Output "=================================================="
$resultsTable | Format-Table -AutoSize | Out-String | Write-Output

# Verify if any workers failed and report non-zero exit code if needed
$anyFailures = $resultsTable | Where-Object { $_.Status -ne "Successful" }
if ($anyFailures) {
    Write-Output "Workflow finished with errors."
    exit 1
} else {
    Write-Output "All operations finished successfully."
    exit 0
}
