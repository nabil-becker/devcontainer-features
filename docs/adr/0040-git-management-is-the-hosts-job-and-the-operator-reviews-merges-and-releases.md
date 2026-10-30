# ADR-0040: Git management is the host's job, and the Operator reviews, merges and releases

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-30 |
| **Deciders** | the Operator; proposed by the host |

## Context

The host kept asking the Operator to say "commit", to pull, and to run the git steps around a
records pull request. The Operator said that git management is not their job and is the host's.
The same session showed what the Operator's hands are needed for: reviewing and merging pull
requests, and starting releases. The project instructions say "commit and push only when asked",
which made every commit a question to the Operator.

## Decision

The host does the git work end to end without asking: commits on topic branches, the records pull
requests, keeping the checkout current with `main`, and cleaning up branches and worktrees. The
Operator reviews and merges pull requests and starts releases; the host says when a release is due
and never runs it. The Operator's own working-tree changes (a file they deleted or edited for their
own reason) are left alone: the host commits only the files that belong to its work.

## Options considered

### Option 1: the host owns git, the Operator owns merge and release (chosen)

Removes the "say commit" and "please pull" round trips. The decisions that carry risk (what lands on
`main`, what is published) stay with the Operator.

### Option 2: commit and push only when asked

The earlier rule. Safe, but it turned routine bookkeeping into a question on every change.

### Option 3: the host also merges

Fastest, but it removes the review that protects `main` and the consumers, and a pull request that
failed lint was already merged by hand once in this session.

## Consequences

- Fewer prompts to the Operator; git steps in a hand-off are reported as done, not requested.
- The host must still read the backs' changes before each commit and commit only its own files.
- The line "commit and push only when asked" in `CLAUDE.md` and in the devhost include no longer
  describes the practice.

## Change log

| Date | Change |
|---|---|
| 2026-10-30 | First draft, accepted by the Operator. |
