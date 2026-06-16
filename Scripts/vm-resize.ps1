param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# 1. Connect to Cluster
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { 
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null 
}

Write-Host "Connecting to Cluster: $($data.pE_IP)..."
Connect-NTNXCluster -Server $data.pE_IP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $data.vmname }
if (-not $VM) { Write-Error "VM $($data.vmname) not found."; exit 1 }

# 2. Storage Actions (Native Cmdlets only - No Plink/ACLI)
if ($data.disk_action -eq "add") {
    Write-Host "Adding disk of $($data.size) GB..."
    # Convert GB to Bytes using [Int64] to prevent overflow errors
    $diskSizeBytes = [Int64]$data.size * 1024 * 1024 * 1024
    New-NTNXVirtualDisk -Vmid $VM.uuid -DiskSize $diskSizeBytes -ErrorAction Stop | Out-Null
    Write-Host "Disk added successfully."
}

# 3. Compute Actions
if ($data.delay_mins -gt 0) { 
    Write-Host "Delaying for $($data.delay_mins) minutes..."
    Start-Sleep -Seconds ($data.delay_mins * 60) 
}

Write-Host "Shutting down VM $($data.vmname)..."
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 60

Write-Host "Resizing VM: $($data.CPU_size) CPU, $($data.mem_size) GB RAM..."
Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus ([int]$data.CPU_size) -MemoryMb ([int]$data.mem_size * 1024) -ErrorAction Stop | Out-Null

Write-Host "Powering on VM..."
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

# 4. Cleanup
Disconnect-NTNXCluster -Servers $data.pE_IP | Out-Null
Write-Host "Resize Completed Successfully."
