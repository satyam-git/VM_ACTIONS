param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
# Update this path to the actual location of plink.exe on your runner server
$plinkPath = "C:\Automation\Tools\plink.exe"
$fingerprint = "ecdsa-sha2-nistp521@521:q5ZpuCn0QBx0/c7ZDam/Wc/xVkgIOJmSwnD9stm4mQg"

# --- PASS 1: STORAGE (ACLI via Plink) ---
Write-Host "--- Starting Storage Pass ---" -ForegroundColor Cyan
if ($data.disk_action -eq "add") {
    try {
        $AcliCmd = "acli vm.disk_create '$($data.vmname)' container='default-container' create_size='$($data.size_gb)G'"
        
        # Use -hostkey to bypass the "host key not cached" error
        # Use -batch to prevent the prompt
        $args = @("-batch", "-ssh", "-hostkey", $fingerprint, "-pw", $env:PE_PASS, "$($env:PE_USER)@$($data.pE_IP)", $AcliCmd)
        
        Write-Host "Executing Plink..."
        $proc = Start-Process -FilePath $plinkPath -ArgumentList $args -Wait -PassThru -NoNewWindow
        
        if ($proc.ExitCode -eq 0) {
            Write-Host "Storage Success" -ForegroundColor Green
        } else {
            Write-Host "Storage Failed with Exit Code: $($proc.ExitCode)" -ForegroundColor Red
        }
    } catch {
        Write-Host "Storage catch error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- PASS 2: COMPUTE (Your working code) ---
Write-Host "--- Starting Compute Pass ---" -ForegroundColor Cyan
# Load Nutanix Modules (Ensure these are installed on the runner)
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null }
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $data.pE_IP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $data.vmname }
if ($VM) {
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 60
    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus ([int]$data.CPU_size) -MemoryMb ([int]$data.mem_size * 1024) -ErrorAction Stop | Out-Null
    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null
    Write-Host "Compute Success" -ForegroundColor Green
}
Disconnect-NTNXCluster -Servers $data.pE_IP -ErrorAction SilentlyContinue | Out-Null
