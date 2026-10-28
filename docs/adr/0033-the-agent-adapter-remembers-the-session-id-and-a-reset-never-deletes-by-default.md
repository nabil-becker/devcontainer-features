# ADR-0033: The agent adapter remembers the session id, and a reset never deletes by default

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-28 |
| **Deciders** | the Operator; proposed by the host, from a consuming repository's report and clean-up script |

## Context

The claude-code adapter of the `agents` Feature found an agent's session by name. Claude Code
replaces a `--name` with an automatic title once real prompts arrive, so after the first prompt the
adapter saw only the old, ended sessions still carrying the name, and started a second session next
to each live one. A name set by hand with `/rename` sticks, which is why one resident agent survived.
Claude Code has no setting that turns automatic titles off.

The consuming repository also asked for a clean-up or reset, and shared the script it had run by hand:
list every session with `claude agents --json --all`, `claude stop` each, then `claude rm` each. That
list covers every repository in the container, and `claude rm` deletes a conversation for good. It was
safe there only because that repository's continuity lives in its own records. See
[ADR-0030](0030-claude-fleet-waits-for-restored-sessions-and-stops-extras-but-never-removes-them.md)
for the rule that nothing in a fleet path removes a session.

## Decision

When the adapter starts or wakes an agent, it records the agent's session id in the claude-code
Feature's own volume (`agent-adapter-claude/agents.tsv`), never in the repository, so it survives a
rebuild. A lookup uses that id first, whatever the session is now called, and falls back to the name.
A live session always beats ended sessions with the same name; a finished session never counts as
running. A test with a fake `claude` that retitles the session after the first prompt asserts that no
second session is ever started.

`task agents:reset -- <name>` (or `--all`) tidies agents:

- It shows its plan and changes nothing until `--yes` is given or the plan is confirmed.
- It stops duplicate sessions with `claude stop`, keeps the agent's session, re-records it, and starts
  a resident agent that is not running. Conversations are kept.
- `--purge` also deletes the agent's ended sessions, only for agents in the list and only in their
  folders. Unlisted sessions in the same folders are reported and left alone unless
  `--include-unlisted` is given.
- It refuses to stop a session that is mid-turn, and with `--purge` to remove a session whose folder
  has uncommitted changes (a plain reset only warns about them), unless `--force` is given; and it
  refuses to run from inside a session it would stop.

## Options considered

### Option 1: remembered session id, lookup by id then name, scoped reset (chosen)

Removes the cause (the name changes) rather than the symptom, and keeps a reset inside the agent list.

### Option 2: stop automatic titles

Claude Code offers no such setting.

### Option 3: tell users to `/rename` every resident session

Works until the next fresh session; a manual step the Feature exists to remove. Kept only as the
workaround until the release.

### Option 4: adopt the consumer's script as the reset

Lists and deletes sessions of other repositories in the same container, and `claude rm` is not
reversible.

## Consequences

- An agent renamed after its first prompt still shows as running; starting it attaches, and `agents up`
  leaves it alone.
- A reset is safe to run by default; a from-scratch clean start needs `--purge`.
- The record is state in the Feature's volume; a lost volume falls back to lookup by name.
- Not yet tried against the real daemon: the retitle is covered by a fake `claude`.
- Releasing `agents` 1.0.1, `claude-code` 1.8.0 and `devcontainer-cli` 1.14.0 is the Operator's call.

## Change log

| Date | Change |
|---|---|
| 2026-10-28 | First draft. |
| 2026-10-28 | Accepted: the Operator chose the reset refusals (stop refused mid-turn; uncommitted changes warn on a plain reset and refuse on `--purge`; `--force` overrides). |
