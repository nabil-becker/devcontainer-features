## What it installs

The `kustomize` release binary from `github.com/kubernetes-sigs/kustomize`,
at `/usr/local/bin/kustomize`. `install.sh` downloads
`kustomize_v<version>_linux_<arch>.tar.gz` and the release's `checksums.txt`,
checks the tarball with `sha256sum -c`, and installs the binary only if the
check passes. It runs `kustomize version` at the end, so the version is in
the build log. It installs no `kubectl` and no `helm`.

- `version` takes a number with or without a leading `v` (`5.8.3`,
  `v5.8.3`), or `latest` (the default). `latest` is resolved once, at image
  build time, through the `releases/latest` redirect (no API call, no
  token), so two builds a month apart can differ. Pin it. Release tags in
  that repository look like `kustomize/v5.8.3`; a leading `kustomize/` on
  `version` is accepted too.
- `curl`, `ca-certificates` and `tar` are installed with `apt-get` only when
  missing; on an image without `apt-get` the build fails.
- Architectures: `x86_64`/`amd64` and `aarch64`/`arm64`. Any other
  `uname -m` (`armv7l` included) fails the build.

## Options

- `version` (default `latest`): change it to the version your CI's
  `kustomize build` runs, so rendered output matches between laptop and
  pipeline. A value that does not start with an `x.y.z` number fails the
  build.
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/kustomize.yml` in the image.

There is no run-time override; the version is fixed at build.

## State

No state: installs a binary only. No volume, no `containerEnv`, no
post-create hook. It does not read `KUBECONFIG` either: kustomize works
offline on files, so it needs nothing from `kube-state`.

## Minimal `devcontainer.json`

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/kustomize:1": {
    "version": "5.8.3"
  }
}
```

Drop the `version` line to follow the newest release at each image build.

## Verify it works

```bash
kustomize version          # prints the installed version
task kustomize:version
```

The build log carries the same line (`kustomize: downloading kustomize
v<version> (kustomize_v<version>_linux_<arch>.tar.gz)...`, then the
`kustomize version` output). A failed checksum stops the build with
`sha256sum`'s `FAILED` line. There is no post-create line: nothing runs
after the build.

## Composition

- `installsAfter` orders it behind this collection's `go-task` Feature (so
  the Taskfile registry exists and is refreshed) and the official
  `common-utils`.
- Pairs with [`kubeconform`](../kubeconform): `task
  kubeconform:validate:kustomize` renders with `kustomize build` and
  validates the output against the Kubernetes schemas.
- Pairs with `ghcr.io/devcontainers/features/kubectl-helm-minikube` for
  `kubectl` and `helm`: kustomize can inflate Helm charts with
  `--enable-helm` when `helm` is on PATH.
- It augments no official Feature and replaces none. It is standalone: it
  does not require `kubectl`.
- Independent of `kube-state`: no cluster is contacted.

## Tasks

With `installTaskfile` on, and a root Taskfile that includes the go-task
registry, these appear under `kustomize:`:

- `kustomize:version`: show the installed version.
- `kustomize:build`: render the kustomization in `DIR` (default `.`) to
  stdout; extra kustomize flags go after `--`.
- `kustomize:build:all`: run `kustomize build` on every directory under
  `ROOT` (default `.`) that holds a `kustomization.yaml` (skipping `.git`),
  print `ok` or `FAIL` per directory, discard the output, and exit non-zero
  if any failed. A quick "does everything still build" check.

## Limits and troubleshooting

- Linux only, on the two architectures above; others fail with
  `unsupported architecture`.
- `could not resolve a kustomize version`: `latest` could not be resolved
  (no network or no redirect) or `version` is not a number. Pin an explicit
  version or fix the network.
- A missing release asset or `checksums.txt` line fails the build (`curl
  -f`, or `sha256sum` finding no matching line). The binary is never
  installed unchecked.
- `kustomize:build:all` stops at nothing: it builds every directory and
  reports at the end, so read the `FAIL` lines, not only the exit code. It
  also builds bases and components that are not meant to render alone, and
  those can show `FAIL`.
- Remote bases (`github.com/...` in `resources`) and Helm charts are fetched
  at build time and need network (and `helm` on PATH for charts).

## Why this one exists

`kubectl` bundles an older kustomize (`kubectl kustomize`). This Feature
installs the standalone binary, so pin `version` to whatever your CI's
`kustomize build` step uses and the rendered manifests stay identical
between laptop and pipeline. No published Dev Container Feature for
standalone kustomize is known to this repository, so there is no other
Feature to compare.
