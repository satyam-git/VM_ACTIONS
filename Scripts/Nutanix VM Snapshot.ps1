param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Helper: Load Nutanix Cmdlets
function Initialize-Nutanix {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin
    }
}

# Mapping sites to Prism Element IPs (extend as needed)
$siteMap = @{
    "Bangalore" = "192.168.136.50"
}

$site = $data.s1
$vmName = $data.v1
$op = $data.op # 1=Create, 2=Delete, 3=Restore
$snapName = $data.sn1

# Setup Logging
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\snapshot_log.csv"
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }

try {
    Initialize-Nutanix
    $creds = ConvertTo-SecureString $env:PE_PASS -AsPlainText -Force
    Connect-NTNXCluster -Server $siteMap[$site] -UserName $env:PE_USER -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

    $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
    if (-not $vm) { throw "VM '$vmName' not found." }

    $status = "Failed"

    switch ($op) {
        "1" { # CREATE
            $spec = New-NTNXObject -Name SnapshotSpecDTO
            $spec.vmUuid = $vm.uuid
            $spec.snapshotName = $snapName
            New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
            $status = "Snapshot '$snapName' Created"
        }
        "2" { # DELETE
            $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
            Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
            $status = "Snapshot '$snapName' Deleted"
        }
        "3" { # RESTORE
            $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
            # Shutdown and Restore logic
            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 30
            # Use Restore-NTNXVirtualMachine for VM-level snapshots
            Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON -ErrorAction Stop | Out-Null
            $status = "Snapshot '$snapName' Restored and VM Powered On"
        }
    }
    "$site,$vmName,$snapName,$status" | Out-File -FilePath $logPath -Append -Encoding utf8
} catch {
    "$site,$vmName,$snapName,ERROR: $($_.Exception.Message)" | Out-File -FilePath $logPath -Append -Encoding utf8
} finally {
    Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
}
