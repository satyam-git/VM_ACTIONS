param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_resize_log.csv"

if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# Helper: returns a flat array of delays (integers) matching the number of VMs
function Get-DelaysForVMs {
    param(
        [string[]]$vmList,
        [string]$delayInput
    )
    # Parse comma-separated delays, trim, ignore empty, convert to int
    $delays = $delayInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
    $vmCount = $vmList.Count

    if ($delays.Count -eq 0) {
        return @(0) * $vmCount
    }
    if ($delays.Count -eq 1) {
        return @($delays[0]) * $vmCount
    }
    # Multiple delays: map one‑to‑one, pad with the last delay
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

# Job script block for a single VM resize
$taskBlock = {
    param($ClusterIP, $VMName, $RequestedCPU, $RequestedMemGB, $Delay, $User, $Pass, $logPath)

    # Load Nutanix module
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
    }

    # Secure credential
    $securePass = New-Object System.Security.SecureString
    foreach ($char in $Pass.ToCharArray()) { $securePass.AppendChar($char) }
    $securePass.MakeReadOnly()

    $Status = "failed"
    $FinalCPU = 0
    $FinalMemGB = 0

    try {
        Connect-NTNXCluster -Server $ClusterIP -UserName $User -Password $securePass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

        $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
        if (-not $VM) {
            $Status = "VM not found"
            throw "VM not found"
        }

        $CurrentCPU = [int]$VM.numVcpus
        $CurrentMemGB = [int]($VM.memoryMb / 1024)

        # Determine final values (0 means "no change")
        $FinalCPU = if ($RequestedCPU -gt 0) { $RequestedCPU } else { $CurrentCPU }
        $FinalMemGB = if ($RequestedMemGB -gt 0) { $RequestedMemGB } else { $CurrentMemGB }
        if ($FinalMemGB -lt 1) { $FinalMemGB = 1 }  # safety

        # Skip if already matching
        if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
            $Status = "skipped (already same)"
            Disconnect-NTNXCluster -Servers $ClusterIP -ErrorAction SilentlyContinue
            "$ClusterIP,$VMName,$FinalCPU,$FinalMemGB,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
            return
        }

        # Apply delay if needed
        if ($Delay -gt 0) {
            Write-Host "VM $VMName: Waiting $Delay minutes before resize..."
            Start-Sleep -Seconds ($Delay * 60)
        }

        # Two‑strike shutdown function
        function Invoke-TwoStrikeShutdown {
            param($VMObj)
            Write-Host "VM $VMName: Attempt 1 – ACPI shutdown..."
            Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 40

            $CheckVM = Get-NTNXVM -Vmid $VMObj.uuid
            if ($CheckVM.powerState -eq "ON") {
                Write-Host "VM $VMName: Still ON – Attempt 2 – ACPI shutdown..."
                Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 20
            }
        }

        # Shut down the VM
        Invoke-TwoStrikeShutdown -VMObj $VM

        # Resize and power on
        Write-Host "VM $VMName: Resizing to $FinalCPU CPU, $FinalMemGB GB RAM."
        Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $FinalCPU -MemoryMb ($FinalMemGB * 1024) -ErrorAction Stop | Out-Null
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

        $Status = "success"
    }
    catch {
        $Status = "failed - $($_.Exception.Message.Split(':')[0])"
    }
    finally {
        Disconnect-NTNXCluster -Servers $ClusterIP -ErrorAction SilentlyContinue
    }

    "$ClusterIP,$VMName,$FinalCPU,$FinalMemGB,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
}

# Process each of the 3 input groups
for ($i = 1; $i -le 3; $i++) {
    $clusterIP = $data.$("pE_IP$i")
    if ([string]::IsNullOrWhiteSpace($clusterIP)) { continue }

    $vmNamesRaw = $data.$("vmname$i")
    if ([string]::IsNullOrWhiteSpace($vmNamesRaw)) { continue }
    $vmList = $vmNamesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $cpuRaw = $data.$("CPU_size$i")
    $cpu = if ([string]::IsNullOrWhiteSpace($cpuRaw)) { 0 } else { [int]$cpuRaw }

    $memRaw = $data.$("mem_size$i")
    $mem = if ([string]::IsNullOrWhiteSpace($memRaw)) { 0 } else { [int]$memRaw }

    $delayInput = $data.$("delay_mins$i")
    if ([string]::IsNullOrWhiteSpace($delayInput)) { $delayInput = "0" }

    $delays = Get-DelaysForVMs -vmList $vmList -delayInput $delayInput

    for ($j = 0; $j -lt $vmList.Count; $j++) {
        Start-Job -ScriptBlock $taskBlock -ArgumentList $clusterIP, $vmList[$j], $cpu, $mem, $delays[$j], $env:PE_USER, $env:PE_PASS, $logPath
    }
}

# Wait for all jobs and collect output (optional)
Get-Job | Wait-Job | Receive-Job
