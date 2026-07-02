param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

function Initialize-Nutanix {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin
    }
}

$siteMap = @{ "Bangalore" = "192.168.136.50" }
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

    $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
    if (-not $snap) { throw "Snapshot '$snapName' not found." }
    
    # Use the base UUID for the restore
    $snapId = $snap.uuid

    switch ($op) {
        "1" { # CREATE
            $spec = New-NTNXObject -Name SnapshotSpecDTO
            $spec.vmUuid = $vm.uuid
            $spec.snapshotName = $snapName
            New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
            Write-Host "SUCCESS: Snapshot '$snapName' Created"
        }
        "2" { # DELETE
            Remove-NTNXSnapshot -Uuid $snapId -ErrorAction Stop | Out-Null
            Write-Host "SUCCESS: Snapshot '$snapName' Deleted"
        }
        "3" { # RESTORE
            Write-Host "Shutting down VM..."
            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 45
            
            # Use Restore-NTNXVM, which is the correct command for VM Snapshots
            # It does not require PdName.
            Write-Host "Restoring VM using Restore-NTNXVM..."
            Restore-NTNXVM -Vmid $vm.uuid -SnapshotUuid $snapId -ErrorAction Stop | Out-Null
            
            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON -ErrorAction Stop | Out-Null
            Write-Host "SUCCESS: Restore completed"
        }
    }
} catch {
    Write-Error "CRITICAL FAILURE: $($_.Exception.Message)"
    exit 1
} finally {
    Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
}
