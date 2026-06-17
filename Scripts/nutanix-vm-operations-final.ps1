param(
    [Parameter(Mandatory = $true)]
    [string]$Operation, # "Compute" or "Storage"

    # JSON input for Compute, or individual parameters for Storage
    [string]$JsonInputs,
    [string]$pe_ip,
    [string]$vmname,
    [string]$disk_action,
    [string]$SizeGB,
    [string]$DiskAddr = "none",
    [string]$GuestIP,
    [string]$DriveLetter
)

$ErrorActionPreference = "Stop"

# --- HELPER: Load Nutanix Modules ---
function Load-NutanixSnapin {
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
    }
}

# --- OPERATION: COMPUTE ---
if ($Operation -eq "Compute") {
    $data = $JsonInputs | ConvertFrom-Json
    Load-NutanixSnapin
    
    $Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
    Connect-NTNXCluster -Server $data.pE_IP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null
    
    $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $data.vmname }
    if (-not $VM) { throw "VM $($data.vmname) not found." }

    if ($data.delay_mins -gt 0) { Start-Sleep -Seconds ($data.delay_mins * 60) }

    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 60
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus [int]$data.CPU_size -MemoryMb ([int]$data.mem_size * 1024) -ErrorAction Stop | Out-Null
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null
    
    Disconnect-NTNXCluster -Servers $data.pE_IP | Out-Null
}

# --- OPERATION: STORAGE ---
elseif ($Operation -eq "Storage") {
    Import-Module Posh-SSH -ErrorAction Stop
    $SecurePassword = ConvertTo-SecureString $env:PE_PASSWORD -AsPlainText -Force
    $Credential = New-Object PSCredential ($env:PE_USERNAME, $SecurePassword)
    $Session = New-SSHSession -ComputerName $pe_ip -Credential $Credential -AcceptKey -Force

    try {
        if ($disk_action -eq "add") {
            Load-NutanixSnapin
            Connect-NTNXCluster -Server $pe_ip -UserName $env:PE_USERNAME -Password $SecurePassword -AcceptInvalidSSLCerts | Out-Null
            # ... (Insert your existing logic to find $BestContainer and $AcliCommand) ...
            $AcliCommand = "acli vm.disk_create '$vmname' container='$ContainerName' create_size='${SizeGB}G'"
        } else {
            $AcliCommand = "acli vm.disk_update '$vmname' disk_addr='$DiskAddr' new_size='${SizeGB}G'"
        }

        $Result = Invoke-SSHCommand -SessionId $Session.SessionId -Command $AcliCommand
        # ... (Insert your existing Guest OS Invoke-Command logic) ...
    }
    finally {
        if ($Session) { Remove-SSHSession -SessionId $Session.SessionId }
    }
}
