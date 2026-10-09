<#
.SYNOPSIS
    `task devcontainer:init` - gets the portable Node.js and @devcontainers/cli
    into the cache (downloading if needed), resolves the container engine, and
    prints what will be used. Nothing is installed on the host. With -Force
    the cached CLI is reinstalled (e.g. to pick up a newer 'latest').

    Empty parameters fall back to DEVCONTAINER_DOCKER_PATH,
    DEVCONTAINER_NODE_VERSION and DEVCONTAINER_CLI_VERSION.
#>
[CmdletBinding()]
param(
    [string]$DockerPath,
    [string]$NodeVersion,
    [string]$CliVersion,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevcontainerCli.psm1') -Force

$engine = Resolve-DockerPath -DockerPath $DockerPath
Write-Host "Container engine : $(if ($engine) { $engine } else { 'docker (on PATH)' })"

if ($IsWindows) {
    $nodeDir = Get-PortableNodeDir -Version $NodeVersion
    Write-Host "Portable Node.js : $nodeDir"
    if ($Force) { Remove-DevcontainersCli }
    $entrypoint = Get-DevcontainersCliEntrypoint -NodeDir $nodeDir -CliVersion $CliVersion
    $version = & (Join-Path $nodeDir 'node.exe') $entrypoint --version
    Write-Host "devcontainer CLI : $version ($entrypoint)"
}
elseif (Get-Command devcontainer -ErrorAction SilentlyContinue) {
    Write-Host "devcontainer CLI : $(devcontainer --version) ($((Get-Command devcontainer).Source))"
}
else {
    Write-Host 'devcontainer CLI : none on PATH - tasks will fall back to `npx -y @devcontainers/cli` (needs Node.js).'
}
