param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_execution_log.csv"
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# ---------- Site to Cluster IP mapping ----------
$siteMap = @{
    "Bangalore" = "192.168.136.50"
    "Banglore"  = "192.168.136.50"   # alias for backward compatibility
    "Chennai"   = "10.0.0.10"
    # Add more if needed
}

# ---------- Helper: expand delays to match VM count ----------
function Expand-Delays {
    param(
        [string[]]$vmList,
        [string]$delayInput
    )
    $vmCount = $vmList.Count
    if ($vmCount -eq 0) { return @() }

    # Parse delays, treat empty as '0'
    $delays = if ([string]::IsNullOrWhiteSpace($delayInput)) {
        @(0)
    } else {
        $delayInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
    }

    # If no delays, default to 0 for all
    if ($delays.Count -eq 0) {
        return @(0) * $vmCount
    }
    # If only one delay given, replicate it to all VMs
    if ($delays.Count -eq 1) {
        return @($delays[0]) * $vmCount
    }
    # More delays than VMs → truncate
    if ($delays.Count -gt $vmCount) {
        return $delays[0..($vmCount-1)]
    }
    # Fewer delays but >1 → pad with the last value
    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) {
        if ($i -lt $delays.Count) { $result += $delays[$i] }
        else { $result += $delays[-1] }
    }
    return $result
}

# ---------- Build global schedule ----------
$startTime = Get-Date
$schedule = @()

for ($i = 1; $i -le 3; $i++) {
    $site = $data.$("s$i")
    if (-not $site -or $site -eq "None") { continue }

    $vmNamesRaw = $data.$("v$i")
    if ([string]::IsNullOrWhiteSpace($vmNamesRaw)) { continue }
    $vmList = $vmNamesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $action = $data.$("a$i")
    if ([string]::IsNullOrWhiteSpace($action)) { $action = "start" }

    $delayInput = $data.$("d$i")
    $delays = Expand-Delays -vmList $vmList -delayInput $delayInput

    for ($j = 0; $j -lt $vmList.Count; $j++) {
        $dueTime = $startTime.AddMinutes([int]$delays[$j])
        $schedule += [PSCustomObject]@{
            Site      = $site
            VMName    = $vmList[$j]
            Action    = $action
            Delay     = $delays[$j]
            DueTime   = $dueTime
            Processed = $false
        }
    }
}

# ---------- Print schedule for debugging ----------
Write-Host "`n===== Schedule ====="
$schedule | ForEach-Object {
    Write-Host "$($_.VMName) (site $($_.Site)) : delay $($_.Delay) min, due at $($_.DueTime.ToString('HH:mm:ss'))"
}
Write-Host "Start time: $($startTime.ToString('HH:mm:ss'))`n"

# ---------- Process VMs in order of due time ----------
$schedule = $schedule | Sort-Object DueTime

# ---------- Helper function to perform action on a single VM ----------
function Invoke-VMAction {
    param(
        $site,
        $vmName,
        $action,
        $logPath,
        $siteMap
    )

    $ip = $siteMap[$site]
    if (-not $ip) {
        Write-Host "[$vmName] ERROR: Site '$site' not found in mapping."
        "$site,$vmName,$action,ERROR: Site not in mapping" | Out-File -FilePath $logPath -Append -Encoding utf8
        return
    }

    # Load Nutanix snapin
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin
    }

    $Status = "failed"
    try {
        # Use PE_USER and PE_PASS as defined in your workflow YML
        $securePass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
        Connect-NTNXCluster -Server $ip -UserName $env:PE_USER -Password $securePass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

        $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName }
        if (-not $vm) {
            $Status = "VM Not Found"
        } else {
            switch ($action) {
                "start" {
                    if ($vm.powerState -eq "on") { $Status = "already on - skipped" }
                    else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON; $Status = "successful" }
                }
                "stop" {
                    if ($vm.powerState -eq "off") { $Status = "already off - skipped" }
                    else {
                        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN
                        Start-Sleep -Seconds 45
                        if ((Get-NTNXVM -Vmid $vm.uuid).powerState -eq "on") {
                            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN
                        }
                        $Status = "successful"
                    }
                }
                "restart" {
                    if ($vm.powerState -eq "off") { $Status = "VM is off, cannot restart" }
                    else {
                        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT
                        Start-Sleep -Seconds 45
                        if ((Get-NTNXVM -Vmid $vm.uuid).powerState -ne "on") {
                            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT
                        }
                        $Status = "successful"
                    }
                }
                default { $Status = "unknown action" }
            }
        }
    } catch {
        $Status = "failed - $($_.Exception.Message.Split(':')[0])"
    } finally {
        Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue
    }

    "$site,$vmName,$action,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host "[$vmName] $Status"
}

# ---------- Execute schedule ----------
foreach ($item in $schedule) {
    $now = Get-Date
    if ($item.DueTime -gt $now) {
        $waitSeconds = ($item.DueTime - $now).TotalSeconds
        if ($waitSeconds -gt 0) {
            Write-Host "Waiting $([math]::Round($waitSeconds, 1)) seconds for $($item.VMName) (delay $($item.Delay) min)..."
            Start-Sleep -Seconds $waitSeconds
        }
    }

    Write-Host "`n----- Processing VM: $($item.VMName) (site $($item.Site), action $($item.Action)) -----"
    Invoke-VMAction -site $item.Site -vmName $item.VMName -action $item.Action -logPath $logPath -siteMap $siteMap
    $item.Processed = $true
}

Write-Host "`n===== All VMs processed successfully ====="
