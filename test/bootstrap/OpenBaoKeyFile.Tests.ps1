# Pester 5+ tests of the Windows launcher's OpenBao key file (bootstrap/host/DevcontainerCli.psm1,
# "the OpenBao key file"; docs/proposals/openbao-key-file.md, slice 2): the unlock step after `up`
# and the tasks devcontainer:openbao:unlock and :keyfile:create|rotate|export|import|forget.
# The container is a stub engine (`docker`, a bash script) that speaks the contract of
# /usr/local/bin/openbao-setup (unlock --status, unlock --stdin, keyfile create|rotate|confirm|cancel
# --stdin, keyfile status; the contract's Amendment 1) and
# records its arguments, its environment and its stdin. DPAPI is Windows-only, so everywhere but the
# round trip the protector (Protect-/Unprotect-OpenBaoKeyFileBlob) is mocked with a reversible
# stand-in; Read-Host is mocked for the shares and the transfer passphrase.
# Covered: the step silent for mode off/operator, ready, no openbao-setup and an older one; the key
# file streamed on stdin only (never in the engine's arguments or environment, nothing in the temp
# folder); the no-key-file line; the agent guard (CLAUDECODE, DEVHOST_JOB_CHILD,
# OPENBAO_AGENT_JOB_VARS); create (typed shares, init), rotate (the key file's own shares), the saved
# key file's shape; the two steps: the key file saved before confirm, confirm's shares read back from
# it, the custody shares printed only after confirm answers ok, a failed save or confirm cancelling
# (the previous key file put back), a lost confirm answer retried and then settled by keyfile
# status, the warnings shown, error then code on failure; export/import round trip, a wrong passphrase,
# the checkout refused; forget; the step wired after `up` only; the bash launcher's one refusal line.
# The stub engine is a shell script, so the Describes that use it run where bash runs (Linux, macOS,
# CI); the DPAPI round trip runs only on Windows:
#   pwsh -NoProfile -Command "Invoke-Pester -Path test/bootstrap/OpenBaoKeyFile.Tests.ps1 -Output Detailed"

BeforeDiscovery {
    $script:HasBash = [bool](Get-Command bash -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $script:Root 'bootstrap/host/DevcontainerCli.psm1') -Force
    $script:HasBash = [bool](Get-Command bash -ErrorAction SilentlyContinue)
    $script:Marker = 'SHAREMARKER-q7x2'

    # A fresh world per test: the workspace, the key folder, an empty temp folder, the stub's logs.
    function Initialize-World {
        $t = Join-Path ([IO.Path]::GetTempPath()) "dcf-obkf-$([guid]::NewGuid().ToString('N'))"
        $w = @{
            T = $t; Bin = (Join-Path $t 'bin'); Ws = (Join-Path $t 'myrepo'); Tmp = (Join-Path $t 'tmp')
            Argv = (Join-Path $t 'argv.log'); EnvLog = (Join-Path $t 'env.log'); Stdin = (Join-Path $t 'stdin.log')
        }
        New-Item -ItemType Directory -Path $w.Bin, (Join-Path $w.Ws '.devcontainer'), $w.Tmp -Force | Out-Null
        $stub = @'
#!/usr/bin/env bash
case "$1" in
  ps) [ "${FAKE_RUNNING:-1}" = 1 ] && echo cid1; exit 0 ;;
  inspect) printf '%s\n' '[{"Config":{"Labels":{"devcontainer.metadata":"[{\"remoteUser\":\"vscode\"}]"}}}]'; exit 0 ;;
  exec) ;;
  *) exit 0 ;;
esac
printf '%s\n' "$*" >> "$FAKE_ARGV"
env >> "$FAKE_ENVLOG"
shift
while [ $# -gt 0 ]; do case "$1" in -i) shift ;; -u) shift 2 ;; *) break ;; esac; done
[ "$1" = cid1 ] || exit 125
shift
if [ "${FAKE_NO_SETUP:-}" = 1 ] || [ "$1" != /usr/local/bin/openbao-setup ]; then
  echo 'OCI runtime exec failed: exec: "/usr/local/bin/openbao-setup": no such file or directory' >&2; exit 127
fi
shift
case "$1 $2" in
  'unlock --status') printf '%s\n' "$FAKE_STATUS"; exit "${FAKE_STATUS_RC:-0}" ;;
  'unlock --stdin') cat > "$FAKE_STDIN"; printf '%s\n' "${FAKE_UNLOCK_OUT:-{\"v\":1,\"ok\":true,\"done\":\"unsealed, logged in\"\}}"; exit "${FAKE_UNLOCK_RC:-0}" ;;
  'keyfile create' | 'keyfile rotate') cat > "$FAKE_STDIN"; echo 'container: rotating keys' >&2; printf '%s\n' "$FAKE_MAKE_OUT"; exit "${FAKE_MAKE_RC:-0}" ;;
  'keyfile confirm')
    { cat; echo; } >> "$FAKE_STDIN.confirm"
    if [ -n "${FAKE_KEYFILE:-}" ] && [ -f "$FAKE_KEYFILE" ]; then echo 'key file on disk at confirm' >> "$FAKE_ARGV"; fi
    n=$(( $(cat "$FAKE_STDIN.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_STDIN.count"
    case "${FAKE_CONFIRM:-ok}:$n" in
      fail:*) printf '%s\n' '{"v":1,"ok":false,"error":"the shares do not verify","code":"verify"}'; exit 1 ;;
      lost:* | lost-once:1) exit 137 ;;
    esac
    printf '%s\n' '{"v":1,"ok":true,"server":"clu-1","backup":"b1","warnings":["the backup went to the default destination"]}'; exit 0 ;;
  'keyfile cancel') cat > "$FAKE_STDIN.cancel"; printf '%s\n' '{"v":1,"ok":true}'; exit 0 ;;
  'keyfile status') printf '%s\n' "${FAKE_KF_STATUS:-{\"v\":1,\"ok\":true,\"server\":\"clu-1\",\"shares\":5,\"threshold\":2,\"approle\":true,\"userpass\":false\}}"; exit 0 ;;
esac
echo "usage: openbao-setup ..." >&2; exit 2
'@
        $engine = Join-Path $w.Bin 'docker'
        [IO.File]::WriteAllText($engine, $stub)
        if (-not $IsWindows) { & chmod +x $engine }
        $w.Engine = $engine
        $w.Saved = @{}
        foreach ($k in 'DEVCONTAINER_DOCKER_PATH', 'XDG_DATA_HOME', 'LOCALAPPDATA', 'TMPDIR', 'TEMP', 'TMP', 'FAKE_ARGV', 'FAKE_ENVLOG', 'FAKE_STDIN',
            'FAKE_STATUS', 'FAKE_STATUS_RC', 'FAKE_RUNNING', 'FAKE_NO_SETUP', 'FAKE_UNLOCK_OUT', 'FAKE_UNLOCK_RC', 'FAKE_MAKE_OUT', 'FAKE_MAKE_RC', 'FAKE_CONFIRM', 'FAKE_KF_STATUS', 'FAKE_KEYFILE',
            'CLAUDECODE', 'DEVHOST_JOB_CHILD', 'OPENBAO_AGENT_JOB_VARS', 'MY_AGENT_JOB') {
            $w.Saved[$k] = [Environment]::GetEnvironmentVariable($k)
        }
        $env:DEVCONTAINER_DOCKER_PATH = $engine
        $env:XDG_DATA_HOME = (Join-Path $t 'data'); $env:LOCALAPPDATA = (Join-Path $t 'localappdata')
        $env:TMPDIR = $w.Tmp; $env:TEMP = $w.Tmp; $env:TMP = $w.Tmp
        $env:FAKE_ARGV = $w.Argv; $env:FAKE_ENVLOG = $w.EnvLog; $env:FAKE_STDIN = $w.Stdin
        foreach ($k in 'FAKE_STATUS_RC', 'FAKE_RUNNING', 'FAKE_NO_SETUP', 'FAKE_UNLOCK_OUT', 'FAKE_UNLOCK_RC', 'FAKE_MAKE_OUT', 'FAKE_MAKE_RC', 'FAKE_CONFIRM', 'FAKE_KF_STATUS', 'FAKE_KEYFILE', 'CLAUDECODE', 'DEVHOST_JOB_CHILD', 'OPENBAO_AGENT_JOB_VARS', 'MY_AGENT_JOB') {
            [Environment]::SetEnvironmentVariable($k, $null)
        }
        $env:FAKE_STATUS = (Get-Status)
        return $w
    }
    function Clear-World($w) {
        foreach ($k in $w.Saved.Keys) { [Environment]::SetEnvironmentVariable($k, $w.Saved[$k]) }
        Remove-Item -LiteralPath $w.T -Recurse -Force -ErrorAction SilentlyContinue
    }
    function Get-Status([string]$Mode = 'keyfile', [bool]$Sealed = $true, [string]$Token = 'missing', [bool]$Initialized = $true, [string]$Server = 'clu-1') {
        $ready = $Mode -eq 'keyfile' -and -not $Sealed -and $Token -eq 'live'
        ConvertTo-Json -Compress -InputObject @{ v = 1; mode = $Mode; initialized = $Initialized; sealed = $Sealed; token = $Token; renewer = $false; ready = $ready; server = $Server }
    }
    function Get-Log([string]$Path) { if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' } }
    # Runs $Body; returns Rc (its output), Host (Write-Host lines) and Err (the console's stderr).
    function Invoke-Captured([scriptblock]$Body) {
        $sw = [IO.StringWriter]::new()
        $old = [Console]::Error
        [Console]::SetError($sw)
        try { $all = @(& $Body 6>&1) }
        finally { [Console]::SetError($old) }
        $info = @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" })
        $rest = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        if ($rest.Count -gt 1) { throw "more than one output object: $($rest -join ', ')" }
        @{ Rc = ($rest | Select-Object -Last 1); Host = ($info -join "`n"); Err = $sw.ToString() }
    }
    function Get-KeyFileJson([string]$Server = 'clu-1') {
        ConvertTo-Json -Compress -InputObject ([ordered]@{ v = 1; server = $Server; repo = 'myrepo'; created = '2026-11-05T10:00:00Z'; shares = @("$($script:Marker)-4", "$($script:Marker)-5"); role_id = 'role-abc'; secret_id = "$($script:Marker)-secret" })
    }
    function Save-TestKeyFile([string]$Server = 'clu-1') {
        InModuleScope DevcontainerCli -Parameters @{ J = (Get-KeyFileJson $Server); S = $Server } {
            param($J, $S)
            Save-OpenBaoKeyFile -Repo 'myrepo' -Server $S -Json ([Text.Encoding]::UTF8.GetBytes($J))
        }
    }
    function Use-ProtectorStandIn {
        # A reversible stand-in for DPAPI off Windows: a prefix and the bytes XOR 0x5A.
        Mock -ModuleName DevcontainerCli Protect-OpenBaoKeyFileBlob { , [byte[]](@(0x50, 0x52) + @($Bytes | ForEach-Object { $_ -bxor 0x5A })) }
        Mock -ModuleName DevcontainerCli Unprotect-OpenBaoKeyFileBlob {
            if ($Bytes[0] -ne 0x50 -or $Bytes[1] -ne 0x52) { throw 'not ours' }
            , [byte[]]@($Bytes | Select-Object -Skip 2 | ForEach-Object { $_ -bxor 0x5A })
        }
    }
    function Secure([string]$s) { $ss = [securestring]::new(); foreach ($ch in $s.ToCharArray()) { $ss.AppendChar($ch) }; $ss }
}

AfterAll { Remove-Module DevcontainerCli -Force -ErrorAction SilentlyContinue }

Describe 'The unlock step after up' -Skip:(-not $script:HasBash -or $IsWindows) {
    BeforeEach { $script:W = Initialize-World; Use-ProtectorStandIn }
    AfterEach { Clear-World $script:W }

    It 'is silent and sends nothing when the status says mode <mode>' -ForEach @(
        @{ mode = 'off' }
        @{ mode = 'operator' }
    ) {
        $env:FAKE_STATUS = Get-Status -Mode $mode
        Save-TestKeyFile
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws }
        $r.Rc | Should -Be 0
        $r.Host | Should -BeNullOrEmpty
        $r.Err | Should -BeNullOrEmpty
        Get-Log $script:W.Argv | Should -Not -Match 'unlock --stdin'
    }

    It 'is silent and sends nothing when the status says ready' {
        $env:FAKE_STATUS = Get-Status -Sealed $false -Token 'live'
        Save-TestKeyFile
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws }
        $r.Rc | Should -Be 0
        "$($r.Host)$($r.Err)" | Should -BeNullOrEmpty
        (Get-Log $script:W.Argv).Trim() | Should -Be 'exec -i -u vscode cid1 /usr/local/bin/openbao-setup unlock --status'
    }

    It 'is silent when the container has no openbao-setup' {
        $env:FAKE_NO_SETUP = '1'
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws }
        $r.Rc | Should -Be 0
        "$($r.Host)$($r.Err)" | Should -BeNullOrEmpty
    }

    It 'is silent when openbao-setup is older and does not know unlock --status' {
        $env:FAKE_STATUS = 'usage: openbao-setup start|status|...'
        $env:FAKE_STATUS_RC = '2'
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws }
        $r.Rc | Should -Be 0
        "$($r.Host)$($r.Err)" | Should -BeNullOrEmpty
    }

    It 'is silent when no container runs' {
        $env:FAKE_RUNNING = '0'
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws }
        $r.Rc | Should -Be 0
        "$($r.Host)$($r.Err)" | Should -BeNullOrEmpty
    }

    It 'streams the key file on stdin only and prints one line' {
        Save-TestKeyFile
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws }
        $r.Rc | Should -Be 0
        $r.Host | Should -Be 'openbao: unsealed, logged in (the OpenBao key file).'
        $r.Err | Should -BeNullOrEmpty
        $sent = Get-Log $script:W.Stdin | ConvertFrom-Json
        $sent.shares | Should -Be @("$($script:Marker)-4", "$($script:Marker)-5")
        $sent.secret_id | Should -Be "$($script:Marker)-secret"
        $sent.server | Should -Be 'clu-1'
        Get-Log $script:W.Argv | Should -Match 'exec -i -u vscode cid1 /usr/local/bin/openbao-setup unlock --stdin'
    }

    It 'puts no secret in the engine''s arguments or environment, nor in this process''s environment' {
        Save-TestKeyFile
        [void](Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws })
        Get-Log $script:W.Stdin | Should -Match $script:Marker
        Get-Log $script:W.Argv | Should -Not -Match $script:Marker
        Get-Log $script:W.EnvLog | Should -Not -BeNullOrEmpty
        Get-Log $script:W.EnvLog | Should -Not -Match $script:Marker
        (Get-ChildItem env: | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "`n" | Should -Not -Match $script:Marker
    }

    It 'writes nothing to the temp folder' {
        Save-TestKeyFile
        [void](Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws })
        Get-Log $script:W.Stdin | Should -Match $script:Marker
        @(Get-ChildItem -LiteralPath $script:W.Tmp -Force -Recurse) | Should -HaveCount 0
    }

    It 'names keyfile:create, and sends nothing, when this workstation has no key file for that server' {
        Save-TestKeyFile -Server 'another-cluster'
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws }
        $r.Rc | Should -Be 1
        $r.Err.Trim() | Should -Match '^openbao: no OpenBao key file for this server \(myrepo, clu-1\) on this workstation.*task dc:openbao:keyfile:create'
        @($r.Err.Trim() -split "`n") | Should -HaveCount 1
        Get-Log $script:W.Argv | Should -Not -Match 'unlock --stdin'
    }

    It 'says why, in one line, when the container refuses the unlock' {
        Save-TestKeyFile
        $env:FAKE_UNLOCK_OUT = '{"v":1,"ok":false,"error":"the key file is for another server"}'
        $env:FAKE_UNLOCK_RC = '1'
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws }
        $r.Rc | Should -Be 1
        $r.Err.Trim() | Should -Be 'openbao: the OpenBao key file did not unlock OpenBao: the key file is for another server.'
    }

    It 'says when a key file does not open for this account' {
        Save-TestKeyFile
        Mock -ModuleName DevcontainerCli Unprotect-OpenBaoKeyFileBlob { throw 'Key not valid for use in specified state.' }
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws }
        $r.Rc | Should -Be 1
        $r.Err | Should -Match 'could not be used \(Key not valid'
        Get-Log $script:W.Argv | Should -Not -Match 'unlock --stdin'
    }

    It 'with -Explicit (task dc:openbao:unlock) says so when OpenBao is ready already' {
        $env:FAKE_STATUS = Get-Status -Sealed $false -Token 'live'
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws -Explicit }
        $r.Rc | Should -Be 0
        $r.Host | Should -Match 'unsealed and logged in already; nothing sent'
    }

    It 'with -Explicit fails when no container runs' {
        $env:FAKE_RUNNING = '0'
        $r = Invoke-Captured { Invoke-OpenBaoUnlock -WorkspaceFolder $script:W.Ws -Explicit }
        $r.Rc | Should -Be 1
        $r.Err | Should -Match 'No running devcontainer'
    }
}

Describe 'Invoke-DevcontainerCli runs the unlock step after up only' {
    BeforeEach {
        InModuleScope DevcontainerCli { $script:CliExitCode = 0 }
        Mock -ModuleName DevcontainerCli Invoke-DevcontainerCliProcess { $script:CliExitCode = 0 }
        Mock -ModuleName DevcontainerCli Enter-DevcontainerBuildLock { [pscustomobject]@{ Held = $true } }
        Mock -ModuleName DevcontainerCli Exit-DevcontainerBuildLock { }
        Mock -ModuleName DevcontainerCli Wait-ContainerEngine { }
        Mock -ModuleName DevcontainerCli Write-ContainerEngineDiagnosis { }
        Mock -ModuleName DevcontainerCli Invoke-OpenBaoUnlock { 0 }
    }

    It 'after a successful up' {
        Invoke-DevcontainerCli -Subcommand up -WorkspaceFolder $TestDrive
        Should -Invoke -ModuleName DevcontainerCli Invoke-OpenBaoUnlock -Times 1 -Exactly -ParameterFilter { -not $Explicit }
    }

    It 'not after <sub>' -ForEach @(@{ sub = 'build' }, @{ sub = 'exec' }, @{ sub = 'read-configuration' }) {
        Invoke-DevcontainerCli -Subcommand $sub -WorkspaceFolder $TestDrive
        Should -Invoke -ModuleName DevcontainerCli Invoke-OpenBaoUnlock -Times 0 -Exactly
    }

    It 'not after a failed up, and a failing step never fails the up' {
        Mock -ModuleName DevcontainerCli Invoke-DevcontainerCliProcess { throw 'the up failed' }
        { Invoke-DevcontainerCli -Subcommand up -WorkspaceFolder $TestDrive } | Should -Throw '*the up failed*'
        Should -Invoke -ModuleName DevcontainerCli Invoke-OpenBaoUnlock -Times 0 -Exactly
        Mock -ModuleName DevcontainerCli Invoke-DevcontainerCliProcess { $script:CliExitCode = 0 }
        Mock -ModuleName DevcontainerCli Invoke-OpenBaoUnlock { throw 'boom' }
        { Invoke-DevcontainerCli -Subcommand up -WorkspaceFolder $TestDrive } | Should -Not -Throw
    }
}

Describe 'The agent guard on the share and file tasks' {
    BeforeEach {
        $script:Saved = @{}
        foreach ($k in 'CLAUDECODE', 'DEVHOST_JOB_CHILD', 'OPENBAO_AGENT_JOB_VARS', 'MY_AGENT_JOB') { $script:Saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
        Mock -ModuleName DevcontainerCli Get-OpenBaoContainer { throw 'the guard must refuse before the container is asked' }
        Mock -ModuleName DevcontainerCli Read-Host { throw 'the guard must refuse before a prompt' }
    }
    AfterEach { foreach ($k in $script:Saved.Keys) { [Environment]::SetEnvironmentVariable($k, $script:Saved[$k]) } }

    It 'keyfile:<action> refuses (exit 3) under <var>' -ForEach @(
        foreach ($action in 'create', 'rotate', 'export', 'import') {
            @{ action = $action; var = 'CLAUDECODE'; names = $null }
            @{ action = $action; var = 'DEVHOST_JOB_CHILD'; names = $null }
            @{ action = $action; var = 'MY_AGENT_JOB'; names = 'OTHER MY_AGENT_JOB' }
        }
    ) {
        if ($names) { $env:OPENBAO_AGENT_JOB_VARS = $names }
        [Environment]::SetEnvironmentVariable($var, '1')
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $TestDrive -Arguments @($action, '--file', (Join-Path $TestDrive 'x'), '--server', '') }
        $r.Rc | Should -Be 3
        $r.Err | Should -Match "keyfile:$action refuses inside an agent's job \($var is set on this workstation\)"
        Should -Invoke -ModuleName DevcontainerCli Get-OpenBaoContainer -Times 0 -Exactly
    }

    It 'forget is not an agent-guarded task (it reveals nothing)' {
        $env:CLAUDECODE = '1'
        Mock -ModuleName DevcontainerCli Find-OpenBaoKeyFile { }
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $TestDrive -Arguments @('forget', '--server', '') }
        $r.Rc | Should -Be 0
        $r.Host | Should -Match 'nothing to forget'
    }
}

Describe 'keyfile:create and keyfile:rotate' -Skip:(-not $script:HasBash -or $IsWindows) {
    BeforeEach {
        $script:W = Initialize-World; Use-ProtectorStandIn
        $kf = [ordered]@{ v = 1; server = 'clu-1'; repo = 'myrepo'; created = '2026-11-05T10:00:00Z'; shares = @('NEW-4', 'NEW-5'); role_id = 'role-abc'; secret_id = 'NEW-SECRET' }
        $env:FAKE_MAKE_OUT = ConvertTo-Json -Compress -Depth 4 -InputObject ([ordered]@{ v = 1; ok = $true; pending = $true; server = 'clu-1'; nonce = 'nonce-1'; custody = @('CUSTODY-1', 'CUSTODY-2', 'CUSTODY-3'); keyfile = $kf; warnings = @('the old userpass login stays until confirm') })
        $script:Typed = [System.Collections.Generic.Queue[string]]::new()
        Mock -ModuleName DevcontainerCli Read-Host { Secure $script:Typed.Dequeue() }
        # The custody shares' printing goes into the stub's call log, so the order of the two is visible.
        Mock -ModuleName DevcontainerCli Write-OpenBaoCustodyShare { Add-Content -LiteralPath $env:FAKE_ARGV -Value ('CUSTODY PRINTED ' + ($Shares -join ' ')) }
        function Get-KeyFilePlain { InModuleScope DevcontainerCli { [Text.Encoding]::UTF8.GetString((Read-OpenBaoKeyFile -Path (Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1'))) } }
        function Get-Call { @((Get-Log $script:W.Argv) -split "`n" | Where-Object { $_ } | ForEach-Object { $_ -replace '^exec -i -u vscode cid1 /usr/local/bin/openbao-setup ', '' }) }
    }
    AfterEach { Clear-World $script:W }

    It 'create sends two typed custody shares on stdin, saves the key file and prints the custody shares once' {
        $script:Typed.Enqueue("$($script:Marker)-1"); $script:Typed.Enqueue("$($script:Marker)-2")
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Rc | Should -Be 0
        $sent = Get-Log $script:W.Stdin | ConvertFrom-Json
        $sent.v | Should -Be 1
        $sent.shares | Should -Be @("$($script:Marker)-1", "$($script:Marker)-2")
        $sent.repo | Should -Be 'myrepo'
        Get-Log $script:W.Argv | Should -Match 'exec -i -u vscode cid1 /usr/local/bin/openbao-setup keyfile create --stdin'
        Get-Log $script:W.Argv | Should -Not -Match $script:Marker
        Get-Log $script:W.EnvLog | Should -Not -Match $script:Marker
        @(Get-ChildItem -LiteralPath $script:W.Tmp -Force -Recurse) | Should -HaveCount 0
        Get-Call | Should -Contain 'CUSTODY PRINTED CUSTODY-1 CUSTODY-2 CUSTODY-3'
        $r.Host | Should -Not -Match 'NEW-4|NEW-SECRET'
        $path = InModuleScope DevcontainerCli { Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1' }
        $path | Should -Exist
        [IO.File]::ReadAllText($path) | Should -Not -Match 'NEW-4|NEW-SECRET'
        $plain = InModuleScope DevcontainerCli -Parameters @{ P = $path } { param($P) [Text.Encoding]::UTF8.GetString((Read-OpenBaoKeyFile -Path $P)) }
        $plain | Should -Be '{"v":1,"server":"clu-1","repo":"myrepo","created":"2026-11-05T10:00:00Z","shares":["NEW-4","NEW-5"],"role_id":"role-abc","secret_id":"NEW-SECRET"}'
    }

    It 'create on an uninitialised server asks nothing and sends init' {
        $env:FAKE_STATUS = Get-Status -Initialized $false -Server ''
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Rc | Should -Be 0
        Should -Invoke -ModuleName DevcontainerCli Read-Host -Times 0 -Exactly
        Get-Log $script:W.Stdin | Should -Be '{"v":1,"init":true,"repo":"myrepo"}'
    }

    It 'rotate with this server''s key file types nothing and sends its own shares' {
        Save-TestKeyFile
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('rotate') }
        $r.Rc | Should -Be 0
        Should -Invoke -ModuleName DevcontainerCli Read-Host -Times 0 -Exactly
        (Get-Log $script:W.Stdin | ConvertFrom-Json).shares | Should -Be @("$($script:Marker)-4", "$($script:Marker)-5")
        Get-Log $script:W.Argv | Should -Match 'keyfile rotate --stdin'
        $plain = InModuleScope DevcontainerCli { [Text.Encoding]::UTF8.GetString((Read-OpenBaoKeyFile -Path (Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1'))) }
        $plain | Should -Match '"shares":\["NEW-4","NEW-5"\]'
    }

    It 'refuses the same share twice before sending anything' {
        $script:Typed.Enqueue('same'); $script:Typed.Enqueue('same')
        { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') } | Should -Throw '*same share twice*'
        Get-Log $script:W.Argv | Should -Not -Match 'keyfile create'
    }

    It 'saves nothing when the container fails, and passes its exit code on' {
        $script:Typed.Enqueue('a'); $script:Typed.Enqueue('b')
        $env:FAKE_MAKE_OUT = '{"v":1,"ok":false,"error":"those shares do not open this server"}'
        $env:FAKE_MAKE_RC = '1'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Rc | Should -Be 1
        $r.Err | Should -Match 'keyfile:create failed: those shares do not open this server'
        InModuleScope DevcontainerCli { Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1' } | Should -Not -Exist
    }

    It 'refuses when the Feature is not in keyfile mode' {
        $env:FAKE_STATUS = Get-Status -Mode 'operator'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Rc | Should -Be 4
        $r.Err | Should -Match 'unlock: keyfile'
        Should -Invoke -ModuleName DevcontainerCli Read-Host -Times 0 -Exactly
    }

    It 'saves the key file, then confirms with shares 4 and 5 read back from it, then prints the custody shares' {
        $script:Typed.Enqueue('a'); $script:Typed.Enqueue('b')
        $env:FAKE_KEYFILE = InModuleScope DevcontainerCli { Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1' }
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Rc | Should -Be 0
        Get-Call | Should -Be @('unlock --status', 'keyfile create --stdin', 'keyfile confirm --stdin', 'key file on disk at confirm', 'CUSTODY PRINTED CUSTODY-1 CUSTODY-2 CUSTODY-3')
        (Get-Log "$($script:W.Stdin).confirm").Trim() | Should -Be '{"v":1,"server":"clu-1","nonce":"nonce-1","shares":["NEW-4","NEW-5"]}'
        Get-Log $script:W.Argv | Should -Not -Match 'NEW-4'
        # FAKE_MAKE_OUT is the stub's own scripted answer; nothing else in the environment may hold a share.
        @((Get-Log $script:W.EnvLog) -split "`n" | Where-Object { $_ -notlike 'FAKE_MAKE_OUT=*' }) -join "`n" | Should -Not -Match 'NEW-4'
        @(Get-ChildItem -LiteralPath $script:W.Tmp -Force -Recurse) | Should -HaveCount 0
    }

    It 'shows the warnings of create and of confirm' {
        $script:Typed.Enqueue('a'); $script:Typed.Enqueue('b')
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Host | Should -Match 'openbao: warning: the old userpass login stays until confirm'
        $r.Host | Should -Match 'openbao: warning: the backup went to the default destination'
    }

    It 'a failed save cancels the rotation, keeps the previous key file and prints no custody share' {
        Save-TestKeyFile
        $before = Get-KeyFilePlain
        Mock -ModuleName DevcontainerCli Protect-OpenBaoKeyFileBlob { throw 'disk full' }
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('rotate') }
        $r.Rc | Should -Be 1
        $r.Err | Should -Match 'could not be saved \(disk full\); cancelling'
        $r.Err | Should -Match 'cancelled; the old shares still unseal'
        Get-Call | Should -Be @('unlock --status', 'keyfile rotate --stdin', 'keyfile cancel --stdin')
        (Get-Log "$($script:W.Stdin).cancel") | Should -Be '{"v":1,"server":"clu-1"}'
        Get-KeyFilePlain | Should -Be $before
    }

    It 'a failed confirm cancels, puts the previous key file back and prints no custody share' {
        Save-TestKeyFile
        $before = Get-KeyFilePlain
        $env:FAKE_CONFIRM = 'fail'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('rotate') }
        $r.Rc | Should -Be 1
        $r.Err | Should -Match 'was not confirmed: the shares do not verify'
        Get-Call | Should -Be @('unlock --status', 'keyfile rotate --stdin', 'keyfile confirm --stdin', 'keyfile cancel --stdin')
        Get-KeyFilePlain | Should -Be $before
    }

    It 'a failed confirm on create removes the new key file' {
        $script:Typed.Enqueue('a'); $script:Typed.Enqueue('b')
        $env:FAKE_CONFIRM = 'fail'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Rc | Should -Be 1
        InModuleScope DevcontainerCli { Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1' } | Should -Not -Exist
        Get-Call | Should -Not -Match 'CUSTODY PRINTED'
    }

    It 'a lost confirm answer is asked once more (confirm is idempotent)' {
        $script:Typed.Enqueue('a'); $script:Typed.Enqueue('b')
        $env:FAKE_CONFIRM = 'lost-once'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Rc | Should -Be 0
        Get-Call | Should -Be @('unlock --status', 'keyfile create --stdin', 'keyfile confirm --stdin', 'keyfile confirm --stdin', 'CUSTODY PRINTED CUSTODY-1 CUSTODY-2 CUSTODY-3')
    }

    It 'confirm answers lost twice: keyfile status showing five shares means it took effect' {
        $script:Typed.Enqueue('a'); $script:Typed.Enqueue('b')
        $env:FAKE_CONFIRM = 'lost'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Rc | Should -Be 0
        $r.Host | Should -Match "the confirm's answer was lost .* the rotation took effect"
        Get-Call | Should -Be @('unlock --status', 'keyfile create --stdin', 'keyfile confirm --stdin', 'keyfile confirm --stdin', 'keyfile status', 'CUSTODY PRINTED CUSTODY-1 CUSTODY-2 CUSTODY-3')
        Get-KeyFilePlain | Should -Match '"shares":\["NEW-4","NEW-5"\]'
    }

    It 'confirm answers lost twice and keyfile status does not show the new shares: cancel, no custody share' {
        $script:Typed.Enqueue('a'); $script:Typed.Enqueue('b')
        $env:FAKE_CONFIRM = 'lost'
        $env:FAKE_KF_STATUS = '{"v":1,"ok":true,"server":"clu-1","shares":3,"threshold":2,"approle":false,"userpass":true}'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Rc | Should -Be 1
        Get-Call | Should -Be @('unlock --status', 'keyfile create --stdin', 'keyfile confirm --stdin', 'keyfile confirm --stdin', 'keyfile status', 'keyfile cancel --stdin')
        InModuleScope DevcontainerCli { Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1' } | Should -Not -Exist
    }

    It 'an answer without a pending rotation saves nothing and cancels' {
        $script:Typed.Enqueue('a'); $script:Typed.Enqueue('b')
        $env:FAKE_MAKE_OUT = '{"v":1,"ok":true,"server":"clu-1","custody":["C1","C2","C3"],"keyfile":{}}'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Rc | Should -Be 1
        Get-Call | Should -Be @('unlock --status', 'keyfile create --stdin', 'keyfile cancel --stdin')
        InModuleScope DevcontainerCli { Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1' } | Should -Not -Exist
    }

    It 'a failure reads error, then code' {
        $script:Typed.Enqueue('a'); $script:Typed.Enqueue('b')
        $env:FAKE_MAKE_OUT = '{"v":1,"ok":false,"code":"sealed"}'
        $env:FAKE_MAKE_RC = '1'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('create') }
        $r.Err | Should -Match 'keyfile:create failed: sealed\.'
    }
}

Describe 'keyfile:export, :import and :forget' {
    BeforeEach {
        $script:W = Initialize-World; Use-ProtectorStandIn
        $script:Out = Join-Path $script:W.T 'carry'
        New-Item -ItemType Directory -Path $script:Out | Out-Null
    }
    AfterEach { Clear-World $script:W }

    It 'export then import round-trips through a one-time passphrase and deletes the transfer file' {
        Save-TestKeyFile
        $file = Join-Path $script:Out 'myrepo.transfer'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('export', '--file', $file, '--server', '') }
        $r.Rc | Should -Be 0
        $file | Should -Exist
        [IO.File]::ReadAllText($file) | Should -Not -Match $script:Marker
        $script:Pass = [regex]::Match($r.Host, 'passphrase, shown this once: (\S+)').Groups[1].Value
        $script:Pass | Should -Match '^[A-Z2-9]{4}(-[A-Z2-9]{4}){7}$'
        @(Get-ChildItem -LiteralPath $script:W.Tmp -Force -Recurse) | Should -HaveCount 0

        $before = InModuleScope DevcontainerCli { [Text.Encoding]::UTF8.GetString((Read-OpenBaoKeyFile -Path (Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1'))) }
        Remove-Item -LiteralPath (InModuleScope DevcontainerCli { Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1' })
        Mock -ModuleName DevcontainerCli Read-Host { Secure ($script:Pass.ToLowerInvariant() -replace '-', ' ') }
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('import', '--file', $file) }
        $r.Rc | Should -Be 0
        $file | Should -Not -Exist
        $after = InModuleScope DevcontainerCli { [Text.Encoding]::UTF8.GetString((Read-OpenBaoKeyFile -Path (Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1'))) }
        $after | Should -Be $before
    }

    It 'import with a wrong passphrase changes nothing and keeps the file' {
        Save-TestKeyFile
        $file = Join-Path $script:Out 'myrepo.transfer'
        [void](Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('export', '--file', $file, '--server', '') })
        Remove-Item -LiteralPath (InModuleScope DevcontainerCli { Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1' })
        Mock -ModuleName DevcontainerCli Read-Host { Secure 'AAAA-BBBB' }
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('import', '--file', $file) }
        $r.Rc | Should -Be 1
        $r.Err | Should -Match 'passphrase is wrong or the file is damaged'
        $file | Should -Exist
        InModuleScope DevcontainerCli { Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1' } | Should -Not -Exist
    }

    It 'import refuses when this workstation has a key file for that server' {
        Save-TestKeyFile
        $file = Join-Path $script:Out 'myrepo.transfer'
        [void](Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('export', '--file', $file, '--server', '') })
        Mock -ModuleName DevcontainerCli Read-Host { throw 'no prompt expected' }
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('import', '--file', $file) }
        $r.Rc | Should -Be 1
        $r.Err | Should -Match 'keyfile:forget SERVER=clu-1 first'
    }

    It 'export refuses a file inside the checkout and one that exists' {
        Save-TestKeyFile
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('export', '--file', (Join-Path $script:W.Ws 'kf.transfer'), '--server', '') }
        $r.Rc | Should -Be 1
        $r.Err | Should -Match 'inside the checkout'
        Join-Path $script:W.Ws 'kf.transfer' | Should -Not -Exist
        $taken = Join-Path $script:Out 'taken'
        Set-Content -LiteralPath $taken -Value 'x'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('export', '--file', $taken, '--server', '') }
        $r.Rc | Should -Be 1
        $r.Err | Should -Match 'exists'
    }

    It 'export asks for SERVER when there are key files for several servers' {
        Save-TestKeyFile -Server 'clu-1'
        Save-TestKeyFile -Server 'clu-2'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('export', '--file', (Join-Path $script:Out 'f'), '--server', '') }
        $r.Rc | Should -Be 1
        $r.Err | Should -Match 'SERVER=<cluster id>'
        $r = Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('export', '--file', (Join-Path $script:Out 'f'), '--server', 'clu-2') }
        $r.Rc | Should -Be 0
    }

    It 'forget deletes the key file after y, and keeps it otherwise' {
        Save-TestKeyFile
        $path = InModuleScope DevcontainerCli { Get-OpenBaoKeyFilePath -Repo 'myrepo' -Server 'clu-1' }
        Mock -ModuleName DevcontainerCli Read-Host { 'n' }
        (Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('forget', '--server', '') }).Rc | Should -Be 1
        $path | Should -Exist
        Mock -ModuleName DevcontainerCli Read-Host { 'y' }
        (Invoke-Captured { Invoke-OpenBaoKeyFileTask -WorkspaceFolder $script:W.Ws -Arguments @('forget', '--server', '') }).Rc | Should -Be 0
        $path | Should -Not -Exist
    }
}

Describe 'Where the key file lives' {
    It 'is its own folder, not the launcher''s download cache' {
        $dir = Get-OpenBaoKeyFileDir
        $dir | Should -Match 'devcontainer-features-keys[\\/]openbao$'
        $dir.StartsWith((Get-LauncherCacheRoot) + [IO.Path]::DirectorySeparatorChar) | Should -BeFalse
    }

    It 'names the file after the repository and the cluster id' {
        Split-Path -Leaf (Get-OpenBaoKeyFilePath -Repo 'my repo' -Server 'abc/123') | Should -Be 'my_repo-abc_123.keyfile'
    }
}

Describe 'The DPAPI round trip (Windows only)' -Skip:(-not $IsWindows) {
    BeforeEach {
        $script:SavedLad = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $TestDrive 'lad'
    }
    AfterEach { $env:LOCALAPPDATA = $script:SavedLad }

    It 'saves with DPAPI and reads the same bytes back' {
        $json = [Text.Encoding]::UTF8.GetBytes((Get-KeyFileJson))
        $path = Save-OpenBaoKeyFile -Repo 'myrepo' -Server 'clu-1' -Json $json
        $path | Should -BeLike "$env:LOCALAPPDATA\devcontainer-features-keys\openbao\myrepo-clu-1.keyfile"
        [IO.File]::ReadAllText($path) | Should -Not -Match $script:Marker
        [Text.Encoding]::UTF8.GetString((Read-OpenBaoKeyFile -Path $path)) | Should -Be (Get-KeyFileJson)
    }

    It 'does not open with another entropy (another program''s blob for this account)' {
        $blob = Protect-OpenBaoKeyFileBlob -Bytes ([Text.Encoding]::UTF8.GetBytes('x'))
        { [System.Security.Cryptography.ProtectedData]::Unprotect($blob, [byte[]]@(1, 2, 3), [System.Security.Cryptography.DataProtectionScope]::CurrentUser) } | Should -Throw
    }
}

Describe 'The bash launcher refuses the OpenBao key file in one line' -Skip:(-not $script:HasBash) {
    It '<sub> exits 1 with one line' -ForEach @(@{ sub = 'openbao-unlock' }, @{ sub = 'openbao-keyfile' }) {
        $cli = Join-Path $script:Root 'src/devcontainer-cli/devcontainer-cli.sh'
        $err = & bash $cli run $sub --workspace-folder $TestDrive -- create 2>&1
        $LASTEXITCODE | Should -Be 1
        @($err) | Should -HaveCount 1
        "$err" | Should -Be 'devcontainer-cli: the OpenBao key file is Windows-only for now; here unseal OpenBao in the container with two custody shares (task openbao:unseal).'
    }
}
