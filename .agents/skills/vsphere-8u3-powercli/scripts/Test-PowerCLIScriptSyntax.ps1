#requires -Version 5.1

<#
.SYNOPSIS
Validates PowerShell syntax without executing the scripts.

.PARAMETER Path
A PowerShell script file or directory to validate. The default is the current directory.

.PARAMETER Recurse
Searches child directories when Path identifies a directory.

.EXAMPLE
.\Test-PowerCLIScriptSyntax.ps1 -Path .\Assign-VDI-v1.ps1

.EXAMPLE
.\Test-PowerCLIScriptSyntax.ps1 -Path . -Recurse
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Path = '.',

    [Parameter()]
    [switch]$Recurse
)

$ErrorActionPreference = 'Stop'
$resolvedPath = Resolve-Path -LiteralPath $Path -ErrorAction Stop
$item = Get-Item -LiteralPath $resolvedPath.Path -ErrorAction Stop

$files = if ($item.PSIsContainer) {
    @(
        Get-ChildItem -LiteralPath $item.FullName -Filter '*.ps1' -File -Recurse:$Recurse |
            Sort-Object FullName
    )
}
else {
    if ($item.Extension -ine '.ps1') {
        throw "Path '$($item.FullName)' is not a PowerShell script file."
    }
    @($item)
}

if ($files.Count -eq 0) {
    throw "No PowerShell script files were found at '$($item.FullName)'."
}

$results = @(
    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )

        [pscustomobject]@{
            Path       = $file.FullName
            Status     = if ($parseErrors.Count -eq 0) { 'Passed' } else { 'Failed' }
            ErrorCount = $parseErrors.Count
            Errors     = @(
                $parseErrors |
                    ForEach-Object {
                        'Line {0}, column {1}: {2}' -f
                            $_.Extent.StartLineNumber,
                            $_.Extent.StartColumnNumber,
                            $_.Message
                    }
            ) -join [Environment]::NewLine
        }
    }
)

$results | Format-Table Path, Status, ErrorCount -AutoSize | Out-Host
$failedResults = @($results | Where-Object { $_.ErrorCount -gt 0 })
if ($failedResults.Count -gt 0) {
    $failedResults | Select-Object Path, Errors | Format-List | Out-Host
    throw "$($failedResults.Count) PowerShell script file(s) contain syntax errors."
}

Write-Host "Validated $($results.Count) PowerShell script file(s)." -ForegroundColor Green
