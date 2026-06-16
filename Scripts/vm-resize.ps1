param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$plinkPath = "C:\Automation\Tools\plink.exe"

# Configuration
$PE_Username = $env:PE_USER
$PE_Password = $env:PE_PASS
$ClusterIP = $data.pE_IP
$VMName = $data.vmname
$CPUS = [int]$data.CPU_size
$MemoryMB = [int]$data.mem_size * 1024
$Delay = [int]$data.delay_mins

# Prepare the ACLI command for compute resources
$AcliCmd = "acli vm.update '$VMName' num_vcpus=$CPUS memory=$MemoryMB"

# Execute via Plink
# -batch: No interactive prompts
# -no-antispoof: Prevents hanging on session start banners
$plinkArgs = @("-batch", "-no-antispoof", "-ssh", "-pw", $PE_Password, "$PE_Username@$ClusterIP", $AcliCmd)

Write-Host "Connecting to $ClusterIP to resize VM $VMName..."
$process = Start-Process -FilePath $plinkPath -ArgumentList $plinkArgs -Wait -PassThru -NoNewWindow

if ($process.ExitCode -eq 0) {
    Write-Host "Compute resources updated successfully."
} else {
    Write-Error "Plink failed with exit code $($process.ExitCode). Ensure the host key is cached for the user running the GitHub Actions service."
    exit 1
}
