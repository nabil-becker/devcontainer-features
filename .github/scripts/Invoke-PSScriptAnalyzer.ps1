<#
.SYNOPSIS
    Runs PSScriptAnalyzer over every PowerShell file in this repository with
    .github/PSScriptAnalyzerSettings.psd1 and fails (exit 1) on any finding.
    Used by `task lint` and the Lint workflow so both check the same thing.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '../..')
$settings = Join-Path $root '.github/PSScriptAnalyzerSettings.psd1'

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    throw 'PSScriptAnalyzer is not installed: Install-Module PSScriptAnalyzer -Scope CurrentUser'
}

$files = Get-ChildItem -Path $root -Recurse -File -Include *.ps1, *.psm1, *.psd1 |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|\.task|node_modules)[\\/]' }

$results = foreach ($f in $files) {
    Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings
}

Write-Host "PSScriptAnalyzer: $($files.Count) files, $(@($results).Count) findings"
if ($results) {
    $results | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize | Out-String -Width 200 | Write-Host
    exit 1
}
