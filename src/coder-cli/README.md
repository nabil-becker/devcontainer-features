
# Coder CLI (coder-cli)

Installs the Coder CLI (https://coder.com) as a release binary at /usr/local/bin/coder, verified against the release's coder_<version>_checksums.txt. Pin version to your coderd server version to avoid 'version mismatch' warnings.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/coder-cli:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| version | Coder release to install (e.g. '2.36.7', with or without a leading 'v'), or 'latest'. Match your Coder server's version. | string | latest |

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


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/coder-cli/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
