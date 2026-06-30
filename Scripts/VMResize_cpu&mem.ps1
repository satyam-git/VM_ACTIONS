param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# ---------- Helper: Convert to Integer ----------
function Convert-ToInteger {
    param([string]$value)
    try {
        $num = [double]$value
        return [int][math]::Round($num)
    } catch { throw "Invalid number: '$value'." }
}

# ---------- Helper: Expand Values ----------
function Expand-Values {
    param([string[]]$vmList, [string]$inputValue, [string]$valueName)
    $vmCount = $vmList.Count
    if ($vmCount -eq 0) { return @() }
    $values = if ([string]::IsNullOrWhiteSpace($inputValue)) { @() } else { $inputValue -split ',' | ForEach-Object { Convert-ToInteger -value $_.Trim() } }
    if ($values.Count -eq 0 -and $valueName -eq "Delay") { return @(0) * $vmCount }
    if ($values.Count -eq 0) { throw "No $valueName values provided." }
    if ($values.Count -eq 1) { return @($values[0]) * $vmCount }
    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) { $result += if ($i -lt $values.Count) { $values[$i] } else { $values[-1] } }
    return $result
}

# ---------- Initialization ----------
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\resize_log.csv"
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }

# Initialize CSV with Headers (Enclosed in quotes to fix parser error)
"SiteName,VMName,CurrentCPU,CurrentMemGB,NewCPU,NewMemGB,Status" | Out-File -FilePath $logPath -Encoding utf8

$siteMap = @{ "Bangalore" = "192.168.136.50"; "Chennai" = "10.0.0.10"; "Pune" = "10.0.0.20" }
$vmNames = ($data.v1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
$cpus = Expand-Values -vmList $vmNames -inputValue $data.c1 -valueName "CPU"
$mems = Expand-Values -vmList $vmNames -inputValue $data.m1 -valueName "Memory"
$delays = Expand-Values -vmList $vmNames -inputValue $data.d1 -valueName "Delay"

# ---------- Resize Job Definition ----------
$resizeJob = {
    param($site, $vmName, $delayMin, $cpu, $memGB, $user, $pass, $siteMap, $logPath)
    $ip = $siteMap[$site]
    if ($delayMin -gt 0) { Start-Sleep -Seconds ($delayMin * 60) }
    
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin }
    
    $securePass = $pass | ConvertTo-SecureString -AsPlainText -Force
    $Status = "failed"
    try {
        Connect-NTNXCluster -Server $ip -UserName $user -Password $securePass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName }
        if ($vm) {
            $CurCPU = [int]$vm.numVcpus; $CurMem = [int]($vm.memoryMb / 1024)
            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 40
            Set-NTNXVirtualMachine -Vmid $vm.uuid -NumVcpus $cpu -MemoryMb ($memGB * 1024) -ErrorAction Stop | Out-Null
            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON -ErrorAction Stop | Out-Null
            $Status = "successful"
            "$site,$vmName,$CurCPU,$CurMem,$cpu,$memGB,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
        }
    } catch { "$site,$vmName,N/A,N/A,$cpu,$memGB,failed" | Out-File -FilePath $logPath -Append -Encoding utf8 }
    finally { Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue }
}

# ---------- Execution ----------
$jobs = @()
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $jobs += Start-Job -ScriptBlock $resizeJob -ArgumentList $data.s1, $vmNames[$i], $delays[$i], $cpus[$i], $mems[$i], $env:PE_USER, $env:PE_PASS, $siteMap, $logPath
}

$jobs | Wait-Job | Out-Null
$jobs | ForEach-Object { Receive-Job $_; Remove-Job $_ }

# ---------- Safe Table Summary Print ----------
Write-Host "`n| Site | VM Name | Current CPU | Current Mem | New CPU | New Mem | Status |"
Write-Host "|------|---------|-------------|-------------|---------|---------|--------|"
Import-Csv -Path $logPath | ForEach-Object {
    Write-Host "| $($_.SiteName) | $($_.VMName) | $($_.CurrentCPU) | $($_.CurrentMemGB) | $($_.NewCPU) | $($_.NewMemGB) | $($_.Status) |"
}
