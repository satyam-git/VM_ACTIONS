param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_resize_log.csv"

if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# Helper to expand a parameter to match the number of VMs
function Expand-Parameter {
    param(
        [string[]]$vmList,
        [string]$rawValue
    )
    $values = $rawValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $vmCount = $vmList.Count

    if ($values.Count -eq 0) {
        # No value provided – default for numeric fields might be 0; for IP we need something else.
        # We'll handle defaults inside the job.
        return $null
    }
    if ($values.Count -eq 1) {
        # Single value applies to all VMs
        return ,@($values[0]) * $vmCount
    }
    # Multiple values: map one‑to‑one, pad with the last value
    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) {
        if ($i -lt $values.Count) {
            $result += $values[$i]
        } else {
            $result += $values[-1]
        }
    }
    return $result
}

# Read and expand all parameters
$vmNamesRaw = $data.vmname
if ([string]::IsNullOrWhiteSpace($vmNamesRaw)) { throw "VM name(s) are required." }
$vmList = $vmNamesRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($vmList.Count -eq 0) { throw "No valid VM names provided." }

$clusterIPs   = Expand-Parameter -vmList $vmList -rawValue $data.pE_IP
$cpuSizes     = Expand-Parameter -vmList $vmList -rawValue $data.CPU_size
$memSizes     = Expand-Parameter -vmList $vmList -rawValue $data.mem_size
$delays       = Expand-Parameter -vmList $vmList -rawValue $data.delay_mins

# If any parameter could not be expanded (null), set a default
if ($null -eq $clusterIPs) { $clusterIPs = @("") * $vmList.Count }
if ($null -eq $cpuSizes)   { $cpuSizes   = @("0") * $vmList.Count }
if ($null -eq $memSizes)   { $memSizes   = @("0") * $vmList.Count }
if ($null -eq $delays)     { $delays     = @("0") * $vmList.Count }

# Build a list of jobs
$jobBlock = {
    param($VMName, $ClusterIP, $CPU, $MemGB, $Delay, $User, $Pass, $LogPath)

    # Load Nutanix module
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
    }

    $Status = "failed"
    $ErrorMsg = ""

    try {
        # Apply delay if any
        if ([int]$Delay -gt 0) {
            Start-Sleep -Seconds ([int]$Delay * 60)
        }

        # Connect to cluster
        $securePass = $Pass | ConvertTo-SecureString -AsPlainText -Force
        Connect-NTNXCluster -Server $ClusterIP -UserName $User -Password $securePass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

        # Find VM
        $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
        if (-not $VM) {
            $Status = "VM not found"
            throw "VM $VMName not found on cluster $ClusterIP."
        }

        $CurrentCPU = [int]$VM.numVcpus
        $CurrentMemGB = [int]($VM.memoryMb / 1024)

        # Determine final values (0 means "keep current")
        $FinalCPU = if ([int]$CPU -gt 0) { [int]$CPU } else { $CurrentCPU }
        $FinalMemGB = if ([int]$MemGB -gt 0) { [int]$MemGB } else { $CurrentMemGB }
        if ($FinalMemGB -lt 1) { $FinalMemGB = 1 }   # minimum 1 GB

        # Skip if no change
        if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
            $Status = "skipped (values unchanged)"
            Write-Host "VM $VMName : Current and requested values are identical. Skipping resize."
            Disconnect-NTNXCluster -Servers $ClusterIP -ErrorAction SilentlyContinue
            return "$VMName,$ClusterIP,$FinalCPU,$FinalMemGB,$Delay,$Status"
        }

        # Two‑strike shutdown
        function Invoke-TwoStrikeShutdown {
            param($VMObj)
            Write-Host "VM $VMName : Attempt 1 - ACPI shutdown..."
            Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 40
            $CheckVM = Get-NTNXVM -Vmid $VMObj.uuid
            if ($CheckVM.powerState -eq "ON") {
                Write-Host "VM $VMName : Still ON. Attempt 2 - ACPI shutdown again..."
                Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 20
            }
        }
        Invoke-TwoStrikeShutdown -VMObj $VM

        # Resize and power on
        Write-Host "VM $VMName : Applying $FinalCPU vCPU, $FinalMemGB GB RAM."
        Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $FinalCPU -MemoryMb ($FinalMemGB * 1024) -ErrorAction Stop | Out-Null
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

        $Status = "successful"
        Disconnect-NTNXCluster -Servers $ClusterIP -ErrorAction SilentlyContinue
    }
    catch {
        $Status = "failed - $($_.Exception.Message.Split(':')[0])"
        $ErrorMsg = $_.Exception.Message
    }
    finally {
        Disconnect-NTNXCluster -Servers $ClusterIP -ErrorAction SilentlyContinue
    }

    # Write log line
    "$VMName,$ClusterIP,$FinalCPU,$FinalMemGB,$Delay,$Status" | Out-File -FilePath $LogPath -Append -Encoding utf8
}

# Launch a background job for each VM
for ($i = 0; $i -lt $vmList.Count; $i++) {
    $vm = $vmList[$i]
    $ip = $clusterIPs[$i]
    $cpu = $cpuSizes[$i]
    $mem = $memSizes[$i]
    $delay = $delays[$i]

    # Validate required fields
    if ([string]::IsNullOrWhiteSpace($ip)) {
        Write-Warning "Skipping VM '$vm' – no cluster IP provided."
        continue
    }

    Start-Job -ScriptBlock $jobBlock -ArgumentList $vm, $ip, $cpu, $mem, $delay, $env:PE_USER, $env:PE_PASS, $logPath
}

# Wait for all jobs and receive output (optional)
Get-Job | Wait-Job | Receive-Job
