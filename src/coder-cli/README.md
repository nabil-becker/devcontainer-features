
# Coder CLI (coder-cli)

Installs the Coder CLI (https://coder.com) as a release binary at /usr/local/bin/coder, verified against the release's coder_<version>_checksums.txt. Pin version to your coderd server version to avoid 'version mismatch' warnings. The login session lives in CODER_CONFIG_DIR at /var/lib/devcontainer-features/coder-cli, a named volume the Feature mounts so it survives rebuilds; the coder-cli-setup post-create hook hands the folder to the remote user.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/coder-cli:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| version | Coder release to install (e.g. '2.36.7', with or without a leading 'v'), or 'latest'. Match your Coder server's version. | string | latest |

## What it installs

The `coder` release binary from `github.com/coder/coder`, at
`/usr/local/bin/coder`. `install.sh` downloads
`coder_<version>_linux_<arch>.tar.gz` and the release's
`coder_<version>_checksums.txt`, checks the tarball with `sha256sum -c`,
extracts it and installs the `coder` binary only if the check passes. It runs
`coder version` at the end, so the version is in the build log. It also
installs the `coder-cli-setup` post-create hook and the shared `dcf-persist`
helper on PATH. The upstream `curl https://coder.com/install.sh | sh` is not
used: it picks the method and version for you and performs no checksum
verification.

- `version` takes a number with or without a leading `v` (`2.36.7`,
  `v2.36.7`), or `latest` (the default). `latest` is resolved once, at image
  build time, through the `releases/latest` redirect (no API call, no
  token), so two builds a month apart can differ. Pin it.
- `curl`, `ca-certificates` and `tar` are installed with `apt-get` only when
  missing; on an image without `apt-get` the build fails.
- Architectures: `x86_64`/`amd64`, `aarch64`/`arm64` and `armv7l` (the
  `armv7` asset). Any other `uname -m` fails the build.

## Options

- `version` (default `latest`): change it to the `coderd` server version.
  The CLI warns on every command when it is newer or older than the server,
  so pin it and bump both together. A value that does not start with an
  `x.y.z` number fails the build.
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/coder-cli.yml` in the image.

There is no run-time override; the version is fixed at build. The state
location is not an option (Feature metadata is static): override it with a
repo mount and `containerEnv`, see State.

## State

The login session lives under `CODER_CONFIG_DIR` (the tool's default is
`~/.config/coderv2`; `coder login` writes the token to `session` and the
server to `url` there). The Feature sets
`CODER_CONFIG_DIR=/var/lib/devcontainer-features/coder-cli` in `containerEnv`
and mounts the named volume `coder-cli-config-${devcontainerId}` on that
folder, so the session survives rebuilds. Its `postCreateCommand` hook
`coder-cli-setup` (also `task coder-cli:setup`; idempotent, never fatal)
hands the folder to the remote user through `dcf-persist` and reports, in
the post-create log:

- `coder-cli: <dir> (<volume|bind|image>, <writable|NOT writable by user>)`: what backs the
  folder and whether it is writable. `image` means nothing is mounted and the
  session is lost at the next rebuild.
- `coder-cli-setup: login present (server: <url>)` when a non-empty `session`
  file exists, else `coder-cli-setup: no login yet (run: coder login <url>;
  ...)`. The check is the file's presence, not `coder whoami`, so it never
  stalls post-create offline; the token is never printed.

A container-engine storage reset or a move to another engine deletes the
volume, and `${devcontainerId}` changes when the checkout moves, leaving the
old volume behind.

For the host disk, a repo bind-mounts a host folder on the same target (a
repo's `mounts` merge after the Features', so its mount wins) and creates it
before the first start:

```json
"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "coder-cli"],
"mounts": ["source=${localEnv:USERPROFILE}/.devcontainer-homes/myrepo/coder-cli,target=/var/lib/devcontainer-features/coder-cli,type=bind"]
```

A repo's own `containerEnv` wins over the Feature's, which is how it points
`CODER_CONFIG_DIR` somewhere else entirely.

## Minimal `devcontainer.json`

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/coder-cli:1": {
    "version": "2.36.7"
  }
}
```

Drop the `version` line to follow the newest release at each image build.
Log in once afterwards with `task coder-cli:login URL=https://coder.example.com`.

## Verify it works

```bash
coder version              # prints the installed client version
task coder-cli:version
echo "$CODER_CONFIG_DIR"   # /var/lib/devcontainer-features/coder-cli
coder-cli-setup            # path, backing, writable, login state
```

The build log carries `coder-cli: downloading Coder v<version>
(coder_<version>_linux_<arch>.tar.gz)...` and the version output; a failed
checksum stops the build with `sha256sum`'s `FAILED` line. The post-create
log carries the two `coder-cli-setup` lines described under State.

## Composition

- `installsAfter` orders it behind this collection's `go-task` Feature (so
  the Taskfile registry exists and is refreshed) and the official
  `common-utils`.
- Augments no official Feature and replaces none. The shared `dcf-persist`
  helper it installs is the same file every state-owning Feature of this
  collection carries.
- Independent of `kube-state`: the CLI talks to the Coder server with its
  own login and does not use `KUBECONFIG`.

## Tasks

With `installTaskfile` on, and a root Taskfile that includes the go-task
registry, these appear under `coder-cli:`; extra flags go after `--`.

- `coder-cli:version`: show client and, when logged in, server versions.
- `coder-cli:setup`: re-run `coder-cli-setup` (ownership, backing, login
  check).
- `coder-cli:login`: log in to `URL=<https://coder.example.com>`
  (interactive).
- `coder-cli:workspaces`: list your workspaces.
- `coder-cli:templates`: list templates on the server.
- `coder-cli:ssh`: open an SSH session to `WORKSPACE=<name>` (interactive).

## Limits and troubleshooting

- Linux only, on the three architectures above; others fail with
  `unsupported architecture`.
- `could not resolve a Coder version`: `latest` could not be resolved (no
  network or no redirect) or `version` is not a number. Pin an explicit
  version or fix the network.
- A missing release asset or checksums line fails the build (`curl -f`, or
  `sha256sum` finding no matching line). The binary is never installed
  unchecked.
- A `version mismatch` warning on every command means the client and the
  server differ; pin `version` to the server.
- The session is tied to the volume. The volume is lost on an engine storage
  reset or when `${devcontainerId}` changes; use the bind mount above to keep
  it on the host disk. The folder holds the session token: keep it out of
  any synced checkout.
- `coder-cli-setup` reports `image` when no mount backs the folder (for
  example the repo overrides the mounts away); the login then does not
  survive.
- Tested (`test/coder-cli`): the binary is on PATH, runs and is root-owned
  (default and pinned 2.36.7, non-root user), `CODER_CONFIG_DIR` is set, the
  state folder is writable and owned by the current user after
  `coder-cli-setup`, `coder-cli-setup` prints its backing and login lines,
  and the Taskfile lands in `includes.d`. Not tested: an actual login or the
  "login present" branch, the bind-mount override, any task against a
  server, `installTaskfile: false`, a failed checksum.

## Why not the upstream install script?

`curl https://coder.com/install.sh | sh` chooses the install method and
version itself and performs no checksum verification. This Feature pins the
version and verifies the release tarball against its checksums file before
installing it.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/coder-cli/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
