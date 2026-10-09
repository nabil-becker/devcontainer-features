<#
.SYNOPSIS
    Drives @devcontainers/cli against a workspace without installing Node.js
    or the CLI system-wide. Backs the devcontainer:* tasks in
    ../devcontainer.yml.

.DESCRIPTION
    On Windows: downloads a pinned, sha256-verified portable Node.js build
    once into %LOCALAPPDATA%\devcontainer-features\devcontainer-node, installs
    @devcontainers/cli next to it with that Node's npm, and runs the CLI's
    devcontainer.js entrypoint via node.exe directly (not npx.cmd - that is a
    cmd.exe batch shim, and cmd.exe's argument re-parsing silently eats
    backslashes).

    On Linux/macOS: uses `devcontainer` if it is on PATH (e.g. installed by
    the devcontainer-cli Feature), else `npx -y @devcontainers/cli`.

    Container engine: any docker-compatible CLI, passed to the devcontainer
    CLI as --docker-path. Chosen by DEVCONTAINER_DOCKER_PATH (a name on PATH
    such as docker, wslc, podman, nerdctl, finch - or a full path); when
    unset, `docker` on PATH is used, else wslc.exe (WSL Containers, WSL >=
    2.9.3) on Windows.

    Every setting here is read from an environment variable so a .env file
    (loaded by Task's dotenv: or by bootstrap.ps1) can drive it:
      DEVCONTAINER_DOCKER_PATH, DEVCONTAINER_NODE_VERSION,
      DEVCONTAINER_CLI_VERSION. Explicit parameters win over the environment.
#>

$script:CacheRoot = if ($IsWindows) { Join-Path $env:LOCALAPPDATA 'devcontainer-features\devcontainer-node' } else { $null }
$script:DefaultNodeVersion = '24.21.0'

function Get-SettingOrEnv {
    <# .SYNOPSIS Explicit value if non-empty, else the environment variable, else the default. #>
    [CmdletBinding()]
    param([string]$Value, [string]$EnvName, [string]$Default = '')
    if ($Value) { return $Value }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv) { return $fromEnv }
    return $Default
}

function ConvertFrom-TaskCliArgString {
    <#
    .SYNOPSIS
        Decodes the CLI_ARGS a Taskfile task passes as
        -CliArgsB64 '{{.CLI_ARGS | splitArgs | toJson | b64enc}}' back into
        an argument array. Passing {{.CLI_ARGS}} straight to `pwsh -File`
        lets PowerShell's parameter binder see them first (`-w` becomes
        ambiguous, `--remove-existing-container` is rejected), so Task splits
        them shell-style and encodes them as one opaque string.
    #>
    [CmdletBinding()]
    param([string]$CliArgsB64)

    if (-not $CliArgsB64) { return , @() }
    $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CliArgsB64))
    # No CLI_ARGS encodes as JSON null; drop it rather than pass "".
    return , [string[]]@($json | ConvertFrom-Json | Where-Object { $null -ne $_ -and $_ -ne '' })
}

function Get-PortableNodeDir {
    [CmdletBinding()]
    param([string]$Version)
    $Version = Get-SettingOrEnv $Version 'DEVCONTAINER_NODE_VERSION' $script:DefaultNodeVersion

    $nodeDir = Join-Path $script:CacheRoot "node-v$Version-win-x64"
    $nodeExe = Join-Path $nodeDir 'node.exe'
    if (Test-Path $nodeExe) { return $nodeDir }

    Write-Host "Downloading portable Node.js v$Version (one-time; cached under $script:CacheRoot)..."
    New-Item -ItemType Directory -Path $script:CacheRoot -Force | Out-Null
    $zipName = "node-v$Version-win-x64.zip"
    $zipPath = Join-Path $script:CacheRoot $zipName
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "https://nodejs.org/dist/v$Version/$zipName" -OutFile $zipPath
        $sums = (Invoke-WebRequest -UseBasicParsing -Uri "https://nodejs.org/dist/v$Version/SHASUMS256.txt").Content
        $line = $sums -split "`n" | Where-Object { $_ -match ('\s' + [regex]::Escape($zipName) + '\s*$') } | Select-Object -First 1
        if (-not $line) { throw "Could not find $zipName in nodejs.org SHASUMS256.txt for v$Version." }
        $expected = ($line.Trim() -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "SHA-256 mismatch for $zipName (expected $expected, got $actual)." }
        Expand-Archive -Path $zipPath -DestinationPath $script:CacheRoot -Force
    }
    finally {
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $nodeExe)) { throw "Portable Node.js extraction failed - expected $nodeExe to exist." }
    return $nodeDir
}

function Get-DevcontainersCliEntrypoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NodeDir,
        [string]$CliVersion
    )
    $CliVersion = Get-SettingOrEnv $CliVersion 'DEVCONTAINER_CLI_VERSION' 'latest'

    $cliDir = Join-Path $script:CacheRoot 'devcontainers-cli'
    $pkgDir = Join-Path $cliDir 'node_modules\@devcontainers\cli'
    $entrypoint = Join-Path $pkgDir 'devcontainer.js'

    if (Test-Path $entrypoint) {
        if ($CliVersion -eq 'latest') { return $entrypoint }
        $installed = (Get-Content (Join-Path $pkgDir 'package.json') -Raw | ConvertFrom-Json).version
        if ($installed -eq $CliVersion) { return $entrypoint }
        Write-Host "Cached @devcontainers/cli is $installed; replacing with $CliVersion..."
    }
    else {
        Write-Host "Installing @devcontainers/cli@$CliVersion (one-time; cached at $cliDir)..."
    }

    New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
    $pkg = if ($CliVersion -eq 'latest') { '@devcontainers/cli' } else { "@devcontainers/cli@$CliVersion" }
    # npm-cli.js via node.exe, for the same cmd.exe-shim reason as the CLI itself.
    # Out-Host: anything npm prints to stdout would otherwise become part of
    # this function's return value alongside $entrypoint.
    $npmCli = Join-Path $NodeDir 'node_modules\npm\bin\npm-cli.js'
    & (Join-Path $NodeDir 'node.exe') $npmCli install $pkg --no-save --no-audit --no-fund --loglevel=error --prefix $cliDir | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "npm install $pkg failed with exit code $LASTEXITCODE." }
    if (-not (Test-Path $entrypoint)) { throw "@devcontainers/cli install failed - expected $entrypoint to exist." }
    return $entrypoint
}

function Remove-DevcontainersCli {
    <# .SYNOPSIS Drops the cached @devcontainers/cli so the next call reinstalls it. #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $cliDir = Join-Path $script:CacheRoot 'devcontainers-cli'
    if ((Test-Path $cliDir) -and $PSCmdlet.ShouldProcess($cliDir, 'Remove cached @devcontainers/cli')) {
        Write-Host "Removing cached @devcontainers/cli at $cliDir..."
        Remove-Item -Path $cliDir -Recurse -Force
    }
}

function Resolve-DockerPath {
    <#
    .SYNOPSIS
        Resolves the docker-compatible CLI to hand to `devcontainer
        --docker-path`. Returns $null when the devcontainer CLI's own default
        (`docker` on PATH) should be used.

    .PARAMETER DockerPath
        A command name on PATH (docker, wslc, podman, nerdctl, finch, ...) or
        a full path. Falls back to $env:DEVCONTAINER_DOCKER_PATH, then to
        auto-detection: docker on PATH, else wslc.exe on Windows.
    #>
    [CmdletBinding()]
    param([string]$DockerPath)

    $wslcFallback = 'C:\Program Files\WSL\wslc.exe'
    $spec = Get-SettingOrEnv $DockerPath 'DEVCONTAINER_DOCKER_PATH'

    if ($spec) {
        if ($spec -eq 'docker') { return $null }
        if (Test-Path -LiteralPath $spec -PathType Leaf) { return (Resolve-Path -LiteralPath $spec).Path }
        $cmd = Get-Command $spec -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        if ($IsWindows -and $spec -in 'wslc', 'wslc.exe' -and (Test-Path $wslcFallback)) { return $wslcFallback }
        throw "DEVCONTAINER_DOCKER_PATH / -DockerPath '$spec' is neither a file nor a command on PATH."
    }

    if (Get-Command docker -ErrorAction SilentlyContinue) { return $null }
    if ($IsWindows) {
        $wslc = Get-Command wslc.exe -ErrorAction SilentlyContinue
        if ($wslc) { return $wslc.Source }
        if (Test-Path $wslcFallback) { return $wslcFallback }
        throw 'No container engine found: install Docker Desktop (docker on PATH), WSL >= 2.9.3 for wslc.exe, or set DEVCONTAINER_DOCKER_PATH.'
    }
    throw 'docker is not on PATH; install a Docker-compatible engine or set DEVCONTAINER_DOCKER_PATH.'
}

function Invoke-DevcontainerCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Subcommand,
        [Parameter(Mandatory)][string]$WorkspaceFolder,
        [string[]]$Arguments = @(),
        [string]$CommandB64,
        [string]$NodeVersion,
        [string]$CliVersion,
        [string]$DockerPath
    )

    $WorkspaceFolder = (Resolve-Path $WorkspaceFolder).Path
    $cliArgs = @($Subcommand)
    # Subcommands that operate on a workspace take --workspace-folder;
    # `features ...` and `templates ...` do not.
    if ($Subcommand -in 'up', 'set-up', 'build', 'run-user-commands', 'read-configuration', 'outdated', 'upgrade', 'exec') {
        $cliArgs += @('--workspace-folder', $WorkspaceFolder)
    }

    if ($IsWindows) {
        $nodeDir = Get-PortableNodeDir -Version $NodeVersion
        $entrypoint = Get-DevcontainersCliEntrypoint -NodeDir $nodeDir -CliVersion $CliVersion
        $exe = Join-Path $nodeDir 'node.exe'
        $cliArgs = @($entrypoint) + $cliArgs
    }
    elseif (Get-Command devcontainer -ErrorAction SilentlyContinue) {
        $exe = 'devcontainer'
    }
    else {
        $exe = 'npx'
        $cliArgs = @('-y', '@devcontainers/cli') + $cliArgs
    }

    $engine = Resolve-DockerPath -DockerPath $DockerPath
    if ($engine) {
        Write-Host "Container engine: $engine"
        $cliArgs += @('--docker-path', $engine)
    }

    if ($CommandB64) {
        if ($Subcommand -ne 'exec') { throw "-CommandB64 is only meaningful with -Subcommand exec (got '$Subcommand')." }
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CommandB64))
        $cliArgs += @('bash', '-lc', $decoded)
    }
    else {
        $cliArgs += $Arguments
    }

    & $exe @cliArgs
    if ($LASTEXITCODE -ne 0) {
        $hint = if ($Subcommand -eq 'exec') { ' Is the container running? Start it with: task devcontainer:up' } else { '' }
        throw "devcontainer $Subcommand failed with exit code $LASTEXITCODE.$hint"
    }
}

Export-ModuleMember -Function Get-SettingOrEnv, ConvertFrom-TaskCliArgString, Get-PortableNodeDir, Get-DevcontainersCliEntrypoint, Remove-DevcontainersCli, Resolve-DockerPath, Invoke-DevcontainerCli
