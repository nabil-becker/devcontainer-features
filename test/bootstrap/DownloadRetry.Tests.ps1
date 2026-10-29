# Pester 5+ tests of Invoke-DcfDownload (bootstrap/host/DevcontainerCli.psm1; bootstrap/bootstrap.ps1 inlines
# the same function, extracted here by name) against a local server (test/bootstrap/flaky_server.py) whose
# first connection fails. Invoke-WebRequest's own -MaximumRetryCount retries only HTTP statuses, never a
# reset or a cut transfer, hence the wrapper. TLS errors are not testable locally.

BeforeAll {
    $script:Server = Join-Path $PSScriptRoot 'flaky_server.py'
    $script:Wrappers = @{
        module    = (Get-Content (Join-Path $PSScriptRoot '../../bootstrap/host/DevcontainerCli.psm1') -Raw)
        bootstrap = (Get-Content (Join-Path $PSScriptRoot '../../bootstrap/bootstrap.ps1') -Raw)
    }
    function Get-WrapperSource([string]$Text) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$null)
        $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-DcfDownload' }, $true).Extent.Text
    }
    function Invoke-Download {
        param([string]$Mode, [string]$Source = 'module')
        $psi = [System.Diagnostics.ProcessStartInfo]::new('python3')
        foreach ($a in @('-I', $script:Server, $Mode)) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = Join-Path ([IO.Path]::GetTempPath()) "dcf-dl-$([guid]::NewGuid().ToString('N'))"
        try {
            $port = $proc.StandardOutput.ReadLine()
            . ([scriptblock]::Create((Get-WrapperSource $script:Wrappers[$Source])))
            try {
                Invoke-DcfDownload -Uri "http://127.0.0.1:$port/f" -OutFile $out -RetryIntervalSec 1
                (Get-Item $out).Length
            }
            catch { -1 }
        }
        finally {
            if (-not $proc.HasExited) { $proc.Kill() }
            Remove-Item $out -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-DcfDownload (<_>)' -ForEach @('module', 'bootstrap') {
    It 'gets the whole file after an HTTP 503' {
        Invoke-Download -Mode 503 -Source $_ | Should -Be 200000
    }
    It 'gets the whole file after a connection reset' {
        Invoke-Download -Mode reset -Source $_ | Should -Be 200000
    }
    It 'gets the whole file after a transfer cut mid-body' {
        Invoke-Download -Mode cut -Source $_ | Should -Be 200000
    }
}

Describe 'Invoke-WebRequest alone' {
    It 'does not survive a reset or a cut, which is why the wrapper exists' {
        foreach ($mode in 'reset', 'cut') {
            $psi = [System.Diagnostics.ProcessStartInfo]::new('python3')
            foreach ($a in @('-I', $script:Server, $mode)) { $psi.ArgumentList.Add($a) }
            $psi.RedirectStandardOutput = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            try {
                $port = $proc.StandardOutput.ReadLine()
                { Invoke-WebRequest -UseBasicParsing -MaximumRetryCount 3 -RetryIntervalSec 1 -TimeoutSec 8 -Uri "http://127.0.0.1:$port/f" -OutFile (Join-Path ([IO.Path]::GetTempPath()) 'dcf-dl-plain') } | Should -Throw
            }
            finally { $proc.Kill() }
        }
    }
}
