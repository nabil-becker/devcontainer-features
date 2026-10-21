
# Claude Code (claude-code)

Claude Code (https://code.claude.com/docs) as a member of this collection's ecosystem: installs the sha256-verified native release binary at /usr/local/bin/claude (no Node.js, version pinnable) unless a claude is already in the image - e.g. from the official ghcr.io/anthropics/devcontainer-features/claude-code, which is then augmented instead of replaced - and adds the claude-host launcher (resume one session by UUID via HOST_SESSION), a named volume mounted at CLAUDE_CONFIG_DIR (/var/lib/devcontainer-features/claude-code) so login and sessions survive rebuilds, a post-create hook that makes that directory usable by the remote user, and the Feature Taskfile. The in-app auto-updater is off; a rebuild updates.

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
