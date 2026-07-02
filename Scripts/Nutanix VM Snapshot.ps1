param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Helper: Load Nutanix Cmdlets
function Initialize-Nutanix {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin
    }
}

$siteMap = @{ "Bangalore" = "192.168.136.50" }
$site = $data.s1
$vmName = $data.v1
$op = $data.op 
$snapName = $data.sn1

try {
    Initialize-Nutanix
    $creds = ConvertTo-SecureString $env:PE_PASS -AsPlainText -Force
    Connect-NTNXCluster -Server $siteMap[$site] -UserName $env:PE_USER -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

    $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
    if (-not $vm) { throw "VM '$vmName' not found." }

    # Find the snapshot and dynamically find the correct ID property
    $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
    if (-not $snap) { throw "Snapshot '$snapName' not found." }
    
    # Detect ID property: Check for 'uuid', 'snapshotUuid', or 'id'
    $snapId = $snap.uuid
    if ($null -eq $snapId) { $snapId = $snap.snapshotUuid }
    if ($null -eq $snapId) { $snapId = $snap.id }

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
            
            # Using the detected ID property
            Write-Host "Restoring snapshot using ID: $snapId"
            Restore-NTNXSnapshot -SnapshotId $snapId -ErrorAction Stop | Out-Null
            
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
