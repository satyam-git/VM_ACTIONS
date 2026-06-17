param(
    [Parameter(Mandatory = $true)]
    [string]$pe_ip,

    [Parameter(Mandatory = $true)]
    [string]$vmname,

    [Parameter(Mandatory = $true)]
    [ValidateSet("add", "extend")]
    [string]$disk_action,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+$')]
    [string]$SizeGB,

    [Parameter(Mandatory = $false)]
    [ValidateSet("none", "scsi.0", "scsi.1", "scsi.2", "scsi.3")]
    [string]$DiskAddr = ""
)

$ErrorActionPreference = "Stop"

Write-Host "diskprovisioning.ps1 version: 2026-06-17-cmdlets-container-selection-v2"

Import-Module Posh-SSH -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($env:PE_USERNAME)) {
    throw "Missing GitHub secret: PE_USERNAME"
}

if ([string]::IsNullOrWhiteSpace($env:PE_PASSWORD)) {
    throw "Missing GitHub secret: PE_PASSWORD"
}

if ([int]$SizeGB -le 0) {
    throw "SizeGB must be greater than 0."
}

if ($disk_action -eq "extend" -and ($DiskAddr -eq "none" -or [string]::IsNullOrWhiteSpace($DiskAddr))) {
    throw "DiskAddr is required when disk_action is extend."
}

if ($disk_action -eq "add" -and $DiskAddr -ne "none" -and -not [string]::IsNullOrWhiteSpace($DiskAddr)) {
    Write-Host "DiskAddr was provided, but disk_action is add. DiskAddr will be ignored."
}

function ConvertTo-AcliQuotedValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value.Contains("'")) {
        throw "Single quote is not supported in ACLI argument value: $Value"
    }

    return "'$Value'"
}

function Get-NutanixUsageStat {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Container,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ($Container.usageStats) {
        $usageStats = $Container.usageStats
    }
    elseif ($Container.usage_stats) {
        $usageStats = $Container.usage_stats
    }
    else {
        return 0
    }

    if ($usageStats -is [hashtable] -and $usageStats.ContainsKey($Key)) {
        return [double]$usageStats[$Key]
    }

    $property = $usageStats.PSObject.Properties[$Key]
    if ($null -ne $property -and $null -ne $property.Value) {
        return [double]$property.Value
    }

    return 0
}

function Connect-NutanixClusterForCmdlets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$Username,

        [Parameter(Mandatory = $true)]
        [string]$Password
