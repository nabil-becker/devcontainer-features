
# kustomize (kustomize)

Installs kustomize (https://kustomize.io), the Kubernetes manifest customization tool, as a release binary at /usr/local/bin/kustomize, verified against the release's checksums.txt. Standalone - does not require kubectl.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/kustomize:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| version | kustomize release to install (e.g. '5.8.3', with or without a leading 'v'), or 'latest'. Pin it to what your CI uses so `kustomize build` output matches. | string | latest |

## Standalone vs `kubectl kustomize`

`kubectl` bundles an older kustomize. This Feature installs the standalone
binary, so pin `version` to whatever your CI's `kustomize build` step uses
and the rendered manifests stay identical between laptop and pipeline.

## Pairs well with

- [`kubeconform`](../kubeconform) to validate `kustomize build` output
  against the Kubernetes schemas.
- `ghcr.io/devcontainers/features/kubectl-helm-minikube` for `kubectl` and
  `helm` (kustomize can inflate Helm charts with `--enable-helm` when `helm`
  is on PATH).

## Verification

The tarball is checked against the release's `checksums.txt` before the
binary is installed.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/kustomize/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
