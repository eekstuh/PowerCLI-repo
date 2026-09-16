#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core

<#
.SYNOPSIS
Expands one existing virtual disk on a vSphere VM with an enhanced Version 3 console interface.

.DESCRIPTION
Automatically selects the workflow from the guest OS name reported by VMware Tools.
Windows Server guests use the SQL volume-label workflow; Windows desktop guests
use the Windows Workstation workflow. VM names do not determine the workflow.
Missing or unrecognized guest OS information prevents that VM from continuing.
If VMware Tools is not running or cannot report a supported Windows OS, the script
warns the operator and returns to the VM name prompt.
SQL mode retrieves and maps Windows volume labels before disk selection and reuses
the guest credentials for partition extension. Failed guest inventory stops the
workflow before expansion. Missing per-disk mappings or labels are displayed as
unavailable; disk and Windows partition selection remain manual. Both workflows retain snapshot checks,
assigned-name lookup, authentication retry, and explicit mutation confirmations.
Only the SQL workflow disk list includes GuestVolumeFreeGB from the latest VMware Tools report.
Multiple mapped volumes are listed separately by path. Missing mapping or free-space
data displays Unavailable. This column does not require additional guest credentials
and does not include unpartitioned space on the VMDK.

Prompts for a VM name, a disk number, and an amount to add in GB unless those
values are supplied as parameters. If an entered name starting with 11VMDEV,
11VMGC, or 11VMHIV is not found exactly, the script searches for an assigned name in the form
'EnteredName - Assigned User' and requires confirmation before using it. VM name
wildcard characters (*, ?, [, ]) are rejected. Enter 'exit' at any script prompt
to cancel the remaining workflow; before confirmation it makes no changes, and
after VMDK expansion it prevents further guest changes.
In the Windows Workstation workflow, enter 'skip' at the capacity prompt to leave
the VMDK unchanged and proceed directly to Windows partition expansion.
At the Windows partition prompt, enter 'back' to select a different Windows disk.

This script expands the VMDK only.  It does not extend a Windows partition or
volume inside the guest OS unless you opt in after the VMDK expansion. The
guest extension requires VMware Tools and a Windows administrator credential.
If a Recovery or another partition follows the chosen partition, the script
stops before extending it. You may explicitly authorize deletion of that
adjacent blocking partition. Deleting a Recovery partition also disables WinRE.
Online Windows disks with no partitions are displayed as 'No partitions' and
cannot be selected for partition extension.

VMDK expansion stops if the VM has snapshots. Remove the snapshots and wait
for removal to complete before running the script again. The script checks
before disk selection and again immediately before expansion; it does not
remove snapshots. GuestOnly mode skips this vSphere expansion check.

.PARAMETER VIServer
Optional vCenter Server name. If omitted, the active default PowerCLI
connection is used when exactly one is available; otherwise the script prompts
for a vCenter Server.

.PARAMETER Credential
Optional credential passed to Connect-VIServer when a new connection is needed.

.PARAMETER VMName
Optional VM name. Assigned-name fallback applies only to 11VMDEV, 11VMGC, and
11VMHIV prefixes. If it is not found exactly and one assigned VM matches the
name followed by ' - Assigned User', the script displays that VM and asks for
confirmation. Wildcard characters are not permitted.

.PARAMETER DiskNumber
Optional disk number from the disk list displayed for the selected VM.

.PARAMETER GBSizeToIncrease
Optional positive number of GB to add to the selected virtual disk.

.PARAMETER GuestCredential
Optional Windows guest administrator credential used for SQL volume-label inventory
and, in either workflow, if you choose to extend a guest partition. If omitted, the script asks for a guest username and
opens the standard PowerShell credential prompt. If authentication fails while
reading the initial guest partition inventory, the script prompts for a new
username and password, including when GuestCredential was supplied initially.

.PARAMETER GuestOnly
Skips all vSphere virtual-disk changes and runs only the Windows guest partition
workflow. Use this to resume after the VMDK was already expanded.

.EXAMPLE
.\Expand-VSphereVmDisk-v3.ps1 -VIServer vcsa01.contoso.com

.EXAMPLE
.\Expand-VSphereVmDisk-v3.ps1 -VIServer vcsa01.contoso.com -VMName APP01 -DiskNumber 2 -GBSizeToIncrease 100

.EXAMPLE
.\Expand-VSphereVmDisk-v3.ps1 -VMName APP01 -GuestOnly
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
$script:ResolvedGuestCredential = $null
$script:ExitRequested = $false
$script:VmdkExpanded = $false
$script:GuestPartitionDeleted = $false
$script:GuestPartitionExtended = $false
$vmNameWasSupplied = $PSBoundParameters.ContainsKey('VMName')
$diskNumberWasSupplied = $PSBoundParameters.ContainsKey('DiskNumber')
$sizeWasSupplied = $PSBoundParameters.ContainsKey('GBSizeToIncrease')

function Write-EnhancedUiBanner {
    if (-not $EnhancedUI) {
        return
    }

    $line = '=' * 72
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host '  vSphere Windows VM Disk Expansion Assistant - Version 3.0' -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "Enter 'exit' at any text prompt to cancel." -ForegroundColor DarkGray
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

function Write-VCenterConnectionDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Server
    )

    $connections = @($Server | Where-Object { $null -ne $_ })
    if ($connections.Count -eq 0) {
        throw 'No vCenter Server connection details are available.'
    }

    Write-Host ''
    $heading = if ($connections.Count -eq 1) { 'Connected to vCenter Server:' } else { 'Connected to vCenter Servers:' }
    Write-Host $heading -ForegroundColor Green
    for ($index = 0; $index -lt $connections.Count; $index++) {
        $connection = $connections[$index]
        if ($connections.Count -gt 1) {
            Write-Host "  Connection $($index + 1)" -ForegroundColor Green
        }
        $version = [string]$connection.Version
        if ([string]::IsNullOrWhiteSpace($version)) {
            $version = 'Unavailable'
        }
        $build = [string]$connection.Build
        if ([string]::IsNullOrWhiteSpace($build)) {
            $build = 'Unavailable'
        }
        $indent = if ($connections.Count -eq 1) { 2 } else { 4 }
        Write-AlignedDetails -Indent $indent -Details ([ordered]@{
                'Host name' = [string]$connection.Name
                'Version'   = $version
                'Build'     = $build
            })
    }
    Write-Host ''
}

function Write-EnhancedUiPhase {
    param(
        [Parameter(Mandatory)]
        [string]$Progress,

        [Parameter(Mandatory)]
        [string]$Title,

        [switch]$NoTrailingBlankLine
    )

    if (-not $EnhancedUI) {
        return
    }

    Write-Host "`n[$Progress] $Title" -ForegroundColor Cyan
    Write-Host ('-' * 72) -ForegroundColor DarkGray
    if (-not $NoTrailingBlankLine) {
        Write-Host ''
    }
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
        [Nullable[decimal]]$NewCapacityGB,

        [Parameter()]
        [switch]$VmdkSkipped
    )

    if (-not $EnhancedUI) {
        return
    }

    Write-EnhancedUiPhase -Progress $Progress -Title 'Operation summary' -NoTrailingBlankLine
    $summaryDetails = [ordered]@{ 'VM' = $SelectedVM }
    $summaryColors = @{}
    if (-not [string]::IsNullOrWhiteSpace($SelectedDisk)) {
        $summaryDetails['Virtual disk'] = $SelectedDisk
    }
    if ($null -ne $OldCapacityGB -and $null -ne $NewCapacityGB) {
        $summaryDetails['vSphere capacity'] = "$OldCapacityGB GB -> $NewCapacityGB GB"
    }
    elseif ($VmdkSkipped) {
        $summaryDetails['vSphere capacity'] = 'Skipped by operator'
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
        [string]$Prompt,

        [Parameter()]
        [string]$PromptOptions = "enter 'exit' to cancel"
    )

    $value = Read-Host -Prompt "$Prompt ($PromptOptions)"
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
            Write-Host ''
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
    $initialNameWasSupplied = $PSBoundParameters.ContainsKey('InitialVMName')
    $candidateName = if ($initialNameWasSupplied) { ([string]$InitialVMName).Trim() } else { '' }

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($candidateName)) {
            $candidateName = Read-ExitAwareInput -Prompt 'Enter VM name'
            Stop-IfExitRequested
        }

        if ([string]::IsNullOrWhiteSpace($candidateName)) {
            Write-Warning 'A VM name is required.'
            Write-Host ''
            $candidateName = ''
            continue
        }

        if ($candidateName.IndexOfAny([char[]]'*?[]') -ge 0) {
            Write-Warning 'Wildcards are not allowed. Enter the VM name exactly.'
            if ($initialNameWasSupplied) {
                throw "VMName '$candidateName' cannot contain wildcard characters (*, ?, [, or ])."
            }
            Write-Host ''
            $candidateName = ''
            continue
        }

        # Do not use Get-VM -Name here: its -Name parameter supports wildcards.
        $exactMatches = @($allVMs | Where-Object { $_.Name -ieq $candidateName })
        if ($exactMatches.Count -eq 1) {
            return $exactMatches[0]
        }
        if ($exactMatches.Count -gt 1) {
            $message = "More than one VM is named '$candidateName'. Use a unique VM name before running this script."
            if ($initialNameWasSupplied) {
                throw $message
            }
            Write-Warning $message
            Write-Host ''
            $candidateName = ''
            continue
        }

        if ($candidateName -notmatch '(?i)^11VM(?:DEV|GC|HIV)') {
            $message = "'$candidateName' was not found on vCenter Server '$($Server.Name)'. Verify the VM inventory name and selected vCenter Server."
            if ($initialNameWasSupplied) {
                throw $message
            }
            Write-Warning $message
            Write-Host ''
            $candidateName = ''
            continue
        }

        Write-Warning "'$candidateName' was not found on vCenter Server '$($Server.Name)'."
        Write-Host 'Searching for an assigned VM name...' -ForegroundColor Cyan

        $escapedBaseName = [regex]::Escape($candidateName)
        $assignedMatches = @(
            $allVMs |
                Where-Object { $_.Name -imatch "^$escapedBaseName\s+-\s+.+$" } |
                Sort-Object Name
        )

        if ($assignedMatches.Count -eq 1) {
            $assignedVM = $assignedMatches[0]
            Write-Host "`nAssigned VM found:" -ForegroundColor Cyan
            Write-AlignedDetails -Details ([ordered]@{
                    'Entered VM name'  = $candidateName
                    'Assigned VM name' = $assignedVM.Name
                })
            Write-Host ''
            if (Read-YesNo -Prompt "Is '$($assignedVM.Name)' the correct VM?") {
                if ($initialNameWasSupplied) {
                    Write-Host ''
                }
                return $assignedVM
            }

            $message = "Assigned VM '$($assignedVM.Name)' was not confirmed."
            if ($initialNameWasSupplied) {
                throw $message
            }
            Write-Host ''
            Write-Host "$message Enter another VM name." -ForegroundColor Yellow
            Write-Host ''
            $candidateName = ''
            continue
        }

        if ($assignedMatches.Count -gt 1) {
            $matchingNames = @($assignedMatches.Name)
            $message = "More than one assigned VM matches base name '$candidateName': $($matchingNames -join ', '). Enter the complete assigned VM name."
        }
        else {
            $message = "No assigned VM matching '$candidateName - <assigned user>' was found on vCenter Server '$($Server.Name)'."
        }

        if ($initialNameWasSupplied) {
            throw $message
        }
        Write-Warning $message
        Write-Host ''
        $candidateName = ''
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

function Get-DiskExpansionWorkflow {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$GuestOSName)

    if ([string]::IsNullOrWhiteSpace($GuestOSName)) {
        throw 'VMware Tools has not reported a guest OS name. Verify VMware Tools is running and reporting the OS, then try again.'
    }
    if ($GuestOSName -notmatch '(?i)\bWindows\b') {
        throw "Guest OS '$GuestOSName' is not Windows. This script supports Windows guests only."
    }
    if ($GuestOSName -match '(?i)\bServer\b') { return 'SQL' }
    if ($GuestOSName -match '(?i)\bWindows\s+(?:11|10|8(?:\.1)?|7|Vista|XP)\b') { return 'Windows' }
    throw "Cannot determine whether guest OS '$GuestOSName' is Windows Server or desktop. Verify the OS information reported by VMware Tools."
}

function Select-VMWithGuestWorkflow {
    param(
        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter()]
        [string]$InitialVMName
    )

    $useInitialVMName = $PSBoundParameters.ContainsKey('InitialVMName')
    while ($true) {
        $vmArguments = @{ Server = $Server }
        if ($useInitialVMName) {
            $vmArguments.InitialVMName = $InitialVMName
        }

        $selectedVM = Select-ExactVM @vmArguments
        if (-not $useInitialVMName) {
            Write-Host ''
        }
        Write-EnhancedUiStatus -Type Success -Message "Selected VM '$($selectedVM.Name)'."

        try {
            $selectedVM.ExtensionData.UpdateViewData('Guest')
        }
        catch {
            Write-Warning "Could not retrieve VMware Tools guest information for VM '$($selectedVM.Name)': $($_.Exception.Message)"
            Write-Host 'Please enable VMware Tools on the selected VM or enter another VM name.' -ForegroundColor Yellow
            Write-Host ''
            $useInitialVMName = $false
            continue
        }

        $toolsRunningStatus = [string]$selectedVM.ExtensionData.Guest.ToolsRunningStatus
        if ($toolsRunningStatus -notin @('guestToolsRunning', 'guestToolsExecutingScripts')) {
            $displayStatus = if ([string]::IsNullOrWhiteSpace($toolsRunningStatus)) { 'not reported' } else { $toolsRunningStatus }
            Write-Warning "VMware Tools is not running on VM '$($selectedVM.Name)' (status: $displayStatus)."
            Write-Host 'Please enable VMware Tools on the selected VM or enter another VM name.' -ForegroundColor Yellow
            Write-Host ''
            $useInitialVMName = $false
            continue
        }

        $guestOSName = [string]$selectedVM.ExtensionData.Guest.GuestFullName
        try {
            $workflow = Get-DiskExpansionWorkflow -GuestOSName $guestOSName
        }
        catch {
            Write-Warning $_.Exception.Message
            Write-Host 'No changes were made. Enter another VM name.' -ForegroundColor Yellow
            Write-Host ''
            $useInitialVMName = $false
            continue
        }

        return [pscustomobject]@{
            VM          = $selectedVM
            GuestOSName = $guestOSName
            Workflow    = $workflow
        }
    }
}

function Get-CombinedGuestVolumeLabelMap {
    param([Parameter(Mandatory)][object]$VM)

    if ($VM.PowerState -ne 'PoweredOn') {
        throw 'The SQL volume-label workflow requires a powered-on VM.'
    }
    if ($null -eq (Get-Command -Name Get-VMGuestDisk -ErrorAction SilentlyContinue)) {
        throw 'Get-VMGuestDisk is required for the SQL volume-label workflow.'
    }
    $forcePrompt = $false
    while ($true) {
        $credential = Get-WindowsGuestCredential -ForcePrompt:$forcePrompt
        if ($null -eq $credential) { throw 'Guest volume inventory was cancelled. No disk was expanded.' }
        try {
            Write-EnhancedUiStatus -Type Action -Message 'Retrieving Windows guest volume labels...'
            $volumes = @(Get-WindowsGuestVolumeLabels -VM $VM -Credential $credential)
            $script:ResolvedGuestCredential = $credential
            $labels = @{}
            foreach ($volume in $volumes) {
                $path = ConvertTo-NormalizedWindowsVolumePath -Path ([string]$volume.Path)
                if ($path) { $labels[$path] = [string]$volume.Label }
            }
            return $labels
        }
        catch {
            if (($_.Exception.ToString() + ' ' + $_.FullyQualifiedErrorId) -notmatch '(?i)Failed to authenticate with the guest operating system using the supplied credentials|InvalidGuestLogin') { throw }
            Write-Warning 'Windows guest authentication failed. Enter the administrator username and password again, or enter exit to cancel.'
            $forcePrompt = $true
        }
    }
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

function Test-VMSnapshotPrerequisite {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object]$Server
    )

    $snapshots = @(Get-Snapshot -VM $VM -Server $Server -ErrorAction Stop)
    if ($snapshots.Count -gt 0) {
        Write-Host ''
        $snapshotWarning = "VM '$($VM.Name)' has $($snapshots.Count) existing snapshot(s)."
        $snapshotWarning += [Environment]::NewLine
        $snapshotWarning += 'Remove all snapshots and wait for removal to complete before adding disk space in vSphere. Then run this script again.'
        Write-Warning $snapshotWarning
        Write-Host 'Disk expansion stopped. No disk capacity or Windows partition changes were made.' -ForegroundColor Yellow
        return $false
    }

    return $true
}

function Select-HardDisk {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter()]
        [switch]$IncludeGuestVolumes,

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
            $row['GuestVolumeFreeGB'] = Get-HardDiskGuestFreeSpace -HardDisk $disks[$index] -VM $VM
        }
        $row += [ordered]@{
            DatastoreFreeGB            = if ($null -ne $datastoreSpace) { [decimal]$datastoreSpace.FreeSpaceGB } else { 'Unavailable' }
            DatastoreProvDB            = if ($null -ne $datastoreSpace) { [decimal]$datastoreSpace.ProvisionedSpaceGB } else { 'Unavailable' }
            DatastoreFile              = $disks[$index].Filename
        }
        [pscustomobject]$row
    }
    # Keep the table's leading gap, but own its trailing spacing explicitly.
    $tableColumns = foreach ($column in $diskList[0].PSObject.Properties.Name) {
        if ($column -eq 'GuestVolumeFreeGB') {
            @{ Name = 'GuestVolumeFreeGB'; Expression = { $_.GuestVolumeFreeGB }; Alignment = 'Right' }
        }
        else {
            $column
        }
    }
    Write-Host (($diskList | Format-Table -Property $tableColumns -AutoSize | Out-String).TrimEnd())
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
        [decimal]$InitialAdditionalGB,

        [Parameter()]
        [switch]$AllowSkip
    )

    if ($PSBoundParameters.ContainsKey('InitialAdditionalGB')) {
        return $InitialAdditionalGB
    }

    Write-Host ''
    while ($true) {
        $inputArguments = @{
            Prompt = 'Enter the capacity to add, in GB'
        }
        if ($AllowSkip) {
            $inputArguments.PromptOptions = "enter 'skip' to skip this step, or 'exit' to cancel"
        }
        $inputValue = Read-ExitAwareInput @inputArguments
        Stop-IfExitRequested

        if ($AllowSkip -and $inputValue -ieq 'skip') {
            return $null
        }

        [decimal]$additionalGB = 0
        if (-not [decimal]::TryParse(
                $inputValue,
                [System.Globalization.NumberStyles]::Number,
                [System.Globalization.CultureInfo]::CurrentCulture,
                [ref]$additionalGB
            ) -or $additionalGB -le 0) {
            $message = 'Enter a positive number of GB, for example 50 or 25.5.'
            if ($AllowSkip) {
                $message += " Enter 'skip' to proceed without changing the VMDK."
            }
            Write-Warning $message
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
        $answer = Read-ExitAwareInput -Prompt "$Prompt [Y/N]"
        Stop-IfExitRequested

        switch -Regex ($answer) {
            '^(?i:y|yes)$' { return $true }
            '^(?i:n|no)$'  { return $false }
            default {
                Write-Warning "Enter Y, N, or 'exit'."
                Write-Host ''
            }
        }
    }
}

function Get-WindowsGuestCredential {
    param([switch]$ForcePrompt)

    if (-not $ForcePrompt -and $null -ne $script:ResolvedGuestCredential) {
        return $script:ResolvedGuestCredential
    }

    if (-not $ForcePrompt -and $null -ne $GuestCredential) {
        return $GuestCredential
    }

    Write-Host ''
    $userName = Read-ExitAwareInput -Prompt 'Enter the Windows guest administrator user name'
    Stop-IfExitRequested

    try {
        $credential = Get-Credential -UserName $userName -Message "Enter the password for Windows guest account '$userName'. Select Cancel to stop the guest partition workflow."
        if ($null -eq $credential) {
            Write-Host ''
            Write-Warning 'Guest partition extension was cancelled. No guest partition was changed.'
        }
        return $credential
    }
    catch {
        Write-Host ''
        Write-Warning 'Guest partition extension was cancelled. No guest partition was changed.'
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
$onlineDisks = @(Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' })
$allPartitions = @(Get-Partition -ErrorAction SilentlyContinue)
$partitions = foreach ($disk in $onlineDisks) {
    $diskPartitions = @($allPartitions | Where-Object { $_.DiskNumber -eq $disk.Number })
    if ($diskPartitions.Count -eq 0) {
        [pscustomobject]@{
            DiskNumber      = $disk.Number
            DiskSizeGB      = [math]::Round($disk.Size / 1GB, 2)
            PartitionNumber = $null
            DriveLetter     = ''
            Label           = ''
            SizeGB          = $null
            AvailableSpaceGB = $null
            Type            = 'No partitions'
            IsRecovery      = $false
        }
        continue
    }

    foreach ($partition in $diskPartitions) {
        $volume = Get-Volume -Partition $partition -ErrorAction SilentlyContinue
        [pscustomobject]@{
            DiskNumber      = $disk.Number
            DiskSizeGB      = [math]::Round($disk.Size / 1GB, 2)
            PartitionNumber = $partition.PartitionNumber
            DriveLetter     = if ($null -ne $volume -and $null -ne $volume.DriveLetter) { $volume.DriveLetter } else { '' }
            Label           = if ($null -ne $volume) { $volume.FileSystemLabel } else { '' }
            SizeGB          = [math]::Round($partition.Size / 1GB, 2)
            AvailableSpaceGB = if ($null -ne $volume -and $null -ne $volume.SizeRemaining) { [math]::Round($volume.SizeRemaining / 1GB, 2) } else { $null }
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
        [object[]]$Partitions,

        [switch]$NoLeadingBlankLine,

        [switch]$WindowsWorkstationWorkflow
    )

    $heading = if ($NoLeadingBlankLine) {
        'Windows guest disks and partitions:'
    }
    else {
        "`nWindows guest disks and partitions:"
    }
    Write-Host $heading -ForegroundColor Cyan
    $partitionTable = $Partitions |
        Sort-Object DiskNumber, PartitionNumber |
        Select-Object DiskNumber,
            PartitionNumber,
            DriveLetter,
            Label,
            @{ Name = 'PartitionSizeGB'; Expression = { $_.SizeGB } },
            @{ Name = 'AvailableDiskSpaceGB'; Expression = { $_.AvailableSpaceGB } },
            DiskSizeGB,
            Type,
            IsRecovery |
        Format-Table -AutoSize |
        Out-String
    Write-Host ($partitionTable.TrimEnd())
    Write-Host ''

    while ($true) {
        $diskPrompt = if ($WindowsWorkstationWorkflow) {
            'Select Windows disk number'
        }
        else {
            'Select the Windows disk corresponding to the expanded virtual disk by entering its disk number'
        }
        $diskInput = Read-ExitAwareInput -Prompt $diskPrompt
        Stop-IfExitRequested

        [int]$guestDiskNumber = 0
        if (-not [int]::TryParse($diskInput, [ref]$guestDiskNumber) -or -not ($Partitions.DiskNumber -contains $guestDiskNumber)) {
            Write-Warning 'Enter a disk number shown in the list.'
            Write-Host ''
            continue
        }

        $availablePartitions = @($Partitions | Where-Object {
                $_.DiskNumber -eq $guestDiskNumber -and $null -ne $_.PartitionNumber
            })
        if ($availablePartitions.Count -eq 0) {
            Write-Warning "Windows disk $guestDiskNumber has no partitions available for extension. Select another Windows disk."
            Write-Host ''
            continue
        }

        Write-Host ''
        $partitionInputArguments = @{
            Prompt = "Select the partition to extend on Windows disk $guestDiskNumber by entering its partition number"
        }
        if ($WindowsWorkstationWorkflow) {
            $partitionInputArguments.PromptOptions = "enter 'back' to select another Windows disk, or 'exit' to cancel"
        }
        $partitionInput = Read-ExitAwareInput @partitionInputArguments
        Stop-IfExitRequested

        if ($WindowsWorkstationWorkflow -and $partitionInput -ieq 'back') {
            Write-Host ''
            continue
        }

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
    Write-Warning 'Deleting it is permanent and disables Windows Recovery Environment (WinRE).'
    Write-Warning 'The script will not recreate the Recovery partition or re-enable WinRE.'
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
            Write-Host ''
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
            Write-Host ''
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
        [object]$VM,

        [switch]$SkipPartitionSelectionConfirmation,

        [switch]$WindowsWorkstationWorkflow
    )

    if ($VM.PowerState -ne 'PoweredOn') {
        Write-Warning "VM '$($VM.Name)' is not powered on. No guest partition was changed."
        return
    }

    $forceCredentialPrompt = $false
    while ($true) {
        $credential = Get-WindowsGuestCredential -ForcePrompt:$forceCredentialPrompt
        if ($null -eq $credential) {
            return
        }

        try {
            Write-EnhancedUiStatus -Type Info -Message 'Fetching Windows guest disks and partition information.'
            $partitions = Get-WindowsGuestPartitions -VM $VM -Credential $credential
            break
        }
        catch {
            # Retry only failed guest authentication during initial inventory.
            # Do not replay partition changes or hide other guest/Tools failures.
            $authenticationError = $_.Exception.ToString() + ' ' + $_.FullyQualifiedErrorId
            if ($authenticationError -notmatch '(?i)Failed to authenticate with the guest operating system using the supplied credentials|InvalidGuestLogin') {
                throw
            }
            Write-Host ''
            Write-Warning 'Windows guest authentication failed. Enter the administrator username and password again, or enter exit to cancel.'
            $credential = $null
            $forceCredentialPrompt = $true
        }
    }
    if (-not $SkipPartitionSelectionConfirmation) {
        Write-Host ''
        if (-not (Read-YesNo -Prompt 'Proceed to select a Windows partition for extension?')) {
            Write-Host ''
            Write-Host 'No guest partition was changed.' -ForegroundColor Yellow
            return
        }
    }

    $partition = Select-WindowsGuestPartition -Partitions $partitions -NoLeadingBlankLine:$SkipPartitionSelectionConfirmation -WindowsWorkstationWorkflow:$WindowsWorkstationWorkflow
    Write-Host ''
    $extensionState = Get-WindowsPartitionExtensionState -VM $VM -Credential $credential -Partition $partition
    $following = $extensionState.FollowingPartition

    if ($null -ne $following) {
        if (-not (Confirm-WindowsBlockingPartitionDeletion -BlockingPartition $following)) {
            return
        }

        $removalResult = Remove-WindowsBlockingPartition -VM $VM -Credential $credential -Partition $partition -BlockingPartition $following
        $script:GuestPartitionDeleted = $true
        if ([bool]$following.IsRecovery) {
            Write-Warning "Deleted Recovery partition $($removalResult.RecoveryPartitionNumber)."
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
    Write-EnhancedUiPhase -Progress $(if ($GuestOnly) { '1/2' } else { '1/4' }) -Title 'Connect to vCenter and select the VM' -NoTrailingBlankLine
    $server = Get-VCenterConnection
    Write-VCenterConnectionDetails -Server $server

    $selectionArguments = @{ Server = $server }
    if ($vmNameWasSupplied) {
        $selectionArguments.InitialVMName = $VMName
    }
    $vmSelection = Select-VMWithGuestWorkflow @selectionArguments
    $vm = $vmSelection.VM
    $guestOSName = $vmSelection.GuestOSName
    $workflow = $vmSelection.Workflow

    if (-not $GuestOnly -and -not (Test-VMSnapshotPrerequisite -VM $vm -Server $server)) {
        return
    }

    Write-AlignedDetails -Details ([ordered]@{
            'Guest OS' = $guestOSName
            'Workflow' = $(if ($workflow -eq 'SQL') { 'Windows Server (SQL workflow)' } else { 'Windows Workstation' })
        })

    if ($GuestOnly) {
        Write-EnhancedUiPhase -Progress '2/2' -Title 'Inspect and extend the Windows guest partition'
        Write-Warning "Guest-only mode: no vSphere virtual disk capacity will be changed on '$($vm.Name)'."
        Invoke-WindowsGuestPartitionExtension -VM $vm -SkipPartitionSelectionConfirmation:($workflow -eq 'Windows') -WindowsWorkstationWorkflow:($workflow -eq 'Windows')
        Write-EnhancedUiSummary -SelectedVM $vm.Name -Progress '2/2'
        return
    }

    Write-EnhancedUiPhase -Progress '2/4' -Title 'Select a virtual disk and specify how much space to add in vSphere' -NoTrailingBlankLine
    $diskArguments = @{ VM = $vm; Server = $server }
    if ($workflow -eq 'SQL') {
        $diskArguments.VolumeLabelsByPath = Get-CombinedGuestVolumeLabelMap -VM $vm
        $diskArguments.IncludeGuestVolumes = $true
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
    if ($workflow -eq 'Windows') {
        $capacityArguments.AllowSkip = $true
    }
    $additionalGB = Read-AdditionalCapacityGB @capacityArguments

    if ($null -eq $additionalGB) {
        Write-Host ''
        Write-EnhancedUiStatus -Type Info -Message "vSphere capacity expansion was skipped for '$($disk.Name)'."
        Write-EnhancedUiPhase -Progress '3/4' -Title 'Windows guest partition extension' -NoTrailingBlankLine
        Invoke-WindowsGuestPartitionExtension -VM $vm -SkipPartitionSelectionConfirmation -WindowsWorkstationWorkflow
        Write-EnhancedUiSummary -SelectedVM $vm.Name -Progress '4/4' -SelectedDisk $disk.Name -VmdkSkipped
        return
    }

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

    if (-not (Read-YesNo -Prompt "Expand '$($disk.Name)' on '$($vm.Name)' to $newCapacityGB GB?")) {
        Write-Host ''
        Write-Host 'Disk expansion was cancelled. No changes were made.' -ForegroundColor Yellow
        return
    }
    # A snapshot may have been created while the operator answered prompts.
    if (-not (Test-VMSnapshotPrerequisite -VM $vm -Server $server)) {
        return
    }

    Write-Host ''
    Write-EnhancedUiStatus -Type Action -Message "Expanding $($disk.Name) to $newCapacityGB GB in vSphere..."
    Set-HardDisk -HardDisk $disk -CapacityGB $newCapacityGB -Confirm:$false -ErrorAction Stop | Out-Null
    $script:VmdkExpanded = $true

    Write-Host "`nSuccessfully expanded '$($disk.Name)' on '$($vm.Name)' by $additionalGB GB." -ForegroundColor Green
    Write-EnhancedUiStatus -Type Success -Message 'The vSphere virtual disk expansion completed.'

    Write-EnhancedUiPhase -Progress '3/4' -Title 'Optional Windows guest partition extension'
    if (Read-YesNo -Prompt 'Would you like to review and extend a Windows guest partition?') {
        Invoke-WindowsGuestPartitionExtension -VM $vm -SkipPartitionSelectionConfirmation:($workflow -eq 'Windows') -WindowsWorkstationWorkflow:($workflow -eq 'Windows')
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
