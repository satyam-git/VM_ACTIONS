param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_resize_log.csv"

$siteMap = @{
    "Banglore" = "192.168.136.50"
    "Chennai"  = "10.0.0.10"
}

if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# ---------- JOB SCRIPT BLOCK (per VM resize) ----------
$taskBlock = {
    param($site, $vmName, $reqCpu, $reqMemGB, $delay, $user, $pass, $logPath, $siteMap)

    $ip = $siteMap[$site]
    if (-not $ip) { return }

    # Load Nutanix module
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin
    }

    # Build secure credential (same as your working script)
    $creds = New-Object System.Security.SecureString
    foreach ($char in $pass.ToCharArray()) { $creds.AppendChar($char) }
    $creds.MakeReadOnly()

    $Status = "Failed"
    $oldCPU = $null; $oldMem = $null; $newCPU = $null; $newMem = $null

    try {
        Connect-NTNXCluster -Server $ip -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

        $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName }
        if (-not $vm) {
            $Status = "VM Not Found"
            return
        }

        # Current specs
        $oldCPU = [int]$vm.numVcpus
        $oldMem = [int]($vm.memoryMb / 1024)

        # Determine new specs (0 means "no change")
        $newCPU = if ($reqCpu -gt 0) { $reqCpu } else { $oldCPU }
        $newMem = if ($reqMemGB -gt 0) { $reqMemGB } else { $oldMem }
        if ($newMem -lt 1) { $newMem = 1 }   # minimum 1 GB

        # If no change, skip (and don't apply delay)
        if ($newCPU -eq $oldCPU -and $newMem -eq $oldMem) {
            $Status = "Skipped (values identical)"
            return
        }

        # Apply delay ONLY if changes are needed
        if ([int]$delay -gt 0) {
            Start-Sleep -Seconds ([int]$delay * 60)
        }

        # ----- Two‑Strike Shutdown (only if VM is ON) -----
        if ($vm.powerState -eq "on") {
            # Strike 1
            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 40

            # Check if still on
            $check = Get-NTNXVM -Vmid $vm.uuid
            if ($check.powerState -eq "on") {
                # Strike 2
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 20
            }
        }

        # Resize
        Set-NTNXVirtualMachine -Vmid $vm.uuid -NumVcpus $newCPU -MemoryMb ($newMem * 1024) -ErrorAction Stop | Out-Null

        # Power on
        Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON -ErrorAction Stop | Out-Null

        $Status = "Success"

    } catch {
        $Status = "failed - $($_.Exception.Message.Split(':')[0])"
    } finally {
        Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue
        # Log result (same format as your VM actions script)
        "$site,$vmName,$oldCPU,$oldMem,$newCPU,$newMem,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
    }
}

# ---------- Helper: flat array of delays ----------
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
        if ($i -lt $delays.Count) {
            $result += $delays[$i]
        } else {
            $result += $delays[-1]
        }
    }
    return $result
}

# ---------- Main: launch jobs for each of the 3 input groups ----------
for ($i = 1; $i -le 3; $i++) {
    $site = $data.$("s$i")
    if ($site -eq "None" -or [string]::IsNullOrWhiteSpace($site)) { continue }

    $vmNamesRaw = $data.$("v$i")
    if ([string]::IsNullOrWhiteSpace($vmNamesRaw)) { continue }
    $vmList = $vmNamesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $cpu = [int]$data.$("c$i")
    $mem = [int]$data.$("m$i")
    $delayInput = $data.$("d$i")
    if ([string]::IsNullOrWhiteSpace($delayInput)) { $delayInput = "0" }

    $delays = Get-DelaysForVMs -vmList $vmList -delayInput $delayInput

    for ($j = 0; $j -lt $vmList.Count; $j++) {
        Start-Job -ScriptBlock $taskBlock -ArgumentList $site, $vmList[$j], $cpu, $mem, $delays[$j], $env:PE_USER, $env:PE_PASS, $logPath, $siteMap
    }
}

# Wait for all jobs and collect their output (optional)
Get-Job | Wait-Job | Receive-Job
