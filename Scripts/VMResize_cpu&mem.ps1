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

# ---------- Build a list of all tasks (VM, site, CPU, memory, delay) ----------
$tasks = @()
$MAX_DELAY_MINUTES = 60

for ($set = 1; $set -le 3; $set++) {
    $site = $data.$("s$set")
    if (-not $site -or $site -eq "None") { continue }

    $vmNamesRaw = $data.$("v$set")
    if ([string]::IsNullOrWhiteSpace($vmNamesRaw)) { continue }
    $vmNames = $vmNamesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($vmNames.Count -eq 0) { continue }

    $cpuInput = $data.$("c$set")
    $memInput = $data.$("m$set")
    $delayInput = $data.$("d$set")

    Write-Host ("`nSet {0} ({1}): VM count = {2}, CPU input = '{3}', Mem input = '{4}', Delay input = '{5}'" -f $set, $site, $vmNames.Count, $cpuInput, $memInput, $delayInput)

    try {
        $cpus = Expand-Values -vmList $vmNames -inputValue $cpuInput -valueName "CPU"
        $mems = Expand-Values -vmList $vmNames -inputValue $memInput -valueName "Memory"
        $delays = Expand-Values -vmList $vmNames -inputValue $delayInput -valueName "Delay"
    } catch {
        Write-Host ("ERROR in Set {0}: {1}" -f $set, $_)
        continue
    }

    # Cap delays
    for ($j = 0; $j -lt $delays.Count; $j++) {
        if ($delays[$j] -gt $MAX_DELAY_MINUTES) {
            Write-Warning "Delay of $($delays[$j]) minutes capped to $MAX_DELAY_MINUTES."
            $delays[$j] = $MAX_DELAY_MINUTES
        }
    }

    Write-Host ("===== Set {0} ({1}) =====" -f $set, $site)
    for ($j = 0; $j -lt $vmNames.Count; $j++) {
        Write-Host "$($vmNames[$j]) : CPU=$($cpus[$j]), Memory=$($mems[$j]) GB, delay=$($delays[$j]) min"
        $tasks += [PSCustomObject]@{
            Site    = $site
            VMName  = $vmNames[$j]
            CPU     = $cpus[$j]
            Mem     = $mems[$j]
            Delay   = $delays[$j]
        }
    }
}

if ($tasks.Count -eq 0) {
    Write-Host "`nNo VMs to process. Exiting."
    exit 0
}

Write-Host "`nTotal tasks: $($tasks.Count)"
Write-Host "Starting parallel execution using runspaces..."

# ---------- Create InitialSessionState with the Nutanix snapin preloaded ----------
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
try {
    $iss.AddPSSnapIn("NutanixCmdletsPSSnapin", $null) | Out-Null
    Write-Host "Nutanix snapin added to initial session state."
} catch {
    Write-Warning "Could not add Nutanix snapin to session state: $_"
    Write-Warning "Will try to load it inside each runspace."
}

# ---------- Create runspace pool with the initial session state ----------
$runspacePool = [runspacefactory]::CreateRunspacePool(1, $tasks.Count, $iss, $host)
$runspacePool.Open()

# ---------- Define the work script ----------
$scriptBlock = {
    param($site, $vmName, $delayMin, $cpu, $memGB, $user, $pass, $siteMap, $logPath)

    # Ensure snapin is loaded (redundant but safe)
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
    }

    $ip = $siteMap[$site]
    if (-not $ip) {
        "$site,$vmName,$cpu,$memGB,$delayMin,ERROR: Site not mapped" | Out-File -FilePath $logPath -Append -Encoding utf8
        return
    }

    # Wait for the delay (if any)
    if ($delayMin -gt 0) {
        Write-Host "[$vmName] Waiting $delayMin minute(s)..."
        Start-Sleep -Seconds ($delayMin * 60)
        Write-Host "[$vmName] Wait finished."
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
        Receive-Job $connJob -ErrorAction Stop
        Remove-Job $connJob
        Write-Host "[$vmName] Connected."

        # ---- Get VM and resize ----
        $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName }
        if (-not $vm) {
            $Status = "VM Not Found"
            Write-Host "[$vmName] VM not found."
        } else {
            $CurrentCPU = [int]$vm.numVcpus
            $CurrentMemGB = [int]($vm.memoryMb / 1024)
            Write-Host "[$vmName] Current: CPU=$CurrentCPU, Mem=$CurrentMemGB GB"

            $FinalCPU = if ($cpu -gt 0) { $cpu } else { $CurrentCPU }
            $TempMem = if ($memGB -gt 0) { $memGB } else { $CurrentMemGB }
            $FinalMemGB = if ($TempMem -lt 1) { 1 } else { $TempMem }

            if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
                $Status = "skipped (no change)"
                Write-Host "[$vmName] No change needed."
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
                Write-Host "[$vmName] Resize completed."
            }
        }
    } catch {
        $Status = "failed - $($_.Exception.Message.Split(':')[0])"
        Write-Host "[$vmName] ERROR: $($_.Exception.Message)"
    } finally {
        Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue
        Write-Host "[$vmName] Disconnected."
    }

    "$site,$vmName,$cpu,$memGB,$delayMin,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host "[$vmName] Final status: $Status"
}

# ---------- Start all tasks ----------
$jobs = @()
foreach ($task in $tasks) {
    $powershell = [powershell]::Create()
    $powershell.RunspacePool = $runspacePool
    $powershell.AddScript($scriptBlock).AddArgument($task.Site).AddArgument($task.VMName).AddArgument($task.Delay).AddArgument($task.CPU).AddArgument($task.Mem).AddArgument($env:PE_USER).AddArgument($env:PE_PASS).AddArgument($siteMap).AddArgument($logPath) | Out-Null
    $jobs += [PSCustomObject]@{
        PowerShell = $powershell
        Handle     = $powershell.BeginInvoke()
        Task       = $task
    }
}

# ---------- Wait for all to complete ----------
Write-Host "`nWaiting for all tasks to finish..."
foreach ($job in $jobs) {
    $job.PowerShell.EndInvoke($job.Handle) | Out-Null
    $job.PowerShell.Dispose()
}
$runspacePool.Dispose()

# ---------- Show log ----------
Write-Host "`n===== CSV Log ($logPath) ====="
if (Test-Path $logPath) {
    Get-Content $logPath | Write-Host
} else {
    Write-Host "No CSV log found."
}

Write-Host "`n===== All VMs processed. ====="
