param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# --- CONNECTION ---
$base64Auth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($env:PE_USER):$($env:PE_PASS)"))
$headers = @{ "Authorization" = "Basic $base64Auth"; "Content-Type" = "application/json" }
$urlBase = "https://$($data.pE_IP):9440/api/nutanix/v3"
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

# --- 1. FIND VM ---
$vmList = Invoke-RestMethod -Uri "$urlBase/vms/list" -Method Post -Headers $headers -Body '{"kind":"vm"}'
$vm = ($vmList.entities | Where-Object { $_.spec.name -eq $data.vmname } | Select-Object -First 1)
if (-not $vm) { Write-Error "VM not found"; exit 1 }

$vmUuid = $vm.metadata.uuid
$currentVm = Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Get -Headers $headers

# --- 2. PREPARE PAYLOAD ---
$spec = $currentVm.spec
# Add CPU/RAM
$spec.resources.num_vcpus = [int]$data.CPU_size
$spec.resources.memory_size_mib = [int]$data.mem_size * 1024

# Add Disk if needed
if ($data.disk_action -eq "add") {
    $diskBytes = [Int64]$data.size_gb * 1024 * 1024 * 1024
    $maxIndex = 0
    foreach ($d in $spec.resources.disk_list) {
        if ($d.device_properties.disk_address.device_index -gt $maxIndex) { $maxIndex = $d.device_properties.disk_address.device_index }
    }
    
    $newDisk = @{ 
        device_properties = @{ device_type = "DISK"; disk_address = @{ adapter_type = "SCSI"; device_index = ($maxIndex + 1) } }; 
        disk_size_bytes = $diskBytes 
    }
    $spec.resources.disk_list += $newDisk
}

# --- 3. APPLY CHANGES ---
# We use a hash table and convert to JSON to ensure the structure is perfect
$body = @{
    spec = $spec
    metadata = @{ kind = "vm"; uuid = $vmUuid; project_reference = $currentVm.metadata.project_reference }
    api_version = "3.1"
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Put -Headers $headers -Body $body
Write-Host "Success: VM Updated." -ForegroundColor Green
