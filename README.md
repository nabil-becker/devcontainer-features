# devcontainer-features

Reusable [Dev Container Features](https://containers.dev/implementors/features/),
a host-side Taskfile for driving the devcontainer CLI from Windows without
installing Node.js, and a one-line bootstrap that wires both into any repo.

## Features

| Feature | What it installs |
| --- | --- |
| [`go-task`](src/go-task) | [Task](https://taskfile.dev) (`task`), sha256-verified from GitHub releases, with bash/zsh completions. |
| [`devcontainer-cli`](src/devcontainer-cli) | `@devcontainers/cli` as `devcontainer`, on a private Node.js under `/opt/devcontainer-cli` that is never put on PATH. |
| [`claude-code`](src/claude-code) | [Claude Code](https://code.claude.com/docs): the native release binary (no Node.js, version pinnable) unless a `claude` is already there (the official Anthropic Feature), plus `agent-adapter-claude` (Claude Code's adapter for the `agents` Feature) and the state (`CLAUDE_CONFIG_DIR`) in a volume it owns; the `claude-host` launcher, `claude-host-pin` hook and `claude-fleet` still work in 1.7.0 but are deprecated (claude-code 2.0 removes them). |
| [`agents`](src/agents) | One list of a repository's agents (`.devcontainer/agents.yml`: name, CLI, folder, args, kind) and one verb for every agent CLI: `task agents -- <name>` makes a `resident` agent run in the background and attaches, or opens a new session of an `on-demand` one; `agents:up` starts the residents with the container; each CLI Feature supplies the adapter. |
| [`git`](src/git) | git augmented for the container: a worktree-aware wrapper that scopes `GIT_DIR` to the checkout and maps a `.git` pointer under the host's `.git-dirs` onto one shared mount, `safe.directory` and `core.hooksPath` at post-create, the global config in a volume it owns. |
| [`gh`](src/gh) | [GitHub CLI](https://cli.github.com) from GitHub releases, checksum-verified, unless the official Feature installed it; its login (`GH_CONFIG_DIR`) in a volume it owns, git's GitHub credentials taken from it. |
| [`ssh-agent`](src/ssh-agent) | `SSH_AUTH_SOCK` at a fixed path in every process, so git commits can be signed with an SSH key: the launcher mounts the host's agent socket (linux, macOS, a WSL distro), the private key never entering the container; the Windows engines get a plain explanation and an opt-in, temporary key mode; `ssh-agent:*` tasks for keys, dedicated-key warnings, rotation and retirement (`key:rotate`, `key:retire`, `key:age`) and git signing setup. |
| [`cloud-folder`](src/cloud-folder) | One fixed path (`/mnt/cloud-folder`, the `mountPoint` option) for a shared document folder that must never go in git (SharePoint, OneDrive), filled by host mode (the launcher bind-mounting the host folder a sync client keeps, `DCF_HOST_CLOUD_FOLDER`, at `/mnt/cloud-folder-host`, linked from `mountPoint`), sync mode (rclone, pinned and verified, running `bisync` with the remote on a timer and on demand, the sign-in in the Feature's volume; nothing privileged, so it works on a cluster) or mount mode (`rclone mount` with a VFS cache in the volume, where the launcher granted FUSE on request, `DCF_HOST_FUSE=1`); `cloud-folder:status` fails when the folder is missing, unwritable, never synced, its last sync failed or uploads failed, so a start-up check can stop, and `cloud-folder:shutdown-check` refuses a stop while a sync runs, local changes wait or uploads are pending. |
| [`az`](src/az) | Augments the official `azure-cli` Feature: its login (`AZURE_CONFIG_DIR`) in a volume it owns, `az bicep` using the Bicep on PATH. |
| [`kube-state`](src/kube-state) | Owns the kubeconfig (`KUBECONFIG`) the Kubernetes tools share, in a volume it owns, so velero and kubectl stop needing a hand-mounted `~/.kube`; installs no binary. |
| [`phi-check`](src/phi-check) | A linter-style command that refuses files holding PHI (US SSNs, Medicare Beneficiary Identifiers, X12, HL7 v2, FHIR Patient data, and a record id or date of birth next to a diagnosis or a name label): `phi-check <path>...`, never printing the matched text, failing closed on binary and missing files, knowing nothing of git (the repository wires it into a hook or CI); the patterns are one importable module for other guards. Python 3 standard library only, nothing downloaded; Python comes through `dependsOn`. |
| [`common`](src/common) | The shared scripts: `dcf-persist`, behind every Feature's setup script (make a state directory usable and say what backs it), for a repo's own scripts too; and `dcf-curl`, which every installer's downloads go through so a TLS reset or a cut connection is retried. |
| [`coder-cli`](src/coder-cli) | [Coder](https://coder.com) CLI from GitHub releases, verified against the release checksums. |
| [`openbao`](src/openbao) | [OpenBao](https://openbao.org) CLI (`bao`), verified against the release checksums. |
| [`velero`](src/velero) | [Velero](https://velero.io) CLI, verified against the release `CHECKSUM`. |
| [`kustomize`](src/kustomize) | Standalone [kustomize](https://kustomize.io), verified against the release checksums. |
| [`kubeconform`](src/kubeconform) | [kubeconform](https://github.com/yannh/kubeconform) manifest validator, verified against the release `CHECKSUMS`. |
| [`argocd`](src/argocd) | [Argo CD](https://argo-cd.readthedocs.io) CLI, verified against the release `cli_checksums.txt`. |
| [`dsc`](src/dsc) | [Microsoft DSC v3](https://github.com/PowerShell/DSC) in `/opt/dsc`, verified against the GitHub-published asset digest (or a pinned `sha256`). |

Every Feature that installs a tool takes a `version` option (`latest` or a
pinned release) and verifies what it downloads before installing it, with one
exception: `devcontainer-cli` verifies its private Node.js but not the npm
package of the CLI itself (see its notes).

### This repository's own devhost

The `devhost` Feature (the way of working: backs, ledger, briefing, verify guards) is local-only. It is
not part of the published collection and is no longer released; it lives in
[`local-features/devhost`](local-features/devhost), and `task features:stage` stages it with the
Features from `src/` into this repository's own devcontainer. The registry keeps its last published
version, frozen. Its Docker tests run with `task test:devhost:docker`.

## How the pieces fit

The collection is an ecosystem, not a bag of installers. Every repo that
uses it gets the same shape, and anything a repo has to script around is a
gap to close here (see [Contributing from a consuming repo](#contributing-from-a-consuming-repo)).

- **Task is the API, on both sides of the container wall.** On the host,
  `task devcontainer:*` (vendored include, alias `dc:`) builds, starts, enters
  and talks to the container; inside, every Feature contributes `<id>:*`
  tasks through the go-task registry. Documents and skills name tasks, never
  the scripts behind them.
- **Augment, don't duplicate.** When an official Feature exists for a tool
  (Anthropic's `claude-code`, `devcontainers/features/git`), this collection's
  Feature of the same id orders itself after it (`installsAfter`) and adds
  what the ecosystem needs around it: a start command, a setup script, a
  Taskfile. It installs the tool itself only when nothing else did, and then
  verified and pinnable. Wrappers are opt-in and generic (no repo paths).
- **The checkout is the only thing on disk; each Feature owns its state.**
  Everything that is not the repo is either persistent somewhere a Feature
  manages, or ephemeral inside the container. A Feature that has state
  (logins, transcripts, tool config) declares the variable that points at it
  and a named volume on `/var/lib/devcontainer-features/<id>`, like the
  official docker-in-docker Feature does, and its setup script makes the
  directory usable by the remote user (`dcf-persist`, from `common`).
  Nothing to configure. A repo that wants that state on the host disk
  (survives container-engine resets, follows the machine) bind-mounts the
  same target, its mount wins, and `task devcontainer:homes` as
  `initializeCommand` guarantees the host folder exists. Examples spell the
  host path with `${localEnv:USERPROFILE}` (Windows); on Linux/macOS use
  `${localEnv:HOME}`, or `${localEnv:DCF_HOST_HOME}` (set by the launcher on every host type,
  see "Host type" in the devcontainer-cli notes) for the same line everywhere (empty when VS Code
  starts the container without the launcher: use `${localEnv:USERPROFILE}` or `${localEnv:HOME}` there). Never
  concatenate the two: both can be set on Windows. Caches and
  worktrees stay out of the checkout too (`PYTHONPYCACHEPREFIX`, a volume
  over `.claude/worktrees`), or a synced checkout carries every build
  artefact.
- **One list of agents, one verb.** A repository names its agents in
  `.devcontainer/agents.yml` (the `agents` Feature): a name, a CLI, a folder,
  extra args and a kind. `task agents -- <name>` inside, `task
  devcontainer:agent -- <name>` from the host, does the right thing for the
  kind: a `resident` agent is made to run in the background and attached, an
  `on-demand` one opens a new session (`--resume` for its latest). Each CLI
  Feature supplies an adapter (`agent-adapter-claude` from `claude-code`); the
  adapter finds a session by its name and folder and acts on it by id, so no
  session id is pinned anywhere and nothing starts a second copy of a running
  agent. `claude-host`, `claude-fleet`, `HOST_SESSION` and `SESSIONS` are
  deprecated and go with claude-code 2.0.
- **Settings are plain variables, three ways.** Command-line var, then the
  `.env` files, then the exported environment, with the same names in the
  tasks, the PowerShell scripts and their bash twins.
- **Windows only bootstraps and launches; the work happens inside.** The
  host needs PowerShell 7, Task and a Docker-compatible engine (`docker` or
  `wslc`), nothing else: Node.js and the devcontainer CLI are cached per
  user, and every tool a project needs is a Feature. Sessions, tests and
  builds run in the container. Linux/macOS get a bash twin of every
  host-side script.

### Feature Taskfiles

Each Feature also ships a Taskfile for its tool (`dsc:get`, `velero:backups`,
`kustomize:build:all`, `argocd:sync`, ...). With the default
`installTaskfile: true` it is registered at build time under
`/usr/local/share/go-task/includes.d/`, and the `go-task` Feature keeps
`/usr/local/share/go-task/features.yml` including all of them. One include in
the root Taskfile, never edited again:

```yaml
includes:
  features:
    taskfile: /usr/local/share/go-task/features.yml
    optional: true
    flatten: true
```

Add a Feature and rebuild: its tasks appear. Remove it: they disappear.
`bootstrap/bootstrap.ps1` / `bootstrap.sh` write that include into the starter
`Taskfile.yml`.

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/devcontainer-cli:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/git:1": { "hooksPath": ".githooks" },
  "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/kustomize:1": { "version": "5.8.3" }
}
```

Not in this collection on purpose: the GitHub Copilot CLI (now an official
`ghcr.io/devcontainers/features/copilot-cli`), code-server (Coder publishes
`ghcr.io/coder/devcontainer-features/code-server`), and shellcheck/yamllint
(`ghcr.io/devcontainers-extra/features/*`).

To try an unpublished change, reference the Feature folder locally
(`"./features/<id>": {}`); the CLI only accepts local Features that live
under the `.devcontainer/` folder, so copy or link it there.

## Bootstrap a repo

Windows is the primary host (PowerShell 7 + Task + Docker Desktop or
`wslc.exe`); Linux and macOS are supported through a bash twin of every
host-side script. From the repo root:

```powershell
# Windows
irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap/bootstrap.ps1 | iex
```

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap/bootstrap.sh | bash
```

[`bootstrap/bootstrap.ps1`](bootstrap/bootstrap.ps1) / [`bootstrap/bootstrap.sh`](bootstrap/bootstrap.sh):

1. vendor `bootstrap/devcontainer.yml`, `bootstrap/host/*` (the PowerShell
   flavour and the bash twins) and the `devcontainer-cli` Feature's
   `devcontainer-cli.sh` into the repo's `.devcontainer/cli_bootstrap.ignore/`
   folder (`BOOTSTRAP_DIR` changes it; the script prints the folder it used) -
   always refreshed, so re-running is the update path - and git-ignore that
   folder (see below);
2. write `Taskfile.yml` (includes the vendored `devcontainer.yml` under
   `devcontainer:` with the alias `dc:` and `optional: true`), `.devcontainer/devcontainer.json` (go-task,
   devcontainer-cli, git, docker-outside-of-docker, PowerShell) and
   `.devcontainer/.env.example` from [`bootstrap/`](bootstrap), plus a
   starter `.devcontainer/shutdown-check.sh` (the repository's
   [shutdown check](bootstrap/SHUTDOWN.md)) - only if they do not exist yet -
   and gitignore `.devcontainer/.env`; when `Taskfile.yml` already exists it
   prints the `shutdown:check` task to add;
3. run `task devcontainer:init` (caches the portable Node.js + CLI, reports
   the engine) and `task devcontainer:up`.

That breaks the circular dependency: the repo never needs a checkout of this
one, and from then on every devcontainer operation goes through
`task devcontainer:*` (or `task dc:*`).

### Where the bootstrap lives, and git

The vendored files are the launcher, not the repository's own code, so they
are not committed: the default folder is `.devcontainer/cli_bootstrap.ignore/`
and the bootstrap git-ignores it by creating `.devcontainer/.gitignore` or
appending `cli_bootstrap.ignore/` to it (only when that line is absent; other
lines are never touched, so re-running is safe).

- `BOOTSTRAP_DIR` (`-BootstrapDir` / `--bootstrap-dir`) picks another folder.
  It must be **relative to the repository root and inside it**: an absolute
  path or one with `..` is refused with a message. The root `Taskfile.yml` the
  bootstrap writes includes `./<folder>/devcontainer.yml`; for an existing
  Taskfile, change the include to the folder the script printed. The host
  scripts are found next to the vendored `devcontainer.yml`, so any folder works.
- Outside `.devcontainer/` the ignore line (`/<folder>/`) goes into the
  **root** `.gitignore`, and the script says so.
- `BOOTSTRAP_GITIGNORE=false` (`-NoGitignore` / `--no-gitignore`) skips the
  git-ignore step, for a repository that commits the vendored folder.
- **A fresh clone has no vendored folder** (it is ignored), so the include in
  `Taskfile.yml` is `optional: true`: `task` still runs, minus `devcontainer:*`.
  The first step on a new machine is the bootstrap one-liner above, which
  restores the folder and brings the devcontainer up.
- `DEVCONTAINER_BOOTSTRAP_SOURCE` (`--source` / `-Source`) accepts a local
  checkout of this repository, so the bootstrap can run offline (the tests do).

**Migrating a repository that vendored into `./bootstrap/`.** Nothing breaks if
it does not re-run the bootstrap: `taskfile: ./bootstrap/devcontainer.yml` keeps
working as it was. To move, re-run the bootstrap (without `BOOTSTRAP_DIR`). It
vendors into `.devcontainer/cli_bootstrap.ignore/`, git-ignores it, prints a
migration note, and, when the root `Taskfile.yml` has an include that is
exactly `taskfile: ./bootstrap/devcontainer.yml`, rewrites only that value to
`./.devcontainer/cli_bootstrap.ignore/devcontainer.yml` (to undo, change it
back; nothing else in the file is touched). Then, by hand: add `optional: true`
to that include, and delete the old folder once the include points at the new one:

```text
taskfile: ./.devcontainer/cli_bootstrap.ignore/devcontainer.yml
optional: true
git rm -r bootstrap
```

The bootstrap never deletes `./bootstrap/`.

### Settings: CLI, `.env`, or environment

Every setting of the bootstrap and of the tasks can be given three ways. The
bootstrap scripts resolve explicit parameter, then environment variable, then
`.env` file (`./.env` or `./.devcontainer/.env`). The tasks resolve as Task
does: a var on the command line (`task dc:up DEVCONTAINER_DOCKER_PATH=docker`),
then the `.env` files (loaded by `dotenv:` in the generated Taskfile), then
the exported environment. That is how a piped `irm | iex` or `curl | bash`
run is configured:

| Setting | Env var | Parameter |
| --- | --- | --- |
| Docker-compatible CLI for `--docker-path` (`docker`, `wslc`, `podman`, `nerdctl`, `finch`, or a path). Unset: the engine of the host type (`docker`, or `wslc.exe` for `windows-wslc`). Always wins over the host type. | `DEVCONTAINER_DOCKER_PATH` | `-DockerPath` / `--docker-path` |
| Kind of host: `auto` (default) or `windows-docker`, `windows-wsl-docker`, `windows-wslc`, `linux`, `macos`; an id skips detection. The launcher sets `DCF_HOST_TYPE`, `DCF_HOST_HOME`, `DCF_HOST_SSH_AGENT` from it (`task devcontainer:host` shows them). | `HOST_TYPE` | `HOST_TYPE=` var |
| Ordered, comma-separated host types `auto` tries (default per OS: Windows `windows-docker,windows-wsl-docker,windows-wslc`, inside WSL `windows-wsl-docker`, `linux`, `macos`) | `HOST_TYPE_PRIORITY` | `HOST_TYPE_PRIORITY=` var |
| `false` (or `0`, `no`): the launcher adds no host mounts to `up`. By default it adds the host home's `.git-dirs` at `/git-dirs` and, where the host type has one, the SSH agent socket at the `ssh-agent` Feature's fixed path (each skipped when the repository's `devcontainer.json` already mounts that target), so a repository declares no mount line; `task devcontainer:host` lists them. | `HOST_MOUNTS` | `HOST_MOUNTS=` var |
| `key`: opt into a signing key kept in the container (the `ssh-agent` Feature's key mode, which breaks "the private key never enters the container" for you): `DCF_HOST_SSH_AGENT=key` and no agent socket mounted. Unset: the host type decides (socket on linux, macos, a WSL distro; none on the Windows engines). | `SSH_AGENT_MODE` | `SSH_AGENT_MODE=` var |
| A host folder a sync client keeps (SharePoint, OneDrive) that `up` bind-mounts at `/mnt/cloud-folder-host`, where the `cloud-folder` Feature's `mountPoint` links; passed on unchanged for `containerEnv`. Never created: a path missing on this host is skipped with a warning. Unset: no folder. | `DCF_HOST_CLOUD_FOLDER` | `DCF_HOST_CLOUD_FOLDER=` var |
| `1`: grant FUSE on this machine for the `cloud-folder` Feature's `mount` mode: `up` sets `DCF_HOST_FUSE_DEVICE`, `DCF_HOST_FUSE_CAP` and `DCF_HOST_FUSE_SECURITY` (`--device=/dev/fuse`, `--cap-add=SYS_ADMIN`, `--security-opt=apparmor=unconfined`), which the repository's `runArgs` read (the bootstrap's template has the lines). Unset: no grant, never by default. Rebuild after a change. | `DCF_HOST_FUSE` | `DCF_HOST_FUSE=` var / `-Fuse` |
| Portable Node.js version | `DEVCONTAINER_NODE_VERSION` | - |
| `@devcontainers/cli` version (default `latest`) | `DEVCONTAINER_CLI_VERSION` | - |
| Root of the host-side tool-state folders (`devcontainer:homes`; default `~/.devcontainer-homes`) | `DEVCONTAINER_HOMES` | - |
| UUID of the Claude Code session `devcontainer:claude` resumes (`HOST_SESSION_<DIR>` per sub-folder) | `HOST_SESSION` | `SESSION=` var |
| Git ref to vendor from (default `main`) | `DEVCONTAINER_BOOTSTRAP_REF` | `-Ref` / `--ref` |
| Source URL base or local checkout | `DEVCONTAINER_BOOTSTRAP_SOURCE` | `-Source` / `--source` |
| Repo root (default cwd) | `DEVCONTAINER_BOOTSTRAP_PATH` | `-Path` / `--path` |
| Stop before `up` | `DEVCONTAINER_BOOTSTRAP_NO_UP=true` | `-NoUp` / `--no-up` |
| Folder to vendor into, repo-relative (default `.devcontainer/cli_bootstrap.ignore`) | `BOOTSTRAP_DIR` | `-BootstrapDir` / `--bootstrap-dir` |
| Git-ignore that folder (default yes; `false` skips) | `BOOTSTRAP_GITIGNORE` | `-NoGitignore` / `--no-gitignore` |

```powershell
$env:DEVCONTAINER_DOCKER_PATH = 'wslc'; irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap/bootstrap.ps1 | iex
# or with parameters
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap/bootstrap.ps1))) -DockerPath wslc -NoUp
```

See [`bootstrap/env.example`](bootstrap/env.example) for a commented `.env`.

### Feature state: volumes or host disk

Each Feature stores its persistent state (logins, config, transcripts) in a named volume by default. To keep a Feature's state on the host disk instead (survives container-engine resets, stays outside a synced checkout), uncomment and configure the host-disk block in `.devcontainer/devcontainer.json`: it binds the same target path on both the host and inside the container, and the repo's mount wins over the Feature's volume.

## Host-side devcontainer CLI (`bootstrap/devcontainer.yml`)

| Task | Does |
| --- | --- |
| `devcontainer:init` | Cache portable Node.js + `@devcontainers/cli`, report engine. `FORCE=true` reinstalls the CLI. |
| `devcontainer:homes NAME=<slug> -- <dir>...` | Create `~/.devcontainer-homes/<slug>/<dir>` on the host, for a repo that bind-mounts a Feature's state target to the host disk instead of the Feature's volume; meant as `initializeCommand` (array form: `["task", "devcontainer:homes", "NAME=myrepo", "--", "claude-code"]`). Also creates `~/.git-dirs` (`%USERPROFILE%\.git-dirs`), the source of the git Feature's one `.git-dirs` mount, when missing. Optional `HOST_GIT_DIR=<path>` also checks that a git dir kept outside the checkout has a HEAD. |
| `devcontainer:stop` / `prepshutdown` | Stop the container after its [shutdown check](bootstrap/SHUTDOWN.md) (`FORCE=1` skips it; `rebuild` stops first the same way and rebuilds nothing when the stop is refused); `prepshutdown` runs the same check inside the running container and stops nothing. The check is `STOP_CHECK` if set, else the repository's `task shutdown:check`, else `devhost-shutdown-check`, else none. |
| `devcontainer:up` / `rebuild` / `build` | `devcontainer up` (extra flags after `--`), from-scratch rebuild, image build only. `up` and `rebuild` add the host mounts of the host type (`--mount`: the home's `.git-dirs` at `/git-dirs` and the SSH agent socket, each skipped when `devcontainer.json` already mounts it; `HOST_MOUNTS=false` turns them off); `build` and `exec` add none. |
| `devcontainer:ssh-add [-- <args>]` | Run the host's `ssh-add` once (no arguments: `-l`) to load a key into the host agent that the `ssh-agent` Feature's socket mode forwards (linux, macos, windows-wsl-docker); on Windows it says the container cannot reach that agent and points to `ssh-key-import`. Host only. |
| `devcontainer:ssh-key-import FILE=<host path>` | Opt-in key mode: stream a private key file of the host (and its `.pub`) into the running container's `ssh-agent` key volume through `devcontainer exec` on stdin (never an argument), mode 0600, then load it; prints the fingerprint, never the key; warns (never blocks) when FILE has a default name or its public key also opens this host. Refuses when FILE is missing, no container runs, or key mode is off there. Host only. |
| `devcontainer:host` | Print the host profile (`HOST_TYPE` and why, engine, `DCF_HOST_*`) and the host mounts `up` would add or skip; starts nothing. |
| `devcontainer:exec CMD='...'` / `shell` / `pwsh` | Run a command (base64-safe), an interactive bash, or PowerShell in the container. |
| `devcontainer:agent [AGENTS_FILE=<path>] -- <name> [--resume\|--new] [<CLI args>]` | Start an agent of the repository's agent list inside (needs the `agents` Feature and the adapter of the agent's CLI): a `resident` runs in the background and is attached, an `on-demand` agent opens a new session in this terminal. Runs directly when already inside the container. |
| `devcontainer:agent:list [-- --json]` | The agents with their kind, CLI, state and session id. |
| `devcontainer:claude [DIR=<sub-folder>] [SESSION=<uuid>] [-- <claude args>]` | Deprecated (prints one line; goes with claude-code 2.0): use `devcontainer:agent`. Start or resume the Claude Code host session inside (needs the `claude-code` Feature): `HOST_SESSION` from `.devcontainer/.env`, `HOST_SESSION_<DIR>` for a sub-folder. Runs directly when already inside the container. |
| `devcontainer:claude:fleet [-- --plan\|--no-view\|--no-wait\|--stop-duplicates]` | Deprecated (prints one line; goes with claude-code 2.0): list the agents in `agents.yml` instead. Several Claude Code sessions in one terminal (`claude-fleet` from the `claude-code` Feature): `SESSIONS` (include `vars:`; one line per session, `name\|session-variable\|dir\|extra claude args`) is read against `claude agents --json`; a session counts as running when its id (from `.devcontainer/.env`, then the container's environment) or its folder is live, the missing ones start in the background with `claude-host --bg` in their folder, then `claude agents` opens. It first waits for sessions restored after a rebuild to settle (`-- --no-wait` skips that); several live sessions for one agent are reported, and `-- --stop-duplicates` stops the extras with `claude stop` (never rm). `-- --plan` prints what it would do and starts nothing; `-- --no-view` skips the view. |
| `devcontainer:config` | Resolved configuration. |
| `devcontainer:<anything>` | Passthrough to that CLI subcommand, args after `--`. |
| `devcontainer:reset-storage` | wslc.exe only: reset WSL Containers' storage after a read-only BuildKit error. |

**For a consuming repository (devcontainer-cli 1.8.0, git 1.4.3):** once you start through these tasks, delete the
`source=${localEnv:USERPROFILE}/.git-dirs,target=/git-dirs,type=bind` line from your `devcontainer.json`: `up` and
`rebuild` mount it for you on every host type. Keeping it is harmless, the launcher sees the target and skips its own
(one line says so). Keep it only if you also open the folder straight in VS Code (Reopen in Container), which
skips the launcher; there use `${localEnv:USERPROFILE}` (Windows host) or `${localEnv:HOME}`, never `DCF_HOST_HOME`,
which is empty without the launcher. Re-run the bootstrap to refresh the vendored launcher.

**SSH commit signing from `devcontainer exec` and `claude` sessions (`ssh-agent` 1.1.0, devcontainer-cli 1.10.0):** add
`ghcr.io/nabil-becker/devcontainer-features/ssh-agent:1` to the `features` and map the host variables with
`containerEnv` (the bootstrap's template does: `"DCF_HOST_TYPE": "${localEnv:DCF_HOST_TYPE}"`, `"DCF_HOST_SSH_AGENT":
"${localEnv:DCF_HOST_SSH_AGENT}"`). On linux, macos and windows-wsl-docker (launcher inside the distro) nothing else:
the launcher mounts the host's agent socket, the key never enters the container; start the host agent first and add
the key with `task dc:ssh-add -- <key>`. On the Windows engines (windows-docker, windows-wslc) the Windows agent is a
named pipe and no process of ours runs on the host, so there is none: use a VS Code terminal (its own forwarding), or
opt into the temporary key mode (`SSH_AGENT_MODE=key` at `task dc:up`, or the Feature's `keyMode: true`), which keeps a
signing key in the container's volume and so breaks "the key never enters the container" for you: load it with
`task dc:ssh-key-import FILE=<key>` (a dedicated key, one per container, registered at GitHub as a signing key only;
`task ssh-agent:key:new` makes one inside the container). Then `task ssh-agent:git:signing` and `task ssh-agent:git:verify`;
`task ssh-agent:key:rotate` replaces the key in four steps and `key:retire` / `key:age` retire it and show its age.

**A shared document folder outside git (`cloud-folder` 1.0.0, devcontainer-cli 1.12.0):** add
`ghcr.io/nabil-becker/devcontainer-features/cloud-folder:1` to the `features`, map `"DCF_HOST_CLOUD_FOLDER":
"${localEnv:DCF_HOST_CLOUD_FOLDER}"` with `containerEnv` (the bootstrap's template does), and set
`DCF_HOST_CLOUD_FOLDER=<the synced folder on this host>` in `.devcontainer/.env`. `up` then mounts it at
`/mnt/cloud-folder-host`, and the Feature's `mountPoint` (default `/mnt/cloud-folder`) links there: the path in the
container is named once, in that option. Drop a hand-written bind mount of the folder from `devcontainer.json`. Put
`task cloud-folder:status` in your start-up check: it fails when the folder is missing or unwritable.
Where there is no host folder (a cluster), `cloud-folder` 1.1.0 syncs it with rclone instead: set `siteUrl` and
`remotePath`, run `task cloud-folder:login` once, and a timer keeps the folder in sync; add
`cloud-folder-setup shutdown-check` to your `shutdown:check` so a stop waits for a running sync (see the Feature's
NOTES). `cloud-folder` 1.2.0 with devcontainer-cli 1.15.0 adds `mount` mode (`rclone mount`, a live view): set
`DCF_HOST_FUSE=1` in `.devcontainer/.env` on the machines that should have it, keep the three `runArgs` lines of the
bootstrap's template, and rebuild; `auto` then takes host, else mount, else sync.

**One verb for every agent (`agents` 1.0.0, claude-code 1.7.0, devcontainer-cli 1.13.0):** add
`ghcr.io/nabil-becker/devcontainer-features/agents:1` to the `features`, write `.devcontainer/agents.yml` (one entry per
agent: `name`, `cli`, `kind` resident or on-demand, `folder`, `args`) and start them with `task devcontainer:agent --
<name>` (inside: `task agents -- <name>`). That replaces `devcontainer:claude`, `devcontainer:claude:fleet` with
`SESSIONS`, the `HOST_SESSION...` pins in `.devcontainer/.env`, the `claude-host-pin` hook and any join script of your
own; they keep working, with a deprecation line, until claude-code 2.0. Step by step:
[docs/migrations/agents.md](docs/migrations/agents.md).

All of them also answer to `dc:` (the include's alias in the generated
Taskfile). Each task dispatches per platform (Task's per-command
`platforms`):

- **Windows** runs `host/Invoke-DevcontainerCli.ps1` (in the bootstrap folder; `bootstrap/host/` in this repository): a pinned
  portable Node.js is downloaded once (sha256-verified) into
  `%LOCALAPPDATA%\devcontainer-features\devcontainer-node`, the CLI is
  npm-installed next to it, nothing lands on PATH. Needs PowerShell 7.
  `homes` runs `Initialize-DevcontainerHomes.ps1`.
- **Linux/macOS** run `devcontainer-cli.sh`, the very script that installs
  the `devcontainer-cli` Feature (vendored as `host/devcontainer-cli.sh` in the bootstrap folder):
  `devcontainer` on PATH if present, else the same portable Node.js trick
  under `~/.cache/devcontainer-features`. Needs bash and curl. `homes` runs
  `devcontainer-homes.sh`.

Builds are serialised host-wide: `up` (and so `rebuild`) and `build` hold the
named mutex `Global\devcontainer-features-build` (Windows) or an `flock` on
`~/.cache/devcontainer-features/build.lock` (Linux/macOS), and a second one
prints `waiting for another devcontainer build to finish...` before it runs.
Without BuildKit build contexts (`wslc`) the devcontainer CLI tags the Feature
content image `dev_container_feature_content_temp` for every repository, so two
builds at once overwrite each other's image and the first fails with
`"/tmp/build-features/<feature>_N": not found`. `exec` and the other
subcommands take no lock; `devcontainer features test` takes it only with
`DEVCONTAINER_BUILD_LOCK_FEATURES_TEST=true` (default false);
`DEVCONTAINER_BUILD_LOCK=0` turns it off.

Both honour the settings above. The include must be a *local* include - the
tasks run the scripts next to the Taskfile, which remote includes cannot
reach. It declares no global `env:` on purpose: with Task 3.45 an `env:` key
in an include claims the name and the `.env` value is discarded for the
whole project (the bug the first consuming repos worked around with a
`dc:*` passthrough; that workaround is no longer needed).

### The shutdown check, for consuming repos

A repository that bootstrapped before this contract re-runs the bootstrap
(it refreshes the vendored tasks and host scripts and, only where absent,
writes `.devcontainer/shutdown-check.sh`), adds the `shutdown:check` task the
bootstrap prints when its `Taskfile.yml` already existed, and drops any
`STOP_CHECK` workaround it set because the default check did not exist there:
with no `shutdown:check` task and no `devhost-shutdown-check`, a stop now
goes ahead with the line `no shutdown check defined; stopping`. A configured
`STOP_CHECK` that is not installed (exit 127) is reported as such.

### Contributing from a consuming repo

A repo that needs something its devcontainer does not provide asks here
first: an [issue](https://github.com/nabil-becker/devcontainer-features/issues)
for a missing Feature, option, task or host script, then a pull request
following [CONTRIBUTING.md](CONTRIBUTING.md). A local workaround in the
consuming repo is a stopgap that names the upstream issue it waits on, and
goes away when the next release ships the functionality. Two things are
not accepted upstream and stay local: anything that embeds the repo's own
paths or names, and anything only one repo has ever wanted.

## Developing

```powershell
task test                    # devcontainer features test, all Features
task test FEATURE=go-task    # one Feature
task test:global             # combined scenario in test/_global
task lint                    # shellcheck, yamllint, PSScriptAnalyzer, Pester, unit tests (what CI runs)
task docs                    # regenerate src/<id>/README.md (commit the result)
```

`devcontainer features test` does not run on a Windows host (the CLI shells
out to `chmod`/bash), so `task test` is gated to Linux/macOS. The easiest
place is this repository's own devcontainer (`.devcontainer/`: docker-in-docker,
shellcheck, PowerShell, and the collection's `go-task` and `devcontainer-cli`
Features); otherwise let CI do it. CI's Lint job runs `task lint` inside that
same toolchain (`.devcontainer/ci/devcontainer.json`, tool versions pinned in
`.devcontainer/devcontainer.json`; see CONTRIBUTING), so both give the same
answer.

Layout follows [devcontainers/feature-starter](https://github.com/devcontainers/feature-starter):
`src/<id>/devcontainer-feature.json` + `install.sh` + `NOTES.md`, with
`README.md` generated from those two by `task docs` and checked by CI, and
`test/<id>/test.sh` + `scenarios.json`.

## Releasing

Run the **Release dev container features** workflow (`workflow_dispatch` on
`main`, `release` environment). It publishes every `src/<id>` to
`ghcr.io/nabil-becker/devcontainer-features/<id>`; it has no write access to
the repository, since READMEs are committed with each change rather than
generated at release time. Bump `version` in the Feature's
`devcontainer-feature.json` before releasing a change.

After the **first** release, GHCR packages are private by default: open each
package's settings on GitHub, change visibility to **Public**, and link it to
this repository. Otherwise consumers (and the containers.dev crawler) cannot
pull it.

## Public registry (containers.dev)

The collection is meant to be listed in the
[containers.dev index](https://containers.dev/collections). Once published,
open a PR against
[`_data/collection-index.yml`](https://github.com/devcontainers/devcontainers.github.io/blob/gh-pages/_data/collection-index.yml)
in `devcontainers/devcontainers.github.io` adding:

```yaml
- name: Dev Container Features by nabil-becker
  maintainer: nabil-becker
  contact: https://github.com/nabil-becker/devcontainer-features/issues
  repository: https://github.com/nabil-becker/devcontainer-features
  ociReference: ghcr.io/nabil-becker/devcontainer-features
```

Listed collections are crawled for liveness and surface in VS Code and
Codespaces, so the repo is run as a public project: see
[CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Governance

- `main` is protected by the `protect-main` ruleset: pull requests only, one
  approval including a code owner, conversations resolved, required checks
  `validate` / `lint` / `tests` / `DCO`, squash merges, no force-push. Repo
  admins may bypass only through a PR.
- Every commit is signed off under the Developer Certificate of Origin;
  `task repo:setup` makes that automatic per clone (see CONTRIBUTING).
- Workflows run with a read-only `GITHUB_TOKEN`; the release job alone gets
  `packages: write`, inside the `release` environment restricted to `main`.
  Actions are SHA-pinned and limited to GitHub-owned ones plus
  `devcontainers/action`; Dependabot bumps them weekly.
- Secret scanning with push protection, Dependabot alerts and private
  vulnerability reporting are on.

All of this is applied by `task repo:govern`
([`.github/scripts/Set-RepoGovernance.ps1`](.github/scripts/Set-RepoGovernance.ps1)),
which is idempotent, so settings drift can be corrected by re-running it.
