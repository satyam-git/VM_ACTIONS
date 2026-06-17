param(
    [Parameter(Mandatory = $true)]
    [string]$pe_ip,

    [Parameter(Mandatory = $true)]
    [string]$vmname,

    [Parameter(Mandatory = $true)]
    [ValidateSet("add","extend")]
    [string]$disk_action,

    [Parameter(Mandatory = $true)]
    [string]$SizeGB,

    [Parameter(Mandatory = $false)]
    [ValidateSet("none","scsi.0","scsi.1","scsi.2","scsi.3")]
    [string]$DiskAddr = "none"
)

$ErrorActionPreference = "Stop"

Write-Host "====================================="
Write-Host "Nutanix Disk Provisioning Started"
Write-Host "====================================="

Import-Module Posh-SSH -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($env:PE_USERNAME)) {
    throw "PE_USERNAME secret not found"
}

if ([string]::IsNullOrWhiteSpace($env:PE_PASSWORD)) {
    throw "PE_PASSWORD secret not found"
}

if ($disk_action -eq "extend" -and $DiskAddr -eq "none") {
    throw "DiskAddr is mandatory when disk_action=extend"
}

$SecurePassword = ConvertTo-SecureString $env:PE_PASSWORD -AsPlainText -Force
$Credential = New-Object PSCredential ($env:PE_USERNAME,$SecurePassword)

Write-Host "Connecting to cluster $pe_ip"

$Session = New-SSHSession `
    -ComputerName $pe_ip `
    -Credential $Credential `
    -AcceptKey `
    -Force

if ($Session.SessionId -lt 0) {
    throw "SSH connection failed"
}

try {

    if ($disk_action -eq "add") {

        Write-Host "Finding best container..."

        if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
            Add-PSSnapin NutanixCmdletsPSSnapin
        }

        Connect-NTNXCluster `
            -Server $pe_ip `
            -UserName $env:PE_USERNAME `
            -Password $SecurePassword `
            -AcceptInvalidSSLCerts | Out-Null

        $ClusterDetails = Get-NTNXCluster

        $Prefix = $ClusterDetails.name.Substring(
            0,
            [math]::Min(3,$ClusterDetails.name.Length)
        )

        $BestContainer = Get-NTNXContainer |
            Where-Object {
                $n = if ($_.name) { $_.name } else { $_.containerName }

                $n -like "$Prefix*" -and
                $n -notmatch "NutanixManagementShare|NutaniXFitInstance|default-container"
            } |
            Select-Object *,
            @{
                Name = "FreePct"
                Expression = {

                    $Cap = [double]$_.usageStats.'storage.capacity_bytes'
                    $Use = [double]$_.usageStats.'storage.usage_bytes'

                    if ($Cap -gt 0) {
                        (($Cap - $Use) / $Cap) * 100
                    }
                    else {
                        0
                    }
                }
            } |
            Sort-Object FreePct -Descending |
            Select-Object -First 1

        $ContainerName = if ($BestContainer.name) {
            $BestContainer.name
        }
        else {
            $BestContainer.containerName
        }

        Write-Host "Selected Container: $ContainerName"

        $AcliCommand = "acli vm.disk_create '$vmname' container='$ContainerName' create_size='${SizeGB}G'"
    }

    else {

        Write-Host "Extending existing disk..."

        $AcliCommand = "acli vm.disk_update '$vmname' disk_addr='$DiskAddr' new_size='${SizeGB}G'"
    }

    Write-Host "Executing:"
    Write-Host $AcliCommand

    $Result = Invoke-SSHCommand `
        -SessionId $Session.SessionId `
        -Command $AcliCommand

    Write-Host ""
    Write-Host "===== ACLI OUTPUT ====="
    Write-Host $Result.Output
    Write-Host "======================="

}
finally {

    if (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue) {
        Disconnect-NTNXCluster -Servers $pe_ip -ErrorAction SilentlyContinue | Out-Null
    }

    if ($Session) {
        Remove-SSHSession -SessionId $Session.SessionId | Out-Null
    }
}

Write-Host "Disk operation completed successfully."
