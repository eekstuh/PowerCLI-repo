#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core
<#
.SYNOPSIS
  Interactively create a numbered batch of developer desktop VMs.

.DESCRIPTION
Creates developer desktop VMs sequentially from the configured template.

Naming:
Choose 11VMDEV, 11VMGC, 11VMSAS, 11VMHIV, or a custom VM name. Numbered naming
finds the highest existing number, including VMs with an assigned-user suffix.

Provisioning:
Displays the complete plan and requires confirmation before creating VMs.
Uses a datastore selected from the datastore cluster. Does not depend on
New-VM output objects, avoiding the associated ClientMapper/EndProcessing
issues.

Connection:
Reuses an active vCenter connection or prompts to establish one.
Enter 'exit' at any text prompt to cancel before VM creation. Select Cancel
at the credential prompt to cancel as well.
.PARAMETER LogPath
CSV path for vSphere disk history. Defaults to C:\Temp\DiskOperations.csv.
Use a secured shared path for history across operators.

.PARAMETER MinimumDatastoreFreePercent
Warn when datastore free space is below this percentage. Default: 10.

.PARAMETER MinimumDatastoreFreeGB
Warn when datastore free space is below this capacity in GB. Default: 50.

.PARAMETER MaximumDatastoreProvisionedPercent
Warn when estimated provisioned capacity exceeds this percentage. Default: 150.

.PARAMETER VIServer
Optional vCenter name. Reuses a matching connection or establishes a new one.

.PARAMETER Credential
Optional vCenter credential used only when a new connection is required.

.EXAMPLE
.\New-DevDesktops-v3.ps1 -WhatIf

#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TemplateName         = 'TMPL-11VM-UEFI',
    [string]$ClusterName          = 'Developer Desktops',
    [string]$DatastoreClusterName = 'PS3KT1-VDI',

    [string]$DatacenterName       = 'Staging',
    [string]$FolderName           = 'Windows Workstations',

    [switch]$PowerOnAfterCreate = $false,
    [string]$LogPath = 'C:\Temp\DiskOperations.csv',
    [ValidateRange(0,100)][decimal]$MinimumDatastoreFreePercent = 10,
    [ValidateRange(0,1000000000)][decimal]$MinimumDatastoreFreeGB = 50,
    [ValidateRange(0,1000000)][decimal]$MaximumDatastoreProvisionedPercent = 150,
    [pscredential]$Credential,
    [string]$VIServer
)

Import-Module (Join-Path $PSScriptRoot 'Modules\PowerCLI.Toolkit.psm1') -Force -ErrorAction Stop
Write-Host ("[i] PowerCLI Toolkit {0}" -f (Get-ToolkitVersion)) -ForegroundColor Gray


# ------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------

function Write-AlignedDetails {
    param([System.Collections.IDictionary]$Details, [int]$Indent = 2, [hashtable]$Colors = @{})
    Write-ToolkitDetails -Details $Details -Indent $Indent -Colors $Colors
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

function Read-ExitAwareInput {
    param(
        [Parameter(Mandatory)] [string]$Prompt,
        [string]$Options
    )

    $hint = if ([string]::IsNullOrWhiteSpace($Options)) {
        "enter 'exit' to cancel"
    }
    else {
        "$Options, or 'exit' to cancel"
    }
    $answer = [string](Read-Host "$Prompt ($hint)")
    $answer = $answer.Trim()
    if ($answer -ieq 'exit') {
        throw [System.OperationCanceledException]::new('Cancelled. No VMs were created.')
    }
    return $answer
}

function Connect-VCenterIfNeeded {
    return Connect-ToolkitVCenter -Name $VIServer -Credential $Credential
}

function Get-ClusterRootResourcePool {

    param([string]$Name)

    $cluster = Get-Cluster -Server $server -ErrorAction Stop | Where-Object Name -ieq $Name

    if (@($cluster).Count -ne 1) { throw 'Expected one exact VM cluster match.' }
    $rp = $cluster |
        Get-ResourcePool -Server $server -ErrorAction Stop |
        Where-Object { $_.ExtensionData.Owner.Type -eq "ClusterComputeResource" } |
        Select-Object -First 1

    if (-not $rp) {
        throw "Root resource pool not found for cluster '$Name'"
    }

    return $rp
}

function Get-OrCreateVmFolder {
    param([string]$DatacenterName, [string]$FolderName)
    $dc = @(Get-Datacenter -Server $server -ErrorAction Stop | Where-Object Name -ieq $DatacenterName)
    if ($dc.Count -ne 1) { throw 'Expected one exact datacenter match.' }
    $folders = @(Get-Folder -Type VM -Location $dc[0] -Server $server -ErrorAction Stop | Where-Object Name -ieq $FolderName)
    if ($folders.Count -gt 1) { throw "More than one VM folder named '$FolderName' exists in the datacenter." }
    if ($folders.Count -eq 1) { return $folders[0] }
    $root = Get-Folder -Id ("Folder-" + $dc[0].ExtensionData.VmFolder.Value) -Server $server -ErrorAction Stop
    return New-Folder -Name $FolderName -Location $root -Server $server -ErrorAction Stop
}

function Get-BestDatastoreFromCluster {

    param([string]$ClusterName)

    $cluster = @(Get-DatastoreCluster -Server $server -ErrorAction Stop | Where-Object Name -ieq $ClusterName)
    if ($cluster.Count -ne 1) { throw 'Expected one exact datastore cluster match.' }

    $ds = Get-Datastore -Location $cluster -Server $server -ErrorAction Stop |
        Where-Object { $_.State -eq "Available" } |
        Sort-Object FreeSpaceGB -Descending |
        Select-Object -First 1

    if (-not $ds) {
        throw "No usable datastore found in cluster '$ClusterName'"
    }

    return $ds
}

function Read-VmNamePrefix {

    $choices = @{
        '1'       = '11VMDEV'
        '2'       = '11VMGC'
        '3'       = '11VMSAS'
        '4'       = '11VMHIV'
        '5'       = 'CUSTOM'
        '11VMGC'  = '11VMGC'
        '11VMDEV' = '11VMDEV'
        '11VMSAS' = '11VMSAS'
        '11VMHIV' = '11VMHIV'
    }

    while ($true) {
        Write-Host 'Select a VM naming convention:' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  1. 11VMDEV'
        Write-Host '  2. 11VMGC'
        Write-Host '  3. 11VMSAS'
        Write-Host '  4. 11VMHIV'
        Write-Host '  5. Custom VM name'
        Write-Host ''

        $selection = (Read-ExitAwareInput -Prompt 'Select an option' -Options '1, 2, 3, 4, 5').ToUpperInvariant()

        if ($choices.ContainsKey($selection)) {
            return $choices[$selection]
        }

        Write-Warning 'Invalid selection. Enter 1, 2, 3, 4, or 5.'
        Write-Host ''
    }
}

function Read-CustomVmName {

    while ($true) {
        $name = Read-ExitAwareInput -Prompt 'Enter a custom VM name'

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Warning 'The custom VM name cannot be blank.'
            Write-Host ''
            continue
        }

        if ($name.IndexOfAny([char[]]'*?[]') -ge 0) {
            Write-Warning 'Wildcard characters (*, ?, [, and ]) are not allowed in a custom VM name.'
            Write-Host ''
            continue
        }

        return $name
    }
}

function Read-VmCount {

    $maximumVmCount = 10

    while ($true) {
        $answer = Read-ExitAwareInput -Prompt 'Enter the number of VMs to create' -Options "1-$maximumVmCount"
        $count = 0

        if ([int]::TryParse($answer, [ref]$count) -and $count -ge 1 -and $count -le $maximumVmCount) {
            return $count
        }

        Write-Warning "Enter a whole number from 1 through $maximumVmCount."
        Write-Host ''
    }
}

function Get-ExistingVmByBaseName {

    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseName,

        [Parameter(Mandatory = $true)]
        [object]$Cluster
    )

    $escapedBaseName = [regex]::Escape($BaseName)
    $validNamePattern = "^$escapedBaseName(?:\s+-\s+.+)?$"

    return @(
        Get-VM -Location $Cluster -Server $server -ErrorAction Stop |
            Where-Object { $_.Name -match $validNamePattern }
    )
}

function Get-NextVmNames {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [int]$Count,

        [Parameter(Mandatory = $true)]
        [object]$Cluster
    )

    $escapedPrefix = [regex]::Escape($Prefix)
    $existingNumbers = @(
        Get-VM -Location $Cluster -Server $server -ErrorAction Stop |
            ForEach-Object {
                if ($_.Name -match "^$escapedPrefix(?<Number>\d+)(?:\s+-\s+.+)?$") {
                    [pscustomobject]@{
                        Name        = $_.Name
                        Number      = [long]$Matches.Number
                        SuffixWidth = $Matches.Number.Length
                    }
                }
            }
    )

    $latest = $existingNumbers |
        Sort-Object Number -Descending |
        Select-Object -First 1

    $latestNumber = if ($latest) { $latest.Number } else { 0 }
    $suffixWidth = if ($latest) { $latest.SuffixWidth } else { 0 }

    $names = @(
        for ($offset = 1; $offset -le $Count; $offset++) {
            $nextNumber = $latestNumber + $offset
            $suffix = if ($suffixWidth -gt 0) {
                $nextNumber.ToString("D$suffixWidth")
            }
            else {
                $nextNumber.ToString()
            }

            "$Prefix$suffix"
        }
    )

    [pscustomobject]@{
        LatestNumber = $latestNumber
        LatestName   = if ($latest) { $latest.Name } else { $null }
        Names        = $names
    }
}

# ------------------------------------------------------------
# BUILD PLAN
# ------------------------------------------------------------

try {
$server = Connect-VCenterIfNeeded
Write-VCenterConnectionDetails -Server $server

$nameSelection = Read-VmNamePrefix
Write-Host ''
$targetCluster = @(Get-Cluster -Server $server -ErrorAction Stop | Where-Object Name -ieq $ClusterName)
if ($targetCluster.Count -ne 1) { throw 'Expected one exact VM cluster match.' }
$targetCluster = $targetCluster[0]

$plan = $null
if ($nameSelection -eq 'CUSTOM') {
    while ($true) {
        $customVmName = Read-CustomVmName
        $existingCustomVm = @(Get-ExistingVmByBaseName -BaseName $customVmName -Cluster $targetCluster)

        if ($existingCustomVm.Count -gt 0) {
            Write-Warning "VM '$($existingCustomVm[0].Name)' already exists in cluster '$($targetCluster.Name)'. Enter another VM name."
            Write-Host ''
            continue
        }

        break
    }

    $vmNames = @($customVmName)
    Write-Host ''
    Write-Host "Custom VM name '$customVmName' is available in cluster '$($targetCluster.Name)'." -ForegroundColor Green
}
else {
    $namePrefix = $nameSelection
    $vmCount = Read-VmCount
    $plan = Get-NextVmNames -Prefix $namePrefix -Count $vmCount -Cluster $targetCluster
    $vmNames = @($plan.Names)

    Write-Host ''
    if ($plan.LatestNumber -gt 0) {
        Write-Host "Highest existing VM in cluster '$($targetCluster.Name)': $($plan.LatestName)" -ForegroundColor Green
    }
    else {
        Write-Host "No existing VMs matching $namePrefix<number> were found in cluster '$($targetCluster.Name)'." -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host "The script will create $($vmNames.Count) VM(s):" -ForegroundColor Cyan
$vmNames | ForEach-Object { Write-Host "  $_" }

Write-Host ''
Write-AlignedDetails -Indent 0 -Details ([ordered]@{
        'Template'          = $TemplateName
        'Cluster'           = $ClusterName
        'Datastore cluster' = $DatastoreClusterName
        'Datacenter'        = $DatacenterName
        'VM folder'         = $FolderName
        'Power on'          = $PowerOnAfterCreate
    })
Write-Host ''

$confirmation = if ($WhatIfPreference) { 'Y' } else { Read-ExitAwareInput -Prompt 'Create the listed VMs? [Y/N]' }
if ($confirmation -notmatch '^(?i:y|yes)$') {
    Write-Host ''
    Write-Host 'Cancelled. No VMs were created.' -ForegroundColor Yellow
    return
}
Write-Host ''

}
catch [System.OperationCanceledException] {
    Write-Host ''
    Write-Host 'Cancelled. No VMs were created.' -ForegroundColor Yellow
    return
}

$template = @(Get-Template -Server $server -ErrorAction Stop | Where-Object Name -ieq $TemplateName)
if ($template.Count -ne 1) { throw 'Expected one exact VM template match.' }
$template = $template[0]
$rootPool = Get-ClusterRootResourcePool -Name $ClusterName
$vmFolder = $null
$targetDatastore = Get-BestDatastoreFromCluster -ClusterName $DatastoreClusterName

Write-Host "Using datastore: $($targetDatastore.Name)" -ForegroundColor Green

# ------------------------------------------------------------
# MAIN LOOP
# ------------------------------------------------------------

for ($index = 0; $index -lt $vmNames.Count; $index++) {

    $name = $vmNames[$index]
    $displayIndex = $index + 1

    $existingVm = @(Get-ExistingVmByBaseName -BaseName $name -Cluster $targetCluster)
    if ($existingVm.Count -gt 0) {
        Write-Warning "VM '$($existingVm[0].Name)' already exists in cluster '$($targetCluster.Name)'"
        continue
    }

    Write-Host ""
    Write-Host "[$displayIndex/$($vmNames.Count)] Creating VM: $name" -ForegroundColor Yellow

    $params = @{
        Name         = $name
        Template     = $template
        ResourcePool = $rootPool
        Datastore    = $targetDatastore
        Server       = $server
        ErrorAction  = 'Stop'
    }

    $creationRecord = $null
    try {

        $targetDatastore = Get-Datastore -Id $targetDatastore.Id -Server $server -ErrorAction Stop
        $templateDisks = @(Get-HardDisk -Template $template -Server $server -ErrorAction Stop)
        $requestedDiskGB = ($templateDisks | Measure-Object CapacityGB -Sum).Sum
        Show-ToolkitDatastoreCapacity -Datastore $targetDatastore -AdditionalGB $requestedDiskGB -StorageFormat Template -MinimumFreePercent $MinimumDatastoreFreePercent -MinimumFreeGB $MinimumDatastoreFreeGB -MaximumProvisionedPercent $MaximumDatastoreProvisionedPercent
        if ($PSCmdlet.ShouldProcess($name, "Create VM and its virtual disks; create target folder if missing")) {
            $vmFolder = Get-OrCreateVmFolder -DatacenterName $DatacenterName -FolderName $FolderName
            $params.Location = $vmFolder
            $recordVM = [pscustomobject]@{Name=$name;Id='';ExtensionData=[pscustomobject]@{Config=[pscustomobject]@{InstanceUuid=''}}}
            $creationRecord = New-ToolkitDiskRecord -VM $recordVM -Server $server -Operation 'CloneVMDisks' -RequestedCapacityGB $requestedDiskGB -OldCapacityGB 0 -ScriptName 'New-DevDesktops-v3.ps1'
            Write-ToolkitCsvRecord -Path $LogPath -Record $creationRecord

            # CRITICAL FIX:
            # Prevent PowerCLI from returning/processing VM object stream
            [void](New-VM @params)

            # Re-query instead of trusting return object
            $createdVMs = @(Get-VM -Location $targetCluster -Server $server -ErrorAction Stop | Where-Object Name -ieq $name)
            if ($createdVMs.Count -ne 1) { throw 'Created VM could not be uniquely verified.' }
            $vm = $createdVMs[0]
            $createdDisks = @(Get-HardDisk -VM $vm -Server $server -ErrorAction Stop)
            $expectedCapacities = @($templateDisks | ForEach-Object { [decimal]$_.CapacityGB } | Sort-Object)
            $actualCapacities = @($createdDisks | ForEach-Object { [decimal]$_.CapacityGB } | Sort-Object)
            if (($expectedCapacities -join ',') -ne ($actualCapacities -join ',')) { throw 'Cloned disk capacities do not match the template.' }
            $creationRecord.VMId = $vm.Id
            $creationRecord.VMInstanceUUID = $vm.ExtensionData.Config.InstanceUuid
            $creationRecord.Cluster = $targetCluster.Name
            $creationRecord.HardDisk = ($createdDisks.Name -join '; ')
            $creationRecord.VMDKPath = ($createdDisks.Filename -join '; ')
            $creationRecord.Datastore = $targetDatastore.Name
            Complete-ToolkitDiskRecord -Path $LogPath -Record $creationRecord -Result 'Success' -VerifiedCapacityGB (($createdDisks | Measure-Object CapacityGB -Sum).Sum)
            $creationRecord = $null

            Write-Host "[OK] Created: $($vm.Name)" -ForegroundColor Green

            if ($PowerOnAfterCreate) {
                Start-VM -VM $vm -Server $server -Confirm:$false -ErrorAction Stop | Out-Null
                $poweredVM = Get-VM -Id $vm.Id -Server $server -ErrorAction Stop
                if ($poweredVM.PowerState -ne 'PoweredOn') { throw 'VM power-on could not be verified.' }
                Write-Host "[OK] Powered on" -ForegroundColor Green
            }
            else {
                Write-Host "(powered off)" -ForegroundColor DarkGray
            }
        }

    }
    catch {
        if ($null -ne $creationRecord) {
            try { Complete-ToolkitDiskRecord -Path $LogPath -Record $creationRecord -Result 'Unverified' -ErrorMessage $_.Exception.Message }
            catch { Write-Warning $_.Exception.Message }
        }
        Write-Host ""
        Write-Host "[ERROR] FAILED: $name" -ForegroundColor Red
        Write-Host "----------------------------------------"

        Write-Host $_.Exception.Message -ForegroundColor Yellow

        if ($_.Exception.InnerException) {
            Write-Host $_.Exception.InnerException.Message -ForegroundColor Yellow
        }

        Write-Host (($_ | Format-List * -Force | Out-String).TrimEnd())
        Write-Host "----------------------------------------"
    }
}

Write-Host ""
Write-Host "DONE" -ForegroundColor Cyan
