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

    FUSE on request (cloud-folder Feature, mount mode; ADR 0031): DCF_HOST_FUSE=1 (or true, yes,
    on) sets DCF_HOST_FUSE_DEVICE, DCF_HOST_FUSE_CAP and DCF_HOST_FUSE_SECURITY to
    --device=/dev/fuse, --cap-add=SYS_ADMIN and --security-opt=apparmor=unconfined for the CLI,
    which the repository's runArgs read with ${localEnv:<name>:<default>} (the CLI has no option
    for run arguments; the bootstrap's devcontainer.json carries the lines). Unset, the three are
    removed. Never granted by default; `up` warns when the repository's devcontainer.json lacks
    the lines (Get-FuseSlotMissing).

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
    return [pscustomobject]@{
        Type = $t.Type; Why = $t.Why; Priority = $t.Priority
        Engine = $engine; EnginePath = $enginePath
        Home = $hostHome; SshAgent = $agent.Mode; SshSocket = $agent.Socket
        CloudFolder = (Get-SettingOrEnv '' 'DCF_HOST_CLOUD_FOLDER')
        Fuse = (Test-FuseRequested)
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
    <# .SYNOPSIS When FUSE is requested, one warning if the repository's devcontainer.json cannot carry the grant. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspaceFolder, [string[]]$Arguments = @())
    if (-not (Test-FuseRequested)) { return }
    $missing = @(Get-FuseSlotMissing -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments)
    if ($missing.Count) {
        Write-Warning "DCF_HOST_FUSE=1, but the repository's devcontainer.json has no runArgs reading $($missing -join ' ') (`${localEnv:<name>:<default>}): FUSE does not reach the container. Copy the three runArgs lines from the bootstrap's devcontainer.json."
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
    if ($p.Fuse) {
        Write-Host "DCF_HOST_FUSE      : 1 (runArgs get: $(@((Get-FuseRunArgument -Requested $true).Values) -join ' '))"
        Write-FuseSlotWarning -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments
    }
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
        Write-FuseSlotWarning -WorkspaceFolder $WorkspaceFolder -Arguments $Arguments
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

Export-ModuleMember -Function Get-HostTypeId, Get-DefaultHostTypePriority, Resolve-HostType, Resolve-SshAgent, Resolve-HostProfile, Initialize-HostEnvironment, Test-FuseRequested, Get-FuseRunArgument, Get-FuseSlotMissing, Write-FuseSlotWarning, Get-DevcontainerConfigFile, Get-HostMount, Test-CloudFolderMount, ConvertTo-MountArgument, ConvertTo-JsonWithoutComment, Get-ConfiguredMountTarget, Test-HostMountsEnabled, Resolve-HostMount, Initialize-HostMountSource, Get-HostMountArgument, Show-HostProfile, Import-SshKey, Clear-HostProfileCache, Get-SettingOrEnv, ConvertFrom-TaskCliArgString, Get-PortableNodeDir, Invoke-DcfDownload, Get-DevcontainersCliEntrypoint, Remove-DevcontainersCli, Resolve-DockerPath, Get-WorkspaceFolderVariant, Get-RunningDevcontainerId, Stop-Devcontainer, Test-BuildSubcommand, Enter-DevcontainerBuildLock, Exit-DevcontainerBuildLock, Invoke-DevcontainerCliProcess, Invoke-DevcontainerCli
