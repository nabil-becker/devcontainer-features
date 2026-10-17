## What it installs

The `kubeconform` release binary from `github.com/yannh/kubeconform`, at
`/usr/local/bin/kubeconform`. `install.sh` downloads
`kubeconform-linux-<arch>.tar.gz` and the release's `CHECKSUMS` file, checks
the tarball with `sha256sum -c`, and installs the binary only if the check
passes. It runs `kubeconform -v` at the end, so the version is in the build
log.

- `version` takes a number with or without a leading `v` (`0.8.0`,
  `v0.8.0`), or `latest` (the default). `latest` is resolved once, at image
  build time, through the `releases/latest` redirect (no API call, no
  token), so two builds a month apart can differ. Pin it.
- `curl`, `ca-certificates` and `tar` are installed with `apt-get` only when
  missing; on an image without `apt-get` the build fails.
- Architectures: `x86_64`/`amd64`, `aarch64`/`arm64`, and `armv7l`, which
  takes the upstream `armv6` asset. Any other `uname -m` fails the build.

## Options

- `version` (default `latest`): change it to the version your CI runs, so
  local and pipeline results agree. A value that is not a `x.y.z` number
  fails the build.
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/kubeconform.yml` in the image.

There is no run-time override; the version is fixed at build.

## State

No state: installs a binary only. No volume, no `containerEnv`, no
post-create hook. It does not read `KUBECONFIG` either: kubeconform works
offline on manifest files, so it needs nothing from `kube-state`. (The
schemas are fetched over HTTPS at validation time, see Limits.)

## Minimal `devcontainer.json`

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/kubeconform:1": {
    "version": "0.8.0"
  }
}
```

Drop the `version` line to follow the newest release at each image build.

## Verify it works

```bash
kubeconform -v          # prints the installed version
task kubeconform:version
```

The build log carries the same line (`kubeconform: downloading kubeconform
v<version> (kubeconform-linux-<arch>.tar.gz)...`, then the `-v` output). A
failed checksum stops the build with `sha256sum`'s `FAILED` line. There is
no post-create line: nothing runs after the build.

## Composition

- `installsAfter` orders it behind this collection's `go-task` Feature (so
  the Taskfile registry exists and is refreshed) and the official
  `common-utils`.
- Pairs with [`kustomize`](../kustomize): `task kubeconform:validate:kustomize`
  renders with `kustomize build` and pipes the output to kubeconform. The
  `kustomize` binary must be on PATH.
- It augments no official Feature and replaces none.
- Independent of `kube-state`: no cluster is contacted.

## Tasks

With `installTaskfile` on, and a root Taskfile that includes the go-task
registry, these appear under `kubeconform:`:

- `kubeconform:version`: show the installed version.
- `kubeconform:validate`: validate `TARGET` (a file or directory, default
  `.`) against the Kubernetes and CRD schemas; extra flags go after `--`.
- `kubeconform:validate:kustomize`: render the kustomization in `DIR`
  (default `.`) with `kustomize build` and validate the output.

Both validate tasks use `KUBECONFORM_FLAGS` (default
`-strict -summary -ignore-missing-schemas`; setting it replaces the
defaults) and `CRD_CATALOG` (default: the community datree catalog at
`https://raw.githubusercontent.com/datreeio/CRDs-catalog/main`). Without the
tasks, the same check by hand:

```bash
kustomize build overlays/prod | kubeconform -strict -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```

## Limits and troubleshooting

- Linux only, on the three architectures above; unsupported ones fail with
  `unsupported architecture`.
- `could not resolve a kubeconform version`: `latest` could not be resolved
  (no network or no redirect) or `version` is not a number. Pin an explicit
  version or fix the network.
- A missing release asset or `CHECKSUMS` line fails the build (`curl -f`, or
  `sha256sum` finding no matching line). The binary is never installed
  unchecked.
- Validation needs network: the default and datree schema locations are
  fetched over HTTPS. Offline, kubeconform cannot find CRD schemas; with the
  default `-ignore-missing-schemas` they are skipped silently rather than
  failing, so a green run offline checks less than it seems to. Point
  `CRD_CATALOG` at a mirror, or drop the flag via `KUBECONFORM_FLAGS`.
- `-strict` rejects unknown fields; remove it through `KUBECONFORM_FLAGS` if
  a manifest carries extension fields on purpose.

## Why this one exists

No published Dev Container Feature for kubeconform is known to this
repository, so there is no alternative to compare.
