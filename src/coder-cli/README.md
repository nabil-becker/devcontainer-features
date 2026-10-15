
# Coder CLI (coder-cli)

Installs the Coder CLI (https://coder.com) as a release binary at /usr/local/bin/coder, verified against the release's coder_<version>_checksums.txt. Pin version to your coderd server version to avoid 'version mismatch' warnings. The login session lives in CODER_CONFIG_DIR at /var/lib/devcontainer-features/coder-cli, a named volume the Feature mounts so it survives rebuilds; the coder-cli-setup post-create hook hands the folder to the remote user.

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
`~/.config/coderv2`). By default the Feature sets
`CODER_CONFIG_DIR=/var/lib/devcontainer-features/coder-cli` in `containerEnv`
and mounts the named volume `coder-cli-config-${devcontainerId}` on that
folder, so the session survives rebuilds. Its `postCreateCommand` hook
`coder-cli-setup` (also `task coder-cli:setup`; idempotent, never fatal)
hands the folder to the remote user through the shared `dcf-persist` helper
and reports what backs it (`volume`, `bind` or `image`), whether it is
writable and whether a login is present (the session token is never
printed). A container-engine storage reset or a move to another engine
deletes the volume, and `${devcontainerId}` changes when the checkout moves,
leaving the old volume behind.

For the host disk, a repo bind-mounts a host folder on the same target (a
repo's `mounts` merge after the Features', so its mount wins) and creates it
before the first start:

```json
"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "coder-cli"],
"mounts": ["source=${localEnv:USERPROFILE}${localEnv:HOME}/.devcontainer-homes/myrepo/coder-cli,target=/var/lib/devcontainer-features/coder-cli,type=bind"]
```

A repo's own `containerEnv` wins over the Feature's, which is how it points
`CODER_CONFIG_DIR` somewhere else entirely.

## Verification

The tarball is checked against the release's `coder_<version>_checksums.txt`
before the binary is installed; the upstream `install.sh` performs no such
check.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/coder-cli/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
