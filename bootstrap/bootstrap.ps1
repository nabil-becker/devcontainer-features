<#
.SYNOPSIS
    One-shot bootstrap for a repo that should be driven through
    `task devcontainer:*`. Windows entry point (PowerShell 7); Linux/macOS
    use bootstrap.sh. Run it from the repo root on a host that has Task and
    a Docker-compatible engine:

      irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap/bootstrap.ps1 | iex

    Every parameter can come from the command line, from an environment
    variable, or from a .env file in the repo (./.env or ./.devcontainer/.env,
    loaded first; existing environment wins over the file; explicit
    parameters win over both). That is how a piped `irm | iex` run is
    configured:

      $env:DEVCONTAINER_DOCKER_PATH = 'wslc'; irm ... | iex

    or, with parameters:

      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap/bootstrap.ps1))) -DockerPath wslc -NoUp

.DESCRIPTION
    Breaks the chicken-and-egg between "the devcontainer tasks live in the
    devcontainer-features repo" and "I don't have that repo checked out":

      1. Vendors bootstrap/devcontainer.yml, bootstrap/host/* (the PowerShell
         flavour) and the devcontainer-cli Feature's devcontainer-cli.sh (the
         bash flavour) into the bootstrap folder (default
         .devcontainer/cli_bootstrap.ignore/, see -BootstrapDir) - always
         refreshed, so re-running the bootstrap is how you update them - and
         git-ignores that folder (.devcontainer/.gitignore when it is under
         .devcontainer/, else the root .gitignore; created or appended, a line
         is never duplicated; -NoGitignore skips).
      2. Writes a starter Taskfile.yml (includes the vendored tasks with
         optional: true, and the Feature-Taskfile registry, loads .env files),
         .devcontainer/devcontainer.json (go-task, devcontainer-cli,
         git, docker-outside-of-docker, PowerShell) and
         .devcontainer/.env.example and the starter
         .devcontainer/shutdown-check.sh (bootstrap/SHUTDOWN.md) - only if they
         don't exist - and gitignores .devcontainer/.env.
      3. Runs `task devcontainer:init` (caches the portable Node.js +
         @devcontainers/cli, reports the engine) and then
         `task devcontainer:up`, unless -NoUp.

    Nothing is installed on the host: Node.js and the CLI are cached under
    %LOCALAPPDATA%\devcontainer-features.

.PARAMETER Ref
    Git ref of nabil-becker/devcontainer-features to vendor from.
    Env: DEVCONTAINER_BOOTSTRAP_REF. Default: main.

.PARAMETER Path
    Repo root to bootstrap. Env: DEVCONTAINER_BOOTSTRAP_PATH. Default: cwd.

.PARAMETER Source
    Where to take the files from: a URL base or a local checkout path.
    Env: DEVCONTAINER_BOOTSTRAP_SOURCE. Default: the raw GitHub URL for -Ref.

.PARAMETER DockerPath
    Docker-compatible CLI for `devcontainer --docker-path`: a command name on
    PATH (docker, wslc, podman, nerdctl, finch) or a full path. Also written
    into the environment for the tasks this script runs.
    Env: DEVCONTAINER_DOCKER_PATH. Default: docker on PATH, else wslc.exe.

.PARAMETER BootstrapDir
    Folder to vendor into, relative to the repo root (no absolute path, no
    ..). Env: BOOTSTRAP_DIR. Default: .devcontainer/cli_bootstrap.ignore.
    A repository that vendored into ./bootstrap/ keeps working untouched; a
    re-run vendors into the new folder, prints a migration note and repoints
    a root Taskfile include of exactly ./bootstrap/devcontainer.yml (adding
    optional: true to that include when it has none).

.PARAMETER NoGitignore
    Do not git-ignore the vendored folder. Env: BOOTSTRAP_GITIGNORE=false.

.PARAMETER NoUp
    Vendor files and write templates only; do not build/start the container.
    Env: DEVCONTAINER_BOOTSTRAP_NO_UP=true.
#>
[CmdletBinding()]
param(
    [string]$Ref,
    [string]$Path,
    [string]$Source,
    [string]$DockerPath,
    [string]$BootstrapDir,
    [switch]$NoGitignore,
    [switch]$NoUp
)

$ErrorActionPreference = 'Stop'

function Import-DotEnv([string]$File) {
    # KEY=VALUE lines; '#' comments; optional surrounding quotes. Never
    # overrides a variable that is already set in the environment.
    if (-not (Test-Path -LiteralPath $File)) { return }
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$' -and $line -notmatch '^\s*#') {
            $name = $Matches[1]
            $value = $Matches[2] -replace '^(["''])(.*)\1$', '$2'
            if (-not [Environment]::GetEnvironmentVariable($name)) {
                [Environment]::SetEnvironmentVariable($name, $value)
            }
        }
    }
    Write-Host "  loaded    $File"
}

function Resolve-Setting([string]$Value, [string]$EnvName, [string]$Default) {
    if ($Value) { return $Value }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv) { return $fromEnv }
    return $Default
}

# Path first (it tells us where the .env files are), then everything else.
$Path = (Resolve-Path (Resolve-Setting $Path 'DEVCONTAINER_BOOTSTRAP_PATH' (Get-Location).Path)).Path
Import-DotEnv (Join-Path $Path '.env')
Import-DotEnv (Join-Path $Path '.devcontainer/.env')

$Ref = Resolve-Setting $Ref 'DEVCONTAINER_BOOTSTRAP_REF' 'main'
$Source = Resolve-Setting $Source 'DEVCONTAINER_BOOTSTRAP_SOURCE' "https://raw.githubusercontent.com/nabil-becker/devcontainer-features/$Ref"
$DockerPath = Resolve-Setting $DockerPath 'DEVCONTAINER_DOCKER_PATH' ''
if (-not $NoUp -and (Resolve-Setting '' 'DEVCONTAINER_BOOTSTRAP_NO_UP' '') -match '^(1|true|yes)$') { $NoUp = $true }
if ($DockerPath) { $env:DEVCONTAINER_DOCKER_PATH = $DockerPath }

# Vendoring folder: repo-relative, inside the repo, forward slashes, no trailing slash.
$DefaultBootstrapDir = '.devcontainer/cli_bootstrap.ignore'
$ExplicitDir = [bool](Resolve-Setting $BootstrapDir 'BOOTSTRAP_DIR' '')
$BootstrapDir = Resolve-Setting $BootstrapDir 'BOOTSTRAP_DIR' $DefaultBootstrapDir
function Invoke-BadBootstrapDir([string]$Why) {
    throw "bootstrap: BOOTSTRAP_DIR '$BootstrapDir' $Why; give a path relative to the repository root, inside it (for example $DefaultBootstrapDir)."
}
$BootstrapDir = $BootstrapDir -replace '\\', '/'
if ($BootstrapDir -match '^(/|[A-Za-z]:)') { Invoke-BadBootstrapDir 'is an absolute path' }
while ($BootstrapDir -match '^\./' -or $BootstrapDir -match '/$') { $BootstrapDir = $BootstrapDir -replace '^\./', '' -replace '/$', '' }
if ($BootstrapDir -in @('', '.', '.devcontainer')) { Invoke-BadBootstrapDir 'would vendor into the repository root or all of .devcontainer' }
if (($BootstrapDir -split '/') -contains '..') { Invoke-BadBootstrapDir 'escapes the repository (..)' }
$GitignoreBootstrap = -not $NoGitignore -and ((Resolve-Setting '' 'BOOTSTRAP_GITIGNORE' '') -notmatch '^(false|0|no)$')

function Get-SourceFile([string]$RelativePath, [string]$Destination) {
    New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
    if ($Source -match '^https?://') {
        Invoke-WebRequest -UseBasicParsing -Uri "$Source/$RelativePath" -OutFile $Destination
    }
    else {
        Copy-Item -LiteralPath (Join-Path $Source $RelativePath) -Destination $Destination -Force
    }
}

Write-Host "Bootstrapping $Path from $Source"
Write-Host "  folder    $BootstrapDir/ (vendored launcher and tasks; BOOTSTRAP_DIR overrides)"
if ($DockerPath) { Write-Host "  engine    DEVCONTAINER_DOCKER_PATH=$DockerPath" }

# 1. Vendor the devcontainer tasks (always refreshed). Source path in the
#    collection repo -> destination in this repo. The bash flavour is the
#    devcontainer-cli Feature's own script, vendored next to the PowerShell.
$vendored = [ordered]@{
    'bootstrap/devcontainer.yml'                   = '{BD}/devcontainer.yml'
    'bootstrap/host/DevcontainerCli.psm1'          = '{BD}/host/DevcontainerCli.psm1'
    'bootstrap/host/Invoke-DevcontainerCli.ps1'    = '{BD}/host/Invoke-DevcontainerCli.ps1'
    'bootstrap/host/Initialize-DevcontainerCli.ps1' = '{BD}/host/Initialize-DevcontainerCli.ps1'
    'bootstrap/host/Reset-WslcStorage.ps1'         = '{BD}/host/Reset-WslcStorage.ps1'
    'bootstrap/host/Initialize-DevcontainerHomes.ps1' = '{BD}/host/Initialize-DevcontainerHomes.ps1'
    'bootstrap/host/devcontainer-homes.sh'         = '{BD}/host/devcontainer-homes.sh'
    'src/devcontainer-cli/devcontainer-cli.sh'     = '{BD}/host/devcontainer-cli.sh'
}
foreach ($entry in $vendored.GetEnumerator()) {
    $dest = $entry.Value.Replace('{BD}', $BootstrapDir)
    Get-SourceFile -RelativePath $entry.Key -Destination (Join-Path $Path $dest)
    Write-Host "  vendored  $dest"
}

# Git-ignore the vendored folder (BOOTSTRAP_GITIGNORE=false / -NoGitignore skips):
# a line in .devcontainer/.gitignore when the folder is under .devcontainer/, else
# in the repository's root .gitignore. Created if missing, the line appended only
# when absent (with or without the trailing or a leading slash), nothing else touched.
function Add-IgnoreLine([string]$File, [string]$Line) {
    $bare = $Line.TrimEnd('/')
    $rel = [System.IO.Path]::GetRelativePath($Path, $File).Replace('\', '/')
    New-Item -ItemType Directory -Path (Split-Path $File -Parent) -Force | Out-Null
    if (Test-Path -LiteralPath $File) {
        $existing = @(Get-Content -LiteralPath $File)
        if ($existing | Where-Object { $_ -in @($Line, $bare, "/$Line", "/$bare") }) {
            Write-Host "  kept      $rel (already ignores $Line)"
            return
        }
        $raw = Get-Content -LiteralPath $File -Raw
        if ($raw -and -not $raw.EndsWith("`n")) { Add-Content -LiteralPath $File -Value '' }
    }
    Add-Content -LiteralPath $File -Value $Line
    Write-Host "  gitignored $Line in $rel"
}
if ($GitignoreBootstrap) {
    if ($BootstrapDir.StartsWith('.devcontainer/')) {
        Add-IgnoreLine (Join-Path $Path '.devcontainer/.gitignore') ($BootstrapDir.Substring('.devcontainer/'.Length) + '/')
    }
    else {
        Add-IgnoreLine (Join-Path $Path '.gitignore') "/$BootstrapDir/"
    }
}
else {
    Write-Host "  skipped   git-ignoring $BootstrapDir/ (BOOTSTRAP_GITIGNORE=false)"
}

# 2. Templates, only where nothing exists yet.
$templates = [ordered]@{
    'bootstrap/Taskfile.yml'      = 'Taskfile.yml'
    'bootstrap/devcontainer.json' = '.devcontainer/devcontainer.json'
    'bootstrap/env.example'       = '.devcontainer/.env.example'
    'bootstrap/shutdown-check.sh' = '.devcontainer/shutdown-check.sh'
}
foreach ($entry in $templates.GetEnumerator()) {
    $dest = Join-Path $Path $entry.Value
    if (Test-Path $dest) {
        Write-Host "  kept      $($entry.Value) (exists)"
        if ($entry.Value -eq '.devcontainer/devcontainer.json') {
            Write-Host "             (see the host-disk override block for Feature state on the host disk)"
        }
        continue
    }
    Get-SourceFile -RelativePath $entry.Key -Destination $dest
    if ($entry.Value -eq 'Taskfile.yml') {
        # the include names the chosen folder
        $text = (Get-Content -LiteralPath $dest -Raw).Replace('{{BOOTSTRAP_DIR}}', $BootstrapDir)
        [System.IO.File]::WriteAllText($dest, $text)
    }
    Write-Host "  wrote     $($entry.Value)"
    if ($entry.Value -eq '.devcontainer/devcontainer.json') {
        Write-Host "             (see the host-disk override block for Feature state on the host disk)"
    }
}

$gitignore = Join-Path $Path '.gitignore'
$ignoreLine = '.devcontainer/.env'
if (-not (Test-Path $gitignore) -or -not ((Get-Content $gitignore) -contains $ignoreLine)) {
    Add-Content -Path $gitignore -Value @('', '# devcontainer task settings - may hold host-specific paths', $ignoreLine)
    Write-Host "  gitignored $ignoreLine"
}

$taskfile = Join-Path $Path 'Taskfile.yml'

# Old form: a repository that vendored into ./bootstrap/ keeps working untouched
# until it re-runs the bootstrap; this run vendored into the new folder.
if (-not $ExplicitDir -and $BootstrapDir -ne 'bootstrap' -and (Test-Path (Join-Path $Path 'bootstrap/devcontainer.yml'))) {
    $oldInclude = './bootstrap/devcontainer.yml'
    $newInclude = "./$BootstrapDir/devcontainer.yml"
    $pattern = '(?m)^([ \t]*taskfile:[ \t]*[''"]?)\./bootstrap/devcontainer\.yml(?=[''"]?[ \t]*(#.*)?\r?$)'
    $text = Get-Content $taskfile -Raw
    if ($text -match $pattern) {
        [System.IO.File]::WriteAllText($taskfile, [regex]::Replace($text, $pattern, { param($m) $m.Groups[1].Value + $newInclude }))
        Write-Host "  repointed Taskfile.yml: taskfile: $oldInclude -> $newInclude (only that value; to undo, change it back)"
        # The vendored folder is git-ignored, so a fresh clone lacks it until the bootstrap ran: the include
        # must be optional. Add `optional: true` to that include block unless the block already has an optional key.
        $lines = [regex]::Split([System.IO.File]::ReadAllText($taskfile), '(?<=\n)')
        $isTarget = { param($l) $l -match '^[ \t]*taskfile:' -and $l.Contains($newInclude) }
        $t = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if (& $isTarget $lines[$i]) { $t = $i; break } }
        if ($t -ge 0) {
            $ind = ([regex]::Match($lines[$t], '^[ \t]*')).Value
            $has = $false
            foreach ($range in @(($t - 1)..0), (($t + 1)..($lines.Count - 1))) {
                foreach ($i in $range) {
                    if ($i -lt 0 -or $i -ge $lines.Count) { break }
                    $l = $lines[$i].TrimEnd("`r", "`n")
                    if ($l -match '^[ \t]*(#.*)?$') { continue }
                    if (([regex]::Match($l, '^[ \t]*')).Length -lt $ind.Length) { break }
                    if ($l -match '^[ \t]*optional:') { $has = $true }
                }
            }
            if (-not $has) {
                $eol = if ($lines[$t].EndsWith("`r`n")) { "`r`n" } else { "`n" }
                $head = if ($lines[$t].EndsWith("`n")) { $lines[$t] } else { $lines[$t] + $eol }
                $lines[$t] = $head + $ind + 'optional: true' + $eol
                [System.IO.File]::WriteAllText($taskfile, ($lines -join ''))
                Write-Host '  added     optional: true to that include (the folder is git-ignored; a fresh clone lacks it until the bootstrap ran)'
            }
        }
    }
    Write-Host @"
MIGRATION: this repository vendored the bootstrap into ./bootstrap/ before; this run vendored into $BootstrapDir/.
  - The include in Taskfile.yml should be:  taskfile: $newInclude   with optional: true (the folder is git-ignored,
    so a fresh clone lacks it until this bootstrap runs; added above when the include block had no such line).
  - Once the include points at $BootstrapDir/, ./bootstrap/ is unused and can be deleted (git rm -r bootstrap).
    Nothing was deleted here, and while the include still names ./bootstrap/devcontainer.yml it keeps working as it was.
"@
}

$taskfileText = Get-Content $taskfile -Raw
if (($taskfileText -notmatch [regex]::Escape("$BootstrapDir/devcontainer.yml")) -and ($taskfileText -notmatch 'bootstrap/devcontainer\.yml')) {
    Write-Warning @"
Taskfile.yml already exists and does not include the devcontainer tasks. Add (the first run on a fresh
clone is the bootstrap one-liner, because $BootstrapDir/ is git-ignored):

  dotenv: ['.env', '.devcontainer/.env']
  includes:
    devcontainer:
      taskfile: ./$BootstrapDir/devcontainer.yml
      optional: true
      aliases: [dc]
    features:
      taskfile: /usr/local/share/go-task/features.yml
      optional: true
      flatten: true
"@
}

if ((Get-Content $taskfile -Raw) -notmatch 'shutdown:check') {
    Write-Host @"
NOTE: Taskfile.yml has no shutdown:check task, so devcontainer:stop and :rebuild run no check of this
repository (see bootstrap/SHUTDOWN.md in the collection). To use .devcontainer/shutdown-check.sh, add under tasks:

  shutdown:check:
    desc: 'Shutdown check run by devcontainer:stop and :rebuild inside the container (edit .devcontainer/shutdown-check.sh).'
    cmds:
      - sh .devcontainer/shutdown-check.sh
"@
}

# 3. Init (portable Node + CLI + engine detection), then up.
if (-not (Get-Command task -ErrorAction SilentlyContinue)) {
    Write-Warning 'Task is not on PATH (winget install Task.Task / scoop install task). Files are in place; run `task devcontainer:up` once it is.'
    return
}
Push-Location $Path
try {
    task devcontainer:init
    if ($LASTEXITCODE -ne 0) { throw "task devcontainer:init failed with exit code $LASTEXITCODE." }
    if ($NoUp) {
        Write-Host 'Skipping `task devcontainer:up` (-NoUp / DEVCONTAINER_BOOTSTRAP_NO_UP).'
    }
    else {
        task devcontainer:up
        if ($LASTEXITCODE -ne 0) { throw "task devcontainer:up failed with exit code $LASTEXITCODE." }
        Write-Host 'Devcontainer is up. Next: task devcontainer:shell, or Reopen in Container from VS Code.'
    }
}
finally {
    Pop-Location
}
