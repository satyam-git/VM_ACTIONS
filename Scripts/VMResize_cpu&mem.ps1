param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

$ClusterIP = $data.pE_IP
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_resize_log.csv"

if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# -----------------------------------------------------------------
# Job script block – runs once per VM
# -----------------------------------------------------------------
$taskBlock = {
    param(
        $ClusterIP,
        $VMName,
        $RequestedCPU,
        $RequestedMemGB,
        $Delay,
        $User,
        $Pass,
        $LogPath
    )

    # Load Nutanix module
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
    }

    # Apply delay (if any)
    if ($Delay -gt 0) {
        Start-Sleep -Seconds ($Delay * 60)
    }

    # Connect
    $SecurePass = $Pass | ConvertTo-SecureString -AsPlainText -Force
    Connect-NTNXCluster -Server $ClusterIP -UserName $User -Password $SecurePass -AcceptInvalidSSLCerts | Out-Null

    $Status = "failed"
    $FinalCPU = $null
    $FinalMemGB = $null

    try {
        # Find VM
        $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
        if (-not $VM) {
            $Status = "VM not found"
            throw "VM not found"
        }

        $CurrentCPU = [int]$VM.numVcpus
        $CurrentMemGB = [int]($VM.memoryMb / 1024)

        # Determine final values: if requested > 0 use it, else keep current
        $FinalCPU = if ($RequestedCPU -gt 0) { $RequestedCPU } else { $CurrentCPU }
        $FinalMemGB = if ($RequestedMemGB -gt 0) { $RequestedMemGB } else { $CurrentMemGB }
        # Ensure memory is at least 1 GB (Nutanix requirement)
        if ($FinalMemGB -lt 1) { $FinalMemGB = 1 }

        # Skip if no change
        if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
            $Status = "skipped (no change)"
            return
        }

        # ---------- Shutdown (two‑strike) ----------
        function Invoke-TwoStrikeShutdown {
            param($VMObj)
            Write-Host "Attempt 1: ACPI shutdown..."
            Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 40
            $CheckVM = Get-NTNXVM -Vmid $VMObj.uuid
            if ($CheckVM.powerState -eq "ON") {
                Write-Host "VM still ON. Attempt 2: ACPI shutdown again..."
                Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 20
            }
        }
        Invoke-TwoStrikeShutdown -VMObj $VM

        # Resize and power on
        Write-Host "Applying: $FinalCPU CPU, $FinalMemGB GB RAM."
        Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $FinalCPU -MemoryMb ($FinalMemGB * 1024) -ErrorAction Stop | Out-Null
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

        $Status = "successful"
    }
    catch {
        $Status = "failed - $($_.Exception.Message.Split(':')[0])"
    }
    finally {
        Disconnect-NTNXCluster -Servers $ClusterIP -ErrorAction SilentlyContinue
    }

    # Log result (each line: VM, ClusterIP, CPU, Memory, Status)
    "$VMName,$ClusterIP,$FinalCPU,$FinalMemGB,$Status" | Out-File -FilePath $LogPath -Append -Encoding utf8
}

# -----------------------------------------------------------------
# Helper: expand a comma‑separated list to an array, 
#         and normalise length to match VM count
# -----------------------------------------------------------------
function Expand-List {
    param(
        [string]$InputString,
        [int]$TargetCount,
        [string]$DefaultValue = "0"
    )
    if ([string]::IsNullOrWhiteSpace($InputString)) { 
        return @($DefaultValue) * $TargetCount
    }
    $items = $InputString -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($items.Count -eq 0) {
        return @($DefaultValue) * $TargetCount
    }
    if ($items.Count -eq 1) {
        # single value applies to all
        return @($items[0]) * $TargetCount
    }
    # pad with last value if fewer items than VMs
    $result = @()
    for ($i = 0; $i -lt $TargetCount; $i++) {
        if ($i -lt $items.Count) {
            $result += $items[$i]
        } else {
            $result += $items[-1]
        }
    }
    return $result
}

# -----------------------------------------------------------------
# Parse inputs and launch parallel jobs
# -----------------------------------------------------------------
$vmList = $data.vmname -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
$vmCount = $vmList.Count

if ($vmCount -eq 0) {
    Write-Host "No VM names provided. Exiting."
    exit 0
}

# Expand CPU, Memory, Delay lists to match VM count
$cpuList = Expand-List -InputString $data.CPU_size -TargetCount $vmCount -DefaultValue "0"
$memList  = Expand-List -InputString $data.mem_size -TargetCount $vmCount -DefaultValue "0"
$delayList = Expand-List -InputString $data.delay_mins -TargetCount $vmCount -DefaultValue "0"

# Launch a background job for each VM
for ($i = 0; $i -lt $vmCount; $i++) {
    Start-Job -ScriptBlock $taskBlock -ArgumentList `
        $ClusterIP,
        $vmList[$i],
        [int]$cpuList[$i],
        [int]$memList[$i],
        [int]$delayList[$i],
        $env:PE_USER,
        $env:PE_PASS,
        $logPath
}

# Wait for all jobs to complete and capture output (optional)
Get-Job | Wait-Job | Receive-Job

Write-Host "All resize jobs completed. Log written to $logPath"
