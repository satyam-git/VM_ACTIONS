[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string]$PrismIP,
    [Parameter(Mandatory=$true)] [string]$Username,
    [Parameter(Mandatory=$true)] [string]$Password,
    [Parameter(Mandatory=$true)] [string]$VMName,
    [Parameter(Mandatory=$true)] [ValidateSet("1","2","3")] [string]$Operation,
    [Parameter(Mandatory=$true)] [string]$SnapshotName
)

$ErrorActionPreference = "Stop"

try {
    # Ensure module is loaded
    if (!(Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin
    }

    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    Connect-NTNXCluster -Server $PrismIP -UserName $Username -Password $securePassword -AcceptInvalidSSLCerts | Out-Null

    $vm = Get-NTNXVM -SearchString $VMName | Where-Object { $_.vmName -eq $VMName }
    if (-not $vm) { throw "VM '$VMName' not found." }
    $vm = $vm[0]

    switch ($Operation) {
        "1" { # CREATE
            $spec = New-NTNXObject -Name SnapshotSpecDTO
            $spec.vmUuid = $vm.uuid
            $spec.snapshotName = $SnapshotName
            New-NTNXSnapshot -SnapshotSpecs $spec | Out-Null
            Write-Host "SUCCESS: Created snapshot '$SnapshotName'"
        }
        "2" { # DELETE
            $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $SnapshotName }
            if (-not $snap) { throw "Snapshot '$SnapshotName' not found." }
            Remove-NTNXSnapshot -Uuid $snap.uuid | Out-Null
            Write-Host "SUCCESS: Deleted snapshot '$SnapshotName'"
        }
        "3" { # RESTORE (Using Cmdlets only)
            $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $SnapshotName }
            if (-not $snap) { throw "Snapshot '$SnapshotName' not found." }

            if ($vm.powerState -eq "on") {
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 45
            }

            # Most compatible restore cmdlet across versions
            Write-Host "Restoring using Restore-NTNXVM..."
            Restore-NTNXVM -Vmid $vm.uuid -SnapshotUuid $snap.uuid 
            
            Set-NTNXVMPowerOn -Vmid $vm.uuid
            Write-Host "SUCCESS: Restore completed."
        }
    }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
}
