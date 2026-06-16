param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# 1. Connect
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null }
Connect-NTNXCluster -Server $data.pE_IP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

# 2. Find VM with Debugging
$AllVMs = Get-NTNXVM
$VM = $AllVMs | Where-Object { $_.vmName -eq $data.vmname }

if (-not $VM) {
    Write-Host "ERROR: VM '$($data.vmname)' NOT FOUND." -ForegroundColor Red
    Write-Host "Available VMs on cluster:"
    $AllVMs | Select-Object -ExpandProperty vmName | Sort-Object
    Disconnect-NTNXCluster -Servers $data.pE_IP
    exit 1
}

# 3. Storage Actions (Native Cmdlets only)
if ($data.disk_action -eq "add") {
    $diskSizeBytes = [Int64]$data.size * 1024 * 1024 * 1024
    New-NTNXVirtualDisk -Vmid $VM.uuid -DiskSize $diskSizeBytes -ErrorAction Stop | Out-Null
    Write-Host "Disk added successfully."
}

# 4. Compute Actions
if ($data.delay_mins -gt 0) { Start-Sleep -Seconds ($data.delay_mins * 60) }
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 60
Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus ([int]$data.CPU_size) -MemoryMb ([int]$data.mem_size * 1024) -ErrorAction Stop | Out-Null
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

Disconnect-NTNXCluster -Servers $data.pE_IP | Out-Null
Write-Host "Resize Completed Successfully."
