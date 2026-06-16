param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# 1. Setup Cluster Connection
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { 
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null 
}

$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Write-Host "Connecting to Cluster: $($data.pE_IP)..."
Connect-NTNXCluster -Server $data.pE_IP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null

# 2. Get VM
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $data.vmname }
if (-not $VM) { Write-Error "VM $($data.vmname) not found."; exit 1 }

# 3. STORAGE: Independent Execution
try {
    if ($data.disk_action -eq "add") {
        Write-Host "Adding disk of $($data.size_gb) GB..."
        $diskSizeBytes = [Int64]$data.size_gb * 1024 * 1024 * 1024
        # Using native cmdlet instead of plink/acli
        New-NTNXVirtualDisk -Vmid $VM.uuid -DiskSize $diskSizeBytes -ErrorAction Stop | Out-Null
        Write-Host "Storage Action Success." -ForegroundColor Green
    }
} catch {
    Write-Host "Storage Action Failed: $($_.Exception.Message)" -ForegroundColor Red
}

# 4. COMPUTE: Independent Execution
try {
    if ($data.delay_mins -gt 0) { Start-Sleep -Seconds ($data.delay_mins * 60) }
    
    Write-Host "Shutting down VM for resize..."
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
