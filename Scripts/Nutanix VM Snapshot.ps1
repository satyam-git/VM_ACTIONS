param($JsonInputs)
$rawJson = $JsonInputs
if (-not $rawJson) { $rawJson = $env:INPUTS_JSON }
$data = $rawJson | ConvertFrom-Json

$siteMap = @{ "Bangalore" = "192.168.136.50"; "Pune" = "10.0.0.20"; "Chennai" = "10.0.0.10" }
$siteName = [string]$data.s1
$vmNames = $data.v1.Split(",") | ForEach-Object { $_.Trim() }
$snapNames = $data.sn1.Split(",") | ForEach-Object { $_.Trim() }
$delays = $data.d1.Split(",") | ForEach-Object { [int]$_.Trim() }

$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.ImportPSSnapIn("NutanixCmdletsPSSnapin", [ref]$null)

$workerBlock = {
    param($siteIp, $user, $pass, $vmName, $snapName, $op, $delay)
    
    # INDEPENDENT DELAY: Executes immediately inside the thread before connection
    Start-Sleep -Seconds [int]$delay
    
    function Write-Log($msg) { Write-Output "[$((Get-Date).ToString('HH:mm:ss'))] [VM: $vmName] $msg" }
    
    Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue
    $creds = ConvertTo-SecureString $pass -AsPlainText -Force
    Connect-NTNXCluster -Server $siteIp -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
    
    $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
    
    switch ($op) {
        "1" { 
            $spec = New-NTNXObject -Name SnapshotSpecDTO; $spec.vmUuid = $vm.uuid; $spec.snapshotName = $snapName
            New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
            Write-Log "SUCCESS: Snapshot Created"
        }
        "3" { 
            if ($vm.powerState -eq "ON") {
                Write-Log "Triggering ACPI Shutdown..."
                Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                for($a=1; $a -le 10; $a++) {
                    Start-Sleep -Seconds 30
                    if ((Get-NTNXVM -Vmid $vm.uuid).powerState -eq "OFF") { break }
                    Write-Log ("Attempt " + $a + ": Still ON, re-triggering...")
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
                }
            }
            Write-Log "Waiting 60s for disk lock release..."
            Start-Sleep -Seconds 60
            $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
            Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
            Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
            Write-Log "SUCCESS: Restore complete"
        }
    }
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, $vmNames.Count, $iss, $Host)
$pool.Open()
$runspaces = foreach ($i in 0..($vmNames.Count-1)) {
    $ps = [PowerShell]::Create().RunspacePool($pool)
    $args = @($siteMap[$siteName], $env:PE_USER, $env:PE_PASS, $vmNames[$i], $snapNames[$i], $data.op, $delays[$i])
    [void]$ps.AddCommand("Invoke-Command").AddParameter("ScriptBlock", $workerBlock).AddParameter("ArgumentList", $args)
    [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke(); VM = $vmNames[$i] }
}
$runspaces | ForEach-Object { $_.PS.EndInvoke($_.Handle); $_.PS.Dispose() }
$pool.Close(); $pool.Dispose()
