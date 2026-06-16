param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Configuration from Inputs/Secrets
$ClusterIP = $data.pE_IP
$VMName = $data.vmname
$CPUs = [int]$data.CPU_size
$MemoryMB = [int]$data.mem_size * 1024
$Delay = [int]$data.delay_mins

# 1. Load Nutanix Module
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

# 2. Connect to Cluster
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

# 3. Find VM
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
if (-not $VM) {
    Write-Error "VM $VMName not found."
    Disconnect-NTNXCluster -Servers $ClusterIP
    exit 1
}

# 4. Handle Delay
if ($Delay -gt 0) {
    Write-Host "Waiting $Delay minutes before resizing..."
    Start-Sleep -Seconds ($Delay * 60)
}

# 5. Shutdown and Resize
Write-Host "Shutting down VM $VMName..."
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 60

Write-Host "Updating VM to $CPUs CPU and $($data.mem_size)GB RAM..."
Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $CPUs -MemoryMb $MemoryMB | Out-Null

Write-Host "Powering on VM $VMName..."
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON | Out-Null

# 6. Cleanup
Disconnect-NTNXCluster -Servers $ClusterIP | Out-Null
Write-Host "Compute resize completed successfully."
