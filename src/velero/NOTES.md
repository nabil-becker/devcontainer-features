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
"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "kube"],
"mounts": [
  "source=${localEnv:USERPROFILE}${localEnv:HOME}/.devcontainer-homes/myrepo/kube,target=/var/lib/devcontainer-features/kube,type=bind"
],
"containerEnv": {
  "KUBECONFIG": "/var/lib/devcontainer-features/kube/config"
}
```

The kubeconfig is cluster credentials, so it stays on the host disk outside
the checkout (never inside a synced checkout) rather than in a volume.

## Verification

The tarball is checked against the release's `CHECKSUM` file before the
binary is installed.
