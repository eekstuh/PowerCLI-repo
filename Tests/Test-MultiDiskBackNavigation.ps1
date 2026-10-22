#requires -Version 5.1
# Offline navigation checks. No vCenter connection or disk changes.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Expand-VSphereVmDisk-v4.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
$definition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-MultipleDiskExpansion'
}, $true)
. ([scriptblock]::Create($definition.Extent.Text))
function Get-HardDisk { param($VM, $Server, $ErrorAction) [pscustomobject]@{ Name = 'Hard disk 1' } }
function Read-ExitAwareInput {
    param($Prompt, $PromptOptions)
    if ($PromptOptions -notmatch "'back'") { throw 'Back option is missing from the prompt.' }
    return 'BACK'
}
function Stop-IfExitRequested {}
function Set-HardDisk { throw 'Navigation must not resize a disk.' }
$script:MultiDiskMode = $true
$script:MultiDiskModeAsked = $true
$result = Invoke-MultipleDiskExpansion -VM ([pscustomobject]@{Name='TestVM'}) -Server 'TestServer' -Workflow 'Windows'
if ($result -ne 'Back' -or $script:MultiDiskMode -or $script:MultiDiskModeAsked) {
    throw 'Back must return to mode selection and reset both mode flags.'
}

# Exercise the caller loop: returning Back must repeat selection, then allow a single disk.
$selectionLoop = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.WhileStatementAst] -and
        $node.Extent.Text -match '\$multiDiskResult = Invoke-MultipleDiskExpansion'
}, $true)
if ($null -eq $selectionLoop) { throw 'Disk selection navigation loop was not found.' }
$script:selectionCount = 0
function Select-HardDisk {
    $script:selectionCount++
    if ($script:selectionCount -gt 2) { throw 'Navigation did not leave the selection loop.' }
    $script:MultiDiskMode = $script:selectionCount -eq 1
    if (-not $script:MultiDiskMode) { return [pscustomobject]@{Name='Hard disk 2'} }
}
$diskArguments = @{}
$vm = [pscustomobject]@{Name='TestVM'}
$server = 'TestServer'
$workflow = 'Windows'
. ([scriptblock]::Create($selectionLoop.Extent.Text))
if ($script:selectionCount -ne 2 -or $disk.Name -ne 'Hard disk 2') {
    throw 'Back did not return to selection and resume the single-disk workflow.'
}
Write-Host 'Multi-disk back navigation checks passed.'
