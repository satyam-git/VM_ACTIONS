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

Import-Module Posh-SSH -ErrorAction Stop

if ($PSVersionTable.PSEdition -eq "Desktop") {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;

public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint,
        X509Certificate certificate,
        WebRequest request,
        int certificateProblem) {
        return true;
    }
}
"@

    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

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

function Invoke-NutanixRest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$Username,

        [Parameter(Mandatory = $true)]
        [string]$Password,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $encodedCredential = [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("${Username}:$Password")
    )

    $headers = @{
        Authorization = "Basic $encodedCredential"
        Accept        = "application/json"
    }
