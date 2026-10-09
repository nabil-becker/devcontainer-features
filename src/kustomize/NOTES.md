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
