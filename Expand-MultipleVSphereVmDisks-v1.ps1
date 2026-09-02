#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core

<#
.SYNOPSIS
Expands a Windows drive to a target VMDK size across multiple vSphere VMs.

.DESCRIPTION
Processes multiple VM names or wildcard patterns without per-VM approval
prompts. For each matching VM, the script maps a Windows drive letter to exactly
one virtual hard disk. It prefers PowerCLI guest-volume mapping, then accepts an
exact guest serial/VMDK UUID match or a unique disk-capacity match. Ambiguous
matches are never guessed. It expands the VMDK only when it is smaller than the
requested target capacity, rescans Windows storage through VMware Tools, and
extends the mapped partition into all contiguous unallocated space.

If a Windows Recovery partition blocks the extension, the VM is skipped unless
AllowRecoveryPartitionDeletion is explicitly supplied. With that switch, WinRE
is disabled and the adjacent Recovery partition is permanently deleted before
the selected partition is extended. The Recovery partition is not recreated
and WinRE is not re-enabled. Non-Recovery blocking partitions are never deleted.

Each VM is isolated from failures on other VMs. A summary is displayed at the
end and can optionally be exported to CSV.

.PARAMETER VIServer
Optional vCenter Server name. If omitted and exactly one active default
PowerCLI connection exists, that connection is reused.

.PARAMETER Credential
Optional credential used only when Connect-VIServer is required.

.PARAMETER VMName
One or more exact VM names or PowerShell wildcard patterns, such as SQL* or
APP-??. Every matching VM receives the same DriveLetter and TargetCapacityGB.
When omitted, the script prompts for a comma-separated list of names or patterns.

.PARAMETER DriveLetter
Windows drive letter to extend on every VM, for example D or D:. Required when
InputCsvPath is not used; if omitted, the script prompts once.

.PARAMETER TargetCapacityGB
Desired total capacity of the VMDK in GB. A VMDK already at or above this size
is not reduced. If the VMDK is larger than the target, that VM is skipped
entirely and its Windows partition is not changed. If it is exactly equal to the
target, the Windows partition is still checked for unallocated space.

.PARAMETER InputCsvPath
Optional CSV manifest containing VMName, DriveLetter, and TargetCapacityGB.
VMName entries can be exact names or wildcard patterns. Cannot be combined with
VMName, DriveLetter, or TargetCapacityGB.

.PARAMETER GuestCredential
Windows administrator credential used through VMware Tools for all VMs. If
omitted, the standard credential prompt is displayed once.

.PARAMETER AllowRecoveryPartitionDeletion
Allows permanent deletion of an adjacent Windows Recovery partition when it is
the only partition blocking extension. This disables WinRE and does not rebuild
the Recovery partition. It never authorizes deletion of other partition types.

.PARAMETER CsvReportPath
Optional path for the final per-VM result report. Its parent folder must exist.

.EXAMPLE
.\Expand-MultipleVSphereVmDisks-v1.ps1 -VMName SQL01,SQL02,SQL03 -DriveLetter D -TargetCapacityGB 500 -GuestCredential (Get-Credential)

.EXAMPLE
.\Expand-MultipleVSphereVmDisks-v1.ps1 -VMName 'SQL-PROD-*' -DriveLetter D -TargetCapacityGB 500 -GuestCredential (Get-Credential)

.EXAMPLE
.\Expand-MultipleVSphereVmDisks-v1.ps1 -InputCsvPath .\DiskTargets.csv -GuestCredential (Get-Credential) -CsvReportPath .\DiskExpansionResults.csv

.EXAMPLE
.\Expand-MultipleVSphereVmDisks-v1.ps1 -VMName APP01,APP02 -DriveLetter C -TargetCapacityGB 250 -GuestCredential (Get-Credential) -AllowRecoveryPartitionDeletion
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
                throw 'VMName entries cannot be blank.'
            }
            $true
        })]
    [string[]]$VMName,

    [Parameter()]
    [ValidatePattern('^(?i:[A-Z]):?$')]
    [string]$DriveLetter,

    [Parameter()]
    [ValidateScript({
            if ($_ -le 0) {
                throw 'TargetCapacityGB must be greater than zero.'
            }
            $true
        })]
    [decimal]$TargetCapacityGB,

    [Parameter()]
    [ValidateScript({
            if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) {
                throw "Input CSV file '$_' was not found."
            }
            $true
        })]
    [string]$InputCsvPath,

    [Parameter()]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter()]
    [switch]$AllowRecoveryPartitionDeletion,

    [Parameter()]
    [string]$CsvReportPath
)

$ErrorActionPreference = 'Stop'
$script:ExitRequested = $false
$targetCapacityWasSupplied = $PSBoundParameters.ContainsKey('TargetCapacityGB')

$manifestParametersUsed = $PSBoundParameters.ContainsKey('VMName') -or
    $PSBoundParameters.ContainsKey('DriveLetter') -or
    $PSBoundParameters.ContainsKey('TargetCapacityGB')
if (-not [string]::IsNullOrWhiteSpace($InputCsvPath) -and $manifestParametersUsed) {
    throw 'InputCsvPath cannot be combined with VMName, DriveLetter, or TargetCapacityGB.'
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
        Write-Host 'Stopped. No changes were made.' -ForegroundColor Yellow
        exit 0
    }
}

function Write-AlignedDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Details,

        [Parameter()]
        [ValidateRange(0, 40)]
        [int]$Indent = 2
    )

    if ($Details.Count -eq 0) {
        return
    }

    $labelWidth = [int](($Details.Keys | ForEach-Object { ([string]$_).Length } | Measure-Object -Maximum).Maximum)
    $prefix = ' ' * $Indent
    foreach ($labelObject in $Details.Keys) {
        $label = [string]$labelObject
        Write-Host ('{0}{1} : {2}' -f $prefix, $label.PadRight($labelWidth), $Details[$labelObject])
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
        $release = ''
        try {
            $serviceInstance = Get-View -Id 'ServiceInstance-ServiceInstance' -Server $connection -ErrorAction Stop
            $release = [string]$serviceInstance.Content.About.FullName
        }
        catch {
            $release = ''
        }
        if ([string]::IsNullOrWhiteSpace($release)) {
            $build = [string]$connection.Build
            $release = if ([string]::IsNullOrWhiteSpace($build)) { 'Unavailable' } else { "Build $build" }
        }
        $indent = if ($connections.Count -eq 1) { 2 } else { 4 }
        Write-AlignedDetails -Indent $indent -Details ([ordered]@{
                'Host name' = [string]$connection.Name
                'Version'   = $version
                'Release'   = $release
            })
    }
    Write-Host ''
}

function Get-VCenterConnection {
    $connections = @()
    foreach ($connection in (@($global:DefaultVIServer) + @($global:DefaultVIServers))) {
        if ($null -eq $connection) { continue }
        if ($connection.PSObject.Properties.Name -contains 'IsConnected' -and -not $connection.IsConnected) { continue }
        if (@($connections | Where-Object { $_.Name -ieq $connection.Name }).Count -eq 0) {
            $connections += $connection
        }
    }

    if ([string]::IsNullOrWhiteSpace($VIServer) -and $connections.Count -eq 1) {
        return $connections[0]
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

    $match = @($connections | Where-Object { $_.Name -ieq $serverName })
    if ($match.Count -gt 0) { return $match[0] }
    $connectionCredential = $Credential
    if ($null -eq $connectionCredential) {
        $connectionCredential = Get-Credential -Message "Enter credentials for vCenter Server '$serverName'."
        if ($null -eq $connectionCredential) {
            throw 'The vCenter credential prompt was cancelled.'
        }
    }
    return Connect-VIServer -Server $serverName -Credential $connectionCredential -ErrorAction Stop
}

function ConvertTo-NormalizedDriveLetter {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $normalized = $Value.Trim().TrimEnd(':').ToUpperInvariant()
    if ($normalized -notmatch '^[A-Z]$') {
        throw "Drive letter '$Value' is invalid. Use one letter, for example D or D:."
    }
    return $normalized
}

function Read-TargetCapacityGB {
    while ($true) {
        $value = Read-ExitAwareInput -Prompt 'Enter the target virtual disk capacity, in GB'
        Stop-IfExitRequested
        [decimal]$number = 0
        if ([decimal]::TryParse($value, [ref]$number) -and $number -gt 0) {
            return $number
        }
        Write-Warning 'Enter a number greater than zero.'
        Write-Host ''
    }
}

function Get-WorkItems {
    if (-not [string]::IsNullOrWhiteSpace($InputCsvPath)) {
        $rows = @(Import-Csv -LiteralPath $InputCsvPath)
        if ($rows.Count -eq 0) {
            throw "Input CSV '$InputCsvPath' contains no rows."
        }
        $requiredColumns = @('VMName', 'DriveLetter', 'TargetCapacityGB')
        foreach ($column in $requiredColumns) {
            if ($rows[0].PSObject.Properties.Name -notcontains $column) {
                throw "Input CSV '$InputCsvPath' must contain a '$column' column."
            }
        }

        $items = foreach ($row in $rows) {
            if ([string]::IsNullOrWhiteSpace([string]$row.VMName)) {
                throw 'Every input CSV row must contain VMName.'
            }
            [decimal]$target = 0
            if (-not [decimal]::TryParse([string]$row.TargetCapacityGB, [ref]$target) -or $target -le 0) {
                throw "TargetCapacityGB '$($row.TargetCapacityGB)' for '$($row.VMName)' is invalid."
            }
            [pscustomobject]@{
                VMName           = ([string]$row.VMName).Trim()
                DriveLetter      = ConvertTo-NormalizedDriveLetter -Value ([string]$row.DriveLetter)
                TargetCapacityGB = $target
            }
        }
        return @($items)
    }

    $names = @($VMName)
    while ($names.Count -eq 0) {
        $value = Read-ExitAwareInput -Prompt 'Enter virtual machine names or wildcard patterns, separated by commas'
        Stop-IfExitRequested
        $names = @($value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($names.Count -eq 0) {
            Write-Warning 'Enter at least one VM name.'
            Write-Host ''
        }
    }
    $selectedDrive = $DriveLetter
    while ([string]::IsNullOrWhiteSpace($selectedDrive)) {
        Write-Host ''
        $selectedDrive = Read-ExitAwareInput -Prompt 'Enter the Windows drive letter to extend (for example, D)'
        Stop-IfExitRequested
        try {
            $selectedDrive = ConvertTo-NormalizedDriveLetter -Value $selectedDrive
        }
        catch {
            Write-Warning $_.Exception.Message
            $selectedDrive = $null
        }
    }
    $selectedDrive = ConvertTo-NormalizedDriveLetter -Value $selectedDrive

    $target = $TargetCapacityGB
    if (-not $targetCapacityWasSupplied) {
        Write-Host ''
        $target = Read-TargetCapacityGB
    }

    return @(
        $names | Sort-Object -Unique | ForEach-Object {
            [pscustomobject]@{
                VMName           = $_
                DriveLetter      = $selectedDrive
                TargetCapacityGB = $target
            }
        }
    )
}

function Get-ResolvedGuestCredential {
    if ($null -ne $GuestCredential) { return $GuestCredential }
    $credential = Get-Credential -Message 'Enter a Windows guest administrator credential to use for this virtual machine batch.'
    if ($null -eq $credential) {
        throw 'Windows guest credentials are required. No changes were made.'
    }
    return $credential
}

function Invoke-WindowsGuestPowerShell {
    param(
        [Parameter(Mandatory)] [object]$VM,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)] [string]$ScriptText
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
    Write-Output ("Guest exception: " + $_.Exception.Message + [Environment]::NewLine + $_.InvocationInfo.PositionMessage)
    exit 1
}
'@
    $wrapper = $wrapper.Replace('__GUEST_SCRIPT_BODY__', $ScriptText)
    $result = Invoke-VMScript -VM $VM -GuestCredential $Credential -ScriptType Powershell -ScriptText $wrapper -ErrorAction Stop
    if ($result.ExitCode -ne 0) {
        $details = [string]$result.ScriptOutput
        if ([string]::IsNullOrWhiteSpace($details)) { $details = 'VMware Tools returned no guest error details.' }
        throw "The Windows guest script failed with exit code $($result.ExitCode): $($details.Trim())"
    }

    $output = [string]$result.ScriptOutput
    $beginMarker = '__VMWARE_GUEST_PAYLOAD_BEGIN__'
    $endMarker = '__VMWARE_GUEST_PAYLOAD_END__'
    $begin = $output.LastIndexOf($beginMarker, [System.StringComparison]::Ordinal)
    if ($begin -lt 0) {
        $display = $output.Trim()
        if ($display.Length -gt 2000) { $display = $display.Substring(0, 2000) + '...' }
        throw "The Windows guest returned an unframed result. Guest output: $display"
    }
    $payloadStart = $begin + $beginMarker.Length
    $end = $output.IndexOf($endMarker, $payloadStart, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { throw 'The Windows guest result was incomplete: the payload end marker was missing.' }
    return $output.Substring($payloadStart, $end - $payloadStart).Trim()
}

function Get-WindowsDriveState {
    param(
        [Parameter(Mandatory)] [object]$VM,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)] [string]$DriveLetter
    )

    $scriptText = @'
$ErrorActionPreference = 'Stop'
$driveLetter = '__DRIVE_LETTER__'
$recoveryGptType = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
Update-HostStorageCache
$partitions = @(Get-Partition -DriveLetter $driveLetter -ErrorAction Stop)
if ($partitions.Count -ne 1) { throw "Drive $driveLetter`: maps to $($partitions.Count) partitions; exactly one is required." }
$partition = $partitions[0]
if ($partition.Type -in @('Recovery', 'System', 'Reserved') -or $partition.GptType -eq $recoveryGptType) {
    throw "Drive $driveLetter`: is on a protected partition type and cannot be extended."
}
$disk = Get-Disk -Number $partition.DiskNumber
$supported = Get-PartitionSupportedSize -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber
$nextPartitions = @(Get-Partition -DiskNumber $partition.DiskNumber | Where-Object Offset -gt $partition.Offset | Sort-Object Offset | Select-Object -First 1)
$following = $null
if ($nextPartitions.Count -eq 1) {
    $next = $nextPartitions[0]
    $following = [pscustomobject]@{
        PartitionNumber = $next.PartitionNumber
        Type            = [string]$next.Type
        GptType         = [string]$next.GptType
        IsRecovery      = ($next.Type -eq 'Recovery' -or $next.GptType -eq $recoveryGptType)
        SizeGB          = [math]::Round($next.Size / 1GB, 2)
    }
}
[pscustomobject]@{
    DiskNumber       = $partition.DiskNumber
    PartitionNumber  = $partition.PartitionNumber
    PartitionSizeGB  = [math]::Round($partition.Size / 1GB, 2)
    WindowsDiskSizeGB = [math]::Round($disk.Size / 1GB, 2)
    SerialNumber     = [string]$disk.SerialNumber
    UniqueId         = [string]$disk.UniqueId
    MaximumSizeGB    = [math]::Round($supported.SizeMax / 1GB, 2)
    CanExtend        = (($supported.SizeMax - $partition.Size) -gt 1MB)
    FollowingPartition = $following
} | ConvertTo-Json -Depth 4 -Compress
'@
    $scriptText = $scriptText.Replace('__DRIVE_LETTER__', $DriveLetter)
    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    return $json | ConvertFrom-Json -ErrorAction Stop
}

function Resize-WindowsDrivePartition {
    param(
        [Parameter(Mandatory)] [object]$VM,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)] [string]$DriveLetter
    )

    $scriptText = @'
$ErrorActionPreference = 'Stop'
$driveLetter = '__DRIVE_LETTER__'
Update-HostStorageCache
$partition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
$supported = Get-PartitionSupportedSize -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber
if (($supported.SizeMax - $partition.Size) -le 1MB) { throw 'There is no contiguous unallocated space after the selected partition.' }
Resize-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -Size $supported.SizeMax
$updated = Get-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber
[pscustomobject]@{ NewSizeGB = [math]::Round($updated.Size / 1GB, 2) } | ConvertTo-Json -Compress
'@
    $scriptText = $scriptText.Replace('__DRIVE_LETTER__', $DriveLetter)
    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    return $json | ConvertFrom-Json -ErrorAction Stop
}

function Remove-AdjacentRecoveryPartition {
    param(
        [Parameter(Mandatory)] [object]$VM,
        [Parameter(Mandatory)] [System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory)] [string]$DriveLetter,
        [Parameter(Mandatory)] [int]$RecoveryPartitionNumber
    )

    $disableScript = @'
$ErrorActionPreference = 'Stop'
$driveLetter = '__DRIVE_LETTER__'
$recoveryPartitionNumber = __RECOVERY_PARTITION_NUMBER__
$recoveryGptType = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
$selected = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
$recovery = Get-Partition -DiskNumber $selected.DiskNumber -PartitionNumber $recoveryPartitionNumber -ErrorAction Stop
if ($recovery.Type -ne 'Recovery' -and $recovery.GptType -ne $recoveryGptType) { throw 'The blocking partition is no longer identified as Recovery.' }
$next = @(Get-Partition -DiskNumber $selected.DiskNumber | Where-Object Offset -gt $selected.Offset | Sort-Object Offset | Select-Object -First 1)
if ($next.Count -ne 1 -or $next[0].PartitionNumber -ne $recoveryPartitionNumber) { throw 'The Recovery partition is no longer immediately after the selected partition.' }
if ($null -eq (Get-Command reagentc.exe -ErrorAction SilentlyContinue)) { throw 'reagentc.exe is unavailable.' }
$reagentOutput = & $env:ComSpec /d /c 'reagentc.exe /disable 2>&1' | Out-String
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0 -and $reagentOutput -notmatch '(?i)Windows RE is already disabled') { throw "Unable to disable WinRE: $reagentOutput" }
[pscustomobject]@{ WinREDisabled = $true } | ConvertTo-Json -Compress
'@
    $disableScript = $disableScript.Replace('__DRIVE_LETTER__', $DriveLetter).Replace('__RECOVERY_PARTITION_NUMBER__', [string]$RecoveryPartitionNumber)
    $disableJson = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $disableScript
    $disableResult = $disableJson | ConvertFrom-Json -ErrorAction Stop
    if (-not [bool]$disableResult.WinREDisabled) { throw 'WinRE disable verification was not returned.' }

    $deleteScript = @'
$ErrorActionPreference = 'Stop'
$driveLetter = '__DRIVE_LETTER__'
$recoveryPartitionNumber = __RECOVERY_PARTITION_NUMBER__
$recoveryGptType = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
$selected = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
$diskNumber = $selected.DiskNumber
$recovery = Get-Partition -DiskNumber $diskNumber -PartitionNumber $recoveryPartitionNumber -ErrorAction Stop
if ($recovery.Type -ne 'Recovery' -and $recovery.GptType -ne $recoveryGptType) { throw 'The blocking partition is no longer identified as Recovery.' }
$next = @(Get-Partition -DiskNumber $diskNumber | Where-Object Offset -gt $selected.Offset | Sort-Object Offset | Select-Object -First 1)
if ($next.Count -ne 1 -or $next[0].PartitionNumber -ne $recoveryPartitionNumber) { throw 'The Recovery partition is no longer immediately after the selected partition.' }
$diskpartFile = Join-Path $env:TEMP ("Delete-Recovery-{0}.txt" -f [guid]::NewGuid().ToString('N'))
try {
    @"
select disk $diskNumber
select partition $recoveryPartitionNumber
delete partition override
"@ | Set-Content -LiteralPath $diskpartFile -Encoding Ascii -Force
    $command = 'diskpart.exe /s "{0}" 2>&1' -f $diskpartFile
    $output = & $env:ComSpec /d /c $command | Out-String
    if ($LASTEXITCODE -ne 0) { throw "DiskPart failed: $output" }
}
finally { Remove-Item -LiteralPath $diskpartFile -Force -ErrorAction SilentlyContinue }
Update-HostStorageCache
if ($null -ne (Get-Partition -DiskNumber $diskNumber -PartitionNumber $recoveryPartitionNumber -ErrorAction SilentlyContinue)) { throw 'Recovery partition still exists after DiskPart completed.' }
[pscustomobject]@{ RecoveryDeleted = $true } | ConvertTo-Json -Compress
'@
    $deleteScript = $deleteScript.Replace('__DRIVE_LETTER__', $DriveLetter).Replace('__RECOVERY_PARTITION_NUMBER__', [string]$RecoveryPartitionNumber)
    $deleteJson = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $deleteScript
    $deleteResult = $deleteJson | ConvertFrom-Json -ErrorAction Stop
    if (-not [bool]$deleteResult.RecoveryDeleted) { throw 'Recovery partition deletion verification was not returned.' }
}

function ConvertTo-NormalizedDiskIdentifier {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) { return '' }
    $normalized = ([string]$Value).ToUpperInvariant() -replace '[^0-9A-F]', ''
    if ($normalized.Length -lt 16) { return '' }
    return $normalized
}

function Get-HardDiskForWindowsDrive {
    param(
        [Parameter(Mandatory)] [object]$VM,
        [Parameter(Mandatory)] [object]$Server,
        [Parameter(Mandatory)] [string]$DriveLetter,
        [Parameter(Mandatory)] [object]$DriveState
    )

    if ($null -eq (Get-Command Get-VMGuestDisk -ErrorAction SilentlyContinue)) {
        throw 'Get-VMGuestDisk is unavailable. PowerCLI with this cmdlet and vCenter 7.0 or later is required.'
    }

    $hardDisks = @(Get-HardDisk -VM $VM -Server $Server -ErrorAction Stop)
    if ($hardDisks.Count -eq 0) { throw "VM '$($VM.Name)' has no virtual hard disks." }
    $targetPath = ("{0}:" -f $DriveLetter).ToUpperInvariant()

    # Preferred path: retrieve the Windows volume and use PowerCLI's documented
    # VMGuestDisk-to-HardDisk relationship to resolve its backing VMDK.
    $directMatches = @()
    try {
        $guestVolumes = @(Get-VMGuestDisk -VM $VM -DiskPath "$DriveLetter`:\" -Server $Server -ErrorAction Stop)
        foreach ($guestVolume in $guestVolumes) {
            $directMatches += @(Get-HardDisk -VMGuestDisk $guestVolume -ErrorAction Stop)
        }
    }
    catch {
        $directMatches = @()
    }
    $directMatches = @(
        $directMatches |
            Where-Object { $hardDisks.Filename -contains $_.Filename } |
            Sort-Object Filename -Unique
    )
    if ($directMatches.Count -eq 1) {
        return [pscustomobject]@{ HardDisk = $directMatches[0]; Method = 'PowerCLI guest-volume mapping' }
    }
    if ($directMatches.Count -gt 1) {
        throw "Windows drive $DriveLetter`: maps directly to $($directMatches.Count) virtual hard disks. Spanned volumes are not supported."
    }

    # Some vCenter environments populate only the reverse relationship.
    $reverseMatches = @()
    foreach ($hardDisk in $hardDisks) {
        $guestDisks = @(Get-VMGuestDisk -HardDisk $hardDisk -ErrorAction SilentlyContinue)
        $paths = @($guestDisks | ForEach-Object { ([string]$_.DiskPath).Trim().TrimEnd('\').ToUpperInvariant() })
        if ($paths -contains $targetPath) { $reverseMatches += $hardDisk }
    }
    if ($reverseMatches.Count -eq 1) {
        return [pscustomobject]@{ HardDisk = $reverseMatches[0]; Method = 'PowerCLI reverse mapping' }
    }
    if ($reverseMatches.Count -gt 1) {
        throw "Windows drive $DriveLetter`: maps in reverse to $($reverseMatches.Count) virtual hard disks. Spanned volumes are not supported."
    }

    # VMware virtual disk serials normally correspond to the VMDK backing UUID.
    # Only an exact and unique normalized identifier match is accepted.
    $guestIdentifiers = @(
        @($DriveState.SerialNumber, $DriveState.UniqueId) |
            ForEach-Object { ConvertTo-NormalizedDiskIdentifier -Value $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $identifierMatches = @(
        $hardDisks | Where-Object {
            $backingIdentifiers = @(
                @($_.ExtensionData.Backing.Uuid, $_.ExtensionData.Backing.LunUuid) |
                    ForEach-Object { ConvertTo-NormalizedDiskIdentifier -Value $_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            @($backingIdentifiers | Where-Object { $guestIdentifiers -contains $_ }).Count -gt 0
        }
    )
    if ($identifierMatches.Count -eq 1) {
        return [pscustomobject]@{ HardDisk = $identifierMatches[0]; Method = 'Guest serial/VMDK UUID' }
    }
    if ($identifierMatches.Count -gt 1) {
        throw "Windows drive $DriveLetter`: matched more than one VMDK by disk identifier. No disk was selected."
    }

    # Last fallback: use capacity only when exactly one VMDK has the same size.
    # Equal-sized disks remain ambiguous and are never guessed.
    [decimal]$windowsDiskSizeGB = $DriveState.WindowsDiskSizeGB
    $capacityMatches = @(
        $hardDisks | Where-Object {
            [math]::Abs([decimal]$_.CapacityGB - $windowsDiskSizeGB) -le [decimal]0.05
        }
    )
    if ($capacityMatches.Count -eq 1) {
        return [pscustomobject]@{ HardDisk = $capacityMatches[0]; Method = 'Unique disk-capacity match' }
    }
    if ($capacityMatches.Count -gt 1) {
        throw "Windows drive $DriveLetter`: is on a $windowsDiskSizeGB GB disk, but $($capacityMatches.Count) attached VMDKs have that capacity. Mapping is ambiguous and no disk was selected."
    }

    throw "Windows drive $DriveLetter`: could not be mapped to a virtual hard disk by PowerCLI guest mapping, disk UUID, or unique capacity."
}

function New-Result {
    param(
        [Parameter(Mandatory)] [object]$Item,
        [string]$HardDisk = '',
        [object]$VmdkBeforeGB = $null,
        [object]$VmdkAfterGB = $null,
        [object]$PartitionBeforeGB = $null,
        [object]$PartitionAfterGB = $null,
        [bool]$RecoveryDeleted = $false,
        [Parameter(Mandatory)] [string]$Outcome,
        [Parameter(Mandatory)] [string]$Message
    )

    [pscustomobject]@{
        VMName             = $Item.VMName
        DriveLetter        = "$($Item.DriveLetter):"
        TargetCapacityGB   = $Item.TargetCapacityGB
        HardDisk           = $HardDisk
        VmdkBeforeGB       = $VmdkBeforeGB
        VmdkAfterGB        = $VmdkAfterGB
        PartitionBeforeGB  = $PartitionBeforeGB
        PartitionAfterGB   = $PartitionAfterGB
        RecoveryDeleted    = $RecoveryDeleted
        Outcome            = $Outcome
        Message            = $Message
    }
}

try {
    Write-Host "`nMulti-VM Windows Disk Expansion - Version 1" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ''
    if ($AllowRecoveryPartitionDeletion) {
        Write-Warning 'Recovery partition deletion is enabled for this run. WinRE will be disabled and the Recovery partition will not be recreated.'
    }

    $server = Get-VCenterConnection
    Write-VCenterConnectionDetails -Server $server
    $requestedItems = @(Get-WorkItems)
    $allVMs = @(Get-VM -Server $server -ErrorAction Stop)
    $results = @()
    $items = @(
        foreach ($requestedItem in $requestedItems) {
            try {
                $pattern = [System.Management.Automation.WildcardPattern]::new(
                    [string]$requestedItem.VMName,
                    [System.Management.Automation.WildcardOptions]::IgnoreCase
                )
                $matchingVMs = @(
                    $allVMs |
                        Where-Object { $pattern.IsMatch([string]$_.Name) } |
                        Sort-Object Name
                )
                if ($matchingVMs.Count -eq 0) {
                    $results += New-Result -Item $requestedItem -Outcome 'PreflightFailed' -Message "VM name or pattern '$($requestedItem.VMName)' matched no VMs."
                    continue
                }

                foreach ($matchingVM in $matchingVMs) {
                    [pscustomobject]@{
                        VMName           = [string]$matchingVM.Name
                        DriveLetter      = $requestedItem.DriveLetter
                        TargetCapacityGB = $requestedItem.TargetCapacityGB
                    }
                }
            }
            catch {
                $results += New-Result -Item $requestedItem -Outcome 'PreflightFailed' -Message "VM wildcard pattern '$($requestedItem.VMName)' is invalid: $($_.Exception.Message)"
            }
        }
    )
    $duplicateTargets = @(
        $items |
            Group-Object { "$(([string]$_.VMName).ToUpperInvariant())|$($_.DriveLetter)" } |
            Where-Object Count -gt 1
    )
    if ($duplicateTargets.Count -gt 0) {
        throw 'The VM name patterns overlap and produce duplicate VMName and DriveLetter targets. Each VM drive may appear only once per run.'
    }

    Write-Host "`nResolved VM targets ($($items.Count)):" -ForegroundColor Cyan
    if ($items.Count -gt 0) {
        $items |
            Sort-Object VMName, DriveLetter |
            Select-Object VMName,
                @{ Name = 'Drive'; Expression = { "$($_.DriveLetter):" } },
                TargetCapacityGB |
            Format-Table -AutoSize |
            Out-Host
        Write-Host ''
        Write-Host 'These VMs will now enter preflight. No per-VM approval will be requested.' -ForegroundColor DarkGray
    }
    else {
        Write-Warning 'No VMs matched the supplied VM names or wildcard patterns.'
    }

    $guestCredentialToUse = if ($items.Count -gt 0) { Get-ResolvedGuestCredential } else { $null }
    $plans = @()

    Write-Host "`nPreflight: validating $($items.Count) VM target(s)..." -ForegroundColor Cyan
    foreach ($item in $items) {
        try {
            $vmMatches = @($allVMs | Where-Object { $_.Name -ieq $item.VMName })
            if ($vmMatches.Count -ne 1) {
                throw "Expected one exact VM match but found $($vmMatches.Count)."
            }
            $vm = $vmMatches[0]
            if ([string]$vm.PowerState -ne 'PoweredOn') { throw "VM is $($vm.PowerState); it must be powered on." }
            if ([string]$vm.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') { throw 'VMware Tools is not running.' }
            $guestFamily = [string]$vm.ExtensionData.Guest.GuestFamily
            if (-not [string]::IsNullOrWhiteSpace($guestFamily) -and $guestFamily -ne 'windowsGuest') {
                throw "Guest family '$guestFamily' is not Windows."
            }

            $driveState = Get-WindowsDriveState -VM $vm -Credential $guestCredentialToUse -DriveLetter $item.DriveLetter
            $diskMapping = Get-HardDiskForWindowsDrive -VM $vm -Server $server -DriveLetter $item.DriveLetter -DriveState $driveState
            $hardDisk = $diskMapping.HardDisk
            if ([decimal]$hardDisk.CapacityGB -gt [decimal]$item.TargetCapacityGB) {
                $message = "Current VMDK capacity $($hardDisk.CapacityGB) GB is greater than the requested $($item.TargetCapacityGB) GB target. The VMDK and Windows partition were not changed."
                $results += New-Result -Item $item -HardDisk $hardDisk.Name -VmdkBeforeGB $hardDisk.CapacityGB -VmdkAfterGB $hardDisk.CapacityGB -PartitionBeforeGB $driveState.PartitionSizeGB -PartitionAfterGB $driveState.PartitionSizeGB -Outcome 'Skipped-TargetBelowCurrent' -Message $message
                Write-Warning "[$($item.VMName)] $message"
                continue
            }
            $needsVmdkExpansion = ([decimal]$hardDisk.CapacityGB -lt [decimal]$item.TargetCapacityGB)
            if ($needsVmdkExpansion -and @(Get-Snapshot -VM $vm -Server $server -ErrorAction Stop).Count -gt 0) {
                throw 'The VM has one or more snapshots; VMDK expansion was not attempted.'
            }

            $plans += [pscustomobject]@{
                Item               = $item
                VM                 = $vm
                HardDisk           = $hardDisk
                MappingMethod      = $diskMapping.Method
                DriveState         = $driveState
                NeedsVmdkExpansion = $needsVmdkExpansion
            }
        }
        catch {
            $results += New-Result -Item $item -Outcome 'PreflightFailed' -Message $_.Exception.Message
        }
    }

    $planDisplay = @($plans | ForEach-Object {
            [pscustomobject]@{
                VMName            = $_.Item.VMName
                Drive             = "$($_.Item.DriveLetter):"
                HardDisk          = $_.HardDisk.Name
                Mapping           = $_.MappingMethod
                CurrentVmdkGB     = $_.HardDisk.CapacityGB
                TargetVmdkGB      = $_.Item.TargetCapacityGB
                VmdkAction        = if ($_.NeedsVmdkExpansion) { 'Expand' } else { 'No resize' }
                PartitionSizeGB   = $_.DriveState.PartitionSizeGB
                FollowingPartition = if ($null -ne $_.DriveState.FollowingPartition) { "#$($_.DriveState.FollowingPartition.PartitionNumber) $($_.DriveState.FollowingPartition.Type)" } else { '(none)' }
            }
        })
    if ($planDisplay.Count -gt 0) {
        Write-Host "`nExecution plan (no per-VM approval will be requested):" -ForegroundColor Cyan
        $planDisplay | Format-Table -AutoSize -Wrap | Out-Host
    }

    foreach ($plan in $plans) {
        $item = $plan.Item
        $vm = $plan.VM
        $hardDisk = $plan.HardDisk
        [decimal]$vmdkBefore = $hardDisk.CapacityGB
        [decimal]$vmdkAfter = $vmdkBefore
        [decimal]$partitionBefore = $plan.DriveState.PartitionSizeGB
        [decimal]$partitionAfter = $partitionBefore
        $recoveryDeleted = $false
        $vmdkChanged = $false

        Write-Host "`n[$($item.VMName)] Processing drive $($item.DriveLetter):..." -ForegroundColor Cyan
        try {
            if ($plan.NeedsVmdkExpansion) {
                Set-HardDisk -HardDisk $hardDisk -CapacityGB $item.TargetCapacityGB -Confirm:$false -ErrorAction Stop | Out-Null
                $vmdkChanged = $true
                $verifiedDisk = Get-HardDisk -VM $vm -Server $server -ErrorAction Stop | Where-Object { $_.Filename -ieq $hardDisk.Filename } | Select-Object -First 1
                if ($null -eq $verifiedDisk) { throw 'The resized VMDK could not be re-resolved for verification.' }
                $vmdkAfter = [decimal]$verifiedDisk.CapacityGB
                if ($vmdkAfter -lt [decimal]$item.TargetCapacityGB) { throw "VMDK verification returned $vmdkAfter GB instead of at least $($item.TargetCapacityGB) GB." }
                Write-Host "  VMDK expanded: $vmdkBefore GB -> $vmdkAfter GB" -ForegroundColor Green
            }
            else {
                Write-Host "  VMDK is already $vmdkBefore GB; no reduction or resize was performed." -ForegroundColor DarkGray
            }

            $state = Get-WindowsDriveState -VM $vm -Credential $guestCredentialToUse -DriveLetter $item.DriveLetter
            $blocking = $state.FollowingPartition
            if ($null -ne $blocking -and [bool]$blocking.IsRecovery) {
                if (-not $AllowRecoveryPartitionDeletion) {
                    $message = "Recovery partition $($blocking.PartitionNumber) blocks use of the newly added disk space. Rerun with -AllowRecoveryPartitionDeletion to authorize its permanent deletion."
                    $outcome = if ($vmdkChanged) { 'Partial-VmdkExpanded' } else { 'Skipped' }
                    $results += New-Result -Item $item -HardDisk $hardDisk.Name -VmdkBeforeGB $vmdkBefore -VmdkAfterGB $vmdkAfter -PartitionBeforeGB $partitionBefore -PartitionAfterGB $partitionAfter -Outcome $outcome -Message $message
                    Write-Warning "[$($item.VMName)] $message"
                    continue
                }
                Remove-AdjacentRecoveryPartition -VM $vm -Credential $guestCredentialToUse -DriveLetter $item.DriveLetter -RecoveryPartitionNumber ([int]$blocking.PartitionNumber)
                $recoveryDeleted = $true
                Write-Warning "[$($item.VMName)] Recovery partition $($blocking.PartitionNumber) was deleted and WinRE is disabled."
                $state = Get-WindowsDriveState -VM $vm -Credential $guestCredentialToUse -DriveLetter $item.DriveLetter
                $blocking = $state.FollowingPartition
            }

            if ($null -ne $blocking) {
                $message = "Partition $($blocking.PartitionNumber) ($($blocking.Type)) blocks use of the newly added disk space and was not deleted."
                $outcome = if ($vmdkChanged -or $recoveryDeleted) { 'Partial-VmdkExpanded' } else { 'Skipped' }
                $results += New-Result -Item $item -HardDisk $hardDisk.Name -VmdkBeforeGB $vmdkBefore -VmdkAfterGB $vmdkAfter -PartitionBeforeGB $partitionBefore -PartitionAfterGB $partitionAfter -RecoveryDeleted $recoveryDeleted -Outcome $outcome -Message $message
                Write-Warning "[$($item.VMName)] $message"
                continue
            }

            if ([bool]$state.CanExtend) {
                $resizeResult = Resize-WindowsDrivePartition -VM $vm -Credential $guestCredentialToUse -DriveLetter $item.DriveLetter
                $partitionAfter = [decimal]$resizeResult.NewSizeGB
                $verifiedState = Get-WindowsDriveState -VM $vm -Credential $guestCredentialToUse -DriveLetter $item.DriveLetter
                $partitionAfter = [decimal]$verifiedState.PartitionSizeGB
                Write-Host "  Windows partition extended: $partitionBefore GB -> $partitionAfter GB" -ForegroundColor Green
                $results += New-Result -Item $item -HardDisk $hardDisk.Name -VmdkBeforeGB $vmdkBefore -VmdkAfterGB $vmdkAfter -PartitionBeforeGB $partitionBefore -PartitionAfterGB $partitionAfter -RecoveryDeleted $recoveryDeleted -Outcome 'Completed' -Message 'VMDK target and Windows partition processing completed.'
            }
            else {
                $message = 'No contiguous unallocated space was available after the selected partition.'
                $outcome = if ($vmdkChanged) { 'Partial-VmdkExpanded' } else { 'NoChange' }
                $results += New-Result -Item $item -HardDisk $hardDisk.Name -VmdkBeforeGB $vmdkBefore -VmdkAfterGB $vmdkAfter -PartitionBeforeGB $partitionBefore -PartitionAfterGB $partitionAfter -RecoveryDeleted $recoveryDeleted -Outcome $outcome -Message $message
            }
        }
        catch {
            $outcome = if ($vmdkChanged -or $recoveryDeleted) { 'Partial-Failed' } else { 'Failed' }
            $results += New-Result -Item $item -HardDisk $hardDisk.Name -VmdkBeforeGB $vmdkBefore -VmdkAfterGB $vmdkAfter -PartitionBeforeGB $partitionBefore -PartitionAfterGB $partitionAfter -RecoveryDeleted $recoveryDeleted -Outcome $outcome -Message $_.Exception.Message
            Write-Warning "[$($item.VMName)] Failed: $($_.Exception.Message)"
        }
    }

    $results = @($results | Sort-Object VMName, DriveLetter)
    Write-Host "`nBatch results:" -ForegroundColor Cyan
    $results | Format-Table VMName, DriveLetter, TargetCapacityGB, HardDisk, VmdkBeforeGB, VmdkAfterGB, PartitionBeforeGB, PartitionAfterGB, RecoveryDeleted, Outcome, Message -AutoSize -Wrap | Out-Host

    if (-not [string]::IsNullOrWhiteSpace($CsvReportPath)) {
        Write-Host ''
        $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CsvReportPath)
        $folder = Split-Path -Parent $resolvedPath
        if (-not [string]::IsNullOrWhiteSpace($folder) -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
            throw "CSV report folder '$folder' does not exist."
        }
        $results | Export-Csv -LiteralPath $resolvedPath -NoTypeInformation -Encoding UTF8
        Write-Host "Results exported to '$resolvedPath'." -ForegroundColor Green
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
