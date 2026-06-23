param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Log inputs for debugging
Write-Host "Inputs Received: VM=$($data.vmname), Cluster=$($data.pE_IP)"

# Configuration
$ClusterIP = $data.pE_IP
$VMName = $data.vmname
$CPUs = [int]$data.CPU_size
$MemoryMB = [int]$data.mem_size * 1024
$Delay = [int]$data.delay_mins

# 1. Load Nutanix Module
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Write-Host "Loading Nutanix Snapin..."
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

# 2. Connect to Cluster
Write-Host "Connecting to Cluster $ClusterIP..."
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

# 3. Find VM
Write-Host "Looking for VM $VMName..."
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
if (-not $VM) {
    Write-Error "VM $VMName NOT FOUND on cluster $ClusterIP."
    Disconnect-NTNXCluster -Servers $ClusterIP
    exit 1
}

# 4. Handle Delay (New Feature)
if ($Delay -gt 0) {
    Write-Host "Delay set to $Delay minutes. Sleeping..."
    Start-Sleep -Seconds ($Delay * 60)
}

# 5. Shutdown Logic (Two-Strike Rule)
function Invoke-TwoStrikeShutdown {
    param($VMObj)
    Write-Host "Attempt 1: Initiating ACPI Shutdown..."
    Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    
    Start-Sleep -Seconds 40
    
    # Refresh VM object to check power state
    $CurrentVM = Get-NTNXVM -Vmid $VMObj.uuid
    if ($CurrentVM.powerState -eq "ON") {
        Write-Host "VM still ON. Attempt 2: Initiating ACPI Shutdown again..."
        Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 20 # Wait a moment for final shutdown
    } else {
        Write-Host "VM confirmed down."
    }
}

Invoke-TwoStrikeShutdown -VMObj $VM

# 6. Resize
Write-Host "Applying settings: $CPUs CPU, $($data.mem_size)GB RAM..."
Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $CPUs -MemoryMb $MemoryMB -ErrorAction Stop | Out-Null

Write-Host "Powering on VM..."
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

# 7. Success
Disconnect-NTNXCluster -Servers $ClusterIP | Out-Null
Write-Host "SUCCESS: Compute resize completed."
