param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# 1. Load Nutanix Module (Mandatory)
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Write-Host "Loading Nutanix Snapin..."
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

# 2. Connect to Cluster
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Write-Host "Connecting to Cluster: $($data.pE_IP)..."
Connect-NTNXCluster -Server $data.pE_IP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $data.vmname }
if (-not $VM) { 
    Write-Host "VM $($data.vmname) not found. Available VMs:" -ForegroundColor Red
    Get-NTNXVM | Select-Object -ExpandProperty vmName
    Disconnect-NTNXCluster -Servers $data.pE_IP
    exit 1 
}

# 3. STORAGE: Independent Action (API-based, No Plink/SSH)
try {
    if ($data.disk_action -eq "add" -and [int]$data.size_gb -gt 0) {
        Write-Host "Adding disk of $($data.size_gb) GB..."
        $diskSizeBytes = [Int64]$data.size_gb * 1024 * 1024 * 1024
        # Native cmdlet: no SSH required
        New-NTNXVirtualDisk -Vmid $VM.uuid -DiskSize $diskSizeBytes -ErrorAction Stop | Out-Null
        Write-Host "Storage Success." -ForegroundColor Green
    }
} catch {
    Write-Host "Storage Action Failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# 4. COMPUTE: Independent Action
try {
    if ($data.delay_mins -gt 0) { Start-Sleep -Seconds ($data.delay_mins * 60) }
    
    Write-Host "Shutting down VM $($data.vmname)..."
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 60

    Write-Host "Updating Compute: $($data.CPU_size) CPU, $($data.mem_size) GB RAM..."
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus ([int]$data.CPU_size) -MemoryMb ([int]$data.mem_size * 1024) -ErrorAction Stop | Out-Null

    Write-Host "Powering on VM..."
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null
    Write-Host "Compute Resize Success." -ForegroundColor Green
} catch {
    Write-Host "Compute Action Failed: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Disconnect-NTNXCluster -Servers $data.pE_IP -ErrorAction SilentlyContinue | Out-Null
}
