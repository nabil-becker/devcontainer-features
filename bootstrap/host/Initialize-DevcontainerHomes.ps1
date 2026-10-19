<#
.SYNOPSIS
    `task devcontainer:homes` - creates the host-side folders a
    devcontainer.json bind-mounts for tool state (Claude Code's config dir,
    gh and az logins, ...), so the container never fails to start on a
    missing mount source. Meant to run as the devcontainer's
    initializeCommand, on the host, before every start:

      "initializeCommand": "task devcontainer:homes NAME=myrepo -- claude gh"

    with matching mounts such as
      source=${localEnv:USERPROFILE}/.devcontainer-homes/myrepo/claude,target=/home/vscode/.claude,type=bind

    Why the host disk rather than a named volume: volumes belong to the
    container engine's storage and vanish when it is reset or swapped
    (Docker Desktop <-> wslc); a folder under the user profile survives both,
    and it stays outside a synced checkout (OneDrive) so transcripts and
    tokens are never synced.

.PARAMETER Name
    Folder under the homes root for this repository (a short slug, no spaces;
    the same literal the mounts in devcontainer.json use).

.PARAMETER Dirs
    Names of the folders to create under <Root>\<Name>, e.g. claude, gh, azure.
    Space-separated string (what Task passes as CLI_ARGS) or an array.

.PARAMETER Root
    Homes root. Empty = $env:DEVCONTAINER_HOMES, else
    %USERPROFILE%\.devcontainer-homes (Windows) or ~/.devcontainer-homes.

.PARAMETER GitDir
    Optional: a git dir kept outside the checkout (the OneDrive pattern: the
    checkout's .git is a pointer file, the real git dir lives in e.g.
    %USERPROFILE%\.git-dirs\<repo> and is bind-mounted into the container).
    When given, the script fails with a plain message if <GitDir>\HEAD is
    missing, rather than letting the mount fail later.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string[]]$Dirs = @(),
    [string]$Root,
    [string]$GitDir
)

$ErrorActionPreference = 'Stop'

if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
    throw "devcontainer:homes NAME '$Name' must be a plain slug (letters, digits, . _ -), the same one the mounts in devcontainer.json use."
}
if (-not $Root) { $Root = $env:DEVCONTAINER_HOMES }
if (-not $Root) {
    $profileDir = if ($IsWindows) { $env:USERPROFILE } else { $env:HOME }
    $Root = Join-Path $profileDir '.devcontainer-homes'
}
# Task passes CLI_ARGS as one string; accept both that and a real array.
$Dirs = @($Dirs | ForEach-Object { $_ -split '\s+' } | Where-Object { $_ })

$base = Join-Path $Root $Name
New-Item -ItemType Directory -Force -Path $base | Out-Null
Write-Host "devcontainer homes: $base"
foreach ($d in $Dirs) {
    $target = Join-Path $base $d
    $state = if (Test-Path -LiteralPath $target) { 'exists' } else { 'created' }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Write-Host "  $d`t$state"
}

if ($GitDir) {
    if (-not (Test-Path -LiteralPath (Join-Path $GitDir 'HEAD'))) {
        throw "git dir not found at $GitDir (no HEAD). The devcontainer bind-mounts it as GIT_DIR; create or move the repository's git dir there first."
    }
    Write-Host "  git dir`t$GitDir"
}
