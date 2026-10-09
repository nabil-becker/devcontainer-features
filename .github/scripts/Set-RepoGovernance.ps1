<#
.SYNOPSIS
    Applies this repository's governance settings on GitHub with the gh CLI:
    security features, merge policy, Actions permissions, a 'release'
    environment, and a ruleset protecting the default branch. Idempotent -
    re-run after changing it. Run as a repo admin: `task repo:govern`.

.DESCRIPTION
    What it configures (and why):
      - Private vulnerability reporting, Dependabot alerts + security
        updates, secret scanning + push protection: public collaboration
        without leaking credentials or shipping known-vulnerable actions.
      - Squash-only merges, delete branch on merge: linear, reviewable
        history on main.
      - Actions: only GitHub-owned actions plus devcontainers/action; default
        GITHUB_TOKEN read-only; Actions may create PRs (the release workflow
        opens the generated-docs PR); fork PR workflows need approval from a
        maintainer for first-time contributors.
      - 'release' environment (required by release.yaml) restricted to the
        default branch - the only place the packages:write token exists.
      - Ruleset 'protect-main': no deletion/force-push, linear history, PRs
        required with 1 approval incl. code owners, stale reviews dismissed,
        conversations resolved, required checks validate / lint / tests.
        Repo admins may bypass *only through a PR* (solo-maintainer escape
        hatch: own PRs can be merged without a second human).

.PARAMETER Repo
    owner/name. Defaults to the repo of the current directory.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Repo
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh CLI is required (winget install GitHub.cli) and must be logged in.' }
if (-not $Repo) { $Repo = gh repo view --json nameWithOwner -q .nameWithOwner }
Write-Host "Applying governance to $Repo"

function Invoke-Gh {
    param([string]$Method, [string]$Endpoint, [hashtable]$Body, [switch]$IgnoreError)
    $args = @('api', '-X', $Method, $Endpoint, '-H', 'Accept: application/vnd.github+json')
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        $args += @('--input', '-')
        $out = $json | gh @args 2>&1
    }
    else {
        $out = gh @args 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        if ($IgnoreError) { Write-Warning "$Method $Endpoint : $out"; return $null }
        throw "$Method $Endpoint failed: $out"
    }
    return $out
}

if ($PSCmdlet.ShouldProcess($Repo, 'repository settings')) {
    Invoke-Gh PATCH "repos/$Repo" @{
        allow_squash_merge          = $true
        allow_merge_commit          = $false
        allow_rebase_merge          = $false
        delete_branch_on_merge      = $true
        allow_update_branch         = $true
        squash_merge_commit_title   = 'PR_TITLE'
        squash_merge_commit_message = 'PR_BODY'
        has_wiki                    = $false
        security_and_analysis       = @{
            secret_scanning                 = @{ status = 'enabled' }
            secret_scanning_push_protection = @{ status = 'enabled' }
        }
    } | Out-Null
    Write-Host '  repository: squash-only merges, branch cleanup, secret scanning + push protection'

    Invoke-Gh PUT "repos/$Repo/private-vulnerability-reporting" | Out-Null
    Invoke-Gh PUT "repos/$Repo/vulnerability-alerts" | Out-Null
    Invoke-Gh PUT "repos/$Repo/automated-security-fixes" | Out-Null
    Write-Host '  security: private vulnerability reporting, Dependabot alerts + security updates'
}

if ($PSCmdlet.ShouldProcess($Repo, 'Actions permissions')) {
    Invoke-Gh PUT "repos/$Repo/actions/permissions" @{ enabled = $true; allowed_actions = 'selected' } | Out-Null
    Invoke-Gh PUT "repos/$Repo/actions/permissions/selected-actions" @{
        github_owned_allowed = $true
        verified_allowed     = $false
        patterns_allowed     = @('devcontainers/action@*')
    } | Out-Null
    Invoke-Gh PUT "repos/$Repo/actions/permissions/workflow" @{
        default_workflow_permissions     = 'read'
        can_approve_pull_request_reviews = $true
    } | Out-Null
    # Newer endpoint; tolerate absence on older GitHub versions.
    Invoke-Gh PUT "repos/$Repo/actions/permissions/fork-pr-contributor-approval" @{ approval_policy = 'first_time_contributors' } -IgnoreError | Out-Null
    Write-Host '  actions: GitHub-owned + devcontainers/action only, read-only token, PR creation allowed'
}

if ($PSCmdlet.ShouldProcess($Repo, "environment 'release'")) {
    Invoke-Gh PUT "repos/$Repo/environments/release" @{
        deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
    } | Out-Null
    $existing = Invoke-Gh GET "repos/$Repo/environments/release/deployment-branch-policies" | ConvertFrom-Json
    if (-not ($existing.branch_policies | Where-Object { $_.name -eq 'main' })) {
        Invoke-Gh POST "repos/$Repo/environments/release/deployment-branch-policies" @{ name = 'main'; type = 'branch' } | Out-Null
    }
    Write-Host "  environment 'release': deployable from main only"
}

if ($PSCmdlet.ShouldProcess($Repo, "ruleset 'protect-main'")) {
    $ruleset = @{
        name         = 'protect-main'
        target       = 'branch'
        enforcement  = 'active'
        conditions   = @{ ref_name = @{ include = @('~DEFAULT_BRANCH'); exclude = @() } }
        # RepositoryRole 5 = admin; bypass only via pull request.
        bypass_actors = @(@{ actor_id = 5; actor_type = 'RepositoryRole'; bypass_mode = 'pull_request' })
        rules        = @(
            @{ type = 'deletion' },
            @{ type = 'non_fast_forward' },
            @{ type = 'required_linear_history' },
            @{ type = 'pull_request'; parameters = @{
                    required_approving_review_count   = 1
                    dismiss_stale_reviews_on_push     = $true
                    require_code_owner_review         = $true
                    require_last_push_approval        = $false
                    required_review_thread_resolution = $true
                    allowed_merge_methods             = @('squash')
                } },
            @{ type = 'required_status_checks'; parameters = @{
                    strict_required_status_checks_policy = $true
                    do_not_enforce_on_create             = $true
                    required_status_checks               = @(
                        @{ context = 'validate' },
                        @{ context = 'lint' },
                        @{ context = 'tests' }
                    )
                } }
        )
    }
    $all = Invoke-Gh GET "repos/$Repo/rulesets" | ConvertFrom-Json
    $current = $all | Where-Object { $_.name -eq 'protect-main' } | Select-Object -First 1
    if ($current) {
        Invoke-Gh PUT "repos/$Repo/rulesets/$($current.id)" $ruleset | Out-Null
        Write-Host "  ruleset 'protect-main': updated (id $($current.id))"
    }
    else {
        $created = Invoke-Gh POST "repos/$Repo/rulesets" $ruleset | ConvertFrom-Json
        Write-Host "  ruleset 'protect-main': created (id $($created.id))"
    }
}

Write-Host @'
Done. Manual follow-ups GitHub does not expose via API:
  - After the first release, set each ghcr.io package to Public
    (https://github.com/nabil-becker?tab=packages) and link it to this repo.
  - Settings > Code security: confirm "Dependabot version updates" is on
    (reads .github/dependabot.yml).
'@
