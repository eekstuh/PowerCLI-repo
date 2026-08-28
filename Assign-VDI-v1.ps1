<#
.SYNOPSIS
Assigns an available developer desktop virtual machine to a user.

.DESCRIPTION
Selects a naming convention and gathers the user's Active Directory account.
The script retrieves the user's full name and consultant status from Active
Directory, finds the highest-numbered assigned virtual machine for the selected
naming convention in the Developer Desktops cluster, and offers powered-on,
unassigned virtual machines with higher numbers in ascending order.

After the operator accepts a virtual machine, the script uses VMware Tools guest
operations to add the user's Active Directory account to the built-in local
Remote Desktop Users group. The vSphere inventory name is changed only after the
guest operation succeeds. The Windows computer name is not changed.

The EXISTING option grants an additional user RDP access to a powered-on VDI
that is already assigned and whose exact vSphere name contains the assignment
delimiter ' - '. This option verifies the guest group membership but never
renames the virtual machine.

If an existing VM name already ends with the same AD full name, the script lists
the matching VM or VMs and asks whether another VDI should be assigned.

After each non-CSV assignment, the script asks whether another VDI should be
assigned and returns to the naming-convention menu when confirmed. CSV mode
processes the imported rows once and does not display this repeat prompt.

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

.PARAMETER ADServer
Optional Active Directory domain controller or domain name used for user
lookups. If omitted, the ActiveDirectory module uses its default domain.

.PARAMETER NamingConvention
Virtual machine assignment option: 11VMGC, 11VMDEV, 11VMSAS, SPECIFIC, or
EXISTING. SPECIFIC assigns an exact unassigned VM name instead of selecting from
the numbered pool. EXISTING grants access to an exact, already-assigned VM name
without renaming it. CUSTOM remains an alias for SPECIFIC, and ASSIGNED remains
an alias for EXISTING.

.PARAMETER VMName
Exact virtual machine name to use with NamingConvention SPECIFIC or EXISTING.
If omitted in interactive mode, the script prompts for it. An EXISTING name must
include its current assignment suffix, such as '11VMDEV501 - First Last Name'.

.PARAMETER ADAccountName
Active Directory account to add to the guest's local Remote Desktop Users group.
A plain sAMAccountName, DOMAIN\username, or user principal name can be supplied.
The script validates the account and retrieves its DisplayName from Active
Directory. When available, the account's canonical user principal name is used
for the VMware Tools guest operation.

.PARAMETER InputCsvPath
Optional path to a CSV file for assigning multiple users. Required columns are
NamingConvention and ADAccountName. Interactive user fields cannot be combined
with InputCsvPath. For a SPECIFIC or EXISTING row, include a VMName column and
the exact virtual machine name. The user's full name and consultant status are
retrieved from Active Directory. Users under OU=noneDOHMHusers are consultants;
users under OU=Agency-Users are not consultants.

.EXAMPLE
.\Assign-VDI-v1.ps1

.EXAMPLE
.\Assign-VDI-v1.ps1 -NamingConvention 11VMDEV -ADAccountName jdoe

.EXAMPLE
.\Assign-VDI-v1.ps1 -NamingConvention SPECIFIC -VMName 11VMDEV501 -ADAccountName jdoe

.EXAMPLE
.\Assign-VDI-v1.ps1 -NamingConvention EXISTING -VMName '11VMDEV501 - Primary User' -ADAccountName secondaryuser

Grants secondaryuser RDP access to the already-assigned VDI and leaves the VM
name unchanged.

.EXAMPLE
.\Assign-VDI-v1.ps1 -InputCsvPath .\DesktopAssignments.csv

The CSV format is:
NamingConvention,VMName,ADAccountName
11VMGC,,jdoe
SPECIFIC,11VMDEV501,CONTOSO\jsmith
EXISTING,"11VMDEV502 - Primary User",CONTOSO\secondaryuser
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

    [Parameter()]
    [string]$ADServer,

    [Parameter(ParameterSetName = 'Interactive')]
    [ValidateSet('11VMGC', '11VMDEV', '11VMSAS', 'SPECIFIC', 'CUSTOM', 'EXISTING', 'ASSIGNED')]
    [string]$NamingConvention,

    [Parameter(ParameterSetName = 'Interactive')]
    [string]$VMName,

    [Parameter(ParameterSetName = 'Interactive')]
    [string]$ADAccountName,

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
$adAccountWasSupplied = $PSBoundParameters.ContainsKey('ADAccountName')

function Write-Banner {
    $line = '=' * 76
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host '  VDI Assignment Assistant - Version 1.0' -ForegroundColor Cyan
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
        $answer = Read-ExitAwareInput -Prompt "$Prompt [Y/N]"
        Stop-IfExitRequested

        switch -Regex ($answer) {
            '^(?i:y|yes)$' { return $true }
            '^(?i:n|no)$'  { return $false }
            default { Write-Warning "Enter Y, N, or 'exit'." }
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
        if ($NamingConvention -ieq 'ASSIGNED') {
            return 'EXISTING'
        }
        return $NamingConvention.ToUpperInvariant()
    }

    while ($true) {
        Write-Host "`nSelect a VDI assignment option:" -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  1. 11VMGC'
        Write-Host '  2. 11VMDEV'
        Write-Host '  3. 11VMSAS'
        Write-Host '  4. Specify VM name'
        Write-Host '  5. Add an additional user to already assigned VDI (VM will not be renamed)'
        Write-Host ''

        $selection = Read-ExitAwareInput -Prompt 'Select an option (1, 2, 3, 4, or 5)'
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
            '5'        { return 'EXISTING' }
            'EXISTING' { return 'EXISTING' }
            'ASSIGNED' { return 'EXISTING' }
            default { Write-Warning 'Select option 1, 2, 3, 4, or 5.' }
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

function Initialize-ActiveDirectoryModule {
    if ($null -ne (Get-Command -Name Get-ADUser -ErrorAction SilentlyContinue)) {
        return
    }

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    }
    catch {
        throw "The ActiveDirectory PowerShell module is required to retrieve user names. Install the RSAT Active Directory tools and try again. $($_.Exception.Message)"
    }
}

function ConvertTo-LdapFilterValue {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace(([char]0).ToString(), '\00')
}

function Resolve-ConsultantStatusFromDistinguishedName {
    param(
        [Parameter(Mandatory)]
        [string]$DistinguishedName,

        [Parameter(Mandatory)]
        [string]$Context
    )

    $isConsultantOU = [regex]::IsMatch($DistinguishedName, '(?i)(?:^|,)\s*OU=noneDOHMHusers\s*(?:,|$)')
    $isAgencyOU = [regex]::IsMatch($DistinguishedName, '(?i)(?:^|,)\s*OU=Agency-Users\s*(?:,|$)')

    if ($isConsultantOU -and $isAgencyOU) {
        throw "$Context is under both OU=noneDOHMHusers and OU=Agency-Users. Consultant status is ambiguous."
    }
    if (-not $isConsultantOU -and -not $isAgencyOU) {
        throw "$Context is not under OU=noneDOHMHusers or OU=Agency-Users. Consultant status cannot be determined."
    }

    return [pscustomobject]@{
        Consultant = $isConsultantOU
        SourceOU   = if ($isConsultantOU) { 'OU=noneDOHMHusers' } else { 'OU=Agency-Users' }
    }
}

function Get-CommonNameFromDistinguishedName {
    param(
        [Parameter(Mandatory)]
        [string]$DistinguishedName
    )

    $commonNameMatch = [regex]::Match($DistinguishedName, '^(?i:CN)=(?<Value>(?:\\[0-9A-Fa-f]{2}|\\.|[^,])+)')
    if (-not $commonNameMatch.Success) {
        return ''
    }

    $commonName = $commonNameMatch.Groups['Value'].Value
    $commonName = [regex]::Replace(
        $commonName,
        '\\(?<Hex>[0-9A-Fa-f]{2})',
        { param($match) [char][Convert]::ToInt32($match.Groups['Hex'].Value, 16) }
    )
    return [regex]::Replace($commonName, '\\(.)', '$1')
}

function Resolve-ActiveDirectoryUser {
    param(
        [Parameter(Mandatory)]
        [string]$AccountName,

        [Parameter(Mandatory)]
        [string]$Context
    )

    Initialize-ActiveDirectoryModule
    $lookupAccount = $AccountName.Trim()
    $queryParameters = @{
        # Name, DistinguishedName, SID, sAMAccountName, and UPN are included in
        # the standard Get-ADUser result. Request only the additional field.
        Properties  = @('DisplayName')
        ErrorAction = 'Stop'
    }
    if (-not [string]::IsNullOrWhiteSpace($ADServer)) {
        $queryParameters.Server = $ADServer
    }

    try {
        $adUsers = @(
            if ($lookupAccount -match '@') {
                $escapedUpn = ConvertTo-LdapFilterValue -Value $lookupAccount
                Get-ADUser -LDAPFilter "(userPrincipalName=$escapedUpn)" @queryParameters
            }
            else {
                $identity = if ($lookupAccount -match '^[^\\]+\\(?<SamAccountName>.+)$') {
                    $Matches['SamAccountName']
                }
                else {
                    $lookupAccount
                }
                Get-ADUser -Identity $identity @queryParameters
            }
        )
    }
    catch {
        throw "$Context '$lookupAccount' could not be resolved in Active Directory. $($_.Exception.Message)"
    }

    if ($adUsers.Count -eq 0) {
        throw "$Context '$lookupAccount' was not found in Active Directory."
    }
    if ($adUsers.Count -gt 1) {
        throw "$Context '$lookupAccount' matched more than one Active Directory user."
    }

    $adUser = $adUsers[0]
    $distinguishedName = [string]$adUser.DistinguishedName
    if ([string]::IsNullOrWhiteSpace($distinguishedName)) {
        $returnedProperties = @($adUser.PSObject.Properties.Name | Sort-Object) -join ', '
        throw "$Context '$lookupAccount' does not have a usable DistinguishedName in the returned Active Directory object. Returned properties: $returnedProperties"
    }

    $resolvedFullName = [regex]::Replace(([string]$adUser.DisplayName).Trim(), '\s+', ' ')
    $fullNameSource = 'DisplayName'
    if ([string]::IsNullOrWhiteSpace($resolvedFullName)) {
        $resolvedFullName = [regex]::Replace(([string]$adUser.Name).Trim(), '\s+', ' ')
        $fullNameSource = 'Name'
    }
    if ([string]::IsNullOrWhiteSpace($resolvedFullName)) {
        $resolvedFullName = [regex]::Replace(("$($adUser.GivenName) $($adUser.Surname)").Trim(), '\s+', ' ')
        $fullNameSource = 'GivenName and Surname'
    }
    if ([string]::IsNullOrWhiteSpace($resolvedFullName)) {
        $resolvedFullName = [regex]::Replace((Get-CommonNameFromDistinguishedName -DistinguishedName $distinguishedName).Trim(), '\s+', ' ')
        $fullNameSource = 'DistinguishedName CN'
    }
    if ([string]::IsNullOrWhiteSpace($resolvedFullName)) {
        throw "$Context '$lookupAccount' does not have a usable DisplayName, Name, GivenName/Surname, or CN in Active Directory."
    }
    if ($resolvedFullName -match '\s+-\s+') {
        throw "$Context '$lookupAccount' has the Active Directory display name '$resolvedFullName', which contains the reserved assignment delimiter ' - '."
    }

    $resolvedSid = [string]$adUser.SID
    if ([string]::IsNullOrWhiteSpace($resolvedSid)) {
        throw "$Context '$lookupAccount' does not have a usable SID in Active Directory."
    }

    $guestAccountName = if (-not [string]::IsNullOrWhiteSpace([string]$adUser.UserPrincipalName)) {
        [string]$adUser.UserPrincipalName
    }
    elseif ($lookupAccount -match '\\') {
        $lookupAccount
    }
    else {
        [string]$adUser.SamAccountName
    }
    if ([string]::IsNullOrWhiteSpace($guestAccountName)) {
        throw "$Context '$lookupAccount' does not have a usable account name in Active Directory."
    }

    $consultantStatus = Resolve-ConsultantStatusFromDistinguishedName -DistinguishedName $distinguishedName -Context "$Context '$lookupAccount'"

    return [pscustomobject]@{
        FullName         = $resolvedFullName
        FullNameSource   = $fullNameSource
        GuestAccountName = $guestAccountName
        SID              = $resolvedSid
        Consultant       = $consultantStatus.Consultant
        ConsultantOU     = $consultantStatus.SourceOU
    }
}

function Resolve-InteractiveActiveDirectoryUser {
    $candidateAccount = $ADAccountName
    $accountWasSupplied = $adAccountWasSupplied

    while ($true) {
        $resolvedAccount = Resolve-RequiredText -InitialValue $candidateAccount -WasSupplied $accountWasSupplied -Prompt "Enter the user's SamAccountName" -FieldName 'Active Directory account name'
        try {
            $adUser = Resolve-ActiveDirectoryUser -AccountName $resolvedAccount -Context 'Active Directory account'
            $consultantLabel = if ($adUser.Consultant) { 'Yes' } else { 'No' }
            Write-Host ''
            Write-AlignedDetails -Indent 0 -Details ([ordered]@{
                    'Resolved Active Directory user' = "$($adUser.FullName) [$($adUser.GuestAccountName)]"
                    'Consultant'                     = $consultantLabel
                }) -Colors @{
                    'Resolved Active Directory user' = 'Green'
                    'Consultant'                     = 'Green'
                }
            return $adUser
        }
        catch {
            Write-Warning $_.Exception.Message
            $candidateAccount = ''
            $accountWasSupplied = $false
        }
    }
}

function Get-AssignmentWorkItems {
    if ($script:InvocationParameterSet -eq 'Interactive') {
        $selectedPrefix = Read-NamingConvention
        $requestedVMName = if ($selectedPrefix -eq 'SPECIFIC') {
            Resolve-RequiredText -InitialValue $VMName -WasSupplied $vmNameWasSupplied -Prompt 'Enter the exact unassigned VM name' -FieldName 'Virtual machine name' -RejectAssignmentDelimiter
        }
        elseif ($selectedPrefix -eq 'EXISTING') {
            Resolve-RequiredText -InitialValue $VMName -WasSupplied $vmNameWasSupplied -Prompt 'Enter the exact name of the assigned VDI' -FieldName 'Virtual machine name'
        }
        else {
            if ($vmNameWasSupplied) {
                throw 'VMName can be used only when NamingConvention is SPECIFIC, CUSTOM, EXISTING, or ASSIGNED.'
            }
            ''
        }
        $resolvedADUser = Resolve-InteractiveActiveDirectoryUser

        return @(
            [pscustomobject]@{
                RowNumber        = $null
                NamingConvention = $selectedPrefix
                RequestedVMName  = $requestedVMName
                FullName         = $resolvedADUser.FullName
                ADAccountName    = $resolvedADUser.GuestAccountName
                ADUserSID        = $resolvedADUser.SID
                Consultant       = $resolvedADUser.Consultant
                ConsultantOU     = $resolvedADUser.ConsultantOU
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

    $requiredColumns = @('NamingConvention', 'ADAccountName')
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
            elseif ($prefix -eq 'ASSIGNED') {
                $prefix = 'EXISTING'
            }
            if ($prefix -notin @('11VMGC', '11VMDEV', '11VMSAS', 'SPECIFIC', 'EXISTING')) {
                throw "CSV row $rowNumber has an invalid NamingConvention '$($row.NamingConvention)'. Use 11VMGC, 11VMDEV, 11VMSAS, SPECIFIC, or EXISTING."
            }

            $requestedVMName = if ($prefix -eq 'SPECIFIC') {
                Resolve-RequiredText -InitialValue ([string]$row.VMName) -WasSupplied $true -Prompt '' -FieldName "CSV row $rowNumber VMName" -RejectAssignmentDelimiter
            }
            elseif ($prefix -eq 'EXISTING') {
                Resolve-RequiredText -InitialValue ([string]$row.VMName) -WasSupplied $true -Prompt '' -FieldName "CSV row $rowNumber VMName"
            }
            else { '' }

            $resolvedADAccount = Resolve-RequiredText -InitialValue ([string]$row.ADAccountName) -WasSupplied $true -Prompt '' -FieldName "CSV row $rowNumber ADAccountName"
            $resolvedADUser = Resolve-ActiveDirectoryUser -AccountName $resolvedADAccount -Context "CSV row $rowNumber ADAccountName"

            [pscustomobject]@{
                RowNumber        = $rowNumber
                NamingConvention = $prefix
                RequestedVMName  = $requestedVMName
                FullName         = $resolvedADUser.FullName
                ADAccountName    = $resolvedADUser.GuestAccountName
                ADUserSID        = $resolvedADUser.SID
                Consultant       = $resolvedADUser.Consultant
                ConsultantOU     = $resolvedADUser.ConsultantOU
                ValidationError  = $null
            }
        }
        catch {
            [pscustomobject]@{
                RowNumber        = $rowNumber
                NamingConvention = [string]$row.NamingConvention
                RequestedVMName  = [string]$row.VMName
                FullName         = ''
                ADAccountName    = [string]$row.ADAccountName
                ADUserSID        = ''
                Consultant       = $null
                ConsultantOU     = ''
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
        User               = [string]$WorkItem.FullName
        Consultant         = if ($null -eq $WorkItem.Consultant) { 'Unknown' } elseif ([bool]$WorkItem.Consultant) { 'Yes' } else { 'No' }
        ConsultantOU       = [string]$WorkItem.ConsultantOU
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

function Confirm-DuplicateUserAssignment {
    param(
        [Parameter(Mandatory)]
        [object[]]$VirtualMachines,

        [Parameter(Mandatory)]
        [string]$FullName
    )

    $escapedPersonName = [regex]::Escape($FullName)
    $pattern = "^.+\s+-\s+(?:Consultant\s+)?$escapedPersonName$"
    $matches = @($VirtualMachines | Where-Object { $_.Name -match $pattern })
    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            Confirmed       = $true
            IsDuplicate     = $false
            ExistingVMNames = @()
        }
    }

    $names = @($matches.Name | Sort-Object)
    Write-Warning "A virtual machine assignment for '$FullName' already exists in the cluster: $($names -join ', ')"
    $confirmed = Read-YesNo -Prompt "Are you sure you want to assign another VDI to '$FullName'?"
    if ($confirmed) {
        Write-Host "Duplicate VDI assignment authorized for '$FullName'." -ForegroundColor Yellow
    }

    return [pscustomobject]@{
        Confirmed       = $confirmed
        IsDuplicate     = $true
        ExistingVMNames = $names
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
    $candidates = @(
        $Inventory |
            Where-Object {
                -not $_.IsAssigned -and
                $_.Number -gt $latestAssigned.Number -and
                $_.PowerState -eq 'PoweredOn'
            } |
            Sort-Object Number, Name
    )

    $assignmentRangeDetails = [ordered]@{
        'Latest assigned virtual machine' = $latestAssigned.Name
    }
    $assignmentRangeColors = @{
        'Latest assigned virtual machine' = 'Green'
    }
    if ($oldUnassigned.Count -gt 0) {
        $assignmentRangeDetails['Ignored older unassigned VMs'] = $oldUnassigned.Count
        $assignmentRangeColors['Ignored older unassigned VMs'] = 'DarkGray'
    }
    Write-Host ''
    Write-AlignedDetails -Indent 0 -Details $assignmentRangeDetails -Colors $assignmentRangeColors

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
        Write-AlignedDetails -Details ([ordered]@{
                'Current VM name'  = $vm.Name
                'Assigned VM name' = $targetName
                'AD account'       = $ADAccount
            })
        Write-Host ''
        if (Read-YesNo -Prompt "Use VM '$($vm.Name)' for this assignment?") {
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
        $vmMatches = @($AllVirtualMachines | Where-Object { $_.Name -ieq $requestedName })
        $validationMessage = $null
        if ($vmMatches.Count -eq 0) {
            $validationMessage = "Virtual machine '$requestedName' was not found in the cluster."
        }
        elseif ($vmMatches.Count -gt 1) {
            $validationMessage = "More than one virtual machine is named '$requestedName' in the cluster."
        }
        elseif ($vmMatches[0].Name -match '\s+-\s+.+$') {
            $validationMessage = "Virtual machine '$($vmMatches[0].Name)' already appears to be assigned."
        }
        elseif ([string]$vmMatches[0].PowerState -ne 'PoweredOn') {
            $validationMessage = "Virtual machine '$($vmMatches[0].Name)' is not powered on."
        }

        if ($null -ne $validationMessage) {
            if (-not $AllowNameCorrection) {
                throw $validationMessage
            }
            Write-Warning $validationMessage
            $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact VM name to assign' -FieldName 'Virtual machine name' -RejectAssignmentDelimiter
            continue
        }

        $vm = Get-RefreshedCandidate -Candidate ([pscustomobject]@{ VM = $vmMatches[0] }) -Server $Server
        if ($null -eq $vm) {
            if (-not $AllowNameCorrection) {
                throw "Virtual machine '$requestedName' does not currently meet the assignment requirements."
            }
            $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact VM name to assign' -FieldName 'Virtual machine name' -RejectAssignmentDelimiter
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
            $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact VM name to assign' -FieldName 'Virtual machine name' -RejectAssignmentDelimiter
            continue
        }

        Write-Host "`nProposed assignment:" -ForegroundColor Cyan
        Write-AlignedDetails -Details ([ordered]@{
                'Current VM name'  = $vm.Name
                'Assigned VM name' = $targetName
                'AD account'       = $ADAccount
            })
        Write-Host ''
        if (Read-YesNo -Prompt "Use VM '$($vm.Name)' for this assignment?") {
            return [pscustomobject]@{
                VM         = $vm
                TargetName = $targetName
            }
        }

        if (-not $AllowNameCorrection) {
            return $null
        }
        Write-Host "Skipped '$($vm.Name)'." -ForegroundColor Yellow
        $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact VM name to assign' -FieldName 'Virtual machine name' -RejectAssignmentDelimiter
    }
}

function Select-ExistingAssignmentVM {
    param(
        [Parameter(Mandatory)]
        [string]$InitialVMName,

        [Parameter(Mandatory)]
        [object[]]$AllVirtualMachines,

        [Parameter(Mandatory)]
        [object]$Server,

        [Parameter(Mandatory)]
        [string]$ADAccount,

        [Parameter()]
        [switch]$AllowNameCorrection
    )

    $requestedName = $InitialVMName
    while ($true) {
        $vmMatches = @($AllVirtualMachines | Where-Object { $_.Name -ieq $requestedName })
        $validationMessage = $null
        if ($vmMatches.Count -eq 0) {
            $validationMessage = "Virtual machine '$requestedName' was not found in the cluster."
        }
        elseif ($vmMatches.Count -gt 1) {
            $validationMessage = "More than one virtual machine is named '$requestedName' in the cluster."
        }
        elseif ($vmMatches[0].Name -notmatch '\s+-\s+.+$') {
            $validationMessage = "Virtual machine '$($vmMatches[0].Name)' does not appear to be assigned. Use option 4 to assign an unassigned VDI."
        }
        elseif ([string]$vmMatches[0].PowerState -ne 'PoweredOn') {
            $validationMessage = "Virtual machine '$($vmMatches[0].Name)' is not powered on."
        }

        if ($null -ne $validationMessage) {
            if (-not $AllowNameCorrection) {
                throw $validationMessage
            }
            Write-Warning $validationMessage
            $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact assigned VDI name' -FieldName 'Virtual machine name'
            continue
        }

        $vm = Get-RefreshedCandidate -Candidate ([pscustomobject]@{ VM = $vmMatches[0] }) -Server $Server
        if ($null -eq $vm) {
            if (-not $AllowNameCorrection) {
                throw "Virtual machine '$requestedName' does not currently meet the access-assignment requirements."
            }
            $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact assigned VDI name' -FieldName 'Virtual machine name'
            continue
        }

        if ($vm.Name -ine $requestedName -or $vm.Name -notmatch '\s+-\s+.+$') {
            $validationMessage = "Virtual machine '$requestedName' changed in vSphere while it was being selected. Its current name is '$($vm.Name)'."
            if (-not $AllowNameCorrection) {
                throw $validationMessage
            }
            Write-Warning $validationMessage
            $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact assigned VDI name' -FieldName 'Virtual machine name'
            continue
        }

        Write-Host "`nProposed additional access assignment:" -ForegroundColor Cyan
        Write-AlignedDetails -Details ([ordered]@{
                'Existing VDI name' = $vm.Name
                'New AD account'    = $ADAccount
                'vSphere rename'    = 'No - the existing name will be preserved'
            })
        if (Read-YesNo -Prompt "Grant '$ADAccount' RDP access to assigned VDI '$($vm.Name)'?") {
            return [pscustomobject]@{
                VM         = $vm
                TargetName = $vm.Name
            }
        }

        if (-not $AllowNameCorrection) {
            return $null
        }
        Write-Host "Skipped '$($vm.Name)'." -ForegroundColor Yellow
        $requestedName = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt 'Enter another exact assigned VDI name' -FieldName 'Virtual machine name'
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

    $guestUserName = Read-ExitAwareInput -Prompt 'Enter your Windows Desktop Administrator credentials to proceed'
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
        [string]$InitialAccountName,

        [Parameter(Mandatory)]
        [string]$ExpectedADUserSID
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
            while ($true) {
                $correctedAccount = Resolve-RequiredText -InitialValue '' -WasSupplied $false -Prompt "Enter the correct Active Directory account for '$($VM.Name)'" -FieldName 'Active Directory account name'
                try {
                    $correctedADUser = Resolve-ActiveDirectoryUser -AccountName $correctedAccount -Context 'Corrected Active Directory account'
                }
                catch {
                    Write-Warning $_.Exception.Message
                    continue
                }

                if ([string]$correctedADUser.SID -ne $ExpectedADUserSID) {
                    Write-Warning "The corrected account belongs to '$($correctedADUser.FullName)', not the selected Active Directory user. Enter another account for the same user."
                    continue
                }

                $accountName = $correctedADUser.GuestAccountName
                break
            }
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
    Initialize-ActiveDirectoryModule
    $results = @()
    $continueAssignmentSession = $true

    while ($continueAssignmentSession) {
        $workItems = @(Get-AssignmentWorkItems)

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
            $personName = [string]$workItem.FullName
            $assignmentLabel = if ([bool]$workItem.Consultant) { "Consultant $personName" } else { $personName }
            $allVirtualMachines = @(Get-VM -Location $cluster -Server $server -ErrorAction Stop)
            $duplicateDecision = Confirm-DuplicateUserAssignment -VirtualMachines $allVirtualMachines -FullName $workItem.FullName
            if (-not $duplicateDecision.Confirmed) {
                $message = "Duplicate VDI assignment was not authorized. Existing assignment(s): $($duplicateDecision.ExistingVMNames -join ', ')"
                Write-Host "$message No changes were made for '$personName'." -ForegroundColor Yellow
                $results += New-AssignmentResult -WorkItem $workItem -Outcome 'Skipped' -Message $message
                continue
            }

            if ($workItem.NamingConvention -eq 'EXISTING') {
                $existingSelectionParameters = @{
                    InitialVMName      = $workItem.RequestedVMName
                    AllVirtualMachines = $allVirtualMachines
                    Server             = $server
                    ADAccount          = $workItem.ADAccountName
                }
                if ($script:InvocationParameterSet -eq 'Interactive') {
                    $existingSelectionParameters.AllowNameCorrection = $true
                }
                $selection = Select-ExistingAssignmentVM @existingSelectionParameters
            }
            elseif ($workItem.NamingConvention -eq 'SPECIFIC') {
                $specificSelectionParameters = @{
                    InitialVMName      = $workItem.RequestedVMName
                    AllVirtualMachines = $allVirtualMachines
                    Server             = $server
                    AssignmentLabel    = $assignmentLabel
                    ADAccount          = $workItem.ADAccountName
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
                $message = if ($workItem.NamingConvention -in @('SPECIFIC', 'EXISTING')) { 'The specified virtual machine was not selected.' } else { 'All available candidates were skipped by the operator.' }
                Write-Host "$message No changes were made for '$personName'." -ForegroundColor Yellow
                $results += New-AssignmentResult -WorkItem $workItem -Outcome 'Skipped' -Message $message
                continue
            }

            if ($workItem.NamingConvention -in @('SPECIFIC', 'EXISTING')) {
                $workItem.RequestedVMName = $selection.VM.Name
            }
            $selectedVM = $selection.VM
            $targetVMName = $selection.TargetName
            $renameRequired = $workItem.NamingConvention -ne 'EXISTING'
            $requestedAction = if ($renameRequired) {
                "Grant RDP access to '$($workItem.ADAccountName)' and rename the VM to '$targetVMName'"
            }
            else {
                "Grant RDP access to '$($workItem.ADAccountName)' without renaming the VM"
            }
            if (-not $PSCmdlet.ShouldProcess($selectedVM.Name, $requestedAction)) {
                $results += New-AssignmentResult -WorkItem $workItem -Outcome 'WhatIf' -Message 'No changes were requested by ShouldProcess.' -VMName $selectedVM.Name
                continue
            }

            $guestAdminCredential = Get-WindowsGuestCredential
            Write-Host "`nGranting RDP Access inside '$($selectedVM.Name)'..." -ForegroundColor Cyan
            $accountResult = Add-GuestRemoteDesktopUserWithCorrection -VM $selectedVM -Credential $guestAdminCredential -InitialAccountName $workItem.ADAccountName -ExpectedADUserSID $workItem.ADUserSID
            $guestResult = $accountResult.GuestResult
            if (-not [bool]$guestResult.Verified) {
                throw 'Remote Desktop Users membership verification was not successful.'
            }
            if ([string]$guestResult.AccountSID -ne [string]$workItem.ADUserSID) {
                if ([bool]$guestResult.Added) {
                    [void](Remove-GuestRemoteDesktopUser -VM $selectedVM -Credential $guestAdminCredential -AccountSID ([string]$guestResult.AccountSID))
                }
                throw 'The Windows guest resolved a different Active Directory user SID than the account selected on the management system. No vSphere rename was performed.'
            }

            if ([bool]$guestResult.Added) {
                Write-Host "Added '$($guestResult.Account)' to local group '$($guestResult.Group)'." -ForegroundColor Green
            }
            else {
                Write-Host "'$($guestResult.Account)' was already a member of local group '$($guestResult.Group)'." -ForegroundColor Green
            }
            Write-Host "Verified '$($guestResult.Account)' as a member of '$($guestResult.Group)'." -ForegroundColor Green

            if ($renameRequired) {
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
            }

            $script:CompletedAssignments++
            if ($renameRequired) {
                Write-Host "Assignment completed successfully for '$personName' on '$targetVMName'." -ForegroundColor Green
                $completionMessage = 'RDP access and the vSphere rename were verified.'
            }
            else {
                Write-Host "Additional RDP access was verified for '$personName' on '$targetVMName'. The vSphere VM name was not changed." -ForegroundColor Green
                $completionMessage = 'Additional RDP access was verified; the vSphere VM name was not changed.'
            }
            $results += New-AssignmentResult -WorkItem $workItem -Outcome 'Completed' -Message $completionMessage -VMName $targetVMName -ResolvedADAccount $guestResult.Account
            }
            catch {
                $message = $_.Exception.Message
                $failedUser = if ([string]::IsNullOrWhiteSpace([string]$workItem.FullName)) { $workItem.ADAccountName } else { $workItem.FullName }
                Write-Warning "Assignment failed for '$failedUser': $message"
                $results += New-AssignmentResult -WorkItem $workItem -Outcome 'Failed' -Message $message -VMName $(if ($null -ne $selectedVM) { $selectedVM.Name } else { '' }) -ResolvedADAccount $(if ($null -ne $guestResult) { [string]$guestResult.Account } else { '' })
            }
        }

        if ($script:InvocationParameterSet -eq 'Interactive') {
            Write-Host ''
            $continueAssignmentSession = Read-YesNo -Prompt 'Would you like to assign another VDI to a user account?'
            if ($continueAssignmentSession) {
                $namingConventionWasSupplied = $false
                $vmNameWasSupplied = $false
                $adAccountWasSupplied = $false
                Write-Banner
                Write-Host "Continuing with vCenter Server '$($server.Name)' and cluster '$($cluster.Name)'." -ForegroundColor Green
            }
        }
        else {
            $continueAssignmentSession = $false
        }
    }

    Write-Host "`nAssignment results:" -ForegroundColor Cyan
    $results |
        Format-Table CsvRow, User, Consultant, VMName, ResolvedADAccount, Outcome -AutoSize -Wrap |
        Out-Host

    $failedResults = @($results | Where-Object { $_.Outcome -in @('InputFailed', 'Failed') })
    if ($failedResults.Count -gt 0) {
        Write-Host "`nFailure details:" -ForegroundColor Yellow
        $failedResults | Select-Object CsvRow, NamingConvention, RequestedVMName, User, Consultant, ConsultantOU, RequestedADAccount, Outcome, Message | Format-List | Out-Host
        throw "$($failedResults.Count) assignment(s) failed. Review the results above."
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
