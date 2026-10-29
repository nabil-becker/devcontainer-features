# Pester 5+ tests of the host launcher's build lock (bootstrap/host/DevcontainerCli.psm1).
# Run: task test:bootstrap   (CI: the "Pester" step of .github/workflows/lint.yaml)
# They use their own mutex names, so a real build running on the host is never touched.

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '../../bootstrap/host/DevcontainerCli.psm1'
    Import-Module $script:ModulePath -Force
    $script:PwshExe = (Get-Process -Id $PID).Path

    # Runs a child pwsh that takes the mutex $Name, then runs $Body ($mutex in scope).
    function Invoke-LockHolder {
        param([string]$Name, [string]$Body)
        $code = "`$mutex = [System.Threading.Mutex]::new(`$false, '$Name'); [void]`$mutex.WaitOne(); $Body"
        $psi = [System.Diagnostics.ProcessStartInfo]::new($script:PwshExe)
        foreach ($a in @('-NoLogo', '-NoProfile', '-Command', $code)) { $psi.ArgumentList.Add($a) }
        $psi.CreateNoWindow = $true
        [System.Diagnostics.Process]::Start($psi)
    }
    function Wait-ForFile {
        param([string]$Path, [int]$Seconds = 30)
        $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
        while (-not (Test-Path $Path) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Test-Path $Path
    }
}

AfterAll { Remove-Module DevcontainerCli -Force -ErrorAction SilentlyContinue }

Describe 'Enter-DevcontainerBuildLock' {
    BeforeEach {
        $script:name = "Global\devcontainer-features-test-$([guid]::NewGuid().ToString('N'))"
        $script:flag = Join-Path ([IO.Path]::GetTempPath()) "dcf-lock-$([guid]::NewGuid().ToString('N'))"
    }
    AfterEach { Remove-Item $script:flag -ErrorAction SilentlyContinue }

    It 'serialises two holders: the second waits until the first releases' {
        # The holder takes the lock, signals, sleeps, then releases.
        $holder = Invoke-LockHolder -Name $script:name -Body "New-Item '$($script:flag)' | Out-Null; Start-Sleep -Seconds 4; `$mutex.ReleaseMutex()"
        try {
            Wait-ForFile $script:flag | Should -BeTrue
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $out = Enter-DevcontainerBuildLock -Name $script:name 6>&1
            $watch.Stop()
            $lock = $out | Where-Object { $_ -is [System.Threading.Mutex] }
            try {
                $lock | Should -Not -BeNullOrEmpty
                # It had to wait for the holder's sleep, and it said so once.
                $watch.Elapsed.TotalSeconds | Should -BeGreaterThan 1.5
                @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -Be 1
                ($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).MessageData.Message |
                    Should -Match 'waiting for another devcontainer build to finish'
            }
            finally { Exit-DevcontainerBuildLock -Lock $lock }
        }
        finally { if (-not $holder.HasExited) { $holder.Kill() } }
    }

    It 'takes a free lock at once and prints nothing' {
        $out = Enter-DevcontainerBuildLock -Name $script:name 6>&1
        try {
            @($out).Count | Should -Be 1
            $out | Should -BeOfType ([System.Threading.Mutex])
        }
        finally { Exit-DevcontainerBuildLock -Lock $out }
    }

    It 'treats an abandoned lock (holder died without releasing) as acquired' {
        $holder = Invoke-LockHolder -Name $script:name -Body "New-Item '$($script:flag)' | Out-Null; [Environment]::Exit(0)"
        $holder.WaitForExit(30000) | Should -BeTrue
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $lock = Enter-DevcontainerBuildLock -Name $script:name
        $watch.Stop()
        try {
            $lock | Should -BeOfType ([System.Threading.Mutex])
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
        }
        finally { Exit-DevcontainerBuildLock -Lock $lock }
    }

    It 'takes no lock when DEVCONTAINER_BUILD_LOCK=0' {
        $holder = Invoke-LockHolder -Name $script:name -Body "New-Item '$($script:flag)' | Out-Null; Start-Sleep -Seconds 20"
        $old = $env:DEVCONTAINER_BUILD_LOCK
        try {
            Wait-ForFile $script:flag | Should -BeTrue
            $env:DEVCONTAINER_BUILD_LOCK = '0'
            Enter-DevcontainerBuildLock -Name $script:name | Should -BeNullOrEmpty
        }
        finally {
            $env:DEVCONTAINER_BUILD_LOCK = $old
            if (-not $holder.HasExited) { $holder.Kill() }
        }
    }
}

Describe 'Invoke-DevcontainerCli and the build lock' {
    BeforeEach {
        InModuleScope DevcontainerCli {
            $script:CliExitCode = 0
        }
        Mock -ModuleName DevcontainerCli Invoke-DevcontainerCliProcess { $script:CliExitCode = 0 }
        Mock -ModuleName DevcontainerCli Enter-DevcontainerBuildLock { [pscustomobject]@{ Held = $true } }
        Mock -ModuleName DevcontainerCli Exit-DevcontainerBuildLock { }
    }

    It 'takes and releases the lock for <sub>' -ForEach @(
        @{ sub = 'up' }
        @{ sub = 'build' }
    ) {
        Invoke-DevcontainerCli -Subcommand $sub -WorkspaceFolder $TestDrive
        Should -Invoke -ModuleName DevcontainerCli Enter-DevcontainerBuildLock -Times 1 -Exactly
        Should -Invoke -ModuleName DevcontainerCli Exit-DevcontainerBuildLock -Times 1 -Exactly
        Should -Invoke -ModuleName DevcontainerCli Invoke-DevcontainerCliProcess -Times 1 -Exactly
    }

    It 'releases the lock when the build fails' {
        Mock -ModuleName DevcontainerCli Invoke-DevcontainerCliProcess { throw 'boom' }
        { Invoke-DevcontainerCli -Subcommand up -WorkspaceFolder $TestDrive } | Should -Throw
        Should -Invoke -ModuleName DevcontainerCli Exit-DevcontainerBuildLock -Times 1 -Exactly
    }

    It 'takes no lock for <sub>' -ForEach @(
        @{ sub = 'exec' }
        @{ sub = 'run-user-commands' }
        @{ sub = 'set-up' }
        @{ sub = 'read-configuration' }
        @{ sub = 'features' }
    ) {
        Invoke-DevcontainerCli -Subcommand $sub -WorkspaceFolder $TestDrive
        Should -Invoke -ModuleName DevcontainerCli Enter-DevcontainerBuildLock -Times 0 -Exactly
        Should -Invoke -ModuleName DevcontainerCli Invoke-DevcontainerCliProcess -Times 1 -Exactly
    }

    It 'features test takes no lock by default' {
        $env:DEVCONTAINER_BUILD_LOCK_FEATURES_TEST = $null
        Invoke-DevcontainerCli -Subcommand features -Arguments @('test', '-f', 'git') -WorkspaceFolder $TestDrive
        Should -Invoke -ModuleName DevcontainerCli Enter-DevcontainerBuildLock -Times 0 -Exactly
    }

    It 'features test takes the lock with DEVCONTAINER_BUILD_LOCK_FEATURES_TEST=<value>' -ForEach @(
        @{ value = 'true' }
        @{ value = '1' }
    ) {
        $env:DEVCONTAINER_BUILD_LOCK_FEATURES_TEST = $value
        try {
            Invoke-DevcontainerCli -Subcommand features -Arguments @('test', '-f', 'git') -WorkspaceFolder $TestDrive
            Should -Invoke -ModuleName DevcontainerCli Enter-DevcontainerBuildLock -Times 1 -Exactly
            Should -Invoke -ModuleName DevcontainerCli Exit-DevcontainerBuildLock -Times 1 -Exactly
        }
        finally { $env:DEVCONTAINER_BUILD_LOCK_FEATURES_TEST = $null }
    }

    It 'other features subcommands take no lock even with the flag' {
        $env:DEVCONTAINER_BUILD_LOCK_FEATURES_TEST = 'true'
        try {
            Invoke-DevcontainerCli -Subcommand features -Arguments @('generate-docs') -WorkspaceFolder $TestDrive
            Should -Invoke -ModuleName DevcontainerCli Enter-DevcontainerBuildLock -Times 0 -Exactly
        }
        finally { $env:DEVCONTAINER_BUILD_LOCK_FEATURES_TEST = $null }
    }
}

Describe 'Stop-Devcontainer and the shutdown check (bootstrap/SHUTDOWN.md)' {
    BeforeAll {
        # Stop-Devcontainer ends in `exit <code>` when it refuses, which would end
        # this Pester run, so each case runs in a child pwsh with the module's
        # engine and CLI calls replaced (functions defined in module scope). The
        # fake CLI process exits with $rc and records the command it was given.
        # -WhatIf stands for "the container would have been stopped".
        function Invoke-StopCase {
            param([int]$CheckExit = 0, [switch]$Running, [switch]$Force, [switch]$CheckOnly, [string]$Check = 'my-check', [switch]$NoCheck)
            $log = Join-Path ([IO.Path]::GetTempPath()) "dcf-stop-$([guid]::NewGuid().ToString('N')).log"
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Check))
            $idsText = if ($Running) { "@('abc123')" } else { '@()' }
            $args2 = @("-WorkspaceFolder '$TestDrive'", "-WhatIf")
            if (-not $NoCheck) { $args2 += "-CommandB64 '$b64'" }
            if ($Force) { $args2 += '-Force' }
            if ($CheckOnly) { $args2 += '-CheckOnly' }
            $code = @"
Import-Module '$($script:ModulePath)' -Force
& (Get-Module DevcontainerCli) {
    function script:Resolve-DockerPath { 'docker' }
    function script:Get-RunningDevcontainerId { $idsText }
    function script:Invoke-DevcontainerCliProcess {
        param(`$Subcommand, `$WorkspaceFolder, `$CommandB64, `$NodeVersion, `$CliVersion, `$DockerPath)
        [IO.File]::AppendAllText('$log', "ran `$([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$CommandB64)))``n")
        `$script:CliExitCode = $CheckExit
    }
}
Stop-Devcontainer $($args2 -join ' ')
"@
            $psi = [System.Diagnostics.ProcessStartInfo]::new($script:PwshExe)
            foreach ($a in @('-NoLogo', '-NoProfile', '-Command', $code)) { $psi.ArgumentList.Add($a) }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $out = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            $ran = if (Test-Path $log) { Get-Content $log -Raw } else { '' }
            Remove-Item $log -ErrorAction SilentlyContinue
            [pscustomobject]@{ Exit = $proc.ExitCode; Output = $out; Ran = $ran; Stopped = ($out -match 'What if') }
        }
    }

    It 'goes ahead when the check passes' {
        $r = Invoke-StopCase -Running -CheckExit 0
        $r.Exit | Should -Be 0
        $r.Ran | Should -Match 'ran my-check'
        $r.Stopped | Should -BeTrue
    }

    It 'goes ahead when no check is given' {
        $r = Invoke-StopCase -Running -NoCheck
        $r.Exit | Should -Be 0
        $r.Ran | Should -BeNullOrEmpty
        $r.Stopped | Should -BeTrue
    }

    It 'refuses with the check''s exit code and the generic message' {
        $r = Invoke-StopCase -Running -CheckExit 3
        $r.Exit | Should -Be 3
        $r.Stopped | Should -BeFalse
        $r.Output | Should -Match 'Not stopping: the shutdown check \(my-check\) found the problems above'
        $r.Output | Should -Not -Match 'not installed'
    }

    It 'runs no check with -Force and stops' {
        $r = Invoke-StopCase -Running -Force -CheckExit 3
        $r.Exit | Should -Be 0
        $r.Ran | Should -BeNullOrEmpty
        $r.Stopped | Should -BeTrue
        $r.Output | Should -Match 'FORCE set'
    }

    It 'says the configured check is not installed on exit 127' {
        $r = Invoke-StopCase -Running -CheckExit 127
        $r.Exit | Should -Be 127
        $r.Stopped | Should -BeFalse
        $r.Output | Should -Match ([regex]::Escape('Not stopping: the shutdown check (my-check) is not installed in the container (exit 127). Define it, unset STOP_CHECK to use the default resolution, or run again with FORCE=1.'))
    }

    It 'does nothing and succeeds when no container runs' {
        $r = Invoke-StopCase -CheckExit 3
        $r.Exit | Should -Be 0
        $r.Ran | Should -BeNullOrEmpty
        $r.Output | Should -Match 'already stopped'
    }

    Context '-CheckOnly (devcontainer:prepshutdown)' {
        It 'runs the check and stops nothing' {
            $r = Invoke-StopCase -Running -CheckOnly -CheckExit 0
            $r.Exit | Should -Be 0
            $r.Ran | Should -Match 'ran my-check'
            $r.Stopped | Should -BeFalse
        }
        It 'passes the refusing check''s exit code on' {
            (Invoke-StopCase -Running -CheckOnly -CheckExit 4).Exit | Should -Be 4
        }
        It 'ignores -Force' {
            (Invoke-StopCase -Running -CheckOnly -Force -CheckExit 4).Exit | Should -Be 4
        }
        It 'says so and succeeds when no container runs' {
            $r = Invoke-StopCase -CheckOnly -CheckExit 4
            $r.Exit | Should -Be 0
            $r.Output | Should -Match 'nothing to check'
        }
    }
}

Describe 'Host type (HOST_TYPE, HOST_TYPE_PRIORITY, DCF_HOST_*)' {
    # The detection evidence is mocked inside the module: the OS the launcher runs
    # on, whether docker / `wsl -e docker` answer, whether wslc.exe exists.
    BeforeAll {
        $script:EnvNames = 'HOST_TYPE', 'HOST_TYPE_PRIORITY', 'DEVCONTAINER_DOCKER_PATH', 'DCF_HOST_TYPE', 'DCF_HOST_HOME', 'DCF_HOST_SSH_AGENT', 'SSH_AGENT_MODE', 'SSH_AUTH_SOCK', 'USERPROFILE', 'HOME'
        $script:SavedEnv = @{}
        foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
        function Initialize-Evidence {
            param([string]$Os, [bool]$Docker = $false, [bool]$WslDocker = $false, [string]$Wslc = '', [bool]$Sock = $false)
            $script:ev = @{ Os = $Os; Docker = $Docker; WslDocker = $WslDocker; Wslc = $Wslc; Sock = $Sock }
            Mock -ModuleName DevcontainerCli Test-HostSocket { $script:ev.Sock }
            Mock -ModuleName DevcontainerCli Get-HostPlatform { $script:ev.Os }
            Mock -ModuleName DevcontainerCli Test-DockerResponding { $script:ev.Docker }
            Mock -ModuleName DevcontainerCli Test-WslDockerResponding { $script:ev.WslDocker }
            Mock -ModuleName DevcontainerCli Get-WslcPath { if ($script:ev.Wslc) { $script:ev.Wslc } else { $null } }
            Mock -ModuleName DevcontainerCli Get-WslHome { '/home/wsluser' }
            # `docker` is on PATH exactly when the evidence says so (the engine lookup uses Get-Command).
            Mock -ModuleName DevcontainerCli Get-Command { if ($script:ev.Docker) { [pscustomobject]@{ Source = '/fake/docker' } } } -ParameterFilter { $Name -eq 'docker' }
        }
    }
    BeforeEach {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $null) }
        [Environment]::SetEnvironmentVariable('USERPROFILE', 'C:\Users\test')
        [Environment]::SetEnvironmentVariable('HOME', '/home/test')
        Clear-HostProfileCache
    }
    AfterAll { foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) } }

    It 'takes an explicit id without running any detection' {
        Initialize-Evidence -Os windows   # nothing answers: auto would fail
        $env:HOST_TYPE = 'windows-wslc'
        $t = Resolve-HostType
        $t.Type | Should -Be 'windows-wslc'
        $t.Why | Should -Match 'explicitly'
        Should -Invoke -ModuleName DevcontainerCli Test-DockerResponding -Times 0 -Exactly
        Should -Invoke -ModuleName DevcontainerCli Get-WslcPath -Times 0 -Exactly
    }

    It 'rejects an unknown HOST_TYPE and lists the known ids' {
        Initialize-Evidence -Os windows
        $env:HOST_TYPE = 'solaris'
        { Resolve-HostType } | Should -Throw "*'solaris' is unknown*windows-docker, windows-wsl-docker, windows-wslc, linux, macos*"
    }

    It 'rejects an unknown id in HOST_TYPE_PRIORITY' {
        Initialize-Evidence -Os windows
        $env:HOST_TYPE_PRIORITY = 'windows-docker,bogus'
        { Resolve-HostType } | Should -Throw "*HOST_TYPE_PRIORITY*'bogus'*Known ids*"
    }

    It 'auto takes the first id of the default Windows priority that passes' {
        Initialize-Evidence -Os windows -Docker $false -WslDocker $true -Wslc 'C:\wslc.exe'
        $t = Resolve-HostType
        $t.Type | Should -Be 'windows-wsl-docker'
        ($t.Priority -join ',') | Should -Be 'windows-docker,windows-wsl-docker,windows-wslc'
    }

    It 'auto falls through to windows-wslc when only wslc.exe exists' {
        Initialize-Evidence -Os windows -Wslc 'C:\wslc.exe'
        (Resolve-HostType).Type | Should -Be 'windows-wslc'
    }

    It 'an organisation priority list overrides the default order' {
        # Both docker and WSL docker answer: the default picks windows-docker, the org list windows-wsl-docker.
        Initialize-Evidence -Os windows -Docker $true -WslDocker $true
        (Resolve-HostType).Type | Should -Be 'windows-docker'
        $env:HOST_TYPE_PRIORITY = 'windows-wsl-docker, windows-docker,windows-wslc'
        $t = Resolve-HostType
        $t.Type | Should -Be 'windows-wsl-docker'
        ($t.Priority -join ',') | Should -Be 'windows-wsl-docker,windows-docker,windows-wslc'
    }

    It 'auto names every failed check when nothing passes' {
        Initialize-Evidence -Os windows
        { Resolve-HostType } | Should -Throw '*no host type*windows-docker*windows-wsl-docker*windows-wslc*'
    }

    It 'defaults per OS: inside WSL, Linux and macOS' {
        Initialize-Evidence -Os wsl
        (Resolve-HostType).Type | Should -Be 'windows-wsl-docker'
        Initialize-Evidence -Os linux
        (Resolve-HostType).Type | Should -Be 'linux'
        Initialize-Evidence -Os macos
        (Resolve-HostType).Type | Should -Be 'macos'
    }

    It 'refuses an explicit id the launcher cannot be' {
        Initialize-Evidence -Os linux
        $env:HOST_TYPE = 'windows-docker'
        { Resolve-HostType } | Should -Throw '*cannot run from a launcher on linux*'
    }

    It 'sets DCF_HOST_TYPE, DCF_HOST_HOME and DCF_HOST_SSH_AGENT per id' -ForEach @(
        @{ Os = 'windows'; Id = 'windows-docker'; HostHome = 'C:\Users\test'; Docker = $true; Agent = 'none' }
        @{ Os = 'windows'; Id = 'windows-wslc'; HostHome = 'C:\Users\test'; Docker = $false; Agent = 'none' }
        @{ Os = 'windows'; Id = 'windows-wsl-docker'; HostHome = '/home/wsluser'; Docker = $true; Agent = 'none' }
        @{ Os = 'wsl'; Id = 'windows-wsl-docker'; HostHome = '/home/test'; Docker = $true; Agent = 'none' }
        @{ Os = 'linux'; Id = 'linux'; HostHome = '/home/test'; Docker = $true; Agent = 'none' }
        @{ Os = 'macos'; Id = 'macos'; HostHome = '/home/test'; Docker = $true; Agent = 'socket' }
    ) {
        Initialize-Evidence -Os $Os -Docker $Docker -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = $Id
        $p = Initialize-HostEnvironment
        $env:DCF_HOST_TYPE | Should -Be $Id
        $env:DCF_HOST_HOME | Should -Be $HostHome
        $env:DCF_HOST_SSH_AGENT | Should -Be $Agent
        $p.Type | Should -Be $Id
    }

    It 'DCF_HOST_SSH_AGENT for <Id> on <Os> with a socket in SSH_AUTH_SOCK is <Agent>' -ForEach @(
        @{ Os = 'linux'; Id = 'linux'; Agent = 'socket'; Source = '/run/user/1000/agent' }
        @{ Os = 'wsl'; Id = 'windows-wsl-docker'; Agent = 'socket'; Source = '/run/user/1000/agent' }
        @{ Os = 'macos'; Id = 'macos'; Agent = 'socket'; Source = '/run/host-services/ssh-auth.sock' }
        @{ Os = 'windows'; Id = 'windows-wsl-docker'; Agent = 'none'; Source = '' }
        @{ Os = 'windows'; Id = 'windows-docker'; Agent = 'none'; Source = '' }
        @{ Os = 'windows'; Id = 'windows-wslc'; Agent = 'none'; Source = '' }
    ) {
        Initialize-Evidence -Os $Os -Docker $true -Wslc 'C:\wslc.exe' -Sock $true
        $env:HOST_TYPE = $Id
        $env:SSH_AUTH_SOCK = '/run/user/1000/agent'
        $a = Resolve-SshAgent -Type $Id
        $a.Mode | Should -Be $Agent
        $a.Socket | Should -Be $Source
    }

    It 'SSH_AUTH_SOCK naming no socket gives none on linux and windows-wsl-docker, and SSH_AGENT_MODE=key wins everywhere' {
        Initialize-Evidence -Os linux -Docker $true -Sock $false
        $env:SSH_AUTH_SOCK = '/run/user/1000/agent'
        (Resolve-SshAgent -Type 'linux').Mode | Should -Be 'none'
        (Resolve-SshAgent -Type 'windows-wsl-docker').Mode | Should -Be 'none'
        Initialize-Evidence -Os linux -Docker $true -Sock $true
        $env:SSH_AGENT_MODE = 'key'
        $k = Resolve-SshAgent -Type 'linux'
        $k.Mode | Should -Be 'key'
        $k.Socket | Should -Be ''
        (Resolve-SshAgent -Type 'macos').Mode | Should -Be 'key'
        (Resolve-SshAgent -Type 'windows-docker').Mode | Should -Be 'key'
        $env:HOST_TYPE = 'linux'
        [void](Initialize-HostEnvironment)
        $env:DCF_HOST_SSH_AGENT | Should -Be 'key'
    }

    It 'engine follows the host type: wslc for windows-wslc, docker for windows-docker' {
        Initialize-Evidence -Os windows -Docker $true -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = 'windows-wslc'
        Resolve-DockerPath | Should -Be 'C:\wslc.exe'
        Clear-HostProfileCache
        $env:HOST_TYPE = 'windows-docker'
        Resolve-DockerPath | Should -BeNullOrEmpty
    }

    It 'DEVCONTAINER_DOCKER_PATH still wins for the engine, whatever the host type' {
        Initialize-Evidence -Os windows -Docker $true -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = 'windows-wslc'
        $env:DEVCONTAINER_DOCKER_PATH = $PSCommandPath    # an existing file stands for "a full path"
        Resolve-DockerPath | Should -Be (Resolve-Path $PSCommandPath).Path
        (Resolve-HostProfile).Engine | Should -Be (Resolve-Path $PSCommandPath).Path
    }

    It 'with DEVCONTAINER_DOCKER_PATH set and nothing detected, auto takes the first id that fits the OS' {
        Initialize-Evidence -Os windows
        $env:DEVCONTAINER_DOCKER_PATH = $PSCommandPath
        $t = Resolve-HostType
        $t.Type | Should -Be 'windows-docker'
        $t.Why | Should -Match 'DEVCONTAINER_DOCKER_PATH'
    }
}

Describe 'Host mounts (HOST_MOUNTS, --mount on up)' {
    # Same evidence as the host type tests: the OS, the engine, mocked inside the module.
    BeforeAll {
        $script:EnvNames = 'HOST_TYPE', 'HOST_TYPE_PRIORITY', 'HOST_MOUNTS', 'DEVCONTAINER_DOCKER_PATH', 'DCF_HOST_TYPE', 'DCF_HOST_HOME', 'DCF_HOST_SSH_AGENT', 'SSH_AGENT_MODE', 'SSH_AUTH_SOCK', 'USERPROFILE', 'HOME', 'DCF_HOST_CLOUD_FOLDER', 'CLOUD_FOLDER_MOUNT_POINT'
        $script:SavedEnv = @{}
        foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
        $script:SavedPath = $env:PATH
        function Initialize-MountEvidence {
            param([string]$Os, [bool]$Docker = $true, [string]$Wslc = '', [bool]$Sock = $false)
            $script:ev = @{ Os = $Os; Docker = $Docker; Wslc = $Wslc; Sock = $Sock }
            Mock -ModuleName DevcontainerCli Test-HostSocket { $script:ev.Sock }
            Mock -ModuleName DevcontainerCli Get-HostPlatform { $script:ev.Os }
            Mock -ModuleName DevcontainerCli Test-DockerResponding { $script:ev.Docker }
            Mock -ModuleName DevcontainerCli Test-WslDockerResponding { $false }
            Mock -ModuleName DevcontainerCli Get-WslcPath { if ($script:ev.Wslc) { $script:ev.Wslc } else { $null } }
            Mock -ModuleName DevcontainerCli Get-WslHome { '/home/wsluser' }
            Mock -ModuleName DevcontainerCli Get-Command { if ($script:ev.Docker) { [pscustomobject]@{ Source = '/fake/docker' } } } -ParameterFilter { $Name -eq 'docker' }
            # The tests that pass a Windows-style home must not create folders on the test machine.
            Mock -ModuleName DevcontainerCli Initialize-HostMountSource { }
        }
        # A workspace whose .devcontainer/devcontainer.json holds $Json (JSONC).
        function Get-MountWorkspace {
            param([string]$Json)
            $ws = Join-Path $TestDrive ('ws-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $ws '.devcontainer') -Force | Out-Null
            if ($Json) { [System.IO.File]::WriteAllText((Join-Path $ws '.devcontainer/devcontainer.json'), $Json) }
            $ws
        }
        $script:OwnMount = @'
{
  // the repository's own line, as this collection's devcontainer.json has it
  "mounts": [
    "source=${localEnv:USERPROFILE}/.git-dirs,target=/git-dirs,type=bind", // trailing comma follows
  ],
  "name": "https://example.invalid/not-a-comment"
}
'@
    }
    BeforeEach {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $null) }
        [Environment]::SetEnvironmentVariable('USERPROFILE', 'C:\Users\test')
        [Environment]::SetEnvironmentVariable('HOME', '/home/test')
        Clear-HostProfileCache
    }
    AfterAll {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) }
        $env:PATH = $script:SavedPath
    }

    It 'lists the .git-dirs mount of the home for <Id>, and nothing when the home is unknown' -ForEach @(
        @{ Id = 'windows-docker' }, @{ Id = 'windows-wsl-docker' }, @{ Id = 'windows-wslc' }, @{ Id = 'linux' }, @{ Id = 'macos' }
    ) {
        $m = @(Get-HostMount -Type $Id -HostHome '/h/u')
        $m.Count | Should -Be 1
        $m[0].Name | Should -Be 'git-dirs'
        $m[0].Source | Should -Be '/h/u/.git-dirs'
        $m[0].Target | Should -Be '/git-dirs'
        ConvertTo-MountArgument -Mount $m[0] | Should -Be 'type=bind,source=/h/u/.git-dirs,target=/git-dirs'
        @(Get-HostMount -Type $Id -HostHome '').Count | Should -Be 0
    }

    It 'lists the ssh-agent mount at the Feature path only for -SshAgent socket with a source' {
        $t = '/var/lib/devcontainer-features/ssh-agent/agent.sock'
        $m = @(Get-HostMount -Type 'linux' -HostHome '/h/u' -SshAgent 'socket' -SshSocket '/run/user/1/agent')
        $m.Count | Should -Be 2
        $m[1].Name | Should -Be 'ssh-agent'
        $m[1].Source | Should -Be '/run/user/1/agent'
        $m[1].Target | Should -Be $t
        ConvertTo-MountArgument -Mount $m[1] | Should -Be "type=bind,source=/run/user/1/agent,target=$t"
        @(Get-HostMount -Type 'linux' -HostHome '/h/u' -SshAgent 'none' -SshSocket '/run/user/1/agent').Count | Should -Be 1
        @(Get-HostMount -Type 'linux' -HostHome '/h/u' -SshAgent 'key' -SshSocket '/run/user/1/agent').Count | Should -Be 1
        @(Get-HostMount -Type 'linux' -HostHome '/h/u' -SshAgent 'socket' -SshSocket '').Count | Should -Be 1
        @(Get-HostMount -Type 'linux' -HostHome '' -SshAgent 'socket' -SshSocket '/run/user/1/agent').Count | Should -Be 1
    }

    It 'passes the agent --mount for <Id> (<Os>) only where the host type has a socket: <Expect>' -ForEach @(
        @{ Os = 'linux'; Id = 'linux'; Sock = $true; Expect = '/run/user/1000/agent' }
        @{ Os = 'linux'; Id = 'linux'; Sock = $false; Expect = $null }
        @{ Os = 'wsl'; Id = 'windows-wsl-docker'; Sock = $true; Expect = '/run/user/1000/agent' }
        @{ Os = 'macos'; Id = 'macos'; Sock = $false; Expect = '/run/host-services/ssh-auth.sock' }
        @{ Os = 'windows'; Id = 'windows-docker'; Sock = $true; Expect = $null }
        @{ Os = 'windows'; Id = 'windows-wslc'; Sock = $true; Expect = $null }
        @{ Os = 'windows'; Id = 'windows-wsl-docker'; Sock = $true; Expect = $null }
    ) {
        Initialize-MountEvidence -Os $Os -Wslc 'C:\wslc.exe' -Sock $Sock
        $env:HOST_TYPE = $Id
        $env:SSH_AUTH_SOCK = '/run/user/1000/agent'
        $ws = Get-MountWorkspace '{ "name": "plain" }'
        $a = @(Get-HostMountArgument -WorkspaceFolder $ws)
        $agent = @($a | Where-Object { $_ -like '*target=/var/lib/devcontainer-features/ssh-agent/agent.sock' })
        if ($Expect) {
            $agent | Should -HaveCount 1
            $agent[0] | Should -Be "type=bind,source=$Expect,target=/var/lib/devcontainer-features/ssh-agent/agent.sock"
        }
        else { $agent | Should -HaveCount 0 }
    }

    It 'SSH_AGENT_MODE=key and HOST_MOUNTS=false both suppress the agent mount; a repository mount of the target skips it' {
        Initialize-MountEvidence -Os linux -Sock $true
        $env:HOST_TYPE = 'linux'
        $env:SSH_AUTH_SOCK = '/run/user/1000/agent'
        $ws = Get-MountWorkspace '{ }'
        @(Get-HostMountArgument -WorkspaceFolder $ws) | Should -HaveCount 4
        $env:SSH_AGENT_MODE = 'key'
        @(Get-HostMountArgument -WorkspaceFolder $ws) | Should -HaveCount 2
        $env:SSH_AGENT_MODE = $null
        $env:HOST_MOUNTS = 'false'
        @(Get-HostMountArgument -WorkspaceFolder $ws) | Should -HaveCount 0
        $env:HOST_MOUNTS = $null
        $own = Get-MountWorkspace '{ "mounts": ["source=a,target=/var/lib/devcontainer-features/ssh-agent/agent.sock,type=bind"] }'
        $out = @(Get-HostMountArgument -WorkspaceFolder $own 6>&1)
        @($out | Where-Object { $_ -is [string] -and $_ -like '*ssh-agent/agent.sock' }) | Should -HaveCount 0
        $lines = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { $_.MessageData.Message })
        $lines | Should -Contain "host mount skipped: /var/lib/devcontainer-features/ssh-agent/agent.sock is already mounted by this repository's devcontainer.json"
    }

    It 'Initialize-HostMountSource leaves an ssh-agent source alone (a socket is not ours to create)' {
        $src = Join-Path $TestDrive 'agent-sock-source'
        $m = [pscustomobject]@{ Name = 'ssh-agent'; Source = $src; Target = '/x'; Type = 'bind' }
        Initialize-HostMountSource -Mount $m -Type linux
        Test-Path $src | Should -BeFalse
    }

    It 'lists the cloud-folder mount only with a -CloudFolder source, always at the fixed host mount' {
        $m = @(Get-HostMount -Type 'windows-docker' -HostHome 'C:\Users\test' -CloudFolder 'C:\Users\test\Synced - Docs\Shared')
        $m.Count | Should -Be 2
        $m[1].Name | Should -Be 'cloud-folder'
        $m[1].Target | Should -Be '/mnt/cloud-folder-host'
        ConvertTo-MountArgument -Mount $m[1] | Should -Be 'type=bind,source=C:\Users\test\Synced - Docs\Shared,target=/mnt/cloud-folder-host'
        (@(Get-HostMount -Type 'linux' -HostHome '' -CloudFolder '/srv/docs'))[0].Target | Should -Be '/mnt/cloud-folder-host'
        @(Get-HostMount -Type 'windows-docker' -HostHome 'C:\Users\test' -CloudFolder '').Count | Should -Be 1
    }

    It 'passes the cloud-folder --mount for <Id> (<Os>) with <Source>: <Expect>' -ForEach @(
        @{ Os = 'windows'; Id = 'windows-docker'; Source = 'C:\Users\test\Synced - Docs\Shared'; Exists = $true; Expect = 'mounted' }
        @{ Os = 'windows'; Id = 'windows-wslc'; Source = 'C:\Users\test\Synced - Docs\Shared'; Exists = $true; Expect = 'mounted' }
        @{ Os = 'windows'; Id = 'windows-docker'; Source = 'C:\Users\test\Missing'; Exists = $false; Expect = 'skipped' }
        @{ Os = 'windows'; Id = 'windows-wsl-docker'; Source = '/home/wsluser/docs'; Exists = $false; Expect = 'mounted' }
        @{ Os = 'linux'; Id = 'linux'; Source = 'C:\Users\test\Synced - Docs\Shared'; Exists = $false; Expect = 'mounted' }
        @{ Os = 'linux'; Id = 'linux'; Source = '/srv/missing-docs'; Exists = $false; Expect = 'skipped' }
    ) {
        Initialize-MountEvidence -Os $Os -Wslc 'C:\wslc.exe'
        $script:CloudExists = $Exists
        Mock -ModuleName DevcontainerCli Test-Path { $script:CloudExists } -ParameterFilter { $PathType -eq 'Container' }
        Mock -ModuleName DevcontainerCli Test-Path { Microsoft.PowerShell.Management\Test-Path @PesterBoundParameters } -ParameterFilter { $PathType -ne 'Container' }
        $env:HOST_TYPE = $Id
        $env:DCF_HOST_CLOUD_FOLDER = $Source
        $ws = Get-MountWorkspace '{ "name": "plain" }'
        $out = @(Get-HostMountArgument -WorkspaceFolder $ws 3>&1)
        $cloud = @($out | Where-Object { $_ -is [string] -and $_ -like '*target=/mnt/cloud-folder-host' })
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
        if ($Expect -eq 'mounted') {
            $cloud | Should -HaveCount 1
            $cloud[0] | Should -Be "type=bind,source=$Source,target=/mnt/cloud-folder-host"
            $warnings | Should -HaveCount 0
        }
        else {
            $cloud | Should -HaveCount 0
            $warnings | Should -Contain "host mount cloud-folder skipped: DCF_HOST_CLOUD_FOLDER '$Source' is not a folder on this host; the container starts without it (task cloud-folder:status says so)."
        }
    }

    It 'the cloud-folder target is fixed (CLOUD_FOLDER_MOUNT_POINT is no launcher setting); HOST_MOUNTS=false and a repository mount of the target suppress it' {
        Initialize-MountEvidence -Os linux
        $env:HOST_TYPE = 'linux'
        $env:DCF_HOST_CLOUD_FOLDER = 'C:\Users\test\Shared'
        $ws = Get-MountWorkspace '{ }'
        $env:CLOUD_FOLDER_MOUNT_POINT = '/mnt/office-shared'
        @(Get-HostMountArgument -WorkspaceFolder $ws) | Should -Contain 'type=bind,source=C:\Users\test\Shared,target=/mnt/cloud-folder-host'
        $env:CLOUD_FOLDER_MOUNT_POINT = $null
        $env:HOST_MOUNTS = 'false'
        @(Get-HostMountArgument -WorkspaceFolder $ws) | Should -HaveCount 0
        $env:HOST_MOUNTS = $null
        $own = Get-MountWorkspace '{ "mounts": ["source=C:/x,target=/mnt/cloud-folder-host,type=bind"] }'
        @(Get-HostMountArgument -WorkspaceFolder $own 6>$null) | Should -Not -Contain 'type=bind,source=C:\Users\test\Shared,target=/mnt/cloud-folder-host'
    }

    It 'sets DCF_HOST_CLOUD_FOLDER unchanged for the CLI, and host prints it' {
        Initialize-MountEvidence -Os windows -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = 'windows-wslc'
        $env:DCF_HOST_CLOUD_FOLDER = 'C:\Users\test\Synced - Docs\Shared'
        (Initialize-HostEnvironment).CloudFolder | Should -Be 'C:\Users\test\Synced - Docs\Shared'
        $env:DCF_HOST_CLOUD_FOLDER | Should -Be 'C:\Users\test\Synced - Docs\Shared'
        $text = (Show-HostProfile -WorkspaceFolder (Get-MountWorkspace '{ }') 6>&1 3>$null | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -Match 'DCF_HOST_CLOUD_FOLDER: C:\\Users\\test\\Synced - Docs\\Shared'
        $env:DCF_HOST_CLOUD_FOLDER = $null
        Clear-HostProfileCache
        $text = (Show-HostProfile -WorkspaceFolder (Get-MountWorkspace '{ }') 6>&1 | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -Match 'DCF_HOST_CLOUD_FOLDER: \(unset\)'
    }

    It 'Initialize-HostMountSource leaves a cloud-folder source alone (the user''s folder is never created)' {
        $src = Join-Path $TestDrive 'cloud-folder-source'
        $m = [pscustomobject]@{ Name = 'cloud-folder'; Source = $src; Target = '/mnt/cloud-folder-host'; Type = 'bind' }
        Initialize-HostMountSource -Mount $m -Type linux
        Test-Path $src | Should -BeFalse
    }

    It 'passes --mount for <Id> with the home of that host type' -ForEach @(
        @{ Os = 'windows'; Id = 'windows-docker'; Source = 'C:\Users\test/.git-dirs' }
        @{ Os = 'windows'; Id = 'windows-wslc'; Source = 'C:\Users\test/.git-dirs' }
        @{ Os = 'windows'; Id = 'windows-wsl-docker'; Source = '/home/wsluser/.git-dirs' }
        @{ Os = 'linux'; Id = 'linux'; Source = '/home/test/.git-dirs' }
    ) {
        Initialize-MountEvidence -Os $Os -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = $Id
        $ws = Get-MountWorkspace '{ "name": "plain" }'
        $a = @(Get-HostMountArgument -WorkspaceFolder $ws)
        $a | Should -HaveCount 2
        $a[0] | Should -Be '--mount'
        $a[1] | Should -Be "type=bind,source=$Source,target=/git-dirs"
        Should -Invoke -ModuleName DevcontainerCli Initialize-HostMountSource -Times 1 -Exactly
    }

    It 'skips a mount whose target devcontainer.json already declares, and says so in one line' {
        Initialize-MountEvidence -Os windows -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = 'windows-wslc'
        $ws = Get-MountWorkspace $script:OwnMount
        $out = @(Get-HostMountArgument -WorkspaceFolder $ws 6>&1)
        @($out | Where-Object { $_ -is [string] -and $_ -eq '--mount' }).Count | Should -Be 0
        $lines = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { $_.MessageData.Message })
        $lines | Should -HaveCount 1
        $lines[0] | Should -Be "host mount skipped: /git-dirs is already mounted by this repository's devcontainer.json"
        Should -Invoke -ModuleName DevcontainerCli Initialize-HostMountSource -Times 0 -Exactly
    }

    It 'reads targets from strings, objects and --config, ignores comments and other targets' {
        $ws = Get-MountWorkspace @'
{
  "mounts": [
    // "source=a,target=/commented-out,type=bind"
    { "type": "volume", "source": "v", "target": "/from-object" },
    "source=b,target=/from-string/,type=bind"
  ],
  "containerEnv": { "X": "target=/not-a-mount" }
}
'@
        @(Get-ConfiguredMountTarget -WorkspaceFolder $ws) | Sort-Object | Should -Be @('/from-object', '/from-string')
        $other = Join-Path $ws 'other.json'
        [System.IO.File]::WriteAllText($other, '{ "mounts": ["source=a,target=/from-config,type=bind"] }')
        @(Get-ConfiguredMountTarget -WorkspaceFolder $ws -Arguments @('--config', $other)) | Should -Be @('/from-config')
        @(Get-ConfiguredMountTarget -WorkspaceFolder $ws -Arguments @("--config=$other")) | Should -Be @('/from-config')
        @(Get-ConfiguredMountTarget -WorkspaceFolder (Get-MountWorkspace)) | Should -HaveCount 0
    }

    It 'does not skip when the repository mounts some other target' {
        Initialize-MountEvidence -Os linux
        $env:HOST_TYPE = 'linux'
        $ws = Get-MountWorkspace '{ "mounts": ["source=a,target=/git-dirs-other,type=bind"] }'
        @(Get-HostMountArgument -WorkspaceFolder $ws) | Should -HaveCount 2
    }

    It 'HOST_MOUNTS=<Value> turns the launcher mounts off' -ForEach @(
        @{ Value = 'false' }, @{ Value = '0' }, @{ Value = 'no' }
    ) {
        Initialize-MountEvidence -Os linux
        $env:HOST_TYPE = 'linux'
        $env:HOST_MOUNTS = $Value
        $ws = Get-MountWorkspace '{ }'
        @(Get-HostMountArgument -WorkspaceFolder $ws) | Should -HaveCount 0
        Should -Invoke -ModuleName DevcontainerCli Initialize-HostMountSource -Times 0 -Exactly
        $env:HOST_MOUNTS = 'true'
        @(Get-HostMountArgument -WorkspaceFolder $ws) | Should -HaveCount 2
    }

    It 'host lists what it would add, what it would skip, and off' {
        Initialize-MountEvidence -Os windows -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = 'windows-wslc'
        $text = { param($ws) (Show-HostProfile -WorkspaceFolder $ws 6>&1 | ForEach-Object { $_.MessageData.Message }) -join "`n" }
        & $text (Get-MountWorkspace '{ }') | Should -Match 'host mount \(add\)\s+: git-dirs: type=bind,source=C:\\Users\\test/\.git-dirs,target=/git-dirs'
        & $text (Get-MountWorkspace $script:OwnMount) | Should -Match 'host mount \(skip\)\s+: git-dirs: /git-dirs is already mounted by devcontainer\.json'
        $env:HOST_MOUNTS = 'false'
        & $text (Get-MountWorkspace '{ }') | Should -Match 'host mounts\s+: off \(HOST_MOUNTS=false\)'
    }
}

# The argument list of the real CLI call: a stub `devcontainer` first on PATH records its
# arguments (the Windows branch runs the portable node.exe instead, so these run on Linux/macOS).
Describe 'The up argument list carries the host mounts' -Skip:$IsWindows {
    BeforeAll {
        $script:EnvNames = 'HOST_TYPE', 'HOST_MOUNTS', 'DEVCONTAINER_DOCKER_PATH', 'HOME', 'SSH_AUTH_SOCK', 'SSH_AGENT_MODE', 'DCF_HOST_TYPE', 'DCF_HOST_HOME', 'DCF_HOST_SSH_AGENT', 'DCF_HOST_CLOUD_FOLDER', 'CLOUD_FOLDER_MOUNT_POINT'
        $script:SavedEnv = @{}
        foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
        $script:SavedPath = $env:PATH
        $script:Bin = Join-Path $TestDrive 'bin'
        New-Item -ItemType Directory -Path $script:Bin | Out-Null
        $script:Rec = Join-Path $TestDrive 'args.txt'
        Set-Content (Join-Path $script:Bin 'devcontainer') "#!/bin/sh`nfor a in `"`$@`"; do echo `"`$a`"; done > '$($script:Rec)'"
        chmod +x (Join-Path $script:Bin 'devcontainer')
        Set-Content (Join-Path $script:Bin 'docker') "#!/bin/sh`nexit 0"
        chmod +x (Join-Path $script:Bin 'docker')
        function Invoke-Recorded {
            param([string]$Subcommand, [string]$Json = '{ }')
            $ws = Join-Path $TestDrive ('ws-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $ws '.devcontainer') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $ws '.devcontainer/devcontainer.json'), $Json)
            Remove-Item $script:Rec -ErrorAction SilentlyContinue
            Invoke-DevcontainerCliProcess -Subcommand $Subcommand -WorkspaceFolder $ws 6>$null
            @(Get-Content $script:Rec)
        }
    }
    BeforeEach {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $null) }
        $env:PATH = $script:Bin + [System.IO.Path]::PathSeparator + $script:SavedPath
        $env:HOME = Join-Path $TestDrive 'home'
        $env:HOST_TYPE = 'linux'
        Clear-HostProfileCache
    }
    AfterAll {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) }
        $env:PATH = $script:SavedPath
    }

    It 'up gets --mount for the .git-dirs of the home, and the folder exists' {
        $a = Invoke-Recorded -Subcommand up
        $i = [array]::IndexOf($a, '--mount')
        $i | Should -BeGreaterThan 0
        $a[$i + 1] | Should -Be "type=bind,source=$($env:HOME)/.git-dirs,target=/git-dirs"
        Test-Path (Join-Path $env:HOME '.git-dirs') | Should -BeTrue
    }

    It 'Initialize-HostMountSource creates the source folder, and is idempotent' {
        $dir = Join-Path $TestDrive 'fresh/.git-dirs'
        $m = [pscustomobject]@{ Name = 'git-dirs'; Source = $dir; Target = '/git-dirs'; Type = 'bind' }
        Initialize-HostMountSource -Mount $m -Type linux
        Test-Path $dir -PathType Container | Should -BeTrue
        { Initialize-HostMountSource -Mount $m -Type linux } | Should -Not -Throw
    }

    It 'up passes no --mount when devcontainer.json already mounts /git-dirs' {
        $a = Invoke-Recorded -Subcommand up -Json '{ "mounts": ["source=${localEnv:HOME}/.git-dirs,target=/git-dirs,type=bind"] }'
        $a | Should -Not -Contain '--mount'
        $a[0] | Should -Be 'up'
    }

    It 'up gets --mount for DCF_HOST_CLOUD_FOLDER at the Feature host mount, and none without it' {
        (Invoke-Recorded -Subcommand up) | Should -Not -Contain 'type=bind,source=,target=/mnt/cloud-folder-host'
        @((Invoke-Recorded -Subcommand up) | Where-Object { $_ -like '*target=/mnt/cloud-folder-host' }) | Should -HaveCount 0
        $docs = Join-Path $TestDrive 'Synced Docs'
        New-Item -ItemType Directory -Path $docs -Force | Out-Null
        $env:DCF_HOST_CLOUD_FOLDER = $docs
        $a = Invoke-Recorded -Subcommand up
        $a | Should -Contain "type=bind,source=$docs,target=/mnt/cloud-folder-host"
        $a[[array]::IndexOf($a, "type=bind,source=$docs,target=/mnt/cloud-folder-host") - 1] | Should -Be '--mount'
        # The stub records with sh's echo, which reads \t and the like: the path has none of them.
        $env:DCF_HOST_CLOUD_FOLDER = 'C:\Users\Synced - Docs\Shared'
        (Invoke-Recorded -Subcommand up) | Should -Contain 'type=bind,source=C:\Users\Synced - Docs\Shared,target=/mnt/cloud-folder-host'
    }

    It 'up passes no --mount with HOST_MOUNTS=false' {
        $env:HOST_MOUNTS = 'false'
        (Invoke-Recorded -Subcommand up) | Should -Not -Contain '--mount'
    }

    It '<Sub> never gets --mount' -ForEach @(@{ Sub = 'build' }, @{ Sub = 'exec' }, @{ Sub = 'read-configuration' }) {
        (Invoke-Recorded -Subcommand $Sub) | Should -Not -Contain '--mount'
    }
}

# FUSE on request (cloud-folder proposal, slice 3; ADR 0031), the counterpart of the FUSE part of
# test/bootstrap/host_mounts_test.sh: DCF_HOST_FUSE=1 sets the three DCF_HOST_FUSE_* variables the
# repository's runArgs read, unset removes them, and the CLI's argument list is the same either way.
Describe 'FUSE on request (DCF_HOST_FUSE)' -Skip:$IsWindows {
    BeforeAll {
        $script:FuseEnvNames = 'HOST_TYPE', 'HOST_MOUNTS', 'DEVCONTAINER_DOCKER_PATH', 'HOME', 'SSH_AUTH_SOCK', 'SSH_AGENT_MODE', 'DCF_HOST_TYPE', 'DCF_HOST_HOME', 'DCF_HOST_SSH_AGENT', 'DCF_HOST_CLOUD_FOLDER', 'DCF_HOST_FUSE', 'DCF_HOST_FUSE_DEVICE', 'DCF_HOST_FUSE_CAP', 'DCF_HOST_FUSE_SECURITY'
        $script:FuseSavedEnv = @{}
        foreach ($n in $script:FuseEnvNames) { $script:FuseSavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
        $script:FuseSavedPath = $env:PATH
        $script:FuseBin = Join-Path $TestDrive 'fuse-bin'
        New-Item -ItemType Directory -Path $script:FuseBin | Out-Null
        $script:FuseRec = Join-Path $TestDrive 'fuse-args.txt'
        Set-Content (Join-Path $script:FuseBin 'devcontainer') "#!/bin/sh`nfor a in `"`$@`"; do echo `"`$a`"; done > '$($script:FuseRec)'`nenv | grep '^DCF_HOST_FUSE' | sort > '$($script:FuseRec).env'"
        chmod +x (Join-Path $script:FuseBin 'devcontainer')
        Set-Content (Join-Path $script:FuseBin 'docker') "#!/bin/sh`nexit 0"
        chmod +x (Join-Path $script:FuseBin 'docker')
        $script:Slots = @'
{
  "runArgs": [
    "${localEnv:DCF_HOST_FUSE_DEVICE:--label=dcf.fuse.device=off}",
    "${localEnv:DCF_HOST_FUSE_CAP:--label=dcf.fuse.cap=off}",
    "${localEnv:DCF_HOST_FUSE_SECURITY:--label=dcf.fuse.security=off}"
  ]
}
'@
        function Get-FuseWorkspace {
            param([string]$Json)
            $ws = Join-Path $TestDrive ('fws-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $ws '.devcontainer') -Force | Out-Null
            if ($Json) { [System.IO.File]::WriteAllText((Join-Path $ws '.devcontainer/devcontainer.json'), $Json) }
            $ws
        }
        function Invoke-FuseRecorded {
            param([string]$Json = $script:Slots)
            $ws = Get-FuseWorkspace $Json
            Remove-Item $script:FuseRec, "$($script:FuseRec).env" -ErrorAction SilentlyContinue
            Invoke-DevcontainerCliProcess -Subcommand up -WorkspaceFolder $ws 6>$null 3>$null
            [pscustomobject]@{
                Args = @(Get-Content $script:FuseRec | ForEach-Object { $_.Replace($ws, 'WS') })
                Env = @(Get-Content "$($script:FuseRec).env" -ErrorAction SilentlyContinue)
            }
        }
    }
    BeforeEach {
        foreach ($n in $script:FuseEnvNames) { [Environment]::SetEnvironmentVariable($n, $null) }
        $env:PATH = $script:FuseBin + [System.IO.Path]::PathSeparator + $script:FuseSavedPath
        $env:HOME = Join-Path $TestDrive 'fuse-home'
        $env:HOST_TYPE = 'linux'
        Clear-HostProfileCache
    }
    AfterAll {
        foreach ($n in $script:FuseEnvNames) { [Environment]::SetEnvironmentVariable($n, $script:FuseSavedEnv[$n]) }
        $env:PATH = $script:FuseSavedPath
    }

    It 'Test-FuseRequested accepts <Value>: <Expected>' -ForEach @(
        @{ Value = '1'; Expected = $true }, @{ Value = 'true'; Expected = $true }, @{ Value = 'Yes'; Expected = $true }, @{ Value = 'on'; Expected = $true }
        @{ Value = ''; Expected = $false }, @{ Value = '0'; Expected = $false }, @{ Value = 'yes-please'; Expected = $false }
    ) {
        $env:DCF_HOST_FUSE = $Value
        Test-FuseRequested | Should -Be $Expected
    }

    It 'Get-FuseRunArgument: the three grant arguments, or none' {
        $g = Get-FuseRunArgument -Requested $true
        @($g.Keys) | Should -Be @('DCF_HOST_FUSE_DEVICE', 'DCF_HOST_FUSE_CAP', 'DCF_HOST_FUSE_SECURITY')
        @($g.Values) | Should -Be @('--device=/dev/fuse', '--cap-add=SYS_ADMIN', '--security-opt=apparmor=unconfined')
        (Get-FuseRunArgument -Requested $false).Count | Should -Be 0
    }

    It 'no request: DCF_HOST_FUSE empty and no grant variables, even when the environment had some' {
        $env:DCF_HOST_FUSE_DEVICE = '--privileged'
        $r = Invoke-FuseRecorded
        @($r.Env | Where-Object { $_ -like 'DCF_HOST_FUSE_*' }) | Should -HaveCount 0
        @($r.Env | Where-Object { $_ -like 'DCF_HOST_FUSE=?*' }) | Should -HaveCount 0
    }

    It 'DCF_HOST_FUSE=1: the CLI sees the three grant variables, and its argument list is unchanged' {
        $without = (Invoke-FuseRecorded).Args
        $env:DCF_HOST_FUSE = '1'
        Clear-HostProfileCache
        $r = Invoke-FuseRecorded
        $r.Env | Should -Be @('DCF_HOST_FUSE=1', 'DCF_HOST_FUSE_CAP=--cap-add=SYS_ADMIN', 'DCF_HOST_FUSE_DEVICE=--device=/dev/fuse', 'DCF_HOST_FUSE_SECURITY=--security-opt=apparmor=unconfined')
        $r.Args | Should -Be $without
        $r.Args | Should -Not -Contain '--privileged'
    }

    It 'Get-FuseSlotMissing: none for the slots and the bootstrap template, all three for a plain file, a commented line counts as missing' {
        @(Get-FuseSlotMissing -WorkspaceFolder (Get-FuseWorkspace $script:Slots)) | Should -HaveCount 0
        $tpl = Get-FuseWorkspace ''
        Copy-Item (Join-Path $PSScriptRoot '../../bootstrap/devcontainer.json') (Join-Path $tpl '.devcontainer/devcontainer.json')
        @(Get-FuseSlotMissing -WorkspaceFolder $tpl) | Should -HaveCount 0
        @(Get-FuseSlotMissing -WorkspaceFolder (Get-FuseWorkspace '{ "name": "plain" }')) | Should -Be @('DCF_HOST_FUSE_DEVICE', 'DCF_HOST_FUSE_CAP', 'DCF_HOST_FUSE_SECURITY')
        $commented = "{`n  // `"`${localEnv:DCF_HOST_FUSE_DEVICE:--label=a}`"`n  `"runArgs`": [`"`${localEnv:DCF_HOST_FUSE_CAP:--label=b}`", `"`${localEnv:DCF_HOST_FUSE_SECURITY:--label=c}`"]`n}"
        @(Get-FuseSlotMissing -WorkspaceFolder (Get-FuseWorkspace $commented)) | Should -Be @('DCF_HOST_FUSE_DEVICE')
        @(Get-FuseSlotMissing -WorkspaceFolder (Get-FuseWorkspace '')) | Should -HaveCount 0
    }

    It 'warns when FUSE is asked for and the runArgs lines are missing, never otherwise' {
        $env:DCF_HOST_FUSE = '1'
        $w = Write-FuseSlotWarning -WorkspaceFolder (Get-FuseWorkspace '{ }') 3>&1
        "$w" | Should -Match 'has no runArgs reading DCF_HOST_FUSE_DEVICE DCF_HOST_FUSE_CAP DCF_HOST_FUSE_SECURITY'
        @(Write-FuseSlotWarning -WorkspaceFolder (Get-FuseWorkspace $script:Slots) 3>&1) | Should -HaveCount 0
        $env:DCF_HOST_FUSE = $null
        @(Write-FuseSlotWarning -WorkspaceFolder (Get-FuseWorkspace '{ }') 3>&1) | Should -HaveCount 0
    }

    It 'host prints the grant, or that there is none' {
        $env:DCF_HOST_FUSE = '1'
        $text = (Show-HostProfile -WorkspaceFolder (Get-FuseWorkspace $script:Slots) 6>&1 3>$null | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -Match 'DCF_HOST_FUSE      : 1 \(runArgs get: --device=/dev/fuse --cap-add=SYS_ADMIN --security-opt=apparmor=unconfined\)'
        $env:DCF_HOST_FUSE = $null
        Clear-HostProfileCache
        $text = (Show-HostProfile -WorkspaceFolder (Get-FuseWorkspace $script:Slots) 6>&1 3>$null | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -Match 'DCF_HOST_FUSE      : \(unset: no FUSE grant\)'
    }
}

# ssh-key-import (task devcontainer:ssh-key-import): the key file reaches `devcontainer exec` on stdin and
# never in its arguments. A stub `devcontainer` records each call's arguments and stdin; a stub `docker`
# answers `ps -q` (the Windows branch runs the portable node.exe instead, so these run on Linux/macOS).
Describe 'ssh-key-import' -Skip:$IsWindows {
    BeforeAll {
        $script:EnvNames = 'HOST_TYPE', 'DEVCONTAINER_DOCKER_PATH', 'HOME', 'DCF_TEST_RUNNING', 'DCF_TEST_REFUSE', 'DCF_TEST_CALLS'
        $script:SavedEnv = @{}
        foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
        $script:SavedPath = $env:PATH
        $script:Bin = Join-Path $TestDrive 'bin'
        $script:Calls = Join-Path $TestDrive 'calls'
        New-Item -ItemType Directory -Path $script:Bin, $script:Calls | Out-Null
        $stub = @'
#!/bin/sh
n=$(ls "$DCF_TEST_CALLS" | grep -c args)
for a in "$@"; do echo "$a"; done > "$DCF_TEST_CALLS/$n.args"
# Only key-stdin reads its input; other calls (key-load) get none, and reading would hang
# wherever the input is a terminal instead of closed (as in CI).
case "$*" in *key-stdin*) cat > "$DCF_TEST_CALLS/$n.stdin" ;; *) : > "$DCF_TEST_CALLS/$n.stdin" ;; esac
case "$*" in *key-stdin*) if [ "$DCF_TEST_REFUSE" = 1 ]; then echo "ssh-agent: key mode is off in this container" >&2; exit 1; fi ;; esac
exit 0
'@
        [System.IO.File]::WriteAllText((Join-Path $script:Bin 'devcontainer'), $stub.Replace("`r`n", "`n"))
        [System.IO.File]::WriteAllText((Join-Path $script:Bin 'docker'), "#!/bin/sh`n[ `"`$1`" = ps ] && [ `"`$DCF_TEST_RUNNING`" = 1 ] && echo abc123`nexit 0`n")
        chmod +x (Join-Path $script:Bin 'devcontainer') (Join-Path $script:Bin 'docker')
        $script:Secret = 'SECRET-KEY-BYTES-0123456789'
        # The marker lines are built, so no private-key-looking block sits in the repository (the secrets guard).
        $script:Begin = '-----BEGIN OPENSSH ' + 'PRIVATE KEY-----'
        $script:End = '-----END OPENSSH ' + 'PRIVATE KEY-----'
        $script:Key = Join-Path $TestDrive 'id_test'
        [System.IO.File]::WriteAllText($script:Key, "$($script:Begin)`n$($script:Secret)`n$($script:End)`n")
        [System.IO.File]::WriteAllText("$($script:Key).pub", "ssh-ed25519 AAAAPUBLIC test`n")
        $script:NoPub = Join-Path $TestDrive 'id_nopub'
        [System.IO.File]::WriteAllText($script:NoPub, "$($script:Begin)`n$($script:Secret)`n$($script:End)`n")
        $script:Ws = Join-Path $TestDrive 'ws'
        New-Item -ItemType Directory -Path $script:Ws | Out-Null
        function Get-CallCount { @(Get-ChildItem $script:Calls -Filter '*.args').Count }
    }
    BeforeEach {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $null) }
        $env:PATH = $script:Bin + [System.IO.Path]::PathSeparator + $script:SavedPath
        $env:HOME = Join-Path $TestDrive 'home'
        $env:HOST_TYPE = 'linux'
        $env:DCF_TEST_CALLS = $script:Calls
        Get-ChildItem $script:Calls | Remove-Item
        Clear-HostProfileCache
    }
    AfterAll {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) }
        $env:PATH = $script:SavedPath
    }

    It 'streams the key and its .pub through stdin, never in an argument, and loads the keys last' {
        $env:DCF_TEST_RUNNING = '1'
        Import-SshKey -WorkspaceFolder $script:Ws -KeyFile $script:Key 6>$null
        Get-CallCount | Should -Be 3
        (Get-Content (Join-Path $script:Calls '0.args')) -join ' ' | Should -Match 'ssh-agent-setup key-stdin id_test$'
        (Get-Content (Join-Path $script:Calls '0.stdin') -Raw) | Should -Match ([regex]::Escape($script:Secret))
        (Get-Content (Join-Path $script:Calls '1.args')) -join ' ' | Should -Match 'ssh-agent-setup key-stdin id_test\.pub$'
        (Get-Content (Join-Path $script:Calls '1.stdin') -Raw) | Should -Match 'AAAAPUBLIC'
        (Get-Content (Join-Path $script:Calls '2.args')) -join ' ' | Should -Match 'ssh-agent-setup key-load$'
        foreach ($f in Get-ChildItem $script:Calls -Filter '*.args') { (Get-Content $f.FullName -Raw) | Should -Not -Match ([regex]::Escape($script:Secret)) }
    }

    It 'a key with no .pub beside it makes two calls' {
        $env:DCF_TEST_RUNNING = '1'
        Import-SshKey -WorkspaceFolder $script:Ws -KeyFile $script:NoPub 6>$null
        Get-CallCount | Should -Be 2
    }

    It 'refuses a missing file, naming FILE, and starts nothing' {
        $env:DCF_TEST_RUNNING = '1'
        { Import-SshKey -WorkspaceFolder $script:Ws -KeyFile (Join-Path $TestDrive 'missing') 6>$null } | Should -Throw '*FILE=<path of a private key on this host>*'
        { Import-SshKey -WorkspaceFolder $script:Ws -KeyFile '' 6>$null } | Should -Throw '*FILE=*'
        Get-CallCount | Should -Be 0
    }

    It 'refuses when no container runs, says how to start it, and starts nothing' {
        { Import-SshKey -WorkspaceFolder $script:Ws -KeyFile $script:Key 6>$null } | Should -Throw '*task dc:start*'
        Get-CallCount | Should -Be 0
    }

    It 'a container that refuses (key mode off) fails the import and nothing else runs' {
        $env:DCF_TEST_RUNNING = '1'
        $env:DCF_TEST_REFUSE = '1'
        { Import-SshKey -WorkspaceFolder $script:Ws -KeyFile $script:Key 6>$null 2>$null } | Should -Throw '*keyMode: true*'
        Get-CallCount | Should -Be 1
    }
    Context 'host-side warnings (a default name, a key that also opens something on this host)' {
        BeforeEach {
            $env:DCF_TEST_RUNNING = '1'
            $script:Ssh = Join-Path $env:HOME '.ssh'
            if (Test-Path $script:Ssh) { Remove-Item $script:Ssh -Recurse -Force }
            New-Item -ItemType Directory -Path $script:Ssh | Out-Null
        }

        It 'a dedicated name with an unrelated key gives no warning' {
            $w = Import-SshKey -WorkspaceFolder $script:Ws -KeyFile $script:Key 3>&1 6>$null | Out-String
            $w | Should -Not -Match 'warning'
        }

        It 'a default file name is warned about and still imports' {
            $dflt = Join-Path $TestDrive 'id_ed25519'
            Copy-Item $script:NoPub $dflt
            $w = Import-SshKey -WorkspaceFolder $script:Ws -KeyFile $dflt 3>&1 6>$null | Out-String
            $w | Should -Match 'id_ed25519 is the default name of a general-purpose key'
            Get-CallCount | Should -Be 2
        }

        It 'a public key in authorized_keys or another ~/.ssh/*.pub is warned about, by fingerprint, never printing the key' -Skip:(-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
            $gen = Join-Path $TestDrive 'gen'
            Remove-Item "$gen*" -ErrorAction SilentlyContinue
            ssh-keygen -q -t ed25519 -N '' -C host-key -f $gen | Out-Null
            $blob = ((Get-Content "$gen.pub" -Raw) -split '\s+')[1]
            $body = (Get-Content $gen)[1]
            $fp = ((ssh-keygen -l -f "$gen.pub") -split '\s+')[1]
            Set-Content (Join-Path $script:Ssh 'authorized_keys') "no-pty $(Get-Content "$gen.pub" -Raw)"
            $w = Import-SshKey -WorkspaceFolder $script:Ws -KeyFile $gen 3>&1 6>$null | Out-String
            $w | Should -Match 'appears in ~/.ssh/authorized_keys'
            $w | Should -Match ([regex]::Escape($fp))
            $w | Should -Not -Match ([regex]::Escape($blob))
            $w | Should -Not -Match ([regex]::Escape($body))
            Remove-Item (Join-Path $script:Ssh 'authorized_keys')
            Copy-Item "$gen.pub" (Join-Path $script:Ssh 'id_work.pub')
            $w = Import-SshKey -WorkspaceFolder $script:Ws -KeyFile $gen 3>&1 6>$null | Out-String
            $w | Should -Match 'is the same key as ~/.ssh/id_work.pub'
            Remove-Item (Join-Path $script:Ssh 'id_work.pub')
            $w = Import-SshKey -WorkspaceFolder $script:Ws -KeyFile $gen 3>&1 6>$null | Out-String
            $w | Should -Not -Match 'warning'
        }
    }
}

Describe 'Host bootstrap downloads retry a dropped connection' {
    # Windows PowerShell 5.1 has no -MaximumRetryCount; the host scripts require PowerShell 7.
    It 'every Invoke-WebRequest in <_> sets -MaximumRetryCount and -RetryIntervalSec' -ForEach @('bootstrap/bootstrap.ps1', 'bootstrap/host/DevcontainerCli.psm1') {
        $file = Join-Path $PSScriptRoot "../../$_"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WebRequest' }, $true)
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) {
            $names = $c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName
            $names | Should -Contain 'MaximumRetryCount'
            $names | Should -Contain 'RetryIntervalSec'
        }
    }
}
