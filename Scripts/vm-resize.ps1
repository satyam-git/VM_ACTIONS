param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# --- CONNECTION SETUP ---
$base64Auth = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($env:PE_USER):$($env:PE_PASS)"))
$headers = @{ "Authorization" = "Basic $base64Auth"; "Content-Type" = "application/json" }
$urlBase = "https://$($data.pE_IP):9440/api/nutanix/v3"

# Fix for older PowerShell: Bypass SSL properly
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

# --- 1. FIND VM ---
Write-Host "Finding VM..."
$vmList = Invoke-RestMethod -Uri "$urlBase/vms/list" -Method Post -Headers $headers -Body '{"kind":"vm"}'
$vm = ($vmList.entities | Where-Object { $_.spec.name -eq $data.vmname } | Select-Object -First 1)

if (-not $vm) { Write-Error "VM $($data.vmname) not found."; exit 1 }
$vmUuid = $vm.metadata.uuid

# --- 2. STORAGE (REST API) ---
if ($data.disk_action -eq "add") {
    Write-Host "Adding disk..."
    $diskBytes = [Int64]$data.size_gb * 1024 * 1024 * 1024
    
    # Get latest spec
    $currentVm = Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Get -Headers $headers
    $spec = $currentVm.spec
    
    # Modify disk list
    $newDisk = @{ device_properties = @{ device_type = "DISK"; disk_address = @{ adapter_type = "SCSI" } }; disk_size_bytes = $diskBytes }
    $spec.resources.disk_list += $newDisk
    
    $body = @{ spec = $spec; api_version = "3.1"; metadata = $currentVm.metadata } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Put -Headers $headers -Body $body
    Write-Host "Storage Success." -ForegroundColor Green
}

# --- 3. COMPUTE (REST API) ---
Write-Host "Updating Compute..."
$spec.resources.num_vcpus = [int]$data.CPU_size
$spec.resources.memory_size_mib = [int]$data.mem_size * 1024

$body = @{ spec = $spec; api_version = "3.1"; metadata = $currentVm.metadata } | ConvertTo-Json -Depth 10
Invoke-RestMethod -Uri "$urlBase/vms/$vmUuid" -Method Put -Headers $headers -Body $body
Write-Host "Compute Success." -ForegroundColor Green
