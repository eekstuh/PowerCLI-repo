<#
.SYNOPSIS
  Bulk VM creation from CSV using a template (hardened PowerCLI-safe version)

.DESCRIPTION
  - Avoids PowerCLI ClientMapper / EndProcessing crashes
  - Does NOT rely on New-VM output objects
  - Uses real datastore instead of DatastoreCluster object
  - Sequential provisioning
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

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

# ------------------------------------------------------------
# VALIDATION
# ------------------------------------------------------------

if (-not (Test-Path $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

$template = Get-Template -Name $TemplateName -ErrorAction Stop
$rootPool = Get-ClusterRootResourcePool -Name $ClusterName
$vmFolder = Get-OrCreateVmFolder -DatacenterName $DatacenterName -FolderName $FolderName
$targetDatastore = Get-BestDatastoreFromCluster -ClusterName $DatastoreClusterName

$rows = Import-Csv $CsvPath

if (-not $rows) {
    throw "CSV is empty"
}

Write-Host "Using datastore: $($targetDatastore.Name)" -ForegroundColor Green

# ------------------------------------------------------------
# MAIN LOOP
# ------------------------------------------------------------

$index = 0

foreach ($row in $rows) {

    $index++
    $name = $row.Name

    if (-not $name) {
        Write-Warning "Row $index missing name"
        continue
    }

    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        Write-Warning "VM '$name' already exists"
        continue
    }

    Write-Host ""
    Write-Host "[$index/$($rows.Count)] Creating VM: $name" -ForegroundColor Yellow

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
            $vm = Get-VM -Name $name -ErrorAction Stop

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
