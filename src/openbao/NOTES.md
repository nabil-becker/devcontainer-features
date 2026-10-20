## What it installs

The `bao` release binary from `github.com/openbao/openbao`, at
`/usr/local/bin/bao`. `install.sh` downloads
`openbao_<version>_linux_<arch>.tar.gz` and the release's `checksums.txt`,
checks the tarball with `sha256sum -c`, and installs the binary only if the
check passes. It runs `bao version` at the end, so the version is in the
build log. It installs no OpenBao server and no `vault` command.

- `version` takes a number with or without a leading `v` (`2.7.1`,
  `v2.7.1`), or `latest` (the default). `latest` is resolved once, at image
  build time, through the `releases/latest` redirect (no API call, no
  token), so two builds a month apart can differ. Pin it to your server's
  version.
- `curl`, `ca-certificates` and `tar` are installed with `apt-get` only when
  missing; on an image without `apt-get` the build fails.
- Architectures: `x86_64`/`amd64` and `aarch64`/`arm64`. Any other
  `uname -m` fails the build.

## Options

- `version` (default `latest`): set it to the version of the OpenBao server
  you talk to, so the CLI and the server agree. A value that does not start
  with an `x.y.z` number fails the build.
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/openbao.yml` in the image.

There is no run-time override of either; both are fixed at build. The
server address is a run-time setting: see State.

## State

The Feature has no state volume, no `containerEnv` and no post-create hook
of its own. Two things live outside the binary:

- **The server address**: `BAO_ADDR`, which the Feature does not set. Put it
  in your `devcontainer.json`.
- **The login token**: `bao login` writes it to `~/.vault-token` of the
  remote user, which sits in the container's own filesystem. **A rebuild
  deletes it and you are logged out.** The sibling CLIs (`gh`, `az`,
  `argocd`, `coder-cli`) own their login state in a named volume under
  `/var/lib/devcontainer-features/<id>`; this one does not yet.

One route keeps a login across rebuilds without a Feature change.

**`BAO_TOKEN` from the environment.** The CLI uses `BAO_TOKEN` in place of
`~/.vault-token`, and the tasks pass the container's environment straight to
`bao`, so `task openbao:status` and the others pick it up. Set it in
`containerEnv`, reading from a variable on the host:

```json
"containerEnv": {
  "BAO_ADDR": "https://bao.example.com",
  "BAO_TOKEN": "${localEnv:BAO_TOKEN}"
}
```

or from an env file the repo keeps out of git:

```json
"runArgs": ["--env-file", "${localWorkspaceFolder}/.devcontainer/bao.env"]
```

with `.devcontainer/bao.env` holding plain `NAME=value` lines (no quotes, no
`export`):

```text
BAO_ADDR=https://bao.example.com
BAO_TOKEN=<token>
```

The token then sits in the container's environment and the env file; tokens
expire, so renew the value there. Never commit it.

A bind-mount of `~/.vault-token` from the host is not offered here: it is
untested, and a single-file mount breaks if `bao login` replaces the file
rather than writing into it. Until the Feature owns its state, use
`BAO_TOKEN`.

## Minimal `devcontainer.json`

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/openbao:1": {
    "version": "2.7.1"
  }
},
"containerEnv": {
  "BAO_ADDR": "https://bao.example.com"
}
```

Drop the `version` line to follow the newest release at each image build.
For a server with a private CA, trust the certificate in the image
(`update-ca-certificates`) rather than setting `BAO_SKIP_VERIFY`.

## Verify it works

```bash
bao version          # prints the installed version
task openbao:version
bao status           # needs BAO_ADDR; prints seal state and server version
```

The build log carries the first line (`openbao: downloading OpenBao
v<version> (openbao_<version>_linux_<arch>.tar.gz)...`, then the `bao
version` output). A failed checksum stops the build with `sha256sum`'s
`FAILED` line. There is no post-create line: nothing runs after the build.

## Composition

- `installsAfter` orders it behind this collection's `go-task` Feature (so
  the Taskfile registry exists and is refreshed) and the official
  `common-utils`.
- It augments no official Feature and replaces none.
- Independent of `kube-state` and `git`: no kubeconfig is read and no git
  config is written.

## Tasks

With `installTaskfile` on, and a root Taskfile that includes the go-task
registry, these appear under `openbao:`:

- `openbao:version`: show the installed version.
- `openbao:status`: run `bao status` against `BAO_ADDR` (seal state, HA,
  version); extra flags go after `--`.
- `openbao:login`: run `bao login` interactively; auth method and flags go
  after `--`, e.g. `task openbao:login -- -method=oidc`.
- `openbao:kv:get`: read the secret `KEY=<mount/path>` from a KV engine
  (`KEY`, not `PATH`, which Task would read as the shell variable); extra
  flags go after `--`, e.g.
  `task openbao:kv:get KEY=secret/app -- -format=json`.

No task reads a variable besides `KEY`; the address and token come from
`BAO_ADDR` and `BAO_TOKEN` in the container's environment, as for `bao`
itself.

## Limits and troubleshooting

- Linux only, on the two architectures above; others fail with
  `unsupported architecture`.
- `could not resolve an OpenBao version`: `latest` could not be resolved (no
  network or no redirect) or `version` is not a number. Pin an explicit
  version or fix the network.
- A missing release asset or `checksums.txt` line fails the build (`curl
  -f`, or `sha256sum` finding no matching line). The binary is never
  installed unchecked.
- Logged out after every rebuild: expected, see State. Use `BAO_TOKEN`.
- `bao status` fails with a connection or certificate error: `BAO_ADDR` is
  unset or wrong, or the server's CA is not trusted in the image.
- A `BAO_TOKEN` in the environment takes precedence over `~/.vault-token`,
  so a stale value there makes `permission denied` appear even right after
  a fresh `bao login`; unset it or update it.

## Why this one exists

No published Dev Container Feature for the OpenBao CLI is known to this
repository, so there is no alternative to compare. The binary is checked
against the release's `checksums.txt`; OpenBao also signs releases with GPG
and Sigstore, which this Feature does not verify.
