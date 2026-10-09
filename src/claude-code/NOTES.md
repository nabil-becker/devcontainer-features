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
