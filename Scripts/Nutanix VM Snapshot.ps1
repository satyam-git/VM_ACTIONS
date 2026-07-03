param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

function Initialize-Nutanix {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
    }
}

$siteMap = @{ "Bangalore" = "192.168.136.50"; "Pune" = "10.0.0.20"; "Chennai" = "10.0.0.10" }
$siteName = $data.s1
$vmNames = $data.v1.Split(',').Trim()
$delays = $data.d1.Split(',').Trim()
$op = $data.op # 1=Create, 2=Delete, 3=Restore
$snapName = $data.sn1

try {
    Initialize-Nutanix
    $creds = ConvertTo-SecureString $env:PE_PASS -AsPlainText -Force
    Connect-NTNXCluster -Server $siteMap[$siteName] -UserName $env:PE_USER -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        $vmName = $vmNames[$i]
        $delay = if ($delays[$i]) { [int]$delays[$i] } else { 0 }
        
        Write-Output "--- Processing: $vmName | Pre-delay: $delay s ---"
        Start-Sleep -Seconds $delay

        $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
        if (-not $vm) { throw "VM '$vmName' not found." }

        switch ($op) {
            "1" { # CREATE
                $spec = New-NTNXObject -Name SnapshotSpecDTO
                $spec.vmUuid = $vm.uuid
                $spec.snapshotName = $snapName
                New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
                Write-Output "SUCCESS: Created snapshot '$snapName' for $vmName"
            }
            "2" { # DELETE
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { throw "Snapshot '$snapName' not found." }
                Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Output "SUCCESS: Deleted snapshot '$snapName' for $vmName"
            }
            "3" { # RESTORE
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { throw "Snapshot '$snapName' not found." }

                # Shutdown Logic with Retries
                if ($vm.powerState -eq "ON") {
                    $shutdownSuccess = $false
                    for ($retry = 1; $retry -le 2; $retry++) {
                        Write-Output "Attempt $retry: Triggering ACPI_SHUTDOWN..."
                        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                        Start-Sleep -Seconds 30
                        if ((Get-NTNXVM -Vmid $vm.uuid).powerState -eq "OFF") { $shutdownSuccess = $true; break }
                    }
                    if (-not $shutdownSuccess) { throw "VM $vmName failed to shut down." }
                }
                
                Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
                Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
                Write-Output "SUCCESS: Restore completed for $vmName"
            }
        }
    }
} catch {
    Write-Error "CRITICAL FAILURE: $($_.Exception.Message)"
    exit 1
} finally {
    Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
}
