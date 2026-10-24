# ADR-0030: claude-fleet waits for restored sessions, and stops extras but never removes them

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-24 |
| **Deciders** | the Operator; proposed by the host, from a consuming repository's lessons |

## Context

A consuming repository runs four Claude agents in one dev container and needs exactly one live
session per agent, always. Its lessons from running `claude-fleet` (see [ADR-0028](0028-claude-host-refuses-a-second-live-session-and-a-hook-writes-the-pin-back.md)
for the rule that a session counts as live only when it has a pid) were:

- After a rebuild the Claude daemon restores background sessions from the claude-code Feature's
  volume. A launcher that starts sessions right after the container comes up races that restore and
  makes duplicates.
- `claude rm` deletes a background session and its worktree. In a fleet the worktree is not
  Claude's to delete. `claude stop` stops the session and keeps its conversation, which
  `claude attach <id>` resumes.
- The session ids come from `.devcontainer/.env` (`HOST_SESSION*`) or the environment. Inside a
  session the environment keeps the id the session started with; after a `/clear` or a fork it is
  stale, while the hook of ADR-0028 keeps `.env` current.
- Duplicates need to be visible before anything is stopped, and stopping needs to be confirmed.

## Decision

`claude-fleet` waits until the list of live sessions is stable before it reconciles: it reads
`claude agents --json` until two reads `FLEET_SETTLE_INTERVAL` seconds apart (default 3) give the
same set of live ids, for at most `FLEET_SETTLE_TIMEOUT` seconds (default 30). It prints "waiting for
restored sessions…" once; on timeout it reconciles anyway with a one-line note. `--no-wait` skips the
wait.

`claude-fleet` never invokes `claude rm`. Stopping an extra session uses `claude stop <id>` only, and
a stopped extra is never restarted. A test asserts that the launcher never calls `rm`.

Session ids are read from `.devcontainer/.env` first; the environment is the fallback only when
`.env` has no line for that variable. This reverses the earlier order.

Duplicates, matched by id or by folder, are listed with a keep or extra mark, pid, age and whether a
transcript exists. The pinned session is kept if it is live, otherwise the newest. A normal run only
prints the hint; `--stop-duplicates` stops the extras, re-reads the list and confirms they are gone,
and exits non-zero when one is still live. `claude-host`'s refusal names `claude attach <id>` for
each live id.

## Options considered

### Option 1: settle wait, stop only, `.env` first, explicit stop flag (chosen)

Each choice removes one cause of a duplicate or of a lost worktree, and the tests can prove each with
a fake `claude`.

### Option 2: start immediately and clean up duplicates afterwards

Races the daemon's restore, so duplicates exist for a while and the cleanup has to pick a loser.

### Option 3: stop extras with `claude rm`

Tidier, but it deletes the worktree. Not reversible, and not Claude's to delete in a fleet.

### Option 4: keep the environment ahead of `.env`

The environment is stale after a `/clear` or a fork, so it can pin a dead session.

### Option 5: stop duplicates automatically on every run

Stopping a session is an outward effect; a hint on a normal run and an explicit flag keeps the
Operator in control.

## Consequences

- A rebuild no longer produces duplicates from the restore race, at the cost of at least one settle
  interval on every run; the test helper sets the interval to 0.
- Nothing in the fleet path deletes a session or its worktree; an extra stays attachable.
- A consumer that relied on the environment winning over `.env` sees the order change.
- Not yet tried against the real daemon: the timing of `claude stop` and the restore race are covered
  by a fake only. The open item for a real background-session check should include a rebuild.
- Releasing the claude-code and devcontainer-cli Features is the Operator's call, and a consumer
  adopts the `.devcontainer` changes from that release.

## Change log

| Date | Change |
|---|---|
| 2026-10-24 | First draft. |
