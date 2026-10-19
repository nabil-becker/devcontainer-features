
# Argo CD CLI (argocd)

Installs the Argo CD CLI (https://argo-cd.readthedocs.io) as a release binary at /usr/local/bin/argocd, verified against the release's cli_checksums.txt. Pin version to your Argo CD server version. The login session lives in ARGOCD_CONFIG_DIR at /var/lib/devcontainer-features/argocd, a named volume the Feature mounts so it survives rebuilds; the argocd-setup post-create hook hands the folder to the remote user.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/argocd:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| version | Argo CD release to install (e.g. '3.5.4', with or without a leading 'v'), or 'latest'. Match your Argo CD server's version. | string | latest |

## What it installs

The `argocd` CLI binary from `github.com/argoproj/argo-cd`, at
`/usr/local/bin/argocd`. `install.sh` downloads `argocd-linux-<arch>` and the
release's `cli_checksums.txt`, checks the binary with `sha256sum -c`, and
installs it only if the check passes. It runs
`argocd version --client --short` at the end, so the version is in the build
log. It also installs the `argocd-setup` post-create hook and the shared
`dcf-persist` helper on PATH.

- `version` takes a number with or without a leading `v` (`3.5.4`,
  `v3.5.4`), or `latest` (the default). `latest` is resolved once, at image
  build time, through the `releases/latest` redirect (no API call, no
  token), so two builds a month apart can differ. Pin it.
- `curl` and `ca-certificates` are installed with `apt-get` only when `curl`
  is missing; on an image without `apt-get` the build fails. No `tar` is
  needed (the release asset is the bare binary).
- Architectures: `x86_64`/`amd64` and `aarch64`/`arm64`. Any other
  `uname -m` fails the build.

## Options

- `version` (default `latest`): change it to the Argo CD server version you
  talk to; the CLI and the API surface move together. A value that does not
  start with an `x.y.z` number fails the build.
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/argocd.yml` in the image.

There is no run-time override; the version is fixed at build. The state
location is not an option (Feature metadata is static): override it with a
repo mount and `containerEnv`, see State.

## State

The login session lives under `ARGOCD_CONFIG_DIR` (the tool's default is
`~/.config/argocd`; `argocd login` writes its `config` file there, with
contexts, servers and users including tokens). The Feature sets
`ARGOCD_CONFIG_DIR=/var/lib/devcontainer-features/argocd` in `containerEnv`
and mounts the named volume `argocd-config-${devcontainerId}` on that
folder, so the session survives rebuilds. Its `postCreateCommand` hook
`argocd-setup` (also `task argocd:setup`; idempotent, never fatal) hands the
folder to the remote user through `dcf-persist` and reports, in the
post-create log:

- `argocd: <dir> (<volume|bind|image>, <writable|NOT writable by user>)`: what backs the
  folder and whether it is writable. `image` means nothing is mounted and the
  session is lost at the next rebuild.
- `argocd-setup: login present (current context: <name>)` when `config`
  holds a non-empty `contexts` list, else `argocd-setup: no login yet (run:
  argocd login <server>; ...)`. The file is only scanned; no token is printed
  and no server is contacted.

A container-engine storage reset or a move to another engine deletes the
volume, and `${devcontainerId}` changes when the checkout moves, leaving the
old volume behind.

For the host disk, a repo bind-mounts a host folder on the same target (a
repo's `mounts` merge after the Features', so its mount wins) and creates it
before the first start:

```json
"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "argocd"],
"mounts": ["source=${localEnv:USERPROFILE}/.devcontainer-homes/myrepo/argocd,target=/var/lib/devcontainer-features/argocd,type=bind"]
```

A repo's own `containerEnv` wins over the Feature's, which is how it points
`ARGOCD_CONFIG_DIR` somewhere else entirely.

## Minimal `devcontainer.json`

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/argocd:1": {
    "version": "3.5.4"
  }
}
```

Drop the `version` line to follow the newest release at each image build.
Log in once afterwards with `task argocd:login SERVER=argocd.example.com`.

## Verify it works

```bash
argocd version --client --short   # prints the installed client version
task argocd:version
echo "$ARGOCD_CONFIG_DIR"         # /var/lib/devcontainer-features/argocd
argocd-setup                      # path, backing, writable, login state
```

The build log carries `argocd: downloading Argo CD CLI v<version>
(argocd-linux-<arch>)...` and the version line; a failed checksum stops the
build with `sha256sum`'s `FAILED` line. The post-create log carries the two
`argocd-setup` lines described under State.

## Composition

- `installsAfter` orders it behind this collection's `go-task` Feature (so
  the Taskfile registry exists and is refreshed) and the official
  `common-utils`.
- Augments no official Feature and replaces none. The shared `dcf-persist`
  helper it installs is the same file every state-owning Feature of this
  collection carries.
- Independent of `kube-state`: the CLI talks to the Argo CD server with its
  own login and does not use `KUBECONFIG`.
- Pairs with `kustomize` and `kubeconform` only in a workflow sense (render
  and validate manifests that Argo CD then syncs); there is no dependency.

## Tasks

With `installTaskfile` on, and a root Taskfile that includes the go-task
registry, these appear under `argocd:`; extra flags go after `--`.

- `argocd:version`: show client and, when logged in, server versions.
- `argocd:setup`: re-run `argocd-setup` (ownership, backing, login check).
- `argocd:login`: log in to `SERVER=<host[:port]>` (interactive; e.g.
  `-- --sso`, `-- --grpc-web`).
- `argocd:apps`: list applications.
- `argocd:diff`: show the live-versus-desired diff for `APP=<name>`.
- `argocd:sync`: sync `APP=<name>` now (e.g. `-- --prune`). This changes the
  cluster; run `argocd:diff` first.

## Limits and troubleshooting

- Linux only, on the two architectures above; others fail with
  `unsupported architecture`.
- `could not resolve an Argo CD version`: `latest` could not be resolved (no
  network or no redirect) or `version` is not a number. Pin an explicit
  version or fix the network.
- A missing release asset or `cli_checksums.txt` line fails the build
  (`curl -f`, or `sha256sum` finding no matching line). The binary is never
  installed unchecked.
- The session is tied to the volume. The volume is lost on an engine storage
  reset or when `${devcontainerId}` changes; use the bind mount above to keep
  it on the host disk. The folder holds tokens: keep it out of any synced
  checkout.
- `argocd-setup` reports `image` when no mount backs the folder (for example
  the repo overrides the mounts away); the login then does not survive.
- Tested (`test/argocd`): the binary is on PATH, runs and is root-owned
  (default and pinned 3.5.4, non-root user), `ARGOCD_CONFIG_DIR` is set, the
  state folder is writable and owned by the current user after
  `argocd-setup`, `argocd-setup` prints its backing and login lines, and the
  Taskfile lands in `includes.d`. Not tested: an actual login or the "login
  present" branch, the bind-mount override, any task against a server,
  `installTaskfile: false`, a failed checksum.

## Why not `ghcr.io/devcontainers-extra/features/argo-cd`?

That Feature resolves the binary through `nanolayer` and the generic
`gh-release` Feature at build time, without checksum verification. This one
downloads the release binary directly and checks it against the release's
`cli_checksums.txt`.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/argocd/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
