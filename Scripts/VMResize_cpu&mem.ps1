param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\resize_log.csv"

$siteMap = @{ "Banglore" = "192.168.136.50"; "Chennai" = "10.0.0.10" }
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }

if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin }

$Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force

for ($i = 1; $i -le 3; $i++) {
    $site = $data.$("s$i")
    $vmNamesRaw = $data.$("v$i")
    $cpu = [int]$data.$("cpu$i")
    $mem = [int]$data.$("mem$i")
    $delayInput = $data.$("d$i")

    if (-not [string]::IsNullOrWhiteSpace($vmNamesRaw) -and $site -ne "None") {
        $vmList = $vmNamesRaw -split ',' | ForEach-Object { $_.Trim() }
        $delayList = if ($delayInput) { $delayInput -split ',' | ForEach-Object { $_.Trim() } } else { @("0") }

        try {
            Connect-NTNXCluster -Server $siteMap[$site] -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
            
            for ($j = 0; $j -lt $vmList.Count; $j++) {
                $vmName = $vmList[$j]
                $vmDelay = if ($j -lt $delayList.Count) { [int]$delayList[$j] } else { [int]$delayList[-1] }
                
                if ($vmDelay -gt 0) { Start-Sleep -Seconds ($vmDelay * 60) }
                
                $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
                if ($VM) {
                    # 2-Strike Shutdown
                    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 45
                    if ((Get-NTNXVM -Vmid $VM.uuid).powerState -eq "ON") { 
                        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue 
                        Start-Sleep -Seconds 20
                    }
                    
                    # Resize & Power On
                    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $cpu -MemoryMb ($mem * 1024) -ErrorAction Stop
                    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON -ErrorAction Stop
                    "$site,$vmName,Success" | Out-File -FilePath $logPath -Append
                }
            }
        } catch { "$site,$vmNamesRaw,Failed" | Out-File -FilePath $logPath -Append }
        finally { Disconnect-NTNXCluster -Servers $siteMap[$site] -ErrorAction SilentlyContinue }
    }
}
