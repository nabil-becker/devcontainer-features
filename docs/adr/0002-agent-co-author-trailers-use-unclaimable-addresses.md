# ADR-0002: Agent co-author trailers use unclaimable per-model addresses

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-16 |
| **Deciders** | the Operator; proposed by the host |

## Context

Agent commits carry a `Co-Authored-By: Claude <model> <noreply@anthropic.com>` trailer. GitHub
turns every `Co-authored-by:` address into a co-author and shows co-authors as participants of a
pull request, using whichever account has verified that address. The address in the trailer is
attached to an unrelated third-party account, so that account appeared as a participant in the
first Features pull request and would have been carried into the squash commit on `main`. Checked
through the GitHub API: the Operator's commits resolve to the Operator's own account, and the bot
identity's address (`.invalid` domain) resolves to no account.

## Decision

Agent co-author trailers use one address per model on the reserved `.invalid` domain, built from
the model's handle: `Co-Authored-By: Claude Sonnet 5.5 <claude-sonnet-5-5@noreply.invalid>`.
`.invalid` (RFC 2606) never resolves, so nobody can verify the address and GitHub links it to no
account. No real, claimable address appears in a trailer. The existing branch's trailers were
rewritten to this form before the pull request was merged.

## Options considered

### Option 1: per-model `.invalid` addresses (chosen)

No account can claim them, and the trailer still records which model wrote each commit. It
matches the bot identity's own address, which already behaves this way.

### Option 2: drop the email, use an `Assisted-by:` trailer

It gives GitHub nothing to link, but it leaves the `Co-Authored-By` convention the contributing
guide asks for and changes the trailer form everywhere.

### Option 3: keep the vendor noreply address

It is the tool's default, but it is claimable by anyone who verified it on an account, and
misattributes the work in a public repository.

## Consequences

- No third-party account appears as a participant or co-author of agent work.
- The model stays visible in each commit; the ledger also records it per job.
- Anything that writes trailers (the host, cons, the close-session skill and its template) must use
  the per-model address; a guard could check that no trailer carries a claimable domain.
- Commits already published with the old address keep it unless rewritten.

## Change log

| Date | Change |
|---|---|
| 2026-10-16 | First draft. |
