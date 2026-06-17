param($JsonInputs)

$data = $JsonInputs | ConvertFrom-Json

if ($data.operation -eq "compute") {

    Write-Host "Starting Compute Resize..."

    $ClusterIP = $data.pE_IP
    $VMName = $data.vmname
    $CPUs = [int]$data.CPU_size
    $MemoryMB = [int]$data.mem_size * 1024
    $Delay = [int]$data.delay_mins

    if (-not (Get-PSSnapin -Name NutanixCmdletsPSSnapin -ErrorAction SilentlyContinue)) {
        Add-PSSnapin NutanixCmdletsPSSnapin | Out-Null
    }

    $Pass = $env:PE_PASSWORD | ConvertTo-SecureString -AsPlainText -Force
    Connect-NTNXCluster -Server $ClusterIP -UserName $env:PE_USERNAME -Password $Pass -AcceptInvalidSSLCerts | Out-Null

    $VM = Get-NTNXVM | Where-Object { $_.vmName -eq $VMName }
    if (-not $VM) { throw "VM not found" }

    if ($Delay -gt 0) { Start-Sleep -Seconds ($Delay * 60) }

    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ACPI_SHUTDOWN -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 60

    Set-NTNXVirtualMachine -Vmid $VM.uuid -NumVcpus $CPUs -MemoryMb $MemoryMB | Out-Null

    Set-NTNXVMPowerState -Vmid $VM.uuid -Transition ON | Out-Null

    Disconnect-NTNXCluster -Servers $ClusterIP | Out-Null

    Write-Host "Compute resize completed."
}
else {

    & "$PSScriptRoot\Storage provisioning with OS.ps1" `
        -pe_ip $data.pe_ip `
        -vmname $data.vmname `
        -disk_action $data.disk_action `
        -SizeGB $data.SizeGB `
        -DiskAddr $data.DiskAddr `
        -GuestIP $data.GuestIP `
        -DriveLetter $data.DriveLetter
}
