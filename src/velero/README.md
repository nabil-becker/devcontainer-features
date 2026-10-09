
# Velero CLI (velero)

Installs the Velero CLI (https://velero.io), for Kubernetes backup and restore, as a release binary at /usr/local/bin/velero, verified against the release's CHECKSUM file. Needs a kubeconfig at runtime (e.g. the kubectl-helm-minikube Feature plus KUBECONFIG).

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/velero:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| version | Velero release to install (e.g. '1.18.4', with or without a leading 'v'), or 'latest'. Match the Velero server deployed in your cluster. | string | latest |

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


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/velero/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
