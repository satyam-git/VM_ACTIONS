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

# ---------- Define the job script block with connection timeout ----------
$resizeJob = {
    param($site, $vmName, $delayMin, $cpu, $memGB, $user, $pass, $siteMap, $logPath)

    $ip = $siteMap[$site]
    if (-not $ip) {
        "$site,$vmName,$cpu,$memGB,$delayMin,ERROR: Site not mapped" | Out-File -FilePath $logPath -Append -Encoding utf8
        Write-Host "[$vmName] ERROR: Site '$site' not in mapping."
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
        # ---- Connection with timeout ----
        Write-Host "[$vmName] Connecting to $ip (timeout 30s)..."
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
        Write-Host "[$vmName] Connected."

        # ---- Get VM and resize ----
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
        Write-Host "[$vmName] ERROR: $($_.Exception.Message)"
    } finally {
        Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue
    }

    "$site,$vmName,$cpu,$memGB,$delayMin,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host "[$vmName] $Status"
}

# ---------- Collect all jobs from all three sets ----------
$allJobs = @()
$MAX_DELAY_MINUTES = 60   # optional cap

for ($i = 1; $i -le 3; $i++) {
    $site = $data.$("s$i")
    if (-not $site -or $site -eq "None") { continue }

    $vmNamesRaw = $data.$("v$i")
    if ([string]::IsNullOrWhiteSpace($vmNamesRaw)) { continue }
    $vmNames = $vmNamesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($vmNames.Count -eq 0) { continue }

    $cpuInput = $data.$("c$i")
    $memInput = $data.$("m$i")
    $delayInput = $data.$("d$i")

    # Expand values for this set
    $cpus = Expand-Values -vmList $vmNames -inputValue $cpuInput -valueName "CPU"
    $mems = Expand-Values -vmList $vmNames -inputValue $memInput -valueName "Memory"
    $delays = Expand-Values -vmList $vmNames -inputValue $delayInput -valueName "Delay"

    # Cap delays
    for ($j = 0; $j -lt $delays.Count; $j++) {
        if ($delays[$j] -gt $MAX_DELAY_MINUTES) {
            Write-Warning "Delay of $($delays[$j]) minutes exceeds cap. Capping to $MAX_DELAY_MINUTES."
            $delays[$j] = $MAX_DELAY_MINUTES
        }
    }

    # Print set summary
    Write-Host "`n===== Set $i ($site) ====="
    for ($j = 0; $j -lt $vmNames.Count; $j++) {
        Write-Host "$($vmNames[$j]) : CPU=$($cpus[$j]), Memory=$($mems[$j]) GB, delay=$($delays[$j]) min"
    }

    # Start a job for each VM in this set
    for ($j = 0; $j -lt $vmNames.Count; $j++) {
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
    Write-Host "No VMs to process. Exiting."
    exit 0
}

# ---------- Wait for all jobs to complete ----------
Write-Host "`nWaiting for all resize jobs to finish..."
$allJobs | Wait-Job | Out-Null

# ---------- Receive output from each job ----------
$allJobs | ForEach-Object {
    Receive-Job $_ -ErrorAction SilentlyContinue
    Remove-Job $_
}

Write-Host "`n===== All VMs processed. Log saved to $logPath ====="
