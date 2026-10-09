
# Claude Code (claude-code)

Installs Anthropic's Claude Code CLI (https://code.claude.com/docs) as its native, sha256-verified release binary at /usr/local/bin/claude - no Node.js required - and disables the in-app auto-updater so the pinned version is what runs. Persist login and sessions across rebuilds by pointing CLAUDE_CONFIG_DIR at a mounted folder (see the notes).

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
| version | Claude Code version to install (e.g. '2.1.286'), or a release channel: 'stable' or 'latest'. | string | stable |

## Customizations

### VS Code Extensions

- `anthropic.claude-code`

## Keeping login and sessions across rebuilds

Claude Code keeps credentials, settings and session history under `~/.claude`
and the OAuth account / per-project trust in `~/.claude.json`. Setting
`CLAUDE_CONFIG_DIR` moves *both* into one directory, so persisting that one
directory is enough. Two patterns:

**A folder inside the checkout** (resolves identically from Windows, WSL or
Codespaces, since the repo is always what gets mounted in; gitignore it):

```json
"containerEnv": {
  "CLAUDE_CONFIG_DIR": "${containerWorkspaceFolder}/.devcontainer/env_mnt/claude"
}
```

**A named volume** (the pattern from Anthropic's own docs):

```json
"mounts": [
  "source=claude-code-config-${devcontainerId},target=/home/vscode/.claude,type=volume"
],
"containerEnv": {
  "CLAUDE_CONFIG_DIR": "/home/vscode/.claude"
}
```

## Updating

`DISABLE_AUTOUPDATER=1` is set because the binary is root-owned and a user
session could not replace it anyway. Bump `version` (or leave it on `stable`)
and rebuild the container to update.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/claude-code/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
