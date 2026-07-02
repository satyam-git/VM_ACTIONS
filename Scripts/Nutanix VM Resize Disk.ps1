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

    # Connect to Nutanix Cluster
    Write-Host "[$current_vmname] Connecting to Prism Element at $current_pe_ip..."
    
    # Auto-load Nutanix Cmdlets
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
    }
    
    # Establish Connection
    $ClusterConnection = Connect-NTNXCluster -Servers $current_pe_ip -UserName $env:PE_USERNAME -Password $env:PE_PASSWORD -ErrorAction Stop
    Write-Host "[$current_vmname] Connected successfully to Nutanix Prism Element."

    try {
        # Check if Virtual Machine exists
        Write-Host "[$current_vmname] Verifying VM existence..."
        $vm = Get-NTNXVM -Name $current_vmname -ErrorAction SilentlyContinue
        if (-not $vm) {
            throw "Virtual Machine '$current_vmname' not found in cluster."
        }

        # Query Storage Containers to pick the one with most space
        Write-Host "[$current_vmname] Probing cluster storage containers..."
        $Containers = Get-NTNXContainer
        $BestContainer = $Containers | Where-Object { $_.name -notmatch "default|container-system|template" } | 
            Sort-Object -Property @{Expression={$_.freeCapacityBytes}; Descending=$true} | Select-Object -First 1

        if (-not $BestContainer) {
            $BestContainer = $Containers | Select-Object -First 1
        }
        Write-Host "[$current_vmname] Selected optimal storage container: $($BestContainer.name) with $($BestContainer.freeCapacityBytes / 1GB) GB free."

        # Handle Action
        if ($current_disk_action -eq "add") {
            Write-Host "[$current_vmname] Creating new virtual disk of size $current_SizeGB GB on container '$($BestContainer.name)'..."
            $Task = New-NTNXVMDisk -Vmid $vm.uuid -ContainerName $BestContainer.name -SizeInBytes ($current_SizeGB * 1GB) -ErrorAction Stop
            Write-Host "[$current_vmname] Disk creation initiated. Task ID: $($Task.taskUuid)"
        }
        else {
            Write-Host "[$current_vmname] Extending disk at SCSI address '$current_DiskAddr' to new size $current_SizeGB GB..."
            $Disk = $vm.diskList | Where-Object { $_.diskAddress -eq $current_DiskAddr }
            if (-not $Disk) {
                throw "Target disk address '$current_DiskAddr' not found on VM '$current_vmname'."
            }
            $Task = Set-NTNXVMDisk -Vmid $vm.uuid -DiskAddress $current_DiskAddr -SizeInBytes ($current_SizeGB * 1GB) -ErrorAction Stop
            Write-Host "[$current_vmname] Disk expansion task initiated. Task ID: $($Task.taskUuid)"
        }

        # Wait for Nutanix Task Completion
        Write-Host "[$current_vmname] Waiting for Nutanix task to complete..."
        Start-Sleep -Seconds 15

        # --- Guest OS Configuration (via WinRM / Posh-SSH) ---
        Write-Host "[$current_vmname] Dispatching configuration to Windows Guest OS at $current_GuestIP..."
        
        $SecPassword = ConvertTo-SecureString $env:LOCAL_PASSWORD -AsPlainText -Force
        $Credential = New-Object System.Management.Automation.PSCredential($env:LOCAL_USERNAME, $SecPassword)

        # Establish remote PowerShell WinRM Session or SSH session
        $Session = New-SSHSession -ComputerName $current_GuestIP -Credential $Credential -AcceptKey -ErrorAction Stop

        # PowerShell Block to execute in Guest OS
        $GuestScript = {
            param($action, $drive)
            Write-Output "Running remote disk manager scan..."
            
            # Rescan Storage
            "rescan" | diskpart | Out-Null
            Start-Sleep -Seconds 5

            if ($action -eq "add") {
                # Fetch raw disks (offline or RAW)
                $rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -or $_.OperationalStatus -eq "Offline" }
                if (-not $rawDisks) {
                    Write-Error "No uninitialized RAW or Offline disks found in Guest OS."
                    exit 1
                }
                
                $targetDisk = $rawDisks | Sort-Object -Property Number | Select-Object -First 1
                Write-Output "Found RAW disk: Index $($targetDisk.Number)"

                # Initialize, Partition and Format
                Initialize-Disk -Number $targetDisk.Number -PartitionStyle GPT -ErrorAction Stop
                $partition = New-Partition -DiskNumber $targetDisk.Number -UseMaximumSize -DriveLetter $drive -ErrorAction Stop
                Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "New_Volume" -Confirm:$false -ErrorAction Stop
                Write-Output "Successfully formatted and mapped disk to $drive`:"
            }
            else {
                # Extend Partition
                Write-Output "Locating partition for Drive $drive`:"
                $partition = Get-Partition -DriveLetter $drive -ErrorAction SilentlyContinue
                if (-not $partition) {
                    Write-Error "Could not locate partition for Drive $drive`:"
                    exit 1
                }
                
                $maxSize = (Get-PartitionSupportedSize -DriveLetter $drive).SizeMax
                Resize-Partition -DriveLetter $drive -Size $maxSize -ErrorAction Stop
                Write-Output "Successfully extended Drive $drive`: partition to maximum supported size ($($maxSize / 1GB) GB)"
            }
        }

        $Result = Invoke-SSHCommand -SessionId $Session.SessionId -Command "powershell -Command { $GuestScript }" -ArgumentList $current_disk_action, $current_DriveLetter

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

# --- Parse Comma-Separated Multi-Valued Inputs Safely as Arrays ---
$SiteNames = if ([string]::IsNullOrWhiteSpace($site_name)) { @() } else { @($site_name.Split(',').ForEach({ $_.Trim() })) }
$VMNames = if ([string]::IsNullOrWhiteSpace($vmname)) { @() } else { @($vmname.Split(',').ForEach({ $_.Trim() })) }
$DiskActions = if ([string]::IsNullOrWhiteSpace($disk_action)) { @() } else { @($disk_action.Split(',').ForEach({ $_.Trim() })) }
$Sizes = if ([string]::IsNullOrWhiteSpace($SizeGB)) { @() } else { @($SizeGB.Split(',').ForEach({ $_.Trim() })) }
$DiskAddrs = if ([string]::IsNullOrWhiteSpace($DiskAddr)) { @() } else { @($DiskAddr.Split(',').ForEach({ $_.Trim() })) }
$GuestIPs = if ([string]::IsNullOrWhiteSpace($GuestIP)) { @() } else { @($GuestIP.Split(',').ForEach({ $_.Trim() })) }
$DriveLetters = if ([string]::IsNullOrWhiteSpace($DriveLetter)) { @() } else { @($DriveLetter.Split(',').ForEach({ $_.Trim() })) }

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
    }
    catch {
        Write-Error "[VM $current_vmname] Failed with error: $($_.Exception.Message)"
        throw $_
    }
}

Write-Host "`nCompleted all operations successfully."
