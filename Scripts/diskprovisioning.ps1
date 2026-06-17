# Requires:
# Install-Module Posh-SSH -Scope CurrentUser -Force

Import-Module Posh-SSH -ErrorAction Stop

function Invoke-NutanixAcli {
    param(
        [Parameter(Mandatory)] [string] $ClusterIp,
        [Parameter(Mandatory)] [string] $Username,
        [Parameter(Mandatory)] [string] $Password,
        [Parameter(Mandatory)] [string] $Command
    )

    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = [pscredential]::new($Username, $securePassword)

    $session = $null

    try {
        $session = New-SSHSession `
            -ComputerName $ClusterIp `
            -Credential $credential `
            -AcceptKey `
            -ErrorAction Stop

        $result = Invoke-SSHCommand `
            -SessionId $session.SessionId `
            -Command $Command `
            -ErrorAction Stop

        if ($result.ExitStatus -ne 0) {
            throw "ACLI failed with exit code $($result.ExitStatus): $($result.Error -join "`n")"
        }

        return $result.Output
    }
    finally {
        if ($session) {
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
        }
    }
}

# ==============================================================================
# PASS 1: STORAGE PROVISIONING
# ==============================================================================
foreach ($row in $MasterRows) {
    Write-Host "`n--- [PASS 1: STORAGE] VM: $($row.vmname) ---" -ForegroundColor Yellow

    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop | Out-Null
    }

    $pePassword = ConvertTo-SecureString $row.PE_password -AsPlainText -Force

    try {
        Connect-NTNXCluster `
            -Server $row.cluster_ip `
            -UserName $row.PE_Username `
            -Password $pePassword `
            -AcceptInvalidSSLCerts `
            -ErrorAction Stop | Out-Null

        $clusterDetails = Get-NTNXCluster -ErrorAction Stop

        if ($row.Disk_Action -in @("add", "extend")) {
            $containerName = $null

            if ($row.Disk_Action -eq "add") {
                $prefix = $clusterDetails.name.Substring(0, [math]::Min(3, $clusterDetails.name.Length))

                $bestContainer = Get-NTNXContainer |
                    Where-Object {
                        $name = if ($_.name) { $_.name } else { $_.containerName }

                        $name -like "$prefix*" -and
                        $name -notmatch "NutanixManagementShare|NutaniXFitInstance|default-container"
                    } |
                    Select-Object *,
                        @{
                            Name = "FreePct"
                            Expression = {
                                $capacity = [double]$_.usageStats.'storage.capacity_bytes'
                                $used = [double]$_.usageStats.'storage.usage_bytes'

                                if ($capacity -gt 0) {
                                    (($capacity - $used) / $capacity) * 100
                                }
                                else {
                                    0
                                }
                            }
                        } |
                    Sort-Object FreePct -Descending |
                    Select-Object -First 1

                if (-not $bestContainer) {
                    throw "No suitable Nutanix container found for VM $($row.vmname)."
                }

                $containerName = if ($bestContainer.name) { $bestContainer.name } else { $bestContainer.containerName }

                $acliCommand = "acli vm.disk_create `"$($row.vmname)`" container=`"$containerName`" create_size=$($row.SizeGB)G"
            }
            else {
                if (-not $row.DiskAddr) {
                    throw "DiskAddr is required when Disk_Action is 'extend' for VM $($row.vmname)."
                }

                $acliCommand = "acli vm.disk_update `"$($row.vmname)`" disk_addr=`"$($row.DiskAddr)`" new_size=$($row.SizeGB)G"
            }

            Write-Host "Running ACLI: $acliCommand"

            Invoke-NutanixAcli `
                -ClusterIp $row.cluster_ip `
                -Username $row.PE_Username `
                -Password $row.PE_password `
                -Command $acliCommand | Out-Host

            $guestPassword = ConvertTo-SecureString $row.Guest_Password -AsPlainText -Force
            $guestCredential = [pscredential]::new($row.Guest_Username, $guestPassword)

            Invoke-Command `
                -ComputerName $row.GuestIP `
                -Credential $guestCredential `
                -ErrorAction Stop `
                -ScriptBlock {
                    param($Action, $Drive)

                    Start-Sleep -Seconds 10

                    if ($Action -eq "add") {
                        Update-HostStorageCache

                        $disk = Get-Disk |
                            Where-Object {
                                $_.PartitionStyle -eq "RAW" -or $_.OperationalStatus -eq "Offline"
                            } |
                            Sort-Object Number |
                            Select-Object -First 1

                        if (-not $disk) {
                            throw "No RAW or offline disk found."
                        }

                        if ($disk.IsOffline) {
                            Set-Disk -Number $disk.Number -IsOffline $false
                        }

                        if ($disk.IsReadOnly) {
                            Set-Disk -Number $disk.Number -IsReadOnly $false
                        }

                        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop

                        New-Partition `
                            -DiskNumber $disk.Number `
                            -DriveLetter $Drive `
                            -UseMaximumSize |
                            Format-Volume -FileSystem NTFS -Confirm:$false -Force
                    }
                    else {
                        Update-HostStorageCache

                        $partition = Get-Partition -DriveLetter $Drive -ErrorAction Stop
                        $supportedSize = Get-PartitionSupportedSize -DriveLetter $Drive -ErrorAction Stop

                        Resize-Partition `
                            -DriveLetter $Drive `
                            -Size $supportedSize.SizeMax `
                            -ErrorAction Stop
                    }
                } `
                -ArgumentList $row.Disk_Action, $row.DriveLetter
        }
    }
    finally {
        Disconnect-NTNXCluster -Servers $row.cluster_ip -ErrorAction SilentlyContinue | Out-Null
    }
}
