
# Claude Code (claude-code)

Claude Code (https://code.claude.com/docs) as a member of this collection's ecosystem: installs the sha256-verified native release binary at /usr/local/bin/claude (no Node.js, version pinnable) unless a claude is already in the image - e.g. from the official ghcr.io/anthropics/devcontainer-features/claude-code, which is then augmented instead of replaced - and adds the claude-host launcher (resume one session by UUID via HOST_SESSION, or the live session of the folder after a /clear), the claude-fleet command (several sessions in one terminal, never a second copy), a named volume mounted at CLAUDE_CONFIG_DIR (/var/lib/devcontainer-features/claude-code) so login and sessions survive rebuilds, a post-create hook that makes that directory usable by the remote user, and the Feature Taskfile. The in-app auto-updater is off; a rebuild updates.

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
| version | Native binary version to install (e.g. '2.1.286'), or a release channel: 'stable' or 'latest'. Ignored when an existing claude is kept (install=auto) or install=none. | string | stable |

## Customizations

### VS Code Extensions

- `anthropic.claude-code`

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
- **The live session of the folder wins** (claude-host, 1.5.0). `/clear` gives a session
  a new id, while the pinned id (`HOST_SESSION...` in `.devcontainer/.env`) keeps its old
  transcript, so "resume if the transcript exists" would run a second copy of one agent
  beside the live one. Before resuming, `claude-host` reads `claude agents --json` (it
  relies on the fields `sessionId` and `cwd`, as seen in Claude Code 2.1.308; the
  entries of interactive and background sessions both count) and looks for live
  sessions whose `cwd` is the current folder:

  | Live in this folder | claude-host does |
  | --- | --- |
  | nothing | as before: `--resume <pinned>` when its transcript exists, else `--session-id <pinned>` |
  | the pinned id | `--resume <pinned>` |
  | one other id | says so, `--resume <that id>`, and warns that the pin is stale |
  | two or more, none pinned | starts nothing, lists the ids on stderr, exits 1 |
  | `claude agents --json` missing or failing (older Claude Code) | one-line note, then as before |

  `CLAUDE_HOST_UPDATE_PIN=1` (also under `CLAUDE_HOST_PRINT_FLAG`) rewrites the stale pin:
  the one `HOST_SESSION...` line of `.devcontainer/.env` (found upwards from the folder,
  or `CLAUDE_HOST_ENV_FILE`) that holds the old id becomes the live id, quotes kept, no
  other line touched; it never creates the file, and refuses when not exactly one line
  holds the old id (`CLAUDE_HOST_PIN_VAR=<name>` names the variable). `CLAUDE_HOST_LIVE_CHECK=0`
  skips the check. The print-flag output follows the same decision (`--resume <live id>`).
  The JSON is read with `sed`, not jq or python, which the Feature does not install.
- **`claude-fleet`: several sessions in one terminal, never a second copy** (1.5.0). Bash
  like `claude-host`, for the same reason (no jq, no python; the container always has
  bash), installed beside it, run where `claude agents` runs. `SESSIONS` (environment, or
  `SESSIONS_B64` base64-encoded) holds one line per session,
  `name|session-variable|dir|extra claude args` (blank lines and `#` lines skipped; the
  extra args are split on whitespace, no quoting). Each variable's value (the session's
  UUID) comes from the environment, else `.devcontainer/.env`, since inside the container
  only `HOST_SESSION` is in the environment. For each line, against `claude agents --json`:
  variable unset: said, skipped; its id live, or any live session working in its folder
  (a `/clear`ed session has a new id there): running, not started (two or more live in
  one folder are reported); otherwise `cd <dir> && HOST_SESSION=<id> claude-host --bg <args>`
  (claude-host's own live check is off for these starts, the fleet has made it). Then
  `exec claude agents`. `-- --plan` prints what it would do and starts nothing; `-- --no-view`
  starts the missing ones and does not open the view. When the list cannot be read it
  starts nothing and exits 1. `task claude-code:fleet` runs it inside (SESSIONS in the
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


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/claude-code/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
