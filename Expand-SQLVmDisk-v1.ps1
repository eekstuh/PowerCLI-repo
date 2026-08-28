#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core

<#
.SYNOPSIS
Expands one existing virtual disk on a Windows SQL VM and shows its guest volume labels.

.DESCRIPTION
Prompts for an exact VM name, a disk number, and an amount to add in GB unless
those values are supplied as parameters. Before disk selection, the script uses
VMware Tools to retrieve Windows volume labels and maps the reported guest
volumes to their backing vSphere virtual disks. VM name wildcard characters
(*, ?, [, ]) are rejected. Enter 'exit' at any script prompt to cancel the remaining workflow; before
confirmation it makes no changes, and after VMDK expansion it prevents further
guest changes.

This script expands the VMDK only.  It does not extend a Windows partition or
volume inside the guest OS unless you opt in after the VMDK expansion. The
guest extension requires VMware Tools and a Windows administrator credential.
If a Recovery or another partition follows the chosen partition, the script
stops before extending it. You may explicitly authorize deletion of that
adjacent blocking partition. Deleting a Recovery partition also disables WinRE.

.PARAMETER VIServer
Optional vCenter Server name. If omitted, the active default PowerCLI
connection is used when exactly one is available; otherwise the script prompts
for a vCenter Server.

.PARAMETER Credential
Optional credential passed to Connect-VIServer when a new connection is needed.

.PARAMETER VMName
Optional exact VM name. Wildcard characters are not permitted.

.PARAMETER DiskNumber
Optional disk number from the disk list displayed for the selected VM.

.PARAMETER GBSizeToIncrease
Optional positive number of GB to add to the selected virtual disk.

.PARAMETER GuestCredential
Optional Windows guest administrator credential used to retrieve guest volume
labels and, if selected, extend a guest partition. If omitted, the script asks
for a guest username and opens the standard PowerShell credential prompt.

.PARAMETER GuestOnly
Skips all vSphere virtual-disk changes and runs only the Windows guest partition
workflow. Use this to resume after the VMDK was already expanded.

.EXAMPLE
.\Expand-SQLVmDisk-v1.ps1 -VIServer vcsa01.contoso.com

.EXAMPLE
.\Expand-SQLVmDisk-v1.ps1 -VIServer vcsa01.contoso.com -VMName SQL01 -DiskNumber 2 -GBSizeToIncrease 100

.EXAMPLE
.\Expand-SQLVmDisk-v1.ps1 -VMName SQL01 -GuestOnly
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$VIServer,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw 'VMName cannot be blank.'
            }
            if ($_.IndexOfAny([char[]]'*?[]') -ge 0) {
                throw 'VMName cannot contain wildcard characters (*, ?, [, or ]).'
            }
            $true
        })]
    [string]$VMName,

    [Parameter()]
    [ValidateRange(1, 2147483647)]
    [int]$DiskNumber,

    [Parameter()]
    [ValidateScript({
            if ($_ -le 0) {
                throw 'GBSizeToIncrease must be greater than zero.'
            }
            $true
        })]
    [decimal]$GBSizeToIncrease,

    [Parameter()]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter()]
    [switch]$GuestOnly
)

$EnhancedUI = $true
$ErrorActionPreference = 'Stop'
$script:ExitRequested = $false
$script:VmdkExpanded = $false
$script:GuestPartitionDeleted = $false
$script:GuestPartitionExtended = $false
$script:ResolvedGuestCredential = $null
$vmNameWasSupplied = $PSBoundParameters.ContainsKey('VMName')
$diskNumberWasSupplied = $PSBoundParameters.ContainsKey('DiskNumber')
$sizeWasSupplied = $PSBoundParameters.ContainsKey('GBSizeToIncrease')

function Write-EnhancedUiBanner {
    if (-not $EnhancedUI) {
        return
    }

    $line = '=' * 72
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host '  SQL VM Disk Expansion Assistant - Version 1' -ForegroundColor Cyan
    Write-Host '  Guest volume labels | VMDK expansion | Recovery handling' -ForegroundColor Gray
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "Enter 'exit' at any text prompt to cancel.`n" -ForegroundColor DarkGray
}

function Write-AlignedDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Details,

        [Parameter()]
        [ValidateRange(0, 40)]
        [int]$Indent = 2,

        [Parameter()]
        [hashtable]$Colors
    )

    if ($Details.Count -eq 0) {
        return
    }

    $labelWidth = [int](($Details.Keys | ForEach-Object { ([string]$_).Length } | Measure-Object -Maximum).Maximum)
    $prefix = ' ' * $Indent
    foreach ($labelObject in $Details.Keys) {
        $label = [string]$labelObject
        $line = '{0}{1} : {2}' -f $prefix, $label.PadRight($labelWidth), $Details[$labelObject]
        if ($null -ne $Colors -and $Colors.ContainsKey($label)) {
            Write-Host $line -ForegroundColor $Colors[$label]
        }
        else {
            Write-Host $line
        }
    }
}

function Write-EnhancedUiPhase {
    param(
        [Parameter(Mandatory)]
        [string]$Progress,

        [Parameter(Mandatory)]
        [string]$Title
    )

    if (-not $EnhancedUI) {
        return
    }

    Write-Host "`n[$Progress] $Title" -ForegroundColor Cyan
    Write-Host ('-' * 72) -ForegroundColor DarkGray
    Write-Host ''
}

function Write-EnhancedUiStatus {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Info', 'Success', 'Action')]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $EnhancedUI) {
        return
    }

    $settings = switch ($Type) {
        'Success' { @{ Prefix = '[OK]'; Color = 'Green' } }
        'Action'  { @{ Prefix = '[>>]'; Color = 'Yellow' } }
        default   { @{ Prefix = '[i]'; Color = 'Gray' } }
    }
    Write-Host "$($settings.Prefix) $Message" -ForegroundColor $settings.Color
}

function Write-EnhancedUiSummary {
    param(
        [Parameter(Mandatory)]
        [string]$SelectedVM,

        [Parameter(Mandatory)]
        [string]$Progress,

        [Parameter()]
        [string]$SelectedDisk,

        [Parameter()]
        [Nullable[decimal]]$OldCapacityGB,

        [Parameter()]
        [Nullable[decimal]]$NewCapacityGB
    )

    if (-not $EnhancedUI) {
        return
    }

    Write-EnhancedUiPhase -Progress $Progress -Title 'Operation summary'
    $summaryDetails = [ordered]@{ 'VM' = $SelectedVM }
    $summaryColors = @{}
    if (-not [string]::IsNullOrWhiteSpace($SelectedDisk)) {
        $summaryDetails['Virtual disk'] = $SelectedDisk
    }
    if ($null -ne $OldCapacityGB -and $null -ne $NewCapacityGB) {
        $summaryDetails['vSphere capacity'] = "$OldCapacityGB GB -> $NewCapacityGB GB"
    }
    elseif ($GuestOnly) {
        $summaryDetails['vSphere capacity'] = 'Skipped (GuestOnly mode)'
    }
    $summaryDetails['Guest partition'] = if ($script:GuestPartitionExtended) { 'Extended' } else { 'Not extended' }
    if ($script:GuestPartitionDeleted) {
        $summaryDetails['Blocking partition'] = 'Deleted with confirmation'
        $summaryColors['Blocking partition'] = 'Yellow'
    }
    Write-AlignedDetails -Details $summaryDetails -Colors $summaryColors
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Read-ExitAwareInput {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $value = Read-Host -Prompt "$Prompt (enter 'exit' to cancel)"
    if ($null -eq $value) {
        return $null
    }

    $value = $value.Trim()
    if ($value -ieq 'exit') {
        $script:ExitRequested = $true
        return $null
    }

    return $value
}

function Stop-IfExitRequested {
    if ($script:ExitRequested) {
        if ($script:GuestPartitionDeleted) {
            Write-Host 'Stopped. A blocking guest partition was already deleted; the selected Windows partition was not extended.' -ForegroundColor Yellow
        }
        elseif ($script:VmdkExpanded) {
            Write-Host 'Stopped. The vSphere virtual disk was already expanded; no further guest changes were made.' -ForegroundColor Yellow
        }
        else {
            Write-Host 'No changes were made.' -ForegroundColor Yellow
        }
        exit 0
    }
}

function Get-VCenterConnection {
    # Do not call Get-VIServer here. In some PowerCLI versions it resolves to a
    # legacy alias for Connect-VIServer and prompts for its mandatory Server
    # parameter. PowerCLI stores active default connections in these variables.
    $existingConnections = @()
    foreach ($connection in (@($global:DefaultVIServer) + @($global:DefaultVIServers))) {
        if ($null -eq $connection) {
            continue
        }

        if ($connection.PSObject.Properties.Name -contains 'IsConnected' -and -not $connection.IsConnected) {
            continue
        }

        if (@($existingConnections | Where-Object { $_.Name -ieq $connection.Name }).Count -eq 0) {
            $existingConnections += $connection
        }
    }

    if ([string]::IsNullOrWhiteSpace($VIServer)) {
        if ($existingConnections.Count -eq 1) {
            return $existingConnections[0]
        }
    }

    $serverName = $VIServer
    while ([string]::IsNullOrWhiteSpace($serverName)) {
        $serverName = Read-ExitAwareInput -Prompt 'Enter the vCenter Server host name or IP address'
        Stop-IfExitRequested

        if ([string]::IsNullOrWhiteSpace($serverName)) {
            Write-Warning 'A vCenter Server host name or IP address is required.'
        }
    }

    $matchingConnection = @($existingConnections | Where-Object { $_.Name -ieq $serverName })
    if ($matchingConnection.Count -gt 0) {
        return $matchingConnection[0]
    }

    try {
        $connectionCredential = $Credential
        if ($null -eq $connectionCredential) {
            $connectionCredential = Get-Credential -Message "Enter credentials for vCenter Server '$serverName'."
            if ($null -eq $connectionCredential) {
                throw 'The vCenter credential prompt was cancelled.'
            }
        }

        return Connect-VIServer -Server $serverName -Credential $connectionCredential -ErrorAction Stop
    }
    catch {
        throw "Could not connect to vCenter Server '$serverName'. $($_.Exception.Message)"
    }
}

function Select-ExactVM {
    param(
        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter()]
        [string]$InitialVMName
    )

    $allVMs = @(Get-VM -Server $Server -ErrorAction Stop)

    if ($PSBoundParameters.ContainsKey('InitialVMName')) {
        # Do not use Get-VM -Name here: its -Name parameter supports wildcards.
        $matches = @($allVMs | Where-Object { $_.Name -ieq $InitialVMName })
        switch ($matches.Count) {
            0 { throw "No VM named '$InitialVMName' was found on $($Server.Name)." }
            1 { return $matches[0] }
            default { throw "More than one VM is named '$InitialVMName'. Use a unique VM name." }
        }
    }

    while ($true) {
        $vmName = Read-ExitAwareInput -Prompt 'Enter the exact virtual machine name'
        Stop-IfExitRequested

        if ([string]::IsNullOrWhiteSpace($vmName)) {
            Write-Warning 'A VM name is required.'
            continue
        }

        if ($vmName.IndexOfAny([char[]]'*?[]') -ge 0) {
            Write-Warning 'Wildcards are not allowed. Enter the VM name exactly.'
            continue
        }

        # Do not use Get-VM -Name here: its -Name parameter supports wildcards.
        $matches = @($allVMs | Where-Object { $_.Name -ieq $vmName })
        switch ($matches.Count) {
            0 {
                Write-Warning "No VM named '$vmName' was found on $($Server.Name)."
                continue
            }
            1 {
                return $matches[0]
            }
            default {
                Write-Warning "More than one VM is named '$vmName'. Use a unique VM name before running this script."
                continue
            }
        }
    }
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

function Get-SqlGuestVolumeLabelMap {
    param(
        [Parameter(Mandatory)]
        [object]$VM
    )

    $volumeLabelsByPath = @{}
    if ($VM.PowerState -ne 'PoweredOn') {
        Write-Warning "VM '$($VM.Name)' is not powered on. Guest volume labels will be unavailable."
        return $volumeLabelsByPath
    }

    $credential = Get-WindowsGuestCredential
    if ($null -eq $credential) {
        Write-Warning 'Guest volume labels will be unavailable; the vSphere disk workflow can still continue.'
        return $volumeLabelsByPath
    }

    try {
        Write-EnhancedUiStatus -Type Action -Message 'Retrieving Windows guest volume labels through VMware Tools...'
        $guestVolumes = @(Get-WindowsGuestVolumeLabels -VM $VM -Credential $credential)
        foreach ($guestVolume in $guestVolumes) {
            $normalizedPath = ConvertTo-NormalizedWindowsVolumePath -Path ([string]$guestVolume.Path)
            if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
                continue
            }

            $volumeLabelsByPath[$normalizedPath] = [string]$guestVolume.Label
        }

        Write-EnhancedUiStatus -Type Success -Message "Retrieved $($guestVolumes.Count) mounted Windows volume(s)."
    }
    catch {
        Write-Warning "Guest volume labels could not be retrieved: $($_.Exception.Message)"
        Write-Warning 'The vSphere disk workflow can still continue; unavailable labels will not be guessed.'
        if ($null -eq $GuestCredential) {
            $script:ResolvedGuestCredential = $null
        }
    }

    return $volumeLabelsByPath
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

function Select-HardDisk {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object]$Server,

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

        [pscustomobject]@{
            Number                     = $index + 1
            Disk                       = $disks[$index].Name
            GuestVolumes               = Get-GuestVolumeDisplayForHardDisk -HardDisk $disks[$index] -VolumeLabelsByPath $VolumeLabelsByPath
            HardDiskCapacityGB         = [decimal]$disks[$index].CapacityGB
            DatastoreFreeGB            = if ($null -ne $datastoreSpace) { [decimal]$datastoreSpace.FreeSpaceGB } else { 'Unavailable' }
            DatastoreProvisionedGB     = if ($null -ne $datastoreSpace) { [decimal]$datastoreSpace.ProvisionedSpaceGB } else { 'Unavailable' }
            DatastoreFile              = $disks[$index].Filename
        }
    }
    $diskList | Format-Table -AutoSize | Out-Host
    Write-Host ''

    if ($PSBoundParameters.ContainsKey('InitialDiskNumber')) {
        if ($InitialDiskNumber -gt $disks.Count) {
            throw "Disk number $InitialDiskNumber is invalid. VM '$($VM.Name)' has $($disks.Count) virtual disk(s)."
        }

        return $disks[$InitialDiskNumber - 1]
    }

    while ($true) {
        $choice = Read-ExitAwareInput -Prompt 'Select the virtual disk to expand by entering its number'
        Stop-IfExitRequested

        [int]$diskNumber = 0
        if (-not [int]::TryParse($choice, [ref]$diskNumber) -or $diskNumber -lt 1 -or $diskNumber -gt $disks.Count) {
            Write-Warning "Enter a number from 1 to $($disks.Count)."
            Write-Host ''
            continue
        }

        return $disks[$diskNumber - 1]
    }
}

function Read-AdditionalCapacityGB {
    param(
        [Parameter()]
        [decimal]$InitialAdditionalGB
    )

    if ($PSBoundParameters.ContainsKey('InitialAdditionalGB')) {
        return $InitialAdditionalGB
    }

    Write-Host ''
    while ($true) {
        $inputValue = Read-ExitAwareInput -Prompt 'Enter the capacity to add, in GB'
        Stop-IfExitRequested

        [decimal]$additionalGB = 0
        if (-not [decimal]::TryParse(
                $inputValue,
                [System.Globalization.NumberStyles]::Number,
                [System.Globalization.CultureInfo]::CurrentCulture,
                [ref]$additionalGB
            ) -or $additionalGB -le 0) {
            Write-Warning 'Enter a positive number of GB, for example 50 or 25.5.'
            Write-Host ''
            continue
        }

        return $additionalGB
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    while ($true) {
        $answer = Read-ExitAwareInput -Prompt "$Prompt [yes/no]"
        Stop-IfExitRequested

        switch -Regex ($answer) {
            '^(?i:y|yes)$' { return $true }
            '^(?i:n|no)$'  { return $false }
            default {
                Write-Warning "Enter yes, no, or 'exit'."
                Write-Host ''
            }
        }
    }
}

function Get-WindowsGuestCredential {
    if ($null -ne $script:ResolvedGuestCredential) {
        return $script:ResolvedGuestCredential
    }

    if ($null -ne $GuestCredential) {
        $script:ResolvedGuestCredential = $GuestCredential
        return $script:ResolvedGuestCredential
    }

    Write-Host ''
    $userName = Read-ExitAwareInput -Prompt 'Enter the Windows guest administrator user name'
    Stop-IfExitRequested

    try {
        $credential = Get-Credential -UserName $userName -Message "Enter the password for Windows guest account '$userName'. Select Cancel to continue without guest information."
        if ($null -eq $credential) {
            Write-Host ''
            Write-Warning 'Windows guest authentication was cancelled.'
        }
        $script:ResolvedGuestCredential = $credential
        return $script:ResolvedGuestCredential
    }
    catch {
        Write-Warning 'Windows guest authentication was cancelled.'
        return $null
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

function Get-WindowsGuestPartitions {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $scriptText = @'
$ErrorActionPreference = 'Stop'
Update-HostStorageCache

$recoveryGptType = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
$partitions = foreach ($disk in Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' }) {
    foreach ($partition in Get-Partition -DiskNumber $disk.Number) {
        $volume = Get-Volume -Partition $partition -ErrorAction SilentlyContinue
        [pscustomobject]@{
            DiskNumber      = $disk.Number
            DiskSizeGB      = [math]::Round($disk.Size / 1GB, 2)
            PartitionNumber = $partition.PartitionNumber
            DriveLetter     = if ($null -ne $volume -and $null -ne $volume.DriveLetter) { $volume.DriveLetter } else { '' }
            Label           = if ($null -ne $volume) { $volume.FileSystemLabel } else { '' }
            SizeGB          = [math]::Round($partition.Size / 1GB, 2)
            Type            = $partition.Type
            IsRecovery      = ($partition.Type -eq 'Recovery' -or $partition.GptType -eq $recoveryGptType)
        }
    }
}

@($partitions) | ConvertTo-Json -Depth 4 -Compress
'@

    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw 'The Windows guest did not return any partitions.'
    }

    return @($json | ConvertFrom-Json -ErrorAction Stop)
}

function Select-WindowsGuestPartition {
    param(
        [Parameter(Mandatory)]
        [object[]]$Partitions
    )

    Write-Host "`nWindows guest disks and partitions:" -ForegroundColor Cyan
    $Partitions |
        Sort-Object DiskNumber, PartitionNumber |
        Select-Object DiskNumber,
            PartitionNumber,
            DriveLetter,
            Label,
            @{ Name = 'PartitionSizeGB'; Expression = { $_.SizeGB } },
            DiskSizeGB,
            Type,
            IsRecovery |
        Format-Table -AutoSize |
        Out-Host
    Write-Host ''

    while ($true) {
        $diskInput = Read-ExitAwareInput -Prompt 'Select the Windows disk corresponding to the expanded virtual disk by entering its disk number'
        Stop-IfExitRequested

        [int]$guestDiskNumber = 0
        if (-not [int]::TryParse($diskInput, [ref]$guestDiskNumber) -or -not ($Partitions.DiskNumber -contains $guestDiskNumber)) {
            Write-Warning 'Enter a disk number shown in the list.'
            Write-Host ''
            continue
        }

        Write-Host ''
        $partitionInput = Read-ExitAwareInput -Prompt "Select the partition to extend on Windows disk $guestDiskNumber by entering its partition number"
        Stop-IfExitRequested

        [int]$guestPartitionNumber = 0
        if (-not [int]::TryParse($partitionInput, [ref]$guestPartitionNumber)) {
            Write-Warning 'Enter a partition number shown for that disk.'
            Write-Host ''
            continue
        }

        $selectedPartition = @($Partitions | Where-Object {
                $_.DiskNumber -eq $guestDiskNumber -and $_.PartitionNumber -eq $guestPartitionNumber
            })

        if ($selectedPartition.Count -ne 1) {
            Write-Warning 'Enter a partition number shown for that disk.'
            Write-Host ''
            continue
        }

        if ([bool]$selectedPartition[0].IsRecovery -or $selectedPartition[0].Type -in @('System', 'Reserved')) {
            Write-Warning 'Recovery, system, and reserved partitions cannot be selected for extension.'
            Write-Host ''
            continue
        }

        return $selectedPartition[0]
    }
}

function Get-WindowsPartitionExtensionState {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory)]
        [object]$Partition
    )

    $scriptText = @'
$ErrorActionPreference = 'Stop'
$diskNumber = __DISK_NUMBER__
$partitionNumber = __PARTITION_NUMBER__
$recoveryGptType = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'

Update-HostStorageCache
$partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber
$supportedSize = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partitionNumber
$followingPartition = @(Get-Partition -DiskNumber $diskNumber |
    Where-Object { $_.Offset -gt $partition.Offset } |
    Sort-Object Offset |
    Select-Object -First 1)

$following = $null
if ($followingPartition.Count -eq 1) {
    $next = $followingPartition[0]
    $following = [pscustomobject]@{
        PartitionNumber = $next.PartitionNumber
        Type            = $next.Type
        IsRecovery      = ($next.Type -eq 'Recovery' -or $next.GptType -eq $recoveryGptType)
        SizeGB          = [math]::Round($next.Size / 1GB, 2)
    }
}

[pscustomobject]@{
    CurrentSizeGB     = [math]::Round($partition.Size / 1GB, 2)
    MaximumSizeGB     = [math]::Round($supportedSize.SizeMax / 1GB, 2)
    CanExtend         = ($supportedSize.SizeMax -gt $partition.Size)
    FollowingPartition = $following
} | ConvertTo-Json -Depth 4 -Compress
'@
    $scriptText = $scriptText.Replace('__DISK_NUMBER__', [string]$Partition.DiskNumber).Replace('__PARTITION_NUMBER__', [string]$Partition.PartitionNumber)

    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    return $json | ConvertFrom-Json -ErrorAction Stop
}

function Expand-WindowsGuestPartition {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory)]
        [object]$Partition
    )

    $scriptText = @'
$ErrorActionPreference = 'Stop'
$diskNumber = __DISK_NUMBER__
$partitionNumber = __PARTITION_NUMBER__

Update-HostStorageCache
$partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber
$supportedSize = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partitionNumber
if ($supportedSize.SizeMax -le $partition.Size) {
    throw 'There is no contiguous unallocated space after the selected partition.'
}

Resize-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -Size $supportedSize.SizeMax
$updatedPartition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber
[pscustomobject]@{
    NewSizeGB = [math]::Round($updatedPartition.Size / 1GB, 2)
} | ConvertTo-Json -Compress
'@
    $scriptText = $scriptText.Replace('__DISK_NUMBER__', [string]$Partition.DiskNumber).Replace('__PARTITION_NUMBER__', [string]$Partition.PartitionNumber)

    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    return $json | ConvertFrom-Json -ErrorAction Stop
}

function Confirm-WindowsRecoveryPartitionDeletion {
    param(
        [Parameter(Mandatory)]
        [object]$RecoveryPartition
    )

    Write-Warning "A $($RecoveryPartition.SizeGB) GB Windows Recovery partition (partition $($RecoveryPartition.PartitionNumber)) immediately follows the selected partition."
    Write-Warning 'Deleting it is permanent and disables Windows Recovery Environment (WinRE). The script will not recreate the Recovery partition or re-enable WinRE.'
    Write-Host ''

    if (-not (Read-YesNo -Prompt 'Do you authorize permanent deletion of this Windows Recovery partition?')) {
        Write-Host ''
        Write-Host 'The Recovery partition and Windows partition were not changed.' -ForegroundColor Yellow
        return $false
    }
    Write-Host ''

    while ($true) {
        $confirmation = Read-ExitAwareInput -Prompt "To confirm permanent deletion, enter DELETE RECOVERY for Windows Recovery partition $($RecoveryPartition.PartitionNumber)"
        Stop-IfExitRequested

        if ($confirmation -ceq 'DELETE RECOVERY') {
            return $true
        }

        Write-Warning "The Recovery partition was not confirmed for deletion. Type DELETE RECOVERY, or 'exit' to stop."
        Write-Host ''
    }
}

function Confirm-WindowsBlockingPartitionDeletion {
    param(
        [Parameter(Mandatory)]
        [object]$BlockingPartition
    )

    if ([bool]$BlockingPartition.IsRecovery) {
        return Confirm-WindowsRecoveryPartitionDeletion -RecoveryPartition $BlockingPartition
    }

    Write-Warning "Partition $($BlockingPartition.PartitionNumber) ($($BlockingPartition.Type), $($BlockingPartition.SizeGB) GB) immediately follows the selected partition and blocks extension."
    Write-Warning 'Deleting it is permanent and removes all data on that partition.'
    Write-Host ''

    if (-not (Read-YesNo -Prompt 'Do you authorize permanent deletion of this blocking partition?')) {
        Write-Host ''
        Write-Host 'The blocking partition and Windows partition were not changed.' -ForegroundColor Yellow
        return $false
    }
    Write-Host ''

    while ($true) {
        $confirmation = Read-ExitAwareInput -Prompt "To confirm permanent deletion, enter DELETE PARTITION for partition $($BlockingPartition.PartitionNumber)"
        Stop-IfExitRequested

        if ($confirmation -ceq 'DELETE PARTITION') {
            return $true
        }

        Write-Warning "The partition was not confirmed for deletion. Type DELETE PARTITION, or 'exit' to stop."
        Write-Host ''
    }
}

function Remove-WindowsRecoveryPartition {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory)]
        [object]$Partition,

        [Parameter(Mandatory)]
        [object]$RecoveryPartition
    )

    # Run WinRE disable and DiskPart deletion as separate VMware Tools calls.
    # Keeping each guest operation small avoids encoded-command length failures
    # and makes it clear which step failed.
    $disableScript = @'
$ErrorActionPreference = 'Stop'
$diskNumber = __DISK_NUMBER__
$partitionNumber = __PARTITION_NUMBER__
$recoveryPartitionNumber = __RECOVERY_PARTITION_NUMBER__
$recoveryGptType = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'

$recovery = Get-Partition -DiskNumber $diskNumber -PartitionNumber $recoveryPartitionNumber
if ($recovery.Type -ne 'Recovery' -and $recovery.GptType -ne $recoveryGptType) {
    throw "Partition $recoveryPartitionNumber is no longer identified as a Recovery partition."
}

$selectedPartition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber
$nextPartition = @(Get-Partition -DiskNumber $diskNumber |
    Where-Object { $_.Offset -gt $selectedPartition.Offset } |
    Sort-Object Offset |
    Select-Object -First 1)
if ($nextPartition.Count -ne 1 -or $nextPartition[0].PartitionNumber -ne $recoveryPartitionNumber) {
    throw "Recovery partition $recoveryPartitionNumber is no longer immediately after the selected partition."
}

if ($null -eq (Get-Command reagentc.exe -ErrorAction SilentlyContinue)) {
    throw 'reagentc.exe is unavailable, so the script will not delete the Recovery partition.'
}

$reagentOutput = & $env:ComSpec /d /c 'reagentc.exe /disable 2>&1' | Out-String
$reagentExitCode = $LASTEXITCODE

$winREAlreadyDisabled = $reagentOutput -match '(?i)Windows RE is already disabled'
if ($reagentExitCode -ne 0 -and -not $winREAlreadyDisabled) {
    throw "Unable to disable WinRE. Recovery partition was not deleted. reagentc.exe output: $reagentOutput"
}

[pscustomobject]@{
    RecoveryPartitionNumber = $recoveryPartitionNumber
    WinREDisabled           = $true
} | ConvertTo-Json -Compress
'@
    $disableScript = $disableScript.Replace('__DISK_NUMBER__', [string]$Partition.DiskNumber).Replace('__PARTITION_NUMBER__', [string]$Partition.PartitionNumber).Replace('__RECOVERY_PARTITION_NUMBER__', [string]$RecoveryPartition.PartitionNumber)
    $disableJson = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $disableScript
    $disableResult = $disableJson | ConvertFrom-Json -ErrorAction Stop

    Write-Host "WinRE is disabled. Deleting Recovery partition $($RecoveryPartition.PartitionNumber)..." -ForegroundColor Yellow

    $deleteScript = @'
$ErrorActionPreference = 'Stop'
$diskNumber = __DISK_NUMBER__
$partitionNumber = __PARTITION_NUMBER__
$recoveryPartitionNumber = __RECOVERY_PARTITION_NUMBER__
$recoveryGptType = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'

$recovery = Get-Partition -DiskNumber $diskNumber -PartitionNumber $recoveryPartitionNumber
if ($recovery.Type -ne 'Recovery' -and $recovery.GptType -ne $recoveryGptType) {
    throw "Partition $recoveryPartitionNumber is no longer identified as a Recovery partition."
}
$selected = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber
$next = @(Get-Partition -DiskNumber $diskNumber | Where-Object Offset -gt $selected.Offset | Sort-Object Offset | Select-Object -First 1)
if ($next.Count -ne 1 -or $next[0].PartitionNumber -ne $recoveryPartitionNumber) {
    throw "Recovery partition $recoveryPartitionNumber is no longer immediately after the selected partition."
}

$diskpartFile = Join-Path $env:TEMP ("Delete-Recovery-{0}.txt" -f [guid]::NewGuid().ToString('N'))
try {
    @"
select disk $diskNumber
select partition $recoveryPartitionNumber
delete partition override
"@ | Set-Content -Path $diskpartFile -Encoding Ascii -Force

    $diskpartCommand = 'diskpart.exe /s "{0}" 2>&1' -f $diskpartFile
    $diskpartOutput = & $env:ComSpec /d /c $diskpartCommand | Out-String
    $diskpartExitCode = $LASTEXITCODE

    if ($diskpartExitCode -ne 0) {
        throw "DiskPart could not delete the Recovery partition. DiskPart output: $diskpartOutput"
    }
}
finally {
    Remove-Item -Path $diskpartFile -Force -ErrorAction SilentlyContinue
}

Update-HostStorageCache
if ($null -ne (Get-Partition -DiskNumber $diskNumber -PartitionNumber $recoveryPartitionNumber -ErrorAction SilentlyContinue)) {
    throw "DiskPart completed but Recovery partition $recoveryPartitionNumber still exists."
}

[pscustomobject]@{
    RecoveryPartitionNumber = $recoveryPartitionNumber
    WinREDisabled           = $true
} | ConvertTo-Json -Compress
'@
    $deleteScript = $deleteScript.Replace('__DISK_NUMBER__', [string]$Partition.DiskNumber).Replace('__PARTITION_NUMBER__', [string]$Partition.PartitionNumber).Replace('__RECOVERY_PARTITION_NUMBER__', [string]$RecoveryPartition.PartitionNumber)

    $deleteJson = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $deleteScript
    $deleteResult = $deleteJson | ConvertFrom-Json -ErrorAction Stop
    if (-not [bool]$disableResult.WinREDisabled) {
        throw 'WinRE disable verification was not returned by the guest.'
    }
    return $deleteResult
}

function Remove-WindowsBlockingPartition {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory)]
        [object]$Partition,

        [Parameter(Mandatory)]
        [object]$BlockingPartition
    )

    if ([bool]$BlockingPartition.IsRecovery) {
        return Remove-WindowsRecoveryPartition -VM $VM -Credential $Credential -Partition $Partition -RecoveryPartition $BlockingPartition
    }

    $scriptText = @'
$ErrorActionPreference = 'Stop'
$diskNumber = __DISK_NUMBER__
$partitionNumber = __PARTITION_NUMBER__
$blockingPartitionNumber = __BLOCKING_PARTITION_NUMBER__

$selectedPartition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber
$nextPartition = @(Get-Partition -DiskNumber $diskNumber |
    Where-Object { $_.Offset -gt $selectedPartition.Offset } |
    Sort-Object Offset |
    Select-Object -First 1)
if ($nextPartition.Count -ne 1 -or $nextPartition[0].PartitionNumber -ne $blockingPartitionNumber) {
    throw "Partition $blockingPartitionNumber is no longer immediately after the selected partition."
}

$diskpartFile = Join-Path $env:TEMP ("Delete-Partition-{0}.txt" -f [guid]::NewGuid().ToString('N'))
try {
    @"
select disk $diskNumber
select partition $blockingPartitionNumber
delete partition override
"@ | Set-Content -Path $diskpartFile -Encoding Ascii -Force

    $diskpartCommand = 'diskpart.exe /s "{0}" 2>&1' -f $diskpartFile
    $diskpartOutput = & $env:ComSpec /d /c $diskpartCommand | Out-String
    $diskpartExitCode = $LASTEXITCODE

    if ($diskpartExitCode -ne 0) {
        throw "DiskPart could not delete the blocking partition. DiskPart output: $diskpartOutput"
    }
}
finally {
    Remove-Item -Path $diskpartFile -Force -ErrorAction SilentlyContinue
}

Update-HostStorageCache
if ($null -ne (Get-Partition -DiskNumber $diskNumber -PartitionNumber $blockingPartitionNumber -ErrorAction SilentlyContinue)) {
    throw "DiskPart completed but blocking partition $blockingPartitionNumber still exists."
}

[pscustomobject]@{
    BlockingPartitionNumber = $blockingPartitionNumber
    WinREDisabled           = $false
} | ConvertTo-Json -Compress
'@
    $scriptText = $scriptText.Replace('__DISK_NUMBER__', [string]$Partition.DiskNumber).Replace('__PARTITION_NUMBER__', [string]$Partition.PartitionNumber).Replace('__BLOCKING_PARTITION_NUMBER__', [string]$BlockingPartition.PartitionNumber)

    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    return $json | ConvertFrom-Json -ErrorAction Stop
}

function Invoke-WindowsGuestPartitionExtension {
    param(
        [Parameter(Mandatory)]
        [object]$VM
    )

    if ($VM.PowerState -ne 'PoweredOn') {
        Write-Warning "VM '$($VM.Name)' is not powered on. No guest partition was changed."
        return
    }

    $credential = Get-WindowsGuestCredential
    if ($null -eq $credential) {
        return
    }

    $partitions = Get-WindowsGuestPartitions -VM $VM -Credential $credential
    Write-Host ''
    if (-not (Read-YesNo -Prompt 'Proceed to select a Windows partition for extension?')) {
        Write-Host ''
        Write-Host 'No guest partition was changed.' -ForegroundColor Yellow
        return
    }

    $partition = Select-WindowsGuestPartition -Partitions $partitions
    $extensionState = Get-WindowsPartitionExtensionState -VM $VM -Credential $credential -Partition $partition
    $following = $extensionState.FollowingPartition

    if ($null -ne $following) {
        if (-not (Confirm-WindowsBlockingPartitionDeletion -BlockingPartition $following)) {
            return
        }

        $removalResult = Remove-WindowsBlockingPartition -VM $VM -Credential $credential -Partition $partition -BlockingPartition $following
        $script:GuestPartitionDeleted = $true
        if ([bool]$following.IsRecovery) {
            Write-Warning "Deleted Recovery partition $($removalResult.RecoveryPartitionNumber). WinRE is now disabled."
        }
        else {
            Write-Warning "Deleted blocking partition $($removalResult.BlockingPartitionNumber)."
        }

        $extensionState = Get-WindowsPartitionExtensionState -VM $VM -Credential $credential -Partition $partition
        $following = $extensionState.FollowingPartition
        if ($null -ne $following) {
            Write-Warning "Partition $($following.PartitionNumber) ($($following.Type)) still follows the selected partition and blocks extension. No Windows partition was extended."
            return
        }

        if (-not [bool]$extensionState.CanExtend) {
            Write-Warning 'The blocking partition was deleted, but the selected Windows partition still has no contiguous unallocated space to extend into. No Windows partition was extended.'
            return
        }

        Write-Host "Verified: after deleting the blocking partition, Windows disk $($partition.DiskNumber), partition $($partition.PartitionNumber) can now grow from $($extensionState.CurrentSizeGB) GB to $($extensionState.MaximumSizeGB) GB." -ForegroundColor Green
        Write-Host ''
    }

    if (-not [bool]$extensionState.CanExtend) {
        Write-Warning 'There is no contiguous unallocated space after the selected partition. No guest partition was changed.'
        return
    }

    Write-Host "The selected Windows partition can grow from $($extensionState.CurrentSizeGB) GB to $($extensionState.MaximumSizeGB) GB." -ForegroundColor Cyan
    Write-Host ''
    if (-not (Read-YesNo -Prompt 'Extend the selected Windows partition now?')) {
        Write-Host ''
        Write-Host 'No guest partition was changed.' -ForegroundColor Yellow
        return
    }
    Write-Host ''

    $result = Expand-WindowsGuestPartition -VM $VM -Credential $credential -Partition $partition
    $script:GuestPartitionExtended = $true
    Write-Host "Successfully extended Windows disk $($partition.DiskNumber), partition $($partition.PartitionNumber) to $($result.NewSizeGB) GB." -ForegroundColor Green
}

try {
    Write-EnhancedUiBanner
    Write-EnhancedUiPhase -Progress $(if ($GuestOnly) { '1/2' } else { '1/4' }) -Title 'Connect to vCenter and select the VM'
    $server = Get-VCenterConnection
    Write-Host "Connected to vCenter Server: $($server.Name)" -ForegroundColor Green
    Write-EnhancedUiStatus -Type Success -Message "Using vCenter connection '$($server.Name)'."

    $vmArguments = @{ Server = $server }
    if ($vmNameWasSupplied) {
        $vmArguments.InitialVMName = $VMName
    }
    $vm = Select-ExactVM @vmArguments
    if (-not $vmNameWasSupplied) {
        Write-Host ''
    }
    Write-EnhancedUiStatus -Type Success -Message "Selected VM '$($vm.Name)'."

    if ($GuestOnly) {
        Write-EnhancedUiPhase -Progress '2/2' -Title 'Inspect and extend the Windows guest partition'
        Write-Warning "Guest-only mode: no vSphere virtual disk capacity will be changed on '$($vm.Name)'."
        Invoke-WindowsGuestPartitionExtension -VM $vm
        Write-EnhancedUiSummary -SelectedVM $vm.Name -Progress '2/2'
        return
    }

    Write-EnhancedUiPhase -Progress '2/4' -Title 'Inspect guest volumes, then select and expand the vSphere virtual disk'
    $volumeLabelsByPath = @{}
    if ($null -eq (Get-Command -Name Get-VMGuestDisk -ErrorAction SilentlyContinue)) {
        Write-Warning 'Get-VMGuestDisk is not available in this PowerCLI installation. Guest volume mappings will be unavailable.'
    }
    else {
        $volumeLabelsByPath = Get-SqlGuestVolumeLabelMap -VM $vm
    }

    $diskArguments = @{
        VM                     = $vm
        Server                 = $server
        VolumeLabelsByPath     = $volumeLabelsByPath
    }
    if ($diskNumberWasSupplied) {
        $diskArguments.InitialDiskNumber = $DiskNumber
    }
    $disk = Select-HardDisk @diskArguments
    if (-not $diskNumberWasSupplied) {
        Write-Host ''
    }
    Write-EnhancedUiStatus -Type Info -Message "Selected $($disk.Name) with current capacity $($disk.CapacityGB) GB."

    $capacityArguments = @{}
    if ($sizeWasSupplied) {
        $capacityArguments.InitialAdditionalGB = $GBSizeToIncrease
    }
    $additionalGB = Read-AdditionalCapacityGB @capacityArguments

    [decimal]$currentCapacityGB = $disk.CapacityGB
    [decimal]$newCapacityGB = $currentCapacityGB + $additionalGB

    Write-Host "`nPlanned change:" -ForegroundColor Cyan
    Write-AlignedDetails -Details ([ordered]@{
            'VM'       = $vm.Name
            'Disk'     = $disk.Name
            'VMDK'     = $disk.Filename
            'Capacity' = "$currentCapacityGB GB -> $newCapacityGB GB"
        })
    Write-Host ''

    while ($true) {
        $confirmation = Read-ExitAwareInput -Prompt "To confirm, enter YES to expand '$($disk.Name)' on '$($vm.Name)'"
        Stop-IfExitRequested

        if ($confirmation -ceq 'YES') {
            break
        }

        Write-Warning "The change has not been confirmed. Enter YES to proceed, or 'exit' to cancel."
        Write-Host ''
    }
    Write-Host ''

    Write-EnhancedUiStatus -Type Action -Message "Expanding $($disk.Name) to $newCapacityGB GB in vSphere..."
    Set-HardDisk -HardDisk $disk -CapacityGB $newCapacityGB -Confirm:$false -ErrorAction Stop | Out-Null
    $script:VmdkExpanded = $true

    Write-Host "`nSuccessfully expanded '$($disk.Name)' on '$($vm.Name)' by $additionalGB GB." -ForegroundColor Green
    Write-EnhancedUiStatus -Type Success -Message 'The vSphere virtual disk expansion completed.'

    Write-EnhancedUiPhase -Progress '3/4' -Title 'Optional Windows guest partition extension'
    if (Read-YesNo -Prompt 'Would you like to review and extend a Windows guest partition?') {
        Invoke-WindowsGuestPartitionExtension -VM $vm
    }
    else {
        Write-Host ''
        Write-Host 'The Windows partition/volume was not extended.' -ForegroundColor Yellow
    }

    Write-EnhancedUiSummary -SelectedVM $vm.Name -Progress '4/4' -SelectedDisk $disk.Name -OldCapacityGB $currentCapacityGB -NewCapacityGB $newCapacityGB
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
