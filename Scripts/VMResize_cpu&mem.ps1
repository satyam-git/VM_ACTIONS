param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# ---------- Print full input for debugging ----------
Write-Host "`n===== INPUT JSON ====="
$data | ConvertTo-Json | Write-Host
Write-Host "========================`n"

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
        [string]$valueName
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

# ---------- Site mapping ----------
$siteMap = @{
    "Bangalore" = "192.168.136.50"
    "Chennai"   = "10.0.0.10"
    "Pune"      = "10.0.0.20"
}

# ---------- Prepare logging ----------
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\resize_log.csv"
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# ---------- Check Nutanix snapin availability before starting jobs ----------
Write-Host "Checking Nutanix snapin..."
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    try {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
        Write-Host "Nutanix snapin loaded successfully."
    } catch {
        throw "Failed to load Nutanix snapin: $($_.Exception.Message)"
    }
} else {
    Write-Host "Nutanix snapin already loaded."
}

# ---------- Define the job script block with extensive logging ----------
$resizeJob = {
    param($site, $vmName, $delayMin, $cpu, $memGB, $user, $pass, $siteMap, $logPath)

    $jobLogPath = Join-Path (Split-Path $logPath -Parent) "job_$vmName.log"
    function Write-JobLog {
        param([string]$msg)
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$timestamp - $msg" | Out-File -FilePath $jobLogPath -Append -Encoding utf8
    }

    Write-JobLog "=== Job started for $vmName ==="
    Write-JobLog "Site: $site, Delay: $delayMin min, CPU: $cpu, Memory: $memGB GB"

    $ip = $siteMap[$site]
    if (-not $ip) {
        Write-JobLog "ERROR: Site '$site' not in mapping."
        "$site,$vmName,$cpu,$memGB,$delayMin,ERROR: Site not mapped" | Out-File -FilePath $logPath -Append -Encoding utf8
        return
    }
    Write-JobLog "Cluster IP: $ip"

    # Wait for the delay (if any)
    if ($delayMin -gt 0) {
        Write-JobLog "Waiting $delayMin minute(s)..."
        Start-Sleep -Seconds ($delayMin * 60)
        Write-JobLog "Wait finished."
    }

    # Load Nutanix snapin (inside job)
    Write-JobLog "Loading Nutanix snapin inside job..."
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop | Out-Null
    }
    Write-JobLog "Snapin loaded."

    $securePass = $pass | ConvertTo-SecureString -AsPlainText -Force
    $Status = "failed"
    try {
        # ---- Connection with timeout ----
        Write-JobLog "Connecting to $ip (timeout 30s)..."
        $connJob = Start-Job -ScriptBlock {
            param($ip, $user, $pass)
            Connect-NTNXCluster -Server $ip -UserName $user -Password $pass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        } -ArgumentList $ip, $user, $securePass

        if (-not (Wait-Job $connJob -Timeout 30)) {
            Stop-Job $connJob
            Remove-Job $connJob
            throw "Connection to $ip timed out after 30 seconds."
        }
        # Get any errors from the connection job
        Receive-Job $connJob -ErrorAction Stop
        Remove-Job $connJob
        Write-JobLog "Connected successfully."

        # ---- Get VM and resize ----
        Write-JobLog "Getting VM $vmName..."
        $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName }
        if (-not $vm) {
            $Status = "VM Not Found"
            Write-JobLog "VM not found."
        } else {
            $CurrentCPU = [int]$vm.numVcpus
            $CurrentMemGB = [int]($vm.memoryMb / 1024)
            Write-JobLog "Current: CPU=$CurrentCPU, Mem=$CurrentMemGB GB"

            $FinalCPU = if ($cpu -gt 0) { $cpu } else { $CurrentCPU }
            $TempMem = if ($memGB -gt 0) { $memGB } else { $CurrentMemGB }
            $FinalMemGB = if ($TempMem -lt 1) { 1 } else { $TempMem }

            if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
                $Status = "skipped (no change)"
                Write-JobLog "No change needed."
            } else {
                Write-JobLog "Attempt 1: ACPI shutdown..."
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 40
                $CheckVM = Get-NTNXVM -Vmid $vm.uuid
                if ($CheckVM.powerState -eq "ON") {
                    Write-JobLog "Attempt 2: ACPI shutdown again..."
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                    Start-Sleep -Seconds 20
                }

                Write-JobLog "Applying: $FinalCPU CPU, $FinalMemGB GB RAM."
                Set-NTNXVirtualMachine -Vmid $vm.uuid -NumVcpus $FinalCPU -MemoryMb ($FinalMemGB * 1024) -ErrorAction Stop | Out-Null
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON -ErrorAction Stop | Out-Null
                $Status = "successful"
                Write-JobLog "Resize completed."
            }
        }
    } catch {
        $Status = "failed - $($_.Exception.Message.Split(':')[0])"
        Write-JobLog "ERROR: $($_.Exception.Message)"
    } finally {
        Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue
        Write-JobLog "Disconnected."
    }

    "$site,$vmName,$cpu,$memGB,$delayMin,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-JobLog "Final status: $Status"
    Write-JobLog "=== Job finished ==="
}

# ---------- Collect all jobs from all three sets ----------
$allJobs = @()
$MAX_DELAY_MINUTES = 60   # optional cap

for ($i = 1; $i -le 3; $i++) {
    $site = $data.$("s$i")
    if (-not $site -or $site -eq "None") {
        Write-Host "Set $i: Site is None or empty – skipping."
        continue
    }

    $vmNamesRaw = $data.$("v$i")
    if ([string]::IsNullOrWhiteSpace($vmNamesRaw)) {
        Write-Host "Set $i: No VM names – skipping."
        continue
    }
    $vmNames = $vmNamesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($vmNames.Count -eq 0) {
        Write-Host "Set $i: No valid VM names – skipping."
        continue
    }

    $cpuInput = $data.$("c$i")
    $memInput = $data.$("m$i")
    $delayInput = $data.$("d$i")

    Write-Host "`nSet $i ($site): VM count = $($vmNames.Count), CPU input = '$cpuInput', Mem input = '$memInput', Delay input = '$delayInput'"

    # Expand values for this set
    try {
        $cpus = Expand-Values -vmList $vmNames -inputValue $cpuInput -valueName "CPU"
        $mems = Expand-Values -vmList $vmNames -inputValue $memInput -valueName "Memory"
        $delays = Expand-Values -vmList $vmNames -inputValue $delayInput -valueName "Delay"
    } catch {
        Write-Host "ERROR in Set $i: $_"
        continue
    }

    # Cap delays
    for ($j = 0; $j -lt $delays.Count; $j++) {
        if ($delays[$j] -gt $MAX_DELAY_MINUTES) {
            Write-Warning "Delay of $($delays[$j]) minutes exceeds cap. Capping to $MAX_DELAY_MINUTES."
            $delays[$j] = $MAX_DELAY_MINUTES
        }
    }

    # Print set summary
    Write-Host "===== Set $i ($site) ====="
    for ($j = 0; $j -lt $vmNames.Count; $j++) {
        Write-Host "$($vmNames[$j]) : CPU=$($cpus[$j]), Memory=$($mems[$j]) GB, delay=$($delays[$j]) min"
    }

    # Start a job for each VM in this set
    for ($j = 0; $j -lt $vmNames.Count; $j++) {
        Write-Host "Starting job for $($vmNames[$j])..."
        $job = Start-Job -ScriptBlock $resizeJob -ArgumentList `
            $site,
            $vmNames[$j],
            $delays[$j],
            $cpus[$j],
            $mems[$j],
            $env:PE_USER,
            $env:PE_PASS,
            $siteMap,
            $logPath
        $allJobs += $job
    }
}

if ($allJobs.Count -eq 0) {
    Write-Host "`nNo VMs to process. Exiting."
    exit 0
}

Write-Host "`nTotal jobs started: $($allJobs.Count)"

# ---------- Wait for all jobs to complete ----------
Write-Host "Waiting for jobs to finish (max 10 minutes per job due to connection timeout)..."
$allJobs | Wait-Job | Out-Null

# ---------- Receive output from each job ----------
Write-Host "`n----- Job Outputs -----"
$allJobs | ForEach-Object {
    $job = $_
    Write-Host "`n--- Job $($job.Id) ($($job.Name)) ---"
    $output = Receive-Job $job -ErrorAction SilentlyContinue
    if ($output) { $output }
    # Also show any error records
    $errors = Receive-Job $job -ErrorVariable jobErrors -ErrorAction SilentlyContinue
    if ($jobErrors) { $jobErrors | ForEach-Object { Write-Host "ERROR: $_" } }
    Remove-Job $job
}

# ---------- Show the log files ----------
Write-Host "`n===== CSV Log ($logPath) ====="
if (Test-Path $logPath) {
    Get-Content $logPath | Write-Host
} else {
    Write-Host "No CSV log found."
}

Write-Host "`n===== Individual job logs (in 'data' folder) ====="
$jobLogs = Get-ChildItem "data\job_*.log" -ErrorAction SilentlyContinue
if ($jobLogs) {
    $jobLogs | ForEach-Object {
        Write-Host "`n--- $($_.Name) ---"
        Get-Content $_.FullName | Write-Host
    }
} else {
    Write-Host "No job logs found."
}

Write-Host "`n===== All VMs processed. ====="
