#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

function Ensure-NutanixModules {
    # Ensure the required module is loaded
    if (-not (Get-Module -Name Nutanix.Cmdlets -ListAvailable)) {
        Write-Error "Nutanix PowerShell module not found on the runner."
        exit 1
    }
    Import-Module Nutanix.Cmdlets
}

function Add-NutanixDisk {
    param($VmName, $SizeGB)
    
    # Locate the VM
    $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1
    if (-not $vm) { throw "VM '$VmName' not found" }

    $vmId = ($vm.vmid -split ':')[-1]
    
    # Define disk creation specifications
    $diskCreateSpec = New-NTNXObject -Name VmDiskSpecCreateDTO
    $diskCreateSpec.sizeMb = [int]$SizeGB * 1024

    $vmDisk = New-NTNXObject -Name VMDiskDTO
    $vmDisk.vmDiskCreate = $diskCreateSpec

    # Execute disk addition
    Add-NTNXVMDisk -Vmid $vmId -Disks $vmDisk
    Write-Host "Success: Added ${SizeGB}GB to '$VmName'" -ForegroundColor Green
}

# --- MAIN EXECUTION ---
Ensure-NutanixModules

# Connect to the cluster using environment variables
$pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
Connect-NTNXCluster -Server $env:PE_IP -UserName $env:PE_USER -Password $pass -AcceptInvalidSSLCerts | Out-Null

try {
    # Strictly handle disk actions; no compute parameters are defined or used here
    if ($env:DISK_ACTION -eq 'add') {
        Add-NutanixDisk -VmName $env:VM_NAME -SizeGB ([int]$env:DISK_SIZE)
    } else {
        Write-Host "No disk action requested." -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Storage operation failed: $($_.Exception.Message)"
    exit 1
}
finally {
    Disconnect-NTNXCluster -Servers $env:PE_IP -ErrorAction SilentlyContinue | Out-Null
}
