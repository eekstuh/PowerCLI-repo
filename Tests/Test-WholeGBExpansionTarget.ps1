#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'Expand-VSphereVmDisk-v4.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
$function = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-WholeGBExpansionTarget'
}, $true)
. ([scriptblock]::Create($function.Extent.Text))
foreach ($case in @(
    @{ Current = 100.4949213124121512d; Add = 20d; Expected = 120d },
    @{ Current = 100d; Add = 20d; Expected = 120d },
    @{ Current = 100.99d; Add = 20d; Expected = 120d },
    @{ Current = 100.25d; Add = 1d; Expected = 101d }
)) {
    $actual = Get-WholeGBExpansionTarget -CurrentCapacityGB $case.Current -AdditionalGB $case.Add
    if ($actual -ne $case.Expected) { throw "Expected $($case.Expected), got $actual." }
}
foreach ($increase in @(0.1d, 0d, -20d)) {
    $rejected = $false
    try { Get-WholeGBExpansionTarget -CurrentCapacityGB 100.49d -AdditionalGB $increase | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'A non-growing target was accepted.' }
}
Write-Host 'Whole-GB expansion target checks passed.'
