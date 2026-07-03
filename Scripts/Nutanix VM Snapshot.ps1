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

# Split comma-separated inputs and trim outer whitespaces
$vmNames = $vmInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
$snapNames = $snapInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

if ($vmNames.Count -eq 0) {
    Write-Error "No VM names provided."
    exit 1
}

try {
    Initialize-Nutanix
    $creds = ConvertTo-SecureString $env:PE_PASS -AsPlainText -Force
    Connect-NTNXCluster -Server $siteMap[$siteName] -UserName $env:PE_USER -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        $vmName = $vmNames[$i]
        
        # Determine the corresponding snapshot name sequentially. Fallback if index out of bounds.
        if ($i -lt $snapNames.Count) {
            $snapName = $snapNames[$i]
        } else {
            $snapName = "$vmName-snapshot"
        }

        Write-Output "--------------------------------------------------"
        Write-Output "Processing VM: '$vmName' with Snapshot: '$snapName'"
        Write-Output "--------------------------------------------------"

        $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
        if (-not $vm) {
            Write-Warning "VM '$vmName' not found. Skipping to next VM."
            continue
        }

        switch ($op) {
            "1" { # CREATE
                $spec = New-NTNXObject -Name SnapshotSpecDTO
                $spec.vmUuid = $vm.uuid
                $spec.snapshotName = $snapName
                New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
                Write-Output "SUCCESS: Created snapshot '$snapName' on VM '$vmName'"
            }
            "2" { # DELETE
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { 
                    Write-Warning "Snapshot '$snapName' not found on VM '$vmName'."
                    continue
                }
                Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Output "SUCCESS: Deleted snapshot '$snapName' on VM '$vmName'"
            }
            "3" { # RESTORE
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) {
                    Write-Warning "Snapshot '$snapName' not found on VM '$vmName'."
                    continue
                }

                if ($vm.powerState -eq "ON") {
                    Write-Output "Initiating ACPI graceful shutdown for VM '$vmName'..."
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                    
                    # Verification loop: Poll power status every 10s for up to 5 minutes
                    $isOff = $false
                    for($j=0; $j -lt 30; $j++) {
                        Start-Sleep -Seconds 10
                        $checkVm = Get-NTNXVM -Vmid $vm.uuid
                        if ($checkVm.powerState -eq "OFF") { $isOff = $true; break }
                        Write-Output "Waiting for graceful shutdown... ($(($j+1)*10)s)"
                    }
                    if (-not $isOff) { throw "VM '$vmName' failed to shut down gracefully." }
                }
                
                # MANDATORY DELAY: Allow hypervisor to release disk locks
                Write-Output "Waiting 60 seconds before initiating restore to prevent SCSI reservation lock conflicts..."
                Start-Sleep -Seconds 60
                
                Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Output "Reverted block-storage states cleanly to snapshot '$snapName'."
                
                Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
                Write-Output "SUCCESS: Restore completed and powered ON VM '$vmName'"
            }
        }
    }
} catch {
    Write-Error "CRITICAL FAILURE: $($_.Exception.Message)"
    exit 1
} finally {
    Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
}
