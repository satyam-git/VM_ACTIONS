param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Configuration
$ClusterIP = $data.pE_IP
$VMName = $data.vmname
$RequestedCPU = [int]$data.CPU_size
$RequestedMemGB = [int]$data.mem_size
$Delay = [int]$data.delay_mins

# 1. Load Nutanix Module
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

# 2. Connect
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

# 3. Find VM and get current values
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
if (-not $VM) { throw "VM $VMName not found." }

$CurrentCPU = [int]$VM.numVcpus
$CurrentMemGB = [int]($VM.memoryMb / 1024)

# 4. Determine what needs changing (Example 4: 0 = No Change)
$FinalCPU = ($RequestedCPU -gt 0) ? $RequestedCPU : $CurrentCPU
$FinalMemGB = ($RequestedMemGB -gt 0) ? $RequestedMemGB : $CurrentMemGB

$NeedsChange = ($FinalCPU -ne $CurrentCPU -or $FinalMemGB -ne $CurrentMemGB)

# 5. Skip Logic (Example 2 & 3)
if (-not $NeedsChange) {
    Write-Host "Current and requested values are identical (or set to 0). Skipping all actions immediately."
    Disconnect-NTNXCluster -Servers $ClusterIP
    exit 0
}

# 6. Apply Delay only if changes are required
if ($Delay -gt 0) {
    Write-Host "Changes detected. Waiting $Delay minutes as requested..."
    Start-Sleep -Seconds ($Delay * 60)
}

# 7. Two-Strike Shutdown Logic
Write-Host "Initiating shutdown for $VMName..."
function Invoke-TwoStrikeShutdown {
    param($VMObj)
    Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 40
    
    $CurrentVM = Get-NTNXVM -Vmid $VMObj.uuid
    if ($CurrentVM.powerState -eq "ON") {
        Write-Host "VM still ON. Second shutdown attempt..."
        Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 20
    }
}
Invoke-TwoStrikeShutdown -VMObj $VM

# 8. Resize
Write-Host "Applying: $FinalCPU CPU, $FinalMemGB GB RAM."
Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $FinalCPU -MemoryMb ($FinalMemGB * 1024) -ErrorAction Stop | Out-Null

# 9. Power On
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null
Disconnect-NTNXCluster -Servers $ClusterIP
Write-Host "SUCCESS: Resize completed."
