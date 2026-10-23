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
        $script:EnvNames = 'HOST_TYPE', 'HOST_TYPE_PRIORITY', 'DEVCONTAINER_DOCKER_PATH', 'DCF_HOST_TYPE', 'DCF_HOST_HOME', 'DCF_HOST_SSH_AGENT', 'USERPROFILE', 'HOME'
        $script:SavedEnv = @{}
        foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
        function Initialize-Evidence {
            param([string]$Os, [bool]$Docker = $false, [bool]$WslDocker = $false, [string]$Wslc = '')
            $script:ev = @{ Os = $Os; Docker = $Docker; WslDocker = $WslDocker; Wslc = $Wslc }
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
        @{ Os = 'windows'; Id = 'windows-docker'; HostHome = 'C:\Users\test'; Docker = $true }
        @{ Os = 'windows'; Id = 'windows-wslc'; HostHome = 'C:\Users\test'; Docker = $false }
        @{ Os = 'windows'; Id = 'windows-wsl-docker'; HostHome = '/home/wsluser'; Docker = $true }
        @{ Os = 'wsl'; Id = 'windows-wsl-docker'; HostHome = '/home/test'; Docker = $true }
        @{ Os = 'linux'; Id = 'linux'; HostHome = '/home/test'; Docker = $true }
        @{ Os = 'macos'; Id = 'macos'; HostHome = '/home/test'; Docker = $true }
    ) {
        Initialize-Evidence -Os $Os -Docker $Docker -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = $Id
        $p = Initialize-HostEnvironment
        $env:DCF_HOST_TYPE | Should -Be $Id
        $env:DCF_HOST_HOME | Should -Be $HostHome
        $env:DCF_HOST_SSH_AGENT | Should -Be 'none'
        $p.Type | Should -Be $Id
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
