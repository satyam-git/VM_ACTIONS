param($JsonInputs)

$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_execution_log.csv"
$tempDir = Join-Path $env:GITHUB_WORKSPACE "data\temp_logs"

if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

$taskBlock = {
    param($site, $vmNames, $action, $delays, $user, $pass, $tempLogPath, $siteMap)
    
    # --- FIX: Load snap-in INSIDE the job to ensure commands are recognized ---
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { 
        Add-PSSnapin NutanixCmdletsPSSnapin 
    }
    
    try {
        # Convert password to SecureString and connect using explicit Username/Password parameters
        $securePass = ConvertTo-SecureString -String $pass -AsPlainText -Force
        Connect-NTNXCluster -Server $siteMap[$site] -UserName $user -Password $securePass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        
        $vmArray = $vmNames.Split(',').Trim()
        
        for ($i = 0; $i -lt $vmArray.Count; $i++) {
            $vmName = $vmArray[$i].Trim()
            
            # Use -ieq for case-insensitive matching
            $vm = Get-NTNXVM | Where-Object { $_.vmName -ieq $vmName } | Select-Object -First 1
            $status = "successful"
            
            if ($null -eq $vm) { $status = "VM Not Found" }
            else {
                $isAlreadyOn = ($vm.powerState -eq "on")
                
                # Perform Action
                switch ($action) {
                    "start"   { if ($isAlreadyOn) { $status = "already on" } else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition "ON" } }
                    "stop"    { if (-not $isAlreadyOn) { $status = "already off" } else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition "ACPI_SHUTDOWN" } }
                    "restart" { if (-not $isAlreadyOn) { $status = "vm is powered off" } else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition "ACPI_REBOOT" } }
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
        # FIX: Pass password directly as argument to avoid credential object issues
        Start-Job -ScriptBlock $taskBlock -ArgumentList $s, $v, $a, $d, $env:NUTANIX_USER, $env:NUTANIX_PASS, $jobLog, $siteMap
    }
}

Get-Job | Wait-Job | Receive-Job

if (Test-Path $tempDir) {
    Get-ChildItem "$tempDir\*.csv" | ForEach-Object { Get-Content $_ | Out-File -FilePath $logPath -Append -Encoding utf8 }
    Remove-Item $tempDir -Recurse -Force
}
