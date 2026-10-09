<#
.SYNOPSIS
    Resets wslc.exe's (WSL Containers) backing storage disk after it gets
    stuck returning "read-only file system" errors mid-build - a known
    BuildKit bug in early WSL Containers releases. Destructive: deletes every
    image and container wslc knows about. Only relevant when the container
    engine is wslc, not Docker Desktop.
#>
[CmdletBinding()]
param([string]$SessionName = "wslc-cli-$env:USERNAME")

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Reset-WslcStorage.ps1 is Windows-only.' }

Import-Module (Join-Path $PSScriptRoot 'DevcontainerCli.psm1') -Force
$wslc = Resolve-DockerPath -DockerPath 'wslc'

Write-Host 'Terminating the wslc session (if any)...'
& $wslc system session terminate 2>&1 | Out-Null
Start-Sleep -Seconds 2

$storagePath = Join-Path $env:LOCALAPPDATA "wslc\sessions\$SessionName\storage.vhdx"
if (Test-Path $storagePath) {
    Write-Host "Deleting $storagePath (all wslc images/containers will be lost)..."
    Remove-Item -Path $storagePath -Force
    Write-Host 'Done. The next wslc command recreates it from scratch.'
}
else {
    Write-Host "No storage disk found at $storagePath - nothing to reset."
}
