#requires -Version 5.1
# Offline timing checks. No workflow or PowerCLI module is executed.
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management
Import-Module Microsoft.PowerShell.Utility
Import-Module Microsoft.PowerShell.Security
$PSModuleAutoLoadingPreference = 'None'
$root = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Expand-VSphereVmDisk-v3.ps1'),[ref]$null,[ref]$null)
foreach ($name in @('Measure-ExecutionStage','Write-ExecutionTimings','Get-WindowsGuestVolumeLabels')) {
    $definition = $ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name
    }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}
$ShowTimings=$false
$script:ExecutionTimings=$null
$value = Measure-ExecutionStage -Name 'Disabled' -Action { 'unchanged' }
Assert-True ($value -eq 'unchanged' -and $null -eq $script:ExecutionTimings) 'Disabled timing changed output or recorded data.'
$ShowTimings=$true
$value = @(Measure-ExecutionStage -Name 'Success' -Action { 1; 2 })
Assert-True (($value -join ',') -eq '1,2') 'Timing changed pipeline output.'
try { Measure-ExecutionStage -Name 'Failure' -Action { throw 'expected' }; throw 'Failure was swallowed' }
catch { Assert-True ($_.Exception.Message -eq 'expected') 'Timing did not preserve the exception.' }
Assert-True ($script:ExecutionTimings.Count -eq 2 -and $script:ExecutionTimings[1].Status -eq 'Failed') 'Failed stage was not recorded.'
$display = @(Write-ExecutionTimings 6>&1) -join "`n"
Assert-True ($display -match 'Failure.*failed' -and $script:ExecutionTimings.Count -eq 0) 'Display did not report failure or clear records.'
function Get-Partition {
    [pscustomobject]@{DiskNumber=0;PartitionNumber=2;AccessPaths=@('C:\')}
}
function Get-Volume { param($Partition,$ErrorAction) [pscustomobject]@{DriveLetter='C';FileSystemLabel='System'} }
function Invoke-WindowsGuestPowerShell {
    param($VM,$Credential,$ScriptText)
    $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseInput($ScriptText,[ref]$null,[ref]$errors)
    Assert-True ($errors.Count -eq 0 -and $ScriptText -notmatch '__SHOW_TIMINGS__') 'Guest timing script is invalid.'
    # Execute only the read-only inventory against the local test doubles above.
    Measure-ExecutionStage -Name 'Guest command (Tools round trip)' -Action { & ([scriptblock]::Create($ScriptText)) }
}
$credential=[pscredential]::new('test',(ConvertTo-SecureString 'test-only' -AsPlainText -Force))
$volumes=@(Get-WindowsGuestVolumeLabels -VM ([pscustomobject]@{Name='mock'}) -Credential $credential)
Assert-True ($volumes.Count -eq 1 -and $volumes[0].Label -eq 'System') 'Guest timing changed inventory.'
Assert-True ($null -ne $script:VolumeQuerySeconds -and $script:VolumeQuerySeconds -ge 0) 'Guest query duration missing.'
$display = @(Write-ExecutionTimings 6>&1) -join "`n"
Assert-True ($display -match 'Windows volume queries' -and $display -match 'Remaining guest-command overhead') 'Guest breakdown missing.'
$ShowTimings=$false
$volumes=@(Get-WindowsGuestVolumeLabels -VM ([pscustomobject]@{Name='mock'}) -Credential $credential)
Assert-True ($volumes[0].Label -eq 'System' -and $null -eq $script:VolumeQuerySeconds) 'Normal inventory behavior changed.'
Assert-True (@(Write-ExecutionTimings 6>&1).Count -eq 0) 'Timings appeared without the switch.'
Write-Host 'Execution timing checks passed.'
