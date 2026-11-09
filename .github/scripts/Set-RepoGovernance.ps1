<#
.SYNOPSIS
    Applies this repository's governance settings on GitHub with the gh CLI:
    security features, merge policy, Actions permissions, a 'release'
    environment with required reviewers, a ruleset protecting the default
    branch and a ruleset protecting release tags. Idempotent -
    re-run after changing it. Run as a repo admin: `task repo:govern`.

.DESCRIPTION
    What it configures (and why):
      - Private vulnerability reporting, Dependabot alerts + security
        updates, secret scanning + push protection: public collaboration
        without leaking credentials or shipping known-vulnerable actions.
      - Squash-only merges, delete branch on merge: linear, reviewable
        history on main.
      - DCO: web-based commits must be signed off, and the 'DCO' status
        check (from the DCO GitHub App, https://github.com/apps/dco - install
        it on the repo first, by hand) is required on main.
      - Actions: only GitHub-owned actions plus devcontainers/action; default
        GITHUB_TOKEN read-only; Actions may create PRs (the release workflow
        opens the generated-docs PR); fork PR workflows need approval from a
        maintainer for first-time contributors.
      - 'release' environment (required by release.yaml) restricted to the
        default branch - the only place the packages:write token exists - and
        with a required reviewer (the repository owner, the Operator, or
        -ReleaseReviewer): a release job waits for their approval. Self-review
        is allowed, so a solo maintainer can still release.
      - Ruleset 'protect-main': no deletion/force-push, linear history, PRs
        required with 1 approval incl. code owners, stale reviews dismissed,
        conversations resolved, required checks validate / lint / tests.
        Repo admins may bypass *only through a PR* (solo-maintainer escape
        hatch: own PRs can be merged without a second human). Kept on
        purpose for now (least-privilege step 1, decision 4): the agent's
        fine-grained token acts as the Operator, so it can still merge.
      - Ruleset 'protect-release-tags': tags 'feature_*' (what the release
        workflow publishes: feature_<id>_<version>) cannot be deleted,
        moved (update) or force-pushed, and can be created only by the
        GitHub Actions app (the release workflow) or a repo admin. If the API
        refuses the Actions app as a bypass actor, the ruleset is applied with
        admins only and a warning says so.

.PARAMETER Repo
    owner/name. Defaults to the repo of the current directory.

.PARAMETER ReleaseReviewer
    GitHub login required to approve runs of the 'release' environment.
    Defaults to the repository owner when that is a user (read at run time,
    never stored in this file). When neither resolves, reviewers are left as
    they are and a warning says so.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Repo,
    [string]$ReleaseReviewer
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh CLI is required (winget install GitHub.cli) and must be logged in.' }
if (-not $Repo) { $Repo = gh repo view --json nameWithOwner -q .nameWithOwner }
Write-Host "Applying governance to $Repo"

function Invoke-Gh {
    param([string]$Method, [string]$Endpoint, [hashtable]$Body, [switch]$IgnoreError)
    $ghArgs = @('api', '-X', $Method, $Endpoint, '-H', 'Accept: application/vnd.github+json')
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        $ghArgs += @('--input', '-')
        $out = $json | gh @ghArgs 2>&1
    }
    else {
        $out = gh @ghArgs 2>&1
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
        web_commit_signoff_required = $true
        squash_merge_commit_title   = 'PR_TITLE'
        squash_merge_commit_message = 'PR_BODY'
        has_wiki                    = $false
        security_and_analysis       = @{
            secret_scanning                 = @{ status = 'enabled' }
            secret_scanning_push_protection = @{ status = 'enabled' }
        }
    } | Out-Null
    Write-Host '  repository: squash-only merges, branch cleanup, web commits signed off, secret scanning + push protection'

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
        patterns_allowed     = @('devcontainers/action@*', 'devcontainers/ci@*')
    } | Out-Null
    Invoke-Gh PUT "repos/$Repo/actions/permissions/workflow" @{
        default_workflow_permissions     = 'read'
        can_approve_pull_request_reviews = $true
    } | Out-Null
    # Newer endpoint; tolerate absence on older GitHub versions.
    Invoke-Gh PUT "repos/$Repo/actions/permissions/fork-pr-contributor-approval" @{ approval_policy = 'first_time_contributors' } -IgnoreError | Out-Null
    Write-Host '  actions: GitHub-owned + devcontainers/action and devcontainers/ci only, read-only token, PR creation allowed'
}

if ($PSCmdlet.ShouldProcess($Repo, "environment 'release'")) {
    $envBody = @{
        deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
    }
    if (-not $ReleaseReviewer) {
        $owner = Invoke-Gh GET "repos/$Repo" | ConvertFrom-Json | Select-Object -ExpandProperty owner
        if ($owner.type -eq 'User') { $ReleaseReviewer = $owner.login }
    }
    if ($ReleaseReviewer) {
        $reviewerId = [int](Invoke-Gh GET "users/$ReleaseReviewer" | ConvertFrom-Json).id
        $envBody.reviewers = @(@{ type = 'User'; id = $reviewerId })
        $envBody.prevent_self_review = $false
    }
    else {
        Write-Warning "No release reviewer resolved (the owner is not a user); pass -ReleaseReviewer <login>. Reviewers left unchanged."
    }
    Invoke-Gh PUT "repos/$Repo/environments/release" $envBody | Out-Null
    $existing = Invoke-Gh GET "repos/$Repo/environments/release/deployment-branch-policies" | ConvertFrom-Json
    if (-not ($existing.branch_policies | Where-Object { $_.name -eq 'main' })) {
        Invoke-Gh POST "repos/$Repo/environments/release/deployment-branch-policies" @{ name = 'main'; type = 'branch' } | Out-Null
    }
    Write-Host "  environment 'release': deployable from main only$(if ($ReleaseReviewer) { ', one required reviewer' })"
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
                        @{ context = 'tests' },
                        @{ context = 'DCO' }
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

if ($PSCmdlet.ShouldProcess($Repo, "ruleset 'protect-release-tags'")) {
    # RepositoryRole 5 = admin. Integration 15368 = the GitHub Actions app,
    # which the release workflow's GITHUB_TOKEN acts as.
    $admin = @{ actor_id = 5; actor_type = 'RepositoryRole'; bypass_mode = 'always' }
    $actions = @{ actor_id = 15368; actor_type = 'Integration'; bypass_mode = 'always' }
    $tagRuleset = @{
        name          = 'protect-release-tags'
        target        = 'tag'
        enforcement   = 'active'
        conditions    = @{ ref_name = @{ include = @('refs/tags/feature_*'); exclude = @() } }
        bypass_actors = @($admin, $actions)
        rules         = @(
            @{ type = 'creation' },
            @{ type = 'update' },
            @{ type = 'deletion' },
            @{ type = 'non_fast_forward' }
        )
    }
    $all = Invoke-Gh GET "repos/$Repo/rulesets" | ConvertFrom-Json
    $current = $all | Where-Object { $_.name -eq 'protect-release-tags' } | Select-Object -First 1
    $method = if ($current) { 'PUT' } else { 'POST' }
    $endpoint = if ($current) { "repos/$Repo/rulesets/$($current.id)" } else { "repos/$Repo/rulesets" }
    $result = Invoke-Gh $method $endpoint $tagRuleset -IgnoreError
    if (-not $result) {
        Write-Warning 'The API refused the GitHub Actions app as a bypass actor; applying with repo admins only (the release workflow then cannot create tags: add the actor by hand).'
        $tagRuleset.bypass_actors = @($admin)
        $result = Invoke-Gh $method $endpoint $tagRuleset
    }
    Write-Host "  ruleset 'protect-release-tags': $(if ($current) { 'updated' } else { 'created' }) (feature_* tags: no delete, update or force-push; created by the release workflow or admins)"
}

Write-Host @'
Done. Manual follow-ups GitHub does not expose via API:
  - Install the DCO app on this repo (https://github.com/apps/dco) - the
    required 'DCO' check blocks every PR until it reports.
  - After the first release, set each ghcr.io package to Public
    (https://github.com/nabil-becker?tab=packages) and link it to this repo.
  - Settings > Code security: confirm "Dependabot version updates" is on
    (reads .github/dependabot.yml).
'@
