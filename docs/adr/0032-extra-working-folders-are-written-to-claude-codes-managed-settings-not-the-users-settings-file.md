# ADR-0032: Extra working folders are written to Claude Code's managed settings, not the user's settings file

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-28 |
| **Deciders** | the Operator; proposed by the host |

## Context

A consuming repository gave every Claude session extra working folders with a wrapper at
`/usr/local/bin/claude` that put `--add-dir <folder>` in front of every command. `--add-dir` takes any
number of folders, so it swallowed the subcommand `agents`, and Claude Code rejected `--json` with
`unknown option '--json'`. The agents Feature then read the session list as unreadable and started
resident agents fresh instead of resuming them. The fix for that wrapper is the consumer's; the
Feature side is to offer the folders without a wrapper, as a claude-code option
`additionalDirectories` that sets `permissions.additionalDirectories` in Claude Code's settings.

Two places can hold that key:

- the managed settings folder (`/etc/claude-code/managed-settings.d/`), which belongs to the container
  image;
- the user's own `settings.json`, in the claude-code Feature's volume, which survives rebuilds and
  also holds the user's own settings and whatever Claude saves there.

## Decision

The `additionalDirectories` option (a comma-separated list; default empty, which writes nothing) is
written at build time into a file in Claude Code's managed settings folder. The user's own
`settings.json` is never read or rewritten by the Feature. A rebuild rewrites the managed file, so a
folder removed from the option is removed from the settings.

A consumer drops its `--add-dir` wrapper and sets the option. The claude-code Feature goes to 1.8.0
for it.

## Options considered

### Option 1: the managed settings folder (chosen)

The Feature owns the file, so there is nothing to merge and nothing of the user's to damage. Repeating
the build is safe, and removal needs no bookkeeping.

### Option 2: merge into the user's `settings.json`

Writes into a file the Feature does not own, which holds personal settings and Claude's own saves. The
merge has to be idempotent, and removing an entry when the option changes means tracking which entries
the Feature wrote. Kept only as a fallback.

### Option 3: keep the wrapper and fix its argument order

Leaves every consumer scripting around a gap the Feature can close, and the next wrapper can break
the same subcommands.

## Consequences

- Consumers get extra folders without a wrapper; the user's settings file stays theirs.
- If an organisation pushes Claude settings centrally (an admin console or device management), Claude
  Code uses those instead of the managed folder, and the extra folders silently do not apply. The
  merge into the user's `settings.json` is built only if a consumer's `/status` shows centrally pushed
  settings.
- Consumers that set the option get a rebuilt image to change it; a change at runtime is not offered.
- The key being allowed in managed settings and how lists combine across settings files were to be
  checked against Claude Code's documentation while building; the check is part of the release review.
- Releasing claude-code 1.8.0 is the Operator's call.

## Change log

| Date | Change |
|---|---|
| 2026-10-28 | First draft. |
