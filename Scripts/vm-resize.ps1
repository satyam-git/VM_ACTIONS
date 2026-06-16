param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$plinkPath = "Z:\sharecenter\New Automation\plink.exe"
$fingerprint = "ecdsa-sha2-nistp521@521:q5ZpuCn0QBx0/c7ZDam/Wc/xVkgIOJmSwnD9stm4mQg"

# --- PASS 1: STORAGE (Independent) ---
try {
    Write-Host "--- Starting Storage Pass ---" -ForegroundColor Cyan
    # (Your existing storage logic here...)
    # REPLACE the plink line with this:
    # & $plinkPath -batch -ssh -hostkey $fingerprint -pw $row.PE_password "$($row.PE_Username)@$($row.cluster_ip)" $AcliCmd
} catch {
    Write-Host "Storage Pass Failed, continuing to Compute..." -ForegroundColor Yellow
}

# --- PASS 2: COMPUTE (Independent) ---
try {
    Write-Host "--- Starting Compute Pass ---" -ForegroundColor Cyan
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null }
    
    $Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
    Connect-NTNXCluster -Server $data.pE_IP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
    
    $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $data.vmname }
    if ($VM) {
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 60
        Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus ([int]$data.CPU_size) -MemoryMb ([int]$data.mem_size * 1024) -ErrorAction Stop | Out-Null
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null
        Write-Host "Compute Resize Success." -ForegroundColor Green
    }
} catch {
    Write-Host "Compute Pass Failed: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Disconnect-NTNXCluster -Servers $data.pE_IP -ErrorAction SilentlyContinue | Out-Null
}
