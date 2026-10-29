<#
.SYNOPSIS
    Entry point for the devcontainer:* tasks in ../devcontainer.yml - runs
    one @devcontainers/cli subcommand against a workspace. See
    DevcontainerCli.psm1 for how Node.js, the CLI and the container engine
    are resolved.

.PARAMETER Subcommand
    @devcontainers/cli subcommand: up, build, exec, read-configuration,
    features, ...; or stop, prepshutdown, running and host, which are not CLI
    subcommands (see DevcontainerCli.psm1).

.PARAMETER WorkspaceFolder
    Folder containing .devcontainer/ (passed as --workspace-folder where the
    subcommand takes it).

.PARAMETER CliArgsB64
    Extra CLI arguments as Task passes them:
    '{{.CLI_ARGS | splitArgs | toJson | b64enc}}'.

.PARAMETER CommandB64
    exec, and stop (its shutdown check): a base64-encoded shell command, run
    as `bash -lc "<cmd>"` inside the container. Encoding it means the command crosses PowerShell,
    the CLI and docker exec untouched - no nested-quoting surprises.

.PARAMETER Force
    stop only: skip the shutdown check (the command in -CommandB64).

.PARAMETER DockerPath
    Docker-compatible CLI (name on PATH or full path) for --docker-path.
    Empty = $env:DEVCONTAINER_DOCKER_PATH, else auto-detect (docker, then
    wslc.exe on Windows).

.PARAMETER HostType
    HOST_TYPE: auto, or one of windows-docker, windows-wsl-docker, windows-wslc,
    linux, macos. Empty = $env:HOST_TYPE, else auto.

.PARAMETER HostTypePriority
    HOST_TYPE_PRIORITY: ordered, comma-separated ids that auto tries. Empty =
    $env:HOST_TYPE_PRIORITY, else the default for the OS.

.PARAMETER HostMounts
    HOST_MOUNTS: false (or 0, no) turns off the mounts the launcher adds to `up`
    (the `.git-dirs` folder at /git-dirs, the SSH agent socket). Empty = $env:HOST_MOUNTS, else on.

.PARAMETER SshAgentMode
    SSH_AGENT_MODE: key = the opt-in to a signing key kept in the container (no agent
    socket is mounted, DCF_HOST_SSH_AGENT=key). Empty = $env:SSH_AGENT_MODE, else the
    host type decides.

.PARAMETER CloudFolder
    DCF_HOST_CLOUD_FOLDER: a host folder (one a sync client keeps) that `up` bind-mounts at the
    cloud-folder Feature's host mount, /mnt/cloud-folder-host. Empty = $env:DCF_HOST_CLOUD_FOLDER,
    else no folder.

.PARAMETER Fuse
    DCF_HOST_FUSE: 1 (or true, yes, on) asks for FUSE on this machine (the cloud-folder Feature's
    mount mode): the launcher sets DCF_HOST_FUSE_DEVICE, DCF_HOST_FUSE_CAP and
    DCF_HOST_FUSE_SECURITY for the repository's runArgs. Empty = $env:DCF_HOST_FUSE, else no grant.

.PARAMETER NodeVersion
    Portable Node.js version (Windows). Empty = $env:DEVCONTAINER_NODE_VERSION
    or the module default.

.PARAMETER CliVersion
    @devcontainers/cli version (Windows). Empty = $env:DEVCONTAINER_CLI_VERSION
    or 'latest'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Subcommand,
    [Parameter(Mandatory)][string]$WorkspaceFolder,
    [string]$CliArgsB64,
    [string]$CommandB64,
    [string]$DockerPath,
    [string]$HostType,
    [string]$HostTypePriority,
    [string]$HostMounts,
    [string]$SshAgentMode,
    [string]$CloudFolder,
    [string]$Fuse,
    [string]$NodeVersion,
    [string]$CliVersion,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevcontainerCli.psm1') -Force
# The module reads them as environment variables (a .env file can drive it too).
if ($HostType) { $env:HOST_TYPE = $HostType }
if ($HostTypePriority) { $env:HOST_TYPE_PRIORITY = $HostTypePriority }
if ($HostMounts) { $env:HOST_MOUNTS = $HostMounts }
if ($SshAgentMode) { $env:SSH_AGENT_MODE = $SshAgentMode }
if ($CloudFolder) { $env:DCF_HOST_CLOUD_FOLDER = $CloudFolder }
if ($Fuse) { $env:DCF_HOST_FUSE = $Fuse }

$params = @{
    Subcommand      = $Subcommand
    WorkspaceFolder = $WorkspaceFolder
    Arguments       = ConvertFrom-TaskCliArgString -CliArgsB64 $CliArgsB64
    DockerPath      = $DockerPath
    NodeVersion     = $NodeVersion
    CliVersion      = $CliVersion
}
if ($CommandB64) { $params.CommandB64 = $CommandB64 }
if ($Force) { $params.Force = $true }
Invoke-DevcontainerCli @params
