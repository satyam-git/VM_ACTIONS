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

    $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }

    switch ($op) {
        "1" { # CREATE
            $spec = New-NTNXObject -Name SnapshotSpecDTO
            $spec.vmUuid = $vm.uuid
            $spec.snapshotName = $snapName
            New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
            Write-Host "SUCCESS: Created snapshot '$snapName'"
        }
        "2" { # DELETE
            if (-not $snap) { throw "Snapshot '$snapName' not found." }
            Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
            Write-Host "SUCCESS: Deleted snapshot '$snapName'"
        }
        "3" { # RESTORE (Clone Method)
            if (-not $snap) { throw "Snapshot '$snapName' not found." }
            
            # Shutdown
            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 45
            
            # Remove old VM and Clone from Snapshot
            Remove-NTNXVM -Vmid $vm.uuid -ErrorAction Stop | Out-Null
            
            $cloneSpec = New-NTNXObject -Name VmCloneSpecDTO
            $cloneSpec.snapshotUuid = $snap.uuid
            $cloneSpec.vmName = $vmName
            New-NTNXVM -VmCloneSpec $cloneSpec -ErrorAction Stop | Out-Null
            
            $newVm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
            Set-NTNXVMPowerOn -Vmid $newVm.uuid -ErrorAction Stop | Out-Null
            Write-Host "SUCCESS: Restore completed"
        }
    }
} catch {
    Write-Error "CRITICAL FAILURE: $($_.Exception.Message)"
    exit 1
} finally {
    Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
}
