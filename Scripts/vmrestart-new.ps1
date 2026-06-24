param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_execution_log.csv"

$siteMap = @{ "Banglore" = "192.168.136.50"; "Chennai" = "10.0.0.10" }

if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

$taskBlock = {
    param($site, $vmNames, $action, $delays, $user, $pass, $logPath, $siteMap)
    $ip = $siteMap[$site]
    if (-not $ip) { return }

    # Load module inside the job scope
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin }
    
    $creds = $pass | ConvertTo-SecureString -AsPlainText -Force
    
    # Split input strings into arrays
    $vmArray = $vmNames.Split(',').Trim()
    $delayArray = if ($delays) { $delays.Split(',').Trim() } else { @() }
    
    # Process each VM in the set independently
    for ($i = 0; $i -lt $vmArray.Count; $i++) {
        $vmName = $vmArray[$i]
        $delay = if ($i -lt $delayArray.Count) { [int]$delayArray[$i] } else { 0 }
        
        # 1. Individual Delay
        if ($delay -gt 0) { Start-Sleep -Seconds ($delay * 60) }
        
        $Status = "failed"
        try {
            Connect-NTNXCluster -Server $ip -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
            $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName }
            
            if ($null -eq $vm) { $Status = "VM Not Found" }
            else {
                switch ($action) {
                    "start" { 
                        if ($vm.powerState -eq "on") { $Status = "already on" } 
                        else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON; $Status = "successful" }
                    }
                    "stop" { 
                        if ($vm.powerState -eq "off") { $Status = "already off" } 
                        else {
                            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN
                            Start-Sleep -Seconds 45
                            if ((Get-NTNXVM -Vmid $vm.uuid).powerState -eq "on") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN }
                            $Status = "successful"
                        }
                    }
                    "restart" { 
                        if ($vm.powerState -eq "off") { $Status = "is off" } 
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
}

# Launch jobs for each set (1, 2, 3)
for ($i = 1; $i -le 3; $i++) {
    $v = $data.$("v$i")
    $s = $data.$("s$i")
    if (-not [string]::IsNullOrWhiteSpace($v) -and $s -ne "None") {
        Start-Job -ScriptBlock $taskBlock -ArgumentList $s, $v, $data.$("a$i"), $data.$("d$i"), $env:NUTANIX_USER, $env:NUTANIX_PASS, $logPath, $siteMap
    }
}

Get-Job | Wait-Job | Receive-Job
