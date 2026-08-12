#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core

<#
.SYNOPSIS
Changes CPU or memory, or adds a uniquely named virtual disk to one vSphere VM.

.DESCRIPTION
Selects a VM by exact name and provides three actions:
  1. Add vCPUs
  2. Add or remove memory
  3. Add an additional virtual disk

New virtual disks are created with an explicitly selected backing filename.
The filename follows the existing VM disk naming convention and is checked
against every attached VMDK filename, preventing duplicate names when the new
disk is placed on another datastore.

Type 'exit' at any text prompt to stop the script.

.PARAMETER VIServer
Optional vCenter Server name. When omitted, one active default PowerCLI
connection is reused. If there is not exactly one, the script prompts.

.PARAMETER Credential
Optional credential used by Connect-VIServer when a connection is required.

.PARAMETER VMName
Optional exact VM name. Wildcards are not allowed.

.PARAMETER Action
Optional action: CPU, Memory, or Disk.

.PARAMETER CPUToAdd
Number of vCPUs to add when Action is CPU.

.PARAMETER TargetCPUCount
Desired total vCPU count when Action is CPU: 8, 16, 24, or 32. This cannot be
used together with CPUToAdd. Interactive use asks for the desired total.

.PARAMETER MemoryGBToAdd
Memory in GB to add when Action is Memory.

.PARAMETER MemoryGBToRemove
Memory in GB to remove when Action is Memory. Memory removal requires the VM
to be powered off. This cannot be used together with MemoryGBToAdd.

.PARAMETER MemoryOperation
Optional memory operation: Add or Remove. When omitted, the script infers it
from a memory amount parameter or prompts interactively.

.PARAMETER DiskSizeGB
Capacity in GB of the new disk when Action is Disk.

.PARAMETER DatastoreName
Exact accessible datastore name for the new disk. When omitted, the script
lists the VM host's accessible datastores and prompts for a selection.

.PARAMETER StorageFormat
Storage format for a new disk: Thin, Thick, or EagerZeroedThick. Default: Thin.

.EXAMPLE
.\Add-vHardware-v1.ps1

.EXAMPLE
.\Add-vHardware-v1.ps1 -VMName SQL01 -Action CPU -TargetCPUCount 16

.EXAMPLE
.\Add-vHardware-v1.ps1 -VMName SQL01 -Action Memory -MemoryGBToAdd 16

.EXAMPLE
.\Add-vHardware-v1.ps1 -VMName SQL01 -Action Memory -MemoryOperation Remove -MemoryGBToRemove 8

.EXAMPLE
.\Add-vHardware-v1.ps1 -VMName SQL01 -Action Disk -DiskSizeGB 250 -DatastoreName SQL-DATA-02 -StorageFormat Thin
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
    [ValidateSet('CPU', 'Memory', 'Disk')]
    [string]$Action,

    [Parameter()]
    [ValidateRange(1, 2147483647)]
    [int]$CPUToAdd,

    [Parameter()]
    [ValidateSet(8, 16, 24, 32)]
    [int]$TargetCPUCount,

    [Parameter()]
    [ValidateScript({
            if ($_ -le 0) {
                throw 'MemoryGBToAdd must be greater than zero.'
            }
            $true
        })]
    [decimal]$MemoryGBToAdd,

    [Parameter()]
    [ValidateScript({
            if ($_ -le 0) {
                throw 'MemoryGBToRemove must be greater than zero.'
            }
            $true
        })]
    [decimal]$MemoryGBToRemove,

    [Parameter()]
    [ValidateSet('Add', 'Remove')]
    [string]$MemoryOperation,

    [Parameter()]
    [ValidateScript({
            if ($_ -le 0) {
                throw 'DiskSizeGB must be greater than zero.'
            }
            $true
        })]
    [decimal]$DiskSizeGB,

    [Parameter()]
    [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw 'DatastoreName cannot be blank.'
            }
            if ($_.IndexOfAny([char[]]'*?[]') -ge 0) {
                throw 'DatastoreName cannot contain wildcard characters (*, ?, [, or ]).'
            }
            $true
        })]
    [string]$DatastoreName,

    [Parameter()]
    [ValidateSet('Thin', 'Thick', 'EagerZeroedThick')]
    [string]$StorageFormat = 'Thin'
)

$ErrorActionPreference = 'Stop'
$script:ExitRequested = $false
$vmNameWasSupplied = $PSBoundParameters.ContainsKey('VMName')
$actionWasSupplied = $PSBoundParameters.ContainsKey('Action')
$cpuWasSupplied = $PSBoundParameters.ContainsKey('CPUToAdd')
$targetCpuWasSupplied = $PSBoundParameters.ContainsKey('TargetCPUCount')
$memoryAddWasSupplied = $PSBoundParameters.ContainsKey('MemoryGBToAdd')
$memoryRemoveWasSupplied = $PSBoundParameters.ContainsKey('MemoryGBToRemove')
$memoryOperationWasSupplied = $PSBoundParameters.ContainsKey('MemoryOperation')
$diskSizeWasSupplied = $PSBoundParameters.ContainsKey('DiskSizeGB')
$datastoreWasSupplied = $PSBoundParameters.ContainsKey('DatastoreName')

if ($cpuWasSupplied -and $targetCpuWasSupplied) {
    throw 'CPUToAdd and TargetCPUCount cannot be used together.'
}
if ($memoryAddWasSupplied -and $memoryRemoveWasSupplied) {
    throw 'MemoryGBToAdd and MemoryGBToRemove cannot be used together.'
}
if ($memoryOperationWasSupplied -and $MemoryOperation -eq 'Add' -and $memoryRemoveWasSupplied) {
    throw "MemoryOperation 'Add' cannot be used with MemoryGBToRemove."
}
if ($memoryOperationWasSupplied -and $MemoryOperation -eq 'Remove' -and $memoryAddWasSupplied) {
    throw "MemoryOperation 'Remove' cannot be used with MemoryGBToAdd."
}

function Write-Banner {
    $line = '=' * 72
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host '  vSphere VM Hardware Assistant - Version 1' -ForegroundColor Cyan
    Write-Host '  Add vCPU | Add/remove memory | Add a uniquely named virtual disk' -ForegroundColor Gray
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "Type 'exit' at any text prompt to stop.`n" -ForegroundColor DarkGray
}

function Read-ExitAwareInput {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $value = Read-Host -Prompt "$Prompt (type 'exit' to quit)"
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
        Write-Host 'Stopped. No changes were made.' -ForegroundColor Yellow
        exit 0
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
            default { Write-Warning "Enter yes, no, or 'exit'." }
        }
    }
}

function Get-VCenterConnection {
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

    if ([string]::IsNullOrWhiteSpace($VIServer) -and $existingConnections.Count -eq 1) {
        return $existingConnections[0]
    }

    $serverName = $VIServer
    while ([string]::IsNullOrWhiteSpace($serverName)) {
        $serverName = Read-ExitAwareInput -Prompt 'Enter the vCenter Server name'
        Stop-IfExitRequested
        if ([string]::IsNullOrWhiteSpace($serverName)) {
            Write-Warning 'A vCenter Server name is required.'
        }
    }

    $matchingConnection = @($existingConnections | Where-Object { $_.Name -ieq $serverName })
    if ($matchingConnection.Count -gt 0) {
        return $matchingConnection[0]
    }

    if ($null -ne $Credential) {
        return Connect-VIServer -Server $serverName -Credential $Credential -ErrorAction Stop
    }

    return Connect-VIServer -Server $serverName -ErrorAction Stop
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
        $matches = @($allVMs | Where-Object { $_.Name -ieq $InitialVMName })
        switch ($matches.Count) {
            0 { throw "No VM named '$InitialVMName' was found on $($Server.Name)." }
            1 { return $matches[0] }
            default { throw "More than one VM is named '$InitialVMName'. Use a unique VM name." }
        }
    }

    while ($true) {
        $name = Read-ExitAwareInput -Prompt 'Enter the exact VM name'
        Stop-IfExitRequested

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Warning 'A VM name is required.'
            continue
        }
        if ($name.IndexOfAny([char[]]'*?[]') -ge 0) {
            Write-Warning 'Wildcards are not allowed. Enter the VM name exactly.'
            continue
        }

        $matches = @($allVMs | Where-Object { $_.Name -ieq $name })
        switch ($matches.Count) {
            0 { Write-Warning "No VM named '$name' was found on $($Server.Name)." }
            1 { return $matches[0] }
            default { Write-Warning "More than one VM is named '$name'. Use a unique VM name." }
        }
    }
}

function Select-HardwareAction {
    if ($actionWasSupplied) {
        return $Action
    }

    while ($true) {
        Write-Host "`nChoose the hardware operation:" -ForegroundColor Cyan
        Write-Host '  1. vCPU'
        Write-Host '  2. Add or remove memory'
        Write-Host '  3. Additional disk'

        $selection = Read-ExitAwareInput -Prompt 'Enter 1, 2, or 3'
        Stop-IfExitRequested
        switch ($selection.Trim().ToUpperInvariant()) {
            '1'      { return 'CPU' }
            'CPU'    { return 'CPU' }
            'VCPU'   { return 'CPU' }
            '2'      { return 'Memory' }
            'MEMORY' { return 'Memory' }
            '3'      { return 'Disk' }
            'DISK'   { return 'Disk' }
            default { Write-Warning 'Enter 1, 2, or 3.' }
        }
    }
}

function Select-MemoryOperation {
    if ($memoryOperationWasSupplied) {
        return $MemoryOperation
    }
    if ($memoryAddWasSupplied) {
        return 'Add'
    }
    if ($memoryRemoveWasSupplied) {
        return 'Remove'
    }

    while ($true) {
        Write-Host "`nChoose the memory operation:" -ForegroundColor Cyan
        Write-Host '  1. Add memory'
        Write-Host '  2. Remove memory'

        $selection = Read-ExitAwareInput -Prompt 'Enter 1 or 2'
        Stop-IfExitRequested
        switch ($selection.Trim().ToUpperInvariant()) {
            '1'      { return 'Add' }
            'ADD'    { return 'Add' }
            '2'      { return 'Remove' }
            'REMOVE' { return 'Remove' }
            default { Write-Warning 'Enter 1 or 2.' }
        }
    }
}

function Read-TargetCpuCount {
    param(
        [Parameter(Mandatory)]
        [int]$CurrentCpu
    )

    $supportedCpuCounts = @(8, 16, 24, 32)
    $availableCpuCounts = @($supportedCpuCounts | Where-Object { $_ -gt $CurrentCpu })
    if ($availableCpuCounts.Count -eq 0) {
        throw "VM already has $CurrentCpu vCPUs. No higher supported target is available; this script offers totals of 8, 16, 24, and 32."
    }

    while ($true) {
        Write-Host "`nChoose the desired total vCPU count:" -ForegroundColor Cyan
        for ($index = 0; $index -lt $availableCpuCounts.Count; $index++) {
            Write-Host "  $($index + 1). $($availableCpuCounts[$index]) vCPUs"
        }

        $selection = Read-ExitAwareInput -Prompt "Enter a menu number or total vCPU count ($($availableCpuCounts -join ', '))"
        Stop-IfExitRequested

        [int]$number = 0
        if ([int]::TryParse($selection, [ref]$number)) {
            if ($number -ge 1 -and $number -le $availableCpuCounts.Count) {
                return $availableCpuCounts[$number - 1]
            }
            if ($availableCpuCounts -contains $number) {
                return $number
            }
        }

        Write-Warning "Choose one of these totals: $($availableCpuCounts -join ', ')."
    }
}

function Read-PositiveDecimal {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    while ($true) {
        $inputValue = Read-ExitAwareInput -Prompt $Prompt
        Stop-IfExitRequested
        [decimal]$number = 0
        if ([decimal]::TryParse($inputValue, [ref]$number) -and $number -gt 0) {
            return $number
        }
        Write-Warning 'Enter a number greater than zero.'
    }
}

function Get-VmCoresPerSocket {
    param(
        [Parameter(Mandatory)]
        [object]$VM
    )

    $coresPerSocket = [int]$VM.ExtensionData.Config.Hardware.NumCoresPerSocket
    if ($coresPerSocket -lt 1) {
        return 1
    }

    return $coresPerSocket
}

function Get-CompatibleCoresPerSocket {
    param(
        [Parameter(Mandatory)]
        [int]$TotalCpu,

        [Parameter(Mandatory)]
        [int]$PreferredCoresPerSocket
    )

    if ($TotalCpu % $PreferredCoresPerSocket -eq 0) {
        return $PreferredCoresPerSocket
    }

    # Select the largest valid divisor no greater than the current setting.
    # This keeps the topology as close as possible without exceeding the
    # administrator's existing cores-per-socket choice.
    for ($candidate = [math]::Min($PreferredCoresPerSocket, $TotalCpu); $candidate -ge 1; $candidate--) {
        if ($TotalCpu % $candidate -eq 0) {
            return $candidate
        }
    }

    return 1
}

function Assert-HotAddAvailability {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [ValidateSet('CPU', 'Memory')]
        [string]$Resource
    )

    if ([string]$VM.PowerState -ne 'PoweredOn') {
        return
    }

    $enabled = if ($Resource -eq 'CPU') {
        [bool]$VM.ExtensionData.Config.CpuHotAddEnabled
    }
    else {
        [bool]$VM.ExtensionData.Config.MemoryHotAddEnabled
    }

    if (-not $enabled) {
        throw "$Resource hot-add is not enabled on powered-on VM '$($VM.Name)'. Power off the VM before adding $Resource, or enable hot-add first. No change was made."
    }
}

function Get-VmdkFileName {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$DatastorePath
    )

    if ([string]::IsNullOrWhiteSpace($DatastorePath)) {
        return $null
    }
    if ($DatastorePath -match '([^/\\]+\.vmdk)$') {
        return $Matches[1]
    }
    return $null
}

function Get-VmdkFolder {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$DatastorePath
    )

    if ($DatastorePath -match '^\[[^\]]+\]\s+(.+)[/\\][^/\\]+$') {
        return ($Matches[1] -replace '\\', '/')
    }
    return $null
}

function Get-VmdkDatastoreName {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$DatastorePath
    )

    if ($DatastorePath -match '^\[([^\]]+)\]') {
        return $Matches[1]
    }
    return $null
}

function Get-NaturalHardDiskSortKey {
    param(
        [Parameter(Mandatory)]
        [object]$HardDisk
    )

    $match = [regex]::Match([string]$HardDisk.Name, '\d+(?=\D*$)')
    if ($match.Success) {
        return [int]$match.Value
    }
    return [int]::MaxValue
}

function Get-UniqueVmdkFileName {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object[]]$HardDisks
    )

    $sortedDisks = @($HardDisks | Sort-Object @{ Expression = { Get-NaturalHardDiskSortKey -HardDisk $_ } }, Name)
    $existingFileNames = @(
        $HardDisks |
            ForEach-Object { Get-VmdkFileName -DatastorePath ([string]$_.Filename) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $rootName = $null
    if ($sortedDisks.Count -gt 0) {
        $firstFileName = Get-VmdkFileName -DatastorePath ([string]$sortedDisks[0].Filename)
        if (-not [string]::IsNullOrWhiteSpace($firstFileName)) {
            $rootName = $firstFileName -replace '(?i)\.vmdk$', ''
            $rootName = $rootName -replace '_\d+$', ''
        }
    }

    if ([string]::IsNullOrWhiteSpace($rootName)) {
        $rootName = ([string]$VM.Name -replace '[\\/:*?"<>|]', '_').Trim()
    }
    if ([string]::IsNullOrWhiteSpace($rootName)) {
        $rootName = 'virtual-disk'
    }

    $usedNames = @{}
    foreach ($fileName in $existingFileNames) {
        $usedNames[$fileName.ToUpperInvariant()] = $true
    }

    $highestSuffix = 0
    $escapedRootName = [regex]::Escape($rootName)
    foreach ($fileName in $existingFileNames) {
        if ($fileName -match "(?i)^$escapedRootName(?:_(?<Suffix>\d+))?\.vmdk$") {
            $suffix = if ($Matches.Suffix) { [int]$Matches.Suffix } else { 0 }
            if ($suffix -gt $highestSuffix) {
                $highestSuffix = $suffix
            }
        }
    }

    $nextSuffix = $highestSuffix + 1
    do {
        $candidate = "${rootName}_${nextSuffix}.vmdk"
        $nextSuffix++
    } while ($usedNames.ContainsKey($candidate.ToUpperInvariant()))

    return $candidate
}

function Get-AvailableDatastores {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object]$Server
    )

    $vmHost = Get-VMHost -VM $VM -Server $Server -ErrorAction Stop
    return @(
        Get-Datastore -RelatedObject $vmHost -Server $Server -ErrorAction Stop |
            Where-Object {
                $_.State -eq 'Available' -and
                ($null -eq $_.ExtensionData.Summary.Accessible -or [bool]$_.ExtensionData.Summary.Accessible)
            } |
            Sort-Object Name
    )
}

function Select-Datastore {
    param(
        [Parameter(Mandatory)]
        [object[]]$Datastores,

        [Parameter()]
        [string]$InitialDatastoreName
    )

    if ($Datastores.Count -eq 0) {
        throw 'No accessible datastores were found for the VM host.'
    }

    if ($PSBoundParameters.ContainsKey('InitialDatastoreName')) {
        $matches = @($Datastores | Where-Object { $_.Name -ieq $InitialDatastoreName })
        switch ($matches.Count) {
            0 { throw "Accessible datastore '$InitialDatastoreName' was not found." }
            1 { return $matches[0] }
            default { throw "More than one accessible datastore is named '$InitialDatastoreName'." }
        }
    }

    Write-Host "`nAccessible datastores:" -ForegroundColor Cyan
    $display = for ($index = 0; $index -lt $Datastores.Count; $index++) {
        [pscustomobject]@{
            Number      = $index + 1
            Datastore   = $Datastores[$index].Name
            FreeSpaceGB = [math]::Round([decimal]$Datastores[$index].FreeSpaceGB, 2)
            CapacityGB  = [math]::Round([decimal]$Datastores[$index].CapacityGB, 2)
            Type        = $Datastores[$index].Type
        }
    }
    $display | Format-Table -AutoSize | Out-Host

    while ($true) {
        $choice = Read-ExitAwareInput -Prompt 'Enter the datastore number for the new disk'
        Stop-IfExitRequested
        [int]$number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $Datastores.Count) {
            return $Datastores[$number - 1]
        }
        Write-Warning "Enter a number from 1 to $($Datastores.Count)."
    }
}

function Get-TargetVmdkFolder {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object]$Datastore,

        [Parameter(Mandatory)]
        [object[]]$HardDisks
    )

    $diskOnTargetDatastore = $HardDisks |
        Where-Object { (Get-VmdkDatastoreName -DatastorePath ([string]$_.Filename)) -ieq $Datastore.Name } |
        Select-Object -First 1
    if ($null -ne $diskOnTargetDatastore) {
        $folder = Get-VmdkFolder -DatastorePath ([string]$diskOnTargetDatastore.Filename)
        if (-not [string]::IsNullOrWhiteSpace($folder)) {
            return $folder
        }
    }

    $vmHomeFolder = Get-VmdkFolder -DatastorePath ([string]$VM.ExtensionData.Config.Files.VmPathName)
    if (-not [string]::IsNullOrWhiteSpace($vmHomeFolder)) {
        return $vmHomeFolder
    }

    return (([string]$VM.Name -replace '[\\/:*?"<>|]', '_').Trim())
}

function Get-FreeScsiLocation {
    param(
        [Parameter(Mandatory)]
        [object]$VMView
    )

    $devices = @($VMView.Config.Hardware.Device)
    $controllers = @(
        $devices |
            Where-Object { $_ -is [VMware.Vim.VirtualSCSIController] } |
            Sort-Object BusNumber
    )
    foreach ($controller in $controllers) {
        $usedUnits = @(
            $devices |
                Where-Object { $_.ControllerKey -eq $controller.Key } |
                ForEach-Object { [int]$_.UnitNumber }
        )
        foreach ($unitNumber in 0..15) {
            if ($unitNumber -eq 7 -or $usedUnits -contains $unitNumber) {
                continue
            }
            return [pscustomobject]@{
                ControllerKey = [int]$controller.Key
                BusNumber     = [int]$controller.BusNumber
                UnitNumber    = $unitNumber
            }
        }
    }

    throw 'No free unit number is available on the VM existing SCSI controllers. Add another SCSI controller before adding this disk.'
}

function Wait-VSphereTask {
    param(
        [Parameter(Mandatory)]
        [object]$TaskReference,

        [Parameter(Mandatory)]
        [object]$Server
    )

    # Query a fresh Task view on each pass. UpdateViewData can reject nested
    # TaskInfo property paths on some PowerCLI/vCenter combinations even after
    # the underlying reconfiguration has already completed successfully.
    do {
        $taskView = Get-View -Id $TaskReference -Server $Server -Property Info.State,Info.Error -ErrorAction Stop
        if ($taskView.Info.State -in @('queued', 'running')) {
            Start-Sleep -Seconds 1
        }
    } while ($taskView.Info.State -in @('queued', 'running'))

    if ($taskView.Info.State -ne 'success') {
        $message = [string]$taskView.Info.Error.LocalizedMessage
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = 'vSphere did not return task error details.'
        }
        throw "The vSphere reconfiguration task failed: $message"
    }
}

function Resolve-UniqueVmdkTarget {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [object]$Datastore
    )

    if ($Datastore.Name -match '\]') {
        throw "Datastore '$($Datastore.Name)' contains an unsupported closing bracket in its name."
    }

    $hardDisks = @(Get-HardDisk -VM $VM -Server $Server -ErrorAction Stop)
    $folder = Get-TargetVmdkFolder -VM $VM -Datastore $Datastore -HardDisks $hardDisks
    if ([string]::IsNullOrWhiteSpace($folder)) {
        throw 'A target datastore folder could not be determined.'
    }

    # Check both attached disks and existing files on the selected datastore.
    # If an orphaned VMDK already owns a proposed path, reserve its name and
    # generate the next suffix instead of attempting to reuse or overwrite it.
    $attempt = 0
    do {
        $attempt++
        if ($attempt -gt 1000) {
            throw 'A unique VMDK filename could not be found after 1,000 attempts.'
        }

        $fileName = Get-UniqueVmdkFileName -VM $VM -HardDisks $hardDisks
        $targetPath = "[$($Datastore.Name)] $folder/$fileName"
        $pathCollisions = @(
            Get-HardDisk -Datastore $Datastore -DatastorePath $targetPath -Server $Server -ErrorAction SilentlyContinue |
                Where-Object { [string]$_.Filename -ieq $targetPath }
        )
        if ($pathCollisions.Count -gt 0) {
            $hardDisks += $pathCollisions
        }
    } while ($pathCollisions.Count -gt 0)

    return [pscustomobject]@{
        FileName      = $fileName
        Folder        = $folder
        DatastorePath = $targetPath
    }
}

function Add-UniqueVirtualDisk {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [object]$Datastore,

        [Parameter(Mandatory)]
        [decimal]$CapacityGB,

        [Parameter(Mandatory)]
        [ValidateSet('Thin', 'Thick', 'EagerZeroedThick')]
        [string]$Format,

        [Parameter(Mandatory)]
        [string]$ExpectedDatastorePath
    )

    # Re-resolve immediately before creation. If anything claimed the confirmed
    # path after it was displayed, stop rather than create a different filename.
    $target = Resolve-UniqueVmdkTarget -VM $VM -Server $Server -Datastore $Datastore
    if ($target.DatastorePath -ine $ExpectedDatastorePath) {
        throw "The confirmed VMDK path '$ExpectedDatastorePath' is no longer available. The next safe path is '$($target.DatastorePath)'. Run the script again to review and confirm it."
    }
    $fileName = $target.FileName
    $targetPath = $target.DatastorePath

    # Get-View's VIObject parameter set does not accept -Server. The VM object
    # already carries its originating vCenter connection context.
    $vmView = Get-View -VIObject $VM -Property Config.Hardware.Device,Config.Files.VmPathName -ErrorAction Stop
    $scsiLocation = Get-FreeScsiLocation -VMView $vmView

    $backing = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo
    $backing.FileName = $targetPath
    $backing.DiskMode = 'persistent'
    switch ($Format) {
        'Thin' {
            $backing.ThinProvisioned = $true
            $backing.EagerlyScrub = $false
        }
        'Thick' {
            $backing.ThinProvisioned = $false
            $backing.EagerlyScrub = $false
        }
        'EagerZeroedThick' {
            $backing.ThinProvisioned = $false
            $backing.EagerlyScrub = $true
        }
    }

    $virtualDisk = New-Object VMware.Vim.VirtualDisk
    $virtualDisk.Key = -1
    $virtualDisk.ControllerKey = $scsiLocation.ControllerKey
    $virtualDisk.UnitNumber = $scsiLocation.UnitNumber
    $virtualDisk.CapacityInKB = [long][math]::Round($CapacityGB * 1MB)
    $virtualDisk.Backing = $backing

    $deviceSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
    $deviceSpec.Operation = [VMware.Vim.VirtualDeviceConfigSpecOperation]::add
    $deviceSpec.FileOperation = [VMware.Vim.VirtualDeviceConfigSpecFileOperation]::create
    $deviceSpec.Device = $virtualDisk

    $configSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $configSpec.DeviceChange = @($deviceSpec)

    $taskReference = $vmView.ReconfigVM_Task($configSpec)
    Wait-VSphereTask -TaskReference $taskReference -Server $Server

    $updatedDisks = @(Get-HardDisk -VM $VM -Server $Server -ErrorAction Stop)
    $createdDisk = $updatedDisks |
        Where-Object { [string]$_.Filename -ieq $targetPath } |
        Select-Object -First 1
    if ($null -eq $createdDisk) {
        throw "vSphere reported success, but the new disk '$targetPath' could not be verified."
    }

    return [pscustomobject]@{
        HardDisk       = $createdDisk
        FileName       = $fileName
        DatastorePath  = $targetPath
        Controller     = "SCSI $($scsiLocation.BusNumber):$($scsiLocation.UnitNumber)"
    }
}

function Show-ExistingDisks {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [object]$Server
    )

    $hardDisks = @(
        Get-HardDisk -VM $VM -Server $Server -ErrorAction Stop |
            Sort-Object @{ Expression = { Get-NaturalHardDiskSortKey -HardDisk $_ } }, Name
    )
    Write-Host "`nExisting virtual disks on '$($VM.Name)':" -ForegroundColor Cyan
    $display = for ($index = 0; $index -lt $hardDisks.Count; $index++) {
        [pscustomobject]@{
            Number        = $index + 1
            Disk          = $hardDisks[$index].Name
            CapacityGB    = [decimal]$hardDisks[$index].CapacityGB
            Datastore     = Get-VmdkDatastoreName -DatastorePath ([string]$hardDisks[$index].Filename)
            VmdkFolder    = Get-VmdkFolder -DatastorePath ([string]$hardDisks[$index].Filename)
            BackingFile   = Get-VmdkFileName -DatastorePath ([string]$hardDisks[$index].Filename)
        }
    }
    $display | Format-Table -AutoSize | Out-Host
    return $hardDisks
}

try {
    Write-Banner
    $server = Get-VCenterConnection
    Write-Host "Using vCenter connection '$($server.Name)'." -ForegroundColor Green

    $vmArguments = @{ Server = $server }
    if ($vmNameWasSupplied) {
        $vmArguments.InitialVMName = $VMName
    }
    $vm = Select-ExactVM @vmArguments
    $currentCoresPerSocket = Get-VmCoresPerSocket -VM $vm
    Write-Host "Selected VM '$($vm.Name)'." -ForegroundColor Green
    Write-Host "  Power state: $($vm.PowerState)"
    Write-Host "  Current CPU: $($vm.NumCpu) vCPU(s)"
    Write-Host "  Cores/socket: $currentCoresPerSocket"
    Write-Host "  Current RAM: $($vm.MemoryGB) GB"
    $cpuHotAddEnabled = [bool]$vm.ExtensionData.Config.CpuHotAddEnabled
    $memoryHotAddEnabled = [bool]$vm.ExtensionData.Config.MemoryHotAddEnabled
    Write-Host ("  CPU Hot Add:    {0}" -f $(if ($cpuHotAddEnabled) { 'Enabled' } else { 'Disabled' })) -ForegroundColor $(if ($cpuHotAddEnabled) { 'Green' } else { 'Yellow' })
    Write-Host ("  Memory Hot Add: {0}" -f $(if ($memoryHotAddEnabled) { 'Enabled' } else { 'Disabled' })) -ForegroundColor $(if ($memoryHotAddEnabled) { 'Green' } else { 'Yellow' })
    $null = Show-ExistingDisks -VM $vm -Server $server

    $selectedAction = Select-HardwareAction
    switch ($selectedAction) {
        'CPU' {
            Assert-HotAddAvailability -VM $vm -Resource CPU
            $newCpuCount = if ($targetCpuWasSupplied) {
                $TargetCPUCount
            }
            elseif ($cpuWasSupplied) {
                [int]$vm.NumCpu + $CPUToAdd
            }
            else {
                Read-TargetCpuCount -CurrentCpu ([int]$vm.NumCpu)
            }

            if ($newCpuCount -le [int]$vm.NumCpu) {
                throw "The target CPU count must be greater than the current $($vm.NumCpu) vCPUs. No change was made."
            }

            if ([string]$vm.PowerState -eq 'PoweredOn') {
                if ($newCpuCount -gt $currentCoresPerSocket) {
                    throw "Powered-on VM '$($vm.Name)' is configured for $currentCoresPerSocket cores per socket. vSphere cannot hot-add to $newCpuCount vCPUs because that total exceeds the current topology limit. Power off the VM, then rerun this change. No change was made."
                }
                if ($newCpuCount % $currentCoresPerSocket -ne 0) {
                    throw "Powered-on VM '$($vm.Name)' uses $currentCoresPerSocket cores per socket, which is incompatible with a total of $newCpuCount vCPUs. Power off the VM to change its CPU topology. No change was made."
                }
            }

            $newCoresPerSocket = if ([string]$vm.PowerState -eq 'PoweredOn') {
                $currentCoresPerSocket
            }
            else {
                Get-CompatibleCoresPerSocket -TotalCpu $newCpuCount -PreferredCoresPerSocket $currentCoresPerSocket
            }

            Write-Host "`nPlanned change:" -ForegroundColor Cyan
            Write-Host "  VM:               $($vm.Name)"
            Write-Host "  vCPU:             $($vm.NumCpu) -> $newCpuCount"
            Write-Host "  Cores per socket: $currentCoresPerSocket -> $newCoresPerSocket"
            if (-not (Read-YesNo -Prompt 'Apply this vCPU change?')) {
                Write-Host 'Cancelled. No changes were made.' -ForegroundColor Yellow
                return
            }

            $cpuChangeParameters = @{
                VM          = $vm
                NumCpu      = $newCpuCount
                Confirm     = $false
                Server      = $server
                ErrorAction = 'Stop'
            }
            if ($newCoresPerSocket -ne $currentCoresPerSocket) {
                $cpuChangeParameters.CoresPerSocket = $newCoresPerSocket
            }

            Set-VM @cpuChangeParameters | Out-Null
            $verifiedVm = Get-VM -Id $vm.Id -Server $server -ErrorAction Stop
            if ([int]$verifiedVm.NumCpu -ne $newCpuCount) {
                throw "The vCPU operation completed, but verification returned $($verifiedVm.NumCpu) instead of $newCpuCount."
            }
            $verifiedCoresPerSocket = Get-VmCoresPerSocket -VM $verifiedVm
            if ($verifiedCoresPerSocket -ne $newCoresPerSocket) {
                throw "The vCPU operation completed, but verification returned $verifiedCoresPerSocket cores per socket instead of $newCoresPerSocket."
            }
            Write-Host "Successfully increased '$($vm.Name)' to $newCpuCount vCPU(s) with $newCoresPerSocket cores per socket." -ForegroundColor Green
        }

        'Memory' {
            $selectedMemoryOperation = Select-MemoryOperation
            if ($selectedMemoryOperation -eq 'Add') {
                Assert-HotAddAvailability -VM $vm -Resource Memory
                $memoryAmountGB = if ($memoryAddWasSupplied) {
                    $MemoryGBToAdd
                }
                else {
                    Read-PositiveDecimal -Prompt 'Enter the memory to add in GB'
                }
                [decimal]$newMemoryGB = [decimal]$vm.MemoryGB + $memoryAmountGB
                $memoryChangeDescription = 'Add memory'
                $memorySuccessVerb = 'increased'
            }
            else {
                if ([string]$vm.PowerState -ne 'PoweredOff') {
                    throw "Memory cannot be removed while VM '$($vm.Name)' is $($vm.PowerState). Power off the VM, then rerun the removal. No change was made."
                }

                while ($true) {
                    $memoryAmountGB = if ($memoryRemoveWasSupplied) {
                        $MemoryGBToRemove
                    }
                    else {
                        Read-PositiveDecimal -Prompt 'Enter the memory to remove in GB'
                    }

                    if ($memoryAmountGB -lt [decimal]$vm.MemoryGB) {
                        break
                    }

                    $message = "The removal amount must be less than the VM's current $($vm.MemoryGB) GB of memory."
                    if ($memoryRemoveWasSupplied) {
                        throw "$message No change was made."
                    }
                    Write-Warning $message
                }

                [decimal]$newMemoryGB = [decimal]$vm.MemoryGB - $memoryAmountGB
                $memoryChangeDescription = 'Remove memory'
                $memorySuccessVerb = 'decreased'
            }

            Write-Host "`nPlanned change:" -ForegroundColor Cyan
            Write-Host "  VM:        $($vm.Name)"
            Write-Host "  Operation: $memoryChangeDescription"
            Write-Host "  Memory:    $($vm.MemoryGB) GB -> $newMemoryGB GB"
            if (-not (Read-YesNo -Prompt 'Apply this memory change?')) {
                Write-Host 'Cancelled. No changes were made.' -ForegroundColor Yellow
                return
            }

            Set-VM -VM $vm -MemoryGB $newMemoryGB -Confirm:$false -Server $server -ErrorAction Stop | Out-Null
            $verifiedVm = Get-VM -Id $vm.Id -Server $server -ErrorAction Stop
            if ([decimal]$verifiedVm.MemoryGB -ne $newMemoryGB) {
                throw "The memory operation completed, but verification returned $($verifiedVm.MemoryGB) GB instead of $newMemoryGB GB."
            }
            Write-Host "Successfully $memorySuccessVerb '$($vm.Name)' memory to $newMemoryGB GB." -ForegroundColor Green
        }

        'Disk' {
            [decimal]$capacity = if ($diskSizeWasSupplied) { $DiskSizeGB } else { Read-PositiveDecimal -Prompt 'Enter the new disk size in GB' }
            $datastores = @(Get-AvailableDatastores -VM $vm -Server $server)
            $datastoreArguments = @{ Datastores = $datastores }
            if ($datastoreWasSupplied) {
                $datastoreArguments.InitialDatastoreName = $DatastoreName
            }
            $targetDatastore = Select-Datastore @datastoreArguments

            $plannedTarget = Resolve-UniqueVmdkTarget -VM $vm -Server $server -Datastore $targetDatastore
            $plannedPath = $plannedTarget.DatastorePath

            Write-Host "`nPlanned change:" -ForegroundColor Cyan
            Write-Host "  VM:             $($vm.Name)"
            Write-Host "  Disk capacity:  $capacity GB"
            Write-Host "  Storage format: $StorageFormat"
            Write-Host "  Datastore:      $($targetDatastore.Name)"
            Write-Host "  Backing file:   $plannedPath" -ForegroundColor Green
            if ([decimal]$targetDatastore.FreeSpaceGB -lt $capacity) {
                Write-Warning "The datastore reports only $([math]::Round([decimal]$targetDatastore.FreeSpaceGB, 2)) GB free. Thin provisioning may overcommit storage; Thick formats may fail."
            }
            if (-not (Read-YesNo -Prompt 'Create and attach this virtual disk?')) {
                Write-Host 'Cancelled. No changes were made.' -ForegroundColor Yellow
                return
            }

            $result = Add-UniqueVirtualDisk -VM $vm -Server $server -Datastore $targetDatastore -CapacityGB $capacity -Format $StorageFormat -ExpectedDatastorePath $plannedPath
            Write-Host "Successfully added '$($result.HardDisk.Name)' to '$($vm.Name)'." -ForegroundColor Green
            Write-Host "  Backing file: $($result.DatastorePath)"
            Write-Host "  Controller:   $($result.Controller)"
            Write-Host 'The disk is not initialized or formatted inside the guest OS.' -ForegroundColor Yellow
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
