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
