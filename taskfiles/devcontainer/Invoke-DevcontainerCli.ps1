<#
.SYNOPSIS
    Entry point for the devcontainer:* tasks in ../devcontainer.yml - runs
    one @devcontainers/cli subcommand against a workspace. See
    DevcontainerCli.psm1 for how Node.js, the CLI and the container engine
    are resolved.

.PARAMETER Subcommand
    @devcontainers/cli subcommand: up, build, exec, read-configuration,
    features, ...

.PARAMETER WorkspaceFolder
    Folder containing .devcontainer/ (passed as --workspace-folder where the
    subcommand takes it).

.PARAMETER CliArgsB64
    Extra CLI arguments as Task passes them:
    '{{.CLI_ARGS | splitArgs | toJson | b64enc}}'.

.PARAMETER CommandB64
    exec only: a base64-encoded shell command, run as `bash -lc "<cmd>"`
    inside the container. Encoding it means the command crosses PowerShell,
    the CLI and docker exec untouched - no nested-quoting surprises.

.PARAMETER DockerPath
    Docker-compatible CLI (name on PATH or full path) for --docker-path.
    Empty = $env:DEVCONTAINER_DOCKER_PATH, else auto-detect (docker, then
    wslc.exe on Windows).

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
    [string]$NodeVersion,
    [string]$CliVersion
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevcontainerCli.psm1') -Force

$params = @{
    Subcommand      = $Subcommand
    WorkspaceFolder = $WorkspaceFolder
    Arguments       = ConvertFrom-TaskCliArgString -CliArgsB64 $CliArgsB64
    DockerPath      = $DockerPath
    NodeVersion     = $NodeVersion
    CliVersion      = $CliVersion
}
if ($CommandB64) { $params.CommandB64 = $CommandB64 }
Invoke-DevcontainerCli @params
