param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Load Nutanix Modules
$snapin = "NutanixCmdletsPSSnapin"
if (-not (Get-PSSnapin -Name $snapin -ErrorAction SilentlyContinue)) { Add-PSSnapin $snapin }

# Connect
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $data.pE_IP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $data.vmname }

# --- STORAGE PASS ---
Write-Host "--- Starting Storage Pass ---"
if ($data.disk_action -eq "add") {
    try {
        # Check if the disk command exists
        if (Get-Command "New-NTNXVirtualDisk" -ErrorAction SilentlyContinue) {
            $sizeBytes = [Int64]$data.size_gb * 1024 * 1024 * 1024
            New-NTNXVirtualDisk -Vmid $VM.uuid -DiskSize $sizeBytes -ErrorAction Stop
            Write-Host "Storage Success." -ForegroundColor Green
        } else {
            Write-Warning "New-NTNXVirtualDisk command not found in your installed modules."
            Write-Host "Available disk commands: $(Get-Command *Disk* | Select-Object -ExpandProperty Name | Out-String)"
        }
    } catch {
        Write-Error "Storage Failed: $($_.Exception.Message)"
    }
}

# --- COMPUTE PASS ---
Write-Host "--- Starting Compute Pass ---"
try {
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 60
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus ([int]$data.CPU_size) -MemoryMb ([int]$data.mem_size * 1024) -ErrorAction Stop
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop
    Write-Host "Compute Success." -ForegroundColor Green
} catch {
    Write-Error "Compute Failed: $($_.Exception.Message)"
} finally {
    Disconnect-NTNXCluster -Servers $data.pE_IP -ErrorAction SilentlyContinue
}
