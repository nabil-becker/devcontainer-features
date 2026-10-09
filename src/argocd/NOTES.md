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
