param(
    [Parameter(Mandatory = $true)]
    [string]$site_name,

    [Parameter(Mandatory = $true)]
    [string]$vmname,

    [Parameter(Mandatory = $true)]
    [string]$disk_action,

    [Parameter(Mandatory = $true)]
    [string]$SizeGB,

    [Parameter(Mandatory = $false)]
    [string]$DiskAddr = "none",

    [Parameter(Mandatory = $true)]
    [string]$GuestIP,

    [Parameter(Mandatory = $true)]
    [string]$DriveLetter
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
    Write-Host "Running provisioning for $current_vmname on $current_GuestIP (PE IP: $current_pe_ip)..."
    Write-Host "--------------------------------------------------------"

    if ($current_disk_action -eq "extend" -and $current_DiskAddr -eq "none") {
        throw "DiskAddr is mandatory when disk_action=extend"
    }

    if ($current_disk_action -ne "add" -and $current_disk_action -ne "extend") {
        throw "disk_action must be 'add' or 'extend'. Got '$current_disk_action'."
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

            if (-not $BestContainer) {
                throw "No eligible storage container found matching prefix '$Prefix'"
            }

            $ContainerName = if ($BestContainer.name) { $BestContainer.name } else { $BestContainer.containerName }
            Write-Host "Auto-selected highest available container: $ContainerName (Free: $([math]::Round($BestContainer.FreePct,2))%)"

            $AcliCmdAdd = "acli vm.disk_create $current_vmname container=$ContainerName create_size=${current_SizeGB}G"
            Write-Host "Adding raw Nutanix virtual disk on VM: $current_vmname..."
            $SshResult = Invoke-SSHCommand -SessionId $Session.SessionId -Command $AcliCmdAdd
            
            if ($SshResult.ExitStatus -ne 0) {
                throw "Nutanix SSH command failed: $($SshResult.Output)"
            }
            Write-Host "Nutanix Disk creation complete."
        }
        else {
            $AcliCmdResize = "acli vm.disk_update $current_vmname disk_addr=$current_DiskAddr new_size=${current_SizeGB}G"
            Write-Host "Extending virtual disk size to ${current_SizeGB} GB at index $current_DiskAddr..."
            $SshResult = Invoke-SSHCommand -SessionId $Session.SessionId -Command $AcliCmdResize

            if ($SshResult.ExitStatus -ne 0) {
                throw "Nutanix SSH command failed: $($SshResult.Output)"
            }
            Write-Host "Nutanix Disk size extended successfully."
        }

        # ==========================================
        # 2. WINDOWS GUEST OS FILE SYSTEM EXPANSION
        # ==========================================
        Write-Host "Waiting 20 seconds for hotplug / resize event propagation on target OS..."
        Start-Sleep -Seconds 20

        $GuestSecurePass = ConvertTo-SecureString $env:LOCAL_PASSWORD -AsPlainText -Force
        $GuestCred = New-Object PSCredential ($env:LOCAL_USERNAME,$GuestSecurePass)

        Write-Host "Executing Partition Configuration on Windows Remote Guest OS..."
        Invoke-Command -ComputerName $current_GuestIP -Credential $GuestCred -ScriptBlock {
            param($Action, $DriveLetter)

            # Ensure storage layer re-discovers disk boundaries
            "rescan" | diskpart | Out-Null

            if ($Action -eq "add") {
                # Look for Offline or un-initialized disk
                $RawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -or $_.OperationalStatus -eq "Offline" }
                if ($RawDisks.Count -eq 0) {
                    throw "No new RAW or Offline disk discovered on Guest OS. Rescan failed."
                }

                $TargetDisk = $RawDisks[0]
                Write-Host "RAW Disk Discovered - Index: $($TargetDisk.Number), Size: $([math]::Round($TargetDisk.Size / 1GB, 2)) GB"

                if ($TargetDisk.OperationalStatus -eq "Offline") {
                    Set-Disk -Number $TargetDisk.Number -IsOffline $false
                }

                Initialize-Disk -Number $TargetDisk.Number -PartitionStyle GPT -ErrorAction Stop
                $NewPartition = New-Partition -DiskNumber $TargetDisk.Number -UseMaximumSize -DriveLetter $DriveLetter -ErrorAction Stop
                
                # Format NTFS Label
                Format-Volume -Partition $NewPartition -FileSystem NTFS -NewFileSystemLabel "New volume" -Confirm:$false -ErrorAction Stop
                Write-Host "Successfully initialized Disk $($TargetDisk.Number) and formatted to Drive $DriveLetter:"
            }
            else {
                # Extend existing SCSI disk partition
                $Partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
                if (-not $Partition) {
                    throw "Target Drive $DriveLetter: could not be located on Remote Guest OS"
                }

                # Rescan disk layer specifically
                Update-Disk -Number $Partition.DiskNumber

                $SupportedSize = Get-PartitionSupportedSize -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
                Write-Host "Available expansion limits: Max=$([math]::Round($SupportedSize.SizeMax / 1GB, 2)) GB"

                # Extend partition to maximum size
                Resize-Partition `
                    -DiskNumber $Partition.DiskNumber `
                    -PartitionNumber $Partition.PartitionNumber `
                    -Size $SupportedSize.SizeMax

                Write-Host "Successfully expanded Drive " + $DriveLetter + ": to maximum size of $([math]::Round($SupportedSize.SizeMax / 1GB, 2)) GB"
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

# --- Parse Comma-Separated Multi-Valued Inputs ---
function Convert-ToArray {
    param([string]$inputString)
    if ([string]::IsNullOrWhiteSpace($inputString)) {
        return @()
    }
    $parts = $inputString.Split(',')
    $trimmed = @()
    foreach ($p in $parts) {
        $trimmed += $p.Trim()
    }
    return ,$trimmed
}

$SiteNames = Convert-ToArray $site_name
$VMNames = Convert-ToArray $vmname
$DiskActions = Convert-ToArray $disk_action
$Sizes = Convert-ToArray $SizeGB
$DiskAddrs = Convert-ToArray $DiskAddr
$GuestIPs = Convert-ToArray $GuestIP
$DriveLetters = Convert-ToArray $DriveLetter

# --- Code-Defined Site to PE IP mapping dictionary ---
$SiteIPMap = @{
    "Banglore" = "192.168.136.50"
    "Chennai"  = "10.0.0.10"
    "CPune"    = "10.0.0.20"
}

# We determine loop size by the number of VM Names provided
$Count = $VMNames.Count
if ($Count -eq 0) {
    throw "No VM Names provided for provisioning."
}

Write-Host "Detected $Count VM(s) to process based on 'vmname' input."

$ExecutionResults = @()
$AnyFailed = $false

for ($i = 0; $i -lt $Count; $i++) {
    $current_vmname = $VMNames[$i]
    
    # Safe index mappings with fallbacks
    $current_site_name = if ($i -lt $SiteNames.Count) { $SiteNames[$i] } else { $SiteNames[0] }
    $current_disk_action = if ($i -lt $DiskActions.Count) { $DiskActions[$i] } else { $DiskActions[0] }
    $current_SizeGB = if ($i -lt $Sizes.Count) { $Sizes[$i] } else { $Sizes[0] }
    $current_DiskAddr = if ($i -lt $DiskAddrs.Count) { $DiskAddrs[$i] } else { $DiskAddrs[0] }
    $current_GuestIP = if ($i -lt $GuestIPs.Count) { $GuestIPs[$i] } else { $GuestIPs[0] }
    $current_DriveLetter = if ($i -lt $DriveLetters.Count) { $DriveLetters[$i] } else { $DriveLetters[0] }

    # Resolve Prism Element IP address from the code-defined mapping
    $current_pe_ip = $current_site_name
    if ($SiteIPMap.ContainsKey($current_site_name)) {
        $current_pe_ip = $SiteIPMap[$current_site_name]
    }

    Write-Host "`n[VM $current_vmname] Starting execution ($($i + 1) of $Count)"
    try {
        Invoke-DiskProvisioning `
            -current_pe_ip $current_pe_ip `
            -current_vmname $current_vmname `
            -current_disk_action $current_disk_action `
            -current_SizeGB $current_SizeGB `
            -current_DiskAddr $current_DiskAddr `
            -current_GuestIP $current_GuestIP `
            -current_DriveLetter $current_DriveLetter
        
        Write-Host "[VM $current_vmname] Succeeded."
        
        $ExecutionResults += [PSCustomObject]@{
            "Site Name" = $current_site_name
            "VMName"    = $current_vmname
            "Action"    = $current_disk_action
            "Size"      = $current_SizeGB
            "Status"    = "successful"
        }
    }
    catch {
        Write-Error "[VM $current_vmname] Failed with error: $($_.Exception.Message)"
        $AnyFailed = $true
        
        $ExecutionResults += [PSCustomObject]@{
            "Site Name" = $current_site_name
            "VMName"    = $current_vmname
            "Action"    = $current_disk_action
            "Size"      = $current_SizeGB
            "Status"    = "failed"
        }
    }
}

Write-Host "`n=============================================================="
Write-Host "                DISK PROVISIONING SUMMARY REPORT              "
Write-Host "=============================================================="
$ExecutionResults | Format-Table -AutoSize
Write-Host "=============================================================="

if ($AnyFailed) {
    throw "One or more VM disk provisioning tasks failed."
} else {
    Write-Host "`nCompleted all operations successfully."
}
