param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# ---------- Site to Cluster IP mapping ----------
$siteMap = @{
    "Bangalore" = "192.168.136.50"
    "Chennai"   = "10.0.0.10"
    "Pune"      = "10.0.0.20"   # Update with your actual IP
}

$siteName = $data.s1
if (-not $siteMap.ContainsKey($siteName)) {
    throw "Site '$siteName' not found in mapping. Available: $($siteMap.Keys -join ', ')"
}
$ClusterIP = $siteMap[$siteName]

# Common CPU & memory
$RequestedCPU = [int]$data.c1
$RequestedMemGB = [int]$data.m1

# Parse VM list
$vmNames = ($data.v1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($vmNames.Count -eq 0) {
    throw "No VM names provided."
}

# ---------- Delay replication (same as Get-DelaysForVMs) ----------
function Get-DelaysForVMs {
    param(
        [string[]]$vmList,
        [string]$delayInput
    )
    $vmCount = $vmList.Count
    if ($vmCount -eq 0) { return @() }

    $delays = if ([string]::IsNullOrWhiteSpace($delayInput)) {
        @(0)
    } else {
        $delayInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
    }

    if ($delays.Count -eq 0) { return @(0) * $vmCount }
    if ($delays.Count -eq 1) { return @($delays[0]) * $vmCount }

    # More than 1 delay – truncate or pad with last value
    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) {
        if ($i -lt $delays.Count) { $result += $delays[$i] }
        else { $result += $delays[-1] }
    }
    return $result
}

# ---------- Build delay list ----------
$delays = Get-DelaysForVMs -vmList $vmNames -delayInput $data.d1

# ---------- Optional: cap delays to prevent "non-ending" waits ----------
$MAX_DELAY_MINUTES = 60   # change as needed
for ($i = 0; $i -lt $delays.Count; $i++) {
    if ($delays[$i] -gt $MAX_DELAY_MINUTES) {
        Write-Warning "Delay of $($delays[$i]) minutes exceeds cap of $MAX_DELAY_MINUTES. Capping to $MAX_DELAY_MINUTES."
        $delays[$i] = $MAX_DELAY_MINUTES
    }
}

# ---------- Print schedule for debugging ----------
Write-Host "`n===== Schedule (parallel jobs) ====="
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    Write-Host "$($vmNames[$i]) : delay $($delays[$i]) min"
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
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $job = Start-Job -ScriptBlock $resizeJob -ArgumentList `
        $siteName,
        $vmNames[$i],
        $delays[$i],
        $RequestedCPU,
        $RequestedMemGB,
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
