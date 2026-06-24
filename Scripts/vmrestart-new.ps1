param($JsonInputs)

# 1. Validate Input
if ([string]::IsNullOrWhiteSpace($JsonInputs)) { Write-Error "No JSON inputs received"; exit 1 }
$data = $JsonInputs | ConvertFrom-Json

$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_execution_log.csv"
$tempDir = Join-Path $env:GITHUB_WORKSPACE "data\temp_logs"

# 2. Setup Environment
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

$taskBlock = {
    param($site, $vmNames, $action, $delays, $user, $tempLogPath, $siteMap)
    
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin }
    
    try {
        # Securely load password as a plain string for the older -Password parameter
        $key = Get-Content "C:\Scripts\key.txt" -ErrorAction Stop
        # pragma: ignore:PSAvoidUsingConvertToSecureStringWithKey
        $secPass = Get-Content "C:\Scripts\nutanix_creds.txt" -ErrorAction Stop | ConvertTo-SecureString -Key $key
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
        $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        
        Connect-NTNXCluster -Server $siteMap[$site] -UserName $user -Password $plainPass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        
        $vmArray = $vmNames.Split(',').Trim()
        $delayArray = if ($delays) { $delays.Split(',').Trim() } else { @() }
        
        for ($i = 0; $i -lt $vmArray.Count; $i++) {
            $vmName = $vmArray[$i]
            $vmDelay = if ($i -lt $delayArray.Count) { [int]$delayArray[$i] } else { 0 }
            if ($vmDelay -gt 0) { Start-Sleep -Seconds ($vmDelay * 60) }
            
            $vm = Get-NTNXVM | Where-Object { $_.vmName -ieq $vmName } | Select-Object -First 1
            $status = if ($null -eq $vm) { "VM Not Found" } else { 
                if ($action -eq "start") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON }
                elseif ($action -eq "stop") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN }
                elseif ($action -eq "restart") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT }
                "successful"
            }
            "$site,$vmName,$action,$status" | Out-File -FilePath $tempLogPath -Append -Encoding utf8
        }
    } catch { "$site,$vmNames,Error,$($_.Exception.Message)" | Out-File -FilePath $tempLogPath -Append }
    finally { Disconnect-NTNXCluster -Servers $siteMap[$site] -ErrorAction SilentlyContinue }
}

# 3. Launch Jobs
$siteMap = @{ "Banglore" = "192.168.136.50"; "Chennai" = "10.0.0.10" }

for ($i = 1; $i -le 3; $i++) {
    $v = $data.$("v$i"); $s = $data.$("s$i"); $a = $data.$("a$i"); $d = $data.$("d$i")
    if (-not [string]::IsNullOrWhiteSpace($v) -and $s -ne "None") {
        $jobLog = Join-Path $tempDir "job_$i.csv"
        Start-Job -ScriptBlock $taskBlock -ArgumentList $s, $v, $a, $d, $env:NUTANIX_USER, $jobLog, $siteMap
    }
}

Get-Job | Wait-Job | Receive-Job

if (Test-Path $tempDir) {
    Get-ChildItem "$tempDir\*.csv" | Get-Content | Out-File -FilePath $logPath -Encoding utf8
    Remove-Item $tempDir -Recurse -Force
}
