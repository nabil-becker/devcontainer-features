
# Kubernetes client config (kube-state) (kube-state)

Owns the kubeconfig for the Kubernetes tools in the image (kubectl, velero, kustomize, argocd, ...): sets KUBECONFIG=/var/lib/devcontainer-features/kube-state/config and mounts a named volume on /var/lib/devcontainer-features/kube-state, so a kubeconfig imported once survives rebuilds and no repo hand-mounts ~/.kube. Installs no kubectl itself (add ghcr.io/devcontainers/features/kubectl-helm-minikube before it if you want one). Adds a post-create hook (kube-state-setup) that makes the directory usable by the remote user, keeps the kubeconfig private to it, and reports whether a kubeconfig and a current context are present. Plus the Feature Taskfile.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/kube-state:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| restrictPermissions | At post-create, chmod the kubeconfig file to 0600 when it exists (kubectl and helm warn about a group- or world-readable one; it holds credentials). Override per container with KUBE_STATE_SETUP_RESTRICT_PERMISSIONS in containerEnv. | boolean | true |

## State only: no kubectl installed

This Feature owns the kubeconfig the Kubernetes tools in the image share
(`kubectl`, `velero`, `kustomize`, `argocd`, `kubeconform`), the way `gh`
and `az` own their logins. It installs no binary: each of the tool Features
brings its own, and `kubectl` comes from the official
`ghcr.io/devcontainers/features/kubectl-helm-minikube` Feature, which
`installsAfter` orders this one behind:

```json
"features": {
  "ghcr.io/devcontainers/features/kubectl-helm-minikube:1": {
    "helm": "none",
    "minikube": "none"
  },
  "ghcr.io/nabil-becker/devcontainer-features/velero:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/kube-state:1": {}
}
```

Without kubectl, `install.sh` says so and goes on, so the auto-generated
test (Feature alone on a bare image) and an image that adds kubectl later
still build.

What the Feature adds:

- `KUBECONFIG=/var/lib/devcontainer-features/kube-state/config` in `containerEnv`
  and a named volume (`kube-state-config-${devcontainerId}`) on the folder
  `/var/lib/devcontainer-features/kube-state`, so a kubeconfig put there survives
  rebuilds (see below).
- A `postCreateCommand` (`kube-state-setup`, also `task kube-state:setup`) that runs
  `dcf-persist` on the kubeconfig's folder (creates it, hands it to the
  remote user, prints `kube-state: <dir> (volume|bind|image, writable)`), sets the
  file to `0600` (`restrictPermissions`), and reports whether a kubeconfig
  is present and, with kubectl, the current context name. It never prints a
  server address or a user.
- `dcf-persist` on PATH, the helper every `<id>-setup` hook of this
  collection shares.

## Getting a kubeconfig in

The volume starts empty. Put a kubeconfig in once, from a file in the
workspace or any mounted path:

```sh
task kube-state:import FILE=./my-cluster.yaml   # merges and flattens into KUBECONFIG, 0600
task kube-state:contexts
task kube-state:use CONTEXT=my-cluster
```

or run the cloud's own command (`az aks get-credentials`, `argocd`, ...),
which writes to `KUBECONFIG` like any client. Do not commit the file.
`restrictPermissions: false` (or `KUBE_STATE_SETUP_RESTRICT_PERMISSIONS=false` in
`containerEnv`, no rebuild) leaves the mode alone.

## Keeping the kubeconfig across rebuilds

`KUBECONFIG` points at a file, the volume is mounted on its folder, so
nothing is needed for it to survive a rebuild. A named volume is deleted by
a container-engine storage reset or a move to another engine; for a folder
on the host disk, bind-mount the same target in the repo's
`devcontainer.json` (`initializeCommand` creates the folder first, since a
bind mount with a missing source fails; array form, since a string goes
through `cmd /c` on Windows):

```json
"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "kube-state"],
"mounts": [
  "source=${localEnv:USERPROFILE}/.devcontainer-homes/myrepo/kube-state,target=/var/lib/devcontainer-features/kube-state,type=bind"
]
```

A repo's `mounts` entry on the same target wins over the Feature's volume.
To use the workstation's own `~/.kube` instead, bind-mount that folder on the
same target (`${localEnv:USERPROFILE}/.kube`, or `${localEnv:HOME}/.kube` on
Linux/macOS), with `KUBECONFIG` left at its default. Alternatively point
`KUBECONFIG` in the repo's `containerEnv` at any other mounted path;
`kube-state-setup` follows the variable (its first entry when it is a list).

## Pairs with

- `ghcr.io/devcontainers/features/kubectl-helm-minikube` for `kubectl`.
- The `velero`, `kustomize`, `argocd` and `kubeconform` Features of this
  collection: they read `KUBECONFIG` and need nothing else from here.
- `task kube-state:import` / `task kube-state:contexts` from a root Taskfile that
  includes the go-task registry.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/kube-state/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
