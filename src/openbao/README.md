
# OpenBao CLI (openbao)

Installs the OpenBao CLI (https://openbao.org), the open-source Vault fork, as a release binary at /usr/local/bin/bao, verified against the release's checksums.txt. Owns the login state as a named volume at OPENBAO_STATE_DIR=/var/lib/devcontainer-features/openbao (bao's token helper, set through BAO_CONFIG_PATH, keeps the token in it) so `bao login` survives rebuilds, with the post-create hook openbao-setup, and installs dcf-secret, the one command the collection's Features use to read and write secrets (get, put, status, with fixed exit codes). Set BAO_ADDR in containerEnv to point it at your server.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/openbao:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| mode | How the Feature is used. Only 'client' exists in this version: the bao CLI and dcf-secret against a server outside the container (BAO_ADDR). Override per container with OPENBAO_SETUP_MODE in containerEnv. | string | client |
| version | OpenBao release to install (e.g. '2.7.1', with or without a leading 'v'), or 'latest'. Match your OpenBao server's version. | string | latest |

## What it installs

The `bao` release binary from `github.com/openbao/openbao`, at
`/usr/local/bin/bao`. `install.sh` downloads
`openbao_<version>_linux_<arch>.tar.gz` and the release's `checksums.txt`,
checks the tarball with `sha256sum -c`, and installs the binary only if the
check passes. It runs `bao version` at the end, so the version is in the
build log. It installs no OpenBao server and no `vault` command.

Besides the binary, `install.sh` puts four scripts on PATH (nothing is downloaded for them):
`dcf-secret` (the interface callers use to read and write secrets, see below), `openbao-setup`
(the post-create hook, see State) and `dcf-persist` (a verbatim copy of `src/common/dcf-persist.sh`,
which makes the state directory usable and says what backs it). It writes the option defaults the
hook reads to `/usr/local/share/openbao-feature/options.env`.

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
- `mode` (default `client`, the only value in this version): the CLI and `dcf-secret` against a
  server outside the container, whose address is `BAO_ADDR`. Any other value fails the build. A
  later version adds `server`; a consumer that changes nothing keeps `client`. Override per
  container with `OPENBAO_SETUP_MODE` in `containerEnv` (the hook reads it; an unknown value is
  reported and the hook runs as `client`).
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/openbao.yml` in the image.

`version` and `installTaskfile` are fixed at build. `mode` has the run-time twin
`OPENBAO_SETUP_MODE`. The server address is a run-time setting: see State.

## State

Owned by the Feature (NFR-1), like `gh` and `az`:

- `containerEnv` sets `OPENBAO_STATE_DIR=/var/lib/devcontainer-features/openbao`.
- `mounts` declares the named volume `openbao-config-${devcontainerId}` on that path. The name
  follows the repository's convention (`<id>-config-${devcontainerId}`, as `gh-config-` and
  `az-config-`) and supersedes `openbao-${devcontainerId}`, which the proposal
  `docs/proposals/secrets-master-split.md` (section 3) wrote before it checked the convention.
- `containerEnv` also sets `BAO_CONFIG_PATH=/usr/local/share/openbao-feature/bao-config.hcl`, a
  config whose one line, `token_helper = "/usr/local/bin/openbao-token-helper"`, makes `bao` keep
  its login token in the volume, at `$OPENBAO_STATE_DIR/token` (mode 600). Because it is
  `containerEnv`, it holds for every process, `devcontainer exec` and agents' shells included.
  **A rebuild keeps the login.**
- The post-create hook `openbao-setup` (also `task openbao:setup`) runs `dcf-persist`, so the
  folder belongs to the remote user and the log says what backs it, and says whether the token
  helper is in effect. A token already in `~/.vault-token` (a login from before this Feature) is
  moved into the volume once, when the volume has none. The hook never contacts the server and
  never fails the rest of post-create.

How `bao` finds the helper, confirmed in OpenBao's source (`internal/command/config` and
`internal/command/token`, v2.1.1 and v2.7.1): the CLI reads an HCL config at `~/.bao`, or at the
path in `BAO_CONFIG_PATH`, and a `token_helper` in it names an absolute path to an executable
that `bao` runs as `<helper> get`, `store` (token on stdin) or `erase`. Without one, `bao` uses
its internal helper, which writes `~/.vault-token` through a temporary file and a rename: a link
to the volume at that path is replaced by the first `bao login`, which is why the Feature does
not use one. The helper is a few lines of `sh` (`openbao-token-helper`) and the token is written
atomically.

- **The server address** is `BAO_ADDR`, which the Feature does not set. Put it in `containerEnv`.
- **A repo that sets its own `BAO_CONFIG_PATH`** (or whose `containerEnv` leaves this one out)
  replaces the Feature's config; the hook says so. Add `token_helper =
  "/usr/local/bin/openbao-token-helper"` to that config to keep the login in the volume. A repo
  that wants the state on the host disk bind-mounts the volume's target (the README's "How the
  pieces fit"), or points `OPENBAO_STATE_DIR` elsewhere in its own `containerEnv`.
- **`bao token revoke -self`** and `bao logout` run the helper's `erase`: the token file is
  removed and the next `dcf-secret` call says to log in.
- **`BAO_TOKEN`** in the environment takes precedence over the saved login (the hook says so). It
  is a way to give a container a token without a login, for a service that cannot run `bao login`:
  set it in `containerEnv` from a host variable (`"BAO_TOKEN": "${localEnv:BAO_TOKEN}"`) or an env
  file the repo keeps out of git. A stale value there makes `permission denied` appear even right
  after a fresh `bao login`; unset it or update it. Never commit it.
- OpenBao 2.6.0 and later also read `BAO_TOKEN_PATH` (the internal helper's file, still written by
  a rename); the Feature uses the token helper because it works for every version `version` can pin.

Upgrading from 1.0.x: the volume starts empty, so log in once after the rebuild; a login made
before it, in `~/.vault-token` of the old container, is gone with that container.

## `dcf-secret`

The interface every Feature and script of this collection uses to read and write a secret, so
where the server runs does not matter to the caller. `openbao:kv:get` stays as the raw `bao kv
get` for people; `dcf-secret` is for callers.

```text
dcf-secret get <name> [--field <field>]    the value on stdout, nothing else (field default: value)
dcf-secret put <name> --field <field> [--replace]
                                           the value on stdin, never an argument
dcf-secret status [<name>]                 one word on stdout, the fix on stderr
```

- **Names are logical** (`ssh/<key>`, `register/<principal>`, `token/<name>`; letters, digits,
  `.`, `_`, `-`, with `/` between parts) and live at `<mount>/<name>` in a KV v2 mount. The mount is
  `dcf`; `DCF_SECRET_MOUNT` names another one (a client of a shared server uses its own).
- **Who asks**: the token `bao` uses (`BAO_TOKEN`, else the saved login). `DCF_SECRET_AS` (logging
  in as an AppRole) is not in this version: setting it exits 2 rather than asking as someone else.
- **`put` merges by default**: it writes only the given field and keeps the secret's other fields
  (`bao kv patch`); when the secret does not exist yet it creates it (`bao kv put -cas=0`, which
  fails if the secret appeared in the meantime, and then one more patch merges into it).
  `--replace` makes the secret exactly this one field (`bao kv put`) and drops the others. A token
  that may not patch is refused (exit 13, naming `--replace`), never silently turned into a
  replace. `put` refuses a terminal on stdin and holds the value in memory only (never a file,
  never an argument; a merge may offer it to `bao` twice). **`get` writes the value only to
  stdout**: it is never put in a file or a variable.
- **No fallback, ever.** On a non-zero exit nothing is read from a file, a volume or the
  environment instead. A second source would be a second master.

Exit codes, the same for every caller, each with one plain line on stderr naming the fix:

| Exit | Meaning | `status` prints |
| --- | --- | --- |
| 0 | done (`get`: the value is on stdout) | `ready` |
| 10 | the server is unreachable (`BAO_ADDR` wrong, server not running, no `bao`) | `unreachable` |
| 11 | the server is sealed, or not initialised | `sealed`, `not-initialised` |
| 12 | no token, or it expired | `logged-out` |
| 13 | the token may not use this name | `denied` (only with a name) |
| 14 | no such secret, or no such field | |
| 1 | `bao` failed and none of its signals say why (`put` only; its message follows) | |
| 2 | a wrong call (usage, a bad name, `DCF_SECRET_AS`) | |

The code is worked out from `bao`'s own signals, never from the words of a message: after a failed
call it asks `bao status -format=json` (exit 2 is sealed, the JSON says `initialized`; anything
else is unreachable), then `bao token capabilities` on `<mount>/data/<name>` (a refused call is no
valid token; no `read` or `root` for a get, no `create`, `update` or `root` for a put, is denied),
and a get that gets this far is a missing secret. A `put` that fails the same way checks for `patch`
(a merge needs it), then for `create` (a secret that does not exist yet needs it). A token
therefore needs the default policy (every token has it unless removed) besides `read` on
`<mount>/data/<name>` to get, `patch` (and `create` for a new secret) to put, and `create` and
`update` for `put --replace`. It speaks only `bao`, so it works the same against a Vault server.

A caller without this Feature finds no `dcf-secret` and says so; the Features stay independent at
build time.

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
The login is kept in the Feature's volume: `bao login` once, and a rebuild keeps it.
For a server with a private CA, trust the certificate in the image
(`update-ca-certificates`) rather than setting `BAO_SKIP_VERIFY`.

## Verify it works

```bash
bao version          # prints the installed version
task openbao:version
openbao-setup        # the post-create report, any time
dcf-secret status    # needs BAO_ADDR; prints ready, or why not (exit codes above)
```

The build log carries the first line (`openbao: downloading OpenBao
v<version> (openbao_<version>_linux_<arch>.tar.gz)...`, then the `bao
version` output). A failed checksum stops the build with `sha256sum`'s
`FAILED` line. The post-create log has the hook's lines: `openbao: /var/lib/devcontainer-features/openbao
(volume, writable)`, `openbao: mode client ...`, `openbao: token helper in effect`,
the version, `BAO_ADDR`, and whether a login is saved. `volume` in the first line is what keeps the
login across rebuilds; `image` means the mount is missing.

## Composition

- `installsAfter` orders it behind this collection's `go-task` Feature (so
  the Taskfile registry exists and is refreshed) and the official
  `common-utils`.
- It augments no official Feature and replaces none.
- `dcf-secret` is what later Features (`ssh-agent`, `gh`, `az`, `cloud-folder`) are to call for
  their secrets; none does yet, and none names this Feature in `installsAfter` (the Features stay
  independent at build time).
- Independent of `kube-state` and `git`: no kubeconfig is read and no git
  config is written. Its volume and hook are the shape of `gh` and `az`.

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

- `openbao:setup`: re-run the post-create hook (`openbao-setup`): make the state directory usable,
  move a token left in `~/.vault-token` into it, report the token helper, the address and the saved login.

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
- Logged out after a rebuild: the volume is gone (a container-engine storage reset, or another
  engine) or the hook's first line says `image` instead of `volume`. Log in again.
- `put` without `--replace` needs the `patch` capability on the secret's path; a policy that has
  only `create` and `update` must use `--replace`, which drops the secret's other fields.
- Client mode only: there is no server, backup, onboarding or `DCF_SECRET_AS` in this version.
- `dcf-secret` asks `bao` up to three questions after a failure, so a failure costs a few round
  trips; a success costs one. It assumes a KV v2 mount (the data lives under `<mount>/data/`).
- The login is kept by a token helper `bao` runs as a shell command on every call that needs the
  token; the container test `dev_server` checks login, use and revoke against a real `bao`.
- `bao status` fails with a connection or certificate error: `BAO_ADDR` is
  unset or wrong, or the server's CA is not trusted in the image.
- A `BAO_TOKEN` in the environment takes precedence over the saved login (see State).

## Why this one exists

Checked 2026-11-03 (NFR-9): no published Dev Container Feature is a general OpenBao CLI Feature
with state, a setup hook and a tested interface, and none is in the containers.dev index (searched
by name and description for `openbao` and `vault`). Three repositories on GitHub hold a Feature
that installs `bao` for their own purpose: `openbao-agent` in `wyrd-company/devcontainers` (installs
OpenBao and runs OpenBao Agent as an s6-overlay service from the user's own config; the archive is
checked against `checksums.txt`), `openbao-secrets` in `dever-labs/devcontainers` (installs `bao` and
a helper that logs `gh` in with a token read from OpenBao through OIDC, a session volume at a fixed
home path; the archive is checked against `checksums.txt`) and `bao-env` in
`stevetfidalgo/mindmap-devcontainer-features` (a manifest tool for KV stores that installs `bao` 2.1.1
and `yq`; no checksum check in its install script, a read of the script, not a test). They install
the binary as a means to something else, and none gives the CLI a login that survives a rebuild
(besides `openbao-secrets`' own session) or a command other Features can call. Here the binary is
checked against the release's `checksums.txt` (OpenBao also signs releases with GPG and Sigstore,
which this Feature does not verify), the login is in a volume the Feature owns, and `dcf-secret`
is the one interface the collection's Features use. The
official `devcontainers/features` collection has no OpenBao or Vault Feature; the Vault ones
elsewhere (`devcontainers-extra`, `postfinance`, `roul`) install HashiCorp's `vault`, not `bao`.

## Version and upgrade

`version` pins the OpenBao release at build (`2.7.1`, with or without `v`) or follows `latest`; pin
it to your server's version. The Feature's own version is the tag you reference
(`openbao:1` follows 1.x; see Changes). **1.1.0** adds the volume, `openbao-setup`, `dcf-secret`
and `mode`, all additive: rebuild to get them, and log in once, because the volume starts empty.
Nothing is removed; `mode` stays `client`.

## Changes

### [1.1.0] - 2026-11-03

#### Added

- **Your `bao login` now survives a rebuild.** The Feature owns a named volume (`openbao-config-<devcontainerId>`, at `/var/lib/devcontainer-features/openbao`, named by `OPENBAO_STATE_DIR`) and points `bao` at a token helper (`BAO_CONFIG_PATH`, set in `containerEnv`, so it holds for `devcontainer exec` too) that keeps the token there, as `gh` and `az` keep their logins. The post-create hook, `openbao-setup` (also `task openbao:setup`), makes the folder usable and moves a token left in `~/.vault-token` into it once. **You must act once:** rebuild the container and run `bao login` again, because the volume starts empty. A repo that sets its own `BAO_CONFIG_PATH` replaces the Feature's config (the hook says so); add `token_helper = "/usr/local/bin/openbao-token-helper"` to it. A repo that wants the state on the host disk bind-mounts the same target. A `BAO_TOKEN` in the environment still takes precedence over the saved login.
- **`dcf-secret`**, a command for scripts and other Features to read and write a secret without knowing where the server runs: `dcf-secret get <name>`, `dcf-secret put <name> --field <field>` (the value on stdin) and `dcf-secret status`. `put` writes only that field and keeps the secret's other fields (it creates the secret when it does not exist); `--replace` makes the secret exactly that one field. A token whose policy lacks the `patch` capability is refused with exit 13 rather than silently replacing the secret. It fails with fixed exit codes (10 unreachable, 11 sealed, 12 not logged in, 13 denied, 14 no such secret), each with one line saying what to do, and never falls back to a key on disk. Secrets live in a KV v2 mount named `dcf` (`DCF_SECRET_MOUNT` changes it). Nothing to do unless you want it; `task openbao:kv:get` is unchanged.
- **The `mode` option**, with the one value `client` (the default, what the Feature always did: the CLI against a server outside the container). A later version adds `server`. `OPENBAO_SETUP_MODE` in `containerEnv` overrides it per container. Nothing to do.
- `task openbao:setup`: re-runs the post-create hook.

### [1.0.4] - 2026-11-03

#### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

### [1.0.3] - 2026-10-28

#### Fixed

- Build-time downloads retry on transient network errors, so a flaky connection no longer fails the container build outright. Rebuild the container to pick it up. No change to options or tasks; nothing to do. ([#94](https://github.com/nabil-becker/devcontainer-features/pull/94))

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/openbao/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/openbao/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
