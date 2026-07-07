param($JsonInputs)
Write-Output "--- NUTANIX AUTOMATION DEBUG LOGS ---"

$rawJson = $JsonInputs
if (-not $rawJson -or $rawJson.Trim() -eq "") {
    if ($env:INPUTS_JSON -and $env:INPUTS_JSON.Trim() -ne "") {
        $rawJson = $env:INPUTS_JSON
    }
}

$data = $rawJson | ConvertFrom-Json
$siteMap = @{ "Bangalore" = "192.168.136.50"; "Pune" = "10.0.0.20"; "Chennai" = "10.0.0.10" }
$siteName = [string]$data.s1
$vmInput = [string]$data.v1
$op = [string]$data.op
$snapInput = [string]$data.sn1
$delayInput = [string]$data.d1

$vmNames = @($vmInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
$snapNames = @($snapInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })

$delayMinutes = [System.Collections.Generic.List[int]]::new()
if ($delayInput -and $delayInput.Trim() -ne "") {
    $parts = $delayInput.Split(",")
    foreach ($part in $parts) {
        $trimmed = $part.Trim()
        if ($trimmed -ne "" -and [int]::TryParse($trimmed, [ref]$null)) {
            [void]$delayMinutes.Add([int]$trimmed)
        }
    }
}

$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
try { $iss.ImportPSSnapIn("NutanixCmdletsPSSnapin", [ref]$null) } catch { }

$workerBlock = {
    param($siteIp, $user, $pass, $vmName, $snapName, $op, $delayMinutes)
    function Write-Log($msg) { Write-Output "[$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))] [VM: $vmName] $msg" }
    
    Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue
    $delaySec = $delayMinutes * 60
    if ($delaySec -gt 0) { Start-Sleep -Seconds $delaySec }
    
    $workerStatus = "Successful"
    $errorMessage = ""
    try {
        $creds = ConvertTo-SecureString $pass -AsPlainText -Force
        Connect-NTNXCluster -Server $siteIp -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
        if (-not $vm) { throw "VM '$vmName' was not found on cluster." }

        if ($op -eq "1") { 
            $spec = New-NTNXObject -Name SnapshotSpecDTO
            $spec.vmUuid = $vm.uuid; $spec.snapshotName = $snapName
            New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
        }
        # Add additional logic for op 2 and 3 as per your original file
    } catch {
        $workerStatus = "failed"; $errorMessage = $_.Exception.Message
    } finally {
        Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
        [PSCustomObject]@{"VM Name" = $vmName; "Snapshot Name" = $snapName; "Action" = $op; "Status" = $workerStatus; "Error" = $errorMessage}
    }
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, $vmNames.Count, $iss, $Host)
$pool.Open()
$runspaces = foreach ($i in 0..($vmNames.Count - 1)) {
    $vmName = $vmNames[$i]
    $snapName = if ($i -lt $snapNames.Count) { $snapNames[$i] } else { "$vmName-snapshot" }
    $delayMin = if ($i -lt $delayMinutes.Count) { $delayMinutes[$i] } else { 0 }
    
    $ps = [PowerShell]::Create().RunspacePool = $pool
    $ps.AddCommand("Invoke-Command").AddParameter("ScriptBlock", $workerBlock).AddParameter("ArgumentList", @($siteMap[$siteName], $env:PE_USER, $env:PE_PASS, $vmName, $snapName, $op, $delayMin))
    [PSCustomObject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke(); VMName = $vmName }
}

while ($runspaces.Handle.IsCompleted -contains $false) { Start-Sleep -Seconds 1 }
$resultsList = $runspaces.ForEach({ $_.PowerShell.EndInvoke($_.Handle) })
$pool.Dispose()

# Summary Logic for GITHUB_STEP_SUMMARY
if ($env:GITHUB_STEP_SUMMARY) {
    $table = "| VM Name | Snapshot Name | Action | Status |`n|---|---|---|---|`n"
    $resultsList | ForEach-Object { $table += "| $($_.'VM Name') | $($_. 'Snapshot Name') | $($_.Action) | $($_.Status) |`n" }
    $table | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
}
