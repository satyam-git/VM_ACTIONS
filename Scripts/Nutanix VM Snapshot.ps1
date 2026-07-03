param($JsonInputs)
Write-Output "--- NUTANIX AUTOMATION DEBUG LOGS ---"

# Support both parameter passing and direct environment variable reading for maximum robustness
$rawJson = $JsonInputs
if (-not $rawJson -or $rawJson.Trim() -eq "") {
    if ($env:INPUTS_JSON -and $env:INPUTS_JSON.Trim() -ne "") {
        $rawJson = $env:INPUTS_JSON
    }
}

Write-Output "Raw JSON input received: $rawJson"
$data = $rawJson | ConvertFrom-Json

$siteMap = @{
    "Bangalore" = "192.168.136.50"
    "Pune"      = "10.0.0.20"
    "Chennai"   = "10.0.0.10"
}

$siteName = [string]$data.s1
$vmInput = [string]$data.v1
$op = [string]$data.op # 1=Create, 2=Delete, 3=Restore
$snapInput = [string]$data.sn1
$delayInput = [string]$data.d1

if (-not $siteMap.ContainsKey($siteName)) {
    throw "Site '$siteName' not found in mapping. Available: $($siteMap.Keys -join ', ')"
}
$siteIp = $siteMap[$siteName]

# ---------- Parse VM list (Ensures collection is always an array) ----------
$vmNames = @()
if ($vmInput -and $vmInput.Trim() -ne "") {
    $vmNames = @($vmInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}
if ($vmNames.Count -eq 0) {
    throw "No VM names provided."
}

# ---------- Expand Snapshot Names ----------
$snapNames = @()
if ($snapInput -and $snapInput.Trim() -ne "") {
    $tempSnaps = @($snapInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        if ($i -lt $tempSnaps.Count) { $snapNames += $tempSnaps[$i] }
        else { $snapNames += $tempSnaps[-1] }
    }
} else {
    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        $snapNames += "$($vmNames[$i])-snapshot"
    }
}

# ---------- Expand Delays ----------
$delays = @()
if ($delayInput -and $delayInput.Trim() -ne "") {
    $tempDelays = @($delayInput.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | ForEach-Object { [int]$_ })
    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        if ($i -lt $tempDelays.Count) { $delays += $tempDelays[$i] }
        else { $delays += $tempDelays[-1] }
    }
} else {
    # Default to 20 seconds delay if empty
    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        $delays += 20
    }
}

# ---------- Optional: cap delays ----------
$MAX_DELAY_SECONDS = 3600
for ($i = 0; $i -lt $delays.Count; $i++) {
    if ($delays[$i] -gt $MAX_DELAY_SECONDS) {
        Write-Warning "Delay of $($delays[$i]) seconds exceeds cap of $MAX_DELAY_SECONDS. Capping to $MAX_DELAY_SECONDS."
        $delays[$i] = $MAX_DELAY_SECONDS
    }
}

# ---------- Print schedule ----------
Write-Output "`n===== Schedule (parallel jobs) ====="
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    Write-Output "$($vmNames[$i]) : Snapshot=$($snapNames[$i]), Delay=$($delays[$i]) sec"
}
Write-Output "Start time: $(Get-Date -Format 'HH:mm:ss')`n"

# ---------- Define the job script block ----------
$snapshotJob = {
    param($siteIp, $user, $pass, $vmName, $snapName, $op, $delay)
    
    function Write-Log($msg) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Output "[$timestamp] [VM: $vmName] $msg"
    }
    
    Write-Log "Background worker initialized. Site IP: $siteIp, Action Op: $op, Delay: $delay sec"

    # Load Nutanix Cmdlets if they aren't already loaded in the job context
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        try {
            Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
        } catch {
            Write-Error "Failed to load Nutanix snap-in inside background job: $($_.Exception.Message)"
            return
        }
    }

    $delaySec = [int]$delay
    if ($delaySec -gt 0) {
        Write-Log "Delaying execution by $delaySec seconds..."
        Start-Sleep -Seconds $delaySec
        Write-Log "Delay completed. Resuming operation."
    } else {
        Write-Log "Starting execution immediately."
    }

    try {
        Write-Log "Connecting to Prism Element on $siteIp..."
        $creds = New-Object System.Security.SecureString
        foreach ($char in $pass.ToCharArray()) { $creds.AppendChar($char) }
        $creds.MakeReadOnly()

        Connect-NTNXCluster -Server $siteIp -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        Write-Log "Connected successfully."

        Write-Log "Locating target VM..."
        $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$vmName' was not found on cluster."
        }
        Write-Log "VM found with UUID: $($vm.uuid). PowerState: $($vm.powerState)"

        switch ($op) {
            "1" { # CREATE
                Write-Log "Creating snapshot '$snapName'..."
                $spec = New-NTNXObject -Name SnapshotSpecDTO
                $spec.vmUuid = $vm.uuid
                $spec.snapshotName = $snapName
                New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
                Write-Log "SUCCESS: Created snapshot '$snapName'"
            }
            "2" { # DELETE
                Write-Log "Searching for snapshot '$snapName'..."
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { throw "Snapshot '$snapName' not found." }
                Write-Log "Deleting snapshot '$snapName'..."
                Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Log "SUCCESS: Deleted snapshot '$snapName'"
            }
            "3" { # RESTORE
                Write-Log "Searching for snapshot '$snapName'..."
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { throw "Snapshot '$snapName' not found." }

                if ($vm.powerState -eq "ON") {
                    Write-Log "VM is currently powered ON. Initiating ACPI graceful shutdown..."
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                    
                    $isOff = $false
                    # Try up to 10 shutdown verification cycles (30s interval each)
                    for($attempt = 1; $attempt -le 10; $attempt++) {
                        Write-Log "Waiting 30 seconds to validate VM power status (Attempt $attempt/10)..."
                        Start-Sleep -Seconds 30
                        
                        $checkVm = Get-NTNXVM -Vmid $vm.uuid
                        if ($checkVm.powerState -eq "OFF") { 
                            $isOff = $true
                            Write-Log "VM shutdown validated. PowerState is OFF."
                            break 
                        }
                        
                        if ($attempt -lt 10) {
                            Write-Log "VM is still ON. Re-triggering ACPI graceful shutdown..."
                            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                        }
                    }
                    if (-not $isOff) { throw "VM failed to shut down after multiple ACPI graceful shutdown triggers." }
                }

                Write-Log "Waiting 60 seconds to allow the hypervisor to release disk locks..."
                Start-Sleep -Seconds 60

                Write-Log "Restoring VM state from snapshot '$snapName'..."
                Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Log "Reverted block-storage states cleanly."

                Write-Log "Powering VM back ON..."
                Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
                Write-Log "SUCCESS: Restore completed and powered ON successfully."
            }
        }
    } catch {
        Write-Error "CRITICAL FAILURE: $($_.Exception.Message)"
    } finally {
        Disconnect-NTNXCluster -Servers * -ErrorAction SilentlyContinue
    }
}

# ---------- Start a background job for each VM ----------
$jobs = @()
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $job = Start-Job -ScriptBlock $snapshotJob -ArgumentList `
        $siteIp, `
        $env:PE_USER, `
        $env:PE_PASS, `
        $vmNames[$i], `
        $snapNames[$i], `
        $op, `
        $delays[$i]
    $jobs += $job
}

# ---------- Wait for all jobs to complete ----------
Write-Output "`nWaiting for all snapshot jobs to finish..."
$jobs | Wait-Job | Out-Null

# ---------- Receive output from each job ----------
for ($i = 0; $i -lt $jobs.Count; $i++) {
    $job = $jobs[$i]
    $vmName = $vmNames[$i]
    Write-Output "`n======================================================================"
    Write-Output "LOG STREAM: VM '$vmName'"
    Write-Output "======================================================================"
    Receive-Job $job
    Remove-Job $job
}

Write-Output "`n===== All VMs processed. ====="
