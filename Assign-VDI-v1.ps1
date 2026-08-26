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
Virtual machine naming convention: 11VMGC, 11VMDEV, 11VMSAS, or SPECIFIC. The
SPECIFIC option assigns an exact VM name instead of selecting from the numbered
pool above the latest assignment cutoff.

.PARAMETER VMName
Exact virtual machine name to use with NamingConvention SPECIFIC. If omitted in
interactive mode, the script prompts for it.

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

.PARAMETER InputCsvPath
Optional path to a CSV file for assigning multiple users. Required columns are
NamingConvention, FirstName, LastName, ADAccountName, and Consultant. Consultant
accepts Y, Yes, True, 1, N, No, False, or 0. Interactive user fields cannot be
combined with InputCsvPath. For a SPECIFIC row, include a VMName column and the
exact virtual machine name.

.EXAMPLE
.\Assign-VDI-v1.ps1

.EXAMPLE
.\Assign-VDI-v1.ps1 -NamingConvention 11VMDEV -FirstName Jane -LastName Doe -ADAccountName jdoe -Consultant $false

.EXAMPLE
.\Assign-VDI-v1.ps1 -NamingConvention SPECIFIC -VMName 11VMDEV501 -FirstName Jane -LastName Doe -ADAccountName jdoe -Consultant $false

.EXAMPLE
.\Assign-VDI-v1.ps1 -InputCsvPath .\DesktopAssignments.csv

The CSV format is:
NamingConvention,VMName,FirstName,LastName,ADAccountName,Consultant
11VMGC,,Jane,Doe,jdoe,No
SPECIFIC,11VMDEV501,John,Smith,CONTOSO\jsmith,Yes
#>
[CmdletBinding(DefaultParameterSetName = 'Interactive', SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$VIServer,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter()]
    [string]$ClusterName = 'Developer Desktops',

    [Parameter(ParameterSetName = 'Interactive')]
    [ValidateSet('11VMGC', '11VMDEV', '11VMSAS', 'SPECIFIC', 'CUSTOM')]
    [string]$NamingConvention,

    [Parameter(ParameterSetName = 'Interactive')]
    [string]$VMName,

    [Parameter(ParameterSetName = 'Interactive')]
    [string]$FirstName,

    [Parameter(ParameterSetName = 'Interactive')]
    [string]$LastName,

    [Parameter(ParameterSetName = 'Interactive')]
    [string]$ADAccountName,

    [Parameter(ParameterSetName = 'Interactive')]
    [Nullable[bool]]$Consultant,

    [Parameter(Mandatory, ParameterSetName = 'Csv')]
    [ValidateNotNullOrEmpty()]
    [string]$InputCsvPath
)

$ErrorActionPreference = 'Stop'
$script:ExitRequested = $false
$script:CompletedAssignments = 0
$script:ResolvedGuestCredential = $null
$script:InvocationParameterSet = $PSCmdlet.ParameterSetName
$namingConventionWasSupplied = $PSBoundParameters.ContainsKey('NamingConvention')
$vmNameWasSupplied = $PSBoundParameters.ContainsKey('VMName')
$firstNameWasSupplied = $PSBoundParameters.ContainsKey('FirstName')
$lastNameWasSupplied = $PSBoundParameters.ContainsKey('LastName')
$adAccountWasSupplied = $PSBoundParameters.ContainsKey('ADAccountName')
$consultantWasSupplied = $PSBoundParameters.ContainsKey('Consultant')

function Write-Banner {
    $line = '=' * 76
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host '  VDI Assignment Assistant - Version 1' -ForegroundColor Cyan
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
        if ($script:CompletedAssignments -gt 0) {
            Write-Host "Cancelled. $($script:CompletedAssignments) assignment(s) were completed before cancellation." -ForegroundColor Yellow
        }
        else {
            Write-Host 'Cancelled. No changes were made.' -ForegroundColor Yellow
        }
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
        if ($NamingConvention -ieq 'CUSTOM') {
            return 'SPECIFIC'
        }
        return $NamingConvention.ToUpperInvariant()
    }

    while ($true) {
        Write-Host "`nSelect a virtual machine naming convention:" -ForegroundColor Cyan
        Write-Host '  1. 11VMGC'
        Write-Host '  2. 11VMDEV'
        Write-Host '  3. 11VMSAS'
        Write-Host '  4. Specific VM name'

        $selection = Read-ExitAwareInput -Prompt 'Select an option (1, 2, 3, or 4)'
        Stop-IfExitRequested
        switch ($selection.Trim().ToUpperInvariant()) {
            '1'       { return '11VMGC' }
            '11VMGC'  { return '11VMGC' }
            '2'       { return '11VMDEV' }
            '11VMDEV' { return '11VMDEV' }
            '3'       { return '11VMSAS' }
            '11VMSAS' { return '11VMSAS' }
            '4'        { return 'SPECIFIC' }
            'SPECIFIC' { return 'SPECIFIC' }
            'CUSTOM'   { return 'SPECIFIC' }
            default { Write-Warning 'Select option 1, 2, 3, or 4.' }
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
        [AllowEmptyString()]
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

function ConvertTo-ConsultantValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Context
    )

    $normalizedValue = ([string]$Value).Trim().ToLowerInvariant()
    switch ($normalizedValue) {
        { $_ -in @('y', 'yes', 'true', '1') } { return $true }
        { $_ -in @('n', 'no', 'false', '0') } { return $false }
        default { throw "$Context has an invalid Consultant value '$Value'. Use Y, Yes, True, 1, N, No, False, or 0." }
    }
}

function Get-AssignmentWorkItems {
    if ($script:InvocationParameterSet -eq 'Interactive') {
        $selectedPrefix = Read-NamingConvention
        $requestedVMName = if ($selectedPrefix -eq 'SPECIFIC') {
            Resolve-RequiredText -InitialValue $VMName -WasSupplied $vmNameWasSupplied -Prompt 'Enter the exact virtual machine name to assign' -FieldName 'Virtual machine name' -RejectAssignmentDelimiter
        }
        else {
            if ($vmNameWasSupplied) {
                throw 'VMName can be used only when NamingConvention is SPECIFIC or CUSTOM.'
            }
            ''
        }
        $resolvedFirstName = Resolve-RequiredText -InitialValue $FirstName -WasSupplied $firstNameWasSupplied -Prompt "Enter the user's first name" -FieldName 'First name' -RejectAssignmentDelimiter
        $resolvedLastName = Resolve-RequiredText -InitialValue $LastName -WasSupplied $lastNameWasSupplied -Prompt "Enter the user's last name" -FieldName 'Last name' -RejectAssignmentDelimiter
        $resolvedADAccount = Resolve-RequiredText -InitialValue $ADAccountName -WasSupplied $adAccountWasSupplied -Prompt "Enter the user's Active Directory account name" -FieldName 'Active Directory account name'
        $isConsultant = if ($consultantWasSupplied) {
            [bool]$Consultant
        }
        else {
            Read-YesNo -Prompt 'Is this user a consultant?'
        }

        return @(
            [pscustomobject]@{
                RowNumber        = $null
                NamingConvention = $selectedPrefix
                RequestedVMName  = $requestedVMName
                FirstName        = $resolvedFirstName
                LastName         = $resolvedLastName
                ADAccountName    = $resolvedADAccount
                Consultant       = $isConsultant
                ValidationError  = $null
            }
        )
    }

    $resolvedCsvPath = (Resolve-Path -LiteralPath $InputCsvPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedCsvPath -PathType Leaf)) {
        throw "CSV input path '$InputCsvPath' is not a file."
    }

    $rows = @(Import-Csv -LiteralPath $resolvedCsvPath -ErrorAction Stop)
    if ($rows.Count -eq 0) {
        throw "CSV input file '$resolvedCsvPath' does not contain any user rows."
    }

    $requiredColumns = @('NamingConvention', 'FirstName', 'LastName', 'ADAccountName', 'Consultant')
    $columnNames = @($rows[0].PSObject.Properties.Name)
    $missingColumns = @($requiredColumns | Where-Object { $columnNames -notcontains $_ })
    if ($missingColumns.Count -gt 0) {
        throw "CSV input file '$resolvedCsvPath' is missing required column(s): $($missingColumns -join ', ')."
    }

    Write-Host "Loaded $($rows.Count) user assignment row(s) from '$resolvedCsvPath'." -ForegroundColor Green
    $workItems = for ($index = 0; $index -lt $rows.Count; $index++) {
        $row = $rows[$index]
        $rowNumber = $index + 2
        try {
            $prefix = ([string]$row.NamingConvention).Trim().ToUpperInvariant()
            if ($prefix -eq 'CUSTOM') {
                $prefix = 'SPECIFIC'
            }
            if ($prefix -notin @('11VMGC', '11VMDEV', '11VMSAS', 'SPECIFIC')) {
                throw "CSV row $rowNumber has an invalid NamingConvention '$($row.NamingConvention)'. Use 11VMGC, 11VMDEV, 11VMSAS, or SPECIFIC."
            }

            $requestedVMName = if ($prefix -eq 'SPECIFIC') {
                Resolve-RequiredText -InitialValue ([string]$row.VMName) -WasSupplied $true -Prompt '' -FieldName "CSV row $rowNumber VMName" -RejectAssignmentDelimiter
            }
            else { '' }

            [pscustomobject]@{
                RowNumber        = $rowNumber
                NamingConvention = $prefix
                RequestedVMName  = $requestedVMName
                FirstName        = Resolve-RequiredText -InitialValue ([string]$row.FirstName) -WasSupplied $true -Prompt '' -FieldName "CSV row $rowNumber FirstName" -RejectAssignmentDelimiter
                LastName         = Resolve-RequiredText -InitialValue ([string]$row.LastName) -WasSupplied $true -Prompt '' -FieldName "CSV row $rowNumber LastName" -RejectAssignmentDelimiter
                ADAccountName    = Resolve-RequiredText -InitialValue ([string]$row.ADAccountName) -WasSupplied $true -Prompt '' -FieldName "CSV row $rowNumber ADAccountName"
                Consultant       = ConvertTo-ConsultantValue -Value $row.Consultant -Context "CSV row $rowNumber"
                ValidationError  = $null
            }
        }
        catch {
            [pscustomobject]@{
                RowNumber        = $rowNumber
                NamingConvention = [string]$row.NamingConvention
                RequestedVMName  = [string]$row.VMName
                FirstName        = [string]$row.FirstName
                LastName         = [string]$row.LastName
                ADAccountName    = [string]$row.ADAccountName
                Consultant       = $null
                ValidationError  = $_.Exception.Message
            }
        }
    }

    return @($workItems)
}

function New-AssignmentResult {
    param(
        [Parameter(Mandatory)]
        [object]$WorkItem,

        [Parameter(Mandatory)]
        [string]$Outcome,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [AllowEmptyString()]
        [string]$VMName = '',

        [Parameter()]
        [AllowEmptyString()]
        [string]$ResolvedADAccount = ''
    )

    return [pscustomobject]@{
        CsvRow             = $WorkItem.RowNumber
        NamingConvention   = $WorkItem.NamingConvention
        RequestedVMName    = $WorkItem.RequestedVMName
        User               = "$($WorkItem.FirstName) $($WorkItem.LastName)".Trim()
        RequestedADAccount = $WorkItem.ADAccountName
        ResolvedADAccount  = $ResolvedADAccount
        VMName             = $VMName
        Outcome            = $Outcome
        Message            = $Message
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
    $pattern = "^.+\s+-\s+(?:Consultant\s+)?$escapedPersonName$"
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

function Select-SpecificAssignmentVM {
    param(
        [Parameter(Mandatory)]
        [string]$InitialVMName,

        [Parameter(Mandatory)]
        [object[]]$AllVirtualMachines,

        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [string]$AssignmentLabel,

        [Parameter(Mandatory)]
        [string]$ADAccount,

        [Parameter()]
        [switch]$AllowNameCorrection
    )

    $requestedName = $InitialVMName
    while ($true) {
        $matches = @($AllVirtualMachines | Where-Object { $_.Name -ieq $requestedName })
        $validationMessage = $null
        if ($matches.Count -eq 0) {
            $validationMessage = "Virtual machine '$requestedName' was not found in the cluster."
        }
        elseif ($matches.Count -gt 1) {
            $validationMessage = "More than one virtual machine is named '$requestedName' in the cluster."
        }
        elseif ($matches[0].Name -match '\s+-\s+.+$') {
            $validationMessage = "Virtual machine '$($matches[0].Name)' already appears to be assigned."
        }
        elseif ([string]$matches[0].PowerState -ne 'PoweredOn') {
            $validationMessage = "Virtual machine '$($matches[0].Name)' is not powered on."
        }

        if ($null -ne $validationMessage) {
            if (-not $AllowNameCorrection) {
                throw $validationMessage
            }
            Write-Warning $validationMessage
            $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact virtual machine name to assign' -FieldName 'Virtual machine name' -RejectAssignmentDelimiter
            continue
        }

        $vm = Get-RefreshedCandidate -Candidate ([pscustomobject]@{ VM = $matches[0] }) -Server $Server
        if ($null -eq $vm) {
            if (-not $AllowNameCorrection) {
                throw "Virtual machine '$requestedName' does not currently meet the assignment requirements."
            }
            $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact virtual machine name to assign' -FieldName 'Virtual machine name' -RejectAssignmentDelimiter
            continue
        }

        $targetName = "$($vm.Name) - $AssignmentLabel"
        $nameCollision = @($AllVirtualMachines | Where-Object { $_.Name -ieq $targetName -and $_.Id -ne $vm.Id })
        if ($nameCollision.Count -gt 0) {
            $validationMessage = "The proposed name '$targetName' already exists in the cluster."
            if (-not $AllowNameCorrection) {
                throw $validationMessage
            }
            Write-Warning $validationMessage
            $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact virtual machine name to assign' -FieldName 'Virtual machine name' -RejectAssignmentDelimiter
            continue
        }

        Write-Host "`nProposed assignment:" -ForegroundColor Cyan
        Write-Host "  Current VM name:  $($vm.Name)"
        Write-Host "  Assigned VM name: $targetName"
        Write-Host "  AD account:        $ADAccount"
        if (Read-YesNo -Prompt "Use virtual machine '$($vm.Name)' for this assignment?") {
            return [pscustomobject]@{
                VM         = $vm
                TargetName = $targetName
            }
        }

        if (-not $AllowNameCorrection) {
            return $null
        }
        Write-Host "Skipped '$($vm.Name)'." -ForegroundColor Yellow
        $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact virtual machine name to assign' -FieldName 'Virtual machine name' -RejectAssignmentDelimiter
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

    $guestUserName = Read-ExitAwareInput -Prompt 'Enter the Windows guest administrator user name'
    Stop-IfExitRequested
    $credential = Get-Credential -UserName $guestUserName -Message 'Enter the Windows guest administrator password used by VMware Tools guest operations.'
    if ($null -eq $credential) {
        throw 'The Windows guest credential prompt was cancelled.'
    }
    $script:ResolvedGuestCredential = $credential
    return $script:ResolvedGuestCredential
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
    throw "__AD_ACCOUNT_NOT_FOUND__|$resolvedAccount|$($_.Exception.Message)"
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
    Account    = $resolvedAccount
    AccountSID = $accountSid.Value
    Group      = $remoteDesktopGroup.Name
    Added      = $added
    Verified   = $true
} | ConvertTo-Json -Compress
'@
    $scriptText = $scriptText.Replace('__ACCOUNT_BASE64__', $encodedAccount)
    $json = Invoke-WindowsGuestPowerShell -VM $VM -Credential $Credential -ScriptText $scriptText
    $result = $json | ConvertFrom-Json -ErrorAction Stop
    if (-not [bool]$result.Verified -or [string]::IsNullOrWhiteSpace([string]$result.AccountSID)) {
        throw 'The Windows guest did not return successful Remote Desktop Users membership verification.'
    }
    return $result
}

function Add-GuestRemoteDesktopUserWithCorrection {
    param(
        [Parameter(Mandatory)]
        [object]$VM,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory)]
        [string]$InitialAccountName
    )

    $accountName = $InitialAccountName
    while ($true) {
        try {
            $guestResult = Add-GuestRemoteDesktopUser -VM $VM -Credential $Credential -AccountName $accountName
            return [pscustomobject]@{
                AccountInput = $accountName
                GuestResult  = $guestResult
            }
        }
        catch {
            $message = $_.Exception.Message
            $accountNotFoundMatch = [regex]::Match($message, '__AD_ACCOUNT_NOT_FOUND__\|(?<Account>[^|]+)\|')
            if (-not $accountNotFoundMatch.Success) {
                throw
            }

            $unresolvedAccount = $accountNotFoundMatch.Groups['Account'].Value
            Write-Warning "Active Directory account '$unresolvedAccount' could not be found. The VM has not been renamed."
            $accountName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt "Enter the correct Active Directory account for '$($VM.Name)'" -FieldName 'Active Directory account name'
        }
    }
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
    $workItems = @(Get-AssignmentWorkItems)
    $results = @()

    for ($index = 0; $index -lt $workItems.Count; $index++) {
        $workItem = $workItems[$index]
        $itemLabel = if ($null -ne $workItem.RowNumber) { "CSV row $($workItem.RowNumber)" } else { 'Interactive assignment' }
        Write-Host "`n[$($index + 1)/$($workItems.Count)] Processing $itemLabel..." -ForegroundColor Cyan

        if (-not [string]::IsNullOrWhiteSpace([string]$workItem.ValidationError)) {
            Write-Warning $workItem.ValidationError
            $results += New-AssignmentResult -WorkItem $workItem -Outcome 'InputFailed' -Message $workItem.ValidationError
            continue
        }

        $selectedVM = $null
        $targetVMName = ''
        $guestResult = $null
        try {
            $personName = "$($workItem.FirstName) $($workItem.LastName)"
            $assignmentLabel = if ([bool]$workItem.Consultant) { "Consultant $personName" } else { $personName }
            $allVirtualMachines = @(Get-VM -Location $cluster -Server $server -ErrorAction Stop)
            Assert-UserIsNotAlreadyAssigned -VirtualMachines $allVirtualMachines -FirstName $workItem.FirstName -LastName $workItem.LastName

            if ($workItem.NamingConvention -eq 'SPECIFIC') {
                $specificSelectionParameters = @{
                    InitialVMName     = $workItem.RequestedVMName
                    AllVirtualMachines = $allVirtualMachines
                    Server            = $server
                    AssignmentLabel   = $assignmentLabel
                    ADAccount         = $workItem.ADAccountName
                }
                if ($script:InvocationParameterSet -eq 'Interactive') {
                    $specificSelectionParameters.AllowNameCorrection = $true
                }
                $selection = Select-SpecificAssignmentVM @specificSelectionParameters
            }
            else {
                $inventory = @(Get-DesktopInventory -VirtualMachines $allVirtualMachines -Prefix $workItem.NamingConvention)
                $candidates = @(Get-AssignmentCandidates -Inventory $inventory -Prefix $workItem.NamingConvention)
                $selection = Select-AssignmentVM -Candidates $candidates -AllVirtualMachines $allVirtualMachines -Server $server -AssignmentLabel $assignmentLabel -ADAccount $workItem.ADAccountName
            }
            if ($null -eq $selection) {
                $message = if ($workItem.NamingConvention -eq 'SPECIFIC') { 'The specified virtual machine was not selected.' } else { 'All available candidates were skipped by the operator.' }
                Write-Host "$message No changes were made for '$personName'." -ForegroundColor Yellow
                $results += New-AssignmentResult -WorkItem $workItem -Outcome 'Skipped' -Message $message
                continue
            }

            if ($workItem.NamingConvention -eq 'SPECIFIC') {
                $workItem.RequestedVMName = $selection.VM.Name
            }
            $selectedVM = $selection.VM
            $targetVMName = $selection.TargetName
            if (-not $PSCmdlet.ShouldProcess($selectedVM.Name, "Grant Remote Desktop access to '$($workItem.ADAccountName)' and rename the VM to '$targetVMName'")) {
                $results += New-AssignmentResult -WorkItem $workItem -Outcome 'WhatIf' -Message 'No changes were requested by ShouldProcess.' -VMName $selectedVM.Name
                continue
            }

            $guestAdminCredential = Get-WindowsGuestCredential
            Write-Host "`nGranting Remote Desktop access inside '$($selectedVM.Name)' through VMware Tools..." -ForegroundColor Cyan
            $accountResult = Add-GuestRemoteDesktopUserWithCorrection -VM $selectedVM -Credential $guestAdminCredential -InitialAccountName $workItem.ADAccountName
            $guestResult = $accountResult.GuestResult
            if (-not [bool]$guestResult.Verified) {
                throw 'Remote Desktop Users membership verification was not successful.'
            }

            if ([bool]$guestResult.Added) {
                Write-Host "Added '$($guestResult.Account)' to local group '$($guestResult.Group)'." -ForegroundColor Green
            }
            else {
                Write-Host "'$($guestResult.Account)' was already a member of local group '$($guestResult.Group)'." -ForegroundColor Green
            }
            Write-Host "Verified '$($guestResult.Account)' as a member of '$($guestResult.Group)'." -ForegroundColor Green

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
                        Write-Warning 'The vSphere rename failed. The newly added Remote Desktop Users membership was removed.'
                    }
                    catch {
                        Write-Warning "The vSphere rename failed, and the guest membership rollback also failed: $($_.Exception.Message)"
                    }
                }
                throw "The vSphere rename failed: $renameError"
            }

            $script:CompletedAssignments++
            Write-Host "Assignment completed successfully for '$personName' on '$targetVMName'." -ForegroundColor Green
            $results += New-AssignmentResult -WorkItem $workItem -Outcome 'Completed' -Message 'Remote Desktop access and vSphere rename were verified.' -VMName $targetVMName -ResolvedADAccount $guestResult.Account
        }
        catch {
            $message = $_.Exception.Message
            Write-Warning "Assignment failed for '$($workItem.FirstName) $($workItem.LastName)': $message"
            $results += New-AssignmentResult -WorkItem $workItem -Outcome 'Failed' -Message $message -VMName $(if ($null -ne $selectedVM) { $selectedVM.Name } else { '' }) -ResolvedADAccount $(if ($null -ne $guestResult) { [string]$guestResult.Account } else { '' })
        }
    }

    Write-Host "`nAssignment results:" -ForegroundColor Cyan
    $results |
        Format-Table CsvRow, User, VMName, ResolvedADAccount, Outcome -AutoSize -Wrap |
        Out-Host

    $failedResults = @($results | Where-Object { $_.Outcome -in @('InputFailed', 'Failed') })
    if ($failedResults.Count -gt 0) {
        Write-Host "`nFailure details:" -ForegroundColor Yellow
        $failedResults | Select-Object CsvRow, NamingConvention, RequestedVMName, User, RequestedADAccount, Outcome, Message | Format-List | Out-Host
        throw "$($failedResults.Count) assignment(s) failed. Review the results above."
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
