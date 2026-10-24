# Copy every src/<id> and local-features/<id> Feature into .devcontainer/features/<id>
# (gitignored), so this repository's own devcontainer references the unpublished Features by
# local path. `task features:stage` runs this on Windows; stage-features.sh is the same on
# Linux/macOS. A directory without devcontainer-feature.json is not a Feature (a leftover of a
# move, say) and is skipped with a warning; the same id in both trees is an error, because the
# second copy would land inside the first and the Feature would be missing its manifest.
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
Remove-Item -Recurse -Force .devcontainer/features -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force .devcontainer/features | Out-Null
$seen = @{}
$n = 0
foreach ($d in @(Get-ChildItem src, local-features -Directory -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path (Join-Path $d.FullName 'devcontainer-feature.json'))) {
        Write-Warning "not staged: $($d.FullName) has no devcontainer-feature.json (a leftover directory? remove it)"
        continue
    }
    if ($seen.ContainsKey($d.Name)) {
        throw "Feature id '$($d.Name)' exists in both src/ and local-features/; keep one."
    }
    $seen[$d.Name] = $true
    Copy-Item -Recurse $d.FullName (Join-Path .devcontainer/features $d.Name)
    $n++
}
Write-Output "staged $n Features into .devcontainer/features"
