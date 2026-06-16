param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Configuration
$PE_Username = $env:PE_USER
$PE_Password = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
$ClusterIP = $data.pE_IP
$VMName = $data.vmname
$CPUs = [int]$data.CPU_size
$MemoryMB = [int]$data.mem_size * 1024

# Load Nutanix Module
if (-not (Get-Module -Name NutanixCmdletsPSSnapin -ListAvailable)) {
    Write-Error "Nutanix PowerShell Cmdlets not found."
    exit 1
}
Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null

# Connect to Cluster
Connect-NTNXCluster -Server $ClusterIP -UserName $PE_Username -Password $PE_Password -AcceptInvalidSSLCerts | Out-Null

# Find the VM
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
if (-not $VM) {
    Write-Error "VM $VMName not found on cluster $ClusterIP."
    exit 1
}

Write-Host "Resizing VM $VMName to $CPUs CPU and $($data.mem_size)GB RAM..."

# Perform the resize
# Note: Set-NTNXVirtualMachine handles the update via the API
Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $CPUs -MemoryMb $MemoryMB | Out-Null

Write-Host "Compute resources updated successfully."

# Disconnect
Disconnect-NTNXCluster -Servers $ClusterIP | Out-Null
