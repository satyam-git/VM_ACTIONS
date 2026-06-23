param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Log inputs for debugging
Write-Host "Inputs Received: VM=$($data.vmname), Cluster=$($data.pE_IP)"

# Configuration
$ClusterIP = $data.pE_IP
$VMName = $data.vmname
$CPUs = [int]$data.CPU_size
$MemoryMB = [int]$data.mem_size * 1024
$Delay = [int]$data.delay_mins

# 1. Load Nutanix Module (Using full path if necessary)
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Write-Host "Loading Nutanix Snapin..."
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

# 2. Connect to Cluster
Write-Host "Connecting to Cluster $ClusterIP..."
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

# 3. Find VM
Write-Host "Looking for VM $VMName..."
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
if (-not $VM) {
    Write-Error "VM $VMName NOT FOUND on cluster $ClusterIP."
    Disconnect-NTNXCluster -Servers $ClusterIP
    exit 1
}

# 4. Handle Delay
if ($Delay -gt 0) {
    Write-Host "Waiting $Delay minutes..."
    Start-Sleep -Seconds ($Delay * 60)
}

# 5. Shutdown and Resize
Write-Host "Shutting down VM $VMName (ACPI)..."
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 60

Write-Host "Applying settings: $CPUs CPU, $($data.mem_size)GB RAM..."
Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $CPUs -MemoryMb $MemoryMB -ErrorAction Stop | Out-Null

Write-Host "Powering on VM..."
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

# 6. Success
Disconnect-NTNXCluster -Servers $ClusterIP | Out-Null
Write-Host "SUCCESS: Compute resize completed."
