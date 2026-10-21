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
}
