<#
.SYNOPSIS
    Tests the vendored Taskfile with stub host scripts (no Node.js or engine
    needed). Requires Task on PATH; runs on Windows and Linux/macOS.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '../..')
$temp = Join-Path ([IO.Path]::GetTempPath()) "devcontainer-taskfile-$([guid]::NewGuid())"
$settings = @('DEVCONTAINER_DOCKER_PATH', 'DEVCONTAINER_NODE_VERSION', 'DEVCONTAINER_CLI_VERSION')
$saved = @{}
foreach ($name in $settings) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

try {
    $hostDir = Join-Path $temp 'bootstrap/host'
    New-Item -ItemType Directory -Path $hostDir, (Join-Path $temp '.devcontainer') -Force | Out-Null
    Copy-Item (Join-Path $root 'bootstrap/Taskfile.yml') (Join-Path $temp 'Taskfile.yml')
    Copy-Item (Join-Path $root 'bootstrap/devcontainer.yml') (Join-Path $temp 'bootstrap/devcontainer.yml')

    # Record settings received by the platform entry points, not Task's
    # dry-run output: bash receives env, PowerShell receives parameters.
    $psStub = @'
param(
    [string]$DockerPath, [string]$NodeVersion, [string]$CliVersion,
    [string]$WorkspaceFolder, [string]$Subcommand, [string]$CliArgsB64,
    [string]$CommandB64, [switch]$Force
)
@($DockerPath, $NodeVersion, $CliVersion) | Set-Content (Join-Path $PSScriptRoot 'settings.txt')
'@
    Set-Content (Join-Path $hostDir 'Invoke-DevcontainerCli.ps1') $psStub
    Set-Content (Join-Path $hostDir 'Initialize-DevcontainerCli.ps1') $psStub
    Set-Content (Join-Path $hostDir 'devcontainer-cli.sh') @'
#!/bin/bash
printf '%s\n' "$DEVCONTAINER_DOCKER_PATH" "$DEVCONTAINER_NODE_VERSION" "$DEVCONTAINER_CLI_VERSION" > "$(dirname "$0")/settings.txt"
'@

    function Assert-Setting {
        param([string]$Case, [string[]]$Expected, [string[]]$TaskVars = @())
        foreach ($taskName in @('init', 'up', 'rebuild', 'build', 'exec', 'shell', 'config', 'outdated')) {
            $result = Join-Path $hostDir 'settings.txt'
            Remove-Item $result -ErrorAction SilentlyContinue
            & task --silent --dir $temp "devcontainer:$taskName" 'CMD=echo test' @TaskVars
            if ($LASTEXITCODE -ne 0) { throw "$Case / $taskName failed: exit $LASTEXITCODE" }
            $actual = @(Get-Content $result)
            if (($actual -join '|') -cne ($Expected -join '|')) {
                throw "$Case / ${taskName}: expected '$($Expected -join '|')', got '$($actual -join '|')'"
            }
        }
        Write-Host "PASS: $Case"
    }

    Assert-Setting -Case 'missing dotenv files use script defaults' -Expected @('', '', '')

    $dotenv = @('wslc', '22.1.0', '0.80.0')
    $lines = for ($i = 0; $i -lt $settings.Count; $i++) { "$($settings[$i])=$($dotenv[$i])" }
    Set-Content (Join-Path $temp '.devcontainer/.env') $lines
    Assert-Setting -Case 'consumer .devcontainer/.env' -Expected $dotenv

    Set-Content (Join-Path $temp '.env') 'DEVCONTAINER_DOCKER_PATH=podman'
    Assert-Setting -Case 'root .env wins; other keys come from .devcontainer/.env' -Expected @('podman', '22.1.0', '0.80.0')

    $cli = @('nerdctl', '24.1.0', '0.81.0')
    $taskVars = for ($i = 0; $i -lt $settings.Count; $i++) { "$($settings[$i])=$($cli[$i])" }
    Assert-Setting -Case 'CLI vars override dotenv' -Expected $cli -TaskVars $taskVars

    Remove-Item (Join-Path $temp '.env'), (Join-Path $temp '.devcontainer/.env') -Force
    $os = @('docker', '20.1.0', '0.79.0')
    for ($i = 0; $i -lt $settings.Count; $i++) {
        [Environment]::SetEnvironmentVariable($settings[$i], $os[$i])
    }
    Assert-Setting -Case 'OS environment without dotenv' -Expected $os
}
finally {
    foreach ($name in $settings) {
        if ($null -eq $saved[$name]) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}
