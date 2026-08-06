#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core

<#
.SYNOPSIS
Enhanced console interface for the vSphere Windows disk expansion workflow.

.DESCRIPTION
Runs Expand-VSphereVmDisk.ps1 with its Version 2 console experience. All disk,
guest-partition, Recovery-partition, confirmation, and GuestOnly safety behavior
is provided by the shared core script.

.EXAMPLE
.\Expand-VSphereVmDisk-v2.ps1

.EXAMPLE
.\Expand-VSphereVmDisk-v2.ps1 -VMName APP01 -DiskNumber 2 -GBSizeToIncrease 100

.EXAMPLE
.\Expand-VSphereVmDisk-v2.ps1 -VMName APP01 -GuestOnly
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
                throw 'VMName cannot be blank.'
            }
            if ($_.IndexOfAny([char[]]'*?[]') -ge 0) {
                throw 'VMName cannot contain wildcard characters (*, ?, [, or ]).'
            }
            $true
        })]
    [string]$VMName,

    [Parameter()]
    [ValidateRange(1, 2147483647)]
    [int]$DiskNumber,

    [Parameter()]
    [ValidateScript({
            if ($_ -le 0) {
                throw 'GBSizeToIncrease must be greater than zero.'
            }
            $true
        })]
    [decimal]$GBSizeToIncrease,

    [Parameter()]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter()]
    [switch]$GuestOnly
)

$coreScript = Join-Path $PSScriptRoot 'Expand-VSphereVmDisk.ps1'
if (-not (Test-Path -LiteralPath $coreScript -PathType Leaf)) {
    Write-Error "Required core script was not found: $coreScript"
    exit 1
}

& $coreScript @PSBoundParameters -EnhancedUI
exit $LASTEXITCODE
