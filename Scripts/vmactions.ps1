param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_execution_log.csv"

$siteMap = @{
    "Banglore" = "192.168.136.50"
    "Chennai"  = "10.0.0.10"
}

if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

$taskBlock = {
    param($site, $vmName, $action, $delay, $user, $pass, $logPath, $siteMap)
    $ip = $siteMap[$site]
    if (-not $ip) { return }

    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin }
    
    # Initial Delay – now $delay is guaranteed to be an integer
    if ([int]$delay -gt 0) { Start-Sleep -Seconds ([int]$delay * 60) }
    
    # Secure credential construction
    $creds = New-Object System.Security.SecureString
    foreach ($char in $pass.ToCharArray()) { $creds.AppendChar($char) }
    $creds.MakeReadOnly()
    
    $Status = "failed"
    try {
        Connect-NTNXCluster -Server $ip -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName }
        
        if ($null -eq $vm) { 
            $Status = "VM Not Found" 
        } else {
            switch ($action) {
                "start" { 
                    if ($vm.powerState -eq "on") { $Status = "already on-hence skipped" } 
                    else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON; $Status = "successful" }
                }
                "stop" { 
                    if ($vm.powerState -eq "off") { $Status = "already off-hence skipped" } 
                    else {
                        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN
                        Start-Sleep -Seconds 45
                        if ((Get-NTNXVM -Vmid $vm.uuid).powerState -eq "on") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN }
                        $Status = "successful"
                    }
                }
                "restart" { 
                    if ($vm.powerState -eq "off") { $Status = "its on off, please poweron" } 
                    else {
                        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT
                        Start-Sleep -Seconds 45
                        if ((Get-NTNXVM -Vmid $vm.uuid).powerState -ne "on") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT }
                        $Status = "successful"
                    }
                }
            }
        }
    } catch { $Status = "failed - $($_.Exception.Message.Split(':')[0])" }
    finally { Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue }
    
    "$site,$vmName,$action,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
}

# Helper: returns a flat array of delays (integers) matching the number of VMs
function Get-DelaysForVMs {
    param(
        [string[]]$vmList,
        [string]$delayInput
    )
    # Parse comma-separated delays, trim, ignore empty, convert to int
    $delays = $delayInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
    $vmCount = $vmList.Count

    if ($delays.Count -eq 0) {
        # No delay provided → all VMs get 0
        return @(0) * $vmCount
    }
    if ($delays.Count -eq 1) {
        # Single delay → applied to all VMs
        return @($delays[0]) * $vmCount
    }
    # Multiple delays: map one‑to‑one, pad with the last delay
    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) {
        if ($i -lt $delays.Count) {
            $result += $delays[$i]
        } else {
            $result += $delays[-1]
        }
    }
    return $result
}

for ($i = 1; $i -le 3; $i++) {
    $site = $data.$("s$i")
    if ($site -eq "None" -or [string]::IsNullOrWhiteSpace($site)) { continue }

    $vmNamesRaw = $data.$("v$i")
    if ([string]::IsNullOrWhiteSpace($vmNamesRaw)) { continue }
    $vmList = $vmNamesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $action = $data.$("a$i")
    if ([string]::IsNullOrWhiteSpace($action)) { $action = "start" }  # default

    $delayInput = $data.$("d$i")
    if ([string]::IsNullOrWhiteSpace($delayInput)) { $delayInput = "0" }

    $delays = Get-DelaysForVMs -vmList $vmList -delayInput $delayInput

    for ($j = 0; $j -lt $vmList.Count; $j++) {
        Start-Job -ScriptBlock $taskBlock -ArgumentList $site, $vmList[$j], $action, $delays[$j], $env:NUTANIX_USER, $env:NUTANIX_PASS, $logPath, $siteMap
    }
}

Get-Job | Wait-Job | Receive-Job
