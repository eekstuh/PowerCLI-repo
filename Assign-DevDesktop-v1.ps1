<#
.SYNOPSIS
Assigns an available developer desktop virtual machine to a user.

.DESCRIPTION
Selects a naming convention, gathers the user's name and Active Directory
account, and determines whether the user is a consultant. The script finds the
highest-numbered assigned virtual machine for the selected naming convention in
the Developer Desktops cluster. It then offers powered-on, unassigned virtual
machines with higher numbers in ascending order.

After the operator accepts a virtual machine, the script uses VMware Tools guest
operations to add the user's Active Directory account to the built-in local
Remote Desktop Users group. The vSphere inventory name is changed only after the
guest operation succeeds. The Windows computer name is not changed.

Enter 'exit' at any text prompt to cancel the remaining workflow.

.PARAMETER VIServer
Optional vCenter Server host name or IP address. If omitted, an existing active
PowerCLI connection is reused. If no single active connection is available, the
script prompts for a vCenter Server.

.PARAMETER Credential
Optional credential used only when a new vCenter Server connection is required.

.PARAMETER GuestCredential
Optional Windows guest administrator credential used by VMware Tools guest
operations.

.PARAMETER ClusterName
Cluster containing the developer desktop virtual machines.

.PARAMETER NamingConvention
Virtual machine naming convention: 11VMGC, 11VMDEV, or 11VMSAS.

.PARAMETER FirstName
User's first name as it should appear in the vSphere inventory name.

.PARAMETER LastName
User's last name as it should appear in the vSphere inventory name.

.PARAMETER ADAccountName
Active Directory account to add to the guest's local Remote Desktop Users group.
A plain sAMAccountName, DOMAIN\username, or user principal name can be supplied.
For a plain account name, the script uses the guest computer's joined domain.

.PARAMETER Consultant
Indicates whether "Consultant" is included before the user's name in the
assigned virtual machine name.

.EXAMPLE
.\Assign-DevDesktop-v1.ps1

.EXAMPLE
.\Assign-DevDesktop-v1.ps1 -NamingConvention 11VMDEV -FirstName Jane -LastName Doe -ADAccountName jdoe -Consultant $false
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$VIServer,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter()]
    [string]$ClusterName = 'Developer Desktops',

    [Parameter()]
    [ValidateSet('11VMGC', '11VMDEV', '11VMSAS')]
    [string]$NamingConvention,

    [Parameter()]
    [string]$FirstName,

    [Parameter()]
    [string]$LastName,

    [Parameter()]
    [string]$ADAccountName,

    [Parameter()]
    [Nullable[bool]]$Consultant
)

$ErrorActionPreference = 'Stop'
$script:ExitRequested = $false
$namingConventionWasSupplied = $PSBoundParameters.ContainsKey('NamingConvention')
$firstNameWasSupplied = $PSBoundParameters.ContainsKey('FirstName')
$lastNameWasSupplied = $PSBoundParameters.ContainsKey('LastName')
$adAccountWasSupplied = $PSBoundParameters.ContainsKey('ADAccountName')
$consultantWasSupplied = $PSBoundParameters.ContainsKey('Consultant')

function Write-Banner {
    $line = '=' * 76
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host '  Developer Desktop Assignment Assistant - Version 1' -ForegroundColor Cyan
    Write-Host '  Select desktop | Grant Remote Desktop access | Rename in vSphere' -ForegroundColor Gray
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "Enter 'exit' at any text prompt to cancel.`n" -ForegroundColor DarkGray
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
        Write-Host 'Cancelled. No changes were made.' -ForegroundColor Yellow
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
    $connections = @()
    foreach ($connection in (@($global:DefaultVIServer) + @($global:DefaultVIServers))) {
        if ($null -eq $connection) {
            continue
        }
        if ($connection.PSObject.Properties.Name -contains 'IsConnected' -and -not $connection.IsConnected) {
            continue
        }
        if (@($connections | Where-Object { $_.Name -ieq $connection.Name }).Count -eq 0) {
            $connections += $connection
        }
    }

    if ([string]::IsNullOrWhiteSpace($VIServer) -and $connections.Count -eq 1) {
        return $connections[0]
    }

    $serverName = $VIServer
    while ([string]::IsNullOrWhiteSpace($serverName)) {
        if ($connections.Count -gt 1) {
            Write-Host 'More than one active vCenter Server connection is available:' -ForegroundColor Yellow
            $connections | ForEach-Object { Write-Host "  $($_.Name)" }
        }

        $serverName = Read-ExitAwareInput -Prompt 'Enter the vCenter Server host name or IP address'
        Stop-IfExitRequested
        if ([string]::IsNullOrWhiteSpace($serverName)) {
            Write-Warning 'A vCenter Server host name or IP address is required.'
        }
    }

    $matchingConnection = @($connections | Where-Object { $_.Name -ieq $serverName })
    if ($matchingConnection.Count -gt 0) {
        return $matchingConnection[0]
    }

    $connectionCredential = $Credential
    if ($null -eq $connectionCredential) {
        $connectionCredential = Get-Credential -Message "Enter credentials for vCenter Server '$serverName'."
        if ($null -eq $connectionCredential) {
            throw 'The vCenter Server credential prompt was cancelled.'
        }
    }

    try {
        return Connect-VIServer -Server $serverName -Credential $connectionCredential -ErrorAction Stop
    }
    catch {
        throw "Could not connect to vCenter Server '$serverName'. $($_.Exception.Message)"
    }
}

function Get-ExactCluster {
    param(
        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $matches = @(Get-Cluster -Server $Server -ErrorAction Stop | Where-Object { $_.Name -ieq $Name })
    switch ($matches.Count) {
        0 { throw "Cluster '$Name' was not found on vCenter Server '$($Server.Name)'." }
        1 { return $matches[0] }
        default { throw "More than one cluster is named '$Name' on vCenter Server '$($Server.Name)'." }
    }
}

function Read-NamingConvention {
    if ($namingConventionWasSupplied) {
        return $NamingConvention
    }

    while ($true) {
        Write-Host "`nSelect a virtual machine naming convention:" -ForegroundColor Cyan
        Write-Host '  1. 11VMGC'
        Write-Host '  2. 11VMDEV'
        Write-Host '  3. 11VMSAS'

        $selection = Read-ExitAwareInput -Prompt 'Select an option (1, 2, or 3)'
        Stop-IfExitRequested
        switch ($selection.Trim().ToUpperInvariant()) {
            '1'       { return '11VMGC' }
            '11VMGC'  { return '11VMGC' }
            '2'       { return '11VMDEV' }
            '11VMDEV' { return '11VMDEV' }
            '3'       { return '11VMSAS' }
            '11VMSAS' { return '11VMSAS' }
            default { Write-Warning 'Select option 1, 2, or 3.' }
        }
    }
}

function Resolve-RequiredText {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$InitialValue,

        [Parameter(Mandatory)]
        [bool]$WasSupplied,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$FieldName,

        [Parameter()]
        [switch]$RejectAssignmentDelimiter
    )

    if ($WasSupplied) {
        $value = [regex]::Replace(([string]$InitialValue).Trim(), '\s+', ' ')
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "$FieldName cannot be blank."
        }
        if ($RejectAssignmentDelimiter -and $value -match '\s+-\s+') {
            throw "$FieldName cannot contain the assignment delimiter ' - '."
        }
        return $value
    }

    while ($true) {
        $value = Read-ExitAwareInput -Prompt $Prompt
        Stop-IfExitRequested
        $value = [regex]::Replace(([string]$value).Trim(), '\s+', ' ')
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Warning "$FieldName cannot be blank."
            continue
        }
        if ($RejectAssignmentDelimiter -and $value -match '\s+-\s+') {
            Write-Warning "$FieldName cannot contain the assignment delimiter ' - '."
            continue
        }
        return $value
    }
}

function Get-DesktopInventory {
    param(
        [Parameter(Mandatory)]
        [object[]]$VirtualMachines,

        [Parameter(Mandatory)]
        [string]$Prefix
    )

    $escapedPrefix = [regex]::Escape($Prefix)
    $pattern = "^$escapedPrefix(?<Number>\d+)(?<Assignment>\s+-\s+.+)?$"
    return @(
        $VirtualMachines |
            ForEach-Object {
                if ($_.Name -match $pattern) {
                    [pscustomobject]@{
                        VM         = $_
                        Name       = $_.Name
                        Number     = [long]$Matches.Number
                        IsAssigned = -not [string]::IsNullOrWhiteSpace([string]$Matches.Assignment)
                        PowerState = [string]$_.PowerState
                    }
                }
            } |
            Sort-Object Number, Name
    )
}

function Assert-UserIsNotAlreadyAssigned {
    param(
        [Parameter(Mandatory)]
        [object[]]$VirtualMachines,

        [Parameter(Mandatory)]
        [string]$FirstName,

        [Parameter(Mandatory)]
        [string]$LastName
    )

    $personName = "$FirstName $LastName"
    $escapedPersonName = [regex]::Escape($personName)
    $pattern = "^(?:11VMGC|11VMDEV|11VMSAS)\d+\s+-\s+(?:Consultant\s+)?$escapedPersonName$"
    $matches = @($VirtualMachines | Where-Object { $_.Name -match $pattern })
    if ($matches.Count -gt 0) {
        $names = $matches.Name -join ', '
        throw "A virtual machine assignment for '$personName' already exists in the cluster: $names"
    }
}

function Get-AssignmentCandidates {
    param(
        [Parameter(Mandatory)]
        [object[]]$Inventory,

        [Parameter(Mandatory)]
        [string]$Prefix
    )

    $assigned = @($Inventory | Where-Object IsAssigned)
    if ($assigned.Count -eq 0) {
        throw "No assigned '$Prefix' virtual machine was found. The script cannot determine the latest assignment range safely."
    }

    $latestAssigned = $assigned | Sort-Object Number -Descending | Select-Object -First 1
    $oldUnassigned = @($Inventory | Where-Object { -not $_.IsAssigned -and $_.Number -le $latestAssigned.Number })
    $poweredOffNewer = @($Inventory | Where-Object { -not $_.IsAssigned -and $_.Number -gt $latestAssigned.Number -and $_.PowerState -ne 'PoweredOn' })
    $candidates = @(
        $Inventory |
            Where-Object {
                -not $_.IsAssigned -and
                $_.Number -gt $latestAssigned.Number -and
                $_.PowerState -eq 'PoweredOn'
            } |
            Sort-Object Number, Name
    )

    Write-Host "`nLatest assigned virtual machine: $($latestAssigned.Name)" -ForegroundColor Green
    Write-Host "Assignment cutoff number:       $($latestAssigned.Number)" -ForegroundColor Gray
    if ($oldUnassigned.Count -gt 0) {
        Write-Host "Ignored older unassigned VMs:   $($oldUnassigned.Count)" -ForegroundColor DarkGray
    }
    if ($poweredOffNewer.Count -gt 0) {
        Write-Host "Ignored powered-off VMs:        $($poweredOffNewer.Count)" -ForegroundColor DarkGray
    }

    return $candidates
}

function Get-RefreshedCandidate {
    param(
        [Parameter(Mandatory)]
        [object]$Candidate,

        [Parameter(Mandatory)]
        [object]$Server
    )

    $vm = Get-VM -Id $Candidate.VM.Id -Server $Server -ErrorAction Stop
    if ([string]$vm.PowerState -ne 'PoweredOn') {
        Write-Warning "Virtual machine '$($vm.Name)' is no longer powered on and will be skipped."
        return $null
    }

    $toolsStatus = [string]$vm.ExtensionData.Guest.ToolsRunningStatus
    if ($toolsStatus -ne 'guestToolsRunning') {
        Write-Warning "VMware Tools is not running on '$($vm.Name)'; this virtual machine will be skipped."
        return $null
    }

    return $vm
}

function Select-AssignmentVM {
    param(
        [Parameter(Mandatory)]
        [object[]]$Candidates,

        [Parameter(Mandatory)]
        [object[]]$AllVirtualMachines,

        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [string]$AssignmentLabel,

        [Parameter(Mandatory)]
        [string]$ADAccount
    )

    if ($Candidates.Count -eq 0) {
        throw 'No powered-on, unassigned virtual machines were found above the latest assigned number.'
    }

    Write-Host "`nPowered-on assignment candidates:" -ForegroundColor Cyan
    $Candidates |
        Select-Object @{ Name = 'VMName'; Expression = { $_.Name } }, Number, PowerState |
        Format-Table -AutoSize |
        Out-Host

    foreach ($candidate in $Candidates) {
        $vm = Get-RefreshedCandidate -Candidate $candidate -Server $Server
        if ($null -eq $vm) {
            continue
        }

        $targetName = "$($vm.Name) - $AssignmentLabel"
        $nameCollision = @($AllVirtualMachines | Where-Object { $_.Name -ieq $targetName -and $_.Id -ne $vm.Id })
        if ($nameCollision.Count -gt 0) {
            Write-Warning "The proposed name '$targetName' already exists; '$($vm.Name)' will be skipped."
            continue
        }

        Write-Host "`nProposed assignment:" -ForegroundColor Cyan
        Write-Host "  Current VM name: $($vm.Name)"
        Write-Host "  Assigned VM name: $targetName"
        Write-Host "  AD account:       $ADAccount"
        if (Read-YesNo -Prompt "Use virtual machine '$($vm.Name)' for this assignment?") {
            return [pscustomobject]@{
                VM         = $vm
                TargetName = $targetName
            }
        }

        Write-Host "Skipped '$($vm.Name)'. Evaluating the next candidate." -ForegroundColor Yellow
    }

    return $null
}

function Get-WindowsGuestCredential {
    if ($null -ne $GuestCredential) {
        return $GuestCredential
    }

    $guestUserName = Read-ExitAwareInput -Prompt 'Enter the Windows guest administrator user name'
    Stop-IfExitRequested
    $credential = Get-Credential -UserName $guestUserName -Message 'Enter the Windows guest administrator password used by VMware Tools guest operations.'
    if ($null -eq $credential) {
        throw 'The Windows guest credential prompt was cancelled.'
    }
    return $credential
}

function ConvertTo-GuestBase64 {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
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
        $details = [string]$result.ScriptOutput
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = 'VMware Tools returned no guest error details.'
        }
        throw "The Windows guest script failed with exit code $($result.ExitCode): $($details.Trim())"
    }

    $output = [string]$result.ScriptOutput
    $beginMarker = '__VMWARE_GUEST_PAYLOAD_BEGIN__'
    $endMarker = '__VMWARE_GUEST_PAYLOAD_END__'
    $beginIndex = $output.LastIndexOf($beginMarker, [System.StringComparison]::Ordinal)
    if ($beginIndex -lt 0) {
        $displayOutput = $output.Trim()
        if ($displayOutput.Length -gt 2000) {
            $displayOutput = $displayOutput.Substring(0, 2000) + '...'
        }
        throw "The Windows guest returned an unframed result. Guest output: $displayOutput"
    }

    $payloadStart = $beginIndex + $beginMarker.Length
    $endIndex = $output.IndexOf($endMarker, $payloadStart, [System.StringComparison]::Ordinal)
    if ($endIndex -lt 0) {
        throw 'The Windows guest result was incomplete: the payload end marker was missing.'
    }

    return $output.Substring($payloadStart, $endIndex - $payloadStart).Trim()
}

function Add-GuestRemoteDesktopUser {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory)]
        [string]$AccountName
    )

    $encodedAccount = ConvertTo-GuestBase64 -Value $AccountName
    $scriptText = @'
$ErrorActionPreference = 'Stop'
$accountInput = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ACCOUNT_BASE64__'))

foreach ($commandName in @('Get-LocalGroup', 'Get-LocalGroupMember', 'Add-LocalGroupMember')) {
    if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue)) {
        throw "Required Windows command '$commandName' is unavailable."
    }
}

$resolvedAccount = $accountInput
if ($accountInput -notmatch '[\\@]') {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if (-not $computerSystem.PartOfDomain -or [string]::IsNullOrWhiteSpace([string]$computerSystem.Domain)) {
        throw "The guest is not joined to a domain. Supply the account as DOMAIN\username or as a user principal name."
    }
    $resolvedAccount = "$($computerSystem.Domain)\$accountInput"
}

try {
    $accountSid = ([System.Security.Principal.NTAccount]::new($resolvedAccount)).Translate([System.Security.Principal.SecurityIdentifier])
}
catch {
    throw "Active Directory account '$resolvedAccount' could not be resolved. $($_.Exception.Message)"
}

$remoteDesktopGroupSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-555')
$remoteDesktopGroup = Get-LocalGroup -SID $remoteDesktopGroupSid -ErrorAction Stop
$existingMember = @(
    Get-LocalGroupMember -Group $remoteDesktopGroup -ErrorAction Stop |
        Where-Object { $null -ne $_.SID -and $_.SID.Value -eq $accountSid.Value }
)

$added = $false
if ($existingMember.Count -eq 0) {
    Add-LocalGroupMember -Group $remoteDesktopGroup -Member $resolvedAccount -ErrorAction Stop
    $added = $true
}

$verifiedMember = @(
    Get-LocalGroupMember -Group $remoteDesktopGroup -ErrorAction Stop |
        Where-Object { $null -ne $_.SID -and $_.SID.Value -eq $accountSid.Value }
)
if ($verifiedMember.Count -eq 0) {
    throw "Account '$resolvedAccount' was not found in local group '$($remoteDesktopGroup.Name)' after the add operation."
}

[pscustomobject]@{
    Account   = $resolvedAccount
    AccountSID = $accountSid.Value
    Group     = $remoteDesktopGroup.Name
    Added     = $added
} | ConvertTo-Json -Compress
'@
    $scriptText = $scriptText.Replace('__ACCOUNT_BASE64__', $encodedAccount)
    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    return $json | ConvertFrom-Json -ErrorAction Stop
}

function Remove-GuestRemoteDesktopUser {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory)]
        [string]$AccountSID
    )

    $encodedSid = ConvertTo-GuestBase64 -Value $AccountSID
    $scriptText = @'
$ErrorActionPreference = 'Stop'
$accountSid = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ACCOUNT_SID_BASE64__'))
$remoteDesktopGroupSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-555')
$remoteDesktopGroup = Get-LocalGroup -SID $remoteDesktopGroupSid -ErrorAction Stop
$member = @(
    Get-LocalGroupMember -Group $remoteDesktopGroup -ErrorAction Stop |
        Where-Object { $null -ne $_.SID -and $_.SID.Value -eq $accountSid }
) | Select-Object -First 1

if ($null -ne $member) {
    Remove-LocalGroupMember -Group $remoteDesktopGroup -Member $member -ErrorAction Stop
}

$remainingMember = @(
    Get-LocalGroupMember -Group $remoteDesktopGroup -ErrorAction Stop |
        Where-Object { $null -ne $_.SID -and $_.SID.Value -eq $accountSid }
)
if ($remainingMember.Count -gt 0) {
    throw "The account with SID '$accountSid' remains in local group '$($remoteDesktopGroup.Name)'."
}

[pscustomobject]@{ Removed = $true } | ConvertTo-Json -Compress
'@
    $scriptText = $scriptText.Replace('__ACCOUNT_SID_BASE64__', $encodedSid)
    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    return $json | ConvertFrom-Json -ErrorAction Stop
}

try {
    Write-Banner
    $server = Get-VCenterConnection
    Write-Host "Using vCenter Server connection '$($server.Name)'." -ForegroundColor Green

    $cluster = Get-ExactCluster -Server $server -Name $ClusterName
    Write-Host "Using cluster '$($cluster.Name)'." -ForegroundColor Green

    $selectedPrefix = Read-NamingConvention
    $resolvedFirstName = Resolve-RequiredText -InitialValue $FirstName -WasSupplied $firstNameWasSupplied -Prompt "Enter the user's first name" -FieldName 'First name' -RejectAssignmentDelimiter
    $resolvedLastName = Resolve-RequiredText -InitialValue $LastName -WasSupplied $lastNameWasSupplied -Prompt "Enter the user's last name" -FieldName 'Last name' -RejectAssignmentDelimiter
    $resolvedADAccount = Resolve-RequiredText -InitialValue $ADAccountName -WasSupplied $adAccountWasSupplied -Prompt "Enter the user's Active Directory account name" -FieldName 'Active Directory account name'
    $isConsultant = if ($consultantWasSupplied) {
        [bool]$Consultant
    }
    else {
        Read-YesNo -Prompt 'Is this user a consultant?'
    }

    $personName = "$resolvedFirstName $resolvedLastName"
    $assignmentLabel = if ($isConsultant) { "Consultant $personName" } else { $personName }
    $allVirtualMachines = @(Get-VM -Location $cluster -Server $server -ErrorAction Stop)
    Assert-UserIsNotAlreadyAssigned -VirtualMachines $allVirtualMachines -FirstName $resolvedFirstName -LastName $resolvedLastName

    $inventory = @(Get-DesktopInventory -VirtualMachines $allVirtualMachines -Prefix $selectedPrefix)
    $candidates = @(Get-AssignmentCandidates -Inventory $inventory -Prefix $selectedPrefix)
    $selection = Select-AssignmentVM -Candidates $candidates -AllVirtualMachines $allVirtualMachines -Server $server -AssignmentLabel $assignmentLabel -ADAccount $resolvedADAccount
    if ($null -eq $selection) {
        Write-Host 'No virtual machine was selected. No changes were made.' -ForegroundColor Yellow
        return
    }

    $selectedVM = $selection.VM
    $targetVMName = $selection.TargetName

    if (-not $PSCmdlet.ShouldProcess($selectedVM.Name, "Grant Remote Desktop access to '$resolvedADAccount' and rename the VM to '$targetVMName'")) {
        Write-Host 'No changes were made.' -ForegroundColor Yellow
        return
    }

    $guestAdminCredential = Get-WindowsGuestCredential
    Write-Host "`nGranting Remote Desktop access inside '$($selectedVM.Name)' through VMware Tools..." -ForegroundColor Cyan
    $guestResult = Add-GuestRemoteDesktopUser -VM $selectedVM -Credential $guestAdminCredential -AccountName $resolvedADAccount
    if ([bool]$guestResult.Added) {
        Write-Host "Added '$($guestResult.Account)' to local group '$($guestResult.Group)'." -ForegroundColor Green
    }
    else {
        Write-Host "'$($guestResult.Account)' is already a member of local group '$($guestResult.Group)'." -ForegroundColor Green
    }

    Write-Host "Renaming '$($selectedVM.Name)' to '$targetVMName' in vSphere..." -ForegroundColor Cyan
    try {
        Set-VM -VM $selectedVM -Name $targetVMName -Server $server -Confirm:$false -ErrorAction Stop | Out-Null
        $verifiedVM = Get-VM -Id $selectedVM.Id -Server $server -ErrorAction Stop
        if ($verifiedVM.Name -cne $targetVMName) {
            throw "Rename verification returned '$($verifiedVM.Name)' instead of '$targetVMName'."
        }
    }
    catch {
        $renameError = $_.Exception.Message
        if ([bool]$guestResult.Added) {
            try {
                [void](Remove-GuestRemoteDesktopUser -VM $selectedVM -Credential $guestAdminCredential -AccountSID ([string]$guestResult.AccountSID))
                Write-Warning "The vSphere rename failed. The newly added Remote Desktop Users membership was removed."
            }
            catch {
                Write-Warning "The vSphere rename failed, and the guest membership rollback also failed: $($_.Exception.Message)"
            }
        }
        throw "The vSphere rename failed: $renameError"
    }

    Write-Host "`nAssignment completed successfully." -ForegroundColor Green
    Write-Host "  VM name:    $targetVMName"
    Write-Host "  User:       $personName"
    Write-Host "  Consultant: $(if ($isConsultant) { 'Yes' } else { 'No' })"
    Write-Host "  AD account: $($guestResult.Account)"
    Write-Host "  Guest group: $($guestResult.Group)"
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
