
# Claude Code (claude-code)

Claude Code (https://code.claude.com/docs) as a member of this collection's ecosystem: installs the sha256-verified native release binary at /usr/local/bin/claude (no Node.js, version pinnable) unless a claude is already in the image - e.g. from the official ghcr.io/anthropics/devcontainer-features/claude-code, which is then augmented instead of replaced - and adds agent-adapter-claude (Claude Code's adapter for the agents Feature: task agents -- <name> finds a session by its name and folder and acts on it by id), the deprecated claude-host launcher, claude-fleet command and claude-host-pin hook (still working, each printing one deprecation line; claude-code 2.0 removes them), a named volume mounted at CLAUDE_CONFIG_DIR (/var/lib/devcontainer-features/claude-code) so login and sessions survive rebuilds, a post-create hook that makes that directory usable by the remote user, and the Feature Taskfile. The in-app auto-updater is off; a rebuild updates.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| install | How the claude binary gets there. 'auto': keep a claude already in the image (official Feature, base image) and only add the ecosystem pieces, else install the native binary. 'native': always install the verified native binary at /usr/local/bin/claude (wins over an npm install on PATH). 'none': never install the binary, only the pieces. | string | auto |
| additionalDirectories | Comma-separated folders every Claude session in the container may read and edit besides the one it starts in (Claude Code's permissions.additionalDirectories), written at build time to the managed-settings drop-in /etc/claude-code/managed-settings.d/50-devcontainer-features-claude-code.json, so no wrapper adding --add-dir is needed and the user's own settings are not touched. Absolute paths, or ~/... for the remote user's home (expanded at build time); a relative path fails the build. Empty: nothing is written. File access only: unlike --add-dir, a folder listed here does not load its CLAUDE.md, skills or other .claude/ configuration. | string | - |
| remoteControl | Start every Claude agent the agents Feature runs with Remote Control on (--remote-control), so agents.yml need not repeat it in each agent's args. Applied by agent-adapter-claude to the sessions it starts or wakes, unless an agent's args already have --remote-control or --no-remote-control (the adapter's own per-agent opt-out). Per run: AGENT_ADAPTER_CLAUDE_REMOTE_CONTROL=0 or 1. | boolean | false |
| version | Native binary version to install (e.g. '2.1.286'), or a release channel: 'stable' or 'latest'. Ignored when an existing claude is kept (install=auto) or install=none. | string | stable |

## Customizations

### VS Code Extensions

- `anthropic.claude-code`

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
| `wake` | the agent's newest stopped or failed session, by its full id: `cd <folder> && claude --bg --resume <session id>` (its conversation, under the same id on Claude Code 2.1.308, which says `woke session ... with its saved options (--name, ...)`; 2.1.314 may answer under a new id, which is recorded when it continues the conversation, 1.9.4), always bare (1.9.3); a line says when its saved options lack or differ from `--name <name> <args>`; extra saved options are no difference. If the session is gone (`source session <id> not found`, 1.8.6), has no transcript, or the wake crashes with "not found" within `AGENT_ADAPTER_SETTLE` seconds (1.9.4), the agent is started fresh as `start-bg` does, and stderr says so |
| `attach` | `claude attach <id>` of its newest running session; an interactive one is refused with the pid and tty of the terminal that holds it. With none running, its newest ended one is woken first as `wake` does (bare, a new id recorded, the old one superseded) and the session that then runs is attached (1.9.6; it was `claude attach <id>` of the ended one, which let Claude Code restart it as an unrecorded copy) |
| `resume` | `cd <folder> && claude --resume <session id> <args>` of its newest own conversation (1.9.5): its recorded session, its listed interactive sessions and the ended ones found only by their transcript in the folder (an interactive session leaves the list when it ends), newest by transcript; never a background session that is not its recorded one. Refused while one of them runs (a second process on one transcript). When the list cannot be read: `claude --resume <args>`, Claude Code's own picker (1.8.0) |
| `new` | `cd <folder> && claude --name <name> <args>` |
| `list` | `claude agents --json --all`: name, session id, state (a pid is running when that process is Claude Code's and runs here (1.9.6: a pid left by a container restart is not), a finished `done` session with a live process included (1.9.2); `blocked` without a live pid is stopped; failed; anything else stopped), folder, newest first |
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
as <id>`). So 1.8.3 woke bare only when the saved options were exactly `--name <name>` and the agent's args
(and its own `"state"` in that file an ended one), and otherwise passed them, accepting a copy rather than an agent
without its options. **Corrected in 1.9.3:** a wake is always bare and extra saved options are no difference (see
the CHANGELOG, 1.9.3). **Corrected in 1.9.1:** the state in that file is not
authoritative (after a restart it still says `working` for a session that was idle, and a bare wake continues it), so
it is no longer consulted; only the saved options are compared, and they keep the order they were given. `attach` of an
ended session follows the same rule before it runs `claude attach <id>`. That file is Claude Code's
own, not a documented interface: when it cannot be read the adapter wakes bare and says so (1.9.3). The name is set with `--name` at start and
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

## Changes

### [1.9.8] - 2026-11-03

#### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

### [1.9.7] - 2026-11-03

#### Changed

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

### [1.9.6] - 2026-10-31

#### Changed

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

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/claude-code/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/claude-code/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
