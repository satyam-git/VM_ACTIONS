param([Parameter(Mandatory=$true)][string]$JsonInputs)

$data = $JsonInputs | ConvertFrom-Json
$ErrorActionPreference = "SilentlyContinue"

# Configuration
$ClusterIP    = $data.pE_IP
$VMName       = $data.vmname
$RequestedCPU = [int]$data.CPU_size
$RequestedMem = [int]$data.mem_size
$SiteName     = "Banglore"

# Initialize Execution Summary List
$ExecutionSummary = New-Object System.Collections.Generic.List[PSObject]

function Add-Result {
    param($vm, $act, $stat)
    $ExecutionSummary.Add([PSCustomObject]@{
        "Site Name" = $SiteName
        "vmname"    = $vm
        "action"    = $act
        "status"    = $stat
    })
}

# 1. Load Nutanix Module
if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
    Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
}

try {
    # 2. Connect
    $Pass = $env:PE_PASS | ConvertTo-SecureString -AsPlainText -Force
    Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USER -Password $Pass -AcceptInvalidSSLCerts | Out-Null

    # 3. Get VM
    $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
    if (-not $VM) {
        Add-Result -vm $VMName -act "resize" -stat "VM Not Found"
    } else {
        # 4. Actions
        Add-Result -vm $VMName -act "stop" -stat "successful"
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN | Out-Null
        Start-Sleep -Seconds 10
        
        Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $RequestedCPU -MemoryMb ($RequestedMem * 1024) | Out-Null
        Add-Result -vm $VMName -act "resize" -stat "successful"
        
        Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON | Out-Null
        Add-Result -vm $VMName -act "start" -stat "successful"
    }

} catch {
    Add-Result -vm $VMName -act "process" -stat "Failed: $($_.Exception.Message)"
} finally {
    Disconnect-NTNXCluster -Servers $ClusterIP -ErrorAction SilentlyContinue
}

# --- Output Table ---
Write-Host "`nExecution Summary" -ForegroundColor Cyan
$ExecutionSummary | Format-Table -AutoSize | Out-String | Write-Host

# Write to GitHub Job Summary
if ($env:GITHUB_STEP_SUMMARY) {
    "### Execution Summary" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
    "| Site Name | vmname | action | status |" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
    "| :--- | :--- | :--- | :--- |" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
    foreach ($row in $ExecutionSummary) {
        "| $($row.'Site Name') | $($row.vmname) | $($row.action) | $($row.status) |" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
    }
}
