param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$ErrorActionPreference = "Stop"

# --- HELPER: Load Nutanix Snapin ---
function Load-Nutanix { 
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { 
        Add-PSSnapin NutanixCmdletsPSSnapin 
    } 
}

# --- STAGE 1: STORAGE (Provisioning) ---
# Only runs if a disk action is specified
if ($data.d_action -ne "none") {
    Write-Host "--- Stage 1: Storage ---"
    
    # Import required module
    Import-Module Posh-SSH -ErrorAction Stop

    # Connection Setup
    $SecurePassword = ConvertTo-SecureString $env:PE_PASSWORD -AsPlainText -Force
    $Credential = New-Object PSCredential ($env:PE_USERNAME, $SecurePassword)
    $Session = New-SSHSession -ComputerName $data.pe_ip -Credential $Credential -AcceptKey -Force

    try {
        if ($data.d_action -eq "add") {
            Load-Nutanix
            Connect-NTNXCluster -Server $data.pe_ip -UserName $env:PE_USERNAME -Password $SecurePassword -AcceptInvalidSSLCerts | Out-Null
            
            # Logic to find Container
            $ClusterDetails = Get-NTNXCluster
            $Prefix = $ClusterDetails.name.Substring(0,[math]::Min(3,$ClusterDetails.name.Length))
            $BestContainer = Get-NTNXContainer | Where-Object { 
                $n = if ($_.name) { $_.name } else { $_.containerName }
                $n -like "$Prefix*" -and $n -notmatch "NutanixManagementShare|NutaniXFitInstance|default-container" 
            } | Sort-Object FreePct -Descending | Select-Object -First 1
            
            $ContainerName = if ($BestContainer.name) { $BestContainer.name } else { $BestContainer.containerName }
            $AcliCommand = "acli vm.disk_create '$($data.vmname)' container='$ContainerName' create_size='$($data.d_size)G'"
        } else {
            $AcliCommand = "acli vm.disk_update '$($data.vmname)' disk_addr='$($data.d_addr)' new_size='$($data.d_size)G'"
        }

        # Execute SSH/Guest OS Commands
        $Result = Invoke-SSHCommand -SessionId $Session.SessionId -Command $AcliCommand
        Write-Host $Result.Output
        
        # Guest OS Logic
        $GuestSecurePassword = ConvertTo-SecureString $env:LOCAL_PASSWORD -AsPlainText -Force
        $GuestCredential = New-Object System.Management.Automation.PSCredential($env:LOCAL_USERNAME, $GuestSecurePassword)
        Start-Sleep -Seconds 15
        
        Invoke-Command -ComputerName $data.g_ip -Credential $GuestCredential -ScriptBlock {
            param($Action, $DriveLetter)
            "rescan" | diskpart | Out-Null
            Start-Sleep -Seconds 5
            if ($Action -eq "add") {
                $Disk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -or $_.OperationalStatus -eq "Offline" } | Sort-Object Number | Select-Object -First 1
                if ($Disk.OperationalStatus -eq "Offline") { Set-Disk -Number $Disk.Number -IsOffline $false }
                Initialize-Disk -Number $Disk.Number -PartitionStyle GPT
                $Partition = New-Partition -DiskNumber $Disk.Number -DriveLetter $DriveLetter -UseMaximumSize
                Format-Volume -Partition $Partition -FileSystem NTFS -Confirm:$false -Force
            } else {
                $Partition = Get-Partition -DriveLetter $DriveLetter
                $SupportedSize = Get-PartitionSupportedSize -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
                Resize-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -Size $SupportedSize.SizeMax
            }
        } -ArgumentList $data.d_action, $data.drive
    } finally {
        if ($Session) { Remove-SSHSession -SessionId $Session.SessionId | Out-Null }
    }
}

# --- STAGE 2: COMPUTE (Resize) ---
# Only runs if CPU or Memory > 0
if ([int]$data.cpu -gt 0 -or [int]$data.mem -gt 0) {
    Write-Host "--- Stage 2: Compute ---"
    Load-Nutanix
    
    $Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
    Connect-NTNXCluster -Server $data.pe_ip -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null
    
    $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $data.vmname }
    
    # Graceful Shutdown
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 60
    
    # Resize
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus [int]$data.cpu -MemoryMb ([int]$data.mem * 1024)
    
    # Power On
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON
    Disconnect-NTNXCluster -Servers $data.pe_ip
}
