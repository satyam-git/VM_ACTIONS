param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_execution_log.csv"

# Configuration
$siteMap = @{ "Banglore" = "192.168.136.50"; "Chennai" = "10.0.0.10" }
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }

# Load Snapin
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { 
    Add-PSSnapin NutanixCmdletsPSSnapin 
}

# Iterate through the 3 input sets
for ($set = 1; $set -le 3; $set++) {
    $site = $data.$("s$set")
    $vmNames = $data.$("v$set")
    $action = $data.$("a$set")
    $delays = $data.$("d$set")
    
    if (-not $site -or $site -eq "None" -or -not $vmNames) { continue }

    # Split into arrays
    $vmArray = $vmNames.Split(',').Trim()
    $delayArray = if ($delays) { $delays.Split(',').Trim() } else { @() }
    
    $ip = $siteMap[$site]
    $creds = $env:NUTANIX_PASS | ConvertTo-SecureString -AsPlainText -Force
    
    try {
        Connect-NTNXCluster -Server $ip -UserName $env:NUTANIX_USER -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        
        # Process each VM in the array
        for ($i = 0; $i -lt $vmArray.Count; $i++) {
            $vmName = $vmArray[$i]
            $vmDelay = if ($delayArray[$i]) { [int]$delayArray[$i] } else { 0 }
            
            Write-Host "Processing $vmName | Site: $site | Action: $action | Delay: $vmDelay min"
            
            # 1. Apply Delay
            if ($vmDelay -gt 0) { Start-Sleep -Seconds ($vmDelay * 60) }
            
            # 2. Get VM
            $vm = Get-NTNXVM -SearchString $vmName | Select-Object -First 1
            if (-not $vm) { throw "VM $vmName not found" }
            
            # 3. Actions with 2-Strike logic
            $status = "successful"
            switch ($action) {
                "start" { 
                    if ($vm.powerState -eq "off") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON } 
                }
                "stop" {
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN
                    Start-Sleep -Seconds 45
                    if ((Get-NTNXVM -Vmid $vm.uuid).powerState -eq "on") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN }
                }
                "restart" {
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT
                    Start-Sleep -Seconds 45
                    if ((Get-NTNXVM -Vmid $vm.uuid).powerState -ne "on") { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT }
                }
            }
            "$site,$vmName,$action,$status" | Out-File -FilePath $logPath -Append
        }
    } catch {
        Write-Error "Set $set failed: $($_.Exception.Message)"
    } finally {
        Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue | Out-Null
    }
}
