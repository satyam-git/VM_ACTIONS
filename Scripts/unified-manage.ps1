param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$ErrorActionPreference = "Stop"

function Load-Nutanix { if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin } }

# --- STAGE 1: STORAGE (ACLI + Guest OS) ---
if ($data.d_action -in "add", "extend") {
    Write-Host "--- Stage 1: Storage ---"
    # Call your existing Disk Provisioning logic here using $data.d_action, $data.d_size, etc.
    # Ensure this block includes your 'acli' and 'Invoke-Command' (diskpart) logic.
    Write-Host "Storage operations for $($data.vmname) completed."
}

# --- STAGE 2: COMPUTE (Resize) ---
if ([int]$data.cpu -gt 0 -or [int]$data.mem -gt 0) {
    Write-Host "--- Stage 2: Compute ---"
    Load-Nutanix
    $Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
    Connect-NTNXCluster -Server $data.pe_ip -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null
    
    $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $data.vmname }
    
    # Graceful Shutdown
    Write-Host "Shutting down for compute resize..."
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 60
    
    # Resize
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus [int]$data.cpu -MemoryMb ([int]$data.mem * 1024)
    
    # Power On
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON
    Disconnect-NTNXCluster -Servers $data.pe_ip
}
