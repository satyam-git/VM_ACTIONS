param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

function Initialize-Nutanix {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin
    }
}

$siteMap = @{ "Bangalore" = "192.168.136.50"; "Pune" = "x.x.x.x"; "Chennai" = "x.x.x.x" }
$site = $data.s1
$vmName = $data.v1
$op = $data.op # 1=Create, 2=Delete, 3=Restore
$snapName = $data.sn1

try {
    Initialize-Nutanix
    $creds = ConvertTo-SecureString $env:PE_PASS -AsPlainText -Force
    Connect-NTNXCluster -Server $siteMap[$site] -UserName $env:PE_USER -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

    $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
    if (-not $vm) { throw "VM '$vmName' not found." }

    switch ($op) {
        "1" { # CREATE
            $spec = New-NTNXObject -Name SnapshotSpecDTO
            $spec.vmUuid = $vm.uuid
            $spec.snapshotName = $snapName
            New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
            Write-Host "SUCCESS: Created snapshot '$snapName'"
        }
        "2" { # DELETE
            $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
            if (-not $snap) { throw "Snapshot '$snapName' not found." }
            Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
            Write-Host "SUCCESS: Deleted snapshot '$snapName'"
        }
        "3" { # RESTORE (Graceful Shutdown Logic)
            $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
            if (-not $snap) { throw "Snapshot '$snapName' not found." }

            if ($vm.powerState -eq "on") {
                Write-Host "Initiating graceful shutdown..."
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                
                # Graceful wait loop (Check status for up to 3 minutes)
                $timeout = 180
                $elapsed = 0
                while ($elapsed -lt $timeout) {
                    Start-Sleep -Seconds 10
                    $elapsed += 10
                    $currentVm = Get-NTNXVM -Vmid $vm.uuid
                    if ($currentVm.powerState -eq "off") {
                        Write-Host "VM shut down gracefully."
                        break
                    }
                    Write-Host "Waiting for shutdown... ($elapsed seconds elapsed)"
                }
                
                if ($currentVm.powerState -eq "on") {
                    throw "VM failed to shut down gracefully within $timeout seconds. Manual intervention required."
                }
            }
            
            # Perform Restore
            Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
            
            Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
            Write-Host "SUCCESS: Restore completed"
        }
    }
} catch {
    Write-Error "CRITICAL FAILURE: $($_.Exception.Message)"
    exit 1
} finally {
    Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
}
