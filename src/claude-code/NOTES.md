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

- `claude-host` on PATH: start or resume **one** session by its UUID. With
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
  | one or more (the pinned id included) | starts nothing, prints each running id and pid and how to attach (`claude agents`, select it), exits 1; with `CLAUDE_HOST_PRINT_FLAG` it prints nothing and exits 1, so a wrapper does not start |
  | any, `CLAUDE_HOST_ALLOW_SECOND=1` | starts by the rule of the first row |
  | `claude agents --json` missing or failing (older Claude Code) | one-line note, then the first row |

  When the pinned id is not one of the running ids, the refusal also says the pin is stale.
  `CLAUDE_HOST_UPDATE_PIN=1` (manual path) then rewrites it when exactly one session runs:
  `claude-host-pin --replace <old> <new>` changes the one `HOST_SESSION...` line holding the old
  id in `.devcontainer/.env` (found upwards, or `CLAUDE_HOST_ENV_FILE`; `CLAUDE_HOST_PIN_VAR=<name>`
  restricts the variable), quotes kept, no other line touched, refusing unless exactly one line
  holds it. `CLAUDE_HOST_LIVE_CHECK=0` skips the check. The JSON is read with `sed`, not jq or
  python, which the Feature does not install. Deliberately not done: falling back to the newest
  transcript of the folder when the pin is stale. It is too implicit; the hook below makes it
  unnecessary.
- **`claude-host-pin`: keep the pin equal to the running id** (opt-in SessionStart hook, 1.5.0).
  The Feature manages no Claude Code settings, so a repository registers the hook in its
  `.claude/settings.json`:

  ```json
  {"hooks": {"SessionStart": [
    {"matcher": "startup|clear", "hooks": [{"type": "command", "command": "claude-host-pin"}]}
  ]}}
  ```

  Claude Code gives a SessionStart hook its input as JSON on stdin (`session_id`, `cwd`,
  `source`: `startup`, `resume`, `clear` or `compact`, among others). The hook finds
  `.devcontainer/.env` upwards from `cwd` (or `CLAUDE_HOST_ENV_FILE`), picks the variable the
  way `devcontainer:claude` does (the folder holding `.devcontainer` is the root:
  `HOST_SESSION`; a sub-folder: `HOST_SESSION_<its name, upper-cased, other characters _>`,
  `rooms/solis` gives `HOST_SESSION_SOLIS`) and writes `session_id` into that line, only when it
  differs, keeping `export`, quotes, comments and every other byte of the file. A UUID is
  required. A variable without a line is left alone (never adds one) unless
  `CLAUDE_HOST_PIN_CREATE=1` appends `VAR=<id>`. It always exits 0, notes go to stderr, so a
  session never fails because of it. The consumer's own write-back and second-copy check can go.
- **`claude-fleet`: several sessions in one terminal, never a second copy** (1.5.0; 1.6.0 below). Bash
  like `claude-host`, for the same reason (no jq, no python; the container always has
  bash), installed beside it, run where `claude agents` runs. `SESSIONS` (environment, or
  `SESSIONS_B64` base64-encoded) holds one line per session,
  `name|session-variable|dir|extra claude args` (blank lines and `#` lines skipped; the
  extra args are split on whitespace, no quoting). Each variable's value (the session's
  UUID) comes from `.devcontainer/.env` first, and from the environment only when `.env`
  has no line for that variable (1.6.0 reverses the earlier order: inside a session the
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
  - `claude-host`'s refusal now names `claude attach <id>` for each live id, and warns when the
    `HOST_SESSION` in the environment is in no line of `.devcontainer/.env` (it still uses it). `task claude-code:fleet` runs it inside (SESSIONS in the
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
