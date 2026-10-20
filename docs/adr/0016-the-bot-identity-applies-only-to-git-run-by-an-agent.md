# ADR-0016: The bot identity applies only to git run by an agent

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR 0012 put the agent identity in the git Feature's wrapper, which fills the author and committer
variables for every git command that has not set them. Setting `commitName` and `commitEmail` in
this devhost (`set-git-commit-identity-options`) would therefore have made the Operator's own
commits in a container terminal the bot's as well. The Operator's own name and email are set in the
shared git config, and their commits should carry them; agents need the bot identity without a `-c`
override on each command.

Claude Code sets `CLAUDECODE` on every process it starts: tool calls, the backs and subagents.

## Decision

The git Feature has an option `commitWhenEnv` (git 1.2.0). When it names an environment variable,
the wrapper applies the commit identity only to git run with that variable set and non-empty. Empty
keeps the earlier behaviour: the identity applies to every invocation. This devhost sets
`commitWhenEnv` to `CLAUDECODE`, so agent commits and sign-offs are `devhost agent
<devhost-agent@noreply.invalid>` and a person's terminal commits keep their own identity.

## Options considered

### Option 1: gate the identity on an environment variable (chosen)

No per-command overrides for agents, nothing for a person to unset, and the Feature stays generic:
any consumer names its own marker variable.

### Option 2: set the options as they were

Simplest, but every git command in the container, a person's included, would commit as the bot.

### Option 3: keep setting the bot identity by hand on each agent commit

Needs no change, but it is the friction the item was opened to remove, and a forgotten override
commits as the Operator.

## Consequences

- Agents commit as the bot with no overrides; a person's terminal commits carry their identity.
- A commit the Operator makes through the `!` prompt runs inside Claude Code, so it carries the bot
  identity; a container terminal gives their own.
- A person or script that sets `CLAUDECODE` by hand gets the bot identity; an agent harness that
  does not set the marker gets none.
- A command that bypasses the wrapper (a full path to the real git) still gets no bot identity
  (ADR 0012).
- The rebuild check is the backlog item `identity-rebuild-check`.

## Change log

| Date | Change |
|---|---|
| 2026-10-20 | First draft, accepted by the Operator; refines ADR 0012 (not superseded). |
