param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# --- CONNECTION SETUP ---
$base64Auth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($env:PE_USER):$($env:PE_PASS)"))
$headers = @{ "Authorization" = "Basic $base64Auth"; "Content-Type" = "application/json" }
$urlBase = "https://$($data.pE_IP):9440/api/nutanix/v3"

# PowerShell 7: SSL Bypass
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

# --- 1. FIND VM ---
Write-Host "Finding VM: $($data.vmname)..."
$vmList = Invoke-RestMethod -Uri "$urlBase/vms/list" -Method Post -Headers $headers -Body '{"kind":"vm"}'
$vm = ($vmList.entities | Where-Object { $_.spec.name -eq $data.vmname } | Select-Object -First 1)

if (-not $vm) { Write-Error "VM not found."; exit 1 }
$vmUuid = $vm.metadata.uuid
$currentVm = Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Get -Headers $headers

# --- 2. STORAGE ---
if ($data.disk_action -eq "add") {
    Write-Host "Adding disk..."
    $diskBytes = [Int64]$data.size_gb * 1024 * 1024 * 1024
    
    # Auto-calculate next index
    $maxIndex = 0
    foreach ($d in $currentVm.spec.resources.disk_list) {
        if ($d.device_properties.disk_address.device_index -gt $maxIndex) { $maxIndex = $d.device_properties.disk_address.device_index }
    }
    
    $newDisk = @{ 
        device_properties = @{ device_type = "DISK"; disk_address = @{ adapter_type = "SCSI"; device_index = ($maxIndex + 1) } }; 
        disk_size_bytes = $diskBytes 
    }
    $currentVm.spec.resources.disk_list += $newDisk
    Write-Host "Storage ready at index $($maxIndex + 1)."
}

# --- 3. COMPUTE ---
Write-Host "Updating Compute..."
$currentVm.spec.resources.num_vcpus = [int]$data.CPU_size
$currentVm.spec.resources.memory_size_mib = [int]$data.mem_size * 1024

# --- 4. APPLY CHANGES ---
$body = @{ spec = $currentVm.spec; api_version = "3.1"; metadata = $currentVm.metadata } | ConvertTo-Json -Depth 10
Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Put -Headers $headers -Body $body
Write-Host "Operation Success: VM resized and disk added." -ForegroundColor Green
