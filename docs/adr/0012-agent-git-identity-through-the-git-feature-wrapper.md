# ADR-0012: Agent git identity is set by the git Feature's wrapper

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-19 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR 0001 decided that the git Feature sets the agent identity through `containerEnv`. The build
(git 1.1.0) did it differently: the `commitName` and `commitEmail` options are written to the
Feature's `identity.env`, and the `/usr/local/bin/git` wrapper exports `GIT_AUTHOR_*` and
`GIT_COMMITTER_*` from it for every git command that has not set them. The divergence was never
recorded as a decision (ledger: "Implement bot-git-identity"; the outline of the third paper).

## Decision

The git Feature sets the agent identity in its wrapper: when `commitEmail` is set, the wrapper
exports the author and committer variables for any git invocation that has not set them itself.
Environment variables still outrank every config file, so the shared git dir's config is left
alone. This supersedes ADR 0001; its reasons (no `-c` overrides, no edit of the shared config)
stand.

## Options considered

### Option 1: the wrapper exports the variables (chosen)

A command, a human or a test can still set its own identity, since the wrapper only fills what is
unset; the identity lives with the Feature that owns git, and a rebuild keeps it.

### Option 2: containerEnv, as ADR 0001 said

Fixed for the whole container: a human committing in the devhost would have to unset four
variables, which ADR 0001 itself listed as a cost.

## Consequences

- The wrapper is the enforcement of the boundary on agent identities (old AP-11, now under P3; ADR 0013).
- A command that bypasses the wrapper (a full path to the real git) gets no bot identity.
- This devhost does not set the options yet (`set-git-commit-identity-options`); until then, agent
  commits set the variables per command.

## Change log

| Date | Change |
|---|---|
| 2026-10-19 | First draft, accepted by the Operator; supersedes ADR 0001. |
