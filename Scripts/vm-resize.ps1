param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$plinkPath = "C:\Automation\Tools\plink.exe" # <-- UPDATE THIS TO YOUR LOCAL SERVER PATH

# Map Workflow Inputs to the structure your script expects
$MasterRows = for ($i = 1; $i -le 1; $i++) {
    if ($data.$("v$i")) {
        [PSCustomObject]@{
            vmname            = $data.$("v$i")
            cpu_value         = $data.$("c$i")
            mem_value         = $data.$("m$i")
            Disk_Action       = $data.$("a$i")
            SizeGB            = $data.$("s$i")
            DiskAddr          = $data.$("ad$i")
            DriveLetter       = $data.$("dr$i")
            compute_delay_sec = $data.$("del$i")
            cluster_ip        = "192.168.136.50"
            PE_Username       = $env:PE_USER
            PE_password       = $env:PE_PASS
            GuestIP           = "192.168.136.55"
            Guest_Username    = $env:GUEST_USER
            Guest_Password    = $env:GUEST_PASS
        }
    }
}

# --- PASS 1: STORAGE (Your tested logic) ---
foreach ($row in $MasterRows) {
    Write-Host "`n--- [PASS 1: STORAGE] VM: $($row.vmname) ---" -ForegroundColor Yellow
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null }

    $Pass = $row.PE_password | ConvertTo-SecureString -AsPlainText -Force
    Connect-NTNXCluster -Server $row.cluster_ip -UserName $row.PE_Username -Password $Pass -AcceptInvalidSSLCerts | Out-Null
    $ClusterDetails = Get-NTNXCluster
    
    if ($row.Disk_Action -in "add", "extend") {
        $c = $null
        if ($row.Disk_Action -eq "add") {
            $prefix = $ClusterDetails.name.Substring(0, [math]::Min(3, $ClusterDetails.name.Length))
            $best = Get-NTNXContainer | Where-Object { 
                $n = if($_.name){$_.name}else{$_.containerName}
                $n -like "$prefix*" -and $n -notmatch "NutanixManagementShare|NutaniXFitInstance|default-container"
            } | Select-Object *, @{N='FreePct'; E={ 
                $cap = [double]$_.usageStats.'storage.capacity_bytes'
                $use = [double]$_.usageStats.'storage.usage_bytes'
                if($cap -gt 0){ (($cap - $use) / $cap) * 100 } else { 0 }
            }} | Sort-Object FreePct -Descending | Select-Object -First 1
            $c = if($best.name){$best.name}else{$best.containerName}
        }
        $AcliCmd = if ($row.Disk_Action -eq "add") { "acli vm.disk_create '$($row.vmname)' container='$c' create_size='$($row.SizeGB)G'" } else { "acli vm.disk_update '$($row.vmname)' disk_addr='$($row.DiskAddr)' new_size='$($row.SizeGB)G'" }
        & $plinkPath -batch -ssh -pw $row.PE_password "$($row.PE_Username)@$($row.cluster_ip)" $AcliCmd
        
        $gCred = New-Object System.Management.Automation.PSCredential($row.Guest_Username, ($row.Guest_Password | ConvertTo-SecureString -AsPlainText -Force))
        Invoke-Command -ComputerName $row.GuestIP -Credential $gCred -ScriptBlock {
            param($Action, $Drive)
            Start-Sleep -Seconds 10
            if ($Action -eq "add") {
                $Disk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -or $_.OperationalStatus -eq "Offline" } | Select-Object -First 1
                if ($Disk) { Initialize-Disk -Number $Disk.Number -PartitionStyle GPT; New-Partition -DiskNumber $Disk.Number -DriveLetter $Drive -UseMaximumSize | Format-Volume -FileSystem NTFS -Confirm:$false }
            } else {
                "rescan" | diskpart | Out-Null
                $Part = Get-Partition -DriveLetter $Drive
                "select disk $($Part.DiskNumber)`nselect partition $($Part.PartitionNumber)`nextend`nexit" | diskpart
            }
        } -ArgumentList $row.Disk_Action, $row.DriveLetter
    }
    Disconnect-NTNXCluster -Servers $row.cluster_ip -ErrorAction SilentlyContinue | Out-Null
}

# --- PASS 2: COMPUTE (Your tested logic) ---
$taskBlock = {
    param($row)
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null }
    $delayMin = [int]$row.compute_delay_sec
    if ($delayMin -gt 0) { Start-Sleep -Seconds ($delayMin * 60) }
    try {
        $Pass = $row.PE_password | ConvertTo-SecureString -AsPlainText -Force
        Connect-NTNXCluster -Server $row.cluster_ip -UserName $row.PE_Username -Password $Pass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $row.vmname }
        if ($VM) {
            $isPoweredOff = $false
            for ($i = 1; $i -le 2; $i++) {
                $VM = Get-NTNXVM -VmId $VM.uuid
                if ($VM.powerState -eq "off") { $isPoweredOff = $true; break }
                Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 45
            }
            if ($isPoweredOff -or (Get-NTNXVM -VmId $VM.uuid).powerState -eq "off") {
                Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus ([int]$row.cpu_value) -MemoryMb ([int]$row.mem_value * 1024) | Out-Null
                Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON | Out-Null
            }
        }
    } finally { Disconnect-NTNXCluster -Servers $row.cluster_ip -ErrorAction SilentlyContinue | Out-Null }
}

foreach ($row in $MasterRows) {
    if ($row.cpu_value) { Start-Job -ScriptBlock $taskBlock -ArgumentList $row | Out-Null }
}
Get-Job | Wait-Job | Receive-Job
