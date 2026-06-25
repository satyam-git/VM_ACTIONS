param($JsonInputs)

$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_execution_log.csv"
$tempDir = Join-Path $env:GITHUB_WORKSPACE "data\temp_logs"

if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

$taskBlock = {
    param($site, $vmNames, $action, $delays, $user, $tempLogPath, $siteMap)
    
    $plainPass = $env:NUTANIX_PASS_JOB
    
    # PowerShell 7 కోసం మాడ్యూల్ ఇంపోర్ట్
    Import-Module Nutanix.Cli -ErrorAction SilentlyContinue
    
    try {
        # Secure implementation (MegaLinter & PS7 compatible)
        $securePassword = ConvertTo-SecureString -String $plainPass -AsPlainText -Force
        $credential = [System.Management.Automation.PSCredential]::new($user, $securePassword)
        
        Connect-NTNXCluster -Server $siteMap[$site] -Credential $credential -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        
        $vmArray = $vmNames.Split(',').Trim()
        
        $isMultiDelay = ($delays -and $delays.Contains(','))
        $delayValues = if ($isMultiDelay) { $delays.Split(',').Trim() } else { $delays }
        
        for ($i = 0; $i -lt $vmArray.Count; $i++) {
            $vmName = $vmArray[$i]
            $vmDelay = if ($isMultiDelay -and ($i -lt $delayValues.Count)) { [int]$delayValues[$i] } elseif ($delays) { [int]$delayValues } else { 0 }
            
            if ($vmDelay -gt 0) { Start-Sleep -Seconds ($vmDelay * 60) }
            
            $vm = Get-NTNXVM | Where-Object { $_.vmName -ieq $vmName } | Select-Object -First 1
            $status = "successful"
            
            if ($null -eq $vm) { $status = "VM Not Found" }
            else {
                $isAlreadyOn = ($vm.powerState -eq "on")
                
                switch ($action) {
                    "start"   { if ($isAlreadyOn) { $status = "already on - hence skipped" } else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition "ON" } }
                    "stop"    { if (-not $isAlreadyOn) { $status = "already off - hence skipped" } else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition "ACPI_SHUTDOWN" } }
                    "restart" { if (-not $isAlreadyOn) { $status = "vm is powered off, please start first" } else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition "ACPI_REBOOT" } }
                }

                if ($status -eq "successful") {
                    Start-Sleep -Seconds 30
                    $currentVM = Get-NTNXVM -Vmid $vm.uuid
                    $isDown = ($currentVM.powerState -eq "off")
                    $isOn = ($currentVM.powerState -eq "on")
                    
                    if (($action -eq "start" -and -not $isOn) -or (($action -eq "stop" -or $action -eq "restart") -and -not $isDown)) {
                        $transition = switch ($action) { "start" { "ON" }; "stop" { "ACPI_SHUTDOWN" }; "restart" { "ACPI_REBOOT" } }
                        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition $transition
                        $status = "Successful"
                    }
                }
            }
            "$site,$vmName,$action,$status" | Out-File -FilePath $tempLogPath -Append -Encoding utf8
        }
    } catch { "$site,$vmNames,Error,$($_.Exception.Message)" | Out-File -FilePath $tempLogPath -Append -Encoding utf8 }
    finally { Disconnect-NTNXCluster -Servers $siteMap[$site] -ErrorAction SilentlyContinue }
}

$siteMap = @{ "Banglore" = "192.168.136.50"; "Chennai" = "10.0.0.10" }

for ($i = 1; $i -le 3; $i++) {
    $v = $data.$("v$i"); $s = $data.$("s$i"); $a = $data.$("a$i"); $d = $data.$("d$i")
    if (-not [string]::IsNullOrWhiteSpace($v) -and $s -ne "None") {
        $jobLog = Join-Path $tempDir "job_$i.csv"
        $env:NUTANIX_PASS_JOB = $env:NUTANIX_PASS
        Start-Job -ScriptBlock $taskBlock -ArgumentList $s, $v, $a, $d, $env:NUTANIX_USER, $jobLog, $siteMap
    }
}

Get-Job | Wait-Job | Receive-Job

if (Test-Path $tempDir) {
    Get-ChildItem "$tempDir\*.csv" | ForEach-Object { Get-Content $_ | Out-File -FilePath $logPath -Append -Encoding utf8 }
    Remove-Item $tempDir -Recurse -Force
}
