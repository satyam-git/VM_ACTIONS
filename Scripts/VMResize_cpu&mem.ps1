param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Helper functions: Convert-ToInteger and Expand-Values (same as your original)
function Convert-ToInteger {
    param([string]$value)
    try { return [int][math]::Round([double]$value) } catch { throw "Invalid number: '$value'" }
}

function Expand-Values {
    param([string[]]$vmList, [string]$inputValue, [string]$valueName)
    $vmCount = $vmList.Count
    if ($vmCount -eq 0) { return @() }
    $values = if ([string]::IsNullOrWhiteSpace($inputValue)) { @() } else { $inputValue -split ',' | ForEach-Object { Convert-ToInteger -value $_.Trim() } }
    
    if ($values.Count -eq 0) {
        if ($valueName -eq "Delay") { return @(0) * $vmCount }
        else { throw "No $valueName provided." }
    }
    if ($values.Count -eq 1) { return @($values[0]) * $vmCount }
    
    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) { $result += if ($i -lt $values.Count) { $values[$i] } else { $values[-1] } }
    return $result
}

# --- Setup ---
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\resize_log.csv"
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

$siteMap = @{ "Bangalore" = "192.168.136.50"; "Chennai" = "10.0.0.10"; "Pune" = "10.0.0.20" }
$resizeJob = { ... } # (Keep your existing job logic inside this block)

# --- Process 3 Sets ---
$taskConfigs = @(
    @{ site = $data.s1; vms = $data.v1; cpu = $data.c1; mem = $data.m1; delay = $data.d1 },
    @{ site = $data.s2; vms = $data.v2; cpu = $data.c2; mem = $data.m2; delay = $data.d2 },
    @{ site = $data.s3; vms = $data.v3; cpu = $data.c3; mem = $data.m3; delay = $data.d3 }
)

$allJobs = @()
foreach ($config in $taskConfigs) {
    if ([string]::IsNullOrWhiteSpace($config.site) -or $config.site -eq "None" -or [string]::IsNullOrWhiteSpace($config.vms)) { continue }

    $vmNames = ($config.vms -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $cpus = Expand-Values -vmList $vmNames -inputValue $config.cpu -valueName "CPU"
    $mems = Expand-Values -vmList $vmNames -inputValue $config.mem -valueName "Memory"
    $delays = Expand-Values -vmList $vmNames -inputValue $config.delay -valueName "Delay"

    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        $allJobs += Start-Job -ScriptBlock $resizeJob -ArgumentList $config.site, $vmNames[$i], $delays[$i], $cpus[$i], $mems[$i], $env:PE_USER, $env:PE_PASS, $siteMap, $logPath
    }
}

# --- Finalize ---
$allJobs | Wait-Job | Out-Null
$allJobs | ForEach-Object { Receive-Job $_; Remove-Job $_ }
Write-Host "`nAll jobs finished."
