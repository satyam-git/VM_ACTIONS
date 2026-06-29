param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# ---------- Site to Cluster IP mapping ----------
$siteMap = @{
    "Bangalore" = "192.168.136.50"
    "Chennai"   = "10.0.0.10"
    "Pune"      = "10.0.0.20"   # మీరు Pune కి సరైన IP ఇవ్వండి
}

# Read inputs (using the short names)
$siteName = $data.s1
$VMName   = $data.v1
$RequestedCPU   = [int]$data.c1
$RequestedMemGB = [int]$data.m1
$Delay    = [int]$data.d1

# Validate site
if (-not $siteMap.ContainsKey($siteName)) {
    throw "Site '$siteName' not found in mapping. Available: $($siteMap.Keys -join ', ')"
}
$ClusterIP = $siteMap[$siteName]

# 1. Load Nutanix Module (Ensure this is installed on the runner)
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

# 2. Connect to Cluster
$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

# 3. Find VM and get current values
$VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
if (-not $VM) { 
    Disconnect-NTNXCluster -Servers $ClusterIP
    throw "VM $VMName not found." 
}

$CurrentCPU = [int]$VM.numVcpus
$CurrentMemGB = [int]($VM.memoryMb / 1024)

# 4. Determine final values (Treat 0 or empty as "no change")
$FinalCPU = if ($RequestedCPU -gt 0) { $RequestedCPU } else { $CurrentCPU }
$TempMem = if ($RequestedMemGB -gt 0) { $RequestedMemGB } else { $CurrentMemGB }
$FinalMemGB = if ($TempMem -lt 1) { 1 } else { $TempMem }

# 5. Skip Logic (If current matches requested, exit immediately)
if ($FinalCPU -eq $CurrentCPU -and $FinalMemGB -eq $CurrentMemGB) {
    Write-Host "Current and requested values are identical. Skipping resize."
    Disconnect-NTNXCluster -Servers $ClusterIP
    exit 0
}

# 6. Apply Delay (Only if changes are required)
if ($Delay -gt 0) {
    Write-Host "Changes detected. Waiting $Delay minutes..."
    Start-Sleep -Seconds ($Delay * 60)
}

# 7. Two-Strike Shutdown Function
function Invoke-TwoStrikeShutdown {
    param($VMObj)
    Write-Host "Attempt 1: Initiating ACPI Shutdown..."
    Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 40
    
    # Check if VM is actually down
    $CheckVM = Get-NTNXVM -Vmid $VMObj.uuid
    if ($CheckVM.powerState -eq "ON") {
        Write-Host "VM still ON. Attempt 2: Initiating ACPI Shutdown again..."
        Set-NTNXVMPowerState -Vmid $VMObj.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 20
    }
}
Invoke-TwoStrikeShutdown -VMObj $VM

# 8. Resize and Power On
Write-Host "Applying: $FinalCPU CPU, $FinalMemGB GB RAM."
Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $FinalCPU -MemoryMb ($FinalMemGB * 1024) -ErrorAction Stop | Out-Null
Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop | Out-Null

Disconnect-NTNXCluster -Servers $ClusterIP
Write-Host "SUCCESS: Resize completed."
