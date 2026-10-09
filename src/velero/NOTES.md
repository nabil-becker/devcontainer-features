## Match the cluster

The client should match the Velero server version deployed in the cluster
(`velero version` shows both). Pin `version` accordingly and bump it with
the server.

## Talking to a cluster

Velero uses the standard kubeconfig lookup (`KUBECONFIG` / `~/.kube/config`).
A typical pairing:

```json
"features": {
  "ghcr.io/devcontainers/features/kubectl-helm-minikube:1": { "minikube": "none" },
  "ghcr.io/nabil-becker/devcontainer-features/velero:1": { "version": "1.18.4" }
},
"containerEnv": {
  "KUBECONFIG": "${containerWorkspaceFolder}/.devcontainer/env_mnt/kube/config"
}
```

## Verification

The tarball is checked against the release's `CHECKSUM` file before the
binary is installed.
