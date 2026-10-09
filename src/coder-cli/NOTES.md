## Match the server version

The CLI warns on every command when it is newer or older than the `coderd`
it talks to. Pin `version` to the deployed server and bump both together:

```json
"ghcr.io/nabil-becker/devcontainer-features/coder-cli:1": { "version": "2.36.7" }
```

## Keep the login across rebuilds

`coder login` stores its session under `CODER_CONFIG_DIR` (default
`~/.config/coderv2`). Point it at a persisted folder:

```json
"containerEnv": {
  "CODER_CONFIG_DIR": "${containerWorkspaceFolder}/.devcontainer/env_mnt/coderv2"
}
```

## Verification

The tarball is checked against the release's `coder_<version>_checksums.txt`
before the binary is installed; the upstream `install.sh` performs no such
check.
