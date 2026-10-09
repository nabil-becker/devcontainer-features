
# Argo CD CLI (argocd)

Installs the Argo CD CLI (https://argo-cd.readthedocs.io) as a release binary at /usr/local/bin/argocd, verified against the release's cli_checksums.txt. Pin version to your Argo CD server version.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/argocd:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| version | Argo CD release to install (e.g. '3.5.4', with or without a leading 'v'), or 'latest'. Match your Argo CD server's version. | string | latest |

## Match the server

Pin `version` to the Argo CD server you talk to; the CLI and API surface
move together.

## Keep the login across rebuilds

`argocd login` stores its session under `ARGOCD_CONFIG_DIR` (default
`~/.config/argocd`). Point it at a persisted folder:

```json
"containerEnv": {
  "ARGOCD_CONFIG_DIR": "${containerWorkspaceFolder}/.devcontainer/env_mnt/argocd"
}
```

## Why not `ghcr.io/devcontainers-extra/features/argo-cd`?

That Feature resolves the binary through `nanolayer` and the generic
`gh-release` Feature at build time, without checksum verification. This one
downloads the release binary directly and checks it against the release's
`cli_checksums.txt`.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/argocd/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
