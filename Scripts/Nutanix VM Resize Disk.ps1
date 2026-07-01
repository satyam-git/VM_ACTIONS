param(
    # Set 1 Inputs
    [Parameter(Mandatory = $true)]
    [string]$pe_ip,

    [Parameter(Mandatory = $true)]
    [string]$vmname,

    [Parameter(Mandatory = $true)]
    [ValidateSet("add","extend")]
    [string]$disk_action,

    [Parameter(Mandatory = $true)]
    [string]$SizeGB,

    [Parameter(Mandatory = $false)]
    [ValidateSet("none","scsi.0","scsi.1","scsi.2","scsi.3","scsi.4")]
    [string]$DiskAddr = "none",

    [Parameter(Mandatory = $true)]
    [string]$GuestIP,

    [Parameter(Mandatory = $true)]
    [string]$DriveLetter,

    # Set 2 Inputs (Optional)
    [Parameter(Mandatory = $false)]
    [string]$pe_ip2 = "",

    [Parameter(Mandatory = $false)]
    [string]$vmname2 = "",

    [Parameter(Mandatory = $false)]
    [string]$disk_action2 = "add",

    [Parameter(Mandatory = $false)]
    [string]$SizeGB2 = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet("none","scsi.0","scsi.1","scsi.2","scsi.3","scsi.4")]
    [string]$DiskAddr2 = "none",

    [Parameter(Mandatory = $false)]
    [string]$GuestIP2 = "",

    [Parameter(Mandatory = $false)]
    [string]$DriveLetter2 = ""
)

$ErrorActionPreference = "Stop"

Write-Host "====================================="
Write-Host "Nutanix Disk Provisioning Started"
Write-Host "====================================="

Import-Module Posh-SSH -ErrorAction Stop

# --- Environmental & Parameter Sanity Checks ---
if ([string]::IsNullOrWhiteSpace($env:PE_USERNAME)) { throw "PE_USERNAME secret not found" }
if ([string]::IsNullOrWhiteSpace($env:PE_PASSWORD)) { throw "PE_PASSWORD secret not found" }
if ([string]::IsNullOrWhiteSpace($env:LOCAL_USERNAME)) { throw "LOCAL_USERNAME secret not found" }
if ([string]::IsNullOrWhiteSpace($env:LOCAL_PASSWORD)) { throw "LOCAL_PASSWORD secret not found" }

# Helper function to execute the main provisioning logic
function Invoke-DiskProvisioning {
    param(
        [string]$current_pe_ip,
        [string]$current_vmname,
        [string]$current_disk_action,
        [string]$current_SizeGB,
        [string]$current_DiskAddr,
        [string]$current_GuestIP,
        [string]$current_DriveLetter
    )

    Write-Host "--------------------------------------------------------"
    Write-Host "Running provisioning for $current_vmname on $current_pe_ip..."
    Write-Host "--------------------------------------------------------"

    if ($current_disk_action -eq "extend" -and $current_DiskAddr -eq "none") {
        throw "DiskAddr is mandatory when disk_action=extend"
    }

    # --- Dynamic TrustedHosts Registration ---
    try {
        Write-Host "Configuring WinRM TrustedHosts for target guest: $current_GuestIP..."
        if (Test-Path "WSMan:\localhost\Client\TrustedHosts") {
            $CurrentTrusted = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
            if ($CurrentTrusted -ne "*" -and $CurrentTrusted -notlike "*$current_GuestIP*") {
                if ([string]::IsNullOrWhiteSpace($CurrentTrusted)) {
                    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $current_GuestIP -Force -Confirm:$false | Out-Null
                } else {
                    Set-Item WSMan:\localhost\Client\TrustedHosts -Value ("$CurrentTrusted," + $current_GuestIP) -Force -Confirm:$false | Out-Null
                }
            }
        }
    } catch {
        Write-Warning "Failed to set TrustedHosts in script. Ensure runner shell is elevated, or configure it in the YAML step."
    }

    $SecurePassword = ConvertTo-SecureString $env:PE_PASSWORD -AsPlainText -Force
    $Credential = New-Object PSCredential ($env:PE_USERNAME,$SecurePassword)

    $Session = New-SSHSession -ComputerName $current_pe_ip -Credential $Credential -AcceptKey -Force

    try {
        # ==========================================
        # 1. NUTANIX CLUSTER DISK CONFIGURATION
        # ==========================================
        if ($current_disk_action -eq "add") {
            if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
                Add-PSSnapin NutanixCmdletsPSSnapin
            }

            Connect-NTNXCluster -Server $current_pe_ip -UserName $env:PE_USERNAME -Password $SecurePassword -AcceptInvalidSSLCerts | Out-Null

            $ClusterDetails = Get-NTNXCluster
            $Prefix = $ClusterDetails.name.Substring(0,[math]::Min(3,$ClusterDetails.name.Length))

            $BestContainer = Get-NTNXContainer |
            Where-Object {
                $n = if ($_.name) { $_.name } else { $_.containerName }
                $n -like ("$Prefix" + "*") -and $n -notmatch "NutanixManagementShare|NutaniXFitInstance|default-container"
            } |
            Select-Object *,@{
                Name="FreePct"
                Expression={
                    $Cap=[double]$_.usageStats.'storage.capacity_bytes'
                    $Use=[double]$_.usageStats.'storage.usage_bytes'
                    if($Cap -gt 0){ (($Cap-$Use)/$Cap)*100 } else {0}
                }
            } |
            Sort-Object FreePct -Descending |
            Select-Object -First 1

            $ContainerName = if ($BestContainer.name) { $BestContainer.name } else { $BestContainer.containerName }

            $AcliCommand = "acli vm.disk_create '$current_vmname' container='$ContainerName' create_size='" + $current_SizeGB + "G'"
        }
        else {
            $AcliCommand = "acli vm.disk_update '$current_vmname' disk_addr='$current_DiskAddr' new_size='" + $current_SizeGB + "G'"
        }

        $Result = Invoke-SSHCommand -SessionId $Session.SessionId -Command $AcliCommand
        Write-Host "Nutanix ACLI Output: $($Result.Output)"

        # Error handling for raw ACLI failures
        if ($Result.Output -like "*Error:*") {
            throw "Nutanix ACLI operation failed: $($Result.Output)"
        }

        # ==========================================
        # 2. WINDOWS GUEST AUTOMATION (OS LAYER)
        # ==========================================
        $GuestSecurePassword = ConvertTo-SecureString $env:LOCAL_PASSWORD -AsPlainText -Force
        $GuestCredential = New-Object System.Management.Automation.PSCredential($env:LOCAL_USERNAME,$GuestSecurePassword)

        Write-Host "Waiting 20 seconds for Nutanix disk hotplug/resize action to commit on Guest OS..."
        Start-Sleep -Seconds 20

        Invoke-Command -ComputerName $current_GuestIP -Credential $GuestCredential -ScriptBlock {
            param($Action, $DriveLetter)

            # Force dynamic disk and storage layer re-discovery
            try {
                Update-StorageProviderCache -DiscoveryLevel Full -ErrorAction SilentlyContinue
            } catch {}
            
            "rescan" | diskpart | Out-Null
            Start-Sleep -Seconds 5

            if ($Action -eq "add") {
                # Retrieve the newly hot-plugged raw or offline disk
                $Disk = Get-Disk | Where-Object {
                    $_.PartitionStyle -eq "RAW" -or $_.OperationalStatus -eq "Offline"
                } | Sort-Object Number | Select-Object -First 1

                if (-not $Disk) { 
                    throw "No RAW or Offline disk found. Please ensure the new virtual drive is recognized." 
                }

                if ($Disk.OperationalStatus -eq "Offline") {
                    Set-Disk -Number $Disk.Number -IsOffline $false
                }

                Initialize-Disk -Number $Disk.Number -PartitionStyle GPT
                $Partition = New-Partition -DiskNumber $Disk.Number -DriveLetter $DriveLetter -UseMaximumSize
                Format-Volume -Partition $Partition -FileSystem NTFS -Confirm:$false -Force
                
                Write-Host "Successfully initialized RAW Disk \$($Disk.Number) and mapped to Drive " + $DriveLetter + ":"
            }
            else {
                $Partition = Get-Partition -DriveLetter $DriveLetter
                if (-not $Partition) {
                    throw "Drive letter " + $DriveLetter + ": was not found on the guest OS. Cannot extend."
                }

                # CRITICAL OS FIX: Force Windows to clear size caching and read new limits
                Update-Disk -Number $Partition.DiskNumber -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3

                # Query the expanded physical disk bounds
                $SupportedSize = Get-PartitionSupportedSize `
                    -DiskNumber $Partition.DiskNumber `
                    -PartitionNumber $Partition.PartitionNumber

                # Extend partition to maximum size
                Resize-Partition `
                    -DiskNumber $Partition.DiskNumber `
                    -PartitionNumber $Partition.PartitionNumber `
                    -Size $SupportedSize.SizeMax

                Write-Host "Successfully expanded Drive " + $DriveLetter + ": to maximum size of \$([math]::Round($SupportedSize.SizeMax / 1GB, 2)) GB"
            }

        } -ArgumentList $current_disk_action, $current_DriveLetter

    }
    finally {
        if (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue) {
            Disconnect-NTNXCluster -Servers $current_pe_ip -ErrorAction SilentlyContinue | Out-Null
        }

        if ($Session) {
            Remove-SSHSession -SessionId $Session.SessionId | Out-Null
        }
    }
}

# Execute Set 1
Invoke-DiskProvisioning `
    -current_pe_ip $pe_ip `
    -current_vmname $vmname `
    -current_disk_action $disk_action `
    -current_SizeGB $SizeGB `
    -current_DiskAddr $DiskAddr `
    -current_GuestIP $GuestIP `
    -current_DriveLetter $DriveLetter

# Execute Set 2 (if provided)
if (-not [string]::IsNullOrWhiteSpace($pe_ip2) -and -not [string]::IsNullOrWhiteSpace($vmname2) -and -not [string]::IsNullOrWhiteSpace($GuestIP2)) {
    Write-Host "\`n========================================="
    Write-Host "Starting Set 2 Disk Provisioning"
    Write-Host "========================================="
    Invoke-DiskProvisioning `
        -current_pe_ip $pe_ip2 `
        -current_vmname $vmname2 `
        -current_disk_action $disk_action2 `
        -current_SizeGB $SizeGB2 `
        -current_DiskAddr $DiskAddr2 `
        -current_GuestIP $GuestIP2 `
        -current_DriveLetter $DriveLetter2
}

Write-Host "Completed successfully."
