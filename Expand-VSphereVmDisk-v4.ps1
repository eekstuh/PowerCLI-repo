#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core

<#
.SYNOPSIS
Expands one or more existing virtual disks on a vSphere VM with an enhanced Version 4 console interface.

.DESCRIPTION
Before each guest command, verifies power state, VMware Tools status, and
execution of a harmless PowerShell command using the supplied credentials.
Failed readiness checks stop the requested guest command without replaying it.
After a VMDK resize, re-reads the selected disk and verifies its requested
capacity before reporting success or proceeding with Windows partition work.

Expands one or more virtual disks on a VM in vSphere and optionally extends Windows
partitions through VMware Tools.

After the script retrieves virtual disk inventory and guest volume/partition information,
it asks whether you want to expand multiple disks in one session. Choosing no continues
the original single-disk workflow. Choosing yes lets you select several disks, specify
additional capacity for each, expand all selected VMDKs, and then optionally extend the
corresponding Windows partitions before the script exits.

Workflow selection:
Uses the guest OS reported by VMware Tools:
  - Windows Server: retrieves guest volume labels before disk selection.
  - Windows Workstation: requests guest credentials at partition extension.
If Tools is unavailable or the OS is unsupported, returns to VM selection.

VM and disk selection:
Accepts a VM name, disk number, and additional capacity in GB as parameters
or prompts. Wildcards are rejected. For names beginning with 11VMDEV, 11VMGC,
or 11VMHIV, can find an assigned-name suffix and asks you to confirm the match.
Disk and Windows partition selection remain manual.

The Server disk table includes GuestVolFreeGB from the latest Tools report.
Multiple volumes are shown by path. Missing labels, mappings, or free-space
data display as unavailable. Free space excludes unpartitioned VMDK space.
A failed guest inventory stops the Server workflow before disk expansion.

Snapshots:
Checks for snapshots before disk selection and immediately before expansion.
Snapshots must be removed before adding VMDK capacity. The script does not
remove them. GuestOnly mode bypasses the vSphere expansion step and its check.

Windows partition extension:
Requires administrator credentials and your confirmation. A blocking adjacent
partition can be deleted only with explicit authorization. Recovery partition
deletion disables WinRE; the script does not recreate it or re-enable WinRE.
Online disks without partitions appear as 'No partitions' and cannot be
selected for partition extension.

Navigation:
  - Enter 'skip' at the Workstation capacity prompt for guest-only extension.
  - Enter 'back' at the partition prompt to choose another Windows disk.
  - Enter 'exit' at a text prompt to cancel the remaining workflow.

Completed changes are not undone when you cancel. Authentication failures
during initial guest inventory prompt for replacement credentials.

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

.PARAMETER ShowTimings
Displays measured execution stages, excluding credential entry and selection
prompts. Includes Windows volume-query time inside the guest and the remaining
guest-command overhead. Timings do not change readiness or confirmation checks.

.EXAMPLE
.\Expand-VSphereVmDisk-v4.ps1 -VIServer vcsa01.contoso.com
# After the disk inventory is displayed the script asks whether to expand multiple disks.

.EXAMPLE
.\Expand-VSphereVmDisk-v4.ps1 -VIServer vcsa01.contoso.com -VMName APP01 -DiskNumber 2 -GBSizeToIncrease 100

.EXAMPLE
.\Expand-VSphereVmDisk-v4.ps1 -VMName APP01 -GuestOnly

.EXAMPLE
.\Expand-VSphereVmDisk-v4.ps1 -VMName SQL01 -ShowTimings
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
    [switch]$GuestOnly,

    [switch]$ShowTimings
)

$EnhancedUI = $true
$ErrorActionPreference = 'Stop'
$script:ResolvedGuestCredential = $null
$script:ExitRequested = $false
$script:VmdkExpanded = $false
$script:MultiDiskMode = $false
$script:MultiDiskModeAsked = $false
$script:ExecutionTimings = $null
$script:VolumeQuerySeconds = $null
$script:VolumeCommandSeconds = $null
$script:GuestPartitionDeleted = $false
$script:GuestPartitionExtended = $false
$vmNameWasSupplied = $PSBoundParameters.ContainsKey('VMName')
$diskNumberWasSupplied = $PSBoundParameters.ContainsKey('DiskNumber')
$sizeWasSupplied = $PSBoundParameters.ContainsKey('GBSizeToIncrease')

function Measure-ExecutionStage {
    param([string]$Name, [scriptblock]$Action)
    if (-not $ShowTimings) { & $Action; return }
    if ($null -eq $script:ExecutionTimings) {
        $script:ExecutionTimings = [collections.generic.list[object]]::new()
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'Failed'
    try {
        & $Action
        $status = 'Completed'
    }
    finally {
        $watch.Stop()
        $script:ExecutionTimings.Add([pscustomobject]@{
            Name=$Name; Seconds=$watch.Elapsed.TotalSeconds; Status=$status
        })
    }
}

function Write-ExecutionTimings {
    if (-not $ShowTimings -or $null -eq $script:ExecutionTimings -or $script:ExecutionTimings.Count -eq 0) { return }
    Write-Host "`nExecution timings (prompt time excluded):" -ForegroundColor Cyan
    $width = '  Windows volume queries (within guest command)'.Length
    foreach ($entry in $script:ExecutionTimings) { $width = [math]::Max($width, $entry.Name.Length) }
    foreach ($entry in $script:ExecutionTimings) {
        $suffix = if ($entry.Status -eq 'Failed') { ' (failed)' } else { '' }
        Write-Host ('  {0} : {1,8:N3} seconds{2}' -f $entry.Name.PadRight($width), $entry.Seconds, $suffix)
    }
    $total = ($script:ExecutionTimings | Measure-Object Seconds -Sum).Sum
    Write-Host ('  {0} : {1,8:N3} seconds' -f 'Total measured stages'.PadRight($width), $total)
    if ($null -ne $script:VolumeQuerySeconds) {
        Write-Host ('  {0} : {1,8:N3} seconds' -f '  Windows volume queries (within guest command)'.PadRight($width), $script:VolumeQuerySeconds)
        if ($null -ne $script:VolumeCommandSeconds -and $script:VolumeCommandSeconds -ge $script:VolumeQuerySeconds) {
            Write-Host ('  {0} : {1,8:N3} seconds' -f '  Remaining guest-command overhead'.PadRight($width), ($script:VolumeCommandSeconds - $script:VolumeQuerySeconds))
        }
        Write-Host '  Guest sub-timings are included above, not added to the total.' -ForegroundColor Gray
    }
    $script:ExecutionTimings.Clear()
    $script:VolumeQuerySeconds = $null
    $script:VolumeCommandSeconds = $null
    Write-Host ''
}

function Write-EnhancedUiBanner {
    if (-not $EnhancedUI) {
        return
    }

    $line = '=' * 72
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host '  vSphere Windows VM Disk Expansion Assistant - Version 4.0' -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
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

        $exact = @($allVMs | Where-Object { $_.Name -ieq $candidateName })
        if ($exact.Count -eq 1) {
            return $exact[0]
        }
        if ($exact.Count -gt 1) {
            throw "Multiple VMs named '$candidateName' were found."
        }

        $prefixMatch = $false
        foreach ($prefix in @('11VMDEV', '11VMGC', '11VMHIV')) {
            if ($candidateName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $prefixMatch = $true
                break
            }
        }
        if ($prefixMatch) {
            $assigned = @($allVMs | Where-Object { $_.Name -like "$candidateName - *" })
            if ($assigned.Count -eq 1) {
                Write-Host "Exact match not found. Found assigned VM: $($assigned[0].Name)" -ForegroundColor Yellow
                if (Read-YesNo -Prompt "Use '$($assigned[0].Name)'?") {
                    return $assigned[0]
                }
                Write-Host 'Returning to VM name entry.' -ForegroundColor Yellow
                Write-Host ''
                $candidateName = ''
                continue
            }
        }

        Write-Warning "VM '$candidateName' was not found."
        if ($initialNameWasSupplied) {
            throw "VM '$candidateName' was not found."
        }
        Write-Host ''
        $candidateName = ''
    }
}

function ConvertTo-NormalizedWindowsVolumePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $normalized = $Path.Trim().TrimEnd('\').ToUpperInvariant()
    if ($normalized -notmatch '^[A-Z]:$') { return $null }
    return $normalized
}

function Get-WindowsGuestVolumeLabels {
    param(
        [Parameter(Mandatory)][object]$VM,
        [Parameter(Mandatory)][pscredential]$Credential
    )
    $scriptText = @'
$volumes = Get-Volume | Where-Object { $null -ne $_.DriveLetter }
$results = foreach ($v in $volumes) {
    [pscustomobject]@{
        DriveLetter = [string]$v.DriveLetter
        Label = [string]$v.FileSystemLabel
        SizeRemainingGB = if ($null -ne $v.SizeRemaining) { [math]::Round($v.SizeRemaining / 1GB, 2) } else { $null }
    }
}
@($results) | ConvertTo-Json -Compress
'@
    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
    $parsed = $json | ConvertFrom-Json -ErrorAction Stop
    $map = @{}
    foreach ($item in @($parsed)) {
        $key = ConvertTo-NormalizedWindowsVolumePath -Path ("$($item.DriveLetter):")
        if ($null -ne $key) {
            $map[$key] = [pscustomobject]@{
                Label = $item.Label
                SizeRemainingGB = $item.SizeRemainingGB
            }
        }
    }
    return $map
}

function Get-GuestVolumeDisplayForHardDisk {
    param(
        [Parameter(Mandatory)][object]$HardDisk,
        [Parameter()][System.Collections.IDictionary]$VolumeLabelsByPath
    )
    try {
        $guestDisk = $HardDisk.ExtensionData.Guest
        if ($null -eq $guestDisk -or $null -eq $guestDisk.Disk) { return 'Unavailable' }
        $labels = @()
        foreach ($gd in @($guestDisk.Disk)) {
            if ($null -eq $gd.Mapping) { continue }
            foreach ($map in @($gd.Mapping)) {
                $path = ConvertTo-NormalizedWindowsVolumePath -Path $map.DevicePath
                if ($null -eq $path) { continue }
                $label = if ($null -ne $VolumeLabelsByPath -and $VolumeLabelsByPath.ContainsKey($path)) {
                    $VolumeLabelsByPath[$path].Label
                } else { '' }
                if ([string]::IsNullOrWhiteSpace($label)) { $label = $path }
                $labels += $label
            }
        }
        if ($labels.Count -eq 0) { return 'Unavailable' }
        return ($labels -join ', ')
    }
    catch { return 'Unavailable' }
}

function Get-HardDiskGuestFreeSpace {
    param(
        [Parameter(Mandatory)][object]$HardDisk,
        [Parameter(Mandatory)][object]$VM
    )
    try {
        $guestDisk = $HardDisk.ExtensionData.Guest
        if ($null -eq $guestDisk -or $null -eq $guestDisk.Disk) { return 'Unavailable' }
        $free = 0
        $found = $false
        foreach ($gd in @($guestDisk.Disk)) {
            if ($null -eq $gd.FreeSpace) { continue }
            $free += [decimal]($gd.FreeSpace / 1GB)
            $found = $true
        }
        if (-not $found) { return 'Unavailable' }
        return [math]::Round($free, 2)
    }
    catch { return 'Unavailable' }
}

function Get-DiskExpansionWorkflow {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$GuestOSName)
    if ([string]::IsNullOrWhiteSpace($GuestOSName)) { return 'Windows' }
    if ($GuestOSName -match '(?i)windows.*server|microsoft windows server') { return 'SQL' }
    return 'Windows'
}

function Select-VMWithGuestWorkflow {
    param([Parameter(Mandatory)][object]$Server, [Parameter()][string]$InitialVMName)
    while ($true) {
        $vmArguments = @{ Server = $Server }
        if (-not [string]::IsNullOrWhiteSpace($InitialVMName)) { $vmArguments.InitialVMName = $InitialVMName }
        $selectedVM = Select-ExactVM @vmArguments
        $guestOS = [string]$selectedVM.Guest.OSFullName
        if ([string]::IsNullOrWhiteSpace($guestOS)) {
            $guestOS = [string]$selectedVM.Guest.ConfiguredGuestId
        }
        $workflow = Get-DiskExpansionWorkflow -GuestOSName $guestOS
        if ($workflow -eq 'Unsupported') {
            Write-Warning "Guest OS '$guestOS' is not supported for automated partition extension. Select another VM."
            $InitialVMName = $null
            continue
        }
        return [pscustomobject]@{ VM = $selectedVM; GuestOSName = $guestOS; Workflow = $workflow }
    }
}

function Get-CombinedGuestVolumeLabelMap {
    param([Parameter(Mandatory)][object]$VM)
    $credential = Get-WindowsGuestCredential
    try {
        return Get-WindowsGuestVolumeLabels -VM $VM -Credential $credential
    }
    catch {
        Write-Warning "Could not retrieve guest volume labels: $($_.Exception.Message)"
        return @{}
    }
}

function Get-HardDiskDatastoreSpace {
    param([Parameter(Mandatory)][object]$HardDisk, [Parameter(Mandatory)][object]$Server)
    $datastore = Get-Datastore -Id $HardDisk.ExtensionData.Datastore -Server $Server -ErrorAction Stop
    return [pscustomobject]@{
        FreeSpaceGB = [math]::Round($datastore.FreeSpaceGB, 2)
        ProvisionedSpaceGB = [math]::Round($datastore.CapacityGB, 2)
    }
}

function Test-VMSnapshotPrerequisite {
    param([Parameter(Mandatory)][object]$VM, [Parameter(Mandatory)][object]$Server)
    $snapshots = @(Get-Snapshot -VM $VM -Server $Server -ErrorAction SilentlyContinue)
    if ($snapshots.Count -gt 0) {
        Write-Warning "VM '$($VM.Name)' has $($snapshots.Count) snapshot(s). Remove all snapshots before expanding a virtual disk."
        return $false
    }
    return $true
}

function Select-HardDisk {
    param(
        [Parameter(Mandatory)][object]$VM,
        [Parameter(Mandatory)][object]$Server,
        [Parameter()][switch]$IncludeGuestVolumes,
        [Parameter()][System.Collections.IDictionary]$VolumeLabelsByPath,
        [Parameter()][int]$InitialDiskNumber
    )

    $disks = @(Measure-ExecutionStage -Name 'Retrieve virtual disk inventory' -Action {
        Get-HardDisk -VM $VM -Server $Server -ErrorAction Stop |
            Sort-Object `
                @{ Expression = {
                    $diskNumberMatch = [regex]::Match([string]$_.Name, '\d+(?=\D*$)')
                    if ($diskNumberMatch.Success) { [int]$diskNumberMatch.Value } else { [int]::MaxValue }
                } },
                Name
    })
    if ($disks.Count -eq 0) { throw "VM '$($VM.Name)' has no virtual hard disks." }

    Write-Host "`nVirtual disks on '$($VM.Name)':" -ForegroundColor Cyan
    $diskList = for ($index = 0; $index -lt $disks.Count; $index++) {
        $datastoreSpace = try {
            Measure-ExecutionStage -Name "Datastore query ($($disks[$index].Name))" -Action {
                Get-HardDiskDatastoreSpace -HardDisk $disks[$index] -Server $Server
            }
        } catch {
            Write-Warning "Could not retrieve datastore space information for '$($disks[$index].Name)': $($_.Exception.Message)"
            $null
        }
        $row = [ordered]@{ Number = $index + 1; Disk = $disks[$index].Name }
        if ($IncludeGuestVolumes) {
            $display = Measure-ExecutionStage -Name "Map volumes ($($disks[$index].Name))" -Action {
                Get-GuestVolumeDisplayForHardDisk -HardDisk $disks[$index] -VolumeLabelsByPath $VolumeLabelsByPath
            }
            $row['GuestVolumes'] = $display
        }
        $row['HDCapacityGB'] = [decimal]$disks[$index].CapacityGB
        if ($IncludeGuestVolumes) {
            $row['GuestVolFreeGB'] = Measure-ExecutionStage -Name "Read guest free space ($($disks[$index].Name))" -Action {
                Get-HardDiskGuestFreeSpace -HardDisk $disks[$index] -VM $VM
            }
        }
        $row += [ordered]@{
            DatastoreFreeGB = if ($null -ne $datastoreSpace) { [decimal]$datastoreSpace.FreeSpaceGB } else { 'Unavailable' }
            DatastoreProvGB = if ($null -ne $datastoreSpace) { [decimal]$datastoreSpace.ProvisionedSpaceGB } else { 'Unavailable' }
            DatastoreFile = $disks[$index].Filename
        }
        [pscustomobject]$row
    }
    $tableColumns = foreach ($column in $diskList[0].PSObject.Properties.Name) {
        if ($column -eq 'GuestVolFreeGB') {
            @{ Name = 'GuestVolFreeGB'; Expression = { $_.GuestVolFreeGB }; Alignment = 'Right' }
        } else { $column }
    }
    Write-Host (($diskList | Format-Table -Property $tableColumns -AutoSize | Out-String).TrimEnd())
    Write-Host ''
    Write-ExecutionTimings

    # Version 4: after disk and guest volume inventory, offer multi-disk expansion.
    if (-not $PSBoundParameters.ContainsKey('InitialDiskNumber') -and $disks.Count -gt 1 -and -not $script:MultiDiskModeAsked) {
        $script:MultiDiskModeAsked = $true
        if (Read-YesNo -Prompt 'Would you like to expand multiple disks at once?') {
            $script:MultiDiskMode = $true
            return $null
        }
    }

    if ($PSBoundParameters.ContainsKey('InitialDiskNumber')) {
        if ($InitialDiskNumber -gt $disks.Count) {
            throw "Disk number $InitialDiskNumber is invalid. VM '$($VM.Name)' has $($disks.Count) virtual disk(s)."
        }
        return $disks[$InitialDiskNumber - 1]
    }

    while ($true) {
        $choice = Read-ExitAwareInput -Prompt 'Select virtual disk number'
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
    param([Parameter()][decimal]$InitialAdditionalGB, [Parameter()][switch]$AllowSkip)
    if ($PSBoundParameters.ContainsKey('InitialAdditionalGB')) { return $InitialAdditionalGB }
    Write-Host ''
    while ($true) {
        $inputArguments = @{ Prompt = 'Enter the capacity to add, in GB' }
        if ($AllowSkip) { $inputArguments.PromptOptions = "enter 'skip' to skip this step, or 'exit' to cancel" }
        $inputValue = Read-ExitAwareInput @inputArguments
        Stop-IfExitRequested
        if ($AllowSkip -and $inputValue -ieq 'skip') { return $null }
        [decimal]$additionalGB = 0
        if (-not [decimal]::TryParse($inputValue, [System.Globalization.NumberStyles]::Number, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$additionalGB) -or $additionalGB -le 0) {
            $message = 'Enter a positive number of GB, for example 50 or 25.5.'
            if ($AllowSkip) { $message += " Enter 'skip' to proceed without changing the VMDK." }
            Write-Warning $message
            Write-Host ''
            continue
        }
        return $additionalGB
    }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $answer = Read-ExitAwareInput -Prompt "$Prompt [Y/N]"
        Stop-IfExitRequested
        switch -Regex ($answer) {
            '^(?i:y|yes)$' { return $true }
            '^(?i:n|no)$'  { return $false }
            default { Write-Warning "Enter Y, N, or 'exit'."; Write-Host '' }
        }
    }
}

function Get-WindowsGuestCredential {
    param([switch]$ForcePrompt)
    if (-not $ForcePrompt -and $null -ne $script:ResolvedGuestCredential) { return $script:ResolvedGuestCredential }
    if (-not $ForcePrompt -and $null -ne $GuestCredential) {
        $script:ResolvedGuestCredential = $GuestCredential
        return $GuestCredential
    }
    $cred = Get-Credential -Message 'Enter Windows guest administrator credentials.'
    if ($null -eq $cred) { throw 'Windows guest credentials are required.' }
    $script:ResolvedGuestCredential = $cred
    return $cred
}

function Get-VerifiedExpandedHardDisk {
    param(
        [Parameter(Mandatory)][object]$VM,
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$HardDisk,
        [Parameter(Mandatory)][decimal]$ExpectedCapacityGB
    )
    $matches = @(Get-HardDisk -VM $VM -Server $Server -ErrorAction Stop |
        Where-Object { $_.Id -eq $HardDisk.Id -and $_.Filename -ieq $HardDisk.Filename })
    if ($matches.Count -ne 1) {
        throw 'The resized VMDK could not be uniquely verified. Guest changes were stopped. Check the VM before retrying.'
    }
    if ([math]::Abs([decimal]$matches[0].CapacityGB - $ExpectedCapacityGB) -gt (1 / 1MB)) {
        throw "VMDK verification returned $($matches[0].CapacityGB) GB instead of $ExpectedCapacityGB GB. Guest changes were stopped. Check the VM before retrying."
    }
    return $matches[0]
}

function Assert-WindowsGuestReadiness {
    param(
        [Parameter(Mandatory)][object]$VM,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][object]$Server
    )
    $currentVM = Get-VM -Id $VM.Id -Server $Server -ErrorAction Stop
    if ($currentVM.PowerState -ne 'PoweredOn') {
        throw "VM '$($VM.Name)' must be powered on before running guest operations."
    }
    if ($currentVM.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') {
        throw "VMware Tools is not running on '$($VM.Name)'. Start VMware Tools before retrying."
    }
    $marker = 'POWERCLI_READY_' + [guid]::NewGuid().ToString('N')
    $ProgressPreference = 'SilentlyContinue'
    $probe = Invoke-VMScript -VM $currentVM -Server $Server -GuestCredential $Credential -ScriptType Powershell -ScriptText ("Write-Output '" + $marker + "'") -ErrorAction Stop
    $lines = @(([string]$probe.ScriptOutput -split '\r?\n') | ForEach-Object { $_.Trim() })
    if ($probe.ExitCode -ne 0 -or $lines -notcontains $marker) {
        throw "VMware Tools guest readiness check failed on '$($VM.Name)' (exit code $($probe.ExitCode)). The requested guest operation was not started. Restart VMware Tools, or reboot the VM if the issue persists."
    }
}

function Invoke-GuestScriptWithCredentialRetry {
    param(
        [Parameter(Mandatory)][object]$VM,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)][string]$ScriptText
    )
    if ($null -eq (Get-Variable -Name RejectedGuestCredentials -Scope Script -ErrorAction SilentlyContinue)) {
        $script:RejectedGuestCredentials = [System.Collections.ArrayList]::new()
    }
    if ($null -ne $script:RejectedGuestCredentials -and $script:RejectedGuestCredentials.Contains($Credential)) {
        $Credential = $script:ResolvedGuestCredential
    }
    while ($true) {
        $retryMessage = $null
        if ($Credential.Password.Length -eq 0) {
            $retryMessage = 'The Windows guest password cannot be empty. Enter the username and password again.'
        } else {
            try {
                Assert-WindowsGuestReadiness -VM $VM -Credential $Credential -Server $server
                return Invoke-VMScript -VM $VM -Server $server -GuestCredential $Credential -ScriptType Powershell -ScriptText $ScriptText -ErrorAction Stop
            } catch {
                if ($_.Exception.Message -notmatch '(?i)vix error codes\s*=\s*\(\s*3033\s*,\s*0\s*\)') { throw }
                $retryMessage = 'VMware Tools rejected the Windows guest credentials (VIX 3033). Enter the username and a non-empty password again.'
            }
        }
        Write-Warning $retryMessage
        if ($null -eq $script:RejectedGuestCredentials) {
            $script:RejectedGuestCredentials = [System.Collections.ArrayList]::new()
        }
        [void]$script:RejectedGuestCredentials.Add($Credential)
        $replacement = Get-Credential -UserName $Credential.UserName -Message 'Enter Windows guest administrator credentials. Select Cancel to cancel this guest operation.'
        if ($null -eq $replacement) {
            throw 'Windows guest credential entry was cancelled. The guest operation was not retried.'
        }
        $Credential = $replacement
        $script:ResolvedGuestCredential = $replacement
    }
}

function Invoke-WindowsGuestPowerShell {
    param(
        [Parameter(Mandatory)][object]$VM,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)][string]$ScriptText
    )
    $wrapper = @'
try {
    $guestResults = @(& {
__GUEST_SCRIPT_BODY__
    })
    if ($guestResults.Count -eq 0) { throw 'Guest operation returned no result payload.' }
    Write-Output '__VMWARE_GUEST_PAYLOAD_BEGIN__'
    Write-Output ([string]$guestResults[-1]).Trim()
    Write-Output '__VMWARE_GUEST_PAYLOAD_END__'
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
'@
    $wrapped = $wrapper.Replace('__GUEST_SCRIPT_BODY__', $ScriptText)
    $result = Invoke-GuestScriptWithCredentialRetry -VM $VM -Credential $Credential -ScriptText $wrapped
    $output = [string]$result.ScriptOutput
    $begin = $output.IndexOf('__VMWARE_GUEST_PAYLOAD_BEGIN__')
    $end = $output.IndexOf('__VMWARE_GUEST_PAYLOAD_END__')
    if ($begin -lt 0 -or $end -lt 0 -or $end -le $begin) {
        throw "Guest command did not return a valid payload. Exit code: $($result.ExitCode). Output: $output"
    }
    $payload = $output.Substring($begin + '__VMWARE_GUEST_PAYLOAD_BEGIN__'.Length, $end - $begin - '__VMWARE_GUEST_PAYLOAD_BEGIN__'.Length).Trim()
    return $payload
}

function Get-WindowsGuestPartitions {
    param([Parameter(Mandatory)][object]$VM, [Parameter(Mandatory)][pscredential]$Credential)
    $scriptText = @'
$recoveryGptType = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
$disks = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' }
$partitions = foreach ($disk in $disks) {
    $parts = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue)
    if ($parts.Count -eq 0) {
        [pscustomobject]@{
            DiskNumber = $disk.Number
            DiskSizeGB = [math]::Round($disk.Size / 1GB, 2)
            PartitionNumber = $null
            DriveLetter = ''
            Label = 'No partitions'
            SizeGB = $null
            AvailableSpaceGB = $null
            Type = ''
            IsRecovery = $false
        }
        continue
    }
    foreach ($partition in $parts) {
        $volume = Get-Volume -Partition $partition -ErrorAction SilentlyContinue
        [pscustomobject]@{
            DiskNumber = $disk.Number
            DiskSizeGB = [math]::Round($disk.Size / 1GB, 2)
            PartitionNumber = $partition.PartitionNumber
            DriveLetter = if ($null -ne $volume -and $null -ne $volume.DriveLetter) { $volume.DriveLetter } else { '' }
            Label = if ($null -ne $volume) { $volume.FileSystemLabel } else { '' }
            SizeGB = [math]::Round($partition.Size / 1GB, 2)
            AvailableSpaceGB = if ($null -ne $volume -and $null -ne $volume.SizeRemaining) { [math]::Round($volume.SizeRemaining / 1GB, 2) } else { $null }
            Type = $partition.Type
            IsRecovery = ($partition.Type -eq 'Recovery' -or $partition.GptType -eq $recoveryGptType)
        }
    }
}
@($partitions) | ConvertTo-Json -Depth 4 -Compress
'@
    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    if ([string]::IsNullOrWhiteSpace($json)) { throw 'The Windows guest did not return any partitions.' }
    return @($json | ConvertFrom-Json -ErrorAction Stop)
}

function Select-WindowsGuestPartition {
    param(
        [Parameter(Mandatory)][object[]]$Partitions,
        [switch]$NoLeadingBlankLine,
        [switch]$WindowsWorkstationWorkflow
    )
    $heading = if ($NoLeadingBlankLine) { 'Windows guest disks and partitions:' } else { "`nWindows guest disks and partitions:" }
    Write-Host $heading -ForegroundColor Cyan
    $partitionTable = $Partitions |
        Sort-Object DiskNumber, PartitionNumber |
        Select-Object @{ Name = 'DiskNum'; Expression = { $_.DiskNumber } },
            @{ Name = 'PartitionNum'; Expression = { $_.PartitionNumber } },
            DriveLetter, Label,
            @{ Name = 'PartitionSizeGB'; Expression = { $_.SizeGB } },
            @{ Name = 'DiskSpaceFreeGB'; Expression = { $_.AvailableSpaceGB } },
            DiskSizeGB, Type, IsRecovery |
        Format-Table -AutoSize | Out-String
    Write-Host ($partitionTable.TrimEnd())
    Write-Host ''
    while ($true) {
        $diskPrompt = if ($WindowsWorkstationWorkflow) { 'Select Windows disk number' } else { 'Select the Windows disk corresponding to the expanded virtual disk by entering its disk number' }
        $diskChoice = Read-ExitAwareInput -Prompt $diskPrompt -PromptOptions "enter 'back' to choose another disk, or 'exit' to cancel"
        Stop-IfExitRequested
        if ($diskChoice -ieq 'back') { return $null }
        [int]$diskNum = 0
        if (-not [int]::TryParse($diskChoice, [ref]$diskNum)) {
            Write-Warning 'Enter a valid disk number.'
            continue
        }
        $diskParts = @($Partitions | Where-Object { $_.DiskNumber -eq $diskNum -and $null -ne $_.PartitionNumber })
        if ($diskParts.Count -eq 0) {
            Write-Warning "Disk $diskNum has no selectable partitions."
            continue
        }
        $partChoice = Read-ExitAwareInput -Prompt 'Select partition number'
        Stop-IfExitRequested
        [int]$partNum = 0
        if (-not [int]::TryParse($partChoice, [ref]$partNum)) {
            Write-Warning 'Enter a valid partition number.'
            continue
        }
        $selected = @($diskParts | Where-Object { $_.PartitionNumber -eq $partNum })
        if ($selected.Count -ne 1) {
            Write-Warning "Partition $partNum was not found on disk $diskNum."
            continue
        }
        return $selected[0]
    }
}

function Get-WindowsPartitionExtensionState {
    param(
        [Parameter(Mandatory)][object]$VM,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][object]$Partition
    )
    $scriptText = @'
$diskNumber = __DISK_NUMBER__
$partitionNumber = __PARTITION_NUMBER__
$partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber
$supported = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partitionNumber
[pscustomobject]@{
    CanExtend = ($supported.SizeMax -gt $partition.Size)
    CurrentSizeGB = [math]::Round($partition.Size / 1GB, 2)
    MaximumSizeGB = [math]::Round($supported.SizeMax / 1GB, 2)
} | ConvertTo-Json -Compress
'@
    $scriptText = $scriptText.Replace('__DISK_NUMBER__', [string]$Partition.DiskNumber).Replace('__PARTITION_NUMBER__', [string]$Partition.PartitionNumber)
    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    return $json | ConvertFrom-Json -ErrorAction Stop
}

function Expand-WindowsGuestPartition {
    param(
        [Parameter(Mandatory)][object]$VM,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][object]$Partition
    )
    $scriptText = @'
$diskNumber = __DISK_NUMBER__
$partitionNumber = __PARTITION_NUMBER__
$supported = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partitionNumber
Resize-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -Size $supported.SizeMax -ErrorAction Stop
$partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber
[pscustomobject]@{
    NewSizeGB = [math]::Round($partition.Size / 1GB, 2)
} | ConvertTo-Json -Compress
'@
    $scriptText = $scriptText.Replace('__DISK_NUMBER__', [string]$Partition.DiskNumber).Replace('__PARTITION_NUMBER__', [string]$Partition.PartitionNumber)
    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    return $json | ConvertFrom-Json -ErrorAction Stop
}

function Confirm-WindowsRecoveryPartitionDeletion {
    param([Parameter(Mandatory)][object]$Partition, [Parameter(Mandatory)][object]$RecoveryPartition)
    Write-Host ''
    Write-Host 'A Recovery partition is blocking extension of the selected partition.' -ForegroundColor Yellow
    Write-Host "Selected partition: Disk $($Partition.DiskNumber), Partition $($Partition.PartitionNumber)"
    Write-Host "Blocking Recovery partition: Partition $($RecoveryPartition.PartitionNumber)"
    Write-Host ''
    Write-Host 'Deleting the Recovery partition will permanently disable Windows Recovery Environment (WinRE).' -ForegroundColor Red
    Write-Host 'The script will not recreate the Recovery partition or re-enable WinRE.' -ForegroundColor Red
    Write-Host ''
    return (Read-YesNo -Prompt 'Permanently delete the blocking Recovery partition and disable WinRE?')
}

function Confirm-WindowsBlockingPartitionDeletion {
    param([Parameter(Mandatory)][object]$Partition, [Parameter(Mandatory)][object]$BlockingPartition)
    Write-Host ''
    Write-Host 'A partition is blocking extension of the selected partition.' -ForegroundColor Yellow
    Write-Host "Blocking partition: Disk $($BlockingPartition.DiskNumber), Partition $($BlockingPartition.PartitionNumber), Type $($BlockingPartition.Type)"
    Write-Host ''
    return (Read-YesNo -Prompt 'Permanently delete the blocking partition?')
}

function Remove-WindowsRecoveryPartition {
    param(
        [Parameter(Mandatory)][object]$VM,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][object]$Partition,
        [Parameter(Mandatory)][object]$RecoveryPartition
    )
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
$nextPartition = @(Get-Partition -DiskNumber $diskNumber | Where-Object { $_.Offset -gt $selectedPartition.Offset } | Sort-Object Offset | Select-Object -First 1)
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
    WinREDisabled = $true
} | ConvertTo-Json -Compress
'@
    $disableScript = $disableScript.Replace('__DISK_NUMBER__', [string]$Partition.DiskNumber).Replace('__PARTITION_NUMBER__', [string]$Partition.PartitionNumber).Replace('__RECOVERY_PARTITION_NUMBER__', [string]$RecoveryPartition.PartitionNumber)
    $disableJson = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $disableScript
    $disableResult = $disableJson | ConvertFrom-Json -ErrorAction Stop
    Write-Host "WinRE is disabled. Deleting Recovery partition $($RecoveryPartition.PartitionNumber)..." -ForegroundColor Yellow
    $deleteScript = @'
$ErrorActionPreference = 'Stop'
$diskNumber = __DISK_NUMBER__
$recoveryPartitionNumber = __RECOVERY_PARTITION_NUMBER__
Remove-Partition -DiskNumber $diskNumber -PartitionNumber $recoveryPartitionNumber -Confirm:$false -ErrorAction Stop
[pscustomobject]@{ Deleted = $true } | ConvertTo-Json -Compress
'@
    $deleteScript = $deleteScript.Replace('__DISK_NUMBER__', [string]$Partition.DiskNumber).Replace('__RECOVERY_PARTITION_NUMBER__', [string]$RecoveryPartition.PartitionNumber)
    $deleteJson = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $deleteScript
    $deleteResult = $deleteJson | ConvertFrom-Json -ErrorAction Stop
    $script:GuestPartitionDeleted = $true
    Write-Host "Recovery partition $($RecoveryPartition.PartitionNumber) deleted." -ForegroundColor Green
    return $deleteResult
}

function Invoke-WindowsGuestPartitionExtension {
    param(
        [Parameter(Mandatory)][object]$VM,
        [switch]$SkipPartitionSelectionConfirmation,
        [switch]$WindowsWorkstationWorkflow
    )
    $credential = Get-WindowsGuestCredential
    $partitions = Get-WindowsGuestPartitions -VM $VM -Credential $credential
    while ($true) {
        $partition = Select-WindowsGuestPartition -Partitions $partitions -WindowsWorkstationWorkflow:$WindowsWorkstationWorkflow
        if ($null -eq $partition) { return }
        if ($null -eq $partition.PartitionNumber) {
            Write-Warning 'The selected disk has no partitions and cannot be extended.'
            continue
        }
        $extensionState = Get-WindowsPartitionExtensionState -VM $VM -Credential $credential -Partition $partition
        if (-not [bool]$extensionState.CanExtend) {
            # Check for blocking partition
            $blocking = @($partitions | Where-Object { $_.DiskNumber -eq $partition.DiskNumber -and $_.PartitionNumber -gt $partition.PartitionNumber } | Sort-Object PartitionNumber | Select-Object -First 1)
            if ($blocking.Count -eq 1) {
                $blocker = $blocking[0]
                if ([bool]$blocker.IsRecovery) {
                    if (Confirm-WindowsRecoveryPartitionDeletion -Partition $partition -RecoveryPartition $blocker) {
                        Remove-WindowsRecoveryPartition -VM $VM -Credential $credential -Partition $partition -RecoveryPartition $blocker
                        $extensionState = Get-WindowsPartitionExtensionState -VM $VM -Credential $credential -Partition $partition
                        Write-Host "Verified: after deleting the blocking partition, Windows disk $($partition.DiskNumber), partition $($partition.PartitionNumber) can now grow from $($extensionState.CurrentSizeGB) GB to $($extensionState.MaximumSizeGB) GB." -ForegroundColor Green
                    } else {
                        Write-Host 'Blocking Recovery partition was not deleted.' -ForegroundColor Yellow
                        continue
                    }
                } else {
                    if (Confirm-WindowsBlockingPartitionDeletion -Partition $partition -BlockingPartition $blocker) {
                        # Simplified deletion for non-recovery blocking partitions
                        $deleteScript = @'
$ErrorActionPreference = 'Stop'
$diskNumber = __DISK_NUMBER__
$blockingPartitionNumber = __BLOCKING_PARTITION_NUMBER__
Remove-Partition -DiskNumber $diskNumber -PartitionNumber $blockingPartitionNumber -Confirm:$false -ErrorAction Stop
[pscustomobject]@{ Deleted = $true } | ConvertTo-Json -Compress
'@
                        $deleteScript = $deleteScript.Replace('__DISK_NUMBER__', [string]$partition.DiskNumber).Replace('__BLOCKING_PARTITION_NUMBER__', [string]$blocker.PartitionNumber)
                        $deleteJson = Invoke-WindowsGuestPowerShell -VM $VM -Credential $credential -ScriptText $deleteScript
                        $script:GuestPartitionDeleted = $true
                        Write-Host "Blocking partition $($blocker.PartitionNumber) deleted." -ForegroundColor Green
                        $extensionState = Get-WindowsPartitionExtensionState -VM $VM -Credential $credential -Partition $partition
                    } else {
                        Write-Host 'Blocking partition was not deleted.' -ForegroundColor Yellow
                        continue
                    }
                }
            }
        }
        if (-not [bool]$extensionState.CanExtend) {
            Write-Warning 'There is no contiguous unallocated space after the selected partition. No guest partition was changed.'
            return
        }
        Write-Host "The selected Windows partition can grow from $($extensionState.CurrentSizeGB) GB to $($extensionState.MaximumSizeGB) GB." -ForegroundColor Cyan
        Write-Host ''
        if (-not (Read-YesNo -Prompt 'Extend the selected Windows partition now?')) {
            Write-Host 'No guest partition was changed.' -ForegroundColor Yellow
            return
        }
        $result = Expand-WindowsGuestPartition -VM $VM -Credential $credential -Partition $partition
        $script:GuestPartitionExtended = $true
        Write-Host "Successfully extended Windows disk $($partition.DiskNumber), partition $($partition.PartitionNumber) to $($result.NewSizeGB) GB." -ForegroundColor Green
        return
    }
}

function Invoke-MultipleDiskExpansion {
    param(
        [Parameter(Mandatory)][object]$VM,
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][string]$Workflow
    )
    Write-Host "`nMulti-disk expansion mode selected." -ForegroundColor Cyan
    Write-Host "Enter disk numbers separated by commas or spaces (for example: 1,3,4)." -ForegroundColor Gray
    Write-Host ''
    $disks = @(Get-HardDisk -VM $VM -Server $Server -ErrorAction Stop |
        Sort-Object @{ Expression = {
            $m = [regex]::Match([string]$_.Name, '\d+(?=\D*$)')
            if ($m.Success) { [int]$m.Value } else { [int]::MaxValue }
        } }, Name)
    $selected = @()
    while ($selected.Count -eq 0) {
        $inputValue = Read-ExitAwareInput -Prompt 'Select disk numbers to expand'
        Stop-IfExitRequested
        $numbers = @($inputValue -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
        $numbers = @($numbers | Sort-Object -Unique)
        if ($numbers.Count -eq 0) {
            Write-Warning 'Enter at least one valid disk number.'
            continue
        }
        $invalid = @($numbers | Where-Object { $_ -lt 1 -or $_ -gt $disks.Count })
        if ($invalid.Count -gt 0) {
            Write-Warning "Invalid disk number(s): $($invalid -join ', '). Valid range is 1 to $($disks.Count)."
            continue
        }
        $selected = @($numbers | ForEach-Object { $disks[$_ - 1] })
    }
    Write-Host "`nSelected disks:" -ForegroundColor Cyan
    $plans = @()
    foreach ($d in $selected) {
        Write-Host "  $($d.Name) (current: $($d.CapacityGB) GB)" -ForegroundColor White
        $add = Read-AdditionalCapacityGB
        if ($null -eq $add) { continue }
        $plans += [pscustomobject]@{
            Disk = $d
            AdditionalGB = $add
            NewCapacityGB = [decimal]$d.CapacityGB + $add
        }
    }
    if ($plans.Count -eq 0) {
        Write-Host 'No disks were selected for expansion. No changes were made.' -ForegroundColor Yellow
        return
    }
    Write-Host "`nPlanned multi-disk expansion:" -ForegroundColor Cyan
    foreach ($p in $plans) {
        Write-Host ("  {0,-20} {1,8:N2} GB -> {2,8:N2} GB (+{3} GB)" -f $p.Disk.Name, $p.Disk.CapacityGB, $p.NewCapacityGB, $p.AdditionalGB)
    }
    Write-Host ''
    if (-not (Read-YesNo -Prompt "Expand all $($plans.Count) selected disk(s) on '$($VM.Name)'?")) {
        Write-Host 'Multi-disk expansion was cancelled. No changes were made.' -ForegroundColor Yellow
        return
    }
    if (-not (Test-VMSnapshotPrerequisite -VM $VM -Server $Server)) { return }
    $expanded = @()
    foreach ($p in $plans) {
        Write-Host ''
        Write-EnhancedUiStatus -Type Action -Message "Expanding $($p.Disk.Name) to $($p.NewCapacityGB) GB..."
        Set-HardDisk -HardDisk $p.Disk -CapacityGB $p.NewCapacityGB -Server $Server -Confirm:$false -ErrorAction Stop | Out-Null
        $verified = Get-VerifiedExpandedHardDisk -VM $VM -Server $Server -HardDisk $p.Disk -ExpectedCapacityGB $p.NewCapacityGB
        $script:VmdkExpanded = $true
        $expanded += $verified
        Write-Host "Successfully expanded '$($verified.Name)' to $($verified.CapacityGB) GB." -ForegroundColor Green
    }
    Write-Host "`nAll selected VMDKs expanded successfully." -ForegroundColor Green
    Write-EnhancedUiPhase -Progress '3/4' -Title 'Optional Windows guest partition extension'
    if (Read-YesNo -Prompt 'Would you like to review and extend Windows guest partitions for the expanded disks?') {
        Invoke-WindowsGuestPartitionExtension -VM $VM -SkipPartitionSelectionConfirmation:($Workflow -eq 'Windows') -WindowsWorkstationWorkflow:($Workflow -eq 'Windows')
    } else {
        Write-Host 'Windows partitions were not extended.' -ForegroundColor Yellow
    }
    Write-EnhancedUiSummary -SelectedVM $VM.Name -Progress '4/4' -SelectedDisk ("$($expanded.Count) disks")
    Write-Host 'Multi-disk expansion complete. Script will now exit.' -ForegroundColor Cyan
}

try {
    Write-EnhancedUiBanner
    Write-EnhancedUiPhase -Progress $(if ($GuestOnly) { '1/2' } else { '1/4' }) -Title 'Connect to vCenter and select the VM' -NoTrailingBlankLine
    $server = Get-VCenterConnection
    Write-VCenterConnectionDetails -Server $server

    $selectionArguments = @{ Server = $server }
    if ($vmNameWasSupplied) { $selectionArguments.InitialVMName = $VMName }
    $vmSelection = Select-VMWithGuestWorkflow @selectionArguments
    $vm = $vmSelection.VM
    $guestOSName = $vmSelection.GuestOSName
    $workflow = $vmSelection.Workflow

    if (-not $GuestOnly -and -not (Test-VMSnapshotPrerequisite -VM $vm -Server $server)) { return }

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
    if ($diskNumberWasSupplied) { $diskArguments.InitialDiskNumber = $DiskNumber }
    $disk = Select-HardDisk @diskArguments
    if ($script:MultiDiskMode) {
        Invoke-MultipleDiskExpansion -VM $vm -Server $server -Workflow $workflow
        return
    }
    if ($null -eq $disk) { throw 'Disk selection was cancelled.' }
    if (-not $diskNumberWasSupplied) { Write-Host '' }
    Write-EnhancedUiStatus -Type Success -Message "Selected $($disk.Name) with current capacity $($disk.CapacityGB) GB."

    $capacityArguments = @{}
    if ($sizeWasSupplied) { $capacityArguments.InitialAdditionalGB = $GBSizeToIncrease }
    if ($workflow -eq 'Windows') { $capacityArguments.AllowSkip = $true }
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
            'VM' = $vm.Name
            'Disk' = $disk.Name
            'VMDK' = $disk.Filename
            'Capacity' = "$currentCapacityGB GB -> $newCapacityGB GB"
        })
    Write-Host ''

    if (-not (Read-YesNo -Prompt "Expand '$($disk.Name)' on '$($vm.Name)' to $newCapacityGB GB?")) {
        Write-Host ''
        Write-Host 'Disk expansion was cancelled. No changes were made.' -ForegroundColor Yellow
        return
    }
    if (-not (Test-VMSnapshotPrerequisite -VM $vm -Server $server)) { return }

    Write-Host ''
    Write-EnhancedUiStatus -Type Action -Message "Expanding $($disk.Name) to $newCapacityGB GB in vSphere..."
    Set-HardDisk -HardDisk $disk -CapacityGB $newCapacityGB -Server $server -Confirm:$false -ErrorAction Stop | Out-Null
    $disk = Get-VerifiedExpandedHardDisk -VM $vm -Server $server -HardDisk $disk -ExpectedCapacityGB $newCapacityGB
    $script:VmdkExpanded = $true

    Write-Host "`nSuccessfully expanded '$($disk.Name)' on '$($vm.Name)' by $additionalGB GB." -ForegroundColor Green
    Write-EnhancedUiStatus -Type Success -Message 'The vSphere virtual disk expansion completed.'

    Write-EnhancedUiPhase -Progress '3/4' -Title 'Optional Windows guest partition extension'
    if (Read-YesNo -Prompt 'Would you like to review and extend a Windows guest partition?') {
        Invoke-WindowsGuestPartitionExtension -VM $vm -SkipPartitionSelectionConfirmation:($workflow -eq 'Windows') -WindowsWorkstationWorkflow:($workflow -eq 'Windows')
    } else {
        Write-Host ''
        Write-Host 'The Windows partition/volume was not extended.' -ForegroundColor Yellow
    }

    Write-EnhancedUiSummary -SelectedVM $vm.Name -Progress '4/4' -SelectedDisk $disk.Name -OldCapacityGB $currentCapacityGB -NewCapacityGB $newCapacityGB
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    Write-ExecutionTimings
}
