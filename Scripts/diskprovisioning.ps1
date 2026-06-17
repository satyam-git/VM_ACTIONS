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
    [string]$DiskAddr = ""
)

$ErrorActionPreference = "Stop"

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

if ($disk_action -eq "extend" -and [string]::IsNullOrWhiteSpace($DiskAddr)) {
    throw "DiskAddr is required when disk_action is extend."
}

if ($disk_action -eq "add" -and -not [string]::IsNullOrWhiteSpace($DiskAddr)) {
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

function Invoke-NutanixAcli {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$Username,

        [Parameter(Mandatory = $true)]
        [string]$Password,

        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = [pscredential]::new($Username, $securePassword)
    $session = $null

    try {
        Write-Host "Connecting to Nutanix PE/CVM: $Server"

        $session = New-SSHSession `
            -ComputerName $Server `
            -Credential $credential `
            -AcceptKey `
            -ErrorAction Stop

        Write-Host "Running ACLI command:"
        Write-Host $Command

        $result = Invoke-SSHCommand `
            -SessionId $session.SessionId `
            -Command $Command `
            -TimeOut 600 `
            -ErrorAction Stop

        if ($result.Output) {
            $result.Output | ForEach-Object { Write-Host $_ }
        }

        if ($result.Error) {
            $result.Error | ForEach-Object { Write-Error $_ }
        }

        if ($result.ExitStatus -ne 0) {
            throw "ACLI command failed with exit code $($result.ExitStatus)."
        }
    }
    finally {
        if ($null -ne $session) {
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
        }
    }
}

$quotedVmName = ConvertTo-AcliQuotedValue -Value $vmname
$sizeValue = ConvertTo-AcliQuotedValue -Value "$($SizeGB)G"

if ($disk_action -eq "add") {
    Write-Host "Action selected: ADD disk."

    $acliCommand = "acli vm.disk_create $quotedVmName create_size=$sizeValue"
}
else {
    Write-Host "Action selected: EXTEND disk."

    $quotedDiskAddr = ConvertTo-AcliQuotedValue -Value $DiskAddr
    $acliCommand = "acli vm.disk_update $quotedVmName disk_addr=$quotedDiskAddr new_size=$sizeValue"
}

Invoke-NutanixAcli `
    -Server $pe_ip `
    -Username $env:PE_USERNAME `
    -Password $env:PE_PASSWORD `
    -Command $acliCommand

Write-Host "Nutanix PE disk provisioning completed successfully."
