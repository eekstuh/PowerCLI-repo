#requires -Version 5.1
# Offline verification of the sequential disk-selection workflow.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Expand-VSphereVmDisk-v4.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw

$activeSelection = $source.Substring($source.IndexOf("Write-EnhancedUiPhase -Progress '2/4'"))
if ($activeSelection -match 'Would you like to expand multiple disks at once\?') {
    throw 'The obsolete multi-disk prompt is still present in the active workflow.'
}
if ($activeSelection -notmatch 'Would you like to expand another disk on') {
    throw 'The follow-up disk expansion prompt was not found.'
}
if ($activeSelection -notmatch '\$continueExpanding = Read-YesNo') {
    throw 'The follow-up prompt does not control the expansion loop.'
}
if ($activeSelection -notmatch '\$expandedDisks \+=') {
    throw 'Successful disk expansions are not tracked before the next selection.'
}
Write-Host 'Sequential disk expansion workflow checks passed.'
