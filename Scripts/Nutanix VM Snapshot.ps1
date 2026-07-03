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

# Split delays and ensure it remains a strongly-typed array to prevent scalar unwrapping in Windows PowerShell
$delays = @()
if ($delayInput -and $delayInput.Trim() -ne "") {
    $parts = $delayInput.Split(",")
    foreach ($part in $parts) {
        $trimmed = $part.Trim()
        if ($trimmed -ne "") {
            if ($trimmed -match '^\d+$') {
                $delays += [int]$trimmed
            }
        }
    }
}
Write-Output "List of parsed delays: $($delays -join ', ')"

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
    param($siteIp, $user, $pass, $vmName, $snapName, $op, $delay)
    
    function Write-Log($msg) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Output "[$timestamp] [VM: $vmName] $msg"
    }
    
    Write-Log "Background worker initialized. Site IP: $siteIp, Action Op: $op, Delay: $delay"

    # Robust, thread-safe dynamic check to verify if the Nutanix snap-in cmdlets
    # are actually loaded and visible in the current Runspace session.
    try {
        if (-not (Get-Command Connect-NTNXCluster -ErrorAction SilentlyContinue)) {
            Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
        }
    } catch {
        Write-Error "Failed to load Nutanix snap-in inside background worker thread: $($_.Exception.Message)"
        return
    }

    $delaySec = [int]$delay
    if ($delaySec -gt 0) {
        Write-Log "Delaying execution by $delaySec seconds..."
        Start-Sleep -Seconds $delaySec
        Write-Log "Delay completed. Resuming operation."
    } else {
        Write-Log "Starting execution immediately."
    }

    try {
        Write-Log "Connecting to Prism Element on $siteIp..."
        $creds = ConvertTo-SecureString $pass -AsPlainText -Force
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
        Write-Error "CRITICAL FAILURE: $($_.Exception.Message)"
    } finally {
        Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
    }
}

$runspaces = @()
$pool = [RunspaceFactory]::CreateRunspacePool($vmNames.Count, $vmNames.Count, $iss, $Host)
$pool.Open()

for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $vmName = $vmNames[$i]
    $snapName = if ($i -lt $snapNames.Count) { $snapNames[$i] } else { "$vmName-snapshot" }
    
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
    Write-Output "Allocated VM '$vmName' delay: $delay seconds."
    
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    
    # Execute the worker block directly using AddScript and AddParameter to natively and thread-safely bind named parameters
    [void]$ps.AddScript($workerBlock.ToString())
    [void]$ps.AddParameter("siteIp", $siteMap[$siteName])
    [void]$ps.AddParameter("user", $env:PE_USER)
    [void]$ps.AddParameter("pass", $env:PE_PASS)
    [void]$ps.AddParameter("vmName", $vmName)
    [void]$ps.AddParameter("snapName", $snapName)
    [void]$ps.AddParameter("op", $op)
    [void]$ps.AddParameter("delay", $delay)

    $handle = $ps.BeginInvoke()
    
    $runspaces += [PSCustomObject]@{
        PowerShell = $ps
        Handle     = $handle
        VMName     = $vmName
    }
}

Write-Output "Dispatched parallel thread-workers for $($vmNames.Count) VMs."
Write-Output "Waiting for all parallel execution threads to complete..."

while ($true) {
    $active = $runspaces | Where-Object { -not $_.Handle.IsCompleted }
    if ($active.Count -eq 0) { break }
    Start-Sleep -Seconds 1
}

$hasErrors = $false

# Retrieve and output results
foreach ($r in $runspaces) {
    Write-Output "`n======================================================================"
    Write-Output "LOG STREAM: VM '$($r.VMName)'"
    Write-Output "======================================================================"
    
    # Retrieve standard output
    $output = $r.PowerShell.EndInvoke($r.Handle)
    foreach ($line in $output) {
        Write-Output $line
    }

    # Retrieve errors
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
