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
        # If no values given, we need to decide:
        # - For Delay: default to 0
        # - For CPU/Mem: throw an error because they are required.
        if ($valueName -eq "Delay") {
            return @(0) * $vmCount
        } else {
            throw "No $valueName values provided. Please specify $valueName for each VM."
        }
    }

    if ($values.Count -eq 1) {
        # Single value: replicate to all VMs
        return @($values[0]) * $vmCount
    }

    # Multiple values: truncate or pad with the last value
    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) {
        if ($i -lt $values.Count) { $result += $values[$i] }
        else { $result += $values[-1] }
    }
    return $result
}

# ---------- Site mapping ----------
$siteMap = @{
    "Bangalore" = "192.168.136.50"
    "Chennai"   = "10.0.0.10"
    "Pune"      = "10.0.0.20"
}

# ---------- Process a single set (site + VM list + specs) ----------
function Process-Set {
    param(
        [string]$site,
        [string]$vmListStr,
        [string]$cpuStr,
        [string]$memStr,
        [string]$delayStr,
        [int]$setNumber
    )
    # Skip if site is "None" or empty, or VM list is empty
    if ([string]::IsNullOrWhiteSpace($site) -or $site -eq "None") {
        return @()
    }
    $vmNames = ($vmListStr -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($vmNames.Count -eq 0) {
        return @()
    }
    # Validate site
    if (-not $siteMap.ContainsKey($site)) {
        throw "Site '$site' in set $setNumber not found. Available: $($siteMap.Keys -join ', ')"
    }
    # Expand CPU, Memory, Delay
    $cpus = Expand-Values -vmList $vmNames -inputValue $cpuStr -valueName "CPU"
    $mems = Expand-Values -vmList $vmNames -inputValue $memStr -valueName "Memory"
    $delays = Expand-Values -vmList $vmNames -inputValue $delayStr -valueName "Delay"

    $result = @()
    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        $result += [PSCustomObject]@{
            Site    = $site
            VMName  = $vmNames[$i]
            CPU     = $cpus[$i]
            Memory  = $mems[$i]
            Delay   = $delays[$i]
        }
    }
    return $result
}

# ---------- Collect all VMs from the three sets ----------
$allVMs = @()
for ($i = 1; $i -le 3; $i++) {
    $vms = Process-Set -site $data."s$i" -vmListStr $data."v$i" `
                       -cpuStr $data."c$i" -memStr $data."m$i" -delayStr $data."d$i" -setNumber $i
    $allVMs += $vms
}

if ($allVMs.Count -eq 0) {
    throw "No VM sets provided (or all are empty). Please provide at least one set with site and VM names."
}

# ---------- Cap delays ----------
$MAX_DELAY_MINUTES = 60
foreach ($vm in $allVMs) {
    if ($vm.Delay -gt $MAX_DELAY_MINUTES) {
        Write-Warning "Delay of $($vm.Delay) minutes exceeds cap of $MAX_DELAY_MINUTES. Capping to $MAX_DELAY_MINUTES."
        $vm.Delay = $MAX_DELAY_MINUTES
    }
}

# ---------- Print schedule ----------
Write-Host "`n===== Schedule (parallel jobs) ====="
foreach ($vm in $allVMs) {
    Write-Host "$($vm.VMName) (Site: $($vm.Site)) : CPU=$($vm.CPU), Memory=$($vm.Memory) GB, delay=$($vm.Delay) min"
}
Write-Host "Start time: $(Get-Date -Format 'HH:mm:ss')`n"

# ---------- Prepare logging ----------
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\resize_log.csv"
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# ---------- Define the job script block ----------
$resizeJob = {
    param($site, $vmName, $delayMin, $cpu, $memGB, $user, $pass, $siteMap, $logPath)

    $ip = $siteMap[$site]
    if (-not $ip) {
        "$site,$vmName,$cpu,$memGB,$delayMin,ERROR: Site not mapped" | Out-File -FilePath $logPath -Append -Encoding utf8
        return
    }

    # Wait for the delay (if any)
    if ($delayMin -gt 0) {
        Write-Host "[$vmName] Waiting $delayMin minute(s)..."
        Start-Sleep -Seconds ($delayMin * 60)
    }

    # Load Nutanix snapin
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin
    }

    $securePass = $pass | ConvertTo-SecureString -AsPlainText -Force
    $Status = "failed"
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

            if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
                $Status = "skipped (no change)"
            } else {
                # Two‑strike shutdown
                Write-Host "[$vmName] Attempt 1: ACPI shutdown..."
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 40
                $CheckVM = Get-NTNXVM -Vmid $vm.uuid
                if ($CheckVM.powerState -eq "ON") {
                    Write-Host "[$vmName] Attempt 2: ACPI shutdown again..."
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                    Start-Sleep -Seconds 20
                }

                # Resize and power on
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

    "$site,$vmName,$cpu,$memGB,$delayMin,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host "[$vmName] $Status"
}

# ---------- Start a background job for each VM ----------
$jobs = @()
foreach ($vm in $allVMs) {
    $job = Start-Job -ScriptBlock $resizeJob -ArgumentList `
        $vm.Site,
        $vm.VMName,
        $vm.Delay,
        $vm.CPU,
        $vm.Memory,
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
