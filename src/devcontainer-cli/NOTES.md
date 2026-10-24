## What it installs

The `@devcontainers/cli` npm package, run on a private Node.js build, so
`devcontainer up`, `build`, `exec` and `features test` work inside a
container with no system-wide Node.js. `install.sh` runs
`devcontainer-cli.sh install`, which:

1. Downloads `node-v<nodeVersion>-linux-<arch>.tar.gz` and `SHASUMS256.txt`
   from `https://nodejs.org/dist/v<nodeVersion>/`, checks the tarball's
   SHA-256 against that file, and unpacks it to `/opt/devcontainer-cli/node`.
2. Runs `npm install -g --prefix /opt/devcontainer-cli @devcontainers/cli`
   (with `@<version>` unless `version` is `latest`), using that Node.
3. Writes a two-line wrapper at `/usr/local/bin/devcontainer` that runs the
   CLI with the private `node`, then runs `devcontainer --version` so the
   version is in the build log.

`node` and `npm` are deliberately not on PATH afterwards. Only the
`devcontainer` wrapper knows about them, so the Feature cannot collide with
the Node.js toolchain your project pins. It installs no Docker engine
(see Composition). The directory `/opt/devcontainer-cli` is removed and
rebuilt on every install, and npm's cache goes to a temporary directory that
is deleted, so it does not stay in the image layer.

What is verified, and what is not:

- The private Node.js is verified: a missing line in `SHASUMS256.txt` or a
  mismatch fails the build.
- The CLI itself is NOT checked against a checksum. It comes from
  `npm install -g` and is protected only by npm's own integrity metadata for
  the package and its dependencies. This Feature adds no checksum, no
  signature check and no lockfile for it. The root README names this as
  the one exception to "verifies what it downloads".

`curl`, `ca-certificates` and `tar` are installed with `apt-get` only when
missing. The install must run as root.

## Options

- `version` (default `latest`): the `@devcontainers/cli` npm version, for
  example `0.89.0`; no leading `v`. `latest` is whatever npm calls latest at
  image build time (not the `releases/latest` redirect the other installers
  use), so two builds a month apart can differ. Pin it when you want `devcontainer
  features test` or `up` to behave the same in CI and on every laptop, or
  when a new CLI release breaks something.
- `nodeVersion` (default `24.21.0`): the Node.js release the CLI runs on, as
  `x.y.z` without `v`. Change it only when a pinned CLI version needs a newer
  or older Node than the default (the CLI states its Node range), or when
  nodejs.org no longer serves the default. It does not change the Node.js
  your project uses; that one is separate.
- `installTaskfile` (default `true`): set it to `false` when you do not use
  the go-task registry and do not want
  `/usr/local/share/go-task/includes.d/devcontainer-cli.yml` in the image.

There is no run-time override; both versions are fixed at build.

## State

No state: installs binaries only. No volume, no `containerEnv`, no
post-create hook.

## Minimal `devcontainer.json`

```json
"features": {
  "ghcr.io/devcontainers/features/docker-in-docker:2": {},
  "ghcr.io/nabil-becker/devcontainer-features/devcontainer-cli:1": {
    "version": "0.89.0"
  }
}
```

Drop `version` to follow npm's latest at each image build.

## Verify it works

```bash
devcontainer --version     # prints the CLI version, for example 0.89.0
task devcontainer-cli:version
```

The build log ends the install with the same `devcontainer --version`
line. `command -v node` finds nothing, on purpose. There is no post-create
line: nothing runs after the build.

## Composition

- `installsAfter` orders it behind this collection's `go-task` Feature (so
  the Taskfile registry exists and is refreshed), the official
  `common-utils`, and the two official Docker Features
  (`docker-in-docker`, `docker-outside-of-docker`) so a Docker engine is in
  place before it when you use one.
- It needs a Docker daemon for anything that builds or runs containers
  (`up`, `build`, `features test`); `read-configuration` and `--version`
  do not. It does not install one. Pair it with one of the official
  Features:

| Host | Use | Why |
| --- | --- | --- |
| Windows / macOS (Docker Desktop) | `docker-in-docker` | `features test` and nested `devcontainer up` bind-mount paths from inside this container; only a daemon that shares its filesystem can resolve them. |
| Linux (same paths on host and container) | `docker-outside-of-docker` | Lighter, shares the host's image cache; works while the workspace is mounted at the same absolute path. |

- It augments no official Feature and replaces none. It is independent of
  `kube-state`, `git` and the other Features here.

## Tasks

With `installTaskfile` on, and a root Taskfile that includes the go-task
registry, these appear under `devcontainer-cli:`:

- `devcontainer-cli:version`: show the installed CLI version.
- `devcontainer-cli:config`: print the resolved and merged configuration of
  `WORKSPACE` (default `.`) with `devcontainer read-configuration`.
- `devcontainer-cli:features:test`: run `devcontainer features test` for the
  Features repository at `PROJECT` (default `.`); extra flags go after `--`
  (for example `-f <id>`). Needs a Docker daemon.

These are for using the CLI inside the container. To drive a devcontainer
from a host, use the `devcontainer:*` tasks (next section).

## Limits and troubleshooting

- Linux only in the container. The architectures are `x86_64`/`amd64`,
  `aarch64`/`arm64` and `armv7l`; any other `uname -m` fails with
  `unsupported architecture`.
- `... not found in SHASUMS256.txt` or `SHA-256 mismatch`: the `nodeVersion`
  does not exist for your architecture, or the download was corrupted. Fix the
  version or retry. The Node.js is never unpacked unchecked.
- A failing `npm install` (no network, or a `version` that npm does not
  have) fails the build. Check the version with `npm view @devcontainers/cli
  versions` on a machine that has npm.
- `features test` and nested `up` fail with a Docker error when no daemon
  is reachable; add `docker-in-docker` (or `docker-outside-of-docker` on
  Linux). With `docker-outside-of-docker`, a workspace mounted at a different
  path on the host than inside the container cannot be resolved.
- The CLI's own dependencies are resolved by npm at build time and are not
  locked here, so supply-chain trust in them is npm's, not this Feature's.

## Host-side counterpart

The same `devcontainer-cli.sh` that installs this Feature also has `init`
and `run` modes for a Linux/macOS host, where it caches a portable Node.js
under `~/.cache/devcontainer-features` (or just uses a `devcontainer` already
on PATH when the version is `latest`). Together with the PowerShell flavour
for Windows it backs the `task devcontainer:*` tasks that
`bootstrap/bootstrap.ps1` / `bootstrap.sh` vendor into a repo's
`.devcontainer/cli_bootstrap.ignore/` (git-ignored; `BOOTSTRAP_DIR` picks another
repo-relative folder, `BOOTSTRAP_GITIGNORE=false` keeps it committable, and the
root Taskfile include is `optional: true`: a fresh clone runs the bootstrap
first; the old `./bootstrap/` form keeps working until the bootstrap is re-run,
see the README); nothing is
installed globally on any host. Its host settings are
`DEVCONTAINER_DOCKER_PATH`, `DEVCONTAINER_NODE_VERSION`,
`DEVCONTAINER_CLI_VERSION`, `HOST_TYPE`, `HOST_TYPE_PRIORITY` and `HOST_MOUNTS` (see "Host type" and "Host mounts").

`task devcontainer:up` (alias `start`) and `task devcontainer:stop` (alias
`down`) are idempotent, so other tasks can require them. `up` starts a stopped
container and leaves a running one alone. `exec`, `shell`, `pwsh` and `claude`
run `up` first; `rebuild` runs `stop` first (shutdown check included; `FORCE=1` and
`STOP_CHECK` pass through) and then recreates the container; a stop that fails
(the check refuses, or any error) stops the rebuild too, so `FORCE=1` is the
one way to rebuild past a refusing check, as for `stop`.
`build` and `config` touch no container.

One build at a time. `up` (so `rebuild` too) and `build` hold a host-wide lock
while they run: the named mutex `Global\devcontainer-features-build` on Windows,
an `flock` on `~/.cache/devcontainer-features/build.lock` on Linux/macOS (none
on a host without `flock`, such as stock macOS). Why: when the engine has no
BuildKit build context (`wslc`), `@devcontainers/cli` tags the Feature content
image with the fixed name `dev_container_feature_content_temp` for every
repository, so two builds at once overwrite each other's image and the first
fails with `"/tmp/build-features/<feature>_N": not found`. A second build
prints `waiting for another devcontainer build to finish...` and then runs;
the lock is released when the build ends or its process dies (an abandoned lock
counts as free). It applies on every engine, harmless with Docker Desktop;
`exec`, `run-user-commands`, `set-up` and the other subcommands take no lock,
and `devcontainer features test` takes it only with
`DEVCONTAINER_BUILD_LOCK_FEATURES_TEST=true` (default false, so a long test run
does not hold up every rebuild). `DEVCONTAINER_BUILD_LOCK=0` turns the lock off.

`stop` is the one host task that is not a CLI subcommand (the CLI has none),
and it is one host-script command, the same in `run stop` and
`Stop-Devcontainer` (running? check? stop?), not nested tasks. The workspace's
container is found by the `devcontainer.local_folder` label that `devcontainer
up` sets, through the configured engine (`DEVCONTAINER_DOCKER_PATH`). The
engine's label filter is case-sensitive and the CLI writes a lowercase drive
letter (`c:\...`) where the task has `C:\...`, so the lookup tries the folder as
given, then with the drive letter lowercased, then uppercased (only for an `X:\`
path). With no running container `stop` prints "already stopped" and succeeds,
without running the check and without starting anything. Otherwise it runs the
`STOP_CHECK` command inside the container (task var, environment variable or
`.devcontainer/.env`) through the same exec path, without `up`, from the
workspace folder (the CLI's `exec` starts in the remote workspace folder), and
when the check fails it prints "Not stopping: ..." and exits with the check's
code, before stopping anything; exit 127 from it prints that the check is not
installed in the container. `FORCE=1` skips the check. With `STOP_CHECK` unset
the task passes one resolution snippet as the command: the repository's
`task shutdown:check` when its Taskfile defines it, else the devhost Feature's
`devhost-shutdown-check` (ADR 0015), else the line "no shutdown check defined;
stopping" and exit 0, so a repository without either stops without a check
(`bootstrap/SHUTDOWN.md` in the collection is the contract). `prepshutdown`
(`devcontainer:prepshutdown`) is the same command without the stop: it runs the
check and exits with its code, or says there is no container and succeeds. The engine's `ps --filter label=...` and
`stop` are assumed to behave as Docker's; this is not tested against `wslc` or
Podman. Stopping the container any other way is not guarded.

`run running` (and `Get-RunningDevcontainerId`) is the same lookup as a silent
test: exit 0 when a container runs, 1 when none does, 2 when the engine cannot
be asked. Task reports a failed command as 201 itself; `task --exit-code
devcontainer:running` passes the script's 0/1/2 through.

A failing `exec` (what `exec`, `shell`, `pwsh` and `claude` run) asks the same
lookup which of three things failed and says so, instead of one guess: the
container runs, so the command failed (`The command exited with code <n> inside
the devcontainer: <command>`, exit with that code); none runs (`No running
devcontainer for <folder>. Start it with: task dc:start`, exit 1); or the
engine could not be reached (its own error plus `the container engine (<path>)
could not be reached`, exit 2). Other subcommands keep their generic failure
message.

## Host type

The launcher (the PowerShell flavour and the bash twin, the same rules in both)
knows what kind of host it runs on, so a repository writes nothing host-specific.
`HOST_TYPE` names it; the design is in `docs/proposals/host-profile.md` and ADR 0024.

| `HOST_TYPE` | Detected by | Engine | `DCF_HOST_HOME` |
| --- | --- | --- | --- |
| `windows-docker` | launcher on Windows; `docker` on PATH answers `docker info` | `docker` | `%USERPROFILE%` |
| `windows-wsl-docker` | inside a WSL distro (`WSL_DISTRO_NAME`, or `/proc/version` names Microsoft); or, from Windows, `wsl -e docker info` answers | `docker` | the distro's `$HOME` (asked through `wsl.exe` from Windows) |
| `windows-wslc` | launcher on Windows; `wslc.exe` on PATH or in `C:\Program Files\WSL` | `wslc` | `%USERPROFILE%` |
| `linux` | `uname -s` is Linux and not WSL | `docker` | `$HOME` |
| `macos` | `uname -s` is Darwin | `docker` | `$HOME` |

- `HOST_TYPE` defaults to `auto`; an explicit id skips detection (and must fit the launcher's OS: the
  bash twin runs on Linux, macOS and inside WSL, so it takes `linux`, `macos` and `windows-wsl-docker`;
  the Windows ids belong to the PowerShell launcher). An unknown id is an error that lists the valid ones.
- `HOST_TYPE_PRIORITY` is the ordered, comma-separated list `auto` walks, taking the first id whose
  detection passes. Default per OS the launcher runs on: Windows `windows-docker,windows-wsl-docker,windows-wslc`;
  inside a WSL distro `windows-wsl-docker`; Linux `linux`; macOS `macos`. An organisation that wants Docker in
  WSL first writes `HOST_TYPE_PRIORITY=windows-wsl-docker,windows-docker,windows-wslc` in `.devcontainer/.env`.
- `DEVCONTAINER_DOCKER_PATH` still names the engine and always wins, whatever the host type (podman, a full path).
  In the PowerShell launcher, with `HOST_TYPE=auto`, nothing passing and `DEVCONTAINER_DOCKER_PATH` set, the first id of
  the priority list that fits the OS is taken, because the engine is given. Unset, the engine follows the host type, so on Windows
  `docker` that is on PATH but whose daemon is down no longer wins over an installed `wslc.exe`.
- Before it runs the CLI (`up`, `build`, `exec` and the other subcommands that take `--docker-path`) the launcher sets
  `DCF_HOST_TYPE` (the resolved id), `DCF_HOST_HOME` (the host user's home) and `DCF_HOST_SSH_AGENT`
  (`socket`, `none` or `key`, see "The SSH agent" below) in its own environment. A repository maps them into the
  container itself with `containerEnv`, `"DCF_HOST_TYPE": "${localEnv:DCF_HOST_TYPE}"` and so on (the bootstrap's
  `devcontainer.json` template does). It declares no host mount: the launcher adds those (next section). Opening the
  folder straight in VS Code skips the launcher: the variables are then empty.
- `task devcontainer:host` prints the result without starting anything: `HOST_TYPE` as resolved and why, the priority list
  used, the engine command, the three `DCF_HOST_*` values and the host mounts `up` would add or skip (next section).
  `HOST_TYPE=<id>` or `HOST_TYPE_PRIORITY=<ids>` on the command line try other choices.

Not verified on real hosts: `wsl -e docker info` answering for the default distro; the WSL markers on every WSL version
(a container on a WSL 2 kernel also reads as WSL); `windows-wsl-docker` driven from Windows, where `--docker-path` takes
one executable, so it needs a `docker` on PATH that reaches the distro or `DEVCONTAINER_DOCKER_PATH`; and Docker
Desktop's context. The evidence is replaceable: the bash twin reads `DCF_HOST_UNAME` and `DCF_HOST_PROC_VERSION`
instead of `uname -s` and `/proc/version`, and an explicit `HOST_TYPE` skips detection altogether.

## Host mounts

A repository should need no host-specific mount line. `devcontainer up` takes `--mount
type=bind,source=<host path>,target=<container path>` (repeatable), so the launcher (both flavours) adds the mounts
the host type needs; ADR 0024 decides it, `docs/proposals/host-profile.md` is the design.

- **What is added.** Two entries. The first, for every host type: the host home's `.git-dirs` folder at `/git-dirs`
  (source `<DCF_HOST_HOME>/.git-dirs`: `%USERPROFILE%/.git-dirs` on Windows, in the same mixed-slash form
  `${localEnv:USERPROFILE}/.git-dirs` has always produced; the distro's `$HOME/.git-dirs` for `windows-wsl-docker`; `$HOME`
  elsewhere). It is what the git Feature's wrapper maps a `.git` pointer onto, so a checkout whose git dir lives outside
  the checkout (OneDrive) works without a line in `devcontainer.json`. The list is one function per launcher
  (`Get-HostMount` in `DevcontainerCli.psm1`, `host_mount_specs` in `devcontainer-cli.sh`), keyed by host type. The
  second is the SSH agent socket where the host type has one (next section).
- **The SSH agent (slice 4, devcontainer-cli 1.8.0).** The launcher bind-mounts the host's agent socket at
  `/var/lib/devcontainer-features/ssh-agent/agent.sock`, the fixed path of the `ssh-agent` Feature's `SSH_AUTH_SOCK`,
  and sets `DCF_HOST_SSH_AGENT` to say what it did: `socket` when it adds the mount, `none` otherwise, `key` when
  `SSH_AGENT_MODE=key` (the user's opt-in to a key kept in the container, which also suppresses the mount).

  | Host type | Source mounted | `DCF_HOST_SSH_AGENT` |
  | --- | --- | --- |
  | `linux` | `$SSH_AUTH_SOCK` of the launcher, only when set and a socket | `socket`, else `none` |
  | `macos` | `/run/host-services/ssh-auth.sock` (Docker Desktop's, inside its VM; cannot be checked from the host) | `socket` |
  | `windows-wsl-docker` | the distro's `$SSH_AUTH_SOCK`, only when the launcher (bash twin) runs inside the distro | `socket`, else `none`; always `none` from Windows |
  | `windows-docker`, `windows-wslc` | none: the Windows agent is a named pipe and a relay would be a process left running on the host | `none` |

  The mount's source is a socket, so the launcher never creates it as a folder. It is skipped like the others when the
  repository's `devcontainer.json` already mounts that target, and `HOST_MOUNTS=false` removes it. Loading keys:
  `task devcontainer:ssh-add -- <key>` runs the host's `ssh-add` once (no arguments: `-l`), for the host agent
  that socket mode forwards; on Windows it says the container cannot reach that agent. `task devcontainer:ssh-key-import
  FILE=<private key on the host>` is the opt-in key mode's import: the file goes to the running container through
  `devcontainer exec` on stdin (never an argument), into the ssh-agent Feature's key volume with mode 0600 and its `.pub`
  beside it, then the Feature loads it; it refuses when the container is not running, key mode is off there, or FILE is
  missing, and prints the fingerprint, never the key. Since 1.10.0 it also warns, on the host and never blocking, when FILE has
  a default name (`id_ed25519` and the like) or its public key (`FILE.pub`, or derived with `ssh-keygen -y` only when the key
  has no passphrase) is also in `~/.ssh/authorized_keys` or the same as another `~/.ssh/*.pub`: such a key is
  general-purpose and should not live in a container volume (it prints fingerprints, never key material).
  Both are one-shot commands; nothing stays running on the host.
  Not verified on a real host: `devcontainer exec` forwarding its stdin on every platform (the tests use a stub).
- **Several Claude sessions (1.9.0).** `task devcontainer:claude:fleet` passes `SESSIONS` (set by the including Taskfile)
  and its arguments to the claude-code Feature's `claude-fleet` in the container (through `exec`, or directly inside); see
  that Feature's notes. `devcontainer:claude` itself gains nothing: its `claude-host` now refuses to start a session already running in the folder
  (and says when the pinned id is stale).
- **Which subcommands.** `up` only, and so `rebuild` and `start`. `build` mounts nothing (it builds an image, no container),
  `exec`, `shell`, `pwsh` and `claude` run in a container that exists, and the other subcommands take no mounts. They
  add nothing to the argument list.
- **The source folder exists.** Before `up` the launcher creates `<host home>/.git-dirs` when missing (idempotent), so a
  start never fails on a missing bind source. (`devcontainer:homes` still does the same for a repository that opens the
  folder in VS Code directly.) For `windows-wsl-docker` driven from Windows the folder is a distro path Windows cannot
  create; there the distro's own `devcontainer:homes`, or `mkdir -p`, applies. A home with a comma in it cannot be carried
  by `--mount` (it separates the fields): the mount is skipped with a warning.
- **No duplicate mount.** When the repository's `devcontainer.json` already mounts a target the launcher would add (its own
  `/git-dirs` line, as this collection's own does, because opening it from VS Code bypasses the launcher), the launcher adds
  nothing for that target and prints one line, `host mount skipped: /git-dirs is already mounted by this repository's
  devcontainer.json`. So keeping the line is harmless, and a repository can drop it once it starts through the tasks.
- **How "already mounted" is known.** From the file, not from the CLI: the launcher strips the comments of `--config <file>`,
  else `.devcontainer/devcontainer.json`, else `.devcontainer.json`, and reads the targets of the `mounts` array (the
  `source=...,target=/x` strings and objects with `"target"`; a trailing slash does not matter; no JSON parser, so trailing
  commas and `//` inside strings are fine). Measured: about 8 to 10 ms in either flavour. The alternative,
  `devcontainer read-configuration`, costs a second Node start (0.23 to 0.47 s here) and asks the engine (`docker ps`), so it fails
  when the engine is down, which `task devcontainer:host` must survive. The limit: only the repository's own file is read; mounts
  that Features declare, docker-compose services and a `--mount` the engineer passes themselves are not seen (none of them
  declares the host mounts).
- **Off.** `HOST_MOUNTS=false` (also `0`, `no`) as a Task var, `.devcontainer/.env` value or environment variable (PowerShell:
  `-HostMounts`) turns all of the launcher's mounts off; the repository then declares what it needs.
- **See it.** `task devcontainer:host` lists `host mount (add)` and `host mount (skip)` lines (or `off`) after the `DCF_HOST_*`
  values, and starts nothing and creates nothing.
- **Not covered.** A container started by VS Code's Reopen in Container never passes through the launcher, so it gets the
  repository's own line only; there `${localEnv:DCF_HOST_HOME}` is empty and the line must use `${localEnv:USERPROFILE}`
  (Windows host) or `${localEnv:HOME}`.

## Why this one exists

The Dev Container CLI is published by the Dev Containers project as an npm
package, and its documented install is `npm install -g @devcontainers/cli`,
which needs a Node.js on PATH. This repository knows of no published Dev
Container Feature that installs it, so there is none to compare. This Feature
exists so that a container can run the CLI without a system-wide Node.js, and
so the same script serves the container and the host-side tasks.
