<#
.SYNOPSIS
    One-shot bootstrap for a repo that should be driven through
    `task devcontainer:*`. Windows entry point (PowerShell 7); Linux/macOS
    use bootstrap.sh. Run it from the repo root on a host that has Task and
    a Docker-compatible engine:

      irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap.ps1 | iex

    Every parameter can come from the command line, from an environment
    variable, or from a .env file in the repo (./.env or ./.devcontainer/.env,
    loaded first; existing environment wins over the file; explicit
    parameters win over both). That is how a piped `irm | iex` run is
    configured:

      $env:DEVCONTAINER_DOCKER_PATH = 'wslc'; irm ... | iex

    or, with parameters:

      & ([scriptblock]::Create((irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap.ps1))) -DockerPath wslc -NoUp

.DESCRIPTION
    Breaks the chicken-and-egg between "the devcontainer tasks live in the
    devcontainer-features repo" and "I don't have that repo checked out":

      1. Vendors taskfiles/devcontainer.yml + taskfiles/devcontainer/* (the
         PowerShell and bash flavours) from this repository (at -Ref) into
         ./taskfiles/ - always refreshed, so re-running the bootstrap is how
         you update them.
      2. Writes a starter Taskfile.yml (includes the vendored tasks, loads
         .env files), .devcontainer/devcontainer.json (go-task,
         devcontainer-cli, docker-outside-of-docker, PowerShell),
         .devcontainer/env_mnt/.gitignore and .devcontainer/.env.example -
         only if they don't exist - and gitignores .devcontainer/.env.
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
if ($DockerPath) { Write-Host "  engine    DEVCONTAINER_DOCKER_PATH=$DockerPath" }

# 1. Vendor the devcontainer tasks (always refreshed).
$vendored = @(
    'taskfiles/devcontainer.yml',
    'taskfiles/devcontainer/DevcontainerCli.psm1',
    'taskfiles/devcontainer/Invoke-DevcontainerCli.ps1',
    'taskfiles/devcontainer/Initialize-DevcontainerCli.ps1',
    'taskfiles/devcontainer/Reset-WslcStorage.ps1',
    'taskfiles/devcontainer/devcontainer-cli.sh'
)
foreach ($rel in $vendored) {
    Get-SourceFile -RelativePath $rel -Destination (Join-Path $Path $rel)
    Write-Host "  vendored  $rel"
}

# 2. Templates, only where nothing exists yet.
$templates = [ordered]@{
    'bootstrap/Taskfile.yml'      = 'Taskfile.yml'
    'bootstrap/devcontainer.json' = '.devcontainer/devcontainer.json'
    'bootstrap/env_mnt.gitignore' = '.devcontainer/env_mnt/.gitignore'
    'bootstrap/env.example'       = '.devcontainer/.env.example'
}
foreach ($entry in $templates.GetEnumerator()) {
    $dest = Join-Path $Path $entry.Value
    if (Test-Path $dest) {
        Write-Host "  kept      $($entry.Value) (exists)"
        continue
    }
    Get-SourceFile -RelativePath $entry.Key -Destination $dest
    Write-Host "  wrote     $($entry.Value)"
}

$gitignore = Join-Path $Path '.gitignore'
$ignoreLine = '.devcontainer/.env'
if (-not (Test-Path $gitignore) -or -not ((Get-Content $gitignore) -contains $ignoreLine)) {
    Add-Content -Path $gitignore -Value @('', '# devcontainer task settings - may hold host-specific paths', $ignoreLine)
    Write-Host "  gitignored $ignoreLine"
}

$taskfile = Join-Path $Path 'Taskfile.yml'
if ((Get-Content $taskfile -Raw) -notmatch 'taskfiles/devcontainer\.yml') {
    Write-Warning @"
Taskfile.yml already exists and does not include the devcontainer tasks. Add:

  dotenv: ['.env', '.devcontainer/.env']
  includes:
    devcontainer:
      taskfile: ./taskfiles/devcontainer.yml
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
