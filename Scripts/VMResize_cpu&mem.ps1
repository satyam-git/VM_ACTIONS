param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# ---------- Helper: convert any numeric string to integer (with rounding) ----------
function Convert-ToInteger {
    param([string]$value)
    try {
        $num = [double]$value
        $rounded = [math]::Round($num)
        if ($num -ne $rounded) {
            Write-Warning "Value '$value' is not an integer. It will be rounded to $rounded."
        }
        return [int]$rounded
    } catch {
        throw "Invalid number: '$value'. Please provide an integer (e.g., 2, 4, 8)."
    }
}

# ---------- Helper: expand a single value or a list to match VM count ----------
function Expand-Values {
    param(
        [string[]]$vmList,
        [string]$inputValue,
        [string]$valueName   # e.g., "CPU", "Memory", "Delay"
    )
    $vmCount = $vmList.Count
    if ($vmCount -eq 0) { return @() }

    $values = if ([string]::IsNullOrWhiteSpace($inputValue)) {
        @()
    } else {
        $inputValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object {
            Convert-ToInteger -value $_
        }
    }

    if ($values.Count -eq 0) {
        if ($valueName -eq "Delay") {
            return @(0) * $vmCount
        } else {
            throw "No $valueName values provided. Please specify $valueName for each VM."
        }
    }

    if ($values.Count -eq 1) {
        return @($values[0]) * $vmCount
    }

    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) {
        if ($i -lt $values.Count) { $result += $values[$i] }
        else { $result += $values[-1] }
    }
    return $result
}

# ---------- Parse VM list ----------
$vmNames = ($data.v1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($vmNames.Count -eq 0) {
    throw "No VM names provided."
}

# ---------- Expand CPU, Memory, and Delay ----------
$cpus = Expand-Values -vmList $vmNames -inputValue $data.c1 -valueName "CPU"
$mems = Expand-Values -vmList $vmNames -inputValue $data.m1 -valueName "Memory"
$delays = Expand-Values -vmList $vmNames -inputValue $data.d1 -valueName "Delay"

# ---------- Optional: cap delays ----------
$MAX_DELAY_MINUTES = 60
for ($i = 0; $i -lt $delays.Count; $i++) {
    if ($delays[$i] -gt $MAX_DELAY_MINUTES) {
        Write-Warning "Delay of $($delays[$i]) minutes exceeds cap of $MAX_DELAY_MINUTES. Capping to $MAX_DELAY_MINUTES."
        $delays[$i] = $MAX_DELAY_MINUTES
    }
}

# ---------- Print schedule ----------
Write-Host "`n===== Schedule (parallel jobs) ====="
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    Write-Host "$($vmNames[$i]) : CPU=$($cpus[$i]), Memory=$($mems[$i]) GB, delay=$($delays[$i]) min"
}
Write-Host "Start time: $(Get-Date -Format 'HH:mm:ss')`n"

# ---------- Prepare logging ----------
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\resize_log.csv"
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# Write CSV header once
"Site,VMName,CurrentCPU,CurrentMemGB,NewCPU,NewMemGB,Status" | Out-File -FilePath $logPath -Append -Encoding utf8

# ---------- Site mapping ----------
$siteMap = @{
    "Bangalore" = "192.168.136.50"
    "Chennai"   = "10.0.0.10"
    "Pune"      = "10.0.0.20"
}

$siteName = $data.s1
if (-not $siteMap.ContainsKey($siteName)) {
    throw "Site '$siteName' not found in mapping. Available: $($siteMap.Keys -join ', ')"
}
$ClusterIP = $siteMap[$siteName]   # not directly used but kept for consistency

# ---------- Define the job script block ----------
$resizeJob = {
    param($site, $vmName, $delayMin, $cpu, $memGB, $user, $pass, $siteMap, $logPath)

    $ip = $siteMap[$site]
    if (-not $ip) {
        "$site,$vmName,0,0,$cpu,$memGB,ERROR: Site not mapped" | Out-File -FilePath $logPath -Append -Encoding utf8
        return
    }

    if ($delayMin -gt 0) {
        Write-Host "[$vmName] Waiting $delayMin minute(s)..."
        Start-Sleep -Seconds ($delayMin * 60)
    }

    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin
    }

    # Build SecureString manually
    $securePass = New-Object System.Security.SecureString
    foreach ($char in $pass.ToCharArray()) { $securePass.AppendChar($char) }
    $securePass.MakeReadOnly()

    $Status = "failed"
    $CurrentCPU = 0
    $CurrentMemGB = 0
    $NewCPU = $cpu
    $NewMemGB = $memGB

    try {
        Connect-NTNXCluster -Server $ip -UserName $user -Password $securePass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

        $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName }
        if (-not $vm) {
            $Status = "VM Not Found"
        } else {
            $CurrentCPU = [int]$vm.numVcpus
            $CurrentMemGB = [int]($vm.memoryMb / 1024)

            $FinalCPU = if ($cpu -gt 0) { $cpu } else { $CurrentCPU }
            $TempMem = if ($memGB -gt 0) { $memGB } else { $CurrentMemGB }
            $FinalMemGB = if ($TempMem -lt 1) { 1 } else { $TempMem }

            $NewCPU = $FinalCPU
            $NewMemGB = $FinalMemGB

            if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
                $Status = "skipped (no change)"
            } else {
                Write-Host "[$vmName] Attempt 1: ACPI shutdown..."
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 40
                $CheckVM = Get-NTNXVM -Vmid $vm.uuid
                if ($CheckVM.powerState -eq "ON") {
                    Write-Host "[$vmName] Attempt 2: ACPI shutdown again..."
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                    Start-Sleep -Seconds 20
                }

                Write-Host "[$vmName] Applying: $FinalCPU CPU, $FinalMemGB GB RAM."
                Set-NTNXVirtualMachine -Vmid $vm.uuid -NumVcpus $FinalCPU -MemoryMb ($FinalMemGB * 1024) -ErrorAction Stop | Out-Null
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON -ErrorAction Stop | Out-Null
                $Status = "successful"
            }
        }
    } catch {
        $Status = "failed - $($_.Exception.Message.Split(':')[0])"
    } finally {
        Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue
    }

    # Log: Site,VMName,CurrentCPU,CurrentMemGB,NewCPU,NewMemGB,Status
    "$site,$vmName,$CurrentCPU,$CurrentMemGB,$NewCPU,$NewMemGB,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host "[$vmName] $Status"
}

# ---------- Start a background job for each VM ----------
$jobs = @()
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $job = Start-Job -ScriptBlock $resizeJob -ArgumentList `
        $siteName,
        $vmNames[$i],
        $delays[$i],
        $cpus[$i],
        $mems[$i],
        $env:PE_USER,
        $env:PE_PASS,
        $siteMap,
        $logPath
    $jobs += $job
}

# ---------- Wait for all jobs to complete ----------
Write-Host "`nWaiting for all resize jobs to finish..."
$jobs | Wait-Job | Out-Null

# ---------- Receive output from each job ----------
$jobs | ForEach-Object {
    Receive-Job $_ -ErrorAction SilentlyContinue
    Remove-Job $_
}

Write-Host "`n===== All VMs processed. Log saved to $logPath ====="

# ---------- Read the log and display a summary table ----------
if (Test-Path $logPath) {
    $results = Import-Csv -Path $logPath

    # --- Console output (format-table) ---
    Write-Host "`n===== Summary Table ====="
    $results | Sort-Object VMName | Format-Table -Property @(
        @{Name='Site Name'; Expression={$_.Site}},
        @{Name='VMName'; Expression={$_.VMName}},
        @{Name='Current CPU'; Expression={$_.CurrentCPU}},
        @{Name='Current Mem'; Expression={$_.CurrentMemGB}},
        @{Name='New CPU'; Expression={$_.NewCPU}},
        @{Name='New Mem'; Expression={$_.NewMemGB}},
        @{Name='Status'; Expression={$_.Status}}
    ) -AutoSize

    # --- GitHub Step Summary (Markdown table) ---
    $summary = @"
## VM Resize Summary

| Site Name | VMName | Current CPU | Current Mem | New CPU | New Mem | Status |
|-----------|--------|-------------|-------------|---------|---------|--------|
"@
    foreach ($row in ($results | Sort-Object VMName)) {
        $summary += "| $($row.Site) | $($row.VMName) | $($row.CurrentCPU) | $($row.CurrentMemGB) | $($row.NewCPU) | $($row.NewMemGB) | $($row.Status) |`n"
    }

    # Append to GitHub step summary
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
        Write-Host "Summary also written to GitHub step summary."
    }

} else {
    Write-Host "Log file not found - no summary available."
}
