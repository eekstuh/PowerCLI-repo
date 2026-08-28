<#
.SYNOPSIS
  Interactively create a numbered batch of developer desktop VMs.

.DESCRIPTION
  - Prompts for the 11VMGC, 11VMDEV, 11VMSAS, or a single custom VM name
  - Finds the highest existing number, including VMs renamed with " - User Name"
  - Shows the complete plan and requires confirmation before provisioning
  - Avoids PowerCLI ClientMapper / EndProcessing crashes
  - Does NOT rely on New-VM output objects
  - Uses real datastore instead of DatastoreCluster object
  - Sequential provisioning
  - Reuses an active vCenter connection or prompts to establish one
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TemplateName         = 'TMPL-11VM-UEFI',
    [string]$ClusterName          = 'Developer Desktops',
    [string]$DatastoreClusterName = 'PS3KT1-VDI',

    [string]$DatacenterName       = 'Staging',
    [string]$FolderName           = 'Windows Workstations',

    [switch]$PowerOnAfterCreate = $false
)

# ------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------

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

function Connect-VCenterIfNeeded {

    $connectionCandidates = @($global:DefaultVIServers) + @($global:DefaultVIServer)
    $activeConnections = @(
        $connectionCandidates |
            Where-Object { $null -ne $_ -and $_.IsConnected } |
            Sort-Object Name -Unique
    )

    if ($activeConnections.Count -gt 0) {
        $connectionNames = $activeConnections.Name -join ', '
        Write-Host "Using existing vCenter connection: $connectionNames" -ForegroundColor Green
        return
    }

    Write-Warning 'No active vCenter connection was found.'
    Write-Host ''
    while ($true) {
        $serverName = (Read-Host 'Enter the vCenter Server host name or IP address').Trim()
        if ([string]::IsNullOrWhiteSpace($serverName)) {
            Write-Warning 'The vCenter Server host name or IP address cannot be blank.'
            Write-Host ''
            continue
        }

        $credential = Get-Credential -Message "Enter credentials for vCenter Server '$serverName'."
        if ($null -eq $credential) {
            Write-Warning 'The credential prompt was cancelled. Enter the vCenter Server host name or IP address to try again.'
            Write-Host ''
            continue
        }

        try {
            [void](Connect-VIServer -Server $serverName -Credential $credential -ErrorAction Stop)
            Write-Host "Connected to vCenter Server: $serverName" -ForegroundColor Green
            return
        }
        catch {
            Write-Warning "Could not connect to vCenter Server '$serverName': $($_.Exception.Message)"
            Write-Host ''
        }
    }
}

function Get-ClusterRootResourcePool {

    param([string]$Name)

    $cluster = Get-Cluster -Name $Name -ErrorAction Stop

    $rp = $cluster |
        Get-ResourcePool |
        Where-Object { $_.ExtensionData.Owner.Type -eq "ClusterComputeResource" } |
        Select-Object -First 1

    if (-not $rp) {
        throw "Root resource pool not found for cluster '$Name'"
    }

    return $rp
}

function Get-OrCreateVmFolder {

    param(
        [string]$DatacenterName,
        [string]$FolderName
    )

    $dc = Get-Datacenter -Name $DatacenterName -ErrorAction Stop

    $folder = Get-Folder -Name $FolderName -Type VM -Location $dc -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $folder) {
        Write-Host "Creating folder '$FolderName'..." -ForegroundColor Cyan
        $folder = New-Folder -Name $FolderName -Location $dc -Type VM -ErrorAction Stop
    }

    return $folder
}

function Get-BestDatastoreFromCluster {

    param([string]$ClusterName)

    $cluster = Get-DatastoreCluster -Name $ClusterName -ErrorAction Stop

    $ds = Get-Datastore -Location $cluster |
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
        '1'       = '11VMGC'
        '2'       = '11VMDEV'
        '3'       = '11VMSAS'
        '4'       = 'CUSTOM'
        '11VMGC'  = '11VMGC'
        '11VMDEV' = '11VMDEV'
        '11VMSAS' = '11VMSAS'
    }

    while ($true) {
        Write-Host ''
        Write-Host 'Select a virtual machine naming convention:' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  1. 11VMGC'
        Write-Host '  2. 11VMDEV'
        Write-Host '  3. 11VMSAS'
        Write-Host '  4. Custom VM name'
        Write-Host ''

        $selection = (Read-Host 'Select an option (1, 2, 3, or 4)').Trim().ToUpperInvariant()

        if ($choices.ContainsKey($selection)) {
            return $choices[$selection]
        }

        Write-Warning 'Invalid selection. Enter 1, 2, 3, or 4.'
        Write-Host ''
    }
}

function Read-CustomVmName {

    while ($true) {
        $name = (Read-Host 'Enter a custom virtual machine name').Trim()

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
        $answer = Read-Host "Enter the number of virtual machines to create (1-$maximumVmCount)"
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
        Get-VM -Name "$BaseName*" -Location $Cluster -ErrorAction SilentlyContinue |
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
        Get-VM -Name "$Prefix*" -Location $Cluster -ErrorAction SilentlyContinue |
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

Connect-VCenterIfNeeded

$nameSelection = Read-VmNamePrefix
Write-Host ''
$targetCluster = Get-Cluster -Name $ClusterName -ErrorAction Stop

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

$confirmation = (Read-Host 'Create the listed virtual machines? [yes/no]').Trim()
if ($confirmation -notmatch '^(?i:y|yes)$') {
    Write-Host ''
    Write-Host 'Cancelled. No VMs were created.' -ForegroundColor Yellow
    return
}
Write-Host ''

$template = Get-Template -Name $TemplateName -ErrorAction Stop
$rootPool = Get-ClusterRootResourcePool -Name $ClusterName
$vmFolder = Get-OrCreateVmFolder -DatacenterName $DatacenterName -FolderName $FolderName
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
        Location     = $vmFolder
        ErrorAction  = 'Stop'
    }

    try {

        if ($PSCmdlet.ShouldProcess($name, "Create VM")) {

            # CRITICAL FIX:
            # Prevent PowerCLI from returning/processing VM object stream
            [void](New-VM @params)

            # Re-query instead of trusting return object
            $vm = Get-VM -Name $name -Location $targetCluster -ErrorAction Stop

            Write-Host "[OK] Created: $($vm.Name)" -ForegroundColor Green

            if ($PowerOnAfterCreate) {
                Start-VM -VM $vm -Confirm:$false | Out-Null
                Write-Host "[OK] Powered on" -ForegroundColor Green
            }
            else {
                Write-Host "(powered off)" -ForegroundColor DarkGray
            }
        }

    }
    catch {

        Write-Host ""
        Write-Host "[ERROR] FAILED: $name" -ForegroundColor Red
        Write-Host "----------------------------------------"

        Write-Host $_.Exception.Message -ForegroundColor Yellow

        if ($_.Exception.InnerException) {
            Write-Host $_.Exception.InnerException.Message -ForegroundColor Yellow
        }

        Write-Host ""
        $_ | Format-List * -Force | Out-String | Write-Host
        Write-Host "----------------------------------------"
    }
}

Write-Host ""
Write-Host "DONE" -ForegroundColor Cyan
