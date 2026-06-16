param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$plinkPath = "C:\Automation\Tools\plink.exe" # <-- UPDATE THIS PATH

$row = [PSCustomObject]@{
    vmname            = $data.vmname
    cluster_ip        = $data.cluster_ip
    PE_Username       = $env:PE_USER
    PE_password       = $env:PE_PASS
    Disk_Action       = $data.disk_action
    SizeGB            = $data.size_gb
    DiskAddr          = $data.disk_addr
    GuestIP           = $data.guest_ip
    Guest_Username    = $env:G_USER
    Guest_Password    = $env:G_PASS
    DriveLetter       = $data.drive_letter
    cpu_value         = $data.cpu_val
    mem_value         = $data.mem_val
    compute_delay_sec = $data.delay_min
}

# --- PASS 1: STORAGE ---
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null }
$Pass = $row.PE_password | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $row.cluster_ip -UserName $row.PE_Username -Password $Pass -AcceptInvalidSSLCerts | Out-Null

if ($row.Disk_Action -in "add", "extend") {
    $c = $null
    if ($row.Disk_Action -eq "add") {
        $ClusterDetails = Get-NTNXCluster
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

# --- PASS 2: COMPUTE ---
$delayMin = [int]$row.compute_delay_sec
if ($delayMin -gt 0) { Start-Sleep -Seconds ($delayMin * 60) }
Connect-NTNXCluster -Server $row.cluster_ip -UserName $row.PE_Username -Password $Pass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $row.vmname }
if ($VM) {
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 90
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus ([int]$row.cpu_value) -MemoryMb ([int]$row.mem_value * 1024) | Out-Null
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON | Out-Null
}
Disconnect-NTNXCluster -Servers $row.cluster_ip -ErrorAction SilentlyContinue | Out-Null
