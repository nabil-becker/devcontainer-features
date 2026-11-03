# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 2.1.1 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [2.1.2] - 2026-11-03

### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

## [2.1.1] - 2026-10-30

### Changed

A wake answered with another session id no longer says the old session "was not woken". The line
was written for a fresh start in place of a gone session, but a CLI may also resume a session under
a new id that continues the same conversation (Claude Code 2.1.314, as a consumer reported; the
CLI adapter in claude-code 1.9.4 records that id and says so on stderr). The line is now neutral,
`<name>: running under a new session id (<new>, was <old>)`, and the adapter's own line above it
says which case it is. Nothing else changes; the lease's carrier was already the id the adapter
prints (2.0.3).

## [2.1.0] - 2026-10-30

### Changed

Session names: the label a CLI shows for an agent's session is a template (the Feature option
`sessionName`, `AGENTS_SESSION_NAME`, a per-agent `session-name:`; default `{handle}`, so nothing
changes until one is set) rendered with `{handle}`, `{repo}` and `{machine}`, at most 60 characters,
refused when it does not render and never cut. The handle stays the address (lease, record, verbs).
`AGENT_SESSION_NAME` is set on every call to a CLI adapter: the rendered name on a call about the
agent, empty on every other call. `list` adds a `NAME` column (the first column becomes `HANDLE`)
only when some agent's name differs from its handle, and `--json` always carries `sessionName`
(after `carrier`); `check` shows a differing name and warns when `{machine}` is used without
`DCF_HOST_MACHINE`.

**Upgrade note.** A 2.0 list and a 2.0 `devcontainer.json` change nothing: with no template every
name is the handle, `list` prints the same table, and an adapter that ignores `AGENT_SESSION_NAME`
starts as before. To tell machines apart set `"sessionName": "{machine} {handle}"` and pair it with
claude-code 1.9.0 (which uses the name) and, for `{machine}`, devcontainer-cli 1.16.2 and a
`"DCF_HOST_MACHINE": "${localEnv:DCF_HOST_MACHINE}"` line in the `containerEnv` of the
repository's `devcontainer.json` (until it is there `{machine}` renders `container`). A session
that exists keeps its name until it is stopped and started again.

## [2.0.3] - 2026-10-30

### Changed

The lease follows a fresh start after a failed wake. When a resident's session could not be
woken and its adapter started it fresh under a new id (claude-code 1.8.6 and later, after a
rebuild), 2.0.0 to 2.0.2 recorded the failed session it had asked to wake as the lease's carrier,
so `agents leases` and `release` named a session that no longer ran while `list` showed the new
one. The carrier is now the id the adapter prints after `wake` and `start-bg` (the contract above
now says `wake` prints it), else the running session its `list` shows, never the session asked to
wake (a start no longer lists the sessions again when the adapter printed the id); a wake that
answers with a new session says so in one line. Whether a lease is live never
depended on the carrier or on the starter's pid alone: a resident's lease held by a session whose
starter (`agents up`) has exited is live while the adapter's `list` shows the agent running.

## [2.0.2] - 2026-10-30

### Changed

Several takers of one dead lease: exactly one claims it, and only that one prints "its lease was
stale". 2.0.0 cleared a stale lease by renaming its folder away and taking it with `mkdir`, so a
plain `mkdir` could claim it in between (no line); cleared the takeover lock after any taker had
waited 5 s, even while its holder still worked (two claims, two lines); and judged a holder dead
from a pid looked at after the holder had written its session and exited (a fresh lease taken
over). Now the takeover replaces the holder file in place under the lock, the lock (a symlink
naming its taker) is cleared only when that taker is gone, a new holder file is linked in so a
stalled taker cannot overwrite another's, and a holder judged dead is read again and must be
unchanged. The section "What 2.x holds so far" is new.

## [2.0.0] - 2026-10-29

### Changed

A stateful agent runs as exactly one live copy (the lease, above), the list grows `lifecycle`,
`identity`, `lease`, `definition` and `default`, and `agents leases` / `agents release` (tasks
`agents:leases`, `agents:release`) show and free the leases. `list` gains the `LIFECYCLE` and
`LEASE` columns (`--json`: `lifecycle`, `identity`, `lease`, `carrier`, added after the others) and
`check` shows the new keys and the default agent.

**Upgrade note.** A 1.x list needs no edit: every entry reads as `stateful` with an exclusive
lease. What changes for it: an on-demand agent started in a second terminal while one runs is
**refused** (exit 2) instead of opening a second session; give an agent you run several of at once
`lifecycle: ephemeral` (its `--resume` is then refused). A resident started twice still attaches;
a session already running at the first start is adopted, nothing restarts. Scripts that parse
the `list` table should read `-- --json`. claude-code 1.8.x works unchanged (`list` is all the
lease needs). Pin `agents:2`. The upgrade path is in
[docs/migrations/agents.md](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/migrations/agents.md).

## [1.0.3] - 2026-10-29

### Changed

`agents check` shows, under the list, one line per CLI used in it with what its CLI adapter says it
supports (`agent-adapter-<cli> supports`), for example `claude: start-bg wake attach resume new list
stop logs ...`. A missing CLI adapter or a failing `supports` is said on that CLI's line and check
carries on (exit codes unchanged). It is information only: at run time each verb's own exit 3 stays
the authority. The contract tests now require `supports` to agree with the verbs (a listed verb never
answers 3, an unlisted contract verb always does).

## [1.0.2] - 2026-10-28

### Fixed

- Reset's plan reads right, a refusal exits 2, one line per removal (agents 1.0.2, claude-code 1.8.1) ([#86](https://github.com/nabil-becker/devcontainer-features/pull/86))

## [1.0.1] - 2026-10-28

### Fixed

- Unreadable lists start nothing, retitled sessions are found, agents:reset; claude-code additionalDirectories (agents 1.0.1, claude-code 1.8.0, devcontainer-cli 1.14.0) ([#85](https://github.com/nabil-becker/devcontainer-features/pull/85))

## [1.0.0] - 2026-10-27

### Added

- One agent list, two kinds, one verb for every agent CLI (agents 1.0.0, claude-code 1.7.0, devcontainer-cli 1.13.0) ([#84](https://github.com/nabil-becker/devcontainer-features/pull/84))
