## Changes in 1.8.0

- **`additionalDirectories`** (new option): folders every Claude session may read and edit, without a
  wrapper adding `--add-dir` (below).
- **`agent-adapter-claude` reads the session list sturdily**: the JSON array is taken even when other
  lines come before or after it; a read that times out or prints nothing is tried once more with a
  longer time-out; when it fails, the message says why (the exit code or the time-out, and Claude
  Code's own first line), and names a wrapper in front of `claude` when Claude Code answers
  `unknown option`. `resume` on an unreadable list opens Claude Code's own picker, never a new
  session; a new `hint` verb tells the `agents` Feature how to resume by hand.

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
| `wake` | the agent's newest stopped or failed session, by its full id: `cd <folder> && claude --bg --resume <session id>` (the same id and conversation; Claude Code 2.1.308 says `woke session ...`) |
| `attach` | `claude attach <id>` of its newest running session; an interactive one is refused with the pid and tty of the terminal that holds it |
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
<name>` start copies, so the adapter never uses them. The name is set with `--name` at start and
survives `/clear`, so nothing has to be written back. The JSON is read with `sed` (no jq or python
in the Feature), as `claude-host` does. Needs Claude Code 2.1.290 or later (session names).

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
  "ghcr.io/devcontainers/features/node:1": {},
  "ghcr.io/anthropics/devcontainer-features/claude-code:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {}
}
```

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
