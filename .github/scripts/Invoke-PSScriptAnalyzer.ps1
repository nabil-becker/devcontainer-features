<#
.SYNOPSIS
    Runs PSScriptAnalyzer over every PowerShell file in this repository with
    .github/PSScriptAnalyzerSettings.psd1 and fails (exit 1) on any finding.
    Used by `task lint` and the Lint workflow so both check the same thing.
#>
[CmdletBinding()]
param(
    # The repository to check; the default is the one this script lives in.
    [string]$Root = (Join-Path $PSScriptRoot '../..')
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path $Root
$settings = Join-Path $root '.github/PSScriptAnalyzerSettings.psd1'

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    throw 'PSScriptAnalyzer is not installed: Install-Module PSScriptAnalyzer -Scope CurrentUser'
}

# Tracked and untracked-but-not-ignored files only: what git ignores (material.ignore/,
# a local scratch folder) is not ours to lint, as for the YAML check (.yamllint).
$listed = git -C $root ls-files --cached --others --exclude-standard -- '*.ps1' '*.psm1' '*.psd1'
if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in $root" }
$files = $listed |
    Where-Object { Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf } |
    ForEach-Object { Get-Item -LiteralPath (Join-Path $root $_) }

$results = foreach ($f in $files) {
    Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings
}

Write-Host "PSScriptAnalyzer: $($files.Count) files, $(@($results).Count) findings"
if ($results) {
    $results | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize | Out-String -Width 200 | Write-Host
    exit 1
}
