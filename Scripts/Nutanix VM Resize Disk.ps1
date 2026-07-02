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

    # --- Enable TLS 1.2 and bypass self-signed certificate validation ---
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

    $pair = "$($env:PE_USERNAME):$($env:PE_PASSWORD)"
    $encodedCredentials = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    $headers = @{
        Authorization = "Basic $encodedCredentials"
        "Content-Type" = "application/json"
    }

    try {
        # ==========================================
        # 1. NUTANIX CLUSTER DISK CONFIGURATION via REST API
        # ==========================================
        # Find VM UUID
        Write-Host "Connecting to Prism Element REST API at https://$($current_pe_ip):9440..."
        $vmUrl = "https://$($current_pe_ip):9440/api/nutanix/v2.0/vms?filter=vm_name==$current_vmname"
        $vmResult = Invoke-RestMethod -Uri $vmUrl -Method Get -Headers $headers
        if (-not $vmResult -or -not $vmResult.entities -or $vmResult.entities.Count -eq 0) {
            throw "VM Not Found: VM '$current_vmname' was not found on the Nutanix cluster."
        }
        $vmObj = $vmResult.entities[0]
        $vmUuid = $vmObj.uuid

        $task = $null

        if ($current_disk_action -eq "add") {
            # Find Best Storage Container
            $containerUrl = "https://$($current_pe_ip):9440/api/nutanix/v2.0/containers"
            $containerResult = Invoke-RestMethod -Uri $containerUrl -Method Get -Headers $headers
            
            $clusterUrl = "https://$($current_pe_ip):9440/api/nutanix/v2.0/cluster"
            $clusterDetails = Invoke-RestMethod -Uri $clusterUrl -Method Get -Headers $headers
            $Prefix = $clusterDetails.name.Substring(0,[math]::Min(3,$clusterDetails.name.Length))

            $BestContainer = $containerResult.entities |
            Where-Object {
                $n = $_.name
                $n -like ("$Prefix" + "*") -and $n -notmatch "NutanixManagementShare|NutaniXFitInstance|default-container"
            } |
            Select-Object *,@{
                Name="FreePct"
                Expression={
                    $Cap=[double]$_.usage_stats.'storage.capacity_bytes'
                    $Use=[double]$_.usage_stats.'storage.usage_bytes'
                    if($Cap -gt 0){ (($Cap-$Use)/$Cap)*100 } else {0}
                }
            } |
            Sort-Object FreePct -Descending |
            Select-Object -First 1

            $ContainerName = $BestContainer.name
            Write-Host "Selected Storage Container: $ContainerName (Free: $([math]::Round($BestContainer.FreePct, 2))%)"

            $diskSizeBytes = [double]$current_SizeGB * 1024 * 1024 * 1024
            $body = @{
                vm_disk_create = @{
                    container_name = $ContainerName
                    size_bytes = $diskSizeBytes
                }
            } | ConvertTo-Json -Depth 5

            $attachUrl = "https://$($current_pe_ip):9440/api/nutanix/v2.0/vms/$vmUuid/disks/attach"
            Write-Host "Dispatching disk attach POST request..."
            $task = Invoke-RestMethod -Uri $attachUrl -Method Post -Headers $headers -Body $body
        }
        else {
            $diskSizeBytes = [double]$current_SizeGB * 1024 * 1024 * 1024
            
            # Parse DiskAddr, e.g., "scsi.1" -> bus: "scsi", index: 1
            $addrParts = $current_DiskAddr.Split('.')
            $deviceBus = $addrParts[0].ToLower()
            $deviceIndex = [int]$addrParts[1]

            $body = @{
                disk_list = @(
                    @{
                        disk_address = @{
                            device_bus = $deviceBus
                            device_index = $deviceIndex
                        }
                        vm_disk_update = @{
                            disk_size_bytes = $diskSizeBytes
                        }
                    }
                )
            } | ConvertTo-Json -Depth 5

            $updateUrl = "https://$($current_pe_ip):9440/api/nutanix/v2.0/vms/$vmUuid"
            Write-Host "Dispatching disk update/resize PUT request..."
            $task = Invoke-RestMethod -Uri $updateUrl -Method Put -Headers $headers -Body $body
        }

        if (-not $task -or -not $task.task_uuid) {
            throw "Failed to trigger Nutanix disk action. No task was returned from Prism Element."
        }

        $taskUuid = $task.task_uuid
        Write-Host "Nutanix REST Task Created: $taskUuid. Polling for completion..."

        $taskUrl = "https://$($current_pe_ip):9440/api/nutanix/v2.0/tasks/$taskUuid"
        $taskStatus = "Queued"
        $timeout = 120
        $elapsed = 0
        while ($taskStatus -ne "Succeeded" -and $taskStatus -ne "Failed" -and $elapsed -lt $timeout) {
            Start-Sleep -Seconds 2
            $elapsed += 2
            $taskResult = Invoke-RestMethod -Uri $taskUrl -Method Get -Headers $headers
            $taskStatus = $taskResult.progress_status
            Write-Host "Polling task $taskUuid... status: $taskStatus"
        }

        if ($taskStatus -ne "Succeeded") {
            throw "Nutanix REST disk action task failed or timed out. Status: $taskStatus"
        }
        Write-Host "Nutanix cluster-side disk operation complete: Succeeded."

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
                $Disk = $null
                $maxAttempts = 6
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    Write-Host "Scanning for newly hot-plugged RAW or Offline disk (Attempt $attempt of $maxAttempts)..."
                    
                    try {
                        Update-StorageProviderCache -DiscoveryLevel Full -ErrorAction SilentlyContinue
                    } catch {}
                    
                    "rescan" | diskpart | Out-Null
                    Start-Sleep -Seconds 5
                    
                    $Disk = Get-Disk | Where-Object {
                        $_.PartitionStyle -eq "RAW" -or $_.OperationalStatus -eq "Offline" -or $_.PartitionStyle -eq "None" -or $_.PartitionStyle -eq "Unknown"
                    } | Sort-Object Number | Select-Object -First 1
                    
                    if ($Disk) {
                        Write-Host "Found target disk: Number $($Disk.Number), Size $($Disk.Size), OperationalStatus $($Disk.OperationalStatus), PartitionStyle $($Disk.PartitionStyle)"
                        break
                    }
                }

                if (-not $Disk) { 
                    Write-Host "All current disks on the Guest OS:"
                    Get-Disk | ForEach-Object {
                        Write-Host "Disk #$($_.Number): Size=$($_.Size), OpStatus=$($_.OperationalStatus), Style=$($_.PartitionStyle)"
                    }
                    throw "No RAW or Offline disk found. Please ensure the new virtual drive is recognized." 
                }

                if ($Disk.OperationalStatus -eq "Offline") {
                    # Bring the disk online first, then ensure read-write status in separate calls to avoid parameter set conflicts
                    Set-Disk -Number $Disk.Number -IsOffline $false -ErrorAction SilentlyContinue
                    Set-Disk -Number $Disk.Number -IsReadOnly $false -ErrorAction SilentlyContinue
                }

                Initialize-Disk -Number $Disk.Number -PartitionStyle GPT
                $Partition = New-Partition -DiskNumber $Disk.Number -DriveLetter $DriveLetter -UseMaximumSize
                Format-Volume -Partition $Partition -FileSystem NTFS -Confirm:$false -Force
                
                Write-Host "Successfully initialized RAW Disk \$($Disk.Number) and mapped to Drive ${DriveLetter}:"
            }
            else {
                $Partition = Get-Partition -DriveLetter $DriveLetter
                if (-not $Partition) {
                    throw "Drive letter ${DriveLetter}: was not found on the guest OS. Cannot extend."
                }

                # CRITICAL OS FIX: Force Windows to clear size caching and read new limits
                Update-Disk -Number $Partition.DiskNumber -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3

                # Refresh partition info after Update-Disk
                $Partition = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber

                # Query the expanded physical disk bounds
                $SupportedSize = Get-PartitionSupportedSize `
                    -DiskNumber $Partition.DiskNumber `
                    -PartitionNumber $Partition.PartitionNumber

                # Only resize if the new maximum size is larger than the current partition size by at least 1MB
                $SizeDifference = $SupportedSize.SizeMax - $Partition.Size
                if ($SizeDifference -ge 1MB) {
                    # Extend partition to maximum size
                    Resize-Partition `
                        -DiskNumber $Partition.DiskNumber `
                        -PartitionNumber $Partition.PartitionNumber `
                        -Size $SupportedSize.SizeMax

                    Write-Host "Successfully expanded Drive ${DriveLetter}: to maximum size of \$([math]::Round($SupportedSize.SizeMax / 1GB, 2)) GB"
                }
                else {
                    Write-Host "Drive ${DriveLetter}: is already at the maximum possible size of \$([math]::Round($Partition.Size / 1GB, 2)) GB (difference is less than 1MB). Skipping resize."
                }
            }

        } -ArgumentList $current_disk_action, $current_DriveLetter

    }
    finally {
        # Stateless REST API does not require session disconnection.
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
        $errMessage = $_.Exception.Message
        $statusVal = "failed"
        if ($errMessage -like "*VM Not Found*" -or $errMessage -like "*Unknown name:*") {
            $statusVal = "VM Not Found"
        } elseif ($errMessage -like "*not found*" -and ($errMessage -like "*VM*" -or $errMessage -like "*VirtualMachine*" -or $errMessage -like "*$current_vmname*")) {
            $statusVal = "VM Not Found"
        } elseif ($errMessage -like "*NotFound*" -and ($errMessage -like "*VM*" -or $errMessage -like "*VirtualMachine*" -or $errMessage -like "*$current_vmname*")) {
            $statusVal = "VM Not Found"
        } elseif ($errMessage -like "*does not exist*" -and ($errMessage -like "*VM*" -or $errMessage -like "*VirtualMachine*" -or $errMessage -like "*$current_vmname*")) {
            $statusVal = "VM Not Found"
        }
        
        if ($statusVal -eq "VM Not Found") {
            Write-Warning "[VM $current_vmname] Not Found: $errMessage"
        } else {
            Write-Error "[VM $current_vmname] Failed with error: $errMessage"
            $AnyFailed = $true
        }
        
        $ExecutionResults += [PSCustomObject]@{
            "Site Name" = $current_site_name
            "VMName"    = $current_vmname
            "Action"    = $current_disk_action
            "Size"      = $current_SizeGB
            "Status"    = $statusVal
        }
    }
}

Write-Host "`n=============================================================="
Write-Host "                DISK PROVISIONING SUMMARY REPORT              "
Write-Host "=============================================================="
$ExecutionResults | Format-Table -AutoSize
Write-Host "=============================================================="

# --- Generate GitHub Actions Step Summary ---
if ($env:GITHUB_STEP_SUMMARY) {
    $md = @()
    $md += "### Nutanix Disk Provisioning Summary"
    $md += ""
    $md += "| Site Name | VMName | Action | Size | Status |"
    $md += "| :--- | :--- | :--- | :---: | :--- |"
    foreach ($res in $ExecutionResults) {
        $site = $res."Site Name"
        $vm = $res."VMName"
        $act = $res."Action"
        $sz = $res."Size"
        $stat = $res."Status"
        $statusFormatted = if ($stat -eq "successful") { ":green_circle: Successful" } elseif ($stat -eq "VM Not Found") { ":yellow_circle: VM Not Found" } else { ":red_circle: Failed" }
        $md += "| $site | $vm | $act | $sz GB | $statusFormatted |"
    }
    $md | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if ($AnyFailed) {
    throw "One or more VM disk provisioning tasks failed."
} else {
    Write-Host "`nCompleted all operations successfully."
}
