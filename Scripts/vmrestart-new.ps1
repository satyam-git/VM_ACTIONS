param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_execution_log.csv"

# Site Mapping
$siteMap = @{ "Banglore" = "192.168.136.50"; "Chennai" = "10.0.0.10" }

# Ensure log environment exists
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# The Task Block (runs inside each Job)
$taskBlock = {
    param($site, $vmNames, $action, $delays, $user, $pass, $logPath, $siteMap)
    
    # 1. Load Modules (Required because Jobs run in a new process)
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { 
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue 
    }
    
    # 2. Parse arrays for multiple VMs and Delays
    $vmArray = $vmNames.Split(',').Trim()
    $delayArray = if ($delays) { $delays.Split(',').Trim() } else { @() }
    
    $ip = $siteMap[$site]
    $creds = $pass | ConvertTo-SecureString -AsPlainText -Force
    
    try {
        Connect-NTNXCluster -Server $ip -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        
        for ($i = 0; $i -lt $vmArray.Count; $i++) {
            $vmName = $vmArray[$i]
            $vmDelay = if ($i -lt $delayArray.Count) { [int]$delayArray[$i] } else { 0 }
            
            # Apply individual delay
            if ($vmDelay -gt 0) { Start-Sleep -Seconds ($vmDelay * 60) }
            
            $vm = Get-NTNXVM | Where-Object { $_.vmName -ieq $vmName } | Select-Object -First 1
            if ($null -eq $vm) { 
                "$site,$vmName,$action,VM Not Found" | Out-File -FilePath $logPath -Append -Encoding utf8
                continue 
            }
            
            $Status = "failed"
            switch ($action) {
                "start" { 
                    if ($vm.powerState -eq "on") { $Status = "already on" } 
                    else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON; $Status = "successful" }
                }
                "stop" { 
                    if ($vm.powerState -eq "off") { $Status = "already off" } 
                    else {
                        # Strike 1
                        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN
                        Start-Sleep -Seconds 40
                        # Validation & Strike 2
                        $current = Get-NTNXVM -Vmid $vm.uuid
                        if ($current.powerState -eq "on") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN }
                        $Status = "successful"
                    }
                }
                "restart" { 
                    if ($vm.powerState -eq "off") { $Status = "it is off" } 
                    else {
                        # Strike 1
                        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT
                        Start-Sleep -Seconds 40
                        # Validation & Strike 2
                        $current = Get-NTNXVM -Vmid $vm.uuid
                        if ($current.powerState -ne "on") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT }
                        $Status = "successful"
                    }
                }
            }
            "$site,$vmName,$action,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
        }
    } catch { 
        "$site,Batch,Error,$($_.Exception.Message)" | Out-File -FilePath $logPath -Append -Encoding utf8
    } finally { 
        Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue 
    }
}

# Run tasks in parallel for Set 1, 2, and 3
for ($i = 1; $i -le 3; $i++) {
    $v = $data.$("v$i")
    $s = $data.$("s$i")
    $a = $data.$("a$i")
    $d = $data.$("d$i")
    
    if (-not [string]::IsNullOrWhiteSpace($v) -and $s -ne "None") {
        Start-Job -ScriptBlock $taskBlock -ArgumentList $s, $v, $a, $d, $env:NUTANIX_USER, $env:NUTANIX_PASS, $logPath, $siteMap
    }
}

Get-Job | Wait-Job | Receive-Job
