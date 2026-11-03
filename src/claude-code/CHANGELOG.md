# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

Entries from 1.0.0 to 1.9.7 were generated from the commit history (`.github/scripts/changelog.py backfill`) and the "Changes in x.y.z" sections that NOTES.md used to hold; most list commit subjects as written then; the newest of them is in wording for users.

## [1.9.8] - 2026-11-03

### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

## [1.9.7] - 2026-11-03

### Changed

- **A stale background-session record no longer starts a copy of a resident agent** (`agents-stale-bg-record`).
  Reported by a consumer after `up --remove-existing-container` (agents 2.1.1, claude-code 1.9.6): `agents up`
  woke a stopped resident with `claude --bg --resume <id>`, and Claude Code answered *"session 43428c82 is already
  running in the background, so this started a copy as cf20ad8b"*, two copies of an agent that may have only one
  (the lease). A new container has no process of any session, but Claude Code's records of sessions live in the
  Feature's volume and survive it.
  - **Stale records are cleared before a wake.** Claude Code keeps one record per session with a process in
    `$CLAUDE_CONFIG_DIR/sessions/<pid>.json` (`pid`, `sessionId`, `procStart`, `pidDomain`,
    `messagingSocketPath`, with a `<pid>.<hash>.key` beside it; read on 2.1.311, where it leaves the records of
    containers that are gone). Before every wake, `wake` and the wake that `attach` does, the adapter looks at
    the records that name the session it is about to wake and removes (with their `.key` files and a socket left
    behind) those whose process is proven not to exist in this container: it ran in another pid namespace
    (`pidDomain` differs from `/proc/self/ns/pid`), or no such pid is here, or the pid is here but started at
    another time (`procStart` differs from field 22 of `/proc/<pid>/stat`). One line says so. A record whose
    process is alive, that cannot be read, or that names another session is never touched.
  - **A copy that is started anyway is stopped by the id in the CLI's note, and the wake is an error.** When the CLI
    still prints "is already running in the background, so this started a copy as <id>", the adapter stops that copy
    (`claude stop <id>`; the id comes from the note, since the copies were never in `claude agents`, only in Claude
    Code's own view), never wakes again in the same run (every repeat made another copy), records nothing and exits 1
    with `agent-adapter-claude: error: <name>: Claude Code took session <id> for one that runs ... started a copy as
    <id2>, which was stopped; the agent is not running`. When `$CLAUDE_CONFIG_DIR/daemon/roster.json` (the background
    service's roster, with each worker's pid and procStart; read by the CLI to decide whether a session runs) names the
    session, the line says so; this Feature does not edit that file, which the service rewrites. `agents` treats the
    failed wake as `agents: <name>: waking failed.`, and at post-start goes on with the container start after saying
    `agents: some agents did not start (above)` (it never fails the start); the lease is released. The next run starts
    from the cleared records.
  - **`attach` never wakes a session a second time.** Reported with it: `agents start` woke the session, which the
    list did not show yet ("not recorded"), then called `attach`, which found no running session and woke it again, a
    second copy per run. A wake leaves a marker (`woken-<session id>` beside `agents.tsv`); `attach` of a session
    woken less than `AGENT_ADAPTER_RECENT` seconds ago (default 60) waits for it to be listed (`AGENT_ADAPTER_WAIT`)
    and attaches it, or says it was woken a moment ago and stops (exit 1), never waking it again.
  - Not changed: `agents` (2.1.1) itself; a session with a live process is still never woken.

## [1.9.6] - 2026-10-31

### Changed

- **The host returns as itself after a restart** (`host-restart-copy`). Reported by a consumer on claude-code 1.9.4
  with Claude Code 2.1.314, after one container restart: three residents woke under new ids with the old ones
  superseded, but the host came back as a copy, a job started as `--fork-session --resume <old id>` whose saved
  options held only `--model` (its `--name`, `--agent` and `--settings` gone), spawned by Claude Code as `(shell)`
  rather than claimed like the others, and nothing recorded it or marked the old session superseded. The host's old
  session was the only one left `blocked`. Which path ran could not be read from that stack; the CLI adapter now
  closes every path that gives that result:
  - **A listed pid is checked.** `list` read any session with a pid as running. A pid listed for a session the
    restart ended (gone, or taken by another program) made it running, so `agents up` never woke it and
    `agents start`/`task devcontainer:agent` attached to it, which let Claude Code restart it on its own. A pid
    counts now only when `$AGENT_ADAPTER_CLAUDE_PROC` (default `/proc`) has it and its command line, when
    readable, names claude; otherwise the session is `stopped` (or `failed`), whatever state it was left in.
  - **`attach` of an ended session wakes it first.** It ran `claude attach <id>` of the ended session, which lets
    Claude Code restart it however it does (a copy under a new id that nothing records). It now wakes it as `wake`
    does (bare, confirmed, a new id recorded with the old one superseded, a gone session started fresh) and attaches
    to the session that then runs.
  - **A fork is recognised by its job.** A new session continues the old one also when its job's `state.json` names
    the old id anywhere (a forked respawn's `--fork-session --resume <old id>`), not only as `resumeSessionId`; it
    is recorded whatever its name. A new running session by the agent's name that is not known to continue it (the
    1.9.1 fallback) is recorded too, now with the woken session superseded, and one line says so.
  - **What a new id lacks is said.** When the session that came back under a new id lacks the agent's options, one
    line names them (`lack or differ in: --name host; --settings ...; --agent host`); it runs without them until
    the agent's next fresh start (`task agents -- <name> --new`, a new conversation). A wake is still always bare.
  - **A quiet trace.** `$CLAUDE_CONFIG_DIR/agent-adapter-claude/trace.log` (beside `agents.tsv`, in the Feature's
    volume, mode 600, the last 500 to 1000 lines) gets one tab-separated line each time an agent is started, woken
    or attached: time (UTC), the verb `agents` called (`start-bg`, `wake`, `attach`), agent, folder, old id, new id,
    and the outcome: `same`, `continues` (a new id continuing it, the old one superseded), `new-id` (a new id not
    known to continue it, the old one superseded), `fresh: <why>`, `started`, `said-woken`, `unconfirmed` (not
    recorded) or `attached`, with `; options lack: ...` when the session lacks the agent's options. Nothing is
    printed. After the next restart, `grep host "$CLAUDE_CONFIG_DIR/agent-adapter-claude/trace.log"` says which verb
    brought the host back and as what.
  - Not changed: `agents` (2.1.1) itself; a session with a live Claude Code process is still running, `blocked`
    too.

## [1.9.5] - 2026-10-30

### Changed

- **`agents start <name> --resume` reaches the agent's own conversation.** `claude agents --json --all` lists an
  interactive session only while it runs: one ended with `/exit` is gone from it, though its transcript stays at
  `$CLAUDE_CONFIG_DIR/projects/<folder slug>/<session id>.jsonl` and names it (`agentName` and `customTitle`
  lines). `resume` took the newest listed session of the agent's name and folder, so once the host ended, a stray
  background session of the same name (left `blocked` by an earlier resident run) was resumed: the wrong
  conversation. `resume` now weighs, by the identity rule (name and folder, the recorded session first): the
  agent's recorded session (the one `new` wrote before it started), listed or ended with a transcript; its listed
  interactive sessions; and the ended sessions found only on disk in the folder's transcript folder, made in that
  folder (`cwd`), whose last title is a name the agent's session has had. A background session (listed so, or one a
  job in `$CLAUDE_CONFIG_DIR/jobs` holds) counts only when it is the recorded one. A running one is refused, as
  before (a second process on one transcript); else the newest by its transcript's time is resumed by its id. When
  the list cannot be read, Claude Code's own picker opens, as before.

## [1.9.4] - 2026-10-30

### Changed

- **A crashed wake never loops.** Reported by a consumer on claude-code 1.9.2 with Claude Code 2.1.314: a resident
  whose session had never been prompted was woken, the wake crashed (`bg settled <short> (crashed): source session
  <id> not found` in `$CLAUDE_CONFIG_DIR/daemon.log`), the CLI adapter recorded the crashed attempt as the agent's
  session (it was briefly listed running under a new id), and every `agents up` woke that attempt and crashed again.
  The workaround was `agents start <name> --new --yes`. Now:
  - A session with no transcript (`$CLAUDE_CONFIG_DIR/projects/<folder>/<session id>.jsonl`, looked for in every
    folder) is never woken: there is no conversation to keep, so the agent starts fresh, as for a gone session, and
    one line says so. When there is no `projects` folder at all the wake goes ahead as before.
  - A session whose job failed with `source session <id> not found` (its `state.json`), or that any job's
    `state.json` names as not found, is gone and never woken again; the agent starts fresh.
  - Every wake is confirmed for `AGENT_ADAPTER_SETTLE` seconds (default 5): when the wake output, the woken job's
    `state.json`, any job's `state.json` or the lines `daemon.log` gained since the wake say `source session <id>
    not found`, the agent starts fresh and the crashed attempt is never recorded. A woken session listed `failed`
    at the end of that time for another reason fails the wake (exit 1), unrecorded, its conversation kept.
- **"Same conversation, new id."** The same report: residents that resumed fine came back under new ids (Claude
  Code 2.1.314 appears to resume into a new id), so "the id after a restart is the id before" no longer holds; a
  consumer's check should compare conversations, not ids. A wake that comes back under another id is the agent's
  session when that session continues the old one: its job's `resumeSessionId` is the old id, or Claude Code said
  it woke the old session and named the new one (`woke session <old>` with `backgrounded · <new>`), or the new
  transcript names the old id. The new id is recorded, the old one kept in the record, and one line names both
  (`woken; Claude Code continues its conversation under a new id, <new> (was <old>)`). A copy Claude Code says it
  started (`started a copy as <id>`) never counts. On 2.1.308 (checked again for this release) a bare wake keeps
  the id, including that of a session never prompted, which also has no transcript there; 1.9.1's "the same id"
  holds on 2.1.308 only.
- **The old session is never left as a second copy.** After a wake under a new id, the old session is stopped by
  its id if it still has a process (an interactive one is left, with a line). Without one it is left (never
  removed) and marked superseded in the record (a seventh field, the sessions the agent left, also filled when it
  starts fresh in place of a gone or crashed session). `list` prints a superseded session without a process as
  `<name> (superseded)`, which is no name of the agent's, so `agents` never counts it as another copy, and the CLI
  adapter never wakes or attaches it as the agent again.
- **Facts checked on Claude Code 2.1.308** (a throwaway `factcheck-nt` session, haiku, never prompted, in a trusted
  folder, stopped by its id): such a session has no transcript; its job's `state.json` has `sessionId` and
  `resumeSessionId` (equal); `daemon.log` sits at `$CLAUDE_CONFIG_DIR/daemon.log` and logs a crashed wake as
  `bg settled <short> (crashed): source session <id> not found`; a bare wake of the never-prompted session continued
  the same id. The 2.1.314 crash and the new id on resume are taken from the consumer's report and modelled in the
  unit tests' fake `claude`; they could not be reproduced here. `agents` 2.1.1 words its line about a new id
  neutrally (it said the old session "was not woken").

## [1.9.3] - 2026-10-30

### Changed

- **Extra saved options never turn a wake into a copy.** Reported by a consumer after 1.9.1: residents whose entries
  in `agents.yml` had `args: [--remote-control]` still came back as copies. Their sessions' saved options were
  `--name mhs --remote-control --model sonnet`: the `--model sonnet` was never passed by the agents Feature or the
  CLI adapter, Claude Code saved it from the room's `.claude/settings.json` (`"model": "sonnet"`). The bare-wake
  check required the saved options to equal `--name <name>` plus the agent's args, saw an extra `--model`, woke with
  flags, and Claude Code started a copy (`the flags you passed started a copy as ...`) that lost the conversation.
- **A wake of an existing session is always bare.** The CLI adapter compares the saved options with what the
  agent wants (`--name` as any name the agent's session has had, 1.9.0, and its args, `--remote-control` left out as
  before) and treats a wanted option that is present with the same value as met, in any order; saved options beyond
  those are no difference. A wanted option that is missing, or saved with another value, is still woken bare, with one
  line on stderr naming it (for example `lack or differ in: --model opus`). `wake` and `attach` of an ended session
  both follow this, and neither ever passes flags to `--bg --resume` any more (that path is removed). When the saved
  options cannot be read the session is woken bare too, with a line saying so.
- **The trade.** A changed `args` entry in `agents.yml` no longer reaches a session that already exists: the session
  keeps the options it was started with, and the changed ones apply at the agent's next fresh start (`agents reset`,
  or the session gone). Losing a resident's conversation is the failure to avoid, so the options give way, not the
  conversation. A session found gone is still started fresh with the agent's flags, as a new session.

## [1.9.2] - 2026-10-30

### Changed

- **A finished resident with a live process is running, not stopped.** Reported against 1.9.1: every `agents up`
  stopped and re-woke a resident that had finished its turn. Claude Code keeps such a session (`state: done`) as a
  process, waiting for a prompt, until it is stopped; 1.8.7 listed it `stopped` so that a wake would stop it first,
  and the agents Feature, seeing `stopped`, woke it every time. The CLI adapter now lists any session with a pid
  `running` (its activity `idle`, so `session-busy` says it is not mid-turn), so `agents up` joins it: no stop, no
  resume, no start. `stop` (and `session-stop`) end it by its id like any running session. `wake` of it is refused
  (nothing to wake; `attach` goes to the live process), so no `--bg --resume` is ever run on a live process (that
  starts a copy, 1.8.7). The stop-then-wake path of 1.8.7 (`stop_done`) is removed: a session reaching `wake` has no
  process.
- **A `blocked` session with no process is stopped.** It was listed `running` although nothing ran, so nothing woke
  it. It is now `stopped`, and a wake resumes it bare under its own id (1.9.1). `blocked` with a pid is still running.
- **Corrections to earlier notes** (the history below is kept, each marked): saved options keep the order they were
  given (1.8.7's "fixed order" was wrong; corrected in 1.9.1), and the `"state"` in Claude Code's `state.json` is not
  authoritative (1.8.3's check on it was wrong; 1.9.1 stopped consulting it).

## [1.9.1] - 2026-10-30

### Changed

- **Residents wake into their own session after a container restart.** Reported by a consumer: after each of two
  restarts, 8 of 9 residents came back as new sessions. The cause was the adapter's own guard, not Claude Code.
  Facts checked on Claude Code 2.1.308 against a background service of its own, killed the way a restart does
  (processes gone, job files kept):
  - A session started with `--bg` and no prompt keeps `"state": "working"` (tempo `blocked`, detail
    `(idle — send a prompt to start)`) in its `state.json` while it waits. Once its process and the background
    service are gone, `claude agents --json --all` lists it `failed`, but the file keeps saying `working`. The
    service writes `failed` (same detail) only when it starts again, and the next `claude --bg` starts it. So the
    consumer's `failed` + `(idle — send a prompt to start)` is Claude Code's own record, written by the wake.
  - A bare `claude --bg --resume <id>` of that session continues the same id with its saved options (`note: woke
    session <id> with its saved options`), even though the file still said `working`. It is the adapter that used
    to see `working`, decide that a bare wake would start a copy (1.8.3), and wake it with `--name` and the args.
    Claude Code then started a copy under a new id (`the flags you passed started a copy as <id>`). The adapter
    no longer consults `state.json`'s state at all.
  - A finished session (`done`) whose process is gone needs no stop: 1.8.7's stop-then-resume applies only when the
    list shows a pid. A bare wake continues it under its own id, and it comes back idle with a pid and its state
    still `done`. The adapter listed it `stopped` (1.8.7), so the wake waited for "running" until
    `AGENT_ADAPTER_WAIT` ran out (`not recorded`) and printed no id, and the agents Feature carried its lease as
    `session:unknown`. The woken session now counts once it has a pid, whatever its state. When Claude Code says it
    woke that very session (`woke session <short id>`, `backgrounded · <short id>`) and the list does not show it
    yet, the adapter records it and prints its id. In neither case is there a fresh start.
  - A fresh start still happens only when Claude Code says the session is gone (`source session <id> not found`,
    1.8.6).
- **`--remote-control` is saved.** Claude Code keeps it in `respawnFlags` where it was given, for example `--name n
  --remote-control --model m`. The bare-wake comparison still leaves it out on both sides, so turning
  `remoteControl` on does not make the wake of a session started without it a copy (1.8.8).
- **Saved options keep the order they were given.** `--model haiku --remote-control --agent a --settings s --name n`
  was saved in exactly that order, so 1.8.7's "fixed order" was wrong. Saved and wanted options are now both put in
  one order before they are compared (`--name`, `--settings`, `--agent`, `--model`, then the rest as given, with
  the last value of a repeated option winning), so the order never decides between a bare wake and a copy.

## [1.9.0] - 2026-10-30

### Changed

- **Session names: `AGENT_SESSION_NAME`.** The CLI adapter (`agent-adapter-claude`) reads the environment variable
  `AGENT_SESSION_NAME`, the name the caller (the `agents` Feature, from its template) wants the session to show.
  When it is not empty it is the session's `--name` on every start (`start-bg`, `new`, a wake that has to start a
  copy, and the fresh start after a session is gone); when it is empty or unset the handle is the name, as before.
  The adapter checks nothing about the template (the caller renders and checks it); it only refuses a value with a
  line break or tab (the handle is used, and it says so). The argument `<name>` stays the agent's handle: it keys the
  record, the lease and every verb. A CLI adapter that cannot name sessions ignores the variable (the NFR-12
  fallback), so there is no `supports` line for it.
- **Fact it rests on.** A name given with `--name` is pinned (`nameSource: user` in the job's `state.json`): Claude
  Code does not retitle such a session, through its first turn, a stop and a bare wake (checked on Claude Code
  2.1.308; the session-names proposal, "Facts checked").
- **A changed name never makes a second session.** The record (`agents.tsv`) keeps, besides the ids, the name the
  session was started with and up to five names before it (two more columns; an older record without them still
  works). The agent's session is found by its record, and otherwise by any name it has had in its folder: the
  session name now, the handle, the recorded name and the recorded earlier names (`host (2)` too). The bare-wake
  comparison accepts a saved `--name` equal to any of those, so a template that changed between starts wakes the
  same session bare, with its conversation, under the name it has. A bare wake also records the name it keeps.
  `record` with no running session clears the ids and keeps the names.
- **A changed name applies at the next fresh start**, not to a running or ended session: the adapter does not
  rename (Claude Code has `/rename` interactively and nothing from outside; NFR-13). A call without
  `AGENT_SESSION_NAME` (a nested call) wakes the same session bare and renames nothing. A session found by neither
  record nor any of those names (a lost record, started under a name the template no longer gives) is not found.

## [1.8.8] - 2026-10-29

### Changed

- **`remoteControl` option: Remote Control on for every agent.** `"remoteControl": true` makes the CLI adapter
  (`agent-adapter-claude`) add `--remote-control` to every session it starts (`start-bg`, `new`) and to a wake that
  starts it again, so `agents.yml` need not repeat `args: [--remote-control]` per agent. Default `false`: nothing
  changes. The option is baked into `/usr/local/share/claude-code/remote-control`;
  `AGENT_ADAPTER_CLAUDE_REMOTE_CONTROL=0` or `1` overrides it for one run
  (`AGENT_ADAPTER_CLAUDE_REMOTE_CONTROL_FILE` moves the file, for tests).
- **Per agent.** An agent whose args already have `--remote-control` is not given a second one. Claude Code has no
  off flag, so `--no-remote-control` in an agent's `args` is the CLI adapter's own opt-out: the adapter removes it
  and adds nothing (it is never passed to `claude`).
- **Wake.** Claude Code's saved options are documented only as `--name`, `--settings`, `--agent`, `--model`; whether
  it saves `--remote-control` was not checked in a real session. The bare-wake comparison therefore ignores
  `--remote-control` on both sides, so turning the option on does not make every wake a copy. If Claude Code does
  not save it, a bare wake brings the session back without Remote Control: to be checked on the workstation.

## [1.8.7] - 2026-10-29

### Changed

- **A wake of a finished session whose process is still alive stops it first.** (Superseded in 1.9.2: such a session
  is now listed running and joined, never woken; the stop-then-wake path is gone.) Claude Code leaves a session
  whose state is `done` running as a process (a pid in `claude agents`) until it is stopped, and `claude --bg
  --resume <id>` of it starts a copy under a new id with empty saved options ("already running"). The adapter now
  lists such a session as `stopped` (its pid kept), and `wake` (and `attach`) run `claude stop <short id>` for that
  one session, wait (`AGENT_ADAPTER_WAIT`, default 10 s) until it has no pid, then resume it. No other session is
  ever stopped.
- **The bare-wake check compares the options in Claude Code's order.** (Corrected in 1.9.1: the order is the one
  given, not a fixed one; both sides are now put in one order before they are compared.) Claude Code saves a session's options in a
  fixed order (`--name`, `--settings <path>`, `--agent <name>`, `--model <m>`, only those present), not the order
  of the args in `agents.yml`; the adapter compared them as given, so a different order looked like a change and
  woke the session with flags, which starts a copy. Both sides now use Claude Code's order (a repeated flag keeps
  the last value). Any other arg is assumed saved after those four, in the order given. Checked on Claude Code
  2.1.308. A wake given a prompt with `--resume` does not start a copy; wake does not use that.

## [1.8.6] - 2026-10-29

### Changed

- **A wake whose session is gone starts the agent fresh.** When `claude --bg --resume <session id>` fails
  because the session no longer exists (the job's `state.json` says `detail: source session <id> not found`, or
  claude printed it), `wake` (and `attach` of an ended session) starts the agent as `start-bg` does, with
  `--name <name>` and its args, records it and prints its id; stderr says `session <id> is gone; started
  fresh.` Any other wake failure still fails. Reported by a consumer whose resident stayed failed after a restart.

## [1.8.5] - 2026-10-28

### Changed

- **The downloads retry every error.** The channel file, the manifest and the binary go through
  `dcf_curl`, the collection's download helper (vendored from `common`): `--retry 3`, and on curl
  7.71+ `--retry-all-errors`, so a TLS reset (curl exit 35) or a connection cut mid-transfer (exit 56)
  no longer fails a no-cache rebuild. The checksum check is unchanged. No option or behavior change.

## [1.8.4] - 2026-10-28

### Changed

- **The example pins Node.** "Augment, don't duplicate" now shows the node Feature with
  `"version": "24"` instead of its moving `lts` default, which broke builds when Node 26.13.0
  became LTS. Documentation only; the Feature itself is unchanged.

## [1.8.3] - 2026-10-28

### Changed

- **A woken agent runs with its options from `agents.yml`, and keeps its name.** Claude Code puts a background
  session's saved options (the flags it was started with) back when it is woken with a bare `claude --bg --resume
  <session id>` or `claude attach <id>`, and starts a copy under a new id when any flag is given with `--resume`
  (Claude Code 2.1.308). `wake`, and `attach` of an ended session, now compare those saved options with what
  `start-bg` passes (`--name <name>` and the agent's args): the same, the session is woken bare (same id, same
  conversation); different, or not readable, it is woken with `--name <name>` and the args, so it never runs without
  its `--agent`, `--settings` or name (a copy, said on stderr, recorded as the agent's). The same when the
  session's own state in Claude Code's job file still says running although the list shows it ended (after a
  rebuild), where a bare wake would start a copy without any options. (Corrected in 1.9.1: that file's state is not
  authoritative; a bare wake of such a session continues it, so the adapter no longer consults it.) `attach` of an ended session
  wakes it that way first, then attaches. Reported after a rebuild, where three residents came back without their
  agent definition and register identity, listed by id rather than name.

## [1.8.2] - 2026-10-28

### Fixed

- Installs retry every download error, no early-closing grep -q under pipefail (cloud-folder 1.1.1, claude-code 1.8.2, git 1.4.4) ([#89](https://github.com/nabil-becker/devcontainer-features/pull/89))

## [1.8.1] - 2026-10-28

### Fixed

- Reset's plan reads right, a refusal exits 2, one line per removal (agents 1.0.2, claude-code 1.8.1) ([#86](https://github.com/nabil-becker/devcontainer-features/pull/86))

## [1.8.0] - 2026-10-28

### Changed

- **`additionalDirectories`** (new option): folders every Claude session may read and edit, without a
  wrapper adding `--add-dir` (below).
- **`agent-adapter-claude` reads the session list sturdily**: the JSON array is taken even when other
  lines come before or after it; a read that times out or prints nothing is tried once more with a
  longer time-out; when it fails, the message says why (the exit code or the time-out, and Claude
  Code's own first line), and names a wrapper in front of `claude` when Claude Code answers
  `unknown option`. `resume` on an unreadable list opens Claude Code's own picker, never a new
  session; a new `hint` verb tells the `agents` Feature how to resume by hand.
- **The adapter keeps its own record of each agent's session**, so a session Claude Code retitles after a prompt is
  still the agent's (1.7.0 found it by name only, so a retitled resident looked stopped and was started again), and
  adds the verbs `record`, `session-busy`, `session-stop` and `session-remove` for `task agents:reset`.

## [1.7.0] - 2026-10-27

### Added

- One agent list, two kinds, one verb for every agent CLI (agents 1.0.0, claude-code 1.7.0, devcontainer-cli 1.13.0) ([#84](https://github.com/nabil-becker/devcontainer-features/pull/84))

## [1.6.1] - 2026-10-24

### Fixed

- The pin follows Task's dotenv order; interactive sessions get the right advice (claude-code 1.6.1) ([#79](https://github.com/nabil-becker/devcontainer-features/pull/79))

## [1.6.0] - 2026-10-24

### Added

- The fleet waits for restored sessions, reports and stops duplicates (claude-code 1.6.0, devcontainer-cli 1.11.0) ([#76](https://github.com/nabil-becker/devcontainer-features/pull/76))

## [1.5.0] - 2026-10-23

### Added

- Claude-host resumes the live session after /clear; claude-fleet (claude-code 1.5.0, devcontainer-cli 1.9.0) ([#70](https://github.com/nabil-becker/devcontainer-features/pull/70))

## [1.4.1] - 2026-10-21

### Fixed

- Az installs the Azure CLI; Feature tasks run in the caller's folder ([#48](https://github.com/nabil-becker/devcontainer-features/pull/48))

## [1.4.0] - 2026-10-21

### Changed

- Claude-code 1.4.0: claude-host prints its session flags with CLAUDE_HOST_PRINT_FLAG=1 ([#37](https://github.com/nabil-becker/devcontainer-features/pull/37))

## [1.3.0] - 2026-10-15

### Changed

- Features/true up features ([#11](https://github.com/nabil-becker/devcontainer-features/pull/11))

## [1.1.0] - 2026-10-09

### Changed

- Add seven Features, a Feature Taskfile registry, development conventions and a repo devcontainer ([#5](https://github.com/nabil-becker/devcontainer-features/pull/5))

## [1.0.0] - 2026-10-09

### Changed

- Add go-task, devcontainer-cli and claude-code Features, host-side Taskfile and bootstrap ([#2](https://github.com/nabil-becker/devcontainer-features/pull/2))
