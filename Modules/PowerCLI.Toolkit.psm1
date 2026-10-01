#requires -Version 5.1
# Shared helpers; importing this module never connects to vCenter or changes a VM.
$script:ToolkitVersion = '1.1.0'
$script:GuestCredentials = @{}
$script:GuestReady = @{}

function Get-ToolkitVersion { return $script:ToolkitVersion }

function Write-ToolkitDetails {
    param([System.Collections.IDictionary]$Details, [int]$Indent = 2, [hashtable]$Colors = @{})
    if ($null -eq $Details -or $Details.Count -eq 0) { return }
    if ($null -eq $Colors) { $Colors = @{} }
    $width = ($Details.Keys | ForEach-Object { ([string]$_).Length } | Measure-Object -Maximum).Maximum
    foreach ($key in $Details.Keys) {
        $line = (' ' * $Indent) + ([string]$key).PadRight($width) + ' : ' + $Details[$key]
        if ($Colors.ContainsKey($key)) { Write-Host $line -ForegroundColor $Colors[$key] }
        else { Write-Host $line }
    }
}

function Connect-ToolkitVCenter {
    param([string]$Name, [pscredential]$Credential)
    $connections = @(@($global:DefaultVIServers) + @($global:DefaultVIServer) |
        Where-Object { $null -ne $_ -and $_.IsConnected } | Sort-Object Name -Unique)
    if ($Name) {
        $selected = @($connections | Where-Object { $_.Name -ieq $Name })
        if ($selected.Count -eq 1) { return $selected[0] }
    }
    elseif ($connections.Count -eq 1) { return $connections[0] }
    elseif ($connections.Count -gt 1) {
        while ($true) {
            Write-Host 'Select a vCenter connection:' -ForegroundColor Cyan
            for ($i = 0; $i -lt $connections.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $connections[$i].Name) }
            $answer = ([string](Read-Host "Select a connection (1-$($connections.Count), or 'exit' to cancel)")).Trim()
            if ($answer -ieq 'exit') { throw [OperationCanceledException]::new('Cancelled.') }
            $number = 0
            if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $connections.Count) {
                return $connections[$number - 1]
            }
            Write-Warning 'Select one of the listed connections.'
        }
    }
    while ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = ([string](Read-Host "Enter the vCenter Server host name (enter 'exit' to cancel)")).Trim()
        if ($Name -ieq 'exit') { throw [OperationCanceledException]::new('Cancelled.') }
    }
    if ($null -eq $Credential) {
        $Credential = Get-Credential -Message "Enter credentials for vCenter '$Name'. Select Cancel to stop."
        if ($null -eq $Credential) { throw [OperationCanceledException]::new('Cancelled.') }
    }
    return Connect-VIServer -Server $Name -Credential $Credential -ErrorAction Stop
}

function Read-ToolkitGuestCredential {
    param([string]$UserName)
    while ($true) {
        $UserName = ([string](Read-Host "Enter the Windows guest administrator user name (enter 'exit' to cancel)")).Trim()
        if ($UserName -ieq 'exit') { throw [OperationCanceledException]::new('Guest operation cancelled.') }
        if (-not $UserName) { Write-Warning 'Enter a username.'; continue }
        $credential = Get-Credential -UserName $UserName -Message 'Enter the Windows guest administrator password. Select Cancel to stop.'
        if ($null -eq $credential) { throw [OperationCanceledException]::new('Guest operation cancelled.') }
        if ($credential.Password.Length -gt 0) { return $credential }
        Write-Warning 'The Windows guest password cannot be empty. Enter the credentials again.'
    }
}

function Invoke-ToolkitGuestCommand {
    param([object]$VM, [pscredential]$Credential, [string]$ScriptText, [object]$Server, [switch]$ReadOnly, [switch]$Preview)
    if (($Preview -or $WhatIfPreference) -and -not $ReadOnly) { throw 'Preview mode blocked a guest change.' }
    # Cache replacements only in memory, per vCenter, VM and original account.
    $key = '{0}|{1}|{2}' -f $Server.Name, $VM.Id, $Credential.UserName
    if ($script:GuestCredentials.ContainsKey($key)) { $Credential = $script:GuestCredentials[$key] }
    while ($true) {
        if ($null -eq $Credential -or $Credential.Password.Length -eq 0) {
            Write-Warning 'The Windows guest password cannot be empty. Enter the credentials again.'
            $Credential = Read-ToolkitGuestCredential
        }
        try {
            $arguments = @{ VM=$VM; GuestCredential=$Credential; ScriptType='Powershell'; ErrorAction='Stop'; Confirm=$false; WhatIf=$false }
            if ($null -ne $Server) { $arguments.Server = $Server }
            $ProgressPreference = 'SilentlyContinue'
            if (-not $script:GuestReady.ContainsKey($key)) {
                # This command has no guest side effects. Authentication and Tools
                # execution must work before the caller's command is attempted.
                $probe = Invoke-VMScript @arguments -ScriptText "Write-Output 'POWERCLI_GUEST_READY'"
                if ($probe.ExitCode -ne 0 -or $probe.ScriptOutput -notmatch 'POWERCLI_GUEST_READY') {
                    throw 'The Windows guest readiness check failed. Verify VMware Tools and guest permissions.'
                }
                $script:GuestReady[$key] = $true
            }
            $result = Invoke-VMScript @arguments -ScriptText $ScriptText
            $script:GuestCredentials[$key] = $Credential
            return $result
        }
        catch {
            $details = $_.Exception.ToString() + ' ' + $_.FullyQualifiedErrorId
            $script:GuestReady.Remove($key)
            if ($details -match '(?i)InvalidGuestLogin|Failed to authenticate with the guest operating system|vix error codes\s*=\s*\(\s*3033\s*,\s*0\s*\)') {
                Write-Warning 'Windows guest authentication failed. Enter the username and a non-empty password again.'
                $Credential = Read-ToolkitGuestCredential
                continue
            }
            if ($details -match '(?i)vix error codes\s*=\s*\(\s*1\s*,\s*0\s*\)') {
                throw [InvalidOperationException]::new(
                    "VMware Tools could not complete the guest operation on '$($VM.Name)'." +
                    [Environment]::NewLine + 'Restart the VMware Tools service inside the VM and try again.' +
                    [Environment]::NewLine + 'If the issue persists, reboot the VM and retry.' +
                    [Environment]::NewLine + "Error details: $($_.Exception.Message)", $_.Exception)
            }
            # Never replay an unknown failure: the guest may have changed already.
            throw
        }
    }
}

function Invoke-ToolkitGuestPowerShell {
    param([object]$VM, [pscredential]$Credential, [string]$ScriptText, [object]$Server, [switch]$ReadOnly, [switch]$Preview)
    $marker = 'POWERCLI_' + [guid]::NewGuid().ToString('N')
    $wrapper = @'
try {
    $guestResults = @(& {
__BODY__
    })
    if ($guestResults.Count -eq 0) { throw 'Guest operation returned no result payload.' }
    Write-Output '__MARKER___BEGIN'
    Write-Output ([string]$guestResults[-1]).Trim()
    Write-Output '__MARKER___END'
}
catch {
    Write-Output ("Guest exception: " + $_.Exception.Message + [Environment]::NewLine + $_.InvocationInfo.PositionMessage)
    exit 1
}
'@
    $wrapper = $wrapper.Replace('__MARKER__', $marker).Replace('__BODY__', $ScriptText)
    $result = Invoke-ToolkitGuestCommand -VM $VM -Credential $Credential -ScriptText $wrapper -Server $Server -ReadOnly:$ReadOnly -Preview:$Preview
    if ($result.ExitCode -ne 0) {
        $details = ([string]$result.ScriptOutput).Trim()
        if (-not $details) { $details = 'VMware Tools returned no guest error details.' }
        throw "The Windows guest script failed with exit code $($result.ExitCode): $details"
    }
    $raw = [string]$result.ScriptOutput
    $begin = $raw.LastIndexOf($marker + '_BEGIN', [StringComparison]::Ordinal)
    if ($begin -lt 0) { throw 'The Windows guest returned an unframed result.' }
    $begin += ($marker + '_BEGIN').Length
    $end = $raw.IndexOf($marker + '_END', $begin, [StringComparison]::Ordinal)
    if ($end -lt 0) { throw 'The Windows guest result was incomplete.' }
    return $raw.Substring($begin, $end - $begin).Trim()
}

function Write-ToolkitCsvRecord {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Record)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    # Avoid Excel formula execution when operators open a report.
    $safe = [ordered]@{}
    foreach ($property in $Record.PSObject.Properties) {
        $value = $property.Value
        if ($value -is [string] -and $value -match '^[\s]*[=+@-]') { $value = "'" + $value }
        $safe[$property.Name] = $value
    }
    $lines = @([pscustomobject]$safe | ConvertTo-Csv -NoTypeInformation)
    $stream = $null
    for ($attempt=0; $attempt -lt 20; $attempt++) {
        try { $stream = [IO.File]::Open($fullPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read); break }
        catch [IO.IOException] { if ($attempt -eq 19) { throw }; Start-Sleep -Milliseconds 100 }
    }
    try {
        $encoding = [Text.UTF8Encoding]::new($false)
        if ($stream.Length -gt 0) {
            $reader = [IO.StreamReader]::new($stream, $encoding, $true, 1024, $true)
            try { $header = $reader.ReadLine() } finally { $reader.Dispose() }
            if ($header -cne $lines[0]) { throw "CSV schema mismatch in '$fullPath'. Use a new log file." }
            [void]$stream.Seek(0, [IO.SeekOrigin]::End)
            $text = ($lines | Select-Object -Skip 1) -join [Environment]::NewLine
        }
        else { $text = $lines -join [Environment]::NewLine }
        $bytes = $encoding.GetBytes($text + [Environment]::NewLine)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Export-ToolkitReport {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object[]]$Rows)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (Test-Path -LiteralPath $fullPath) { throw "Report '$fullPath' already exists. Choose a new filename." }
    $safeRows = foreach ($row in $Rows) {
        $safe = [ordered]@{}
        foreach ($property in $row.PSObject.Properties) {
            $value = $property.Value
            if ($value -is [string] -and $value -match '^[\s]*[=+@-]') { $value = "'" + $value }
            $safe[$property.Name] = $value
        }
        [pscustomobject]$safe
    }
    $safeRows | Export-Csv -LiteralPath $fullPath -NoTypeInformation -Encoding UTF8 -NoClobber -ErrorAction Stop
    Write-Host "Results exported to '$fullPath'." -ForegroundColor Green
}

function New-ToolkitDiskRecord {
    param([object]$VM, [object]$Server, [object]$Disk, [string]$Operation,
        [decimal]$OldCapacityGB, [decimal]$RequestedCapacityGB, [string]$ScriptName,
        [string]$VMDKPath, [string]$DiskName)
    $cluster = ''
    try { $cluster = (@(Get-Cluster -VM $VM -Server $Server -ErrorAction Stop).Name -join '; ') } catch { }
    if ($null -ne $Disk) { $VMDKPath = $Disk.Filename; $DiskName = $Disk.Name }
    $datastore = if ($VMDKPath -match '^\[([^\]]+)\]') { $Matches[1] } else { '' }
    return [pscustomobject][ordered]@{
        OperationId = [guid]::NewGuid().ToString()
        StartedUTC = [datetime]::UtcNow.ToString('o')
        CompletedUTC = ''
        VCenter = [string]$Server.Name
        VCenterUser = [string]$Server.User
        Operator = [Environment]::UserDomainName + '\' + [Environment]::UserName
        VMName = [string]$VM.Name
        VMInstanceUUID = [string]$VM.ExtensionData.Config.InstanceUuid
        VMId = [string]$VM.Id
        Cluster = $cluster
        Operation = $Operation
        HardDisk = $DiskName
        VMDKPath = $VMDKPath
        Datastore = $datastore
        OldCapacityGB = $OldCapacityGB
        RequestedIncreaseGB = $RequestedCapacityGB - $OldCapacityGB
        RequestedCapacityGB = $RequestedCapacityGB
        VerifiedCapacityGB = ''
        Result = 'Started'
        ErrorMessage = ''
        ScriptName = $ScriptName
        ScriptVersion = $script:ToolkitVersion
    }
}

function Complete-ToolkitDiskRecord {
    param([string]$Path, [object]$Record, [string]$Result, [object]$VerifiedCapacityGB, [string]$ErrorMessage)
    $Record.CompletedUTC = [datetime]::UtcNow.ToString('o')
    $Record.Result = $Result
    $Record.VerifiedCapacityGB = $VerifiedCapacityGB
    $Record.ErrorMessage = $ErrorMessage
    try { Write-ToolkitCsvRecord -Path $Path -Record $Record }
    catch {
        # A logging failure cannot undo a completed operation or justify retrying it.
        throw "Disk operation outcome: $Result. Could not record the final result in '$Path'. Verify the VM before retrying. Log error: $($_.Exception.Message)"
    }
}

function Show-ToolkitDiskHistory {
    param([object]$VM, [object]$Server, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { Write-Host '[i] No disk changes recorded by these scripts.' -ForegroundColor Gray; return }
    try {
        $uuid = [string]$VM.ExtensionData.Config.InstanceUuid
        $history = @(Import-Csv -LiteralPath $Path -ErrorAction Stop | Where-Object {
            $_.VCenter -ieq $Server.Name -and
            (($uuid -and $_.VMInstanceUUID -eq $uuid) -or (-not $uuid -and $_.VMId -eq $VM.Id))
        })
        $last = $history | Where-Object Result -eq 'Success' | Sort-Object CompletedUTC -Descending | Select-Object -First 1
        if ($null -ne $last) {
            Write-Host 'Last change recorded by these scripts:' -ForegroundColor Cyan
            Write-ToolkitDetails -Details ([ordered]@{
                'Date (UTC)'=$last.CompletedUTC; 'Disk'=$last.HardDisk
                'Change'="$($last.Operation): $($last.OldCapacityGB) GB -> $($last.VerifiedCapacityGB) GB"
                'Performed by'=$last.VCenterUser
            })
        }
        else { Write-Host '[i] No successful disk changes recorded by these scripts.' -ForegroundColor Gray }
        $latest = $history | Select-Object -Last 1
        if ($null -ne $latest -and $latest.Result -ne 'Success') {
            Write-Warning "Latest recorded attempt: $($latest.Result), operation $($latest.OperationId). Verify current state before making another change."
        }
    }
    catch { Write-Warning "Disk history is unavailable: $($_.Exception.Message)" }
}

function Show-ToolkitDatastoreCapacity {
    param([object]$Datastore, [decimal]$AdditionalGB,
        [ValidateRange(0,100)][decimal]$MinimumFreePercent=10,
        [ValidateRange(0,1000000000)][decimal]$MinimumFreeGB=50,
        [ValidateRange(0,1000000)][decimal]$MaximumProvisionedPercent=150,
        [string]$StorageFormat='Thin')
    if ($null -eq $Datastore -or $Datastore.CapacityGB -le 0) { throw 'Datastore capacity could not be assessed.' }
    $free = [decimal]$Datastore.FreeSpaceGB
    $total = [decimal]$Datastore.CapacityGB
    $reportedUncommitted = $Datastore.ExtensionData.Summary.Uncommitted
    $provisioned = if ($null -ne $reportedUncommitted) {
        $total - $free + ([decimal]$reportedUncommitted / 1GB)
    } else { $null }
    $freePercent = [math]::Round(100 * $free / $total, 2)
    $projectedPercent = if ($null -ne $provisioned) {
        [math]::Round(100 * ($provisioned + $AdditionalGB) / $total, 2)
    } else { 'Unavailable' }
    Write-ToolkitDetails -Details ([ordered]@{
        'Datastore'=$Datastore.Name; 'Free GB'=[math]::Round($free,2)
        'Free percent'=$freePercent; 'Projected provisioned percent'=$projectedPercent
    })
    if ($free -lt $MinimumFreeGB -or $freePercent -lt $MinimumFreePercent) {
        Write-Warning "Datastore free space is below the configured threshold ($MinimumFreeGB GB / $MinimumFreePercent%)."
    }
    if ($null -eq $provisioned) {
        Write-Warning 'Uncommitted datastore space was not reported; the provisioning threshold cannot be evaluated.'
    }
    elseif ($projectedPercent -gt $MaximumProvisionedPercent) {
        Write-Warning "Projected provisioning exceeds the configured $MaximumProvisionedPercent% threshold."
    }
    if ($StorageFormat -eq 'Thin') {
        Write-Host '[i] Thin capacity is potential growth, not immediate physical allocation.' -ForegroundColor Gray
        if ($AdditionalGB -gt $free) { Write-Warning 'The requested virtual capacity exceeds current datastore free space.' }
    }
    elseif ($StorageFormat -in @('Thick','EagerZeroedThick')) {
        if ($AdditionalGB -gt $free) { throw 'Insufficient reported datastore free space for this thick-provisioned change.' }
    }
    else {
        Write-Host '[i] Storage format follows the existing backing/template; virtual capacity is not a measurement of allocated space.' -ForegroundColor Gray
        if ($AdditionalGB -gt $free) { Write-Warning 'The requested capacity exceeds free space; sufficient physical capacity is not assured.' }
    }
}

function Expand-ToolkitDisk {
    param([object]$VM, [object]$Server, [object]$Disk, [decimal]$TargetGB,
        [string]$LogPath, [string]$ScriptName)
    $freshVM = Get-VM -Id $VM.Id -Server $Server -ErrorAction Stop
    $fresh = @(Get-HardDisk -VM $freshVM -Server $Server -ErrorAction Stop | Where-Object { $_.Id -eq $Disk.Id })
    if ($fresh.Count -ne 1) { throw 'The selected virtual disk is no longer uniquely available.' }
    if ($fresh[0].Filename -ine $Disk.Filename) { throw 'The selected disk backing changed after planning. Review the disk again.' }
    if ([decimal]$fresh[0].CapacityGB -ne [decimal]$Disk.CapacityGB) { throw 'Disk capacity changed after the plan was displayed. Run again to review current state.' }
    if ($TargetGB -le [decimal]$fresh[0].CapacityGB) { throw 'The target capacity must exceed current capacity.' }
    if (@(Get-Snapshot -VM $freshVM -Server $Server -ErrorAction Stop).Count -gt 0) { throw 'Remove VM snapshots before expanding this disk.' }
    $record = New-ToolkitDiskRecord -VM $freshVM -Server $Server -Disk $fresh[0] -Operation 'ExpandVirtualDisk' -OldCapacityGB $fresh[0].CapacityGB -RequestedCapacityGB $TargetGB -ScriptName $ScriptName
    Write-ToolkitCsvRecord -Path $LogPath -Record $record
    $verified = $null
    try {
        Set-HardDisk -HardDisk $fresh[0] -CapacityGB $TargetGB -Server $Server -Confirm:$false -ErrorAction Stop | Out-Null
        $verified = @(Get-HardDisk -VM $freshVM -Server $Server -ErrorAction Stop | Where-Object { $_.Id -eq $Disk.Id })
        if ($verified.Count -ne 1 -or [math]::Abs([decimal]$verified[0].CapacityGB - $TargetGB) -gt (1 / 1MB)) {
            throw 'Disk resize returned but the requested capacity could not be verified. Guest changes were stopped.'
        }
    }
    catch {
        $failure = $_
        $actual = $null
        try {
            $current = @(Get-HardDisk -VM $freshVM -Server $Server -ErrorAction Stop | Where-Object { $_.Id -eq $Disk.Id })
            if ($current.Count -eq 1) { $actual = $current[0].CapacityGB }
        } catch { }
        $outcome = if ($null -ne $actual -and [decimal]$actual -eq [decimal]$record.OldCapacityGB) { 'Failed' } else { 'Unverified' }
        Complete-ToolkitDiskRecord -Path $LogPath -Record $record -Result $outcome -VerifiedCapacityGB $actual -ErrorMessage $failure.Exception.Message
        throw $failure
    }
    Complete-ToolkitDiskRecord -Path $LogPath -Record $record -Result 'Success' -VerifiedCapacityGB $verified[0].CapacityGB
    return $verified[0]
}

function Set-ToolkitAssignmentIdentity {
    param([object]$VM, [object]$Server, [string]$Account, [string]$SID, [switch]$Additional)
    $values = [ordered]@{}
    if ($Additional) {
        $existing = @(Get-Annotation -Entity $VM -Server $Server -ErrorAction Stop | Where-Object Name -eq 'VDI.AdditionalUsers')
        $users = @()
        if ($existing.Count -eq 1 -and $existing[0].Value) {
            $decoded = $existing[0].Value | ConvertFrom-Json -ErrorAction Stop
            $users = @($decoded)
        }
        $users = @($users | Where-Object { $_.SID -ne $SID })
        $users += [pscustomobject]@{Account=$Account;SID=$SID}
        $values['VDI.AdditionalUsers'] = ConvertTo-Json -InputObject @($users) -Compress
    }
    else {
        # Account first, SID last: SID is the authoritative assignment marker.
        $values['VDI.AssignedADAccount'] = $Account
        $values['VDI.AssignedADSID'] = $SID
    }
    foreach ($name in $values.Keys) {
        $attribute = @(Get-CustomAttribute -Server $Server -ErrorAction Stop | Where-Object { $_.Name -ceq $name -and $_.TargetType -eq 'VirtualMachine' })
        if ($attribute.Count -eq 0) { $attribute = @(New-CustomAttribute -Name $name -TargetType VirtualMachine -Server $Server -Confirm:$false -ErrorAction Stop) }
        if ($attribute.Count -ne 1) { throw "Custom attribute '$name' is ambiguous." }
        Set-Annotation -Entity $VM -CustomAttribute $attribute[0] -Value $values[$name] -Server $Server -Confirm:$false -ErrorAction Stop | Out-Null
        $check = @(Get-Annotation -Entity $VM -CustomAttribute $attribute[0] -Server $Server -ErrorAction Stop)
        if ($check.Count -ne 1 -or $check[0].Value -cne $values[$name]) { throw "Could not verify assignment attribute '$name'." }
    }
}

function Get-ToolkitDuplicateAssignments {
    param([object[]]$VMs, [object]$Server, [string]$SID, [string]$FullName)
    $pattern = '^.+\s+-\s+(?:Consultant\s+)?' + [regex]::Escape($FullName) + '$'
    foreach ($vm in $VMs) {
        $annotations = @(Get-Annotation -Entity $vm -Server $Server -ErrorAction Stop)
        $primary = @($annotations | Where-Object Name -eq 'VDI.AssignedADSID')
        $extra = @($annotations | Where-Object Name -eq 'VDI.AdditionalUsers')
        $isMatch = $false
        if ($primary.Count -eq 1 -and $primary[0].Value) { $isMatch = $primary[0].Value -eq $SID }
        else { $isMatch = $vm.Name -match $pattern }
        if ($extra.Count -eq 1 -and $extra[0].Value) {
            $decoded = $extra[0].Value | ConvertFrom-Json -ErrorAction Stop
            $members = @($decoded)
            if (@($members | Where-Object SID -eq $SID).Count -gt 0) { $isMatch = $true }
        }
        if ($isMatch) { $vm }
    }
}

Export-ModuleMember -Function *-Toolkit*
