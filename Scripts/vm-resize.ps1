param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# --- CONNECTION ---
$base64Auth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($env:PE_USER):$($env:PE_PASS)"))
$headers = @{ "Authorization" = "Basic $base64Auth"; "Content-Type" = "application/json" }
$urlBase = "https://$($data.pE_IP):9440/api/nutanix/v3"

# Bypass SSL certificates for internal API requests
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

# --- 1. FIND VM ---
Write-Host "Finding VM: $($data.vmname)..."
$vmList = Invoke-RestMethod -Uri "$urlBase/vms/list" -Method Post -Headers $headers -Body '{"kind":"vm"}'
$vm = ($vmList.entities | Where-Object { $_.spec.name -eq $data.vmname } | Select-Object -First 1)

if (-not $vm) { Write-Error "VM '$($data.vmname)' not found."; exit 1 }
$vmUuid = $vm.metadata.uuid
$currentVm = Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Get -Headers $headers

# --- 2. STORAGE (Add Disk) ---
if ($data.disk_action -eq "add") {
    Write-Host "Adding disk of $($data.size_gb) GB..."
    $diskBytes = [Int64]$data.size_gb * 1024 * 1024 * 1024
    
    # Calculate next device_index
    $maxIndex = 0
    foreach ($d in $currentVm.spec.resources.disk_list) {
        if ($d.device_properties.disk_address.device_index -gt $maxIndex) { 
            $maxIndex = $d.device_properties.disk_address.device_index 
        }
    }
    
    $newDisk = @{ 
        device_properties = @{ device_type = "DISK"; disk_address = @{ adapter_type = "SCSI"; device_index = ($maxIndex + 1) } }; 
        disk_size_bytes = $diskBytes 
    }
    $currentVm.spec.resources.disk_list += $newDisk
    Write-Host "Disk prepared at index $($maxIndex + 1)."
}

# --- 3. COMPUTE (Resize) ---
Write-Host "Setting CPU to $($data.CPU_size) and RAM to $($data.mem_size) GB..."
$currentVm.spec.resources.num_vcpus = [int]$data.CPU_size
$currentVm.spec.resources.memory_size_mib = [int]$data.mem_size * 1024

# --- 4. APPLY CHANGES ---
$body = @{ spec = $currentVm.spec; api_version = "3.1"; metadata = $currentVm.metadata } | ConvertTo-Json -Depth 10
Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Put -Headers $headers -Body $body

Write-Host "Operation Success: VM $($data.vmname) updated." -ForegroundColor Green
