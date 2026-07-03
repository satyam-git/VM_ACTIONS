param($JsonInputs)
Write-Output "--- NUTANIX AUTOMATION DEBUG LOGS ---"

# ---------- Helper: convert any numeric string to integer (with rounding) ----------
function Convert-ToInteger {
    param([string]$value)
    try {
        $num = [double]$value
        $rounded = [math]::Round($num)
        if ($num -ne $rounded) {
            Write-Warning "Value '$value' is not an integer. It will be rounded to $rounded."
        }
        return [int]$rounded
    } catch {
        throw "Invalid number: '$value'. Please provide an integer (e.g., 20, 40)."
    }
}

# ---------- Helper: expand a single value or a list to match VM count ----------
function Expand-Value {
    param(
        [string[]]$vmList,
        [string]$inputValue,
        [string]$valueName   # e.g., "Delay"
    )
    $vmCount = $vmList.Count
    if ($vmCount -eq 0) { return @() }

    $values = if ([string]::IsNullOrWhiteSpace($inputValue)) {
        @()
    } else {
        $inputValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object {
            Convert-ToInteger -value $_
        }
    }

    if ($values.Count -eq 0) {
        if ($valueName -eq "Delay") {
            return @(0) * $vmCount
        } else {
            throw "No $valueName values provided. Please specify $valueName for each VM."
        }
    }

    if ($values.Count -eq 1) {
        return @($values[0]) * $vmCount
    }

    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) {
        if ($i -lt $values.Count) { $result += $values[$i] }
        else { $result += $values[-1] }
    }
    return $result
}

# ---------- Helper: expand a single string or a list to match VM count ----------
function Expand-StringValue {
    param(
        [string[]]$vmList,
        [string]$inputValue,
        [string]$defaultValueTemplate
    )
    $vmCount = $vmList.Count
    if ($vmCount -eq 0) { return @() }

    $values = if ([string]::IsNullOrWhiteSpace($inputValue)) {
        @()
    } else {
        @($inputValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }

    if ($values.Count -eq 0) {
        $result = @()
        for ($i = 0; $i -lt $vmCount; $i++) {
            $result += $defaultValueTemplate -f $vmList[$i]
        }
        return $result
    }

    if ($values.Count -eq 1) {
        return @($values[0]) * $vmCount
    }

    $result = @()
    for ($i = 0; $i -lt $vmCount; $i++) {
        if ($i -lt $values.Count) { $result += $values[$i] }
        else { $result += $values[-1] }
    }
    return $result
}

# Support both parameter passing and direct environment variable reading for maximum robustness
$rawJson = $JsonInputs
if (-not $rawJson -or $rawJson.Trim() -eq "") {
    if ($env:INPUTS_JSON -and $env:INPUTS_JSON.Trim() -ne "") {
        $rawJson = $env:INPUTS_JSON
    }
}

Write-Output "Raw JSON input received: $rawJson"
$data = $rawJson | ConvertFrom-Json

# ---------- Site mapping ----------
$siteMap = @{
    "Bangalore" = "192.168.136.50"
    "Pune"      = "10.0.0.20"
    "Chennai"   = "10.0.0.10"
}

$siteName = $data.s1
if (-not $siteMap.ContainsKey($siteName)) {
    throw "Site '$siteName' not found in mapping. Available: $($siteMap.Keys -join ', ')"
}
$siteIp = $siteMap[$siteName]

# ---------- Parse VM list (Ensures collection is always an array) ----------
$vmNames = @(($data.v1 -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
if ($vmNames.Count -eq 0) {
    throw "No VM names provided."
}

# ---------- Expand Snapshot Names and Delays ----------
$snapNames = Expand-StringValue -vmList $vmNames -inputValue $data.sn1 -defaultValueTemplate "{0}-snapshot"
$delays = Expand-Value -vmList $vmNames -inputValue $data.d1 -valueName "Delay"
$op = $data.op # 1=Create, 2=Delete, 3=Restore

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
    Write-Output "$($vmNames[$i]) : Snapshot=$($snapNames[$i]), delay=$($delays[$i]) sec"
}
Write-Output "Start time: $(Get-Date -Format 'HH:mm:ss')`n"

# ---------- Define the job script block ----------
$snapshotJob = {
    param($siteIp, $vmName, $delaySec, $snapName, $op, $user, $pass)

    if ($delaySec -gt 0) {
        Write-Output "[$vmName] Waiting $delaySec second(s)..."
        Start-Sleep -Seconds $delaySec
    }

    # Load Nutanix Cmdlets if they aren't already loaded in the runspace context
    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        try {
            Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop
        } catch {
            Write-Error "[$vmName] Failed to load NutanixCmdletsPSSnapin: $($_.Exception.Message)"
            return
        }
    }

    $creds = New-Object System.Security.SecureString
    foreach ($char in $pass.ToCharArray()) { $creds.AppendChar($char) }
    $creds.MakeReadOnly()

    try {
        Write-Output "[$vmName] Connecting to Prism Element on $siteIp..."
        Connect-NTNXCluster -Server $siteIp -UserName $user -Password $creds -AcceptInvalidSSLCerts -ErrorAction Stop | Out-Null
        Write-Output "[$vmName] Connected successfully."

        Write-Output "[$vmName] Locating target VM..."
        $vm = Get-NTNXVM -SearchString $vmName | Where-Object { $_.vmName -eq $vmName } | Select-Object -First 1
        if (-not $vm) {
            throw "VM '$vmName' was not found on cluster."
        }
        Write-Output "[$vmName] VM found with UUID: $($vm.uuid). PowerState: $($vm.powerState)"

        switch ($op) {
            "1" { # CREATE
                Write-Output "[$vmName] Creating snapshot '$snapName'..."
                $spec = New-NTNXObject -Name SnapshotSpecDTO
                $spec.vmUuid = $vm.uuid
                $spec.snapshotName = $snapName
                New-NTNXSnapshot -SnapshotSpecs $spec -ErrorAction Stop | Out-Null
                Write-Output "[$vmName] SUCCESS: Created snapshot '$snapName'"
            }
            "2" { # DELETE
                Write-Output "[$vmName] Searching for snapshot '$snapName'..."
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { throw "Snapshot '$snapName' not found." }
                Write-Output "[$vmName] Deleting snapshot '$snapName'..."
                Remove-NTNXSnapshot -Uuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Output "[$vmName] SUCCESS: Deleted snapshot '$snapName'"
            }
            "3" { # RESTORE
                Write-Output "[$vmName] Searching for snapshot '$snapName'..."
                $snap = Get-NTNXSnapshot | Where-Object { $_.vmUuid -eq $vm.uuid -and $_.snapshotName -eq $snapName }
                if (-not $snap) { throw "Snapshot '$snapName' not found." }

                if ($vm.powerState -eq "ON") {
                    Write-Output "[$vmName] VM is currently powered ON. Initiating ACPI graceful shutdown..."
                    Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                    
                    $isOff = $false
                    # Try up to 10 shutdown verification cycles (30s interval each)
                    for($attempt = 1; $attempt -le 10; $attempt++) {
                        Write-Output "[$vmName] Waiting 30 seconds to validate VM power status (Attempt $attempt/10)..."
                        Start-Sleep -Seconds 30
                        
                        $checkVm = Get-NTNXVM -Vmid $vm.uuid
                        if ($checkVm.powerState -eq "OFF") { 
                            $isOff = $true
                            Write-Output "[$vmName] VM shutdown validated. PowerState is OFF."
                            break 
                        }
                        
                        if ($attempt -lt 10) {
                            Write-Output "[$vmName] VM is still ON. Re-triggering ACPI graceful shutdown..."
                            Set-NTNXVMPowerState -Vmid $vm.uuid -Transition ACPI_SHUTDOWN -ErrorAction Stop | Out-Null
                        }
                    }
                    if (-not $isOff) { throw "VM failed to shut down after multiple ACPI graceful shutdown triggers." }
                }

                Write-Output "[$vmName] Waiting 60 seconds to allow the hypervisor to release disk locks cleanly..."
                Start-Sleep -Seconds 60

                Write-Output "[$vmName] Restoring VM state from snapshot '$snapName'..."
                Restore-NTNXVirtualMachine -Vmid $vm.uuid -SnapshotUuid $snap.uuid -ErrorAction Stop | Out-Null
                Write-Output "[$vmName] Reverted block-storage states cleanly."

                Write-Output "[$vmName] Powering VM back ON..."
                Set-NTNXVMPowerOn -Vmid $vm.uuid -ErrorAction Stop | Out-Null
                Write-Output "[$vmName] SUCCESS: Restore completed and powered ON successfully."
            }
        }
    } catch {
        Write-Error "[$vmName] CRITICAL FAILURE: $($_.Exception.Message)"
    } finally {
        Disconnect-NTNXCluster -Servers $siteIp -ErrorAction SilentlyContinue
    }
}

# ---------- Start a background job for each VM ----------
$jobs = @()
for ($i = 0; $i -lt $vmNames.Count; $i++) {
    $job = Start-Job -ScriptBlock $snapshotJob -ArgumentList `
        $siteIp, `
        $vmNames[$i], `
        $delays[$i], `
        $snapNames[$i], `
        $op, `
        $env:PE_USER, `
        $env:PE_PASS
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
