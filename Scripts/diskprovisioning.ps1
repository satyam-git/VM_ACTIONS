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
    [string]$DiskAddr = "none"
)

$ErrorActionPreference = "Stop"

Write-Host "diskprovisioning.ps1 version: 2026-06-17-cmdlets-simple-v3"

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

if ($vmname.Contains("'")) {
    throw "VM name cannot contain a single quote."
}

if ($DiskAddr.Contains("'")) {
    throw "DiskAddr cannot contain a single quote."
}

$quotedVmName = "'$vmname'"
$quotedSize = "'$($SizeGB)G'"
$acliCommand = $null

if ($disk_action -eq "add") {
    Write-Host "Action selected: ADD disk."

    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin -ErrorAction Stop | Out-Null
    }

    $securePePassword = ConvertTo-SecureString $env:PE_PASSWORD -AsPlainText -Force

    try {
        Write-Host "Connecting to Nutanix PE with Nutanix cmdlets: $pe_ip"

        Connect-NTNXCluster `
            -Server $pe_ip `
            -UserName $env:PE_USERNAME `
            -Password $securePePassword `
            -AcceptInvalidSSLCerts `
            -ErrorAction Stop | Out-Null

        $cluster = Get-NTNXCluster -ErrorAction Stop
        $clusterName = $cluster.name

        if ([string]::IsNullOrWhiteSpace($clusterName)) {
            throw "Unable to read Nutanix cluster name."
        }

        $prefixLength = [Math]::Min(3, $clusterName.Length)
        $containerPrefix = $clusterName.Substring(0, $prefixLength)

        Write-Host "Cluster name: $clusterName"
        Write-Host "Container prefix: $containerPrefix"

        $candidateContainers = @()
        $containers = @(Get-NTNXContainer -ErrorAction Stop)

        foreach ($container in $containers) {
            $containerName = if ($container.name) { $container.name } else { $container.containerName }

            if ([string]::IsNullOrWhiteSpace($containerName)) {
                continue
            }

            if ($containerName -notlike "$containerPrefix*") {
                continue
            }
