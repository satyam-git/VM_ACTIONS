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

$jobs = @()

for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $vmName = $vmNames[$i]
    
    # Determine corresponding snapshot name and delay
    $snapName = if ($i -lt $snapNames.Count) { $snapNames[$i] } else { "$vmName-snapshot" }
    $delay = if ($i -lt $delays.Count) { $delays[$i] } else { 0 }
    
    # Run the job in parallel using Start-Job
    $job = Start-Job -ScriptBlock {
        param($siteIp, $user, $pass, $vmName, $snapName, $op, $delay)
        
        try {
            if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
                Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
            }

            # Handle Independent Delay
            if ($delay -gt 0) {
                Write-Output "[VM: $vmName] Initiating independent start delay of $delay seconds..."
                Start-Sleep -Seconds $delay
            }

            Write-Output "[VM: $vmName] Connecting to Prism Element on $siteIp..."
            $creds = ConvertTo-SecureString $pass -AsPlainText -Force
            Connect-NTNXCluster -Server $siteIp -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

            Write-Output "[VM: $vmName] Locating target VM..."
            $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
            if (-not $vm) {
                throw "VM '$vmName' was not found on cluster."
            }

            switch ($op) {
                "1" { # CREATE
                    Write-Output "[VM: $vmName] Creating snapshot '$snapName'..."
                    $spec = New-NTNXObject -Name SnapshotSpecDTO
                    $spec.vmUuid = $vm.uuid
                    $spec.snapshotName = $snapName
                    New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
                    Write-Output "SUCCESS: Created snapshot '$snapName' on VM '$vmName'"
                }
                "2" { # DELETE
                    Write-Output "[VM: $vmName] Deleting snapshot '$snapName'..."
                    $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                    if (-not $snap) { throw "Snapshot '$snapName' not found on VM '$vmName'." }
                    Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
                    Write-Output "SUCCESS: Deleted snapshot '$snapName' on VM '$vmName'"
                }
                "3" { # RESTORE
                    Write-Output "[VM: $vmName] Restoring snapshot '$snapName'..."
                    $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                    if (-not $snap) { throw "Snapshot '$snapName' not found on VM '$vmName'." }

                    if ($vm.powerState -eq "ON") {
                        Write-Output "[VM: $vmName] Initiating ACPI graceful shutdown..."
                        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                        
                        # Verification loop: Poll power status every 10s for up to 5 minutes
                        $isOff = $false
                        for($j=0; $j -lt 30; $j++) {
                            Start-Sleep -Seconds 10
                            $checkVm = Get-NTNXVM -Vmid $vm.uuid
                            if ($checkVm.powerState -eq "OFF") { $isOff = $true; break }
                            Write-Output "[VM: $vmName] Waiting for graceful shutdown... ($(($j+1)*10)s)"
                        }
                        if (-not $isOff) { throw "VM '$vmName' failed to shut down gracefully." }
                    }
                    
                    # MANDATORY DELAY: Allow hypervisor to release disk locks
                    Write-Output "[VM: $vmName] Waiting 60 seconds before initiating restore to prevent SCSI reservation lock conflicts..."
                    Start-Sleep -Seconds 60
                    
                    Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
                    Write-Output "[VM: $vmName] Reverted block-storage states cleanly to snapshot '$snapName'."
                    
                    Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
                    Write-Output "SUCCESS: Restore completed and powered ON VM '$vmName'"
                }
            }
        } catch {
            Write-Error "[VM: $vmName] CRITICAL FAILURE: $($_.Exception.Message)"
        } finally {
            Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
        }
    } -ArgumentList $siteMap[$siteName], $env:PE_USER, $env:PE_PASS, $vmName, $snapName, $op, $delay

    $jobs += $job
}

Write-Output "Dispatched parallel snapshot operations for $($vmNames.Count) VMs."
Write-Output "Waiting for all parallel threads to complete (No sequential blockages)..."
$jobs | Wait-Job | Out-Null

# Retrieve outputs and check for errors
$hasErrors = $false
foreach ($j in $jobs) {
    Write-Output "======================================================================"
    Write-Output "LOG STREAM: VM '$($j.ChildJobs[0].JobParameters.ArgumentList[3])' with delay $($j.ChildJobs[0].JobParameters.ArgumentList[6])s"
    Write-Output "======================================================================"
    Receive-Job -Job $j
    if ($j.State -eq "Failed") {
        $hasErrors = $true
    }
}

# Cleanup background jobs
$jobs | Remove-Job

if ($hasErrors) {
    exit 1
}
