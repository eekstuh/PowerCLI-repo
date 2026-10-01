#requires -Version 5.1
<#
.SYNOPSIS
Opens the PowerCLI toolkit menu and allows repeated workflows.
.DESCRIPTION
Runs scripts in this folder in the current PowerShell session. Existing vCenter
connections are reused; multiple connections require an explicit selection.
After a workflow completes, choose to run it again or return to the menu.
Guest credentials are requested by each workflow and are never saved to disk.
Preview mode passes WhatIf to mutating workflows; inventory scripts remain read-only.
.PARAMETER Preview
Preview infrastructure changes instead of performing them.
.EXAMPLE
.\Start-PowerCLITools.ps1 -Preview
#>
[CmdletBinding()]
param([switch]$Preview)

$entries = @(
    @{Label='Expand a Windows VM disk'; File='Expand-VSphereVmDisk-v3.ps1'; Mutates=$true}
    @{Label='Expand disks across multiple VMs'; File='Expand-MultipleVSphereVmDisks-v1.ps1'; Mutates=$true}
    @{Label='Add or change VM hardware'; File='Add-vHardware-v1.ps1'; Mutates=$true}
    @{Label='Assign a VDI'; File='Assign-VDI-v1.ps1'; Mutates=$true}
    @{Label='Create desktop VMs'; File='New-DevDesktops-v3.ps1'; Mutates=$true}
    @{Label='Show SQL / Windows Server disks'; File='ShowSQLDisk.ps1'; Mutates=$false}
    @{Label='Show ESXi physical switch connections'; File='Get-ESXiVmnicSwitchPorts-v1.ps1'; Mutates=$false}
)
while ($true) {
    Write-Host "`nPowerCLI Tools" -ForegroundColor Cyan
    if ($Preview) { Write-Host '[i] Preview mode is enabled.' -ForegroundColor Yellow }
    Write-Host ''
    for ($i=0; $i -lt $entries.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i+1), $entries[$i].Label) }
    Write-Host ''
    $answer = ([string](Read-Host "Select an option (1-$($entries.Count), or 'exit' to cancel)")).Trim()
    if ($answer -ieq 'exit') { return }
    $choice = 0
    if (-not [int]::TryParse($answer,[ref]$choice) -or $choice -lt 1 -or $choice -gt $entries.Count) {
        Write-Warning 'Select one of the listed options.'
        continue
    }
    $entry = $entries[$choice-1]
    do {
        $arguments = @{}
        if ($Preview -and $entry.Mutates) { $arguments.WhatIf=$true }
        try { & (Join-Path $PSScriptRoot $entry.File) @arguments }
        catch { Write-Warning $_.Exception.Message }
        Write-Host ''
        do {
            $again = ([string](Read-Host "Run this workflow again? [Y/N] (enter 'exit' to cancel)")).Trim()
            if ($again -ieq 'exit') { return }
        } while ($again -notmatch '^(?i:y|yes|n|no)$')
    } while ($again -match '^(?i:y|yes)$')
}
