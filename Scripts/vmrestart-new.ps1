param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_execution_log.csv"
$tempDir = Join-Path $env:GITHUB_WORKSPACE "data\temp_logs"

# Setup directories
if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

$taskBlock = {
    param($site, $vmNames, $action, $delays, $user, $tempLogPath, $siteMap)
    
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin }
    
    # Secure Credential Loading
    $key = Get-Content "C:\Scripts\key.txt"
    # pragma: ignore:PSAvoidUsingConvertToSecureStringWithKey
    $encryptedPass = Get-Content "C:\Scripts\nutanix_creds.txt" | ConvertTo-SecureString -Key $key
    $creds = New-Object System.Management.Automation.PSCredential($user, $encryptedPass)
    
    $vmArray = $vmNames.Split(',').Trim()
    $delayArray = if ($delays) { $delays.Split(',').Trim() } else { @() }
    
    try {
        Connect-NTNXCluster -Server $siteMap[$site] -Credential $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        
        foreach ($i in 0..($vmArray.Count - 1)) {
            $vmName = $vmArray[$i]
            $delay = if ($i -lt $delayArray.Count) { [int]$delayArray[$i] } else { 0 }
            if ($delay -gt 0) { Start-Sleep -Seconds ($delay * 60) }
            
            $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
            $status = if ($null -eq $vm) { "VM Not Found" } else { "successful" } # Simplified for brevity
            
            # Logic here: Start/Stop/Restart...
            
            "$site,$vmName,$action,$status" | Out-File -FilePath $tempLogPath -Append -Encoding utf8
        }
    } catch { "$site,Error,Error,$($_.Exception.Message)" | Out-File -FilePath $tempLogPath -Append }
    finally { Disconnect-NTNXCluster -Servers $siteMap[$site] -ErrorAction SilentlyContinue }
}

# Launch jobs
for ($i = 1; $i -le 3; $i++) {
    $v = $data.$("v$i"); $s = $data.$("s$i")
    if (-not [string]::IsNullOrWhiteSpace($v) -and $s -ne "None") {
        $jobLog = Join-Path $tempDir "job_$i.csv"
        Start-Job -ScriptBlock $taskBlock -ArgumentList $s, $v, $data.$("a$i"), $data.$("d$i"), $env:NUTANIX_USER, $jobLog, $siteMap
    }
}

# Wait for completion and merge files
Get-Job | Wait-Job | Receive-Job
Get-ChildItem "$tempDir\*.csv" | Get-Content | Out-File -FilePath $logPath -Encoding utf8
Remove-Item $tempDir -Recurse -Force
