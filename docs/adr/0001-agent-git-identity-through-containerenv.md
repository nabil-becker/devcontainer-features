# ADR-0001: Agent git identity is set through containerEnv

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-16 |
| **Deciders** | the Operator; proposed by the host |

## Context

Agents commit in the devhost under a bot identity (author and committer `devhost agent`, with a
noreply address, and a matching DCO sign-off). The identity lives in the git Feature's global
config. The shared git dir's own config, which is bind-mounted from outside the checkout, sets a
`user.email` that belongs to the Operator, and a repository-level setting overrides the global
one. A con's first commits therefore carried the Operator's real address in author and sign-off,
and had to be reset away before anything was published. The brief forbade `GIT_AUTHOR_*` and
`GIT_COMMITTER_*` variables and config changes, so the con could not fix it inside its brief. The
second con worked around it with a per-command `git -c` wrapper, which is a config override in
effect and must not become the norm.

## Decision

The git Feature takes the agent identity as an option and sets it through the container's
`containerEnv` (`GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`,
`GIT_COMMITTER_EMAIL`). Environment variables outrank every config file, so the bot identity wins
over the shared git dir's config without touching it. The shared git dir's config is left alone.
Agents do not wrap git in `-c` overrides to set an identity.

## Options considered

### Option 1: identity through containerEnv in the git Feature (chosen)

It beats every config level, needs no change to the shared git dir, and applies to every session
and subagent in the devhost with no per-command effort.

### Option 2: remove `user.email` from the shared git dir config

The shared config also serves the Operator's workstation use, so editing it changes how humans
commit and fixes only this one checkout.

### Option 3: set the identity per worktree (devhost git wrapper or `task repo:setup`)

It repeats the setup for every worktree and can be forgotten for a new one, so the leak can
return.

### Option 4: a `git -c user.*` wrapper script per con

It works but is a config override each brief has to allow, and any call that bypasses the wrapper
leaks the real address.

## Consequences

- Agent commits carry the bot identity regardless of what the shared git dir config holds.
- A human committing inside the devhost also gets the bot identity unless they unset the
  variables; the git Feature's option must make that easy to override.
- The git Feature gains an option and a version bump; the backlog item for the bot identity
  through the git Feature carries the work.
- A check that the effective author email is not a personal address can still be added as a
  guard.

## Change log

| Date | Change |
|---|---|
| 2026-10-16 | First draft. |
