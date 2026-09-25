#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core
<#
.SYNOPSIS
Lists vSphere virtual disks with Windows guest volume and datastore details.

.DESCRIPTION
Selects a VM and prompts for Windows administrator credentials. Displays the
Windows Server (SQL workflow) virtual-disk table from Expand-VSphereVmDisk-v3.ps1:
Number, Disk, GuestVolumes, HDCapacityGB, GuestVolFreeGB, DatastoreFreeGB,
DatastoreProvGB, and DatastoreFile.

Retrieves volume labels through VMware Tools and maps them to virtual disks.
Free space uses the latest Tools report and excludes unpartitioned space.
Missing volume mappings display as unavailable; disk labels sort numerically.

Reuses a single active vCenter connection or prompts for a server. This script
does not resize, initialize, or delete disks or partitions. Empty passwords and
recognized authentication failures prompt for credentials again. Enter 'exit'
at text prompts or cancel the credential dialog to stop.

.PARAMETER VMName
Exact VM inventory name. Wildcards are not accepted.

.PARAMETER VIServer
Optional vCenter hostname.

.PARAMETER GuestCredential
Optional Windows guest administrator credential.

.EXAMPLE
.\ShowVMDisk.ps1

.EXAMPLE
.\ShowVMDisk.ps1 -VMName '11VMDEV501 - John Smith'
#>
[CmdletBinding()]
param(
    [string]$VMName,
    [string]$VIServer,
    [pscredential]$GuestCredential
)

function Read-InventoryInput {
    param([string]$Prompt)
    $answer = ([string](Read-Host "$Prompt (enter 'exit' to cancel)")).Trim()
    if ($answer -ieq 'exit') { throw [OperationCanceledException]::new() }
    return $answer
}

function Read-GuestCredential {
    while ($true) {
        $name = Read-InventoryInput 'Enter the Windows guest administrator user name'
        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Warning 'Enter a username.'
            continue
        }
        $credential = Get-Credential -UserName $name -Message 'Enter the Windows guest administrator password. Select Cancel to stop.'
        if ($null -eq $credential) { throw [OperationCanceledException]::new() }
        if ($credential.Password.Length -eq 0) {
            Write-Warning 'The Windows guest password cannot be empty. Enter the credentials again.'
            continue
        }
        return $credential
    }
}

function Invoke-WindowsGuestPowerShell {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory)]
        [string]$ScriptText
    )

    # Keep this wrapper compact. Invoke-VMScript transports Windows PowerShell
    # through VMware Tools and large encoded command lines can fail before the
    # guest script starts, returning exit code 1 with no ScriptOutput.
    $wrappedScript = @'
try {
    $guestResults = @(& {
__GUEST_SCRIPT_BODY__
    })
    if ($guestResults.Count -eq 0) {
        throw 'Guest operation returned no result payload.'
    }
    Write-Output '__VMWARE_GUEST_PAYLOAD_BEGIN__'
    Write-Output ([string]$guestResults[-1]).Trim()
    Write-Output '__VMWARE_GUEST_PAYLOAD_END__'
}
catch {
    Write-Output ("Guest exception: " + $_.Exception.Message + [Environment]::NewLine + $_.InvocationInfo.PositionMessage)
    exit 1
}
'@
    $wrappedScript = $wrappedScript.Replace('__GUEST_SCRIPT_BODY__', $ScriptText)

    $result = Invoke-VMScript -VM $VM -GuestCredential $Credential -ScriptType Powershell -ScriptText $wrappedScript -ErrorAction Stop
    if ($result.ExitCode -ne 0) {
        $errorDetails = [string]$result.ScriptOutput
        if ([string]::IsNullOrWhiteSpace($errorDetails)) {
            $errorDetails = 'VMware Tools returned no guest error details.'
        }
        throw "The Windows guest script failed with exit code $($result.ExitCode): $($errorDetails.Trim())"
    }

    $rawOutput = [string]$result.ScriptOutput
    $beginMarker = '__VMWARE_GUEST_PAYLOAD_BEGIN__'
    $endMarker = '__VMWARE_GUEST_PAYLOAD_END__'
    $beginIndex = $rawOutput.LastIndexOf($beginMarker, [System.StringComparison]::Ordinal)
    if ($beginIndex -lt 0) {
        $displayOutput = $rawOutput.Trim()
        if ($displayOutput.Length -gt 2000) {
            $displayOutput = $displayOutput.Substring(0, 2000) + '...'
        }
        throw "The Windows guest returned an unframed result. Guest output: $displayOutput"
    }

    $payloadStart = $beginIndex + $beginMarker.Length
    $endIndex = $rawOutput.IndexOf($endMarker, $payloadStart, [System.StringComparison]::Ordinal)
    if ($endIndex -lt 0) {
        throw 'The Windows guest result was incomplete: the payload end marker was missing.'
    }

    return $rawOutput.Substring($payloadStart, $endIndex - $payloadStart).Trim()
}

function ConvertTo-NormalizedWindowsVolumePath {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    return $Path.Trim().TrimEnd('\').ToUpperInvariant()
}

function Get-WindowsGuestVolumeLabels {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $scriptText = @'
$ErrorActionPreference = 'Stop'
$volumes = foreach ($partition in Get-Partition) {
    $volume = Get-Volume -Partition $partition -ErrorAction SilentlyContinue
    if ($null -eq $volume) {
        continue
    }

    $accessPaths = @(
        $partition.AccessPaths |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_ -notmatch '^\\\\\?\\Volume\{'
            }
    )

    if ($null -ne $volume.DriveLetter) {
        $accessPaths += "$($volume.DriveLetter):\"
    }

    foreach ($path in @($accessPaths | Sort-Object -Unique)) {
        [pscustomobject]@{
            DiskNumber      = $partition.DiskNumber
            PartitionNumber = $partition.PartitionNumber
            Path            = $path
            Label           = [string]$volume.FileSystemLabel
        }
    }
}

[pscustomobject]@{
    Volumes = @($volumes)
} | ConvertTo-Json -Depth 4 -Compress
'@

    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    $payload = $json | ConvertFrom-Json -ErrorAction Stop
    return @($payload.Volumes)
}

function Get-GuestVolumeDisplayForHardDisk {
    param(
        [Parameter(Mandatory)]
        [object]$HardDisk,

        [Parameter()]
        [System.Collections.IDictionary]$VolumeLabelsByPath
    )

    if ($null -eq (Get-Command -Name Get-VMGuestDisk -ErrorAction SilentlyContinue)) {
        return 'Unavailable'
    }

    try {
        $guestDisks = @(Get-VMGuestDisk -HardDisk $HardDisk -ErrorAction Stop)
    }
    catch {
        Write-Warning "Could not retrieve guest volume mapping for '$($HardDisk.Name)': $($_.Exception.Message)"
        return 'Unavailable'
    }

    $paths = @(
        $guestDisks |
            ForEach-Object { [string]$_.DiskPath } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    if ($paths.Count -eq 0) {
        return 'No mapped volume'
    }

    $displayValues = foreach ($path in $paths) {
        $label = $null
        $normalizedPath = ConvertTo-NormalizedWindowsVolumePath -Path $path
        if ($null -ne $VolumeLabelsByPath -and $VolumeLabelsByPath.Contains($normalizedPath)) {
            $label = [string]$VolumeLabelsByPath[$normalizedPath]
            if ([string]::IsNullOrWhiteSpace($label)) {
                $label = 'No label'
            }
        }
        else {
            $label = 'Label unavailable'
        }

        "$path [$label]"
    }

    return $displayValues -join '; '
}

function Get-HardDiskGuestFreeSpace {
    param(
        [Parameter(Mandatory)][object]$HardDisk,
        [Parameter(Mandatory)][object]$VM
    )

    # Match Tools volume paths to this VMDK; never infer Windows disk numbers.
    try {
        $mappedVolumes = @(Get-VMGuestDisk -HardDisk $HardDisk -ErrorAction Stop)
        $paths = @($mappedVolumes | ForEach-Object { [string]$_.DiskPath } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($paths.Count -eq 0) { return 'Unavailable' }
        $values = foreach ($path in $paths) {
            $normalizedPath = ConvertTo-NormalizedWindowsVolumePath -Path $path
            $matches = @($VM.ExtensionData.Guest.Disk | Where-Object {
                (ConvertTo-NormalizedWindowsVolumePath -Path $_.DiskPath) -eq $normalizedPath
            })
            if ($matches.Count -eq 1 -and $null -ne $matches[0].FreeSpace) {
                $freeGB = [math]::Round(([decimal]$matches[0].FreeSpace / 1GB), 2)
                if ($paths.Count -eq 1) { $freeGB } else { "$path [$freeGB]" }
            }
            else { "$path [Unavailable]" }
        }
        return $values -join '; '
    }
    catch { return 'Unavailable' }
}

function Get-HardDiskDatastoreSpace {
    param(
        [Parameter(Mandatory)]
        [object]$HardDisk,

        [Parameter(Mandatory)]
        [object]$Server
    )

    $datastoreReference = $HardDisk.ExtensionData.Backing.Datastore
    if ($null -eq $datastoreReference -or [string]::IsNullOrWhiteSpace([string]$datastoreReference.Value)) {
        return $null
    }

    $datastoreId = "Datastore-$($datastoreReference.Value)"
    $datastore = Get-Datastore -Id $datastoreId -Server $Server -ErrorAction Stop
    [decimal]$freeSpaceGB = $datastore.FreeSpaceGB
    [decimal]$usedSpaceGB = [decimal]$datastore.CapacityGB - $freeSpaceGB
    [decimal]$uncommittedSpaceGB = 0
    if ($null -ne $datastore.ExtensionData.Summary.Uncommitted) {
        $uncommittedSpaceGB = [decimal]$datastore.ExtensionData.Summary.Uncommitted / 1GB
    }

    return [pscustomobject]@{
        FreeSpaceGB        = [math]::Round($freeSpaceGB, 2)
        ProvisionedSpaceGB = [math]::Round($usedSpaceGB + $uncommittedSpaceGB, 2)
    }
}

function Show-VirtualDisks {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter()]
        [switch]$IncludeGuestVolumes = $true,

        [Parameter()]
        [System.Collections.IDictionary]$VolumeLabelsByPath,

        [Parameter()]
        [int]$InitialDiskNumber
    )

    $disks = @(
        Get-HardDisk -VM $VM -Server $Server -ErrorAction Stop |
            Sort-Object `
                @{ Expression = {
                    $diskNumberMatch = [regex]::Match([string]$_.Name, '\d+(?=\D*$)')
                    if ($diskNumberMatch.Success) {
                        [int]$diskNumberMatch.Value
                    }
                    else {
                        [int]::MaxValue
                    }
                } },
                Name
    )
    if ($disks.Count -eq 0) {
        throw "VM '$($VM.Name)' has no virtual hard disks."
    }

    Write-Host "`nVirtual disks on '$($VM.Name)':" -ForegroundColor Cyan
    $diskList = for ($index = 0; $index -lt $disks.Count; $index++) {
        $datastoreSpace = try {
            Get-HardDiskDatastoreSpace -HardDisk $disks[$index] -Server $Server
        }
        catch {
            Write-Warning "Could not retrieve datastore space information for '$($disks[$index].Name)': $($_.Exception.Message)"
            $null
        }

        $row = [ordered]@{
            Number                     = $index + 1
            Disk                       = $disks[$index].Name
        }
        if ($IncludeGuestVolumes) {
            $display = Get-GuestVolumeDisplayForHardDisk -HardDisk $disks[$index] -VolumeLabelsByPath $VolumeLabelsByPath
            $row['GuestVolumes'] = $display
        }
        $row['HDCapacityGB'] = [decimal]$disks[$index].CapacityGB
        if ($IncludeGuestVolumes) {
            $row['GuestVolFreeGB'] = Get-HardDiskGuestFreeSpace -HardDisk $disks[$index] -VM $VM
        }
        $row += [ordered]@{
            DatastoreFreeGB            = if ($null -ne $datastoreSpace) { [decimal]$datastoreSpace.FreeSpaceGB } else { 'Unavailable' }
            DatastoreProvGB            = if ($null -ne $datastoreSpace) { [decimal]$datastoreSpace.ProvisionedSpaceGB } else { 'Unavailable' }
            DatastoreFile              = $disks[$index].Filename
        }
        [pscustomobject]$row
    }
    # Keep the table's leading gap, but own its trailing spacing explicitly.
    $tableColumns = foreach ($column in $diskList[0].PSObject.Properties.Name) {
        if ($column -eq 'GuestVolFreeGB') {
            @{ Name = 'GuestVolFreeGB'; Expression = { $_.GuestVolFreeGB }; Alignment = 'Right' }
        }
        else {
            $column
        }
    }
    Write-Host (($diskList | Format-Table -Property $tableColumns -AutoSize | Out-String).TrimEnd())
    Write-Host ''

}

try {
    if ([string]::IsNullOrWhiteSpace($VIServer)) {
        $connections = @(@($global:DefaultVIServers) + @($global:DefaultVIServer) |
            Where-Object { $null -ne $_ -and $_.IsConnected } |
            Sort-Object Name -Unique)
        if ($connections.Count -eq 1) { $server = $connections[0] }
        else {
            do { $VIServer = Read-InventoryInput 'Enter the vCenter Server host name' }
            while ([string]::IsNullOrWhiteSpace($VIServer))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($VIServer)) {
        $credential = Get-Credential -Message "Enter credentials for vCenter '$VIServer'. Select Cancel to stop."
        if ($null -eq $credential) { throw [OperationCanceledException]::new() }
        $server = Connect-VIServer -Server $VIServer -Credential $credential -ErrorAction Stop
    }
    Write-Host ''
    Write-Host 'Connected to vCenter Server:' -ForegroundColor Cyan
    Write-Host ("  Host name : {0}" -f $server.Name)
    Write-Host ("  Version   : {0}" -f $server.Version)
    Write-Host ("  Build     : {0}" -f $server.Build)
    Write-Host ''

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($VMName)) { $VMName = Read-InventoryInput 'Enter VM name' }
        if ([string]::IsNullOrWhiteSpace($VMName) -or $VMName.IndexOfAny([char[]]'*?[]') -ge 0) {
            Write-Warning 'Enter an exact VM name without wildcards.'
            $VMName = ''
            continue
        }
        $vmMatches = @(Get-VM -Server $server -ErrorAction Stop | Where-Object { $_.Name -ieq $VMName })
        if ($vmMatches.Count -ne 1) {
            Write-Warning "Expected one VM named '$VMName'; found $($vmMatches.Count). Enter another VM name."
            $VMName = ''
            continue
        }
        $vm = $vmMatches[0]
        if ($vm.PowerState -ne 'PoweredOn' -or $vm.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') {
            Write-Warning 'The VM must be powered on with VMware Tools running. Enter another VM name.'
            $VMName = ''
            continue
        }
        if ([string]$vm.ExtensionData.Guest.GuestFullName -notmatch '(?i)Windows') {
            Write-Warning 'VMware Tools must report a Windows guest OS. Enter another VM name.'
            $VMName = ''
            continue
        }
        break
    }

    while ($true) {
        if ($null -eq $GuestCredential) { $GuestCredential = Read-GuestCredential }
        if ($GuestCredential.Password.Length -eq 0) {
            Write-Warning 'The Windows guest password cannot be empty. Enter the credentials again.'
            $GuestCredential = $null
            continue
        }
        try {
            Write-Host '[i] Fetching Windows guest volume information.' -ForegroundColor Gray
            $volumes = @(Get-WindowsGuestVolumeLabels -VM $vm -Credential $GuestCredential)
            break
        }
        catch {
            if ($_.Exception.ToString() -match '(?i)InvalidGuestLogin|Failed to authenticate with the guest operating system|vix error codes\s*=\s*\(\s*3033\s*,\s*0\s*\)') {
                Write-Warning 'Windows guest authentication failed. Enter the username and password again.'
                $GuestCredential = $null
                continue
            }
            if ($_.Exception.Message -match '(?i)vix error codes\s*=\s*\(\s*1\s*,\s*0\s*\)') {
                throw "VMware Tools could not complete the guest operation on '$($vm.Name)'. Restart the VMware Tools service inside the VM and try again. If the issue persists, reboot the VM and retry. Error details: $($_.Exception.Message)"
            }
            throw
        }
    }
    Write-Host ''
    $labels = @{}
    foreach ($volume in $volumes) {
        $path = ConvertTo-NormalizedWindowsVolumePath -Path ([string]$volume.Path)
        if ($path) { $labels[$path] = [string]$volume.Label }
    }
    $vm.ExtensionData.UpdateViewData('Guest')
    Show-VirtualDisks -VM $vm -Server $server -VolumeLabelsByPath $labels

}
catch [System.OperationCanceledException] {
    Write-Host 'Cancelled. No disk or partition changes were made.' -ForegroundColor Yellow
}
catch {
    Write-Error $_.Exception.Message
}
