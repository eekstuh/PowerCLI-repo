<#
.SYNOPSIS
  Interactively create a numbered batch of developer desktop VMs.

.DESCRIPTION
  - Prompts for the 11VMGC, 11VMDEV, or 11VMSAS naming convention
  - Finds the highest existing number and generates the next names
  - Shows the complete plan and requires confirmation before provisioning
  - Avoids PowerCLI ClientMapper / EndProcessing crashes
  - Does NOT rely on New-VM output objects
  - Uses real datastore instead of DatastoreCluster object
  - Sequential provisioning
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
        '11VMGC'  = '11VMGC'
        '11VMDEV' = '11VMDEV'
        '11VMSAS' = '11VMSAS'
    }

    while ($true) {
        Write-Host ''
        Write-Host 'Choose a VM naming convention:' -ForegroundColor Cyan
        Write-Host '  1. 11VMGC'
        Write-Host '  2. 11VMDEV'
        Write-Host '  3. 11VMSAS'

        $selection = (Read-Host 'Enter 1, 2, or 3').Trim().ToUpperInvariant()

        if ($choices.ContainsKey($selection)) {
            return $choices[$selection]
        }

        Write-Warning 'Invalid selection. Enter 1, 2, or 3.'
    }
}

function Read-VmCount {

    $maximumVmCount = 10

    while ($true) {
        $answer = Read-Host "How many new VMs do you want to create? (maximum $maximumVmCount)"
        $count = 0

        if ([int]::TryParse($answer, [ref]$count) -and $count -ge 1 -and $count -le $maximumVmCount) {
            return $count
        }

        Write-Warning "Enter a whole number from 1 through $maximumVmCount."
    }
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
                if ($_.Name -match "^$escapedPrefix(?<Number>\d+)$") {
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

$namePrefix = Read-VmNamePrefix
$vmCount = Read-VmCount
$targetCluster = Get-Cluster -Name $ClusterName -ErrorAction Stop
$plan = Get-NextVmNames -Prefix $namePrefix -Count $vmCount -Cluster $targetCluster
$vmNames = @($plan.Names)

Write-Host ''
if ($plan.LatestNumber -gt 0) {
    Write-Host "Highest existing VM in cluster '$($targetCluster.Name)': $($plan.LatestName)" -ForegroundColor Green
}
else {
    Write-Host "No existing VMs matching $namePrefix<number> were found in cluster '$($targetCluster.Name)'." -ForegroundColor Yellow
}

Write-Host ''
Write-Host "The script will create $($vmNames.Count) VM(s):" -ForegroundColor Cyan
$vmNames | ForEach-Object { Write-Host "  $_" }

Write-Host ''
Write-Host "Template:          $TemplateName"
Write-Host "Cluster:           $ClusterName"
Write-Host "Datastore cluster: $DatastoreClusterName"
Write-Host "Datacenter:        $DatacenterName"
Write-Host "VM folder:         $FolderName"
Write-Host "Power on:          $PowerOnAfterCreate"

$confirmation = (Read-Host 'Do you want to create these VMs? (Y/N)').Trim()
if ($confirmation -notmatch '^(?i:y|yes)$') {
    Write-Host 'Cancelled. No VMs were created.' -ForegroundColor Yellow
    return
}

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

    if (Get-VM -Name $name -Location $targetCluster -ErrorAction SilentlyContinue) {
        Write-Warning "VM '$name' already exists in cluster '$($targetCluster.Name)'"
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
