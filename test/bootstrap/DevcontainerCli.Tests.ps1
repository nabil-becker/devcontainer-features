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
        # The lock on whatever engine runs the tests (=1 skips the BuildKit probe), its files in a temp folder.
        $script:oldLockSetting = $env:DEVCONTAINER_BUILD_LOCK
        $env:DEVCONTAINER_BUILD_LOCK = '1'
        $script:state = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N'))"
        $PSDefaultParameterValues['Enter-DevcontainerBuildLock:StateDir'] = $script:state
    }
    AfterEach {
        Remove-Item $script:flag -ErrorAction SilentlyContinue
        $env:DEVCONTAINER_BUILD_LOCK = $script:oldLockSetting
        $PSDefaultParameterValues.Remove('Enter-DevcontainerBuildLock:StateDir')
    }

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

Describe 'The build lock holder and waiter files' {
    BeforeEach {
        $script:name = "Global\devcontainer-features-test-$([guid]::NewGuid().ToString('N'))"
        $script:flag = Join-Path ([IO.Path]::GetTempPath()) "dcf-lock-$([guid]::NewGuid().ToString('N'))"
        $script:oldLockSetting = $env:DEVCONTAINER_BUILD_LOCK
        $env:DEVCONTAINER_BUILD_LOCK = '1'
        $script:state = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:state | Out-Null
        $script:children = [System.Collections.Generic.List[object]]::new()
        # Starts a process that just sleeps and returns it: a live pid for a holder or waiter file.
        function Get-Sleeper {
            $psi = [System.Diagnostics.ProcessStartInfo]::new($script:PwshExe)
            foreach ($a in @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 60')) { $psi.ArgumentList.Add($a) }
            $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $script:children.Add($p)
            $p
        }
        # The pid of a process that has ended: a stale file.
        function Get-DeadPid {
            $psi = [System.Diagnostics.ProcessStartInfo]::new($script:PwshExe)
            foreach ($a in @('-NoLogo', '-NoProfile', '-Command', 'exit 0')) { $psi.ArgumentList.Add($a) }
            $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.WaitForExit(30000) | Out-Null
            $p.Id
        }
        function Add-TestLockFile {
            param([string]$Leaf, [hashtable]$Content)
            Set-Content -LiteralPath (Join-Path $script:state $Leaf) -Value ($Content | ConvertTo-Json -Compress)
        }
    }
    AfterEach {
        foreach ($c in $script:children) { if (-not $c.HasExited) { $c.Kill() } }
        Remove-Item $script:flag -ErrorAction SilentlyContinue
        $env:DEVCONTAINER_BUILD_LOCK = $script:oldLockSetting
    }

    It 'the holder writes its repository, subcommand with flags, pid and start, and removes the file on exit' {
        $ws = Join-Path $TestDrive 'alpha'
        New-Item -ItemType Directory -Path $ws -Force | Out-Null
        $lock = Enter-DevcontainerBuildLock -Name $script:name -StateDir $script:state -WorkspaceFolder $ws `
            -Subcommand up -Arguments @('--remove-existing-container', '--build-no-cache', '--config', 'x.json')
        $file = Join-Path $script:state 'holder.json'
        try {
            $h = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            $h.repo | Should -Be 'alpha'
            $h.subcommand | Should -Be 'up --remove-existing-container --build-no-cache --config'
            $h.pid | Should -Be $PID
            ([datetimeoffset]::Parse($h.started)).UtcDateTime | Should -BeGreaterThan ([datetime]::UtcNow.AddMinutes(-1))
        }
        finally { Exit-DevcontainerBuildLock -Lock $lock }
        Test-Path -LiteralPath $file | Should -BeFalse
    }

    It 'the waiting line names the holder, its start and every other waiter, earlier or later' {
        $holder = Get-Sleeper
        $earlier = Get-Sleeper
        $later = Get-Sleeper
        $start = [datetime]::UtcNow.AddMinutes(-5)
        Add-TestLockFile 'holder.json' @{ pid = $holder.Id; repo = 'alpha'; subcommand = 'up --build-no-cache'; started = $start.ToString('o') }
        Add-TestLockFile "waiter-$($earlier.Id).json" @{ pid = $earlier.Id; started = [datetime]::UtcNow.AddMinutes(-2).ToString('o') }
        Add-TestLockFile "waiter-$($later.Id).json" @{ pid = $later.Id; started = [datetime]::UtcNow.AddMinutes(2).ToString('o') }
        $at = $start.ToLocalTime().ToString('HH:mm')
        Get-BuildLockWaitMessage -StateDir $script:state -Self $PID |
            Should -Be "waiting for alpha's up --build-no-cache (started $at, 2 waiting)..."
    }

    It 'no count when no other waiter' {
        $holder = Get-Sleeper
        $start = [datetime]::UtcNow
        Add-TestLockFile 'holder.json' @{ pid = $holder.Id; repo = 'alpha'; subcommand = 'build'; started = $start.ToString('o') }
        Get-BuildLockWaitMessage -StateDir $script:state -Self $PID |
            Should -Be "waiting for alpha's build (started $($start.ToLocalTime().ToString('HH:mm')))..."
    }

    It 'ignores a stale holder file and stale waiter files (their process is gone)' {
        $dead = Get-DeadPid
        Add-TestLockFile 'holder.json' @{ pid = $dead; repo = 'gone'; subcommand = 'up'; started = [datetime]::UtcNow.ToString('o') }
        Add-TestLockFile "waiter-$dead.json" @{ pid = $dead; started = [datetime]::UtcNow.AddMinutes(-2).ToString('o') }
        Get-BuildLockWaitMessage -StateDir $script:state -Self $PID |
            Should -Be 'waiting for another devcontainer build to finish...'
    }

    It 'falls back to the plain line with a count when there is no holder file' {
        $earlier = Get-Sleeper
        Add-TestLockFile "waiter-$($earlier.Id).json" @{ pid = $earlier.Id; started = [datetime]::UtcNow.AddMinutes(-2).ToString('o') }
        Get-BuildLockWaitMessage -StateDir $script:state -Self $PID |
            Should -Be 'waiting for another devcontainer build to finish (1 waiting)...'
    }

    It 'a waiter registers while it waits, says the line again when the holder changes, and leaves no waiter file' {
        $holderFile = Join-Path $script:state 'holder.json'
        $now = [datetime]::UtcNow.ToString('o')
        # The child holds the mutex as alpha, hands the holder file to beta (a sleeper) after 2 s, releases after 4 s.
        $beta = Get-Sleeper
        $json1 = (@{ pid = 0; repo = 'alpha'; subcommand = 'up --build-no-cache'; started = $now } | ConvertTo-Json -Compress)
        $json2 = (@{ pid = $beta.Id; repo = 'beta'; subcommand = 'build'; started = $now } | ConvertTo-Json -Compress)
        $body = "`$j = '$json1' -replace '`"pid`":0', ('`"pid`":' + `$PID); Set-Content -LiteralPath '$holderFile' -Value `$j; " +
            "New-Item '$($script:flag)' | Out-Null; Start-Sleep -Seconds 2; Set-Content -LiteralPath '$holderFile' -Value '$json2'; " +
            "Start-Sleep -Seconds 2; `$mutex.ReleaseMutex()"
        $holder = Invoke-LockHolder -Name $script:name -Body $body
        $script:children.Add($holder)
        Wait-ForFile $script:flag | Should -BeTrue
        $waiterFile = Join-Path $script:state "waiter-$PID.json"
        $job = Start-ThreadJob -ScriptBlock {
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            while ([datetime]::UtcNow -lt $deadline) { if (Test-Path -LiteralPath $using:waiterFile) { return $true }; Start-Sleep -Milliseconds 50 }
            $false
        }
        $out = Enter-DevcontainerBuildLock -Name $script:name -StateDir $script:state -WorkspaceFolder $TestDrive -Subcommand up 6>&1
        $seen = Receive-Job $job -Wait -AutoRemoveJob
        $lock = $out | Where-Object { $_ -is [System.Threading.Mutex] }
        try {
            $lock | Should -Not -BeNullOrEmpty
            $lines = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { $_.MessageData.Message })
            $lines.Count | Should -Be 2
            $lines[0] | Should -Match "^waiting for alpha's up --build-no-cache \(started \d\d:\d\d\)\.\.\.$"
            $lines[1] | Should -Match "^waiting for beta's build \(started \d\d:\d\d\)\.\.\.$"
            $seen | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:state "waiter-$PID.json") | Should -BeFalse
            (Get-Content -LiteralPath $holderFile -Raw | ConvertFrom-Json).pid | Should -Be $PID
        }
        finally { Exit-DevcontainerBuildLock -Lock $lock }
    }
}

Describe 'The build lock skipped with BuildKit build contexts' {
    BeforeEach {
        $script:oldLockSetting = $env:DEVCONTAINER_BUILD_LOCK
        $env:DEVCONTAINER_BUILD_LOCK = $null
        $script:name = "Global\devcontainer-features-test-$([guid]::NewGuid().ToString('N'))"
        $script:state = Join-Path $TestDrive "state-$([guid]::NewGuid().ToString('N'))"
        Mock -ModuleName DevcontainerCli Resolve-DockerPath { $null }
    }
    AfterEach { $env:DEVCONTAINER_BUILD_LOCK = $script:oldLockSetting }

    It 'docker with buildx <v> skips the lock' -ForEach @(
        @{ v = '0.35.0' }
        @{ v = '0.8.0' }
        @{ v = '1.0.0' }
    ) {
        Mock -ModuleName DevcontainerCli Get-EngineBuildxVersion { $v }.GetNewClosure()
        Get-BuildLockSkipReason | Should -Be "docker builds with BuildKit build contexts (buildx $v), so builds of different repositories cannot collide"
    }

    It 'keeps the lock when buildx is older than 0.8.0 or cannot be asked (<v>)' -ForEach @(
        @{ v = '0.7.1' }
        @{ v = $null }
    ) {
        Mock -ModuleName DevcontainerCli Get-EngineBuildxVersion { $v }.GetNewClosure()
        Get-BuildLockSkipReason | Should -BeNullOrEmpty
    }

    It 'keeps the lock for wslc (<path>) without asking it' -ForEach @(
        @{ path = 'C:\Program Files\WSL\wslc.exe' }
        @{ path = '/usr/bin/wslc' }
    ) {
        Mock -ModuleName DevcontainerCli Resolve-DockerPath { $path }.GetNewClosure()
        Mock -ModuleName DevcontainerCli Get-EngineBuildxVersion { '0.35.0' }
        Get-BuildLockSkipReason | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DevcontainerCli Get-EngineBuildxVersion -Times 0 -Exactly
    }

    It 'keeps the lock when the engine cannot be resolved' {
        Mock -ModuleName DevcontainerCli Resolve-DockerPath { throw 'no engine' }
        Get-BuildLockSkipReason | Should -BeNullOrEmpty
    }

    It 'Enter-DevcontainerBuildLock skips a held lock at once with one line' {
        Mock -ModuleName DevcontainerCli Get-EngineBuildxVersion { '0.35.0' }
        $held = [System.Threading.Mutex]::new($true, $script:name)
        try {
            $out = @(Enter-DevcontainerBuildLock -Name $script:name -StateDir $script:state 6>&1)
            @($out | Where-Object { $_ -is [System.Threading.Mutex] }).Count | Should -Be 0
            $out = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] })
            $out.Count | Should -Be 1
            $out[0].MessageData.Message | Should -Be 'build lock skipped: docker builds with BuildKit build contexts (buildx 0.35.0), so builds of different repositories cannot collide (DEVCONTAINER_BUILD_LOCK=1 keeps it).'
        }
        finally { $held.ReleaseMutex(); $held.Dispose() }
    }

    It 'DEVCONTAINER_BUILD_LOCK=1 keeps the lock without asking the engine' {
        Mock -ModuleName DevcontainerCli Get-EngineBuildxVersion { '0.35.0' }
        $env:DEVCONTAINER_BUILD_LOCK = '1'
        $lock = Enter-DevcontainerBuildLock -Name $script:name -StateDir $script:state
        try { $lock | Should -BeOfType ([System.Threading.Mutex]) }
        finally { Exit-DevcontainerBuildLock -Lock $lock }
        Should -Invoke -ModuleName DevcontainerCli Get-EngineBuildxVersion -Times 0 -Exactly
    }

    It 'DEVCONTAINER_BUILD_LOCK=0 takes no lock and says nothing' {
        Mock -ModuleName DevcontainerCli Get-EngineBuildxVersion { '0.35.0' }
        $env:DEVCONTAINER_BUILD_LOCK = '0'
        @(Enter-DevcontainerBuildLock -Name $script:name -StateDir $script:state 6>&1 | Where-Object { $_ }).Count | Should -Be 0
        Should -Invoke -ModuleName DevcontainerCli Get-EngineBuildxVersion -Times 0 -Exactly
    }

    It 'Get-EngineBuildxVersion reads the version a buildx prints, $null when it fails' -Skip:$IsWindows {
        $ok = Join-Path $TestDrive 'engine-ok'
        Set-Content -LiteralPath $ok -Value "#!/bin/sh`necho 'github.com/docker/buildx v0.35.0 0123abc'"
        $bad = Join-Path $TestDrive 'engine-bad'
        Set-Content -LiteralPath $bad -Value "#!/bin/sh`necho 'unknown command: buildx' >&2`nexit 1"
        chmod +x $ok $bad
        Get-EngineBuildxVersion -Exe $ok | Should -Be '0.35.0'
        Get-EngineBuildxVersion -Exe $bad | Should -BeNullOrEmpty
        Get-EngineBuildxVersion -Exe (Join-Path $TestDrive 'no-such-engine') | Should -BeNullOrEmpty
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
        # The engine wait has its own Describe below; here the engine always answers.
        Mock -ModuleName DevcontainerCli Wait-ContainerEngine { }
        Mock -ModuleName DevcontainerCli Write-ContainerEngineDiagnosis { }
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

    It 'hands the lock the workspace, the subcommand, its arguments and the engine' {
        Invoke-DevcontainerCli -Subcommand up -WorkspaceFolder $TestDrive -Arguments @('--build-no-cache') -DockerPath 'docker'
        Should -Invoke -ModuleName DevcontainerCli Enter-DevcontainerBuildLock -Times 1 -Exactly -ParameterFilter {
            $WorkspaceFolder -eq $TestDrive -and $Subcommand -eq 'up' -and $Arguments -contains '--build-no-cache' -and $DockerPath -eq 'docker'
        }
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

Describe 'The container engine wait (DEVCONTAINER_ENGINE_WAIT)' {
    # Right after a rebuild the engine may not answer for a moment, and `devcontainer up`
    # then fails inside with "Command failed: docker ps ..." and docker's stderr hidden.
    BeforeAll {
        $script:EnvNames = 'DEVCONTAINER_ENGINE_WAIT', 'DEVCONTAINER_DOCKER_PATH', 'HOST_TYPE'
        $script:SavedEnv = @{}
        foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
    }
    BeforeEach {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $null) }
        Clear-HostProfileCache
        $script:answers = @()
        $script:checks = 0
        # The engine answers when the next entry of $script:answers says so (the last one repeats).
        Mock -ModuleName DevcontainerCli Test-ContainerEngineResponding {
            $i = [Math]::Min($script:checks, $script:answers.Count - 1)
            $script:checks++
            [bool]$script:answers[$i]
        }
        Mock -ModuleName DevcontainerCli Start-Sleep { }
        Mock -ModuleName DevcontainerCli Resolve-DockerPath { $null }
        Mock -ModuleName DevcontainerCli Get-CachedHostType { @{ Type = 'windows-docker'; Why = 'test'; Priority = @('windows-docker') } }
    }
    AfterAll { foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) } }

    It 'a healthy engine costs one check: no sleep, no waiting line' {
        $script:answers = @($true)
        $out = Wait-ContainerEngine 6>&1
        $script:checks | Should -Be 1
        Should -Invoke -ModuleName DevcontainerCli Start-Sleep -Times 0 -Exactly
        @($out | Where-Object { "$_" -match 'waiting' }).Count | Should -Be 0
    }

    It 'an engine that answers on the third check: one waiting line, two pauses of a second' {
        $script:answers = @($false, $false, $true)
        $out = Wait-ContainerEngine 6>&1
        $script:checks | Should -Be 3
        Should -Invoke -ModuleName DevcontainerCli Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 1 }
        @($out | Where-Object { "$_" -match 'waiting for the container engine to answer\.\.\.' }).Count | Should -Be 1
    }

    It 'gives up after DEVCONTAINER_ENGINE_WAIT seconds, naming the engine, how to start it and the setting' {
        $script:answers = @($false)
        $env:DEVCONTAINER_ENGINE_WAIT = '3'
        Mock -ModuleName DevcontainerCli Get-ContainerEngineError { 'Cannot connect to the Docker daemon' }
        { Wait-ContainerEngine 6>$null } | Should -Throw '*docker*did not answer within 3 s*Cannot connect to the Docker daemon*Docker Desktop*DEVCONTAINER_ENGINE_WAIT*'
        $script:checks | Should -Be 4
    }

    It 'DEVCONTAINER_ENGINE_WAIT=0 checks nothing' {
        $script:answers = @($false)
        $env:DEVCONTAINER_ENGINE_WAIT = '0'
        Wait-ContainerEngine
        $script:checks | Should -Be 0
    }

    It 'a DEVCONTAINER_ENGINE_WAIT that is not a whole number is refused, naming the setting' {
        $env:DEVCONTAINER_ENGINE_WAIT = 'soon'
        { Wait-ContainerEngine } | Should -Throw "*DEVCONTAINER_ENGINE_WAIT*'soon'*"
    }

    It 'how to start the engine, per host type: <type>' -ForEach @(
        @{ type = 'windows-docker'; hint = 'Docker Desktop' }
        @{ type = 'windows-wsl-docker'; hint = 'WSL distro' }
        @{ type = 'windows-wslc'; hint = 'wsl --status' }
        @{ type = 'linux'; hint = 'systemctl start docker' }
        @{ type = 'macos'; hint = 'Docker Desktop' }
    ) {
        Get-ContainerEngineStartHint -Type $type | Should -Match ([regex]::Escape($hint))
    }

    Context 'Invoke-DevcontainerCli' {
        BeforeEach {
            $script:order = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName DevcontainerCli Enter-DevcontainerBuildLock { $script:order.Add('lock'); [pscustomobject]@{ Held = $true } }
            Mock -ModuleName DevcontainerCli Exit-DevcontainerBuildLock { if ($Lock) { $script:order.Add('unlock') } }
            Mock -ModuleName DevcontainerCli Wait-ContainerEngine { $script:order.Add('wait') }
            Mock -ModuleName DevcontainerCli Invoke-DevcontainerCliProcess { $script:order.Add('cli'); & (Get-Module DevcontainerCli) { $script:CliExitCode = 0 } }
            Mock -ModuleName DevcontainerCli Write-ContainerEngineDiagnosis { $script:order.Add('diagnosis') }
        }

        It 'waits for the engine before <sub>' -ForEach @(
            @{ sub = 'up'; seq = 'lock,wait,cli,unlock' }
            @{ sub = 'build'; seq = 'lock,wait,cli,unlock' }
            @{ sub = 'exec'; seq = 'wait,cli' }
            @{ sub = 'set-up'; seq = 'wait,cli' }
            @{ sub = 'run-user-commands'; seq = 'wait,cli' }
        ) {
            Invoke-DevcontainerCli -Subcommand $sub -WorkspaceFolder $TestDrive
            ($script:order -join ',') | Should -Be $seq
        }

        It 'does not wait for <sub>, which needs no engine' -ForEach @(
            @{ sub = 'read-configuration' }
            @{ sub = 'features' }
            @{ sub = 'outdated' }
        ) {
            Invoke-DevcontainerCli -Subcommand $sub -WorkspaceFolder $TestDrive
            Should -Invoke -ModuleName DevcontainerCli Wait-ContainerEngine -Times 0 -Exactly
        }

        It 'an engine that never answers: the CLI is not run and the lock is released' {
            Mock -ModuleName DevcontainerCli Wait-ContainerEngine { throw 'the container engine (docker) did not answer' }
            { Invoke-DevcontainerCli -Subcommand up -WorkspaceFolder $TestDrive } | Should -Throw '*did not answer*'
            ($script:order -join ',') | Should -Be 'lock,unlock'
        }

        It 'a failed <sub> asks the engine once and still fails' -ForEach @(
            @{ sub = 'up' }
            @{ sub = 'build' }
        ) {
            Mock -ModuleName DevcontainerCli Invoke-DevcontainerCliProcess { $script:order.Add('cli'); & (Get-Module DevcontainerCli) { $script:CliExitCode = 1 } }
            { Invoke-DevcontainerCli -Subcommand $sub -WorkspaceFolder $TestDrive } | Should -Throw "*devcontainer $sub failed*"
            ($script:order -join ',') | Should -Be 'lock,wait,cli,unlock,diagnosis'
        }

        It 'a successful up asks nothing more' {
            Invoke-DevcontainerCli -Subcommand up -WorkspaceFolder $TestDrive
            Should -Invoke -ModuleName DevcontainerCli Write-ContainerEngineDiagnosis -Times 0 -Exactly
        }
    }
}

Describe 'The container engine check, with a stub engine' -Skip:$IsWindows {
    BeforeAll {
        # Runs $Body with [Console]::Error captured; returns what it wrote there.
        function Get-ConsoleError([scriptblock]$Body) {
            $saved = [Console]::Error
            $sw = [System.IO.StringWriter]::new()
            [Console]::SetError($sw)
            try { & $Body | Out-Null } finally { [Console]::SetError($saved) }
            $sw.ToString()
        }
        $script:Stub = Join-Path $TestDrive 'stub'
        New-Item -ItemType Directory -Path $script:Stub -Force | Out-Null
        $script:Calls = Join-Path $TestDrive 'engine-calls'
        # The stub records its arguments; STUB_DOWN=1 makes it fail as a stopped daemon does.
        $body = "#!/bin/sh`necho `"`$*`" >> '$($script:Calls)'`nif [ `"`$STUB_DOWN`" = 1 ]; then echo 'Client: ok'; echo 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock' >&2; exit 1; fi`necho 'Server: ok'`n"
        foreach ($n in 'docker', 'wslc') {
            [IO.File]::WriteAllText((Join-Path $script:Stub $n), $body)
            & chmod +x (Join-Path $script:Stub $n)
        }
    }
    BeforeEach {
        Remove-Item $script:Calls -ErrorAction SilentlyContinue
        $env:STUB_DOWN = $null
        Mock -ModuleName DevcontainerCli Get-CachedHostType { @{ Type = 'windows-docker'; Why = 'test'; Priority = @('windows-docker') } }
    }
    AfterAll { $env:STUB_DOWN = $null }

    It 'asks a docker engine `info` and a wslc engine `ps -q`' {
        Mock -ModuleName DevcontainerCli Resolve-DockerPath { Join-Path $script:Stub 'docker' }
        InModuleScope DevcontainerCli { Test-ContainerEngineResponding } | Should -BeTrue
        Mock -ModuleName DevcontainerCli Resolve-DockerPath { Join-Path $script:Stub 'wslc' }
        InModuleScope DevcontainerCli { Test-ContainerEngineResponding } | Should -BeTrue
        (Get-Content $script:Calls) -join '|' | Should -Be 'info|ps -q'
    }

    It 'a stopped engine does not answer, and its own error is what Get-ContainerEngineError returns' {
        $env:STUB_DOWN = '1'
        Mock -ModuleName DevcontainerCli Resolve-DockerPath { Join-Path $script:Stub 'docker' }
        InModuleScope DevcontainerCli { Test-ContainerEngineResponding } | Should -BeFalse
        $e = InModuleScope DevcontainerCli { Get-ContainerEngineError }
        $e | Should -Match 'Cannot connect to the Docker daemon'
        $e | Should -Not -Match 'Client: ok'
    }

    It 'after a failed up: the engine''s own error and how to start it, when it does not answer' {
        $env:STUB_DOWN = '1'
        Mock -ModuleName DevcontainerCli Resolve-DockerPath { Join-Path $script:Stub 'docker' }
        $err = Get-ConsoleError { Write-ContainerEngineDiagnosis }
        $err | Should -Match 'does not answer'
        $err | Should -Match 'Cannot connect to the Docker daemon'
        $err | Should -Match 'Docker Desktop'
    }

    It 'after a failed up: says the engine answers now, when it does' {
        Mock -ModuleName DevcontainerCli Resolve-DockerPath { Join-Path $script:Stub 'docker' }
        $err = Get-ConsoleError { Write-ContainerEngineDiagnosis }
        $err | Should -Match 'answers now'
        $err | Should -Match 'run the task again'
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
        $script:EnvNames = 'HOST_TYPE', 'HOST_TYPE_PRIORITY', 'DEVCONTAINER_DOCKER_PATH', 'DCF_HOST_TYPE', 'DCF_HOST_HOME', 'DCF_HOST_SSH_AGENT', 'SSH_AGENT_MODE', 'SSH_AUTH_SOCK', 'USERPROFILE', 'HOME', 'DCF_HOST_FUSE', 'DCF_HOST_FUSE_DEVICE', 'DCF_HOST_FUSE_CAP', 'DCF_HOST_FUSE_SECURITY'
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

    # The FUSE grant depends on the engine (ADR 0031; the bash twin's fuse_refusal): `wslc run` has
    # no --device, --cap-add or --security-opt option (WSL 3.0.3) and refuses the start when runArgs
    # carry one, so on windows-wslc the grant is withheld with a warning. These run on every OS; the
    # grant's variables on `up` are covered by 'FUSE on request' below, where sh runs.
    It 'Get-FuseRefusal: the windows-wslc host type or an engine named wslc, never another engine' {
        Get-FuseRefusal -Type 'windows-wslc' | Should -Match 'wslc run \(WSL Containers\) has no --device, --cap-add or --security-opt option'
        Get-FuseRefusal -Type 'windows-docker' -Engine 'C:\Program Files\WSL\wslc.exe' | Should -Match 'wslc run'
        Get-FuseRefusal -Type 'linux' -Engine 'wslc' | Should -Match 'wslc run'
        Get-FuseRefusal -Type 'windows-docker' | Should -BeNullOrEmpty
        Get-FuseRefusal -Type 'windows-docker' -Engine '' | Should -BeNullOrEmpty
        Get-FuseRefusal -Type 'windows-docker' -Engine 'C:\Program Files\Docker\Docker\resources\bin\docker.exe' | Should -BeNullOrEmpty
        Get-FuseRefusal -Type 'linux' -Engine '/usr/bin/podman' | Should -BeNullOrEmpty
        Get-FuseRefusal -Type 'macos' -Engine 'docker' | Should -BeNullOrEmpty
    }

    It 'DCF_HOST_FUSE=1 on windows-wslc: asked for, not granted, no grant variable for the CLI, one warning naming why' {
        Initialize-Evidence -Os windows -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = 'windows-wslc'
        $env:DCF_HOST_FUSE = '1'
        $env:DCF_HOST_FUSE_DEVICE = '--device=/dev/fuse'   # left in the environment by something else
        # As `up` does: the warnings first, then the environment for the CLI.
        $w = @(Write-FuseRefusedWarning 3>&1)
        $w | Should -HaveCount 1
        "$w" | Should -Match 'DCF_HOST_FUSE=1, but FUSE is not granted on this host \(windows-wslc\): wslc run'
        "$w" | Should -Match 'The container starts without it'
        # No runArgs lines in this workspace, but while the grant is refused the slot warning stays quiet.
        @(Write-FuseSlotWarning -WorkspaceFolder $TestDrive 3>&1) | Should -HaveCount 0
        $p = Initialize-HostEnvironment
        $p.FuseRequested | Should -BeTrue
        $p.Fuse | Should -BeFalse
        $p.FuseRefusal | Should -Match 'wslc run'
        $env:DCF_HOST_FUSE | Should -BeNullOrEmpty
        $env:DCF_HOST_FUSE_DEVICE | Should -BeNullOrEmpty
        $env:DCF_HOST_FUSE_CAP | Should -BeNullOrEmpty
        $env:DCF_HOST_FUSE_SECURITY | Should -BeNullOrEmpty
    }

    It 'DCF_HOST_FUSE=1 on windows-docker: granted as before, no refusal warning' {
        Initialize-Evidence -Os windows -Docker $true -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = 'windows-docker'
        $env:DCF_HOST_FUSE = '1'
        $p = Initialize-HostEnvironment
        $p.FuseRequested | Should -BeTrue
        $p.Fuse | Should -BeTrue
        $p.FuseRefusal | Should -BeNullOrEmpty
        $env:DCF_HOST_FUSE | Should -Be '1'
        $env:DCF_HOST_FUSE_DEVICE | Should -Be '--device=/dev/fuse'
        $env:DCF_HOST_FUSE_CAP | Should -Be '--cap-add=SYS_ADMIN'
        $env:DCF_HOST_FUSE_SECURITY | Should -Be '--security-opt=apparmor=unconfined'
        @(Write-FuseRefusedWarning 3>&1) | Should -HaveCount 0
    }

    It 'DCF_HOST_FUSE=1 with DEVCONTAINER_DOCKER_PATH naming wslc: refused on any host type' {
        Initialize-Evidence -Os windows -Docker $true -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = 'windows-docker'
        $env:DEVCONTAINER_DOCKER_PATH = 'wslc'
        $env:DCF_HOST_FUSE = '1'
        $p = Initialize-HostEnvironment
        $p.Fuse | Should -BeFalse
        $p.FuseRefusal | Should -Match 'wslc run'
        $env:DCF_HOST_FUSE_DEVICE | Should -BeNullOrEmpty
    }

    It 'no request on windows-wslc: nothing said about FUSE' {
        Initialize-Evidence -Os windows -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = 'windows-wslc'
        $p = Initialize-HostEnvironment
        $p.FuseRequested | Should -BeFalse
        $p.Fuse | Should -BeFalse
        @(Write-FuseRefusedWarning 3>&1) | Should -HaveCount 0
    }

    It 'host says the grant was asked for and why it is not given' {
        Initialize-Evidence -Os windows -Wslc 'C:\wslc.exe'
        $env:HOST_TYPE = 'windows-wslc'
        $env:DCF_HOST_FUSE = '1'
        $text = (Show-HostProfile -WorkspaceFolder $TestDrive 6>&1 3>$null | ForEach-Object { $_.MessageData.Message }) -join "`n"
        $text | Should -Match 'DCF_HOST_FUSE      : 1 asked for, not granted on windows-wslc: wslc run \(WSL Containers\) has no --device'
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
# The grant refused on a wslc engine is tested in 'Host type' above, where no sh is needed.
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

# Audio on request (the audio Feature), the counterpart of the audio part of
# test/bootstrap/host_mounts_test.sh: DCF_HOST_AUDIO=wslg on a WSL2-backed Windows host type runs
# the bind once (Invoke-WslgBind, mocked) and adds /mnt/wsl/wslg at /mnt/wslg; unset or none runs
# nothing and adds nothing; a host that cannot carry it warns once and passes none. The recorded
# `up` runs a stub devcontainer, so that part is skipped on Windows.
Describe 'Audio on request (DCF_HOST_AUDIO)' {
    BeforeAll {
        $script:AudioEnvNames = 'HOST_TYPE', 'HOST_TYPE_PRIORITY', 'HOST_MOUNTS', 'DEVCONTAINER_DOCKER_PATH', 'HOME', 'USERPROFILE', 'SSH_AUTH_SOCK', 'SSH_AGENT_MODE', 'DCF_HOST_TYPE', 'DCF_HOST_HOME', 'DCF_HOST_SSH_AGENT', 'DCF_HOST_CLOUD_FOLDER', 'DCF_HOST_FUSE', 'DCF_HOST_AUDIO'
        $script:AudioSavedEnv = @{}
        foreach ($n in $script:AudioEnvNames) { $script:AudioSavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
        $script:AudioSavedPath = $env:PATH
        $script:AudioMount = 'type=bind,source=/mnt/wsl/wslg,target=/mnt/wslg'
        function Initialize-AudioEvidence {
            param([string]$Os = 'windows', [string]$Bind = 'bound')
            $script:aev = @{ Os = $Os; Bind = $Bind }
            Mock -ModuleName DevcontainerCli Get-HostPlatform { $script:aev.Os }
            Mock -ModuleName DevcontainerCli Test-DockerResponding { $true }
            Mock -ModuleName DevcontainerCli Test-WslDockerResponding { $true }
            Mock -ModuleName DevcontainerCli Get-WslcPath { 'C:\wslc.exe' }
            Mock -ModuleName DevcontainerCli Get-WslHome { '/home/wsluser' }
            Mock -ModuleName DevcontainerCli Test-HostSocket { $false }
            Mock -ModuleName DevcontainerCli Get-Command { [pscustomobject]@{ Source = '/fake/docker' } } -ParameterFilter { $Name -eq 'docker' }
            Mock -ModuleName DevcontainerCli Initialize-HostMountSource { }
            Mock -ModuleName DevcontainerCli Invoke-WslgBind { $script:aev.Bind }
        }
        function Get-AudioWorkspace {
            param([string]$Json = '{ "name": "plain" }')
            $ws = Join-Path $TestDrive ('aws-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $ws '.devcontainer') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $ws '.devcontainer/devcontainer.json'), $Json)
            $ws
        }
    }
    BeforeEach {
        foreach ($n in $script:AudioEnvNames) { [Environment]::SetEnvironmentVariable($n, $null) }
        $env:USERPROFILE = 'C:\Users\test'
        $env:HOME = '/home/test'
        Clear-HostProfileCache
    }
    AfterAll {
        foreach ($n in $script:AudioEnvNames) { [Environment]::SetEnvironmentVariable($n, $script:AudioSavedEnv[$n]) }
        $env:PATH = $script:AudioSavedPath
    }

    It 'Get-AudioRequest reads <Value> as <Expected>' -ForEach @(
        @{ Value = ''; Expected = 'none' }, @{ Value = 'none'; Expected = 'none' }, @{ Value = ' NONE '; Expected = 'none' }
        @{ Value = 'wslg'; Expected = 'wslg' }, @{ Value = 'WSLg'; Expected = 'wslg' }, @{ Value = 'pulse'; Expected = 'unknown' }
    ) {
        $env:DCF_HOST_AUDIO = $Value
        Get-AudioRequest | Should -Be $Expected
    }

    It 'opt-out (<Value>): no bind, no mount, DCF_HOST_AUDIO=none, no warning' -ForEach @(@{ Value = '' }, @{ Value = 'none' }) {
        Initialize-AudioEvidence
        $env:HOST_TYPE = 'windows-docker'
        $env:DCF_HOST_AUDIO = $Value
        $w = $null
        Initialize-HostAudio -WarningVariable w -WarningAction SilentlyContinue | Should -Be 'none'
        $w | Should -HaveCount 0
        $a = @(Get-HostMountArgument -WorkspaceFolder (Get-AudioWorkspace) 6>$null)
        $a | Should -Not -Contain $script:AudioMount
        @($a | Where-Object { $_ -eq '--mount' }) | Should -HaveCount 1   # .git-dirs only, as before
        [void](Initialize-HostEnvironment)
        $env:DCF_HOST_AUDIO | Should -Be 'none'
        Should -Invoke -ModuleName DevcontainerCli Invoke-WslgBind -Times 0 -Exactly
    }

    It 'wslg on <Id> (<Os>), bind answering <Bind>: the mount and DCF_HOST_AUDIO=wslg, the bind run once' -ForEach @(
        @{ Os = 'windows'; Id = 'windows-docker'; Bind = 'bound' }
        @{ Os = 'windows'; Id = 'windows-docker'; Bind = 'present' }
        @{ Os = 'windows'; Id = 'windows-wsl-docker'; Bind = 'bound' }
        @{ Os = 'wsl'; Id = 'windows-wsl-docker'; Bind = 'present' }
    ) {
        Initialize-AudioEvidence -Os $Os -Bind $Bind
        $env:HOST_TYPE = $Id
        $env:DCF_HOST_AUDIO = 'wslg'
        Initialize-HostAudio 6>$null | Should -Be 'wslg'
        Initialize-HostAudio 6>$null | Should -Be 'wslg'
        $a = @(Get-HostMountArgument -WorkspaceFolder (Get-AudioWorkspace) 6>$null)
        $a | Should -Contain $script:AudioMount
        $a[[array]::IndexOf($a, $script:AudioMount) - 1] | Should -Be '--mount'
        [void](Initialize-HostEnvironment)
        $env:DCF_HOST_AUDIO | Should -Be 'wslg'
        Should -Invoke -ModuleName DevcontainerCli Invoke-WslgBind -Times 1 -Exactly
    }

    It 'wslg, bind answering <Bind>: one warning, no mount, none' -ForEach @(
        @{ Bind = 'nopulse'; Says = 'has no /mnt/wslg/PulseServer' }
        @{ Bind = 'nowsl'; Says = 'wsl.exe is not on PATH' }
        @{ Bind = 'error: exit 32: mount: permission denied'; Says = 'bind in the default WSL distro failed (error: exit 32' }
    ) {
        Initialize-AudioEvidence -Bind $Bind
        $env:HOST_TYPE = 'windows-docker'
        $env:DCF_HOST_AUDIO = 'wslg'
        $w = $null
        Initialize-HostAudio -WarningVariable w -WarningAction SilentlyContinue 6>$null | Should -Be 'none'
        $w | Should -HaveCount 1
        "$w" | Should -BeLike "*$Says*"
        "$w" | Should -BeLike '*starts without audio*'
        @(Get-HostMountArgument -WorkspaceFolder (Get-AudioWorkspace) 6>$null) | Should -Not -Contain $script:AudioMount
        [void](Initialize-HostEnvironment)
        $env:DCF_HOST_AUDIO | Should -Be 'none'
    }

    It 'wslg on <Id>: refused with one warning naming why, the bind never run' -ForEach @(
        @{ Os = 'windows'; Id = 'windows-wslc'; Says = 'not verified on windows-wslc' }
        @{ Os = 'linux'; Id = 'linux'; Says = 'linux is not a Windows host type backed by WSL2' }
        @{ Os = 'macos'; Id = 'macos'; Says = 'macos is not a Windows host type backed by WSL2' }
    ) {
        Initialize-AudioEvidence -Os $Os
        $env:HOST_TYPE = $Id
        $env:DCF_HOST_AUDIO = 'wslg'
        $w = $null
        Initialize-HostAudio -WarningVariable w -WarningAction SilentlyContinue | Should -Be 'none'
        "$w" | Should -BeLike "*no audio on this host ($Id): $Says*"
        Should -Invoke -ModuleName DevcontainerCli Invoke-WslgBind -Times 0 -Exactly
    }

    It 'wslg with HOST_MOUNTS=false, or an unknown value: one warning, none, no bind' {
        Initialize-AudioEvidence
        $env:HOST_TYPE = 'windows-docker'
        $env:DCF_HOST_AUDIO = 'wslg'
        $env:HOST_MOUNTS = 'false'
        $w = $null
        Initialize-HostAudio -WarningVariable w -WarningAction SilentlyContinue | Should -Be 'none'
        "$w" | Should -BeLike '*HOST_MOUNTS=false*'
        $env:HOST_MOUNTS = $null
        Clear-HostProfileCache
        $env:DCF_HOST_AUDIO = 'pulse'
        Initialize-HostAudio -WarningVariable w -WarningAction SilentlyContinue | Should -Be 'none'
        "$w" | Should -BeLike "*DCF_HOST_AUDIO='pulse' is not known*"
        Should -Invoke -ModuleName DevcontainerCli Invoke-WslgBind -Times 0 -Exactly
    }

    It 'Get-HostMount lists audio only with -Audio wslg; Initialize-HostMountSource leaves its source alone' {
        @(Get-HostMount -Type 'windows-docker' -HostHome '' -Audio 'none') | Should -HaveCount 0
        $m = @(Get-HostMount -Type 'windows-docker' -HostHome '' -Audio 'wslg')
        $m | Should -HaveCount 1
        $m[0].Name | Should -Be 'audio'
        ConvertTo-MountArgument -Mount $m[0] | Should -Be $script:AudioMount
    }

    It 'host says what wslg would do, or why not, and runs nothing' {
        Initialize-AudioEvidence
        $env:HOST_TYPE = 'windows-docker'
        $ws = Get-AudioWorkspace '{ "containerEnv": { "DCF_HOST_MACHINE": "${localEnv:DCF_HOST_MACHINE}" } }'
        $text = (Show-HostProfile -WorkspaceFolder $ws 6>&1 | Out-String)
        $text | Should -Match 'DCF_HOST_AUDIO     : \(unset: no audio\)'
        $env:DCF_HOST_AUDIO = 'wslg'
        $text = (Show-HostProfile -WorkspaceFolder $ws 6>&1 | Out-String)
        $text | Should -Match 'DCF_HOST_AUDIO     : wslg asked for: up binds the default WSL distro''s /mnt/wslg to /mnt/wsl/wslg'
        $text | Should -Not -Match 'target=/mnt/wslg'
        $env:HOST_TYPE = 'windows-wslc'
        Clear-HostProfileCache
        (Show-HostProfile -WorkspaceFolder $ws 6>&1 | Out-String) | Should -Match 'DCF_HOST_AUDIO     : wslg asked for, not on windows-wslc'
        Should -Invoke -ModuleName DevcontainerCli Invoke-WslgBind -Times 0 -Exactly
    }

    It 'the recorded up: the mount and DCF_HOST_AUDIO reach the CLI only with wslg' -Skip:$IsWindows {
        # Only the OS and the bind are mocked: the stub docker and devcontainer below are real commands.
        Mock -ModuleName DevcontainerCli Get-HostPlatform { 'wsl' }
        Mock -ModuleName DevcontainerCli Invoke-WslgBind { 'bound' }
        $bin = Join-Path $TestDrive 'audio-bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        $rec = Join-Path $TestDrive 'audio-args.txt'
        Set-Content (Join-Path $bin 'devcontainer') "#!/bin/sh`nfor a in `"`$@`"; do echo `"`$a`"; done > '$rec'`nenv | grep '^DCF_HOST_AUDIO=' > '$rec.env'"
        chmod +x (Join-Path $bin 'devcontainer')
        Set-Content (Join-Path $bin 'docker') "#!/bin/sh`nexit 0"
        chmod +x (Join-Path $bin 'docker')
        $env:PATH = $bin + [System.IO.Path]::PathSeparator + $script:AudioSavedPath
        $env:HOST_TYPE = 'windows-wsl-docker'
        Invoke-DevcontainerCliProcess -Subcommand up -WorkspaceFolder (Get-AudioWorkspace) 6>$null 3>$null
        @(Get-Content $rec) | Should -Not -Contain $script:AudioMount
        Get-Content "$rec.env" | Should -Be 'DCF_HOST_AUDIO=none'
        Should -Invoke -ModuleName DevcontainerCli Invoke-WslgBind -Times 0 -Exactly
        Clear-HostProfileCache
        $env:DCF_HOST_AUDIO = 'wslg'
        Invoke-DevcontainerCliProcess -Subcommand up -WorkspaceFolder (Get-AudioWorkspace) 6>$null 3>$null
        @(Get-Content $rec) | Should -Contain $script:AudioMount
        Get-Content "$rec.env" | Should -Be 'DCF_HOST_AUDIO=wslg'
        Should -Invoke -ModuleName DevcontainerCli Invoke-WslgBind -Times 1 -Exactly
        $env:PATH = $script:AudioSavedPath
    }
}

# The machine name (session-names proposal, slice 1), the counterpart of the machine part of
# test/bootstrap/host_mounts_test.sh: DCF_HOST_MACHINE is the workstation's name, sanitised, set for
# `up`; `up` and `host` warn once when the repository's devcontainer.json does not read it.
Describe 'The machine name (DCF_HOST_MACHINE)' -Skip:$IsWindows {
    BeforeAll {
        $script:MEnvNames = 'HOST_TYPE', 'HOST_MOUNTS', 'DEVCONTAINER_DOCKER_PATH', 'HOME', 'SSH_AUTH_SOCK', 'SSH_AGENT_MODE', 'DCF_HOST_TYPE', 'DCF_HOST_HOME', 'DCF_HOST_SSH_AGENT', 'DCF_HOST_CLOUD_FOLDER', 'DCF_HOST_FUSE', 'DCF_HOST_MACHINE', 'COMPUTERNAME'
        $script:MSavedEnv = @{}
        foreach ($n in $script:MEnvNames) { $script:MSavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
        $script:MSavedPath = $env:PATH
        $script:MBin = Join-Path $TestDrive 'machine-bin'
        New-Item -ItemType Directory -Path $script:MBin | Out-Null
        $script:MRec = Join-Path $TestDrive 'machine-args.txt'
        Set-Content (Join-Path $script:MBin 'devcontainer') "#!/bin/sh`nenv | grep '^DCF_HOST_MACHINE' > '$($script:MRec)' || : > '$($script:MRec)'"
        Set-Content (Join-Path $script:MBin 'docker') "#!/bin/sh`nexit 0"
        chmod +x (Join-Path $script:MBin 'devcontainer') (Join-Path $script:MBin 'docker')
        $script:MLine = '{ "containerEnv": { "DCF_HOST_MACHINE": "${localEnv:DCF_HOST_MACHINE}" } }'
        function Get-MachineWorkspace {
            param([string]$Json)
            $ws = Join-Path $TestDrive ('mws-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $ws '.devcontainer') -Force | Out-Null
            if ($Json) { [System.IO.File]::WriteAllText((Join-Path $ws '.devcontainer/devcontainer.json'), $Json) }
            $ws
        }
    }
    BeforeEach {
        foreach ($n in $script:MEnvNames) { [Environment]::SetEnvironmentVariable($n, $null) }
        $env:PATH = $script:MBin + [System.IO.Path]::PathSeparator + $script:MSavedPath
        $env:HOME = Join-Path $TestDrive 'machine-home'
        $env:HOST_TYPE = 'linux'
        Clear-HostProfileCache
    }
    AfterAll {
        foreach ($n in $script:MEnvNames) { [Environment]::SetEnvironmentVariable($n, $script:MSavedEnv[$n]) }
        $env:PATH = $script:MSavedPath
    }

    It 'ConvertTo-MachineName: <Raw> becomes <Expected>' -ForEach @(
        @{ Raw = 'Alice-PC'; Expected = 'Alice-PC' }
        @{ Raw = '  my laptop (2)!.'; Expected = 'my-laptop-2' }
        @{ Raw = 'a_b.c'; Expected = 'a_b.c' }
        @{ Raw = '!!!'; Expected = '' }
        @{ Raw = ('a' * 80); Expected = ('a' * 63) }
    ) {
        ConvertTo-MachineName -Name $Raw | Should -Be $Expected
    }

    It 'Get-HostMachineName reads COMPUTERNAME, sanitised' {
        $env:COMPUTERNAME = 'DESK TOP-01'
        Get-HostMachineName | Should -Be 'DESK-TOP-01'
    }

    It 'up: the CLI sees DCF_HOST_MACHINE, replacing an inherited value' {
        $env:COMPUTERNAME = 'Alice-PC'
        $env:DCF_HOST_MACHINE = 'inherited'
        Invoke-DevcontainerCliProcess -Subcommand up -WorkspaceFolder (Get-MachineWorkspace $script:MLine) 6>$null 3>$null
        Get-Content $script:MRec | Should -Be @('DCF_HOST_MACHINE=Alice-PC')
    }

    It 'up: one warning, and the CLI still runs, when the line is missing; none when present or for build' {
        $env:COMPUTERNAME = 'Alice-PC'
        $w = Invoke-DevcontainerCliProcess -Subcommand up -WorkspaceFolder (Get-MachineWorkspace '{ "name": "plain" }') 6>$null 3>&1
        @($w | Where-Object { "$_" -match 'does not read DCF_HOST_MACHINE' }) | Should -HaveCount 1
        Get-Content $script:MRec | Should -Be @('DCF_HOST_MACHINE=Alice-PC')
        $w = Invoke-DevcontainerCliProcess -Subcommand up -WorkspaceFolder (Get-MachineWorkspace $script:MLine) 6>$null 3>&1
        @($w | Where-Object { "$_" -match 'does not read DCF_HOST_MACHINE' }) | Should -HaveCount 0
        $w = Invoke-DevcontainerCliProcess -Subcommand build -WorkspaceFolder (Get-MachineWorkspace '{ }') 6>$null 3>&1
        @($w | Where-Object { "$_" -match 'does not read DCF_HOST_MACHINE' }) | Should -HaveCount 0
    }

    It 'Test-MachineSlotMissing: a commented line counts as missing, the template and no file do not' {
        Test-MachineSlotMissing -WorkspaceFolder (Get-MachineWorkspace $script:MLine) | Should -BeFalse
        Test-MachineSlotMissing -WorkspaceFolder (Get-MachineWorkspace '{ }') | Should -BeTrue
        Test-MachineSlotMissing -WorkspaceFolder (Get-MachineWorkspace "{`n  // `"DCF_HOST_MACHINE`": `"`${localEnv:DCF_HOST_MACHINE}`"`n}") | Should -BeTrue
        Test-MachineSlotMissing -WorkspaceFolder (Get-MachineWorkspace '') | Should -BeFalse
        $tpl = Get-MachineWorkspace ''
        Copy-Item (Join-Path $PSScriptRoot '../../bootstrap/devcontainer.json') (Join-Path $tpl '.devcontainer/devcontainer.json')
        Test-MachineSlotMissing -WorkspaceFolder $tpl | Should -BeFalse
    }

    It 'host prints the machine name and warns when the line is missing' {
        $env:COMPUTERNAME = 'Alice-PC'
        $text = (Show-HostProfile -WorkspaceFolder (Get-MachineWorkspace '{ }') 6>&1 3>&1 | ForEach-Object { if ($_.MessageData) { $_.MessageData.Message } else { "$_" } }) -join "`n"
        $text | Should -Match 'DCF_HOST_MACHINE   : Alice-PC'
        $text | Should -Match 'does not read DCF_HOST_MACHINE'
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

    It 'says it is deprecated, naming openbao-ssh-import' {
        $env:DCF_TEST_RUNNING = '1'
        $w = Import-SshKey -WorkspaceFolder $script:Ws -KeyFile $script:Key 3>&1 6>$null | Out-String
        $w | Should -Match 'deprecated: .*task devcontainer:openbao-ssh-import FILE=<key>'
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

# openbao-ssh-import (task devcontainer:openbao-ssh-import): the key file reaches `devcontainer exec` of
# `openbao-ssh import --from file` on stdin and never in its arguments; the bash twin's tests are in
# ssh_key_import_test.sh.
Describe 'openbao-ssh-import' -Skip:$IsWindows {
    BeforeAll {
        $script:EnvNames = 'HOST_TYPE', 'DEVCONTAINER_DOCKER_PATH', 'HOME', 'DCF_TEST_RUNNING', 'DCF_TEST_REFUSE', 'DCF_TEST_CALLS'
        $script:SavedEnv = @{}
        foreach ($n in $script:EnvNames) { $script:SavedEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
        $script:SavedPath = $env:PATH
        $script:Bin = Join-Path $TestDrive 'obin'
        $script:Calls = Join-Path $TestDrive 'ocalls'
        New-Item -ItemType Directory -Path $script:Bin, $script:Calls | Out-Null
        $stub = @'
#!/bin/sh
n=$(ls "$DCF_TEST_CALLS" | grep -c args)
for a in "$@"; do echo "$a"; done > "$DCF_TEST_CALLS/$n.args"
case "$*" in *openbao-ssh*) cat > "$DCF_TEST_CALLS/$n.stdin" ;; *) : > "$DCF_TEST_CALLS/$n.stdin" ;; esac
case "$*" in *openbao-ssh*) if [ "$DCF_TEST_REFUSE" = 1 ]; then echo "dcf-secret: the server is sealed" >&2; exit 11; fi ;; esac
exit 0
'@
        [System.IO.File]::WriteAllText((Join-Path $script:Bin 'devcontainer'), $stub.Replace("`r`n", "`n"))
        [System.IO.File]::WriteAllText((Join-Path $script:Bin 'docker'), "#!/bin/sh`n[ `"`$1`" = ps ] && [ `"`$DCF_TEST_RUNNING`" = 1 ] && echo abc123`nexit 0`n")
        chmod +x (Join-Path $script:Bin 'devcontainer') (Join-Path $script:Bin 'docker')
        $script:Secret = 'SECRET-KEY-BYTES-0123456789'
        $script:Begin = '-----BEGIN OPENSSH ' + 'PRIVATE KEY-----'
        $script:End = '-----END OPENSSH ' + 'PRIVATE KEY-----'
        $script:Key = Join-Path $TestDrive 'work-sign'
        [System.IO.File]::WriteAllText($script:Key, "$($script:Begin)`n$($script:Secret)`n$($script:End)`n")
        $script:Ws = Join-Path $TestDrive 'ows'
        New-Item -ItemType Directory -Path $script:Ws | Out-Null
        function Get-CallCount { @(Get-ChildItem $script:Calls -Filter '*.args').Count }
    }
    BeforeEach {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $null) }
        $env:PATH = $script:Bin + [System.IO.Path]::PathSeparator + $script:SavedPath
        $env:HOME = Join-Path $TestDrive 'ohome'
        $env:HOST_TYPE = 'linux'
        $env:DCF_TEST_CALLS = $script:Calls
        Get-ChildItem $script:Calls | Remove-Item
        Clear-HostProfileCache
    }
    AfterAll {
        foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $script:SavedEnv[$n]) }
        $env:PATH = $script:SavedPath
    }

    It 'streams the key into openbao-ssh import --from file on stdin, never in an argument, in one call' {
        $env:DCF_TEST_RUNNING = '1'
        $w = Import-OpenBaoSshKey -WorkspaceFolder $script:Ws -KeyFile $script:Key 3>&1 6>$null | Out-String
        Get-CallCount | Should -Be 1
        (Get-Content (Join-Path $script:Calls '0.args')) -join ' ' | Should -Match 'openbao-ssh import --from file --name work-sign$'
        (Get-Content (Join-Path $script:Calls '0.stdin') -Raw) | Should -Match ([regex]::Escape($script:Secret))
        (Get-Content (Join-Path $script:Calls '0.args') -Raw) | Should -Not -Match ([regex]::Escape($script:Secret))
        $w | Should -Not -Match 'deprecated'
    }

    It 'passes NAME as the record name' {
        $env:DCF_TEST_RUNNING = '1'
        Import-OpenBaoSshKey -WorkspaceFolder $script:Ws -KeyFile $script:Key -Name 'other-sign' 6>$null
        (Get-Content (Join-Path $script:Calls '0.args')) -join ' ' | Should -Match '--name other-sign$'
    }

    It 'refuses a missing file, naming FILE, and starts nothing' {
        $env:DCF_TEST_RUNNING = '1'
        { Import-OpenBaoSshKey -WorkspaceFolder $script:Ws -KeyFile (Join-Path $TestDrive 'missing') 6>$null } | Should -Throw '*FILE=<path of a private key on this host>*'
        Get-CallCount | Should -Be 0
    }

    It 'refuses when no container runs and starts nothing' {
        { Import-OpenBaoSshKey -WorkspaceFolder $script:Ws -KeyFile $script:Key 6>$null } | Should -Throw '*task dc:start*'
        Get-CallCount | Should -Be 0
    }

    It 'a container that refuses fails the import, naming the login' {
        $env:DCF_TEST_RUNNING = '1'
        $env:DCF_TEST_REFUSE = '1'
        { Import-OpenBaoSshKey -WorkspaceFolder $script:Ws -KeyFile $script:Key 6>$null 2>$null } | Should -Throw '*exit 11*task openbao:login*'
    }

    It 'the launcher dispatches the openbao-ssh-import subcommand with the file and the name' {
        $env:DCF_TEST_RUNNING = '1'
        Invoke-DevcontainerCli -Subcommand 'openbao-ssh-import' -WorkspaceFolder $script:Ws -Arguments @($script:Key, 'disp-sign') 6>$null
        (Get-Content (Join-Path $script:Calls '0.args')) -join ' ' | Should -Match 'openbao-ssh import --from file --name disp-sign$'
    }
}

Describe 'Host bootstrap downloads retry a dropped connection' {
    It 'every Invoke-WebRequest in <_> sits inside Invoke-DcfDownload' -ForEach @('bootstrap/bootstrap.ps1', 'bootstrap/host/DevcontainerCli.psm1') {
        $file = Join-Path $PSScriptRoot "../../$_"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WebRequest' }, $true)
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) {
            $p = $c.Parent
            while ($p -and -not ($p -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $p = $p.Parent }
            $p.Name | Should -Be 'Invoke-DcfDownload'
        }
    }
}
