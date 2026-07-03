param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

function Initialize-Nutanix {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
    }
}

$siteMap = @{ "Bangalore" = "192.168.136.50"; "Pune" = "10.0.0.20"; "Chennai" = "10.0.0.10" }
$siteName = $data.s1
$vmInput = $data.v1
$op = $data.op # 1=Create, 2=Delete, 3=Restore
$snapInput = $data.sn1
$delayInput = $data.d1

# Split comma-separated inputs
$vmNames = $vmInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
$snapNames = $snapInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

# Split delays
$delays = @()
if ($delayInput) {
    $delays = $delayInput.Split(",") | ForEach-Object { [int]$_.Trim() }
}

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

$runspaces = @()
$pool = [RunspaceFactory]::CreateRunspacePool(1, $vmNames.Count, $iss, $Host)
$pool.Open()

for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $vmName = $vmNames[$i]
    $snapName = if ($i -lt $snapNames.Count) { $snapNames[$i] } else { "$vmName-snapshot" }
    $delay = if ($i -lt $delays.Count) { $delays[$i] } else { 0 }
    
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    
    # We pass variables as arguments
    [void]$ps.AddScript({
        param($siteIp, $user, $pass, $vmName, $snapName, $op, $delay)
        
        function Write-Log($msg) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Output "[$timestamp] [VM: $vmName] $msg"
        }
        
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

        if ($delay -gt 0) {
            Write-Log "Delaying execution by $delay seconds..."
            Start-Sleep -Seconds $delay
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
                        for($j=0; $j -lt 30; $j++) {
                            Start-Sleep -Seconds 10
                            $checkVm = Get-NTNXVM -Vmid $vm.uuid
                            if ($checkVm.powerState -eq "OFF") { $isOff = $true; break }
                            Write-Log "Waiting for graceful shutdown... ($(($j+1)*10)s)"
                        }
                        if (-not $isOff) { throw "VM failed to shut down gracefully within 5 minutes." }
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
    })
    
    [void]$ps.AddArgument($siteMap[$siteName])
    [void]$ps.AddArgument($env:PE_USER)
    [void]$ps.AddArgument($env:PE_PASS)
    [void]$ps.AddArgument($vmName)
    [void]$ps.AddArgument($snapName)
    [void]$ps.AddArgument($op)
    [void]$ps.AddArgument($delay)

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
