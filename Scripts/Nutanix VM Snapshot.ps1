param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

function Initialize-Nutanix {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
    }
}

$siteMap = @{ "Bangalore" = "192.168.136.50"; "Pune" = "10.0.0.20"; "Chennai" = "10.0.0.10" }
$siteName = $data.s1
$vmName = $data.v1
$op = $data.op # 1=Create, 2=Delete, 3=Restore
$snapName = $data.sn1
$consistencyMode = $data.consistency # 1=Crash-Consistent, 2=App-Consistent VSS, 3=Offline Graceful

try {
    Initialize-Nutanix
    $creds = ConvertTo-SecureString $env:PE_PASS -AsPlainText -Force
    Connect-NTNXCluster -Server $siteMap[$siteName] -UserName $env:PE_USER -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

    $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
    if (-not $vm) { throw "VM '$vmName' not found." }

    switch ($op) {
        "1" { # CREATE
            $spec = New-NTNXObject -Name SnapshotSpecDTO
            $spec.vmUuid = $vm.uuid
            $spec.snapshotName = $snapName
            
            $wasOn = $false
            if ($vm.powerState -eq "ON") {
                if ($consistencyMode -eq "2") {
                    # Application-consistent using VSS (NGT Required)
                    $spec.snapshotType = "VSS"
                    Write-Output "Initiating application-consistent VSS snapshot (NGT required)..."
                }
                elseif ($consistencyMode -eq "3") {
                    # Offline Graceful Snapshot (Ensures 100% clean disk state)
                    $wasOn = $true
                    Write-Output "VM is powered ON. To prevent unexpected shutdown events on restore, shutting down VM gracefully..."
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                    
                    # Verification loop: Poll power status every 10s for up to 5 minutes
                    $isOff = $false
                    for($i=0; $i -lt 30; $i++) {
                        Start-Sleep -Seconds 10
                        $checkVm = Get-NTNXVM -Vmid $vm.uuid
                        if ($checkVm.powerState -eq "OFF") { $isOff = $true; break }
                        Write-Output "Waiting for VM to power off... ($(($i+1)*10)s)"
                    }
                    if (-not $isOff) { throw "VM failed to shut down gracefully." }
                    Write-Output "VM successfully powered OFF. Allowing 10 seconds for locks to release..."
                    Start-Sleep -Seconds 10
                }
                else {
                    Write-Output "Initiating crash-consistent live snapshot (Note: Windows will register this as dirty on restore)..."
                }
            }

            New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
            Write-Output "SUCCESS: Created snapshot '$snapName'"

            # If we powered it off for Offline Graceful mode, power it back on now
            if ($wasOn -and $consistencyMode -eq "3") {
                Write-Output "Powering VM back ON..."
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON -ErrorAction Stop | Out-Null
            }
        }
        "2" { # DELETE
            $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
            if (-not $snap) { throw "Snapshot '$snapName' not found." }
            Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
            Write-Output "SUCCESS: Deleted snapshot '$snapName'"
        }
        "3" { # RESTORE
            $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
            if (-not $snap) { throw "Snapshot '$snapName' not found." }

            # If VM is currently ON, shut it down gracefully before restoring
            if ($vm.powerState -eq "ON") {
                Write-Output "Initiating graceful shutdown of active VM before restore..."
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                
                # Verification loop: Poll power status every 10s for up to 5 minutes
                $isOff = $false
                for($i=0; $i -lt 30; $i++) {
                    Start-Sleep -Seconds 10
                    $checkVm = Get-NTNXVM -Vmid $vm.uuid
                    if ($checkVm.powerState -eq "OFF") { $isOff = $true; break }
                    Write-Output "Waiting for graceful shutdown... ($(($i+1)*10)s)"
                }
                if (-not $isOff) { throw "VM failed to shut down gracefully." }
            }
            
            # MANDATORY DELAY: Allow hypervisor to release disk locks
            Write-Output "Waiting 60 seconds before initiating restore to allow disk lock release..."
            Start-Sleep -Seconds 60
            
            Write-Output "Restoring virtual machine to snapshot '$snapName'..."
            Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
            
            Write-Output "Powering VM back ON..."
            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON -ErrorAction Stop | Out-Null
            Write-Output "SUCCESS: Restore completed successfully."
        }
    }
} catch {
    Write-Error "CRITICAL FAILURE: $($_.Exception.Message)"
    exit 1
} finally {
    Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
}
