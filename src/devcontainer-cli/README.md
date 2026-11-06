
# Dev Container CLI (devcontainer-cli)

Installs @devcontainers/cli as /usr/local/bin/devcontainer, backed by a private, sha256-verified Node.js under /opt/devcontainer-cli that is NOT added to PATH - so `devcontainer up/build/exec/features test` work inside a container without a system-wide Node.js. Pair with docker-in-docker (needed for features test and nested `up` on Windows/macOS hosts) or docker-outside-of-docker (Linux hosts, same paths).

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/devcontainer-cli:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| version | @devcontainers/cli npm version to install (e.g. '0.89.0'), or 'latest'. | string | latest |
| nodeVersion | Node.js release used privately by the CLI. Downloaded from nodejs.org and verified against its SHASUMS256.txt. | string | 24.21.0 |

## How it fits

```text
  host: task devcontainer:* (launcher; bootstrap vendored into the repo)
     |  adds mounts: ~/.git-dirs, ssh agent socket, cloud folder, audio relay dir (opt-in)
     v
  devcontainer CLI  --needs--> Docker daemon
  (private Node in /opt/devcontainer-cli,    (docker-in-docker, or
   not on PATH)                               docker-outside-of-docker)
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Nothing | installs binaries only; no volume, no `containerEnv`, no hook | none |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: [windows-workstation-devhost](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/reference-architectures/windows-workstation-devhost.md)

## What it installs

The `@devcontainers/cli` npm package, run on a private Node.js build, so
`devcontainer up`, `build`, `exec` and `features test` work inside a
container with no system-wide Node.js. `install.sh` runs
`devcontainer-cli.sh install`, which:

1. Downloads `node-v<nodeVersion>-linux-<arch>.tar.gz` and `SHASUMS256.txt`
   from `https://nodejs.org/dist/v<nodeVersion>/`, checks the tarball's
   SHA-256 against that file, and unpacks it to `/opt/devcontainer-cli/node`.
   Both downloads go through `dcf_curl` (`dcf-curl.sh`, the collection's
   download helper, vendored from `common`), which retries every error on
   curl 7.71+, a TLS reset or a connection cut mid-transfer included.
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
`.devcontainer/cli_bootstrap.ignore/` (with `dcf-curl.sh`, its download helper,
beside it in `host/`; git-ignored; `BOOTSTRAP_DIR` picks another
repo-relative folder, `BOOTSTRAP_GITIGNORE=false` keeps it committable, and the
root Taskfile include is `optional: true`: a fresh clone runs the bootstrap
first; the old `./bootstrap/` form keeps working until the bootstrap is re-run,
see the README); nothing is
installed globally on any host. Its host settings are
`DEVCONTAINER_DOCKER_PATH`, `DEVCONTAINER_NODE_VERSION`,
`DEVCONTAINER_CLI_VERSION`, `HOST_TYPE`, `HOST_TYPE_PRIORITY` and `HOST_MOUNTS` (see "Host type" and "Host mounts"); the cloud-folder sign-in reads `CLOUD_FOLDER_LOGIN_TIMEOUT` (see "Cloud-folder sign-in").

`task devcontainer:up` (alias `start`) and `task devcontainer:stop` (alias
`down`) are idempotent, so other tasks can require them. `up` starts a stopped
container and leaves a running one alone. `exec`, `shell`, `pwsh`, `agent` and `claude`
run `up` first; `rebuild` runs `stop` first (shutdown check included; `FORCE=1` and
`STOP_CHECK` pass through) and then recreates the container; a stop that fails
(the check refuses, or any error) stops the rebuild too, so `FORCE=1` is the
one way to rebuild past a refusing check, as for `stop`.
`build`, `config`, `lock` and `outdated` touch no container. `task devcontainer:lock` rewrites
`.devcontainer/devcontainer-lock.json` to the Feature versions `devcontainer.json` asks for
(`devcontainer upgrade`): run it after changing a Feature version, then commit the lock file;
`task devcontainer:outdated` lists what is behind. Features referenced by a local path are never
locked.

One build at a time, where builds can collide. `up` (so `rebuild` too) and
`build` hold a host-wide lock while they run: the named mutex
`Global\devcontainer-features-build` on Windows, an `flock` on
`~/.cache/devcontainer-features/build.lock` on Linux/macOS (none on a host
without `flock`, such as stock macOS). Why: when the engine has no BuildKit
build context (`wslc`), `@devcontainers/cli` tags the Feature content image
with the fixed name `dev_container_feature_content_temp` for every repository,
so two builds at once overwrite each other's image and the first fails with
`"/tmp/build-features/<feature>_N": not found`. When `<engine> buildx version`
reports 0.8.0 or later (Docker with buildx; the same check the CLI makes) the
CLI builds with BuildKit build contexts and makes no such image, so the
launcher skips the lock and says so in one line (`build lock skipped: ...`);
`wslc` always takes it. `DEVCONTAINER_BUILD_LOCK=1` takes it on every engine,
`DEVCONTAINER_BUILD_LOCK=0` never.

A waiter says whom it waits for. The holder writes `holder.json` (Windows) or
`holder` (bash) in `build-lock/` under the launcher cache
(`%LOCALAPPDATA%\devcontainer-features`, `~/.cache/devcontainer-features`):
its pid, its repository's folder name, the subcommand with its flags (not their
values) and its start time; each waiter writes a `waiter-<pid>` file while it
waits. The line reads `waiting for alpha's up --build-no-cache (started 14:02, 2
waiting)...` and is printed again when the holder or the count changes; without a
live holder file (an older launcher holds the lock, or its holder died) it is
`waiting for another devcontainer build to finish...`. A file whose process is
gone is ignored. The count is every other waiter, not the holder and not
this one, whenever it arrived (none, no count): the lock is not first-come, so
any of them may go next. The lock is released when
the build ends or its process dies (an abandoned lock counts as free).
`exec`, `run-user-commands`, `set-up` and the other subcommands take no lock,
and `devcontainer features test` takes it only with
`DEVCONTAINER_BUILD_LOCK_FEATURES_TEST=true` (default false, so a long test run
does not hold up every rebuild).

The engine answers first. Right after a rebuild or an engine restart the engine
may not answer for a moment, and `devcontainer up` then fails inside with
`Command failed: docker ps -q -a --filter label=...` and "An error occurred
setting up the container", the engine's own error hidden by `@devcontainers/cli`.
So `up`, `build`, `exec`, `set-up` and `run-user-commands` first check that the
engine the CLI will use answers: `docker info` (or `podman info`), `ps -q` for
any other engine (`wslc` has no `info`). When it answers that is the one check;
otherwise the launcher prints `waiting for the container engine to answer...`
once, checks every second for `DEVCONTAINER_ENGINE_WAIT` seconds (default 60;
`0` = no wait, no check), and then fails without running the CLI, naming the
engine, its own error and how to start it (Docker Desktop; the Docker Engine in
the WSL distro; `wsl --status` for `wslc`; `systemctl start docker`). The wait
runs inside the build lock, right before the CLI. When `up`, `build`, `set-up` or
`run-user-commands` fails anyway, the launcher asks the engine once more and
prints what it says: its error and how to start it, or that it answers now (the
failure was a moment when it did not, and a second run usually goes through).
On Windows with `HOST_TYPE=auto` the host type is detected before the wait, and
detection asks the engines too: with every engine down it fails at detection,
as before.

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

## Cloud-folder sign-in

`task cloud-folder:login` (or `task devcontainer:cloud-folder-login`) on the workstation signs the
cloud-folder Feature's remote in. rclone's sign-in sends the browser back to the fixed
`http://localhost:53682/` (its app registration allows nothing else), where rclone listens inside
the container; the workstation's `localhost:53682` is not the container's. So, by default, the
launcher:

1. finds the running container by its `devcontainer.local_folder` label (none: `task dc:start`);
2. opens a listener on `127.0.0.1:53682` on the workstation, for this sign-in only (a python3
   program in the bash twin, a `TcpListener` in PowerShell);
3. starts `cloud-folder-setup login --relay` in the container through `devcontainer exec`, which
   runs `rclone authorize "onedrive" --auth-no-open-browser` there and prints its link;
4. opens the default browser at that link (`DCF_BROWSER` names another command; without an opener
   the address is printed);
5. relays each request of the browser into the container: `<engine> exec -i <id> bash -c` opens
   `/dev/tcp/127.0.0.1/53682` there, writes the request (made HTTP/1.0 with `Connection: close`)
   and copies rclone's answer back. No port mapping, no socat, nothing in `devcontainer.json`;
6. closes the listener when the login ends, fails, or after `CLOUD_FOLDER_LOGIN_TIMEOUT` seconds
   (default 600), and says so.

When `53682` is taken on the workstation, or (bash twin) there is no `python3`, it says so and runs
the container's login on this terminal instead: paste back the address the browser fails to open
(`-- --paste` chooses that). `-- --workstation-rclone` signs in with rclone on the workstation
instead: the version is the repository's cloud-folder `rcloneVersion` in `devcontainer.json`, else
the Feature's default (both twins carry it; a test keeps it equal), `latest` asks the publisher;
the release zip is downloaded once into the launcher cache (`%LOCALAPPDATA%\devcontainer-features\rclone`,
`~/.cache/devcontainer-features/rclone`) with the retrying download helper, checked against the
release's `SHA256SUMS` (saved to a file and read as text on Windows), and its `rclone authorize
"onedrive"` opens the browser itself; the token goes to `cloud-folder-setup login --token` in the
container on stdin, never as an argument, and is never printed. Not verified on a real host: the
relay through Docker Desktop, `wslc exec -i` and a WSL distro's localhost forwarding.

## The OpenBao key file (Windows)

With the openbao Feature (1.5.0 or later) in server mode and its option `unlock: keyfile`, the
Windows launcher unseals OpenBao and logs the Operator in at every start, with nothing typed. The
**OpenBao key file** holds unseal shares 4 and 5 and the Operator's AppRole login (role id, secret
id) for one server; shares 1 to 3 are the **custody shares** the Operator keeps. Repositories whose
openbao Feature is not set to `unlock: keyfile`, or that have no openbao Feature, see no change.

- **Where it lives**: `%LOCALAPPDATA%\devcontainer-features-keys\openbao\<repo>-<cluster id>.keyfile`,
  one file per server (`<repo>` is the workspace folder's name). Its own folder, not the launcher's
  download cache (`%LOCALAPPDATA%\devcontainer-features`), which may be cleared; `%LOCALAPPDATA%`
  does not roam and is not in OneDrive's known-folder move. Never in the shared folder, the checkout
  or git.
- **How it is protected**: Windows DPAPI (`ProtectedData`, scope `CurrentUser`, a fixed entropy of
  this launcher). It opens for any process running as your Windows account on that machine, and for
  nobody else; on a domain-joined machine **the domain's DPAPI backup key opens it too**. A Claude
  Code session on the workstation runs as you and could open it: the share and file tasks below
  refuse inside one, but the file itself cannot tell. The plain JSON exists only in the launcher's
  memory.
- **Windows only for now**: the bash launcher (Linux, macOS, a WSL distro) has no store; its tasks
  say "the OpenBao key file is Windows-only for now" in one line and `up` has no unlock step there.

**At every start.** After a successful `up` (so `start`, `shell`, `pwsh`, `exec`, `agent`, `claude`
and `rebuild`), the launcher asks `/usr/local/bin/openbao-setup unlock --status` in the container.
When the mode is `keyfile` and the server is sealed or the token is missing or dead, it opens this
server's key file and streams it into `openbao-setup unlock --stdin`, then prints one line
(`openbao: unsealed, logged in (the OpenBao key file).`, or why not). Silent when the mode is `off` or
`operator`, when the status says `ready`, and when the container has no `openbao-setup` that
answers. With no key file for that server it says so in one line and names
`task dc:openbao:keyfile:create` (or two custody shares at `task openbao:unseal` in the container,
then `task dc:openbao:keyfile:rotate`); the start goes on and OpenBao stays sealed. A failing step
never fails the `up`.

**How it travels.** Through the engine's own `exec -i -u <remote user> <container>
/usr/local/bin/openbao-setup ...` (the remote user from the container's `devcontainer.metadata`
label), not `devcontainer exec`, which runs the user's profile first; the bytes are written to its
standard input from memory. Never an argument, an environment variable, a temporary file or a log
line. Not verified on a real host: `wslc exec -i -u`.

**The tasks** (from the workstation; inside the container they say so and stop):

| Task | What it does |
|---|---|
| `task dc:openbao:unlock` | The same step on demand, for a container started another way (VS Code); says so when OpenBao is ready or the mode is not `keyfile`. |
| `task dc:openbao:keyfile:create` | Once per server. On today's server, type two custody shares at hidden prompts (`Read-Host -AsSecureString`); on an uninitialised one nothing is typed. The container prepares five shares, threshold two (or initialises so), makes the `operator` AppRole; the launcher saves the key file, confirms, and then prints the three custody shares once (see "Two steps" below). |
| `task dc:openbao:keyfile:rotate` | New shares and a new secret id: with this workstation's key file for that server nothing is typed, else any two of the five. After a suspected copy, a restore, an onboarding claim, and once agents run as their own Linux user. Replaces the key file and prints the three new custody shares once. |
| `task dc:openbao:keyfile:export FILE=<path> [SERVER=<id>]` | Writes the key file to `FILE` (outside the checkout, a new file) encrypted with a one-time transfer passphrase printed once (AES-256-GCM, a key from PBKDF2-SHA256), for a second workstation that restores this server's backups. Carry the file and the passphrase by different routes. |
| `task dc:openbao:keyfile:import FILE=<path>` | Asks the passphrase (hidden), saves the key file with this workstation's DPAPI and deletes the transfer file. Refuses when a key file for that server is here already; a wrong passphrase changes nothing. |
| `task dc:openbao:keyfile:forget [SERVER=<id>]` | Deletes the key file after a `y`. Its shares 4 and 5 keep opening the server and its backups until a `rotate`; set `unlock: operator` to go back to typing. |

**Two steps, so a rotation never outruns the key file.** `create` and `rotate` use OpenBao's rekey
verification: the container's first answer is a *pending* rotation (the old shares still unseal).
The launcher then saves the new key file, reads shares 4 and 5 back from it and sends them to
`keyfile confirm`; only that makes the new shares take effect, and only after confirm answers ok are
the custody shares printed. When the key file cannot be saved, or confirm fails, the launcher puts
the previous key file back (or removes the new one) and cancels the pending rotation (`keyfile
cancel`, always with this run's nonce): the old shares and the old key file stay in force, and no
custody share is shown. When confirm's answer is lost it asks once more (confirm is idempotent),
then `keyfile status`: `pending` equal to this run's verification nonce means not applied (cancel, previous key
file back); `pending` empty with five shares means applied (the custody shares are printed; this is
how a rotate, five shares before and after, is told apart). Anything else (another rotation
pending, or no answer) cannot be told: nothing is cancelled, since the launcher never cancels a
rotation it did not start, the new key file stays with the previous one beside it as
`<file>.previous`, and no custody share is shown. The nonce step 1 returns is
`<verification nonce>:<narrow confirm token>` (`init` for an initialisation); it is a secret: the
launcher sends it whole on confirm and on every cancel (so the container can cancel the rekey on
the server at once), compares only the part before the first colon with `pending`, and never prints
or logs it. Warnings the container returns are shown as
`openbao: warning: ...` lines; a failure shows the container's `error` (else its `code`).

Each time custody shares are printed, store them again, each in its own place, and **keep the
previous custody shares until the backups made under them are pruned**: a backup opens only with the
shares in force when it was made. Then clear the console. `SERVER=<cluster id>` is needed only when
this workstation has key files for several servers of the repository.

**The agent guard.** `create`, `rotate`, `export` and `import` handle custody shares or the whole
key file, so they refuse (exit 3) when `CLAUDECODE`, `DEVHOST_JOB_CHILD` or a variable named in
`OPENBAO_AGENT_JOB_VARS` (space separated) is set on the workstation, and they are
`interactive: true` tasks. Run them yourself in a plain terminal. Until agents run as their own
Linux user in the container, any agent there could read what the unlock leaves (the token, and
while it runs, the shares): rotate once that lands.

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
  `DCF_HOST_TYPE` (the resolved id), `DCF_HOST_HOME` (the host user's home), `DCF_HOST_SSH_AGENT`
  (`socket`, `none` or `key`, see "The SSH agent" below), `DCF_HOST_CLOUD_FOLDER` (the user's own value, passed on
  unchanged, see "The cloud folder" below) and `DCF_HOST_MACHINE` (the machine name, see the CHANGELOG, 1.16.2) in its own environment. A repository maps them into the
  container itself with `containerEnv`, `"DCF_HOST_TYPE": "${localEnv:DCF_HOST_TYPE}"` and so on (the bootstrap's
  `devcontainer.json` template does). It declares no host mount: the launcher adds those (next section). Opening the
  folder straight in VS Code skips the launcher: the variables are then empty.
- `task devcontainer:host` prints the result without starting anything: `HOST_TYPE` as resolved and why, the priority list
  used, the engine command, the `DCF_HOST_*` values (with the machine-line hint),, the FUSE grant when `DCF_HOST_FUSE` asks for it, and the host mounts `up` would add or skip (next section).
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
  **Since 1.19.0 `devcontainer:ssh-key-import` is deprecated** (it says so; it goes with ssh-agent 2.0) in favour of
  `task devcontainer:openbao-ssh-import FILE=<private key on the host> [NAME=]`: the same stream on stdin, the same
  host-side warnings, into the `openbao` Feature's `task openbao:ssh:import FROM=file` in the running container, which
  stores the key in OpenBao as `ssh/<NAME>` (default the file name) and adds its public key to the repository's
  `.devcontainer/allowed_signers`; the container must have the openbao Feature 1.3.0 or later, its server unsealed and a
  login (`task openbao:login`), and a key with a passphrase is imported inside the container instead, where ssh-keygen can
  ask for it. Then `task ssh-agent:key:load NAME=ssh/<NAME>` loads it for a sitting (ADR 0048, ADR 0026).
  All three are one-shot commands; nothing stays running on the host.
  Not verified on a real host: `devcontainer exec` forwarding its stdin on every platform (the tests use a stub).
- **The cloud folder (1.12.0).** When `DCF_HOST_CLOUD_FOLDER` names a host folder (one a sync client keeps, such as a
  SharePoint or OneDrive folder), `up` bind-mounts it at one fixed path, `/mnt/cloud-folder-host`, the `cloud-folder`
  Feature's host mount (a constant in both twins and in the Feature). The Feature links its `mountPoint` option to that
  path at build time, so a consumer names the path in the container once, in the option, and the launcher needs no
  target setting. The variable is a setting like the others: a Task var, `.devcontainer/.env` or the environment
  (PowerShell: `-CloudFolder`); the path is shell-quoted on its way, so spaces and quotes in a library's name survive.
  Unset means no folder and no mount. The
  folder is the user's, so it is never created: a path this launcher can check (a Windows path from Windows, an absolute
  path elsewhere) that is not a folder is skipped with one warning and the container starts without it (the Feature's
  `task cloud-folder:status` then fails); another form, such as a Windows path seen from Linux, goes to the engine as is.
  A source with a comma is skipped the same way. `HOST_MOUNTS=false` and a
  repository line for the same target suppress it like the others. `DCF_HOST_CLOUD_FOLDER` itself is passed on to the
  CLI unchanged, so `containerEnv` can map it (the bootstrap's template does) and the Feature's report can name the
  source. Not verified on a real host: Docker Desktop and wslc taking a Windows path with spaces from `--mount`.
- **FUSE on request (1.15.0).** The `cloud-folder` Feature's `mount` mode (`rclone mount`) needs `/dev/fuse`,
  `CAP_SYS_ADMIN` and an AppArmor profile that allows mount. The launcher grants them per machine, only when the project
  asks, never by default (ADR 0031): with `DCF_HOST_FUSE=1` (or `true`, `yes`, `on`; a Task var, `.devcontainer/.env`
  or the environment; PowerShell `-Fuse`) it sets `DCF_HOST_FUSE_DEVICE=--device=/dev/fuse`,
  `DCF_HOST_FUSE_CAP=--cap-add=SYS_ADMIN` and `DCF_HOST_FUSE_SECURITY=--security-opt=apparmor=unconfined` before it
  runs the CLI, and passes `DCF_HOST_FUSE=1` on for `containerEnv`. Unset, the three are removed from the CLI's
  environment, so a value left in a shell or `.env` never reaches the container. `devcontainer up` has no option for
  run arguments and a Feature's `capAdd`/`securityOpt` would reach every consumer, so the repository's `runArgs` read
  the three with a harmless default, `"${localEnv:DCF_HOST_FUSE_DEVICE:--label=dcf.fuse.device=off}"` and so on (the
  bootstrap's `devcontainer.json` carries the three lines; checked against `@devcontainers/cli` 0.90.0's
  `read-configuration`). `up` and `task devcontainer:host` warn once when FUSE is asked for and the repository's
  `devcontainer.json` lacks a line. A change takes effect at the next `task devcontainer:rebuild` (run arguments
  belong to the container). Not on `windows-wslc` (1.16.3): `wslc run` has no `--device`, `--cap-add` or
  `--security-opt` option and refuses a start that carries one, so there the launcher withholds the grant, warns
  once with the reason and starts the container without FUSE (`auto` takes sync); `host` prints the refusal. Not
  verified on a real host: Docker Desktop and a Kubernetes cluster taking the three arguments (proposal section 11,
  item 6).
- **Downloads retry (1.14.1).** The Node.js tarball and `SHASUMS256.txt` go through `dcf_curl` (`dcf-curl.sh`,
  vendored from `common`, and vendored by the bootstrap next to `host/devcontainer-cli.sh`): a TLS reset or a cut
  connection is retried on curl 7.71+. A host whose bootstrap folder predates it re-runs the bootstrap; without
  `dcf-curl.sh` beside it the script stops with that hint when it has to download Node.js, and every other verb works.
- **Reset the agents (1.14.0).** `task devcontainer:agent:reset -- <name>... | --all [--purge] [--include-unlisted]
  [--yes] [--force]` runs the `agents` Feature's reset in the container (agents 1.0.1; a dry run unless `--yes`), the
  same way as `devcontainer:agent`; `AGENTS_FILE=<path>` before the `--` picks another list.
- **One verb for every agent (1.13.0).** `task devcontainer:agent -- <name> [--resume|--new] [extra CLI args]` runs the
  `agents` Feature's start verb in the container (`agents start`, through `exec` with a terminal, starting the container
  first; directly when already inside), and `task devcontainer:agent:list [-- --json]` its list. `AGENTS_FILE=<path>`
  on the command line (before the `--`) picks another agent list; it reaches the container as `AGENTS_FILE_TASK_VAR`,
  and the `agents` command resolves it against `.env` and the environment there. Taskfile tasks only: neither launcher
  twin changes. `devcontainer:claude` and `devcontainer:claude:fleet` still work and print one line saying they are
  deprecated and go with claude-code 2.0; the migration is in `docs/migrations/agents.md` of the collection.
- **Fleet waits, reports and stops duplicates (1.11.0).** `task devcontainer:claude:fleet -- --no-wait|--stop-duplicates` reach `claude-fleet` (claude-code 1.6.0); the task description says so.
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

## Audio (opt-in, gated on the workstation)

`DCF_HOST_AUDIO=wslg` (a Task var, `.devcontainer/.env` or the environment; PowerShell `-Audio`) lets the
container have the workstation's microphone through WSLg's PulseAudio socket, for the `audio` Feature (which installs the
recorders and fixes `PULSE_SERVER=unix:/mnt/wslg/PulseServer`), but only while the engineer has turned it on, on the
workstation. Since 1.21.0 (always on); gated since 1.22.0; backlog items `audio-feature` and `audio-gate-ttl`, ADR 0057.

```text
  workstation (default WSL distro)                       container
  /mnt/wslg/PulseServer  (WSLg, the real socket)         never mounted
        ^
        |  socat, only while task audio:on runs (TTL), as root
        |
  /mnt/wsl/devhost-audio/PulseServer   ==== mounted ===> /mnt/wslg/PulseServer
  /mnt/wsl/devhost-audio/expires       (time left)        PULSE_SERVER points here
  task audio:off, or the TTL ending: socket file gone     audio-check: "off" / "ready"
```

- **Why a relay directory.** WSLg puts its socket at `/mnt/wslg/PulseServer` in the user's WSL distros, but the container
  engine's own distro (Rancher Desktop's, proven on 2026-11-06) does not see `/mnt/wslg`. Every WSL2 distro shares
  `/mnt/wsl`, so a directory there is visible to the engine. Mounting WSLg's own directory (1.21.0) made the microphone
  always reachable by any process in the container, and nothing in the container could be trusted to gate it (pactl
  suspend, chmod and an environment variable can all be undone from inside). The switch has to be where the container
  cannot reach it: the workstation. The real socket is never mounted; the container sees an empty directory until a relay
  puts a socket in it.
- **What `up` does.** Before `devcontainer up`, on `windows-docker` and `windows-wsl-docker` (the PowerShell launcher;
  the bash twin from inside a distro: `windows-wsl-docker`, through WSL interop): one `wsl.exe -u root -e sh -c
  '<one line>'` in the default distro, which says `nopulse` when that distro has no `/mnt/wslg/PulseServer`, `present`
  when `/mnt/wsl/devhost-audio` is already there, and otherwise makes it. Then it adds `--mount
  type=bind,source=/mnt/wsl/devhost-audio,target=/mnt/wslg` and sets `DCF_HOST_AUDIO=wslg`, which the repository's
  `containerEnv` passes on (`"DCF_HOST_AUDIO": "${localEnv:DCF_HOST_AUDIO}"`; the bootstrap's template has it). The
  microphone is OFF after `up`. `PULSE_SERVER` is the audio Feature's own `containerEnv`, because `devcontainer up` has no
  option for container environment variables.
- **The switch.** `task audio:on [TTL=<duration>]`, `task audio:off` and `task audio:status` (the root Taskfile includes the
  vendored `audio.yml`; the launcher subcommand is `audio on|off|status`). `on` runs one `wsl.exe -u root -e sh -c
  '<one line>' sh on <seconds> /mnt/wsl/devhost-audio /mnt/wslg/PulseServer`: the script checks `socat` and WSLg's socket, ends
  an earlier relay, writes `expires`, and starts `setsid sh -c 'exec timeout <seconds> socat
  UNIX-LISTEN:/mnt/wsl/devhost-audio/PulseServer,fork,mode=0666 UNIX-CONNECT:/mnt/wslg/PulseServer'`, with its pid in
  `/mnt/wsl/devhost-audio.pid` (outside the mounted directory), and answers `on <seconds>` once the socket exists. The
  relay is a process of the WSL distro, not of Windows: nothing of ours is left running on the Windows host (ADR 0026),
  and no daemon runs while audio is off. `off` kills the relay's process group and removes the socket and `expires`; when
  the duration ends `timeout` stops socat, which unlinks its socket. `status` prints `on` with the time left, or `off`.
- **The duration.** `TTL` is `90s`, `15m` or `2h`; a bare number is minutes. Without it, `DCF_HOST_AUDIO_TTL` (default
  `15m`). `DCF_HOST_AUDIO_TTL_MAX` (default `2h`) is the longest: more is cut to it, with a line saying so. Something that
  is not a duration is refused and runs nothing.
- **The workstation wins.** `audio off` always ends it, whoever turned it on. The container cannot turn audio on or off:
  see ADR 0057 for the container-side request (not built, and why).
- **Root in the default distro, and not for ever.** `/mnt/wsl` is memory: the directory and any relay live until WSL
  restarts (`wsl --shutdown`, a reboot). Every `up` checks it and redoes it, so start through `task devcontainer:up`: after a
  WSL restart, a start that bypasses the launcher (VS Code's Reopen in Container, a plain `docker start`) finds no
  `/mnt/wsl/devhost-audio` and the engine may refuse to start the container until the next `task devcontainer:up`. A
  container that was running when the directory was re-made keeps the old, orphaned one: after a restart of WSL run
  `task devcontainer:up` and `task devcontainer:rebuild` once. `task audio:on` says so when it had to make the directory.
- **Needs socat in the default distro** (`task audio:setup` installs it, once per machine; or `sudo apt-get install socat` there), which `audio on` checks and says.
- **Never fails a start.** Unset or `none` (the default) runs nothing, adds nothing and passes `none`. `wslg` where
  it cannot be carried passes `none` with one warning naming why: another host type (`linux`, `macos`), `windows-wslc`
  (not verified: whether `wslc run` can bind a path of the WSL VM is unknown), `HOST_MOUNTS=false`, no `wsl.exe`, a
  default distro without `/mnt/wslg/PulseServer` (WSLg off, WSL1, or the engine's own distro set as the default), or
  a failed directory. An unknown value warns the same way. A repository that mounts `/mnt/wslg` itself keeps its line, as
  with the other host mounts.
- **Rebuild after turning it on.** A mount belongs to the container: `task devcontainer:rebuild`, once, when `DCF_HOST_AUDIO` or
  the launcher version changes. Turning audio on and off afterwards needs no rebuild.
- **See it.** `task devcontainer:host` prints `DCF_HOST_AUDIO : wslg asked for: ...` or why not, and runs nothing;
  `task audio:status` on the workstation and `task audio:check` inside the container (the audio Feature) say whether it is on.
- **Privacy.** While audio is on, every process in the container can open the microphone, as a Windows desktop app can;
  while it is off, none can. Claude Code's `/voice` sends the recorded audio to Anthropic for transcription. Whether dictated
  audio may go to a model provider is the consuming repository's ruling, not the launcher's: the setting is per
  machine and off by default on purpose.
- **Not verified on a real host by the tests** (they mock `wsl.exe`; the relay script itself runs for real in a unit test): the
  call through `wsl.exe` from PowerShell and from a distro's interop, whether WSL keeps the relay alive for the whole duration
  once `wsl.exe` has returned, `socat` in the default distro, Docker Desktop's engine seeing `/mnt/wsl/devhost-audio` (only Rancher Desktop was
  proven by hand), a container seeing a socket made after it started, and the engine's behaviour when the mount source is gone
  after a WSL restart.

## Anti-patterns

### Don't switch off the build lock on an engine without BuildKit build contexts

- **Don't:** set `DEVCONTAINER_BUILD_LOCK=0` to avoid waiting on `wslc`, or on any engine where the launcher says the lock is kept.
- **Why:** without BuildKit build contexts, `@devcontainers/cli` tags every repository's Feature content image `dev_container_feature_content_temp`, so two builds at once overwrite each other and the first fails with `... not found`. The wait itself was unreadable until issue #154 (2026-11-03, "Build lock names its holder and is skipped with BuildKit build contexts (#154)"): an `up` waited behind unrelated no-cache builds with no clue why.
- **Instead:** read the waiting line (it names the holder's repository, subcommand and how many wait); where `buildx` is 0.8.0 or later the launcher skips the lock itself.
- **Caught by:** by design: `DEVCONTAINER_BUILD_LOCK=0` is a documented override, so it is not guarded; `task test:build-lock` covers the lock and its skip.

### Don't run the raw `devcontainer up` right after a rebuild or an engine restart

- **Don't:** call `devcontainer up` directly, or re-run it blindly, while the engine may not answer yet.
- **Why:** 2026-11-02, "Docker ps failures in two stacks traced to the engine, not a race": `devcontainer up` failed with `Command failed: docker ps -q -a ...` and hid the engine's own error.
- **Instead:** go through the launcher (`task dc:up`): it checks the engine first, waits up to `DEVCONTAINER_ENGINE_WAIT` seconds, validates arguments (a nameless `dc:agent` is refused, 2026-11-02, "Engine wait before up and nameless dc:agent refusal") and prints the engine's own error.
- **Caught by:** `task test:engine-wait` (it is wall-clock based and has flaked: entries of 2026-11-02 and 2026-11-03).

### Don't retry a Docker Desktop backend failure as if it were a race

- **Don't:** re-run `task dc:up` when container creation fails with "mount path must be absolute" on a Windows path, or "failed to connect to the backend".
- **Why:** 2026-11-03, "Docker Desktop build error explained: mount path fault, not the repository": the backend was down, not the repository, and the launcher's text said "run the task again".
- **Instead:** restart Docker Desktop (or `wsl --shutdown`), then `task dc:up`.
- **Caught by:** nothing yet (open item `launcher-docker-backend-message`).

### Don't leave the `DCF_HOST_MACHINE` line out of `devcontainer.json`

- **Don't:** upgrade the launcher and keep a `devcontainer.json` whose `containerEnv` has no `"DCF_HOST_MACHINE": "${localEnv:DCF_HOST_MACHINE}"`.
- **Why:** 2026-10-30, "devcontainer-cli 1.16.2 launcher passes DCF_HOST_MACHINE ...": the container never sees the variable, so the `agents` session names show `container` for `{machine}`. (The same kind of gap: the root Taskfile include for `cloud-folder:login`, 2026-10-29, "cloud-folder:login built as one command ...".)
- **Instead:** copy the line from the bootstrap's `devcontainer.json`; the launcher warns and prints the exact line when it is missing, and the Feature's CHANGELOG names a consumer action when a release needs one.
- **Caught by:** the launcher's warning, tested in `task test:bootstrap` and its PowerShell twin.

## Why this one exists

The Dev Container CLI is published by the Dev Containers project as an npm
package, and its documented install is `npm install -g @devcontainers/cli`,
which needs a Node.js on PATH. This repository knows of no published Dev
Container Feature that installs it, so there is none to compare. This Feature
exists so that a container can run the CLI without a system-wide Node.js, and
so the same script serves the container and the host-side tasks.

## Changes

### [1.22.0] - 2026-11-06

#### Added

- **The microphone is gated on the workstation (both launchers)**: with `DCF_HOST_AUDIO=wslg`, `up` no longer binds WSLg's own `/mnt/wslg` and mounts it in the container (1.21.0, always on) but makes an empty relay directory `/mnt/wsl/devhost-audio` in the default WSL distro and mounts that at `/mnt/wslg`. The real socket is never mounted and the microphone is OFF until you turn it on: `task audio:on` (the new `audio.yml`, vendored by the bootstrap; include it in the root Taskfile as the bootstrap's `Taskfile.yml` shows) starts a socat relay in the default distro for `TTL=<duration>` (`90s`, `15m`, `2h`; default `DCF_HOST_AUDIO_TTL` or 15 minutes; at most `DCF_HOST_AUDIO_TTL_MAX`, default 2 hours, longer is cut to it), `task audio:off` ends it at once, `task audio:status` says whether it is on and the time left. When the relay ends, the socket file is gone and the container sees none. The switch lives outside the container, so no process in it can undo it, and turning it on or off needs no rebuild. New launcher subcommand `audio on|off|status`. It needs socat in the default distro.
- `task devcontainer:host` describes the relay directory.
- `task audio:setup` (optional, once per machine) installs socat in the default WSL distro with apt-get, or says it is already there; `audio on` names it when socat is missing.

#### Changed

- **Act:** if you use `DCF_HOST_AUDIO=wslg`, re-run the bootstrap (it vendors `audio.yml`), add the `audio` include to the root Taskfile (the `Taskfile.yml` of a new bootstrap has it), install socat in the default WSL distro, run `task devcontainer:up` and `task devcontainer:rebuild` once (the mount source changed), then `task audio:on` whenever you dictate. Unset or `none` still changes nothing. The audio Feature 1.1.0 is the container side.

### [1.21.0] - 2026-11-06

#### Added

- **Audio on request (both launchers)**: `DCF_HOST_AUDIO=wslg` in a Windows WSL2 workstation's `.devcontainer/.env` gives the container its microphone through WSLg's PulseAudio socket, for the new `audio` Feature (Claude Code's `/voice`). Before `up`, on the `windows-docker` and `windows-wsl-docker` host types, the launcher binds the default WSL distro's `/mnt/wslg` to `/mnt/wsl/wslg` as root (skipped when already there; a WSL restart drops it and the next `up` redoes it), mounts it at `/mnt/wslg`, and sets `DCF_HOST_AUDIO=wslg` for `containerEnv`; anywhere else, or when that distro has no WSLg socket, it warns once and starts the container without audio (`DCF_HOST_AUDIO=none`). `task devcontainer:host` says what it would do. Unset or `none` (the default) runs nothing and adds nothing: nothing changes unless you opt in. It gives every process in the container the microphone; whether dictated audio may go to a model provider is your repository's ruling. To use it: re-vendor the bootstrap, add `"DCF_HOST_AUDIO": "${localEnv:DCF_HOST_AUDIO}"` to `containerEnv` (the bootstrap's template has it), add the `audio` Feature once it is released, set the variable and run `task devcontainer:rebuild`.

### [1.20.0] - 2026-11-05

#### Added

- **The OpenBao key file (Windows launcher)**: with the openbao Feature 1.5.0 or later set to `unlock: keyfile`, every `task dc:up` (so `start`, `shell`, `exec`, `agent`, `claude`, `rebuild`) unseals OpenBao and logs you in with nothing typed, from a DPAPI-protected key file in `%LOCALAPPDATA%\devcontainer-features-keys\openbao\` (it also opens with a domain's DPAPI backup key). It is streamed into the container on stdin through the engine's `exec`, never as an argument, an environment variable or a file. New tasks: `dc:openbao:unlock`, `dc:openbao:keyfile:create`, `:rotate`, `:export`, `:import`, `:forget`; `create` and `rotate` take two steps (OpenBao's rekey verification): the key file is saved first, then confirmed with its own shares 4 and 5, and only then are the three custody shares printed; a failed save or confirm cancels the rotation (with its own nonce; another rotation is never cancelled) and keeps the old shares and key file; a lost confirm answer is settled by `keyfile status`'s pending verification nonce; the nonce carries a confirm token, so it is never printed or logged; the container's warnings are shown. The four that handle shares or the file refuse inside an agent's job (`CLAUDECODE`, `DEVHOST_JOB_CHILD`, `OPENBAO_AGENT_JOB_VARS`). Nothing changes for a repository whose openbao Feature is not in keyfile mode (one silent status call after `up`). To use it: re-vendor the bootstrap, set `unlock: keyfile`, rebuild, then run `task dc:openbao:keyfile:create` once in a plain terminal and store the three custody shares it prints.
- The bash launcher (Linux, macOS, a WSL distro) refuses those tasks in one line: the OpenBao key file is Windows-only for now.

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/devcontainer-cli/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/devcontainer-cli/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
