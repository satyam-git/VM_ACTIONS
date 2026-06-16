param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$plinkPath = "C:\Automation\Tools\plink.exe" 

# 1. Update this fingerprint! 
# Get this by running: C:\Automation\Tools\plink.exe -ssh 192.168.136.50
$fingerprint = "ssh-rsa 2048 q5ZpuCn0QBx0/c7ZDam/Wc/xVkgIOJmSwnD9stm4mQg"

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

# --- STORAGE PASS ---
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null }
Connect-NTNXCluster -Server $row.cluster_ip -UserName $row.PE_Username -Password ($row.PE_password | ConvertTo-SecureString -AsPlainText -Force) -AcceptInvalidSSLCerts | Out-Null

if ($row.Disk_Action -in "add", "extend") {
    $AcliCmd = if ($row.Disk_Action -eq "add") { "acli vm.disk_create '$($row.vmname)' container='default-container' create_size='$($row.SizeGB)G'" } else { "acli vm.disk_update '$($row.vmname)' disk_addr='$($row.DiskAddr)' new_size='$($row.SizeGB)G'" }
    
    # ROBUST PLINK CALL
    $plinkArgs = @("-batch", "-ssh", "-hostkey", $fingerprint, "-pw", $row.PE_password, "$($row.PE_Username)@$($row.cluster_ip)", $AcliCmd)
    Start-Process -FilePath $plinkPath -ArgumentList $plinkArgs -Wait -NoNewWindow
    
    # Guest Disk Logic
    $gCred = New-Object System.Management.Automation.PSCredential($row.Guest_Username, ($row.Guest_Password | ConvertTo-SecureString -AsPlainText -Force))
    Invoke-Command -ComputerName $row.GuestIP -Credential $gCred -ScriptBlock {
        param($Action, $Drive)
        Start-Sleep -Seconds 10
        if ($Action -eq "add") {
            $Disk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -or $_.OperationalStatus -eq "Offline" } | Select-Object -First 1
            if ($Disk) { Initialize-Disk -Number $Disk.Number -PartitionStyle GPT; New-Partition -DiskNumber $Disk.Number -DriveLetter $Drive -UseMaximumSize | Format-Volume -FileSystem NTFS -Confirm:$false }
        }
    } -ArgumentList $row.Disk_Action, $row.DriveLetter
}
Disconnect-NTNXCluster -Servers $row.cluster_ip -ErrorAction SilentlyContinue | Out-Null

# --- COMPUTE PASS ---
Connect-NTNXCluster -Server $row.cluster_ip -UserName $row.PE_Username -Password ($row.PE_password | ConvertTo-SecureString -AsPlainText -Force) -AcceptInvalidSSLCerts | Out-Null
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $row.vmname }
if ($VM) {
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 60
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus ([int]$row.cpu_value) -MemoryMb ([int]$row.mem_value * 1024) | Out-Null
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON | Out-Null
}
Disconnect-NTNXCluster -Servers $row.cluster_ip -ErrorAction SilentlyContinue | Out-Null
