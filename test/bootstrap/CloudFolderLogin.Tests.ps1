# Pester 5+ tests of the Windows launcher's cloud-folder login (bootstrap/host/DevcontainerCli.psm1,
# Invoke-CloudFolderLogin, behind task cloud-folder:login on a Windows workstation), the counterpart of
# test/bootstrap/cloud_folder_login_test.sh. The launcher runs as a child pwsh (Invoke-DevcontainerCli.ps1
# -Subcommand cloud-folder-login); the "container" is this machine: a stub `devcontainer` runs the
# exec'd command here, a stub `docker` answers `ps` with one id and runs `exec -i <id> bash -c` here, so
# the real cloud-folder-setup signs in against the fake rclone authorize
# (test/cloud-folder/unit/fake_authorize.py), and a "browser" (Python's urllib, DCF_BROWSER) goes through the
# listener. Covered: the relay (the browser at the rewritten link, each request through docker exec and
# /dev/tcp, the token in the volume), the listener closed after success, failure and timeout, the busy
# port taking the paste route, no container, --workstation-rclone (download from a local server through
# Invoke-DcfDownload, SHA256SUMS saved and read as text, verified, cached, a wrong digest refused, the
# token to `login --token` on stdin), and the default pin equal to the Feature's. The stubs are shell
# scripts, so these run where bash runs (Linux, macOS; CI).

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:Entry = Join-Path $script:Root 'bootstrap/host/Invoke-DevcontainerCli.ps1'
    $script:FakePy = Join-Path $script:Root 'test/cloud-folder/unit/fake_authorize.py'
    $script:Setup = Join-Path $script:Root 'src/cloud-folder/cloud-folder-setup.sh'
    $script:T = Join-Path ([IO.Path]::GetTempPath()) "dcf-cfl-$([guid]::NewGuid().ToString('N'))"
    $script:Bin = Join-Path $script:T 'bin'
    $script:Ws = Join-Path $script:T 'ws'
    $script:State = Join-Path $script:T 'state'
    $script:Secret = 'SECRETTOKENMARKER-p5h3'
    $script:Token = '{"access_token":"' + $script:Secret + '","token_type":"Bearer","expiry":"2099-01-01T00:00:00Z"}'
    New-Item -ItemType Directory -Path $script:Bin, (Join-Path $script:Ws '.devcontainer') -Force | Out-Null
    Set-Content (Join-Path $script:Ws '.devcontainer/devcontainer.json') '{ "features": { "ghcr.io/nabil-becker/devcontainer-features/cloud-folder:1": {} } }'

    function Write-StubFile([string]$Name, [string]$Text) {
        $p = Join-Path $script:Bin $Name
        [IO.File]::WriteAllText($p, $Text.Replace("`r`n", "`n"))
        & chmod +x $p
    }
    Write-StubFile devcontainer @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
[ "$1" = exec ] || exit 0
shift
while [ $# -gt 0 ]; do case "$1" in --workspace-folder | --docker-path) shift 2 ;; *) break ;; esac; done
exec "$@"
'@
    Write-StubFile docker @'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
case "$1" in
  ps) [ "${FAKE_RUNNING:-1}" = 1 ] && echo cid1; exit 0 ;;
  exec) [ "$2" = -i ] && [ "$3" = cid1 ] || exit 125; shift 3; exec "$@" ;;
esac
exit 0
'@
    Write-StubFile cloud-folder-setup "#!/bin/sh`nexec bash '$($script:Setup)' `"`$@`"`n"
    Write-StubFile rclone @"
#!/usr/bin/env bash
printf '%s\n' "`$*" >> "`$STUB_CALLS"
case "`$1" in
  version) echo 'rclone v1.75.2'; exit 0 ;;
  authorize) exec python3 -I '$($script:FakePy)' "`$@" ;;
  lsjson) echo '{}'; exit 0 ;;
  config) printf '{\n\t"State": "",\n\t"Option": null,\n\t"Error": "",\n\t"Result": ""\n}\n'; exit 0 ;;
esac
exit 2
"@
    Write-StubFile browser @'
#!/usr/bin/env bash
echo "$1" >> "$BROWSER_LOG"
python3 -I -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=20).read()' "$1" 2>/dev/null; echo "rc=$?" >> "$BROWSER_LOG"
'@

    function Get-FreePort {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p
    }
    function Test-PortFree([int]$Port) {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        try { $l.Start(); $l.Stop(); $true } catch { $false }
    }
    $script:L = Get-FreePort
    $script:C = Get-FreePort

    # Runs the launcher; returns @{ Code; Out }. $Env adds to (or, with $null, removes from) the environment.
    function Invoke-Launcher {
        param([hashtable]$Env = @{}, [string[]]$Arguments = @(), [string]$Stdin = '')
        $calls = Join-Path $script:T 'calls'; $blog = Join-Path $script:T 'browser.log'; $alog = Join-Path $script:T 'auth.log'
        foreach ($f in $calls, $blog, $alog) { Set-Content -LiteralPath $f -Value $null }
        $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -InputObject @($Arguments))))
        foreach ($a in @('-NoLogo', '-NoProfile', '-File', $script:Entry, '-Subcommand', 'cloud-folder-login', '-WorkspaceFolder', $script:Ws, '-CliArgsB64', $b64)) { $psi.ArgumentList.Add($a) }
        $vars = @{
            PATH = "$($script:Bin):$env:PATH"; HOME = $script:T; XDG_CACHE_HOME = (Join-Path $script:T 'cache')
            STUB_CALLS = $calls; BROWSER_LOG = $blog; DCF_BROWSER = (Join-Path $script:Bin 'browser')
            HOST_TYPE = 'linux'; HOST_MOUNTS = 'false'; DEVCONTAINER_DOCKER_PATH = ''
            DCF_CLOUD_FOLDER_LOGIN_PORT = "$($script:L)"; DCF_CLOUD_FOLDER_LOGIN_CONTAINER_PORT = "$($script:C)"
            FAKE_AUTH_PORT = "$($script:C)"; FAKE_AUTH_BACK = "http://127.0.0.1:$($script:L)/"; FAKE_AUTH_STATE = 'teststate'
            FAKE_AUTH_TOKEN = $script:Token; FAKE_AUTH_LOG = $alog
            DCF_CLOUD_FOLDER_STATE_DIR = $script:State; CLOUD_FOLDER_REMOTE_TYPE = 'onedrive'; CLOUD_FOLDER_MODE = 'sync'
            CLOUD_FOLDER_MOUNT_POINT = (Join-Path $script:T 'cloud folder'); CLOUD_FOLDER_SYNC_INTERVAL = '0'
            DCF_CLOUD_FOLDER_FUSE_DEV = (Join-Path $script:T 'no-fuse')
        }
        foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
        foreach ($k in $vars.Keys) { if ($null -eq $vars[$k]) { [void]$psi.Environment.Remove($k) } else { $psi.Environment[$k] = $vars[$k] } }
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $err = $p.StandardError.ReadToEndAsync()
        $p.StandardInput.Write($Stdin)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        $all = $out + $err.Result
        Add-Content -LiteralPath (Join-Path $script:T 'all-output') -Value $all
        @{ Code = $p.ExitCode; Out = $all }
    }
    function Get-Log([string]$Name) { $f = Join-Path $script:T $Name; if (Test-Path $f) { (Get-Content -Raw -LiteralPath $f) ?? '' } else { '' } }
    function Clear-ConfFile { Remove-Item -LiteralPath (Join-Path $script:State 'rclone.conf') -ErrorAction SilentlyContinue }
}

AfterAll {
    Get-Process python3 -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*fake_authorize.py*" } | Stop-Process -ErrorAction SilentlyContinue
    if ($script:Server -and -not $script:Server.HasExited) { $script:Server.Kill() }
    Remove-Item -LiteralPath $script:T -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'cloud-folder login: the relay' -Skip:$IsWindows {
    It 'signs in through the workstation listener and closes it after success' {
        Clear-ConfFile
        $r = Invoke-Launcher
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match "relaying 127.0.0.1:$($script:L) on this workstation into the devcontainer"
        @((Get-Log 'browser.log') -split "`n")[0] | Should -Be "http://127.0.0.1:$($script:L)/auth?state=teststate"
        Get-Log 'browser.log' | Should -Match 'rc=0'
        Get-Log 'auth.log' | Should -Match ([regex]::Escape('/?code=fakecode&state=teststate'))
        Get-Log 'calls' | Should -Match ([regex]::Escape("exec -i cid1 bash -c exec 3<>/dev/tcp/127.0.0.1/$($script:C)"))
        Get-Log 'calls' | Should -Match 'cloud-folder-setup login --relay'
        Get-Content -Raw (Join-Path $script:State 'rclone.conf') | Should -Match $script:Secret
        Test-PortFree $script:L | Should -BeTrue
        $r.Out | Should -Match "the relay on 127.0.0.1:$($script:L) is closed"
    }
    It 'closes the listener after a failed sign-in' {
        Clear-ConfFile
        $r = Invoke-Launcher -Env @{ FAKE_AUTH_FAIL = '1' }
        $r.Code | Should -Not -Be 0
        $r.Out | Should -Match 'rclone authorize failed'
        Test-PortFree $script:L | Should -BeTrue
    }
    It 'closes the listener after the timeout' {
        Clear-ConfFile
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Launcher -Env @{ DCF_BROWSER = 'true'; CLOUD_FOLDER_LOGIN_TIMEOUT = '2' }
        $watch.Stop()
        $r.Code | Should -Not -Be 0
        $r.Out | Should -Match 'no sign-in within 2s'
        Test-PortFree $script:L | Should -BeTrue
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 20
        Test-Path (Join-Path $script:State 'rclone.conf') | Should -BeFalse
    }
    It 'takes the paste route when the port is busy' {
        $block = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $script:L)
        $block.Start()
        try { $r = Invoke-Launcher -Stdin "http://localhost:53682/?code=pasted&state=teststate`n" }
        finally { $block.Stop() }
        $r.Out | Should -Match "port $($script:L) on this workstation is in use"
        Get-Log 'browser.log' | Should -BeNullOrEmpty
        Get-Log 'calls' | Should -Not -Match 'login --relay'
        Get-Log 'calls' | Should -Match 'cloud-folder-setup login'
    }
    It 'refuses without a running container' {
        $r = Invoke-Launcher -Env @{ FAKE_RUNNING = '0' }
        $r.Code | Should -Not -Be 0
        $r.Out | Should -Match 'task dc:start'
    }
}

Describe 'cloud-folder login: --workstation-rclone' -Skip:$IsWindows {
    BeforeAll {
        $os = if ($IsMacOS) { 'osx' } else { 'linux' }
        $arch = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }
        $script:Asset = "rclone-v1.75.2-$os-$arch.zip"
        $files = Join-Path $script:T 'srv/files/v1.75.2'
        $inner = Join-Path $script:T "zip/rclone-v1.75.2-$os-$arch"
        New-Item -ItemType Directory -Path $files, $inner -Force | Out-Null
        $wsLog = Join-Path $script:T 'ws-rclone.log'
        [IO.File]::WriteAllText((Join-Path $inner 'rclone'), "#!/usr/bin/env bash`necho `"workstation-rclone `$*`" >> '$wsLog'`necho 'NOTICE: go to the following link: http://127.0.0.1:53682/auth?state=x' >&2`nprintf 'Paste the following into your remote machine --->\n%s\n<---End paste\n' '$($script:Token)'`n")
        & chmod +x (Join-Path $inner 'rclone')
        & python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1], "w").write(sys.argv[2], sys.argv[3])' (Join-Path $files $script:Asset) (Join-Path $inner 'rclone') "rclone-v1.75.2-$os-$arch/rclone"
        $script:Sha = (Get-FileHash (Join-Path $files $script:Asset) -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:SumsFile = Join-Path $files 'SHA256SUMS'
        Set-Content $script:SumsFile "-----BEGIN PGP SIGNED MESSAGE-----`nHash: SHA1`n`n$('0' * 64)  rclone-v1.75.2-windows-amd64.zip`n$($script:Sha)  $($script:Asset)`n-----BEGIN PGP SIGNATURE-----"
        $psi = [System.Diagnostics.ProcessStartInfo]::new('python3')
        foreach ($a in @('-I', (Join-Path $PSScriptRoot 'flaky_server.py'), 'reset', (Join-Path $script:T 'srv/files'))) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $script:Server = [System.Diagnostics.Process]::Start($psi)
        $script:Base = "http://127.0.0.1:$($script:Server.StandardOutput.ReadLine())"
        $script:Cached = Join-Path $script:T 'cache/devcontainer-features/rclone/v1.75.2/rclone'
    }
    It 'downloads the pinned rclone, verified and cached, and hands its token to login --token' {
        Clear-ConfFile
        $r = Invoke-Launcher -Env @{ DCF_RCLONE_DOWNLOADS = $script:Base } -Arguments @('--workstation-rclone')
        $r.Code | Should -Be 0 -Because $r.Out
        $r.Out | Should -Match ([regex]::Escape("downloading rclone v1.75.2 ($($script:Asset)"))
        Test-Path $script:Cached | Should -BeTrue
        Get-Log 'ws-rclone.log' | Should -Match 'workstation-rclone authorize onedrive'
        Get-Log 'calls' | Should -Match 'cloud-folder-setup login --token'
        Get-Log 'calls' | Should -Not -Match 'auth-no-open-browser'
        Get-Content -Raw (Join-Path $script:State 'rclone.conf') | Should -Match $script:Secret
    }
    It 'uses the cache the second time' {
        Set-Content (Join-Path $script:T 'srv/requests.log') $null
        $r = Invoke-Launcher -Env @{ DCF_RCLONE_DOWNLOADS = $script:Base } -Arguments @('--workstation-rclone')
        $r.Code | Should -Be 0 -Because $r.Out
        Get-Log 'srv/requests.log' | Should -BeNullOrEmpty
    }
    It 'refuses a download whose digest does not match' {
        Remove-Item (Split-Path $script:Cached) -Recurse -Force
        Set-Content $script:SumsFile "$('0' * 64)  $($script:Asset)"
        $r = Invoke-Launcher -Env @{ DCF_RCLONE_DOWNLOADS = $script:Base } -Arguments @('--workstation-rclone')
        $r.Code | Should -Not -Be 0
        $r.Out | Should -Match 'SHA-256 mismatch'
        Test-Path $script:Cached | Should -BeFalse
    }
    It 'pins the same rclone as the Feature' {
        $feature = Get-Content -Raw (Join-Path $script:Root 'src/cloud-folder/devcontainer-feature.json') | ConvertFrom-Json
        $module = Get-Content -Raw (Join-Path $script:Root 'bootstrap/host/DevcontainerCli.psm1')
        [regex]::Match($module, "CloudFolderRcloneDefault = '([^']+)'").Groups[1].Value | Should -Be $feature.options.rcloneVersion.default
    }
    It 'never shows the token' {
        Get-Log 'all-output' | Should -Not -Match $script:Secret
        Get-Log 'calls' | Should -Not -Match $script:Secret
    }
}
