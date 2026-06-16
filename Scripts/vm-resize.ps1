param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Configuration
$ClusterIP = $data.pE_IP
$VMName = $data.vmname
$PE_Username = $env:PE_USER
$PE_Password = $env:PE_PASS
$plinkPath = "C:\Automation\Tools\plink.exe"

# 1. Load Nutanix Module
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null }

# 2. Connect
$PassSecure = $PE_Password | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $ClusterIP -UserName $PE_Username -Password $PassSecure -AcceptInvalidSSLCerts | Out-Null
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }

# 3. Storage Pass (ACLI via Plink)
if ($data.disk_action -in "add", "extend") {
    $AcliCmd = if ($data.disk_action -eq "add") { "acli vm.disk_create '$VMName' container='default-container' create_size='$($data.size)G'" } 
               else { "acli vm.disk_update '$VMName' disk_addr='$($data.DiskAddr)' new_size='$($data.size)G'" }
    
    Write-Host "Executing Storage Action: $AcliCmd"
    $plinkArgs = @("-batch", "-ssh", "-pw", $PE_Password, "$PE_Username@$ClusterIP", $AcliCmd)
    Start-Process -FilePath $plinkPath -ArgumentList $plinkArgs -Wait -NoNewWindow
}

# 4. Compute Pass (Native API)
if ($data.delay_mins -gt 0) { Start-Sleep -Seconds ($data.delay_mins * 60) }

Write-Host "Shutting down for Compute update..."
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 60

Write-Host "Updating CPU/RAM..."
Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus ([int]$data.CPU_size) -MemoryMb ([int]$data.mem_size * 1024) -ErrorAction Stop | Out-Null

Write-Host "Powering on..."
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON | Out-Null

Disconnect-NTNXCluster -Servers $ClusterIP | Out-Null
Write-Host "Resize completed successfully."
