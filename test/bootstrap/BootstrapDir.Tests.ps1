# Pester 5+ tests of where bootstrap/bootstrap.ps1 vendors (slice 2 of the host-profile
# proposal), the twin of test/bootstrap/bootstrap_dir_test.sh: the default folder
# .devcontainer/cli_bootstrap.ignore, BOOTSTRAP_DIR, its rejections, the .gitignore
# handling and the Taskfile template's include. The script runs in a child pwsh against a
# temp "consuming repo", takes its files from this checkout (-Source <dir>) and a fake
# `task` first on PATH. Run: task test:bootstrap (part of lint).

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:Script = if ($env:BOOTSTRAP_PS1) { $env:BOOTSTRAP_PS1 } else { Join-Path $script:Root 'bootstrap/bootstrap.ps1' }
    $script:PwshExe = (Get-Process -Id $PID).Path
    $script:Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bootstrap-dir-" + [guid]::NewGuid().ToString('N'))
    $script:Bin = Join-Path $script:Tmp 'bin'
    New-Item -ItemType Directory -Path $script:Bin -Force | Out-Null
    if ($IsWindows) { Set-Content (Join-Path $script:Bin 'task.cmd') '@echo fake task %*' }
    else {
        Set-Content (Join-Path $script:Bin 'task') "#!/bin/sh`necho fake task `$*"
        chmod +x (Join-Path $script:Bin 'task')
    }

    function Get-TempRepo { $r = Join-Path $script:Tmp ('repo-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $r | Out-Null; $r }
    # Runs the bootstrap in $Repo with $Env (hashtable) set; returns @{ Out; Code }.
    function Invoke-Bootstrap {
        param([string]$Repo, [hashtable]$Env = @{}, [string[]]$Extra = @())
        $saved = @{}
        $names = @('BOOTSTRAP_DIR', 'BOOTSTRAP_GITIGNORE') + @($Env.Keys)
        foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
        $savedPath = $env:PATH
        try {
            foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
            $env:PATH = $script:Bin + [System.IO.Path]::PathSeparator + $env:PATH
            Push-Location $Repo
            $out = & $script:PwshExe -NoLogo -NoProfile -File $script:Script -Source $script:Root -NoUp @Extra 2>&1 | Out-String
            @{ Out = $out; Code = $LASTEXITCODE }
        }
        finally {
            Pop-Location
            $env:PATH = $savedPath
            foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        }
    }
    function Get-FileLine([string]$File) { @(Get-Content -LiteralPath $File) }
}

AfterAll { Remove-Item -Recurse -Force $script:Tmp -ErrorAction SilentlyContinue }

Describe 'bootstrap.ps1 vendoring folder' {
    It 'vendors into .devcontainer/cli_bootstrap.ignore by default and prints it' {
        $r = Get-TempRepo; $res = Invoke-Bootstrap $r
        $res.Code | Should -Be 0
        Test-Path (Join-Path $r '.devcontainer/cli_bootstrap.ignore/devcontainer.yml') | Should -BeTrue
        Test-Path (Join-Path $r '.devcontainer/cli_bootstrap.ignore/host/devcontainer-cli.sh') | Should -BeTrue
        Test-Path (Join-Path $r 'bootstrap') | Should -BeFalse
        $res.Out | Should -Match 'folder\s+\.devcontainer/cli_bootstrap\.ignore/'
        $res.Out | Should -Not -Match 'MIGRATION'
    }

    It 'honours BOOTSTRAP_DIR (environment) and the -BootstrapDir parameter' {
        $r = Get-TempRepo; $res = Invoke-Bootstrap $r @{ BOOTSTRAP_DIR = 'tools/dc/' }
        $res.Code | Should -Be 0
        Test-Path (Join-Path $r 'tools/dc/devcontainer.yml') | Should -BeTrue
        Test-Path (Join-Path $r '.devcontainer/cli_bootstrap.ignore') | Should -BeFalse
        $res.Out | Should -Match 'folder\s+tools/dc/'
        $r2 = Get-TempRepo; $null = Invoke-Bootstrap $r2 @{} @('-BootstrapDir', '.devcontainer/vendor')
        Test-Path (Join-Path $r2 '.devcontainer/vendor/devcontainer.yml') | Should -BeTrue
        Get-FileLine (Join-Path $r2 '.devcontainer/.gitignore') | Should -Contain 'vendor/'
    }

    It 'refuses <Dir> and writes nothing' -ForEach @(
        @{ Dir = '/abs/path' }, @{ Dir = 'C:\x' }, @{ Dir = '../up' }, @{ Dir = 'a/../../up' },
        @{ Dir = '..' }, @{ Dir = '.' }, @{ Dir = '.devcontainer' }
    ) {
        $r = Get-TempRepo; $res = Invoke-Bootstrap $r @{ BOOTSTRAP_DIR = $Dir }
        $res.Code | Should -Not -Be 0
        $res.Out | Should -Match 'BOOTSTRAP_DIR'
        @(Get-ChildItem $r -Recurse -File).Count | Should -Be 0
    }
}

Describe 'bootstrap.ps1 git-ignore of the vendored folder' {
    It 'creates .devcontainer/.gitignore and appends once on a re-run' {
        $r = Get-TempRepo; $null = Invoke-Bootstrap $r; $null = Invoke-Bootstrap $r
        @(Get-FileLine (Join-Path $r '.devcontainer/.gitignore') | Where-Object { $_ -eq 'cli_bootstrap.ignore/' }).Count | Should -Be 1
    }

    It 'keeps unrelated lines and handles a missing final newline' {
        $r = Get-TempRepo; New-Item -ItemType Directory -Path (Join-Path $r '.devcontainer') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $r '.devcontainer/.gitignore'), "*.log`nsecrets/")
        $null = Invoke-Bootstrap $r; $null = Invoke-Bootstrap $r
        (Get-FileLine (Join-Path $r '.devcontainer/.gitignore')) -join '|' | Should -Be '*.log|secrets/|cli_bootstrap.ignore/'
    }

    It 'writes the root .gitignore for a folder outside .devcontainer' {
        $r = Get-TempRepo; $null = Invoke-Bootstrap $r @{ BOOTSTRAP_DIR = 'tools/dc' }
        Get-FileLine (Join-Path $r '.gitignore') | Should -Contain '/tools/dc/'
        Test-Path (Join-Path $r '.devcontainer/.gitignore') | Should -BeFalse
    }

    It 'writes none with BOOTSTRAP_GITIGNORE=false or -NoGitignore' {
        $r = Get-TempRepo; $res = Invoke-Bootstrap $r @{ BOOTSTRAP_GITIGNORE = 'false' }
        Test-Path (Join-Path $r '.devcontainer/.gitignore') | Should -BeFalse
        $res.Out | Should -Match 'skipped'
        $r2 = Get-TempRepo; $null = Invoke-Bootstrap $r2 @{} @('-NoGitignore')
        Test-Path (Join-Path $r2 '.devcontainer/.gitignore') | Should -BeFalse
    }
}

Describe 'bootstrap.ps1 Taskfile template and the old form' {
    It 'writes an optional include of the chosen path' {
        $r = Get-TempRepo; $null = Invoke-Bootstrap $r
        $t = Get-Content (Join-Path $r 'Taskfile.yml') -Raw
        $t | Should -Match "taskfile: '\./\.devcontainer/cli_bootstrap\.ignore/devcontainer\.yml'"
        # the devcontainer include itself, not the features include after it
        $t | Should -Match "(?s)devcontainer:\s+taskfile: '[^']+'\s+optional: true"
        $t | Should -Not -Match 'BOOTSTRAP_DIR'
        $r2 = Get-TempRepo; $null = Invoke-Bootstrap $r2 @{ BOOTSTRAP_DIR = 'tools/dc' }
        Get-Content (Join-Path $r2 'Taskfile.yml') -Raw | Should -Match "taskfile: '\./tools/dc/devcontainer\.yml'"
    }

    It 'migrates an old ./bootstrap repo: note, repointed include, ./bootstrap kept' {
        $r = Get-TempRepo; New-Item -ItemType Directory -Path (Join-Path $r 'bootstrap') | Out-Null
        Set-Content (Join-Path $r 'bootstrap/devcontainer.yml') 'old vendored'
        $old = "version: '3'`n# my comment`nincludes:`n  devcontainer:`n    taskfile: ./bootstrap/devcontainer.yml   # old`n    aliases: [dc]`n  other:`n    taskfile: ./other.yml`n"
        [System.IO.File]::WriteAllText((Join-Path $r 'Taskfile.yml'), $old)
        $res = Invoke-Bootstrap $r
        $res.Code | Should -Be 0
        $res.Out | Should -Match 'MIGRATION'
        $res.Out | Should -Match 'repointed Taskfile\.yml'
        (Get-Content (Join-Path $r 'bootstrap/devcontainer.yml') -Raw).Trim() | Should -Be 'old vendored'
        Test-Path (Join-Path $r '.devcontainer/cli_bootstrap.ignore/devcontainer.yml') | Should -BeTrue
        $expected = $old.Replace('taskfile: ./bootstrap/devcontainer.yml   # old', "taskfile: ./.devcontainer/cli_bootstrap.ignore/devcontainer.yml   # old`n    optional: true")
        [System.IO.File]::ReadAllText((Join-Path $r 'Taskfile.yml')) | Should -Be $expected
        $res.Out | Should -Match 'added\s+optional: true'
        # a second run has nothing left to repoint or add
        $res2 = Invoke-Bootstrap $r
        $res2.Out | Should -Not -Match 'repointed|added\s+optional'
        @(Select-String -Path (Join-Path $r 'Taskfile.yml') -Pattern 'optional: true').Count | Should -Be 1
    }

    It 'adds no second optional when the include block already has one, before or after the taskfile line' -ForEach @(
        @{ Name = 'before'; Text = "includes:`n  devcontainer:`n    optional: true`n    taskfile: ./bootstrap/devcontainer.yml`n  other:`n    taskfile: ./other.yml`n" }
        @{ Name = 'after'; Text = "includes:`n  devcontainer:`n    taskfile: ./bootstrap/devcontainer.yml`n    optional: false`n  other:`n    taskfile: ./other.yml`n" }
    ) {
        $r = Get-TempRepo; New-Item -ItemType Directory -Path (Join-Path $r 'bootstrap') | Out-Null
        Set-Content (Join-Path $r 'bootstrap/devcontainer.yml') 'old vendored'
        [System.IO.File]::WriteAllText((Join-Path $r 'Taskfile.yml'), $Text)
        $res = Invoke-Bootstrap $r
        $res.Out | Should -Not -Match 'added\s+optional'
        @(Select-String -Path (Join-Path $r 'Taskfile.yml') -Pattern 'optional').Count | Should -Be 1
    }

    It 'adds optional: true on its own line when the taskfile line ends the file' {
        $r = Get-TempRepo; New-Item -ItemType Directory -Path (Join-Path $r 'bootstrap') | Out-Null
        Set-Content (Join-Path $r 'bootstrap/devcontainer.yml') 'old vendored'
        [System.IO.File]::WriteAllText((Join-Path $r 'Taskfile.yml'), "includes:`n  devcontainer:`n    taskfile: ./bootstrap/devcontainer.yml")
        $null = Invoke-Bootstrap $r
        [System.IO.File]::ReadAllText((Join-Path $r 'Taskfile.yml')) | Should -Be "includes:`n  devcontainer:`n    taskfile: ./.devcontainer/cli_bootstrap.ignore/devcontainer.yml`n    optional: true`n"
    }

    It 'gives no note and no rewrite when BOOTSTRAP_DIR is set' {
        $r = Get-TempRepo; New-Item -ItemType Directory -Path (Join-Path $r 'bootstrap') | Out-Null
        Set-Content (Join-Path $r 'bootstrap/devcontainer.yml') 'old vendored'
        $old = "includes:`n  devcontainer:`n    taskfile: ./bootstrap/devcontainer.yml`n"
        [System.IO.File]::WriteAllText((Join-Path $r 'Taskfile.yml'), $old)
        $res = Invoke-Bootstrap $r @{ BOOTSTRAP_DIR = 'vendor' }
        $res.Out | Should -Not -Match 'MIGRATION'
        [System.IO.File]::ReadAllText((Join-Path $r 'Taskfile.yml')) | Should -Be $old
    }
}
