param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_resize_log.csv"

# Site name → Cluster IP mapping
$siteMap = @{
    "Banglore" = "192.168.136.50"
    "Chennai"  = "10.0.0.10"
}

# Ensure log directory and clean old log
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# ---------- Helper: flat array of delays matching VM count ----------
function Get-DelaysForVMs {
    param(
        [string[]]$vmList,
        [string]$delayInput
    )
    $delays = $delayInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
    $vmCount = $vmList.Count
    if ($delays.Count -eq 0) {
        return @(0) * $vmCount
    }
    if ($delays.Count -eq 1) {
        return @($delays[0]) * $vmCount
    }
    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) {
        $result += if ($i -lt $delays.Count) { $delays[$i] } else { $delays[-1] }
    }
    return $result
}

# ---------- Job Script Block ----------
$taskBlock = {
    param($site, $vmName, $reqCpu, $reqMemGB, $delayMin, $user, $pass, $logPath, $siteMap)

    $ip = $siteMap[$site]
    if (-not $ip) { return }

    # Load Nutanix module
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
    }

    $status = "Failed"
    $oldCPU = $null; $oldMem = $null; $newCPU = $null; $newMem = $null

    try {
        # Connect
        $securePass = $pass | ConvertTo-SecureString -AsPlainText -Force
        Connect-NTNXCluster -Server $ip -UserName $user -Password $securePass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

        # Find VM
        $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName }
        if (-not $vm) {
            $status = "VM Not Found"
            return
        }

        # Current values
        $oldCPU = [int]$vm.numVcpus
        $oldMem = [int]($vm.memoryMb / 1024)

        # Determine final values (0 means "no change")
        $newCPU = if ($reqCpu -gt 0) { $reqCpu } else { $oldCPU }
        $newMem = if ($reqMemGB -gt 0) { $reqMemGB } else { $oldMem }
        if ($newMem -lt 1) { $newMem = 1 }

        # Skip if no change
        if ($newCPU -eq $oldCPU -and $newMem -eq $oldMem) {
            $status = "Skipped (values identical)"
            return
        }

        # Apply delay (only if changes are needed)
        if ($delayMin -gt 0) {
            Start-Sleep -Seconds ($delayMin * 60)
        }

        # ----- Two‑Strike Shutdown (only if VM is ON) -----
        if ($vm.powerState -eq "on") {
            Write-Host "[$vmName] Attempt 1: ACPI shutdown..."
            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 40

            $check = Get-NTNXVM -Vmid $vm.uuid
            if ($check.powerState -eq "on") {
                Write-Host "[$vmName] VM still ON. Attempt 2: ACPI shutdown again..."
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 20
            }
        } else {
            Write-Host "[$vmName] VM is already off. Skipping shutdown."
        }

        # Resize
        Write-Host "[$vmName] Applying: CPU $newCPU, Mem ${newMem}GB"
        Set-NTNXVirtualMachine -Vmid $vm.uuid -NumVcpus $newCPU -MemoryMb ($newMem * 1024) -ErrorAction Stop | Out-Null

        # Power on
        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON -ErrorAction Stop | Out-Null

        $status = "Success"

    } catch {
        $status = "Failed - $($_.Exception.Message.Split(':')[0])"
    } finally {
        Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue
        # Write log line
        "$site,$vmName,$oldCPU,$oldMem,$newCPU,$newMem,$status" | Out-File -FilePath $logPath -Append -Encoding utf8
    }
}

# ---------- Main: launch jobs for each input set ----------
for ($i = 1; $i -le 3; $i++) {
    $site = $data.$("s$i")
    if ($site -eq "None" -or [string]::IsNullOrWhiteSpace($site)) { continue }

    $vmRaw = $data.$("v$i")
    if ([string]::IsNullOrWhiteSpace($vmRaw)) { continue }
    $vmList = $vmRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $cpu = [int]$data.$("c$i")
    $mem = [int]$data.$("m$i")
    $delayInput = $data.$("d$i")
    if ([string]::IsNullOrWhiteSpace($delayInput)) { $delayInput = "0" }

    $delays = Get-DelaysForVMs -vmList $vmList -delayInput $delayInput

    for ($j = 0; $j -lt $vmList.Count; $j++) {
        Start-Job -ScriptBlock $taskBlock -ArgumentList $site, $vmList[$j], $cpu, $mem, $delays[$j], $env:PE_USER, $env:PE_PASS, $logPath, $siteMap
    }
}

# Wait for all jobs and collect output (optional)
Get-Job | Wait-Job | Receive-Job
