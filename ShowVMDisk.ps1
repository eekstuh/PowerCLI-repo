#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core
<#
.SYNOPSIS
Lists Windows guest disks and partitions through VMware Tools.

.DESCRIPTION
Selects a VM and prompts for Windows administrator credentials. Displays the
same online-disk and partition columns as Expand-VSphereVmDisk-v3.ps1.
Disks without partitions appear as 'No partitions'; offline disks are excluded.

Reuses a single active vCenter connection or prompts for a server. Refreshes
the guest storage inventory but does not resize, initialize, or delete disks
or partitions. Empty passwords and recognized authentication failures prompt
for credentials again. Enter 'exit' at text prompts or cancel the credential
dialog to stop.

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
            Write-Host '[i] Fetching Windows guest disks and partition information.' -ForegroundColor Gray
            $partitions = @(Get-WindowsGuestPartitions -VM $vm -Credential $GuestCredential)
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
    Write-Host "Windows guest disks and partitions on '$($vm.Name)':" -ForegroundColor Cyan
    if ($partitions.Count -eq 0) {
        Write-Host 'No online Windows disks were found.'
    }
    else {
        $partitions | Sort-Object DiskNumber, PartitionNumber |
            Select-Object @{Name='DiskNum';Expression={$_.DiskNumber}},
                @{Name='PartitionNum';Expression={$_.PartitionNumber}},
                DriveLetter, Label,
                @{Name='PartitionSizeGB';Expression={$_.SizeGB}},
                @{Name='DiskSpaceFreeGB';Expression={$_.AvailableSpaceGB}},
                DiskSizeGB, Type, IsRecovery |
            Format-Table -AutoSize
    }
}
catch [System.OperationCanceledException] {
    Write-Host 'Cancelled. No disk or partition changes were made.' -ForegroundColor Yellow
}
catch {
    Write-Error $_.Exception.Message
}
