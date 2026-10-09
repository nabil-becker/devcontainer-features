@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Write-Host is the intended user-facing output in these task scripts.
        'PSAvoidUsingWriteHost'
    )
}
