## What it installs

The `velero` release binary from `github.com/vmware-tanzu/velero`, at
`/usr/local/bin/velero`. `install.sh` downloads
`velero-v<version>-linux-<arch>.tar.gz` and the release's `CHECKSUM` file,
checks the tarball with `sha256sum -c`, extracts only the `velero` binary and
installs it only if the check passes. It runs `velero version --client-only`
at the end, so the version is in the build log.

- `version` takes a number with or without a leading `v` (`1.18.4`,
  `v1.18.4`), or `latest` (the default). `latest` is resolved once, at image
  build time, through the `releases/latest` redirect (no API call, no
  token), so two builds a month apart can differ. Pin it.
- `curl`, `ca-certificates` and `tar` are installed with `apt-get` only when
  missing; on an image without `apt-get` the build fails.
- Architectures: `x86_64`/`amd64` and `aarch64`/`arm64`. Any other
  `uname -m` fails the build.

## Options

- `version` (default `latest`): change it to the Velero server version
  deployed in the cluster (`velero version` shows client and server), and
  bump it when the server is upgraded. A value that does not start with an
  `x.y.z` number fails the build.
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/velero.yml` in the image.

There is no run-time override; the version is fixed at build.

## State

No state of its own: installs a binary only. No volume, no `containerEnv`,
no post-create hook. Velero reads the standard kubeconfig lookup
(`KUBECONFIG`, else `~/.kube/config`), so a kubeconfig must be present at
run time; this Feature does not provide one. The cluster credentials stay in
whatever supplies the kubeconfig (see Composition), never in this Feature.

## Minimal `devcontainer.json`

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/velero:1": {
    "version": "1.18.4"
  }
}
```

Drop the `version` line to follow the newest release at each image build.
With a kubeconfig volume, see Composition.

## Verify it works

```bash
velero version --client-only   # prints the client version, no cluster needed
velero version                 # client and server; needs a reachable cluster
task velero:version
```

The build log carries the first line (`velero: downloading Velero
v<version> (velero-v<version>-linux-<arch>.tar.gz)...`, then the version
output). A failed checksum stops the build with `sha256sum`'s `FAILED` line.
There is no post-create line: nothing runs after the build.

## Composition

- `installsAfter` orders it behind this collection's `go-task` Feature (so
  the Taskfile registry exists and is refreshed) and the official
  `common-utils`.
- Pairs with [`kube-state`](../kube-state), which owns the kubeconfig in a
  named volume and sets `KUBECONFIG` for it, and with the official
  `ghcr.io/devcontainers/features/kubectl-helm-minikube` for `kubectl`:

  ```json
  "features": {
    "ghcr.io/devcontainers/features/kubectl-helm-minikube:1": { "helm": "none", "minikube": "none" },
    "ghcr.io/nabil-becker/devcontainer-features/velero:1": { "version": "1.18.4" },
    "ghcr.io/nabil-becker/devcontainer-features/kube-state:1": {}
  }
  ```

  Import the kubeconfig once with `task kube-state:import FILE=...`. The
  kubeconfig is cluster credentials, so it stays on the host disk or in that
  volume, never inside a synced checkout.
- It augments no official Feature and replaces none.

## Tasks

With `installTaskfile` on, and a root Taskfile that includes the go-task
registry, these appear under `velero:`. All talk to the cluster of the
current kubeconfig context, and `NAMESPACE` (default `velero`) names the
Velero namespace; extra flags go after `--`.

- `velero:version`: show client and, if reachable, server versions (falls
  back to `--client-only`).
- `velero:backups`: list backups.
- `velero:backup`: create an on-demand backup `NAME=<name>`.
- `velero:describe`: describe backup `NAME=<name>` with `--details`.
- `velero:restores`: list restores.
- `velero:schedules`: list backup schedules.

There is no task to restore or delete: use `velero restore create` directly.

## Limits and troubleshooting

- Linux only, on the two architectures above; others fail with
  `unsupported architecture`.
- `could not resolve a Velero version`: `latest` could not be resolved (no
  network or no redirect) or `version` is not a number. Pin an explicit
  version or fix the network.
- A missing release asset or `CHECKSUM` line fails the build (`curl -f`, or
  `sha256sum` finding no matching line). The binary is never installed
  unchecked.
- Keep the client at the server's version (pin `version`); this Feature does
  not check the match.
- Without a reachable cluster or kubeconfig only the client version is
  available (`velero:version` falls back to `--client-only`); the tasks that
  list or create objects fail.
- Tested (`test/velero`): the binary is on PATH, runs and is root-owned, the
  default (`latest`) and a pinned version (1.18.4), running as a non-root
  user, and that the Taskfile lands in `includes.d`. Not tested: any task
  against a cluster, `installTaskfile: false`, a failed checksum.

## Why this one exists

No published Dev Container Feature for velero is known to this repository,
so there is no alternative to compare.
