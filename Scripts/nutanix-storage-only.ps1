param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# --- CONNECTION MAPPING ---
$siteMap = @{
    "Banglore" = "192.168.136.50"
    "Chennai"  = "10.0.0.10"
}

# --- INITIALIZATION ---
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { 
    Add-PSSnapin NutanixCmdletsPSSnapin 
}

$ip = $siteMap[$data.site]
$creds = $env:NUTANIX_PASS | ConvertTo-SecureString -AsPlainText -Force

try {
    Connect-NTNXCluster -Server $ip -UserName $env:NUTANIX_USER -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
    
    $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $data.vmname } | Select-Object -First 1
    if (-not $vm) { throw "VM '$($data.vmname)' not found." }

    # --- STORAGE ACTION ---
    if ($data.disk_action -eq "add") {
        $vmId = ($vm.vmid -split ':')[-1]
        
        $diskCreateSpec = New-NTNXObject -Name VmDiskSpecCreateDTO
        $diskCreateSpec.sizeMb = [int]$data.disksize * 1024

        $vmDisk = New-NTNXObject -Name VMDiskDTO
        $vmDisk.vmDiskCreate = $diskCreateSpec

        Add-NTNXVMDisk -Vmid $vmId -Disks $vmDisk
        Write-Host "Success: Added $($data.disksize)GB disk to $($data.vmname)." -ForegroundColor Green
    }
}
catch {
    Write-Error "Storage operation failed: $($_.Exception.Message)"
    exit 1
}
finally {
    Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue
}
