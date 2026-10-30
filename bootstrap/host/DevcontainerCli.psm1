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

    Host type: HOST_TYPE (default auto) names the kind of host - windows-docker,
    windows-wsl-docker, windows-wslc, linux, macos - and HOST_TYPE_PRIORITY
    (ordered comma list) says which `auto` tries first. The engine follows the
    host type unless DEVCONTAINER_DOCKER_PATH is set, which always wins. Before
    the CLI runs, DCF_HOST_TYPE, DCF_HOST_HOME, DCF_HOST_SSH_AGENT and DCF_HOST_CLOUD_FOLDER are
    set in this process (see Resolve-HostProfile; `host` prints them).

    Every setting here is read from an environment variable so a .env file
    (loaded by Task's dotenv: or by bootstrap.ps1) can drive it:
      DEVCONTAINER_DOCKER_PATH, DEVCONTAINER_NODE_VERSION,
      DEVCONTAINER_CLI_VERSION, HOST_TYPE, HOST_TYPE_PRIORITY, HOST_MOUNTS, SSH_AGENT_MODE,
      DCF_HOST_CLOUD_FOLDER, DCF_HOST_FUSE. Explicit parameters win over the environment.

    DCF_HOST_MACHINE is always the launcher's own value: the workstation's machine name
    ($env:COMPUTERNAME on Windows, else the host name before its first dot), cut to letters, digits,
    dot, underscore and hyphen (at most 63 characters). `up` and `host` warn once when the
    repository's devcontainer.json does not read it with ${localEnv:DCF_HOST_MACHINE}.

    FUSE on request (cloud-folder Feature, mount mode; ADR 0031): DCF_HOST_FUSE=1 (or true, yes,
    on) sets DCF_HOST_FUSE_DEVICE, DCF_HOST_FUSE_CAP and DCF_HOST_FUSE_SECURITY to
    --device=/dev/fuse, --cap-add=SYS_ADMIN and --security-opt=apparmor=unconfined for the CLI,
    which the repository's runArgs read with ${localEnv:<name>:<default>} (the CLI has no option
    for run arguments; the bootstrap's devcontainer.json carries the lines). Unset, the three are
    removed. Never granted by default; `up` warns when the repository's devcontainer.json lacks
    the lines (Get-FuseSlotMissing). Not granted on windows-wslc (or an engine named wslc): wslc
    run has no --device, --cap-add or --security-opt option and would refuse the start, so `up`
    warns once and starts the container without FUSE (Get-FuseRefusal, Write-FuseRefusedWarning).

    Host mounts: `up` (so `rebuild`) adds the mounts the host type needs with
    `--mount type=bind,source=...,target=...` (Get-HostMount; slice 3: the
    `.git-dirs` folder of the host home at /git-dirs; slice 4: the SSH agent socket at
    /var/lib/devcontainer-features/ssh-agent/agent.sock where the host type has one),
    so a repository declares none. DCF_HOST_SSH_AGENT is socket, none or key
    (SSH_AGENT_MODE=key, the opt-in to a key in the container, also suppresses the mount). The
    host folder DCF_HOST_CLOUD_FOLDER, when set, goes to the cloud-folder Feature's fixed host mount
    /mnt/cloud-folder-host (the Feature links its mountPoint there); it is never created, and
    skipped with a warning when it does not exist on this host. A mount whose target the repository's devcontainer.json already mounts is
    skipped, with one line saying so. HOST_MOUNTS=false turns the launcher's mounts
    off. `build` mounts nothing and `exec` runs in an existing container: neither
    takes them.

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

function Invoke-DcfDownload {
    # Invoke-WebRequest's own -MaximumRetryCount retries only HTTP statuses (408, 429, 5xx), never a reset
    # connection or a cut transfer, so retry on any exception: 4 attempts in all, a pause between them, a
    # partial -OutFile removed before each retry, the last error rethrown. Returns the response without -OutFile.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [string]$OutFile, [int]$RetryIntervalSec = 2)
    for ($attempt = 1; ; $attempt++) {
        try {
            if ($OutFile) { Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile }
            else { return Invoke-WebRequest -UseBasicParsing -Uri $Uri }
            return
        }
        catch {
            if ($OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
            if ($attempt -ge 4) { throw }
            Start-Sleep -Seconds $RetryIntervalSec
        }
    }
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
        Invoke-DcfDownload -Uri "https://nodejs.org/dist/v$Version/$zipName" -OutFile $zipPath
        $sums = (Invoke-DcfDownload -Uri "https://nodejs.org/dist/v$Version/SHASUMS256.txt").Content
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

    # No explicit command: the engine follows the host type (HOST_TYPE, see Resolve-HostType).
    return (Resolve-EngineForHostType -Type (Get-CachedHostType).Type)
}

# ------------------------------------------------------------ host type ----
# HOST_TYPE says what kind of host the launcher runs on (docs/proposals/host-profile.md,
# ADR 0024). The bash twin (src/devcontainer-cli/devcontainer-cli.sh) does the same;
# keep the two in step (test/bootstrap/host_type_test.sh and DevcontainerCli.Tests.ps1).
$script:HostTypeIds = @('windows-docker', 'windows-wsl-docker', 'windows-wslc', 'linux', 'macos')
$script:HostProfileCache = @{}

function Clear-HostProfileCache { <# .SYNOPSIS Forgets the resolved host profile (tests; the cache lives one launcher run). #> $script:HostProfileCache = @{} }

# --- evidence, one small function each so a test can replace it -------------
function Get-HostPlatform {
    <# .SYNOPSIS 'windows', 'macos', 'wsl' (pwsh inside a WSL distro) or 'linux'. #>
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    if (Test-InsideWsl) { return 'wsl' }
    return 'linux'
}
function Test-InsideWsl {
    if ($env:WSL_DISTRO_NAME) { return $true }
    # Unverified here: the WSL kernel string names Microsoft in /proc/version.
    if (Test-Path -LiteralPath '/proc/version') { return [bool](Select-String -Path '/proc/version' -Pattern 'microsoft' -Quiet) }
    return $false
}
function Test-DockerResponding {
    <# .SYNOPSIS $true when `docker` is on PATH and `docker info` exits 0 (a stopped daemon fails it). #>
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}
function Test-WslDockerResponding {
    <# .SYNOPSIS $true when `wsl -e docker info` answers: Docker Engine in the default WSL distro. UNVERIFIED on a real Windows host: assumes the default distro and wsl.exe on PATH. #>
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    & wsl.exe -e docker info *> $null
    return ($LASTEXITCODE -eq 0)
}
function Get-WslcPath {
    <# .SYNOPSIS wslc.exe from PATH, else C:\Program Files\WSL\wslc.exe, else $null (as Resolve-DockerPath did). #>
    $wslc = Get-Command wslc.exe -ErrorAction SilentlyContinue
    if ($wslc) { return $wslc.Source }
    if (Test-Path 'C:\Program Files\WSL\wslc.exe') { return 'C:\Program Files\WSL\wslc.exe' }
    return $null
}
function Test-HostSocket {
    <# .SYNOPSIS $true when the path exists and is not a directory (a unix socket; a test replaces this). #>
    param([string]$Path)
    return [bool]$Path -and (Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $Path -PathType Container)
}
function Get-WslHome {
    <# .SYNOPSIS The default WSL distro's $HOME, asked through wsl.exe (windows-wsl-docker from Windows). #>
    $h = (& wsl.exe -e sh -c 'printf %s "$HOME"') -join ''
    if ($LASTEXITCODE -ne 0 -or -not $h) { throw 'windows-wsl-docker: could not read $HOME of the default WSL distro (wsl -e sh -c ...).' }
    return $h
}

function Get-HostTypeId { <# .SYNOPSIS The known HOST_TYPE ids. #> return , $script:HostTypeIds }

function Get-DefaultHostTypePriority {
    <# .SYNOPSIS The default HOST_TYPE_PRIORITY for the OS the launcher runs on (proposal section 3). #>
    switch (Get-HostPlatform) {
        'windows' { return @('windows-docker', 'windows-wsl-docker', 'windows-wslc') }
        'wsl' { return @('windows-wsl-docker') }
        'macos' { return @('macos') }
        default { return @('linux') }
    }
}

function ConvertTo-HostTypeList {
    <# .SYNOPSIS Splits an ordered comma list, rejecting an unknown id with the list of valid ones. #>
    param([string]$Text, [string]$Setting)
    $ids = @($Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($id in $ids) {
        if ($id -notin $script:HostTypeIds) {
            throw "$Setting has an unknown host type '$id'. Known ids: $($script:HostTypeIds -join ', ')."
        }
    }
    return , $ids
}

function Test-HostTypeFitsPlatform {
    <# .SYNOPSIS $true when a launcher on this OS can act as that host type at all (no engine questions). #>
    param([Parameter(Mandatory)][string]$Id)
    switch ($Id) {
        'windows-docker' { return (Get-HostPlatform) -eq 'windows' }
        'windows-wslc' { return (Get-HostPlatform) -eq 'windows' }
        'windows-wsl-docker' { return (Get-HostPlatform) -in 'windows', 'wsl' }
        'linux' { return (Get-HostPlatform) -in 'linux', 'wsl' }
        'macos' { return (Get-HostPlatform) -eq 'macos' }
    }
    return $false
}

function Test-HostTypeDetection {
    <# .SYNOPSIS Detection of one id, with what was found. Returns @{ Ok; Note }. The checks are the ones the proposal names. #>
    param([Parameter(Mandatory)][string]$Id)
    if (-not (Test-HostTypeFitsPlatform -Id $Id)) { return @{ Ok = $false; Note = "the launcher runs on $(Get-HostPlatform), not a host for $Id" } }
    switch ($Id) {
        'windows-docker' {
            if (Test-DockerResponding) { return @{ Ok = $true; Note = '`docker info` answers' } }
            return @{ Ok = $false; Note = '`docker` is not on PATH or `docker info` fails' }
        }
        'windows-wsl-docker' {
            if ((Get-HostPlatform) -eq 'wsl') { return @{ Ok = $true; Note = 'running inside a WSL distro' } }
            if (Test-WslDockerResponding) { return @{ Ok = $true; Note = '`wsl -e docker info` answers' } }
            return @{ Ok = $false; Note = '`wsl -e docker info` does not answer' }
        }
        'windows-wslc' {
            $p = Get-WslcPath
            if ($p) { return @{ Ok = $true; Note = "wslc.exe found ($p)" } }
            return @{ Ok = $false; Note = 'wslc.exe is not on PATH nor in C:\Program Files\WSL' }
        }
        'linux' { return @{ Ok = $true; Note = 'Linux, not WSL' } }
        'macos' { return @{ Ok = $true; Note = 'macOS' } }
    }
}

function Resolve-HostType {
    <#
    .SYNOPSIS
        The host type: HOST_TYPE (default auto; an explicit id skips detection),
        else the first id of HOST_TYPE_PRIORITY (default per OS) whose
        detection passes. Returns @{ Type; Why; Priority }. An unknown id is an
        error listing the valid ones.

    .DESCRIPTION
        DEVCONTAINER_DOCKER_PATH set and no id passing: the engine is given, so
        the first id of the priority list that fits this OS is taken (Why says so).
        Nothing passing and no DEVCONTAINER_DOCKER_PATH: an error naming each check.
    #>
    [CmdletBinding()]
    param([string]$HostType, [string]$Priority)

    $HostType = Get-SettingOrEnv $HostType 'HOST_TYPE' 'auto'
    $priorityText = Get-SettingOrEnv $Priority 'HOST_TYPE_PRIORITY'
    $source = 'HOST_TYPE_PRIORITY'
    $list = if ($priorityText) { ConvertTo-HostTypeList -Text $priorityText -Setting 'HOST_TYPE_PRIORITY' }
    else { $source = 'default for this OS'; @(Get-DefaultHostTypePriority) }

    if ($HostType -ne 'auto') {
        if ($HostType -notin $script:HostTypeIds) {
            throw "HOST_TYPE '$HostType' is unknown. Known ids: auto, $($script:HostTypeIds -join ', ')."
        }
        if (-not (Test-HostTypeFitsPlatform -Id $HostType)) {
            throw "HOST_TYPE '$HostType' cannot run from a launcher on $(Get-HostPlatform). Known ids: $($script:HostTypeIds -join ', ')."
        }
        return @{ Type = $HostType; Why = 'HOST_TYPE set explicitly (detection skipped)'; Priority = $list }
    }

    $notes = @()
    foreach ($id in $list) {
        $d = Test-HostTypeDetection -Id $id
        if ($d.Ok) { return @{ Type = $id; Why = "auto: first in $source to pass (${id}: $($d.Note))"; Priority = $list } }
        $notes += "$id`: $($d.Note)"
    }
    if (Get-SettingOrEnv '' 'DEVCONTAINER_DOCKER_PATH') {
        $fit = $list | Where-Object { Test-HostTypeFitsPlatform -Id $_ } | Select-Object -First 1
        if ($fit) { return @{ Type = $fit; Why = "auto: no check passed, DEVCONTAINER_DOCKER_PATH names the engine, so the first id in $source that fits this OS ($($notes -join '; '))"; Priority = $list } }
    }
    throw "HOST_TYPE=auto: no host type in [$($list -join ', ')] passed. $($notes -join '; '). Set HOST_TYPE=<id> ($($script:HostTypeIds -join ', ')), or HOST_TYPE_PRIORITY, or DEVCONTAINER_DOCKER_PATH."
}

function Get-CachedHostType {
    $key = "$env:HOST_TYPE|$env:HOST_TYPE_PRIORITY|$env:DEVCONTAINER_DOCKER_PATH"
    if (-not $script:HostProfileCache.ContainsKey($key)) { $script:HostProfileCache[$key] = Resolve-HostType }
    return $script:HostProfileCache[$key]
}

function Resolve-EngineForHostType {
    <# .SYNOPSIS The engine for a host type when DEVCONTAINER_DOCKER_PATH is unset: $null = `docker` on PATH (the CLI's default), else a full path. #>
    param([Parameter(Mandatory)][string]$Type)
    switch ($Type) {
        'windows-wslc' {
            $p = Get-WslcPath
            if ($p) { return $p }
            throw 'HOST_TYPE windows-wslc: wslc.exe not found (WSL >= 2.9.3), or set DEVCONTAINER_DOCKER_PATH.'
        }
        'windows-wsl-docker' {
            if (Get-Command docker -ErrorAction SilentlyContinue) { return $null }
            # --docker-path takes one executable, so `wsl -e docker` cannot be passed from Windows.
            throw 'HOST_TYPE windows-wsl-docker from Windows needs a single command for --docker-path: put a docker CLI on PATH that talks to the distro, or set DEVCONTAINER_DOCKER_PATH.'
        }
        default {
            if (Get-Command docker -ErrorAction SilentlyContinue) { return $null }
            if ($Type -eq 'windows-docker') { throw 'HOST_TYPE windows-docker: docker is not on PATH; install Docker Desktop or set DEVCONTAINER_DOCKER_PATH.' }
            throw 'docker is not on PATH; install a Docker-compatible engine or set DEVCONTAINER_DOCKER_PATH.'
        }
    }
}

function Resolve-SshAgent {
    <#
    .SYNOPSIS
        The SSH agent for a host type (proposal section 5): @{ Mode = socket|none|key; Socket }.
    .DESCRIPTION
        SSH_AGENT_MODE=key is the user's opt-in to a signing key kept in the container: Mode key,
        no socket mounted. Otherwise linux and windows-wsl-docker (from inside the distro) take
        $env:SSH_AUTH_SOCK when it is set and a socket exists; macos takes Docker Desktop's
        /run/host-services/ssh-auth.sock (a path in its VM, not checkable here); windows-docker,
        windows-wslc and windows-wsl-docker driven from Windows are none: the Windows agent is a
        named pipe and bridging it needs a process of ours left running on the host, which is
        ruled out. Mode none and key are reported by the container as such.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Type)
    if ((Get-SettingOrEnv '' 'SSH_AGENT_MODE') -eq 'key') { return @{ Mode = 'key'; Socket = '' } }
    switch ($Type) {
        { $_ -in 'linux', 'windows-wsl-docker' } {
            if ((Get-HostPlatform) -ne 'windows' -and (Test-HostSocket -Path $env:SSH_AUTH_SOCK)) { return @{ Mode = 'socket'; Socket = $env:SSH_AUTH_SOCK } }
        }
        'macos' { return @{ Mode = 'socket'; Socket = '/run/host-services/ssh-auth.sock' } }
    }
    return @{ Mode = 'none'; Socket = '' }
}

function Resolve-HostProfile {
    <#
    .SYNOPSIS
        Everything the launcher knows about the host: Type, Why, Priority, Engine
        (the command shown), EnginePath ($null = docker on PATH), and the three
        DCF_HOST_* values: Home, SshAgent (socket, none or key), SshSocket (the host
        socket the agent mount takes, or empty) and CloudFolder (DCF_HOST_CLOUD_FOLDER as given, or
        empty).
    #>
    [CmdletBinding()]
    param([string]$DockerPath)
    $t = Get-CachedHostType
    $spec = Get-SettingOrEnv $DockerPath 'DEVCONTAINER_DOCKER_PATH'
    # An engine problem is shown by `host`, not thrown from here: the CLI path throws it itself.
    $engineError = $null
    try { $enginePath = Resolve-DockerPath -DockerPath $DockerPath } catch { $enginePath = $null; $engineError = $_.Exception.Message }
    $engine = if ($engineError) { "(none: $engineError)" } elseif ($enginePath) { $enginePath } elseif ($spec) { $spec } else { 'docker' }
    $hostHome = switch ($t.Type) {
        'windows-docker' { $env:USERPROFILE }
        'windows-wslc' { $env:USERPROFILE }
        'windows-wsl-docker' { if ((Get-HostPlatform) -eq 'windows') { Get-WslHome } else { $env:HOME } }
        default { $env:HOME }
    }
    $agent = Resolve-SshAgent -Type $t.Type
    # FUSE: asked for (DCF_HOST_FUSE), and granted only where the engine takes the run arguments.
    $fuseAsked = Test-FuseRequested
    $fuseRefusal = Get-FuseRefusal -Type $t.Type -Engine $(if ($enginePath) { $enginePath } else { $spec })
    return [pscustomobject]@{
        Type = $t.Type; Why = $t.Why; Priority = $t.Priority
        Engine = $engine; EnginePath = $enginePath
        Home = $hostHome; SshAgent = $agent.Mode; SshSocket = $agent.Socket
        CloudFolder = (Get-SettingOrEnv '' 'DCF_HOST_CLOUD_FOLDER')
        Fuse = ($fuseAsked -and -not $fuseRefusal); FuseRequested = $fuseAsked; FuseRefusal = $fuseRefusal
    }
}

# FUSE on request (cloud-folder proposal, slice 3; ADR 0031; the bash twin's fuse_vars and
# fuse_args). A Feature's capAdd and securityOpt are static and `devcontainer up` has no option
# for run arguments, so the grant travels as three variables the repository's runArgs read.
$script:FuseGrant = [ordered]@{
    DCF_HOST_FUSE_DEVICE   = '--device=/dev/fuse'
    DCF_HOST_FUSE_CAP      = '--cap-add=SYS_ADMIN'
    DCF_HOST_FUSE_SECURITY = '--security-opt=apparmor=unconfined'
}

function Test-FuseRequested {
    <# .SYNOPSIS $true when DCF_HOST_FUSE (environment, or the parameter the entry script copies into it) is 1, true, yes or on. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ("$env:DCF_HOST_FUSE".Trim().ToLowerInvariant() -in '1', 'true', 'yes', 'on')
}

# wslc (WSL Containers 3.0.3: `wslc run --help`) has no --device, --cap-add or --security-opt
# option and refuses the whole run ("Option name was not recognized") when runArgs carry one, so
# on that engine the grant is withheld, with a warning: the container starts without FUSE and the
# cloud-folder Feature's auto mode takes sync.
function Get-FuseRefusal {
    <# .SYNOPSIS Why this host cannot carry the FUSE grant, or $null when it can: the windows-wslc host type, or an engine command named wslc, has no run option for a device, a capability or a security option. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Type, [AllowEmptyString()][string]$Engine = '')
    # Split on both separators: [IO.Path] on Linux or macOS leaves a Windows path whole.
    $leaf = if ($Engine) { [IO.Path]::GetFileNameWithoutExtension(($Engine -split '[\\/]')[-1]).ToLowerInvariant() } else { '' }
    if ($Type -eq 'windows-wslc' -or $leaf -eq 'wslc') {
        return 'wslc run (WSL Containers) has no --device, --cap-add or --security-opt option, so the cloud-folder Feature''s mount mode cannot run here; its auto mode takes sync'
    }
    return $null
}

function Get-FuseRunArgument {
    <# .SYNOPSIS The grant: an ordered map of DCF_HOST_FUSE_* to the run argument each carries; empty when not requested. #>
    [CmdletBinding()]
    param([bool]$Requested = (Test-FuseRequested))
    if (-not $Requested) { return [ordered]@{} }
    return $script:FuseGrant
}

function Get-FuseSlotMissing {
    <# .SYNOPSIS The DCF_HOST_FUSE_* names the repository's devcontainer.json does not read with ${localEnv:...} outside comments; none when there is no file. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceFolder, [string[]]$Arguments = @())
    $file = Get-DevcontainerConfigFile -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments
    if (-not $file) { return @() }
    $text = ConvertTo-JsonWithoutComment -Text (Get-Content -LiteralPath $file -Raw)
    return @($script:FuseGrant.Keys | Where-Object { -not $text.Contains('${localEnv:' + $_) })
}

function Write-FuseSlotWarning {
    <# .SYNOPSIS When FUSE is granted, one warning if the repository's devcontainer.json cannot carry the grant (none when the host refuses it: Write-FuseRefusedWarning says why). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceFolder, [string[]]$Arguments = @(), [string]$DockerPath)
    if (-not (Resolve-HostProfile -DockerPath $DockerPath).Fuse) { return }
    $missing = @(Get-FuseSlotMissing -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments)
    if ($missing.Count) {
        Write-Warning "DCF_HOST_FUSE=1, but the repository's devcontainer.json has no runArgs reading $($missing -join ' ') (`${localEnv:<name>:<default>}): FUSE does not reach the container. Copy the three runArgs lines from the bootstrap's devcontainer.json."
    }
}

function Write-FuseRefusedWarning {
    <# .SYNOPSIS When FUSE is asked for and this host cannot carry the grant, one warning naming why; the start goes on without FUSE. #>
    [CmdletBinding()]
    param([string]$DockerPath)
    $p = Resolve-HostProfile -DockerPath $DockerPath
    if ($p.FuseRequested -and $p.FuseRefusal) {
        Write-Warning "DCF_HOST_FUSE=1, but FUSE is not granted on this host ($($p.Type)): $($p.FuseRefusal). The container starts without it; unset DCF_HOST_FUSE in .devcontainer/.env on this machine to drop this warning."
    }
}

# The machine name (docs/proposals/session-names.md, slice 1; the bash twin's sanitise_machine and
# resolve_machine): DCF_HOST_MACHINE is the workstation's own name, $env:COMPUTERNAME on Windows,
# else the host name up to the first dot, cut to letters, digits, dot, underscore and hyphen (anything
# else becomes a hyphen, runs collapse, no leading or trailing hyphen or dot), at most 63 characters.
function ConvertTo-MachineName {
    <# .SYNOPSIS A machine name cut to the safe set [A-Za-z0-9._-]: other characters become hyphens, runs collapse, no leading or trailing hyphen or dot, at most 63 characters. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Name = '')
    $n = [regex]::Replace($Name, '[^A-Za-z0-9._-]', '-')
    $n = [regex]::Replace($n, '-+', '-')
    $n = $n.Trim('-', '.')
    if ($n.Length -gt 63) { $n = $n.Substring(0, 63).Trim('-', '.') }
    return $n
}

function Get-HostMachineName {
    <# .SYNOPSIS The workstation's machine name for DCF_HOST_MACHINE: $env:COMPUTERNAME, else the host name before its first dot, sanitised. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $raw = "$env:COMPUTERNAME"
    if (-not $raw) { $raw = ([System.Net.Dns]::GetHostName() -split '\.')[0] }
    return ConvertTo-MachineName -Name $raw
}

function Test-MachineSlotMissing {
    <# .SYNOPSIS $true when the repository's devcontainer.json (outside comments) does not read ${localEnv:DCF_HOST_MACHINE}; $false when it does or there is no file. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$WorkspaceFolder, [string[]]$Arguments = @())
    $file = Get-DevcontainerConfigFile -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments
    if (-not $file) { return $false }
    $text = ConvertTo-JsonWithoutComment -Text (Get-Content -LiteralPath $file -Raw)
    return -not $text.Contains('${localEnv:DCF_HOST_MACHINE')
}

function Write-MachineSlotWarning {
    <# .SYNOPSIS One warning, never a failure, when the repository's devcontainer.json lacks the DCF_HOST_MACHINE line. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceFolder, [string[]]$Arguments = @())
    if (Test-MachineSlotMissing -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments) {
        Write-Warning "The repository's devcontainer.json does not read DCF_HOST_MACHINE (`"DCF_HOST_MACHINE`": `"`${localEnv:DCF_HOST_MACHINE}`" in containerEnv): agents' session names show `"container`" for {machine} until it does. Copy the line from the bootstrap's devcontainer.json."
    }
}

function Initialize-HostEnvironment {
    <# .SYNOPSIS Sets DCF_HOST_TYPE, DCF_HOST_HOME, DCF_HOST_SSH_AGENT, DCF_HOST_CLOUD_FOLDER and the FUSE grant (DCF_HOST_FUSE and DCF_HOST_FUSE_*) in this process, so the devcontainer CLI (and ${localEnv:...} in a repo's devcontainer.json) sees them. Returns the profile. #>
    [CmdletBinding()]
    param([string]$DockerPath)
    $p = Resolve-HostProfile -DockerPath $DockerPath
    [Environment]::SetEnvironmentVariable('DCF_HOST_TYPE', $p.Type)
    [Environment]::SetEnvironmentVariable('DCF_HOST_HOME', $p.Home)
    [Environment]::SetEnvironmentVariable('DCF_HOST_SSH_AGENT', $p.SshAgent)
    # Passed on unchanged (the user's value), so containerEnv can map it; empty removes it.
    [Environment]::SetEnvironmentVariable('DCF_HOST_CLOUD_FOLDER', $p.CloudFolder)
    # The workstation's machine name: always the launcher's own value, empty removes it.
    $machine = Get-HostMachineName
    if ($machine) { [Environment]::SetEnvironmentVariable('DCF_HOST_MACHINE', $machine) }
    else { Remove-Item -LiteralPath 'Env:DCF_HOST_MACHINE' -ErrorAction SilentlyContinue }
    # The FUSE grant from the fixed list when asked for; removed otherwise, so a value left in the
    # user's environment or .env never reaches runArgs.
    [Environment]::SetEnvironmentVariable('DCF_HOST_FUSE', $(if ($p.Fuse) { '1' } else { '' }))
    $grant = Get-FuseRunArgument -Requested $p.Fuse
    foreach ($name in $script:FuseGrant.Keys) {
        # Remove-Item, not SetEnvironmentVariable(name, $null): PowerShell passes $null to a string
        # parameter as '', which on Linux and macOS leaves the variable set and empty, and an empty
        # value would replace runArgs' default with an empty argument.
        if ($grant.Contains($name)) { [Environment]::SetEnvironmentVariable($name, $grant[$name]) }
        else { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    }
    return $p
}

# ---------------------------------------------------------------- host mounts ----
# The mounts the launcher adds to `devcontainer up` (--mount), per host type: the host home's
# .git-dirs (slice 3), the SSH agent socket at the ssh-agent Feature's fixed path (slice 4), and
# the host folder DCF_HOST_CLOUD_FOLDER at the cloud-folder Feature's fixed host mount (cloud-folder
# proposal, slice 1; the same constant is cloud_folder_target in devcontainer-cli.sh and HOST_MOUNT
# in the Feature's install.sh). Add a case to the switch, or an entry to the array of a case: nothing else changes.
$script:SshAgentTarget = '/var/lib/devcontainer-features/ssh-agent/agent.sock'
$script:CloudFolderTarget = '/mnt/cloud-folder-host'
function Get-HostMount {
    <#
    .SYNOPSIS
        The host mounts for a host type: objects with Name, Source, Target and Type.
        git-dirs is empty when the home is unknown; ssh-agent is present only with
        -SshAgent socket and a -SshSocket source; cloud-folder only with a -CloudFolder source,
        always at /mnt/cloud-folder-host.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Type, [string]$HostHome, [string]$SshAgent = 'none', [string]$SshSocket, [string]$CloudFolder)
    $mounts = @()
    if ($HostHome) {
        switch ($Type) {
            { $_ -in 'windows-docker', 'windows-wsl-docker', 'windows-wslc', 'linux', 'macos' } {
                # Windows homes are C:\Users\<user>; the engine accepts the mixed form that
                # ${localEnv:USERPROFILE}/.git-dirs has always produced, so the same is built here.
                $mounts += [pscustomobject]@{ Name = 'git-dirs'; Source = "$HostHome/.git-dirs"; Target = '/git-dirs'; Type = 'bind' }
            }
        }
    }
    if ($SshAgent -eq 'socket' -and $SshSocket) {
        $mounts += [pscustomobject]@{ Name = 'ssh-agent'; Source = $SshSocket; Target = $script:SshAgentTarget; Type = 'bind' }
    }
    if ($CloudFolder) {
        $mounts += [pscustomobject]@{ Name = 'cloud-folder'; Source = $CloudFolder; Target = $script:CloudFolderTarget; Type = 'bind' }
    }
    return $mounts
}

function ConvertTo-MountArgument {
    <# .SYNOPSIS The value of one `--mount` option for a host mount. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mount)
    return "type=$($Mount.Type),source=$($Mount.Source),target=$($Mount.Target)"
}

function ConvertTo-JsonWithoutComment {
    <# .SYNOPSIS Strips // and /* */ comments from JSONC text, leaving strings untouched. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    $n = $Text.Length; $i = 0
    while ($i -lt $n) {
        $c = $Text[$i]
        $d = if ($i + 1 -lt $n) { $Text.Substring($i, 2) } else { [string]$c }
        if ($c -eq '"') {
            [void]$sb.Append($c); $i++
            while ($i -lt $n) {
                $c = $Text[$i]; [void]$sb.Append($c); $i++
                if ($c -eq '\' -and $i -lt $n) { [void]$sb.Append($Text[$i]); $i++ }
                elseif ($c -eq '"') { break }
            }
        }
        elseif ($d -eq '//') { while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ } }
        elseif ($d -eq '/*') { $end = $Text.IndexOf('*/', $i + 2); $i = if ($end -lt 0) { $n } else { $end + 2 } }
        else { [void]$sb.Append($c); $i++ }
    }
    return $sb.ToString()
}

function Get-DevcontainerConfigFile {
    <# .SYNOPSIS The repository's devcontainer.json: the file --config names in $Arguments, else .devcontainer/devcontainer.json, else .devcontainer.json; $null when there is none. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceFolder, [string[]]$Arguments = @())
    $file = $null
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -eq '--config' -and $i + 1 -lt $Arguments.Count) { $file = $Arguments[$i + 1] }
        elseif ($Arguments[$i] -like '--config=*') { $file = $Arguments[$i].Substring(9) }
    }
    if (-not $file) {
        foreach ($rel in '.devcontainer/devcontainer.json', '.devcontainer.json') {
            $candidate = Join-Path $WorkspaceFolder $rel
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $file = $candidate; break }
        }
    }
    if (-not $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    return $file
}

function Get-ConfiguredMountTarget {
    <#
    .SYNOPSIS
        The mount targets the repository's own devcontainer.json declares (strings
        `source=..,target=/x` and objects with "target"): the file --config names in
        $Arguments, else .devcontainer/devcontainer.json, else .devcontainer.json.
    .DESCRIPTION
        Read straight from the file (comments stripped, no JSON parser, so trailing commas
        are fine) rather than with `devcontainer read-configuration`: that costs a second
        Node start (about 0.25-0.5 s), asks the engine (`docker ps`) and fails when the
        engine is down, which `host` must survive. Mounts that Features declare and
        docker-compose files are not seen; neither declares the host mounts.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceFolder, [string[]]$Arguments = @())
    $file = Get-DevcontainerConfigFile -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments
    if (-not $file) { return @() }
    $text = ConvertTo-JsonWithoutComment -Text (Get-Content -LiteralPath $file -Raw)
    $targets = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($text, '"mounts"\s*:\s*\[[^\]]*\]')) {
        foreach ($t in [regex]::Matches($m.Value, '(?:target|destination|dst)=([^,"\s]+)')) { $targets.Add($t.Groups[1].Value.TrimEnd('/')) }
        foreach ($t in [regex]::Matches($m.Value, '"(?:target|destination)"\s*:\s*"([^"]+)"')) { $targets.Add($t.Groups[1].Value.TrimEnd('/')) }
    }
    return @($targets)
}

function Test-HostMountsEnabled {
    <# .SYNOPSIS $false when HOST_MOUNTS is false, 0 or no (environment variable or the parameter the entry script copies into it). #>
    [CmdletBinding()]
    param()
    return (Get-SettingOrEnv '' 'HOST_MOUNTS' 'true') -notin @('false', '0', 'no')
}

function Resolve-HostMount {
    <#
    .SYNOPSIS
        What the launcher would mount: @{ Enabled; Add = mounts to pass; Skip = mounts the
        repository already declares }. Starts nothing and creates nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceFolder, [string[]]$Arguments = @(), [string]$DockerPath)
    if (-not (Test-HostMountsEnabled)) { return [pscustomobject]@{ Enabled = $false; Add = @(); Skip = @() } }
    $p = Resolve-HostProfile -DockerPath $DockerPath
    $configured = @(Get-ConfiguredMountTarget -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments)
    $add = @(); $skip = @()
    foreach ($m in @(Get-HostMount -Type $p.Type -HostHome $p.Home -SshAgent $p.SshAgent -SshSocket $p.SshSocket -CloudFolder $p.CloudFolder)) {
        if ($configured -contains $m.Target) { $skip += $m } else { $add += $m }
    }
    return [pscustomobject]@{ Enabled = $true; Add = $add; Skip = $skip }
}

function Initialize-HostMountSource {
    <# .SYNOPSIS Creates the host folder of a bind mount when it is a path this launcher can reach (idempotent), so a start never fails on a missing source. A failure is a warning, never fatal. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mount, [Parameter(Mandatory)][string]$Type)
    # A socket is not ours to create, nor is the user's cloud folder (an empty one would hide a wrong path).
    if ($Mount.Name -in 'ssh-agent', 'cloud-folder') { return }
    # windows-wsl-docker driven from Windows has a distro path (/home/...) that Windows cannot create.
    if ($Type -eq 'windows-wsl-docker' -and (Get-HostPlatform) -eq 'windows') { return }
    try { if (-not (Test-Path -LiteralPath $Mount.Source)) { [void](New-Item -ItemType Directory -Path $Mount.Source -Force) } }
    catch { Write-Warning "host mount: could not create $($Mount.Source): $($_.Exception.Message)" }
}

function Test-CloudFolderMount {
    <#
    .SYNOPSIS
        $true when the cloud-folder mount can be passed: a source that is a folder on this host. A source this launcher cannot check (a Windows path from Linux or
        macOS, a distro path from Windows) goes to the engine as is. A refusal is one warning;
        the container then starts without the folder and its status says so.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Mount)
    $windowsPath = $Mount.Source -match '^([A-Za-z]:[\\/]|\\\\)'
    $checkable = if ((Get-HostPlatform) -eq 'windows') { $windowsPath } else { $Mount.Source.StartsWith('/') }
    if ($checkable -and -not (Test-Path -LiteralPath $Mount.Source -PathType Container)) {
        Write-Warning "host mount cloud-folder skipped: DCF_HOST_CLOUD_FOLDER '$($Mount.Source)' is not a folder on this host; the container starts without it (task cloud-folder:status says so)."
        return $false
    }
    return $true
}

function Get-HostMountArgument {
    <#
    .SYNOPSIS
        The `--mount <spec>` arguments for `up`, after printing one line per skipped mount.
        Creates each source folder. Empty when HOST_MOUNTS=false.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceFolder, [string[]]$Arguments = @(), [string]$DockerPath)
    $r = Resolve-HostMount -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments -DockerPath $DockerPath
    $type = (Resolve-HostProfile -DockerPath $DockerPath).Type
    $out = @()
    foreach ($m in $r.Skip) { Write-Host "host mount skipped: $($m.Target) is already mounted by this repository's devcontainer.json" }
    foreach ($m in $r.Add) {
        if ($m.Source -match ',') { Write-Warning "host mount $($m.Name) skipped: the source '$($m.Source)' contains a comma, which --mount cannot carry."; continue }
        if ($m.Name -eq 'cloud-folder' -and -not (Test-CloudFolderMount -Mount $m)) { continue }
        Initialize-HostMountSource -Mount $m -Type $type
        $out += @('--mount', (ConvertTo-MountArgument -Mount $m))
    }
    return $out
}

function Show-HostProfile {
    <# .SYNOPSIS `task devcontainer:host`: prints the resolved host profile; starts nothing. #>
    [CmdletBinding()]
    param([string]$DockerPath, [string]$WorkspaceFolder, [string[]]$Arguments = @())
    $p = Resolve-HostProfile -DockerPath $DockerPath
    Write-Host "HOST_TYPE          : $($p.Type)"
    Write-Host "why                : $($p.Why)"
    Write-Host "priority list      : $($p.Priority -join ',')"
    Write-Host "engine command     : $($p.Engine)"
    Write-Host "DCF_HOST_TYPE      : $($p.Type)"
    Write-Host "DCF_HOST_HOME      : $($p.Home)"
    Write-Host "DCF_HOST_SSH_AGENT : $($p.SshAgent)"
    Write-Host "DCF_HOST_CLOUD_FOLDER: $(if ($p.CloudFolder) { $p.CloudFolder } else { '(unset)' })"
    if (-not $WorkspaceFolder) { $WorkspaceFolder = (Get-Location).Path }
    $machine = Get-HostMachineName
    Write-Host "DCF_HOST_MACHINE   : $(if ($machine) { $machine } else { '(unset)' })"
    Write-MachineSlotWarning -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments
    if ($p.Fuse) {
        Write-Host "DCF_HOST_FUSE      : 1 (runArgs get: $(@((Get-FuseRunArgument -Requested $true).Values) -join ' '))"
        Write-FuseSlotWarning -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments -DockerPath $DockerPath
    }
    elseif ($p.FuseRequested) { Write-Host "DCF_HOST_FUSE      : 1 asked for, not granted on $($p.Type): $($p.FuseRefusal)" }
    else { Write-Host 'DCF_HOST_FUSE      : (unset: no FUSE grant)' }
    $r = Resolve-HostMount -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments -DockerPath $DockerPath
    if (-not $r.Enabled) { Write-Host 'host mounts        : off (HOST_MOUNTS=false)'; return }
    if (-not ($r.Add.Count + $r.Skip.Count)) { Write-Host 'host mounts        : none'; return }
    foreach ($m in $r.Add) { Write-Host "host mount (add)   : $($m.Name): $(ConvertTo-MountArgument -Mount $m)" }
    foreach ($m in $r.Skip) { Write-Host "host mount (skip)  : $($m.Name): $($m.Target) is already mounted by devcontainer.json" }
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
        container; when it fails, the stop is refused with its exit code
        (a check that is not installed, exit 127, gets its own message).
        -CheckOnly is devcontainer:prepshutdown: run the check, stop nothing,
        ignore -Force.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$WorkspaceFolder,
        [string]$DockerPath,
        [string]$CommandB64,
        [switch]$Force,
        [switch]$CheckOnly,
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
        if ($CheckOnly) { Write-Host "No running devcontainer for ${WorkspaceFolder}: nothing to check." }
        else { Write-Host "No running devcontainer for ${WorkspaceFolder}: already stopped." }
        return
    }
    if ($Force -and -not $CheckOnly) {
        Write-Host 'FORCE set: skipping the shutdown check.'
    }
    elseif ($CommandB64) {
        $check = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CommandB64))
        Write-Host "Running the shutdown check ($check); if it fails the stop is refused."
        Invoke-DevcontainerCliProcess -Subcommand exec -WorkspaceFolder $WorkspaceFolder -CommandB64 $CommandB64 `
            -NodeVersion $NodeVersion -CliVersion $CliVersion -DockerPath $DockerPath
        $rc = $script:CliExitCode
        if ($rc -eq 127) {
            [Console]::Error.WriteLine("Not stopping: the shutdown check ($check) is not installed in the container (exit 127). Define it, unset STOP_CHECK to use the default resolution, or run again with FORCE=1.")
            exit $rc
        }
        if ($rc -ne 0) {
            [Console]::Error.WriteLine("Not stopping: the shutdown check ($check) found the problems above. Fix them (shutdown-devhost skill) or run again with FORCE=1.")
            exit $rc
        }
    }
    if ($CheckOnly) {
        Write-Host 'The shutdown check passed (or none is defined): a stop would go ahead.'
        return
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

function Get-DevcontainerCliInvocation {
    <#
    .SYNOPSIS
        The program and arguments of one @devcontainers/cli call (Exe, Arguments), with the host
        mounts for `up`, --docker-path and the DCF_HOST_* environment set up as for every call.
        Invoke-DevcontainerCliProcess runs it on the console; the cloud-folder login reads its output.
    #>
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
    # Host mounts go to `up` only (and so to rebuild): `build` mounts nothing and `exec`
    # runs in a container that exists. Initialize-HostEnvironment below sets DCF_HOST_*.
    if ($Subcommand -eq 'up') {
        $cliArgs += @(Get-HostMountArgument -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments -DockerPath $DockerPath)
        Write-FuseRefusedWarning -DockerPath $DockerPath
        Write-FuseSlotWarning -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments -DockerPath $DockerPath
        Write-MachineSlotWarning -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments
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
        # DCF_HOST_* go into this process's environment, which the CLI inherits;
        # a repository maps them into the container with containerEnv.
        [void](Initialize-HostEnvironment -DockerPath $DockerPath)
    }

    if ($CommandB64) {
        if ($Subcommand -ne 'exec') { throw "-CommandB64 is only meaningful with -Subcommand exec (got '$Subcommand')." }
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CommandB64))
        $cliArgs += @('bash', '-lc', $decoded)
    }
    else {
        $cliArgs += $Arguments
    }
    return [pscustomobject]@{ Exe = $exe; Arguments = [string[]]$cliArgs }
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
        [string]$DockerPath,
        [string]$InputFile
    )

    $inv = Get-DevcontainerCliInvocation -Subcommand $Subcommand -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments `
        -CommandB64 $CommandB64 -NodeVersion $NodeVersion -CliVersion $CliVersion -DockerPath $DockerPath
    $exe = $inv.Exe
    $cliArgs = $inv.Arguments

    # Not returned: the CLI's own output must reach the console (a pipeline
    # would capture it, and Out-Host would take away an interactive terminal).
    # -InputFile: the file's text goes to the CLI's stdin (ssh-key-import), never into its arguments.
    if ($InputFile) { Get-Content -LiteralPath $InputFile -Raw | & $exe @cliArgs } else { & $exe @cliArgs }
    $script:CliExitCode = $LASTEXITCODE
}

function Write-GeneralPurposeKeyWarning {
    <#
    .SYNOPSIS
        Warnings (never a refusal) when the key about to be imported looks like a general-purpose key.
    .DESCRIPTION
        A default file name (id_ed25519, id_rsa, ...), or a public key that also opens something on
        this host: listed in ~/.ssh/authorized_keys, or the same as another ~/.ssh/*.pub. The public
        half is FILE.pub, or derived with `ssh-keygen -y` only for a key with no passphrase (a wrong
        passphrase is given, so a protected key fails instead of prompting, and is skipped). Prints
        fingerprints, never key material.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$KeyFile)
    $name = Split-Path -Leaf $KeyFile
    if ($name -in 'id_ed25519', 'id_ecdsa', 'id_rsa', 'id_dsa', 'id_ed25519_sk', 'id_ecdsa_sk') {
        Write-Warning "ssh-key-import: $name is the default name of a general-purpose key. Import only a dedicated signing key (one key per purpose and per container, named <repo>-<container>-sign) that opens nothing else; task ssh-agent:key:new inside the container makes one that never leaves it."
    }
    $keygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
    $pub = $null
    if (Test-Path -LiteralPath "$KeyFile.pub" -PathType Leaf) { $pub = Get-Content -LiteralPath "$KeyFile.pub" -TotalCount 1 }
    elseif ($keygen) {
        $derived = $null | & $keygen.Source -y -P 'not-the-passphrase' -f $KeyFile 2>$null
        if ($LASTEXITCODE -eq 0 -and $derived) { $pub = @($derived)[0] }
    }
    $blob = if ($pub) { @(([string]$pub) -split '\s+')[1] } else { $null }
    if (-not $blob) { return }
    $fp = ''
    if ($keygen) {
        $tmp = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($tmp, "$pub`n")
            $l = & $keygen.Source -l -f $tmp 2>$null
            if ($LASTEXITCODE -eq 0 -and $l) { $fp = (@(([string]@($l)[0]) -split '\s+'))[1] }
        }
        finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
    $userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    if (-not $userHome) { return }
    $sshDir = Join-Path $userHome '.ssh'
    $hit = $null
    $authorized = Join-Path $sshDir 'authorized_keys'
    if (Test-Path -LiteralPath $authorized -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $authorized) {
            if (@($line -split '\s+') -contains $blob) { $hit = 'appears in ~/.ssh/authorized_keys (it logs in to this host)'; break }
        }
    }
    if (-not $hit -and (Test-Path -LiteralPath $sshDir -PathType Container)) {
        $own = if (Test-Path -LiteralPath "$KeyFile.pub") { (Resolve-Path -LiteralPath "$KeyFile.pub").Path } else { $null }
        foreach ($p in Get-ChildItem -LiteralPath $sshDir -Filter '*.pub' -File) {
            if ($own -and $p.FullName -eq $own) { continue }
            $other = @(((Get-Content -LiteralPath $p.FullName -TotalCount 1) -split '\s+'))[1]
            if ($other -eq $blob) { $hit = "is the same key as ~/.ssh/$($p.Name)"; break }
        }
    }
    if ($hit) {
        $shown = if ($fp) { " ($fp)" } else { '' }
        Write-Warning "ssh-key-import: the public key of $name$shown $hit, so it is a general-purpose key. A key that also opens GitHub, servers or other repos must not live in a container volume: import a dedicated signing key instead (registered at GitHub as a signing key only)."
    }
}

function Import-SshKey {
    <#
    .SYNOPSIS
        The opt-in key mode's one-shot import (task devcontainer:ssh-key-import): streams a
        private key file of this host into the running container's ssh-agent key volume.
    .DESCRIPTION
        The key goes through `devcontainer exec` on stdin (ssh-agent-setup key-stdin), never as an
        argument, so it is not in a process list or a log; the .pub beside it follows when it
        exists; then the Feature loads the keys. The container refuses, before reading anything,
        when key mode is off. Throws with a clear message when the file is missing, no container
        runs, or the container refuses. Nothing is left running on the host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceFolder,
        [string]$KeyFile,
        [string]$NodeVersion,
        [string]$CliVersion,
        [string]$DockerPath
    )
    if (-not $KeyFile -or -not (Test-Path -LiteralPath $KeyFile -PathType Leaf)) {
        throw "ssh-key-import: FILE=<path of a private key on this host> is required, and '$KeyFile' is not a file."
    }
    Write-GeneralPurposeKeyWarning -KeyFile $KeyFile
    $folder = (Resolve-Path $WorkspaceFolder).Path
    $ids = @(Get-RunningDevcontainerId -WorkspaceFolder $folder -DockerPath $DockerPath)
    if ($ids.Count -eq 0) { throw "No running devcontainer for $folder. Start it with: task dc:start" }
    $name = Split-Path -Leaf $KeyFile
    $common = @{ Subcommand = 'exec'; WorkspaceFolder = $folder; NodeVersion = $NodeVersion; CliVersion = $CliVersion; DockerPath = $DockerPath }
    Invoke-DevcontainerCliProcess @common -Arguments @('ssh-agent-setup', 'key-stdin', $name) -InputFile $KeyFile
    if ($script:CliExitCode -ne 0) {
        throw "ssh-key-import: the container refused or failed (exit $($script:CliExitCode), see above). Key mode must be on there: Feature option keyMode: true, or SSH_AGENT_MODE=key at task devcontainer:up; the ssh-agent Feature must be installed."
    }
    if (Test-Path -LiteralPath "$KeyFile.pub" -PathType Leaf) {
        Invoke-DevcontainerCliProcess @common -Arguments @('ssh-agent-setup', 'key-stdin', "$name.pub") -InputFile "$KeyFile.pub"
        if ($script:CliExitCode -ne 0) { Write-Warning 'ssh-key-import: the .pub could not be stored (the private key was).' }
    }
    Invoke-DevcontainerCliProcess @common -Arguments @('ssh-agent-setup', 'key-load')
    if ($script:CliExitCode -ne 0) { throw "ssh-key-import: loading the keys failed (exit $($script:CliExitCode))." }
}

# ------------------------------------------------------ cloud-folder login ----
# task cloud-folder:login from the workstation (devcontainer:cloud-folder-login): the cloud-folder
# Feature's sign-in, which runs `rclone authorize "onedrive"` in the container, reached from this
# workstation's browser. Microsoft sends the browser after the sign-in to the fixed
# http://localhost:53682/ (rclone's app registration allows only that address), which here does not
# reach the container. Three routes, as in the bash twin (devcontainer-cli.sh, "cloud-folder login"):
# the relay (default: a listener on 127.0.0.1:53682 for the sign-in only, each request relayed into
# the container through `<engine> exec -i` and bash's /dev/tcp), --paste, and --workstation-rclone.
# Test hooks: DCF_CLOUD_FOLDER_LOGIN_PORT, DCF_CLOUD_FOLDER_LOGIN_CONTAINER_PORT, DCF_BROWSER,
# DCF_RCLONE_DOWNLOADS.
# The cloud-folder Feature's rcloneVersion default (CloudFolderLogin.Tests.ps1 checks it matches).
$script:CloudFolderRcloneDefault = '1.75.2'

function Get-LauncherCacheRoot {
    <# .SYNOPSIS The launcher's download cache: %LOCALAPPDATA%\devcontainer-features on Windows, else ${XDG_CACHE_HOME:-~/.cache}/devcontainer-features (as the bash twin). #>
    [CmdletBinding()]
    param()
    if ($IsWindows) { return (Join-Path $env:LOCALAPPDATA 'devcontainer-features') }
    $base = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' }
    return (Join-Path $base 'devcontainer-features')
}

function Get-CloudFolderRcloneVersion {
    <# .SYNOPSIS The cloud-folder rcloneVersion in the repository's devcontainer.json, else the Feature's default; "latest" asks the publisher. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceFolder)
    $v = ''
    $file = Get-DevcontainerConfigFile -WorkspaceFolder $WorkspaceFolder
    if ($file) {
        $text = ConvertTo-JsonWithoutComment -Text (Get-Content -LiteralPath $file -Raw)
        $m = [regex]::Match($text, '"rcloneVersion"\s*:\s*"([^"]*)"')
        if ($m.Success) { $v = $m.Groups[1].Value }
    }
    $v = $v -replace '^v', ''
    if ($v -eq 'latest') {
        $base = Get-SettingOrEnv '' 'DCF_RCLONE_DOWNLOADS' 'https://downloads.rclone.org'
        $file = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-DcfDownload -Uri "$base/version.txt" -OutFile $file
            $m = [regex]::Match((Get-Content -LiteralPath $file -Raw), 'rclone v?([0-9][0-9.]*)')
            if (-not $m.Success) { throw 'cloud-folder-login: rcloneVersion latest: the publisher did not say which version that is.' }
            $v = $m.Groups[1].Value
        }
        finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
    if (-not $v) { $v = $script:CloudFolderRcloneDefault }
    return $v
}

function Get-WorkstationRclone {
    <#
    .SYNOPSIS
        The rclone release for this workstation in the launcher cache (downloaded once, verified
        against the release's SHA256SUMS); returns the executable's path. Throws on a mismatch.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'osx' } else { 'linux' }
    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { 'amd64' } 'Arm64' { 'arm64' } default { throw "cloud-folder-login: no rclone build for $_ here (amd64, arm64)." }
    }
    $exeName = if ($IsWindows) { 'rclone.exe' } else { 'rclone' }
    $dir = Join-Path (Get-LauncherCacheRoot) "rclone/v$Version"
    $exe = Join-Path $dir $exeName
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }

    $asset = "rclone-v$Version-$os-$arch.zip"
    $base = (Get-SettingOrEnv '' 'DCF_RCLONE_DOWNLOADS' 'https://downloads.rclone.org') + "/v$Version"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "dcf-rclone-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Write-Host "cloud-folder-login: downloading rclone v$Version ($asset, once; cached under $dir)..."
    try {
        try {
            Invoke-DcfDownload -Uri "$base/$asset" -OutFile (Join-Path $tmp $asset)
            # Saved to a file and read as text: for this file Invoke-WebRequest's .Content is bytes.
            Invoke-DcfDownload -Uri "$base/SHA256SUMS" -OutFile (Join-Path $tmp 'SHA256SUMS')
        }
        catch { throw "cloud-folder-login: could not download rclone v$Version from $base ($($_.Exception.Message))" }
        $sums = Get-Content -LiteralPath (Join-Path $tmp 'SHA256SUMS') -Raw
        $line = $sums -split "`n" | Where-Object { $_ -match ('^\s*[0-9a-fA-F]{64}\s+' + [regex]::Escape($asset) + '\s*$') } | Select-Object -First 1
        if (-not $line) { throw "cloud-folder-login: $asset is not in the release's SHA256SUMS." }
        $expected = ($line.Trim() -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath (Join-Path $tmp $asset) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "cloud-folder-login: SHA-256 mismatch for $asset (expected $expected, got $actual); nothing kept." }
        Expand-Archive -LiteralPath (Join-Path $tmp $asset) -DestinationPath (Join-Path $tmp 'x') -Force
        $found = Join-Path $tmp "x/rclone-v$Version-$os-$arch/$exeName"
        if (-not (Test-Path -LiteralPath $found -PathType Leaf)) { throw "cloud-folder-login: $asset has no rclone-v$Version-$os-$arch/$exeName." }
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Move-Item -LiteralPath $found -Destination $exe -Force
        if (-not $IsWindows) { & chmod 0755 $exe }
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    return $exe
}

function Open-Browser {
    <# .SYNOPSIS Opens the address in the default browser (DCF_BROWSER: another command), without waiting. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)
    try {
        if ($env:DCF_BROWSER) { Start-Process -FilePath $env:DCF_BROWSER -ArgumentList @($Url) | Out-Null }
        else { Start-Process -FilePath $Url | Out-Null }
    }
    catch { Write-Host "cloud-folder-login: open this address in your browser: $Url" }
}

function Invoke-CloudFolderRelayRequest {
    <#
    .SYNOPSIS
        One request of the browser: read from the workstation listener, made HTTP/1.0 with
        Connection: close (so rclone answers and closes), written into the container through
        `<engine> exec -i <id> bash -c` to /dev/tcp/127.0.0.1/<port>, and the answer copied back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.Sockets.TcpClient]$Client,
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$ContainerId,
        [Parameter(Mandatory)][int]$ContainerPort
    )
    try {
        $stream = $Client.GetStream()
        $stream.ReadTimeout = 10000
        $buf = [byte[]]::new(65536)
        $data = [System.IO.MemoryStream]::new()
        $ascii = [System.Text.Encoding]::ASCII
        while ($data.Length -lt 65536) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $data.Write($buf, 0, $n)
            if ($ascii.GetString($data.ToArray()).Contains("`r`n`r`n")) { break }
        }
        $head = ($ascii.GetString($data.ToArray()) -split "`r`n`r`n", 2)[0] -split "`r`n"
        $first = $head[0] -split ' '
        if ($first.Count -lt 2) { return }
        $lines = @("$($first[0]) $($first[1]) HTTP/1.0")
        $lines += @($head | Select-Object -Skip 1 | Where-Object { $_ -and (($_ -split ':', 2)[0].Trim().ToLowerInvariant() -notin 'connection', 'keep-alive') })
        $lines += 'Connection: close'
        $request = $ascii.GetBytes(($lines -join "`r`n") + "`r`n`r`n")

        $psi = [System.Diagnostics.ProcessStartInfo]::new($Engine)
        foreach ($a in @('exec', '-i', $ContainerId, 'bash', '-c', "exec 3<>/dev/tcp/127.0.0.1/$ContainerPort || exit 1; cat <&3 & cat >&3; wait")) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $answer = [System.IO.MemoryStream]::new()
        try {
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.BaseStream.Write($request, 0, $request.Length)
            $p.StandardInput.Close()
            $p.StandardOutput.BaseStream.CopyTo($answer)
            [void]$p.WaitForExit(30000)
        }
        catch { $answer.SetLength(0) }
        $bytes = $answer.ToArray()
        if ($bytes.Length -eq 0) {
            $bytes = $ascii.GetBytes("HTTP/1.0 502 Bad Gateway`r`nContent-Type: text/plain`r`n`r`nThe devcontainer did not answer (is task cloud-folder:login still running?).`n")
        }
        $stream.Write($bytes, 0, $bytes.Length)
    }
    catch { Write-Verbose "cloud-folder-login: a relayed request failed: $($_.Exception.Message)" }
    finally { $Client.Close() }
}

function Invoke-CloudFolderLoginRelay {
    <#
    .SYNOPSIS
        The relay route: listens on 127.0.0.1:53682 for the sign-in only, starts `cloud-folder-setup
        login --relay` in the container, opens the browser at the link it prints, relays every
        request, and closes the listener when the login ends, fails or times out. A busy port falls
        back to the paste route. The exit code is left in $script:CliExitCode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceFolder,
        [Parameter(Mandatory)][string]$ContainerId,
        [string]$NodeVersion,
        [string]$CliVersion,
        [string]$DockerPath
    )
    $port = [int](Get-SettingOrEnv '' 'DCF_CLOUD_FOLDER_LOGIN_PORT' '53682')
    $cport = [int](Get-SettingOrEnv '' 'DCF_CLOUD_FOLDER_LOGIN_CONTAINER_PORT' '53682')
    $timeout = [int](Get-SettingOrEnv '' 'CLOUD_FOLDER_LOGIN_TIMEOUT' '600')
    $common = @{ WorkspaceFolder = $WorkspaceFolder; NodeVersion = $NodeVersion; CliVersion = $CliVersion; DockerPath = $DockerPath }
    $engine = Resolve-DockerPath -DockerPath $DockerPath
    if (-not $engine) { $engine = 'docker' }

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    try { $listener.Start() }
    catch {
        Write-Host "cloud-folder-login: port $port on this workstation is in use (another sign-in, or a local rclone?), so the browser's redirect cannot be relayed; signing in by pasting the address instead."
        Invoke-DevcontainerCliProcess -Subcommand exec @common -Arguments @('cloud-folder-setup', 'login')
        return
    }
    $proc = $null
    try {
        Write-Host "cloud-folder-login: relaying 127.0.0.1:$port on this workstation into the devcontainer for the sign-in (closed when it ends, at the latest after ${timeout}s)."
        $inv = Get-DevcontainerCliInvocation -Subcommand exec @common -Arguments @('env', "CLOUD_FOLDER_LOGIN_TIMEOUT=$timeout", 'cloud-folder-setup', 'login', '--relay')
        $psi = [System.Diagnostics.ProcessStartInfo]::new($inv.Exe)
        foreach ($a in $inv.Arguments) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Close()
        # The container's login stops at the same timeout; this one is the backstop.
        $deadline = [datetime]::UtcNow.AddSeconds($timeout + 15)
        $opened = $false
        $next = $proc.StandardOutput.ReadLineAsync()
        while ($true) {
            if ($next.IsCompleted) {
                $line = $next.Result
                if ($null -eq $line) { break }
                Write-Host $line
                if (-not $opened -and $line -match 'sign-in URL: (http://\S+)') {
                    $url = $Matches[1] -replace ":$cport/", ":$port/"
                    Write-Host "cloud-folder-login: opening the sign-in in your browser: $url"
                    Open-Browser -Url $url
                    $opened = $true
                }
                $next = $proc.StandardOutput.ReadLineAsync()
                continue
            }
            if ($listener.Pending()) {
                Invoke-CloudFolderRelayRequest -Client $listener.AcceptTcpClient() -Engine $engine -ContainerId $ContainerId -ContainerPort $cport
                continue
            }
            if ([datetime]::UtcNow -gt $deadline) {
                Write-Host "cloud-folder-login: no sign-in within ${timeout}s; stopping."
                try { $proc.Kill($true) } catch { Write-Verbose 'the login had ended' }
                break
            }
            Start-Sleep -Milliseconds 50
        }
        $proc.WaitForExit()
        $script:CliExitCode = $proc.ExitCode
    }
    finally {
        $listener.Stop()
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill($true) } catch { Write-Verbose 'the login had ended' } }
        Write-Host "cloud-folder-login: the relay on 127.0.0.1:$port is closed."
    }
}

function Invoke-CloudFolderLogin {
    <#
    .SYNOPSIS
        task devcontainer:cloud-folder-login (and task cloud-folder:login on the workstation): the
        cloud-folder Feature's sign-in through the running devcontainer. Arguments: none (the
        relay), --paste, or --workstation-rclone. The exit code is left in $script:CliExitCode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspaceFolder,
        [string[]]$Arguments = @(),
        [string]$NodeVersion,
        [string]$CliVersion,
        [string]$DockerPath
    )
    $route = 'relay'
    foreach ($a in $Arguments) {
        switch ($a) {
            '--paste' { $route = 'paste' }
            '--workstation-rclone' { $route = 'workstation' }
            default { throw "cloud-folder-login: unknown argument '$a' (--paste, --workstation-rclone)." }
        }
    }
    $folder = (Resolve-Path $WorkspaceFolder).Path
    $common = @{ WorkspaceFolder = $folder; NodeVersion = $NodeVersion; CliVersion = $CliVersion; DockerPath = $DockerPath }
    $ids = @(Get-RunningDevcontainerId -WorkspaceFolder $folder -DockerPath $DockerPath)
    if ($ids.Count -eq 0) { throw "No running devcontainer for $folder. Start it with: task dc:start" }

    switch ($route) {
        'paste' { Invoke-DevcontainerCliProcess -Subcommand exec @common -Arguments @('cloud-folder-setup', 'login') }
        'relay' { Invoke-CloudFolderLoginRelay @common -ContainerId $ids[0] }
        'workstation' {
            $v = Get-CloudFolderRcloneVersion -WorkspaceFolder $folder
            $rclone = Get-WorkstationRclone -Version $v
            Write-Host "cloud-folder-login: signing in with rclone v$v on this workstation: rclone authorize `"onedrive`" opens your browser."
            # Its notices (the link) reach the console; its standard output, which holds the token, is kept here.
            $out = @(& $rclone authorize onedrive)
            $rc = $LASTEXITCODE
            $token = $null
            for ($i = 0; $i -lt $out.Count; $i++) {
                if ($out[$i] -match '^Paste the following into your remote machine --->') {
                    $token = @($out | Select-Object -Skip ($i + 1) | Where-Object { $_.Trim() } | Select-Object -First 1)[0]
                    break
                }
            }
            $out = $null
            if ($rc -ne 0 -or -not $token -or $token -match '^<---End paste') {
                throw "cloud-folder-login: rclone authorize did not give a token (exit $rc; its messages are above)."
            }
            $file = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllText($file, "$token`n")
                $token = $null
                Write-Host 'cloud-folder-login: handing the token to the devcontainer (on stdin, never as an argument).'
                Invoke-DevcontainerCliProcess -Subcommand exec @common -Arguments @('cloud-folder-setup', 'login', '--token') -InputFile $file
            }
            finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($script:CliExitCode -eq 127) {
        [Console]::Error.WriteLine('cloud-folder-login: the devcontainer has no cloud-folder-setup: add the cloud-folder Feature (1.3.0 or later) to its devcontainer.json and rebuild.')
    }
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
    # `prepshutdown` is the same without the stop (-CheckOnly).
    if ($Subcommand -in 'stop', 'prepshutdown') {
        Stop-Devcontainer -WorkspaceFolder $WorkspaceFolder -DockerPath $DockerPath -CommandB64 $CommandB64 -Force:$Force `
            -CheckOnly:($Subcommand -eq 'prepshutdown') -NodeVersion $NodeVersion -CliVersion $CliVersion
        return
    }

    # `ssh-key-import` is not a CLI subcommand: the key file is Arguments[0].
    if ($Subcommand -eq 'ssh-key-import') {
        Import-SshKey -WorkspaceFolder $WorkspaceFolder -KeyFile ($Arguments | Select-Object -First 1) -NodeVersion $NodeVersion -CliVersion $CliVersion -DockerPath $DockerPath
        return
    }

    # `cloud-folder-login` is not a CLI subcommand: the cloud-folder Feature's sign-in from here.
    if ($Subcommand -eq 'cloud-folder-login') {
        Invoke-CloudFolderLogin -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments -NodeVersion $NodeVersion -CliVersion $CliVersion -DockerPath $DockerPath
        if ($script:CliExitCode -ne 0) { exit $script:CliExitCode }
        return
    }

    # `host` is not a CLI subcommand: it prints the resolved host profile and starts nothing.
    if ($Subcommand -eq 'host') { Show-HostProfile -DockerPath $DockerPath -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments; return }

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

Export-ModuleMember -Function Get-HostTypeId, Get-DefaultHostTypePriority, Resolve-HostType, Resolve-SshAgent, Resolve-HostProfile, Initialize-HostEnvironment, Test-FuseRequested, Get-FuseRefusal, Get-FuseRunArgument, Get-FuseSlotMissing, Write-FuseSlotWarning, Write-FuseRefusedWarning, ConvertTo-MachineName, Get-HostMachineName, Test-MachineSlotMissing, Write-MachineSlotWarning, Get-DevcontainerConfigFile, Get-HostMount, Test-CloudFolderMount, ConvertTo-MountArgument, ConvertTo-JsonWithoutComment, Get-ConfiguredMountTarget, Test-HostMountsEnabled, Resolve-HostMount, Initialize-HostMountSource, Get-HostMountArgument, Show-HostProfile, Import-SshKey, Clear-HostProfileCache, Get-SettingOrEnv, ConvertFrom-TaskCliArgString, Get-PortableNodeDir, Invoke-DcfDownload, Get-DevcontainersCliEntrypoint, Remove-DevcontainersCli, Resolve-DockerPath, Get-WorkspaceFolderVariant, Get-RunningDevcontainerId, Stop-Devcontainer, Test-BuildSubcommand, Enter-DevcontainerBuildLock, Exit-DevcontainerBuildLock, Get-DevcontainerCliInvocation, Invoke-DevcontainerCliProcess, Get-LauncherCacheRoot, Get-CloudFolderRcloneVersion, Get-WorkstationRclone, Open-Browser, Invoke-CloudFolderRelayRequest, Invoke-CloudFolderLoginRelay, Invoke-CloudFolderLogin, Invoke-DevcontainerCli
