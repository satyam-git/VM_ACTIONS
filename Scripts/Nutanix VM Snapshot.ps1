param($JsonInputs)
$data = $JsonInputs | ConvertFrom-Json

# Helper to expand values to match VM count
function Expand-Value {
    param([string[]]$vmList, [string]$inputValue, [string]$valueName)
    $vmCount = $vmList.Count
    if ($vmCount -eq 0) { return @() }
    $values = if ([string]::IsNullOrWhiteSpace($inputValue)) { @() } else { $inputValue -split ',' | ForEach-Object { $_.Trim() } }
    if ($values.Count -eq 0) { if ($valueName -eq "Delay") { return @(0) * $vmCount } else { throw "No $valueName provided." } }
    if ($values.Count -eq 1) { return @($values[0]) * $vmCount }
    return $values
}

$vmNames = ($data.v1 -split ',').Trim() | Where-Object { $_ -ne '' }
$snapNames = Expand-Value -vmList $vmNames -inputValue $data.sn1 -valueName "Snapshot Name"
$delays = Expand-Value -vmList $vmNames -inputValue $data.d1 -valueName "Delay"
$op = $data.op # 1=Create, 2=Delete, 3=Restore

$siteMap = @{ "Bangalore" = "192.168.136.50"; "Chennai" = "10.0.0.10"; "Pune" = "10.0.0.20" }
$logPath = Join-Path $env:GITHUB_WORKSPACE "data\snapshot_log.csv"
if (-not (Test-Path "data")) { New-Item -ItemType Directory -Path "data" -Force | Out-Null }

$snapshotJob = {
    param($site, $vmName, $snapName, $op, $delayMin, $user, $pass, $siteMap, $logPath)
    if ($delayMin -gt 0) { Start-Sleep -Seconds ($delayMin * 60) }
    
    Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue
    $creds = ConvertTo-SecureString $pass -AsPlainText -Force
    Connect-NTNXCluster -Server $siteMap[$site] -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
    
    $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
    $status = "Failed"
    try {
        if (-not $vm) { $status = "VM Not Found" }
        else {
            switch ($op) {
                "1" { # Create
                    $spec = New-NTNXObject -Name SnapshotSpecDTO; $spec.vmUuid = $vm.uuid; $spec.snapshotName = $snapName
                    New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
                    $status = "Created"
                }
                "2" { # Delete
                    $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                    Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
                    $status = "Deleted"
                }
                "3" { # Restore
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                    Start-Sleep -Seconds 60
                    $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                    Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ON -ErrorAction Stop | Out-Null
                    $status = "Restored"
                }
            }
        }
    } catch { $status = "Error: $($_.Exception.Message.Split(':')[0])" }
    "$site,$vmName,$snapName,$status" | Out-File -FilePath $logPath -Append -Encoding utf8
}

$jobs = for ($i = 0; $i -lt $vmNames.Count; $i++) {
    Start-Job -ScriptBlock $snapshotJob -ArgumentList $data.s1, $vmNames[$i], $snapNames[$i], $op, [int]$delays[$i], $env:PE_USER, $env:PE_PASS, $siteMap, $logPath
}
$jobs | Wait-Job | Receive-Job
# Summary logic (similar to PS1.txt snippet 70-76) would go here to update $env:GITHUB_STEP_SUMMARY
