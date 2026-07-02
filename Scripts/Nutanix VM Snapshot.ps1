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
            New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
            Write-Output "SUCCESS: Created snapshot '$snapName'"
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

            if ($vm.powerState -eq "ON") {
                Write-Output "Initiating graceful shutdown..."
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
            Write-Output "Waiting 30 seconds before initiating restore..."
            Start-Sleep -Seconds 30
            
            Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
            
            Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
            Write-Output "SUCCESS: Restore completed"
        }
    }
} catch {
    Write-Error "CRITICAL FAILURE: $($_.Exception.Message)"
    exit 1
} finally {
    Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
}
