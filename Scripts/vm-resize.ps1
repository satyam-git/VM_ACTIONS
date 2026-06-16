param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$plinkPath = "C:\Automation\Tools\plink.exe" 
# Use the fingerprint from your own error log:
$fingerprint = "ecdsa-sha2-nistp521@521:q5ZpuCn0QBx0/c7ZDam/Wc/xVkgIOJmSwnD9stm4mQg"

# --- PASS 1: STORAGE (ACLI via Plink) ---
Write-Host "--- Starting Storage Pass ---" -ForegroundColor Cyan
if ($data.disk_action -in "add", "extend") {
    $AcliCmd = if ($data.disk_action -eq "add") { "acli vm.disk_create '$($data.vmname)' container='default-container' create_size='$($data.size_gb)G'" } 
               else { "acli vm.disk_update '$($data.vmname)' disk_addr='$($data.disk_addr)' new_size='$($data.size_gb)G'" }
    
    # Explicitly using -hostkey to bypass the "host key not cached" error
    $args = @("-batch", "-ssh", "-hostkey", $fingerprint, "-pw", $env:PE_PASS, "$($env:PE_USER)@$($data.pE_IP)", $AcliCmd)
    
    $proc = Start-Process -FilePath $plinkPath -ArgumentList $args -Wait -PassThru -NoNewWindow
    
    if ($proc.ExitCode -eq 0) {
        Write-Host "Storage Action Executed Successfully." -ForegroundColor Green
    } else {
        # This will now appear in your logs if it fails
        Write-Error "STORAGE FAILED! Plink Exit Code: $($proc.ExitCode). Ensure $plinkPath exists and the fingerprint is correct."
    }
}

# --- PASS 2: COMPUTE ---
# (Rest of your working compute code remains exactly the same)
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
