## Changes in 1.9.1

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

## Changes in 1.9.0

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

## Changes in 1.8.8

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

## Changes in 1.8.5

- **The downloads retry every error.** The channel file, the manifest and the binary go through
  `dcf_curl`, the collection's download helper (vendored from `common`): `--retry 3`, and on curl
  7.71+ `--retry-all-errors`, so a TLS reset (curl exit 35) or a connection cut mid-transfer (exit 56)
  no longer fails a no-cache rebuild. The checksum check is unchanged. No option or behavior change.

## Changes in 1.8.4

- **The example pins Node.** "Augment, don't duplicate" now shows the node Feature with
  `"version": "24"` instead of its moving `lts` default, which broke builds when Node 26.13.0
  became LTS. Documentation only; the Feature itself is unchanged.

## Changes in 1.8.7

- **A wake of a finished session whose process is still alive stops it first.** Claude Code leaves a session
  whose state is `done` running as a process (a pid in `claude agents`) until it is stopped, and `claude --bg
  --resume <id>` of it starts a copy under a new id with empty saved options ("already running"). The adapter now
  lists such a session as `stopped` (its pid kept), and `wake` (and `attach`) run `claude stop <short id>` for that
  one session, wait (`AGENT_ADAPTER_WAIT`, default 10 s) until it has no pid, then resume it. No other session is
  ever stopped.
- **The bare-wake check compares the options in Claude Code's order.** Claude Code saves a session's options in a
  fixed order (`--name`, `--settings <path>`, `--agent <name>`, `--model <m>`, only those present), not the order
  of the args in `agents.yml`; the adapter compared them as given, so a different order looked like a change and
  woke the session with flags, which starts a copy. Both sides now use Claude Code's order (a repeated flag keeps
  the last value). Any other arg is assumed saved after those four, in the order given. Checked on Claude Code
  2.1.308. A wake given a prompt with `--resume` does not start a copy; wake does not use that.

## Changes in 1.8.6

- **A wake whose session is gone starts the agent fresh.** When `claude --bg --resume <session id>` fails
  because the session no longer exists (the job's `state.json` says `detail: source session <id> not found`, or
  claude printed it), `wake` (and `attach` of an ended session) starts the agent as `start-bg` does, with
  `--name <name>` and its args, records it and prints its id; stderr says `session <id> is gone; started
  fresh.` Any other wake failure still fails. Reported by a consumer whose resident stayed failed after a restart.

## Changes in 1.8.3

- **A woken agent runs with its options from `agents.yml`, and keeps its name.** Claude Code puts a background
  session's saved options (the flags it was started with) back when it is woken with a bare `claude --bg --resume
  <session id>` or `claude attach <id>`, and starts a copy under a new id when any flag is given with `--resume`
  (Claude Code 2.1.308). `wake`, and `attach` of an ended session, now compare those saved options with what
  `start-bg` passes (`--name <name>` and the agent's args): the same, the session is woken bare (same id, same
  conversation); different, or not readable, it is woken with `--name <name>` and the args, so it never runs without
  its `--agent`, `--settings` or name (a copy, said on stderr, recorded as the agent's). The same when the
  session's own state in Claude Code's job file still says running although the list shows it ended (after a
  rebuild), where a bare wake would start a copy without any options. `attach` of an ended session
  wakes it that way first, then attaches. Reported after a rebuild, where three residents came back without their
  agent definition and register identity, listed by id rather than name.

## Changes in 1.8.0

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

## Deprecated in 1.7.0: claude-host, claude-fleet, claude-host-pin

The [`agents`](../agents) Feature replaces them: a repository lists its agents in
`.devcontainer/agents.yml` (name, CLI, kind, folder, args) and starts any of them with
`task agents -- <name>` inside, `task devcontainer:agent -- <name>` from the host. No session id
is pinned anywhere, so `HOST_SESSION`, the `claude-host-pin` hook and `SESSIONS` go. This
release keeps the three scripts working; each prints one line on stderr saying it is deprecated
and that **claude-code 2.0 removes it** (`claude-fleet` says it once, not again for the
`claude-host` it calls). `task claude-code:host` and `task claude-code:fleet` say so in their
descriptions. The migration for a consuming repository is in
[docs/migrations/agents.md](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/migrations/agents.md).

## The agents adapter (`agent-adapter-claude`, 1.7.0)

Claude Code's adapter for the `agents` Feature, on PATH. The `agents` command calls it; nothing
else should. The contract (verbs, exit codes) is in the `agents` Feature's notes.

| Verb | What it runs |
| --- | --- |
| `start-bg` | `cd <folder> && claude --bg --name <name> <args>`; waits until the session is listed and prints its id |
| `wake` | the agent's newest stopped or failed session, by its full id: `cd <folder> && claude --bg --resume <session id>` (the same id and conversation; Claude Code 2.1.308 says `woke session ... with its saved options (--name, ...)`) when its saved options are `--name <name> <args>`; otherwise `... --resume <session id> --name <name> <args>`, which Claude Code starts as a copy with those options (1.8.3). If the session is gone (`source session <id> not found`), the agent is started fresh as `start-bg` does, and stderr says so (1.8.6) |
| `attach` | `claude attach <id>` of its newest running session; an interactive one is refused with the pid and tty of the terminal that holds it. With none running, `claude attach <id>` of its newest ended one when its saved options are the agent's (Claude Code restarts it with them), else it is woken as `wake` does and then attached (1.8.3) |
| `resume` | `cd <folder> && claude --resume <session id> <args>` of its newest session; refused while that session runs (a second process on one transcript). When the list cannot be read: `claude --resume <args>`, Claude Code's own picker (1.8.0) |
| `new` | `cd <folder> && claude --name <name> <args>` |
| `list` | `claude agents --json --all`: name, session id, state (a pid is running; failed; anything else stopped), folder, newest first |
| `hint` | how to find and resume the agent by hand (`claude agents`; `cd <folder> && claude --resume`, pick it), for when the list cannot be read (1.8.0) |
| `stop` | `claude stop <id>` of its newest running session; `--extras` stops every other running one instead. Never `claude rm`. |
| `logs` | `claude logs <id>` |

**Identity by name and folder, action by id.** A session is the agent's when its `cwd` is the
agent's folder and its `name` is the agent's name, or that name with Claude Code's collision
number (`host (2)`). `attach`, `stop` and `logs` take the session's short `id` from the list (the
full `sessionId` when there is none), never the name: `claude attach host` also matches part of a
name (`host-review`) and works only while the session runs, and `claude stop` takes an id only.
A stopped session is woken by its full id with `--bg --resume`; `--bg -c` and `--bg --resume
<name>` start copies, so the adapter never uses them. **Saved options (1.8.3).** Claude Code keeps the flags a background
session was started with (`respawnFlags` in `$CLAUDE_CONFIG_DIR/jobs/<id>/state.json`) and puts them back on a bare
wake; a flag given with `--bg --resume` starts a copy under a new id instead (`the flags you passed started a copy
as <id>`). So the adapter wakes bare only when the saved options are exactly `--name <name>` and the agent's args,
and its own `"state"` in that file is an ended one (`stopped`, `done`, `failed`), and otherwise passes them,
accepting a copy rather than an agent without its options. The state matters after a rebuild: the volume keeps the
last state (`running`) of a session whose process is gone, the list shows it ended, and a bare wake would make Claude
Code take it for a live session and start a copy with no options at all (no name, so listed by id). `attach` of an
ended session follows the same rule before it runs `claude attach <id>`. That file is Claude Code's
own, not a documented interface: when it cannot be read the adapter passes the options. The name is set with `--name` at start and
survives `/clear`, so nothing has to be written back. The JSON is read with `sed` (no jq or python
in the Feature), as `claude-host` does. Needs Claude Code 2.1.290 or later (session names).

**Records (1.8.0).** Claude Code can retitle a background session after a prompt, so the name given with `--name`
does not always stay (a resident started as `framework` was listed as "d47 d50 personalization medallion"). No setting
turns that off, and there is no command to rename a session from outside (Claude Code's docs: `-n`/`--name`, `/rename`
and `Ctrl+R` in agent view; a name set with `/rename` is kept). So the adapter records, when it starts, wakes or opens
an agent's session, the agent's name and folder with the session's short job id and full session id, in
`$CLAUDE_CONFIG_DIR/agent-adapter-claude/agents.tsv` (the Feature's volume, so it survives a rebuild; folder 700,
file 600; `AGENT_ADAPTER_CLAUDE_STATE` moves it; never in the repository, and not a pin: nothing has to be kept by
hand). `new` chooses the session id itself (`--session-id`) and records it before the session starts. A recorded
session still in `claude agents --json --all` is the agent's whatever its name now is, and `list` prints it under the
agent's name and folder, before the agent's other sessions:

- found by its job id with a new session id (a `/clear` starts a new conversation in the same job): followed, the
  record updated, and said on stderr;
- found by its session id under a new job id (a wake that started a copy): followed, updated, said;
- not listed any more (removed): the name and folder find the agent, as before, and that is said.

Matching by name, a running session (a pid, or a background state of working, blocked, busy, waiting or idle) always
wins over ended ones (done, stopped, failed); an ended one is woken only when none runs. `start-bg` refuses when the
agent's recorded session runs (never a second one).

| Verb | What it runs |
| --- | --- |
| `record` | records the agent's running session (the one the lookup picks), or clears its record when none runs |
| `session-busy <id>` | exit 0 when that session is mid-turn: `status` `busy` (a live process) or background `state` `working`; exit 1 when it is idle, `waiting` for input, `blocked` on a decision or ended; exit 3 when a running session says neither |
| `session-stop <id>` | `claude stop` of the session with that id (from `list`); an interactive one is refused |
| `session-remove <id>` | `claude rm` of that ended session (Claude Code keeps the transcript and a worktree with unpushed work); a running one is refused |

**Reading the list (1.8.0).** `claude agents --json --all` runs within
`AGENT_ADAPTER_CLAUDE_TIMEOUT` seconds (default 30), its output to files (a process that keeps a pipe
open cannot hang it); plain `--json` is asked only when Claude Code refuses `--all` as unknown (an
older release), since a list without the stopped sessions would wake nothing. The array is taken
from the first line starting with `[` through its end, so a notice before or after it does no harm.
A read that timed out or printed nothing is tried once more after `AGENT_ADAPTER_CLAUDE_PAUSE`
seconds (default 3) with three times the time-out; a quick error with a message is not, since it
would not change. A failure says the call, its exit code or time-out and its first line (cut to 160
characters), for example

```
agent-adapter-claude: the session list could not be read: 'claude agents --json --all' exited 1: error: unknown option '--json'. A wrapper or alias in front of claude may be rewriting its arguments: claude here is /usr/local/bin/claude.
```

That one is what a wrapper putting `--add-dir <dir>` before every argument causes: `--add-dir`
takes any number of folders, swallows `agents`, and plain `claude` refuses `--json`. Drop the
wrapper and use the `additionalDirectories` option instead.

Not verified against a live `claude --bg` in CI: the unit tests (`task test:claude-unit`) use a
fake `claude`; the calls rest on the facts checked live on Claude Code 2.1.308 (the agents
proposal, section 7). A background session in a folder Claude Code has never trusted fails to
start (`Workspace not trusted`): run `claude` there once and accept.

## Additional working directories (`additionalDirectories`, 1.8.0)

`"additionalDirectories": "/workspaces/shared, ~/notes"` gives every Claude session in the container
those folders as working directories (read and edit them as it does the folder it starts in), the
persistent form of `--add-dir`. The Feature writes them at build time as Claude Code's
`permissions.additionalDirectories` to a managed-settings drop-in the image owns,
`/etc/claude-code/managed-settings.d/50-devcontainer-features-claude-code.json`:

```json
{"permissions":{"additionalDirectories":["/workspaces/shared","/home/vscode/notes"]}}
```

- **Why there:** the user's own `settings.json` (in the Feature's volume) is never rewritten, and a
  rebuild writes the file afresh, so a folder taken out of the option is gone again. Claude Code
  combines lists across settings files, so folders from the user's, the project's or local settings
  still apply beside these; managed settings need no workspace trust (a project's
  `.claude/settings.json` list does).
- **Paths:** comma-separated; absolute, or `~` / `~/...`, which the Feature expands at build time to
  the remote user's home (the file holds absolute paths only). Spaces inside a path are kept, spaces
  around a comma dropped. A relative path or `~user` fails the build with the reason. A folder need
  not exist at build time (a mount appears later). Empty (the default): nothing is written.
- **File access only:** unlike `--add-dir`, a folder listed in settings does not load its
  `CLAUDE.md`, skills, subagents or other `.claude/` configuration (Claude Code's permissions docs,
  "Additional directories grant file access, not configuration"). A repository that relied on that
  keeps `--add-dir` for that one session, or moves the configuration into the repository.
- **Limit:** managed settings rank by source, and by default (`managedSourcesBehavior`
  `first-wins`) Claude Code uses only the highest source that holds a policy. When your organization
  delivers server-managed settings (the claude.ai admin console) or an MDM policy, this file is
  skipped and the folders do not apply; `/status` shows the `Setting sources` it used. That is not
  verified here; tell us if it happens.

**Migrating from a wrapper:** a repository that wraps `claude` (for example a `/usr/local/bin/claude`
that runs the real one with `--add-dir <dir>` first) drops the wrapper and sets this option to the
same folders. Such a wrapper also breaks every `claude <command>` (`--add-dir` swallows the
command's name; `claude agents --json` then fails with `unknown option '--json'`), which is what
`task agents:list` showed as `error`.

## Augment, don't duplicate

With the default `install: auto` this Feature keeps a `claude` that is
already in the image and adds only the ecosystem pieces around it, so it
composes with the official Feature:

```json
"features": {
  "ghcr.io/devcontainers/features/node:1": { "version": "24" },
  "ghcr.io/anthropics/devcontainer-features/claude-code:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {}
}
```

Pin Node to a major rather than the node Feature's default `lts`: when a new LTS lands, `lts`
moves with it on the day, and Node 26.13.0 (2026-10-28) broke builds that way (it needs
`libatomic1`, which Debian bookworm images lack, and its checksum was briefly unreadable).

`installsAfter` orders this one after the official Feature (and after the
`node` Feature it needs). On its own, or with `install: native`, it installs
the native release binary instead: sha256-verified against the release
manifest, pinnable with `version`, no Node.js. The official Feature pins no
version and verifies nothing, which is why this installer still exists.

What the Feature adds in both cases:

- `agent-adapter-claude` on PATH (1.7.0, above).
- With `additionalDirectories` set, the managed-settings drop-in under `/etc/claude-code/managed-settings.d` (1.8.0, above).
- `claude-host` on PATH (deprecated in 1.7.0, see the top): start or resume **one** session by its UUID. With
  `HOST_SESSION=<uuid>` set it runs `claude --resume <uuid>` when that
  session's transcript exists for the current directory, else
  `claude --session-id <uuid>` to create it; unset, a plain `claude` with a
  hint. Names given with `/rename` are labels; the UUID (shown by `/status`)
  is the handle. `task claude-code:host` inside, `task devcontainer:claude`
  from the host machine (the `bootstrap/devcontainer.yml` include, which
  reads `HOST_SESSION` from `.devcontainer/.env`). With
  `CLAUDE_HOST_PRINT_FLAG=1` it instead prints that decision, `--resume <uuid>`
  or `--session-id <uuid>`, on stdout and exits 0 without starting `claude`,
  so a launcher of your own (detached `claude remote-control` sessions, say)
  reuses it: `claude remote-control $(CLAUDE_HOST_PRINT_FLAG=1 claude-host)`.
  With `HOST_SESSION` unset it prints nothing and exits 0; an invalid UUID is
  still exit 2. Messages go to stderr.
- **A running session is never started a second time** (claude-host, 1.5.0). `claude --resume
  <id>` on a session that is still running opens a second process on the same transcript,
  and `/clear` gives a session a new id, so the pinned id (`HOST_SESSION...` in
  `.devcontainer/.env`) may not even be the running one. Before starting, `claude-host` reads
  `claude agents --json` (fields `pid`, `sessionId`, `cwd`, as seen in Claude Code 2.1.308) and
  looks for live sessions whose `cwd` is the current folder. Live means the entry has a
  `pid`: the list also holds ended sessions, without one (or with `null` or `0`), which never
  count.

  | Live in this folder | claude-host does |
  | --- | --- |
  | nothing | as before: `--resume <pinned>` when its transcript exists, else `--session-id <pinned>` |
  | one or more (the pinned id included) | starts nothing, prints each running id and pid and how to reach it (a background session: `claude attach <id>`; an interactive one, which `claude attach` cannot reach: the terminal that holds it, by pid and tty, to switch to, or Remote Control), exits 1; with `CLAUDE_HOST_PRINT_FLAG` it prints nothing and exits 1, so a wrapper does not start |
  | any, `CLAUDE_HOST_ALLOW_SECOND=1` | starts by the rule of the first row |
  | `claude agents --json` missing or failing (older Claude Code) | one-line note, then the first row |

  When the pinned id is not one of the running ids, the refusal also says the pin is stale.
  `CLAUDE_HOST_UPDATE_PIN=1` (manual path) then rewrites it when exactly one session runs:
  `claude-host-pin --replace <old> <new>` changes the one `HOST_SESSION...` line holding the old
  id in the first of the root `.env` and `.devcontainer/.env` that holds it (the lookup below; or `CLAUDE_HOST_ENV_FILE`; `CLAUDE_HOST_PIN_VAR=<name>`
  restricts the variable), quotes kept, no other line touched, refusing unless exactly one line
  holds it. `CLAUDE_HOST_LIVE_CHECK=0` skips the check. The JSON is read with `sed`, not jq or
  python, which the Feature does not install. Deliberately not done: falling back to the newest
  transcript of the folder when the pin is stale. It is too implicit; the hook below makes it
  unnecessary.
- **`claude-host-pin`: keep the pin equal to the running id** (opt-in SessionStart hook, 1.5.0; deprecated in 1.7.0).
  The Feature manages no Claude Code settings, so a repository registers the hook in its
  `.claude/settings.json`:

  ```json
  {"hooks": {"SessionStart": [
    {"matcher": "startup|clear", "hooks": [{"type": "command", "command": "claude-host-pin"}]}
  ]}}
  ```

  Claude Code gives a SessionStart hook its input as JSON on stdin (`session_id`, `cwd`,
  `source`: `startup`, `resume`, `clear` or `compact`, among others). The hook finds
  the repository's `.env` files upwards from `cwd` (or `CLAUDE_HOST_ENV_FILE`), in the order Task's
  `dotenv: ['.env', '.devcontainer/.env']` reads them (the root, the folder holding `.devcontainer`: its
  `.env`, then `.devcontainer/.env`; the first file that defines a variable wins, so the hook writes the
  line in the file that holds it, and `claude-host` and `claude-fleet` read the same way; 1.6.1, before
  that only `.devcontainer/.env` was looked at and a pin kept in the root `.env` went stale after a
  `/clear`), picks the variable the
  way `devcontainer:claude` does (the folder holding `.devcontainer` is the root:
  `HOST_SESSION`; a sub-folder: `HOST_SESSION_<its name, upper-cased, other characters _>`,
  `rooms/solis` gives `HOST_SESSION_SOLIS`) and writes `session_id` into that line, only when it
  differs, keeping `export`, quotes, comments and every other byte of the file. A UUID is
  required. A variable without a line is left alone (never adds one) unless
  `CLAUDE_HOST_PIN_CREATE=1` appends `VAR=<id>` to `.devcontainer/.env` (no file holds the variable). It always exits 0, notes go to stderr, so a
  session never fails because of it. The consumer's own write-back and second-copy check can go.
- **`claude-fleet`: several sessions in one terminal, never a second copy** (1.5.0; 1.6.0 below; deprecated in 1.7.0). Bash
  like `claude-host`, for the same reason (no jq, no python; the container always has
  bash), installed beside it, run where `claude agents` runs. `SESSIONS` (environment, or
  `SESSIONS_B64` base64-encoded) holds one line per session,
  `name|session-variable|dir|extra claude args` (blank lines and `#` lines skipped; the
  extra args are split on whitespace, no quoting). Each variable's value (the session's
  UUID) comes from the `.env` files first (root `.env`, then `.devcontainer/.env`; the first file with a
  line for the variable wins, as in Task), and from the environment only when none
  has a line for that variable (1.6.0 reverses the earlier order: inside a session the
  environment keeps the id the session started with, stale after a `/clear` or a fork, while
  the `claude-host-pin` hook keeps `.env` current). For each line, against `claude agents --json`:
  variable unset: said, skipped; its id live, or any live session working in its folder
  (a `/clear`ed session has a new id there): running, not started (two or more live in
  one folder are reported as duplicates, below); otherwise `cd <dir> && HOST_SESSION=<id> claude-host --bg <args>`
  (claude-host's own live check is off for these starts, the fleet has made it; a live session is one with a `pid`, ended entries never count). Then
  `exec claude agents`. `-- --plan` prints what it would do and starts nothing; `-- --no-view`
  starts the missing ones and does not open the view. When the list cannot be read it
  starts nothing and exits 1.

  1.6.0, from a consuming repository's lessons running four agents in one container:
  - **It waits for restored sessions.** After a rebuild the Claude daemon restores background
    sessions from this Feature's volume; starting sessions in that window races the restore and
    makes duplicates. Before reconciling, `claude-fleet` prints `waiting for restored
    sessions…` and reads `claude agents --json` until two reads `FLEET_SETTLE_INTERVAL` seconds
    apart (default 3) give the same set of live ids, for at most `FLEET_SETTLE_TIMEOUT` seconds
    (default 30; then it reconciles anyway with a one-line note). `-- --no-wait` skips it.
  - **Duplicates are reported, and stopped only on request.** When more than one live session
    matches an agent (by its id or by its folder), `-- --plan` and a normal run list each one
    (id, pid, age, whether a transcript exists) and mark the kept one (the id in `.env` if
    live, else the newest by `startedAt`) and the extras, then print the `--stop-duplicates`
    hint; nothing is stopped. `-- --stop-duplicates` stops the extras with `claude stop <id>`,
    which keeps the conversation (`claude attach <id>` resumes it), re-reads the list to confirm
    they are gone, and says so. A stopped extra is never restarted: the agent still has its kept
    session. `claude-fleet` never deletes a session (`claude rm` can delete its worktree, which
    is not Claude's to delete in a fleet); a test guards that.
  - `claude-host`'s refusal reads each live session's `kind` from `claude agents --json`: for a
    background session it names `claude attach <id>`; for an interactive one (`claude attach` fails
    there with "No job matching") it says a terminal holds it, naming the pid and the tty (`ps -o tty=`), and
    to switch to that terminal or use Remote Control (1.6.1). It also warns when the
    `HOST_SESSION` in the environment is in no line of the `.env` files (it still uses it). `task claude-code:fleet` runs it inside (SESSIONS in the
  environment); from the host, `task devcontainer:claude:fleet` (see the README), with
  `SESSIONS` set where the Taskfile includes `bootstrap/devcontainer.yml`:

  ```yaml
  includes:
    devcontainer:
      taskfile: ./.devcontainer/cli_bootstrap.ignore/devcontainer.yml
      vars:
        SESSIONS: |
          solis|HOST_SESSION_SOLIS|rooms/solis|--model sonnet
          atlas|HOST_SESSION_ATLAS|rooms/atlas|
  ```

  A repository that scripted this itself (a `scripts/agents.py` that reads `claude agents
  --json` and starts the missing sessions) can drop the script and keep only its
  `SESSIONS` list. Not verified against a real `claude --bg` here: the tests use a fake
  `claude`; `claude agents --json` output was read from Claude Code 2.1.308.
- `CLAUDE_CONFIG_DIR=/var/lib/devcontainer-features/claude-code` in
  `containerEnv` and a named volume mounted there, so login and sessions
  survive rebuilds without any configuration (see below).
- A `postCreateCommand` (`claude-code-setup`, also `task claude-code:setup`)
  that creates `CLAUDE_CONFIG_DIR` and chowns it to the remote user, since
  bind mounts and named volumes arrive root-owned, and reports what backs it
  (volume, bind or image), writability and whether a login is present.
- `DISABLE_AUTOUPDATER=1`: the binary is root-owned in every install mode, so
  a user session could not replace it anyway; bump `version` (or leave it on
  `stable`) and rebuild to update.

## Keeping login and sessions across rebuilds

Claude Code keeps credentials, settings and session history under `~/.claude`
and the OAuth account / per-project trust in `~/.claude.json`. Setting
`CLAUDE_CONFIG_DIR` moves *both* into one directory, so persisting that one
directory is enough.

By default nothing needs configuring: the Feature sets
`CLAUDE_CONFIG_DIR=/var/lib/devcontainer-features/claude-code` and mounts the
named volume `claude-code-config-${devcontainerId}` there (the pattern the
official docker-in-docker Feature uses for its storage). The volume survives
rebuilds and image updates. It does not survive a container-engine storage
reset or a move to another engine, and `${devcontainerId}` changes when the
checkout moves to another path, which leaves the old volume behind (`docker
volume ls` shows it; remove it by hand).

For the host disk (survives all of that; stays out of the checkout, so a
synced checkout such as OneDrive never carries transcripts), the repo
bind-mounts a host folder on the same target - a repo's `mounts` merge after
the Features' and the last source on a target wins - and creates the folder
with `initializeCommand` before the first start, since a bind mount with a
missing source fails (array form: a string goes through `cmd /c` on Windows,
which mangles quotes and `%VARS%`):

```json
"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "claude"],
"mounts": [
  "source=${localEnv:USERPROFILE}/.devcontainer-homes/myrepo/claude,target=/var/lib/devcontainer-features/claude-code,type=bind"
]
```

`CLAUDE_CONFIG_DIR` stays as the Feature sets it; the hook reports
`claude-code: /var/lib/devcontainer-features/claude-code (bind, writable)`
instead of `(volume, writable)` in the post-create log.

Two containers on the same config dir at once (one from VS Code, one from
the CLI) contend for `.claude.json.lock`; run one.
