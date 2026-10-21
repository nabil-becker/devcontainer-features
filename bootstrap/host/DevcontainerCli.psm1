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

    Image builds are serialised host-wide: `up` and `build` hold the named
    mutex Global\devcontainer-features-build while they run (see
    Enter-DevcontainerBuildLock). DEVCONTAINER_BUILD_LOCK=0 turns that off.
#>

$script:CacheRoot = if ($IsWindows) { Join-Path $env:LOCALAPPDATA 'devcontainer-features\devcontainer-node' } else { $null }
$script:DefaultNodeVersion = '24.21.0'
$script:BuildLockName = 'Global\devcontainer-features-build'
# The subcommands that build an image. `up` also covers `rebuild` (up
# --remove-existing-container). `run-user-commands`, `set-up` and `exec` work on a
# container that exists, so they take no lock.
$script:BuildSubcommands = @('up', 'build')

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

function Get-WorkspaceFolderVariant {
    <#
    .SYNOPSIS
        The folder as given, then with the drive letter lowercased, then
        uppercased (only for an X:\ path), without repeats. `devcontainer up`
        labels the container with a lowercase drive letter while the folder
        reaches the scripts with an uppercase one, and the engine's label
        filter is case-sensitive.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceFolder)

    $variants = [System.Collections.Generic.List[string]]::new()
    $variants.Add($WorkspaceFolder)
    if ($WorkspaceFolder -match '^[A-Za-z]:[\\/]') {
        $rest = $WorkspaceFolder.Substring(1)
        foreach ($v in @(($WorkspaceFolder[0].ToString().ToLowerInvariant() + $rest), ($WorkspaceFolder[0].ToString().ToUpperInvariant() + $rest))) {
            if (-not $variants.Contains($v)) { $variants.Add($v) }
        }
    }
    return , $variants.ToArray()
}

function Get-RunningDevcontainerId {
    <#
    .SYNOPSIS
        The ids of the running container(s) of a workspace, found by the
        devcontainer.local_folder label `devcontainer up` puts on them (the
        folder as given, else with the drive letter in the other cases); empty
        when none runs. Throws when the engine cannot list containers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceFolder,
        [string]$DockerPath
    )

    $WorkspaceFolder = (Resolve-Path $WorkspaceFolder).Path
    $engine = Resolve-DockerPath -DockerPath $DockerPath
    if (-not $engine) { $engine = 'docker' }
    foreach ($variant in (Get-WorkspaceFolderVariant -WorkspaceFolder $WorkspaceFolder)) {
        $ids = @(& $engine ps -q --filter "label=devcontainer.local_folder=$variant")
        if ($LASTEXITCODE -ne 0) { throw "$engine could not list containers (exit code $LASTEXITCODE)." }
        $ids = @($ids | Where-Object { $_ })
        if ($ids.Count -gt 0) { return $ids }
    }
    return @()
}

function Stop-Devcontainer {
    <#
    .SYNOPSIS
        Stops the running container(s) of a workspace through the configured
        engine. The CLI has no stop: the container is found by the
        devcontainer.local_folder label `devcontainer up` puts on it.
        Nothing running = "already stopped", exit 0. Unless -Force, the
        command in -CommandB64 (the shutdown check) first runs inside the
        container; when it fails, the stop is refused with its exit code.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$WorkspaceFolder,
        [string]$DockerPath,
        [string]$CommandB64,
        [switch]$Force,
        [string]$NodeVersion,
        [string]$CliVersion
    )

    $WorkspaceFolder = (Resolve-Path $WorkspaceFolder).Path
    $engine = Resolve-DockerPath -DockerPath $DockerPath
    $engineShown = if ($engine) { $engine } else { 'docker' }
    try { $ids = @(Get-RunningDevcontainerId -WorkspaceFolder $WorkspaceFolder -DockerPath $DockerPath) }
    catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        [Console]::Error.WriteLine("the container engine ($engineShown) could not be reached.")
        exit 2
    }
    if ($ids.Count -eq 0) {
        Write-Host "No running devcontainer for ${WorkspaceFolder}: already stopped."
        return
    }
    if ($Force) {
        Write-Host 'FORCE set: skipping the shutdown check.'
    }
    elseif ($CommandB64) {
        $check = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CommandB64))
        Write-Host "Running the shutdown check ($check); if it fails the stop is refused."
        Invoke-DevcontainerCliProcess -Subcommand exec -WorkspaceFolder $WorkspaceFolder -CommandB64 $CommandB64 `
            -NodeVersion $NodeVersion -CliVersion $CliVersion -DockerPath $DockerPath
        $rc = $script:CliExitCode
        if ($rc -ne 0) {
            [Console]::Error.WriteLine("Not stopping: the shutdown check ($check) found the problems above. Fix them (shutdown-devhost skill) or run again with FORCE=1.")
            exit $rc
        }
    }
    Write-Host "Container engine: $engineShown"
    if ($PSCmdlet.ShouldProcess($WorkspaceFolder, "Stop container(s) $($ids -join ' ')")) {
        & $engineShown stop @ids
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("$engineShown stop failed with exit code $LASTEXITCODE.")
            exit $LASTEXITCODE
        }
    }
}

function Test-BuildSubcommand {
    <#
    .SYNOPSIS
        $true for a subcommand that builds an image and so takes the build lock.
        `features test` builds too, but takes the lock only with
        DEVCONTAINER_BUILD_LOCK_FEATURES_TEST=true (default false): a long test
        run would hold up every repository's rebuild.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Subcommand, [string[]]$Arguments = @())
    if ($Subcommand -in $script:BuildSubcommands) { return $true }
    if ($Subcommand -eq 'features' -and $Arguments.Count -gt 0 -and $Arguments[0] -eq 'test') {
        return (Get-SettingOrEnv '' 'DEVCONTAINER_BUILD_LOCK_FEATURES_TEST' 'false') -in @('true', '1')
    }
    return $false
}

function Enter-DevcontainerBuildLock {
    <#
    .SYNOPSIS
        Takes the host-wide build lock, waiting for another devcontainer
        build to finish first. Returns the held mutex for
        Exit-DevcontainerBuildLock, or $null when DEVCONTAINER_BUILD_LOCK=0.

    .DESCRIPTION
        Why: when the engine has no BuildKit build context (wslc), the
        @devcontainers/cli tags the Feature content image with the fixed name
        `dev_container_feature_content_temp` for every repository, so two
        builds at once overwrite each other's image and the first fails with
        `"/tmp/build-features/<feature>_N": not found`.

        A named mutex rather than a lock file: the operating system releases
        it when the holder dies, so a crash can leave no stale lock behind,
        and an abandoned mutex (the holder died without releasing it) counts
        as acquired. The mutex belongs to the thread that took it, so enter
        and exit in the same script, as Invoke-DevcontainerCli does.

    .PARAMETER Name
        Mutex name; the default is shared by every repository on the host.
    #>
    [CmdletBinding()]
    param([string]$Name = $script:BuildLockName)

    if ((Get-SettingOrEnv '' 'DEVCONTAINER_BUILD_LOCK') -eq '0') { return $null }

    $mutex = [System.Threading.Mutex]::new($false, $Name)
    $announced = $false
    while ($true) {
        try {
            # 500 ms slices, not an endless wait, so Ctrl+C is honoured while waiting.
            if ($mutex.WaitOne(500)) { return $mutex }
        }
        catch [System.Threading.AbandonedMutexException] {
            # The holder died without releasing; the mutex is now ours.
            return $mutex
        }
        if (-not $announced) {
            Write-Host 'waiting for another devcontainer build to finish...'
            $announced = $true
        }
    }
}

function Exit-DevcontainerBuildLock {
    <# .SYNOPSIS Releases the lock Enter-DevcontainerBuildLock returned (a $null is ignored). #>
    [CmdletBinding()]
    param($Lock)
    if (-not $Lock) { return }
    try { $Lock.ReleaseMutex() } finally { $Lock.Dispose() }
}

function Invoke-DevcontainerCliProcess {
    <# .SYNOPSIS One @devcontainers/cli call; its exit code is left in $script:CliExitCode (no throw for a failing CLI). #>
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

    # Only the subcommands that drive an engine take --docker-path;
    # `features ...`, `templates ...` and `outdated` reject it.
    if ($Subcommand -in 'up', 'set-up', 'build', 'run-user-commands', 'read-configuration', 'upgrade', 'exec') {
        $engine = Resolve-DockerPath -DockerPath $DockerPath
        if ($engine) {
            Write-Host "Container engine: $engine"
            $cliArgs += @('--docker-path', $engine)
        }
    }

    if ($CommandB64) {
        if ($Subcommand -ne 'exec') { throw "-CommandB64 is only meaningful with -Subcommand exec (got '$Subcommand')." }
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CommandB64))
        $cliArgs += @('bash', '-lc', $decoded)
    }
    else {
        $cliArgs += $Arguments
    }

    # Not returned: the CLI's own output must reach the console (a pipeline
    # would capture it, and Out-Host would take away an interactive terminal).
    & $exe @cliArgs
    $script:CliExitCode = $LASTEXITCODE
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
        [string]$DockerPath,
        [switch]$Force
    )

    # `stop` is not a CLI subcommand: the whole of it (running? check? stop?)
    # is one command here.
    if ($Subcommand -eq 'stop') {
        Stop-Devcontainer -WorkspaceFolder $WorkspaceFolder -DockerPath $DockerPath -CommandB64 $CommandB64 -Force:$Force `
            -NodeVersion $NodeVersion -CliVersion $CliVersion
        return
    }

    # `running` is not a CLI subcommand either: exit 0 when a container of the
    # workspace runs, 1 when none does, 2 when the engine cannot be asked.
    if ($Subcommand -eq 'running') {
        try { $ids = @(Get-RunningDevcontainerId -WorkspaceFolder $WorkspaceFolder -DockerPath $DockerPath) }
        catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            [Console]::Error.WriteLine("the container engine could not be reached.")
            exit 2
        }
        if ($ids.Count -gt 0) { exit 0 } else { exit 1 }
    }

    # An image build takes the host-wide lock (see Enter-DevcontainerBuildLock);
    # the CLI's own temp image name is shared by every repository.
    $lock = if (Test-BuildSubcommand -Subcommand $Subcommand -Arguments $Arguments) { Enter-DevcontainerBuildLock }
    try {
        Invoke-DevcontainerCliProcess -Subcommand $Subcommand -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments `
            -CommandB64 $CommandB64 -NodeVersion $NodeVersion -CliVersion $CliVersion -DockerPath $DockerPath
    }
    finally { Exit-DevcontainerBuildLock -Lock $lock }
    $rc = $script:CliExitCode
    if ($rc -eq 0) { return }

    if ($Subcommand -ne 'exec') { throw "devcontainer $Subcommand failed with exit code $rc." }

    # A failed exec: say which of three things failed, by asking the engine.
    $folder = (Resolve-Path $WorkspaceFolder).Path
    try { $ids = @(Get-RunningDevcontainerId -WorkspaceFolder $folder -DockerPath $DockerPath) }
    catch {
        $engine = Resolve-DockerPath -DockerPath $DockerPath
        [Console]::Error.WriteLine($_.Exception.Message)
        [Console]::Error.WriteLine("the container engine ($(if ($engine) { $engine } else { 'docker' })) could not be reached.")
        exit 2
    }
    if ($ids.Count -eq 0) {
        [Console]::Error.WriteLine("No running devcontainer for $folder. Start it with: task dc:start")
        exit 1
    }
    $text = if ($CommandB64) { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CommandB64)) } else { $Arguments -join ' ' }
    if ($text.Length -gt 80) { $text = $text.Substring(0, 80) }
    [Console]::Error.WriteLine("The command exited with code $rc inside the devcontainer: $text (its output is above).")
    exit $rc
}

Export-ModuleMember -Function Get-SettingOrEnv, ConvertFrom-TaskCliArgString, Get-PortableNodeDir, Get-DevcontainersCliEntrypoint, Remove-DevcontainersCli, Resolve-DockerPath, Get-WorkspaceFolderVariant, Get-RunningDevcontainerId, Stop-Devcontainer, Test-BuildSubcommand, Enter-DevcontainerBuildLock, Exit-DevcontainerBuildLock, Invoke-DevcontainerCliProcess, Invoke-DevcontainerCli
