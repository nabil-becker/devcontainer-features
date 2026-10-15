
# Argo CD CLI (argocd)

Installs the Argo CD CLI (https://argo-cd.readthedocs.io) as a release binary at /usr/local/bin/argocd, verified against the release's cli_checksums.txt. Pin version to your Argo CD server version. The login session lives in ARGOCD_CONFIG_DIR at /var/lib/devcontainer-features/argocd, a named volume the Feature mounts so it survives rebuilds; the argocd-setup post-create hook hands the folder to the remote user.

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
`~/.config/argocd`). By default the Feature sets
`ARGOCD_CONFIG_DIR=/var/lib/devcontainer-features/argocd` in `containerEnv`
and mounts the named volume `argocd-config-${devcontainerId}` on that
folder, so the session survives rebuilds. Its `postCreateCommand` hook
`argocd-setup` (also `task argocd:setup`; idempotent, never fatal) hands the
folder to the remote user through the shared `dcf-persist` helper and
reports what backs it (`volume`, `bind` or `image`), whether it is writable
and whether a login is present (a `contexts` entry in `config`; no token is
printed). A container-engine storage reset or a move to another engine
deletes the volume, and `${devcontainerId}` changes when the checkout moves,
leaving the old volume behind.

For the host disk, a repo bind-mounts a host folder on the same target (a
repo's `mounts` merge after the Features', so its mount wins) and creates it
before the first start:

```json
"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "argocd"],
"mounts": ["source=${localEnv:USERPROFILE}${localEnv:HOME}/.devcontainer-homes/myrepo/argocd,target=/var/lib/devcontainer-features/argocd,type=bind"]
```

A repo's own `containerEnv` wins over the Feature's, which is how it points
`ARGOCD_CONFIG_DIR` somewhere else entirely.

## Why not `ghcr.io/devcontainers-extra/features/argo-cd`?

That Feature resolves the binary through `nanolayer` and the generic
`gh-release` Feature at build time, without checksum verification. This one
downloads the release binary directly and checks it against the release's
`cli_checksums.txt`.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/argocd/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
