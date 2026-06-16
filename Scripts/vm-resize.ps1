param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# --- CONNECTION SETUP ---
$base64Auth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($env:PE_USER):$($env:PE_PASS)"))
$headers = @{ "Authorization" = "Basic $base64Auth"; "Content-Type" = "application/json" }
$urlBase = "https://$($data.pE_IP):9440/api/nutanix/v3"

# --- 1. FIND VM ---
$vmList = Invoke-RestMethod -Uri "$urlBase/vms/list" -Method Post -Headers $headers -Body '{"kind":"vm"}' -SkipCertificateCheck
$vm = ($vmList.entities | Where-Object { $_.spec.name -eq $data.vmname } | Select-Object -First 1)

if (-not $vm) { Write-Error "VM $($data.vmname) not found."; exit 1 }
$vmUuid = $vm.metadata.uuid

# --- 2. STORAGE (REST API - NO SSH) ---
if ($data.disk_action -eq "add") {
    Write-Host "Adding disk via API..."
    $diskBytes = [Int64]$data.size_gb * 1024 * 1024 * 1024
    
    # Get current VM spec to modify it
    $currentVm = Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Get -Headers $headers -SkipCertificateCheck
    $spec = $currentVm.spec
    
    # Add new disk to disk_list
    $newDisk = @{ device_properties = @{ device_type = "DISK"; disk_address = @{ adapter_type = "SCSI" } }; disk_size_bytes = $diskBytes }
    $spec.resources.disk_list += $newDisk
    
    $body = @{ spec = $spec; api_version = "3.1"; metadata = $currentVm.metadata } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Put -Headers $headers -Body $body -SkipCertificateCheck
    Write-Host "Storage Added Successfully." -ForegroundColor Green
}

# --- 3. COMPUTE (REST API) ---
Write-Host "Updating Compute..."
$spec.resources.num_vcpus = [int]$data.CPU_size
$spec.resources.memory_size_mib = [int]$data.mem_size * 1024

$body = @{ spec = $spec; api_version = "3.1"; metadata = $currentVm.metadata } | ConvertTo-Json -Depth 10
Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Put -Headers $headers -Body $body -SkipCertificateCheck
Write-Host "Compute Updated Successfully." -ForegroundColor Green
