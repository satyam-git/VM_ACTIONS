param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\vm_execution_log.csv"

$siteMap = @{
    "Banglore" = "192.168.136.50"
    "Chennai"  = "10.0.0.10"
}

if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }
if (Test-Path $logPath) { Remove-Item $logPath }

# Credentials initialization
$creds = New-Object System.Security.SecureString
foreach ($char in $env:NUTANIX_PASS.ToCharArray()) { $creds.AppendChar($char) }
$creds.MakeReadOnly()

if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) { Add-PSSnapin NutanixCmdletsPSSnapin }

for ($i = 1; $i -le 3; $i++) {
    $v = $data.$("v$i")
    $s = $data.$("s$i")
    $a = $data.$("a$i")
    $d = $data.$("d$i")

    if (-not [string]::IsNullOrWhiteSpace($v) -and $s -ne "None") {
        $ip = $siteMap[$s]
        $vmArray = $v.Split(',').Trim()
        $delayArray = if ($d) { $d.Split(',').Trim() } else { @() }

        try {
            Connect-NTNXCluster -Server $ip -UserName $env:NUTANIX_USER -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
            
            for ($j = 0; $j -lt $vmArray.Count; $j++) {
                $vmName = $vmArray[$j]
                # Delay logic: ఒక్క ఇన్పుట్ ఉంటే అందరికీ వర్తిస్తుంది, లేదంటే ఇండెక్స్ బట్టి వర్తిస్తుంది
                $vmDelay = if ($delayArray.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($delayArray[0])) { [int]$delayArray[0] } `
                           elseif ($j -lt $delayArray.Count) { [int]$delayArray[$j] } else { 0 }
                
                if ($vmDelay -gt 0) { Start-Sleep -Seconds ($vmDelay * 60) }
                
                $vm = Get-NTNXVM | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
                $Status = "failed"
                
                if ($null -eq $vm) { $Status = "VM Not Found" }
                else {
                    switch ($a) {
                        "start" { 
                            if ($vm.powerState -eq "on") { $Status = "already on" } 
                            else { Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON; $Status = "successful" }
                        }
                        "stop" { 
                            if ($vm.powerState -eq "off") { $Status = "already off" } 
                            else { 
                                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN
                                Start-Sleep -Seconds 30
                                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN
                                $Status = "successful"
                            }
                        }
                        "restart" { 
                            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT
                            Start-Sleep -Seconds 30
                            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_REBOOT
                            $Status = "successful"
                        }
                    }
                }
                "$s,$vmName,$a,$Status" | Out-File -FilePath $logPath -Append -Encoding utf8
            }
        } catch {
            "$s,Error,Error,Failed" | Out-File -FilePath $logPath -Append -Encoding utf8
        } finally {
            Disconnect-NTNXCluster -Servers $ip -ErrorAction SilentlyContinue
        }
    }
}
