# ADR-0028: claude-host refuses a second live session, and an opt-in hook writes the pin back

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-24 |
| **Deciders** | the Operator; proposed by the host, from a consuming repository's request |

## Context

`claude-host` resumes the session id pinned in `.devcontainer/.env` (`HOST_SESSION`, or
`HOST_SESSION_<DIR>`). A `/clear` inside a session starts a new session id in the same folder, and
nothing writes it back. The next start either resumes the old, pre-clear session or, if the new one
is still running, starts a second copy in the same folder. A consuming repository hit both with four
agents in one dev container and worked around it with its own SessionStart hook and its own check.

`claude agents --json` lists sessions that ended as well as live ones; only a live session has a pid.
The first design of pull request #70 resumed a live session it found in the folder, but `claude
--resume` on a session that is still running opens a second process on the same transcript, which is
another kind of duplicate.

## Decision

`claude-host` counts a session as live only when it has a pid. When a live session runs in the
folder, `claude-host` starts nothing: it names the running session's id and pid, says to attach with
`claude agents`, and says when the pin is stale. `CLAUDE_HOST_ALLOW_SECOND=1` overrides the refusal.
The fleet launcher counts a session as running by the same rule.

The claude-code Feature ships `claude-host-pin`, an opt-in SessionStart hook for `startup` and
`clear`. It writes the new session id into the matching `HOST_SESSION*` line of
`.devcontainer/.env`, changes only that line and only when the id differs, leaves every other byte
alone, and never fails a session. A session started deeper than one sub-folder, with no pin variable
named after its folder, is skipped with a note. A repository registers the hook in its own
`.claude/settings.json`; the Feature does not.

## Options considered

### Option 1: refuse the second copy, and write the pin back by a hook (chosen)

The write-back lives where `HOST_SESSION` is defined, so every consumer drops its own copy. Refusing
is the only outcome that never produces two processes on one transcript.

### Option 2: resume the live session

The first design of #70. It lost because resuming a running session is itself a second process on
the same transcript.

### Option 3: fall back to the newest transcript in the folder

Too implicit once the hook keeps the pin current; it guesses where the hook states.

### Option 4: leave the write-back to each consumer

Every consumer carries the same script, which is a gap to close here.

## Consequences

- A stale pin after `/clear` no longer resumes a dead session or doubles a live one.
- A start that finds a live session now fails instead of resuming; the Operator attaches with
  `claude agents` or sets `CLAUDE_HOST_ALLOW_SECOND=1`.
- Registering the hook in a repository's settings is that repository's call; this repository adds it
  after the release, so its next `/clear` is the hook's first real test.
- Not yet tried against a real Claude Code session start: the hook's input fields come from the hook
  documentation and the devhost's own hooks.
- A hook point for a consumer's own brief is left out on purpose and may be raised again.

## Change log

| Date | Change |
|---|---|
| 2026-10-24 | First draft. |
