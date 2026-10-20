# devcontainer-features

Reusable [Dev Container Features](https://containers.dev/implementors/features/),
a host-side Taskfile for driving the devcontainer CLI from Windows without
installing Node.js, and a one-line bootstrap that wires both into any repo.

## Features

| Feature | What it installs |
| --- | --- |
| [`go-task`](src/go-task) | [Task](https://taskfile.dev) (`task`), sha256-verified from GitHub releases, with bash/zsh completions. |
| [`devcontainer-cli`](src/devcontainer-cli) | `@devcontainers/cli` as `devcontainer`, on a private Node.js under `/opt/devcontainer-cli` that is never put on PATH. |
| [`claude-code`](src/claude-code) | [Claude Code](https://code.claude.com/docs): the native release binary (no Node.js, version pinnable) unless a `claude` is already there (the official Anthropic Feature), plus the `claude-host` launcher and its state (`CLAUDE_CONFIG_DIR`) in a volume it owns. |
| [`git`](src/git) | git augmented for the container: a worktree-aware wrapper that scopes `GIT_DIR` to the checkout, `safe.directory` and `core.hooksPath` at post-create, the global config in a volume it owns. |
| [`gh`](src/gh) | [GitHub CLI](https://cli.github.com) from GitHub releases, checksum-verified, unless the official Feature installed it; its login (`GH_CONFIG_DIR`) in a volume it owns, git's GitHub credentials taken from it. |
| [`az`](src/az) | Augments the official `azure-cli` Feature: its login (`AZURE_CONFIG_DIR`) in a volume it owns, `az bicep` using the Bicep on PATH. |
| [`kube-state`](src/kube-state) | Owns the kubeconfig (`KUBECONFIG`) the Kubernetes tools share, in a volume it owns, so velero and kubectl stop needing a hand-mounted `~/.kube`; installs no binary. |
| [`devhost`](src/devhost) | The way of working as a Feature: one host Claude Code session per repo, backs that keep the ledger, backlog and docs from Claude Code hooks, the session briefing, cost report, ADR tool, verify guards, and `devhost-init` to scaffold a repo. |
| [`common`](src/common) | The shared helper behind every Feature's post-create hook (`dcf-persist`: make a state directory usable and say what backs it), for a repo's own scripts too. |
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
  what the ecosystem needs around it: a launcher, a post-create hook, a
  Taskfile. It installs the tool itself only when nothing else did, and then
  verified and pinnable. Wrappers are opt-in and generic (no repo paths).
- **The checkout is the only thing on disk; each Feature owns its state.**
  Everything that is not the repo is either persistent somewhere a Feature
  manages, or ephemeral inside the container. A Feature that has state
  (logins, transcripts, tool config) declares the variable that points at it
  and a named volume on `/var/lib/devcontainer-features/<id>`, like the
  official docker-in-docker Feature does, and its post-create hook makes the
  directory usable by the remote user (`dcf-persist`, from `common`).
  Nothing to configure. A repo that wants that state on the host disk
  (survives container-engine resets, follows the machine) bind-mounts the
  same target, its mount wins, and `task devcontainer:homes` as
  `initializeCommand` guarantees the host folder exists. Examples spell the
  host path with `${localEnv:USERPROFILE}` (Windows); on Linux/macOS use
  `${localEnv:HOME}`. Never concatenate the two: both can be set on Windows. Caches and
  worktrees stay out of the checkout too (`PYTHONPYCACHEPREFIX`, a volume
  over `.claude/worktrees`), or a synced checkout carries every build
  artefact.
- **One session per role, found by UUID.** `claude-host` resumes the session
  in `HOST_SESSION` (from `.devcontainer/.env`) wherever it runs;
  `task devcontainer:claude` does it from the host, `task claude-code:host`
  inside, `DIR=<sub-folder>` for a session per sub-folder.
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

## Agentic shared experience (proposal)

Initial work toward a Dev Container Feature providing normalized session-state
storage across agent tools. This is a **draft contract**, not an installable
Feature: there is no storage service, CLI, or integration with existing agents
yet, and no changes to their current session storage.

- [Session schema](schemas/agentic-shared-experience/session.schema.json):
  a versioned envelope with stable session and workspace identifiers, originating
  agent, timestamps, lifecycle status, and a JSON state checkpoint.
- [Example checkpoint](schemas/agentic-shared-experience/session.example.json):
  synthetic data illustrating the proposed format.

The envelope normalizes identity and lifecycle metadata; the `state` payload is
still agent-specific. Adapters may keep namespaced metadata in `extensions`.
Identifiers are opaque values, never paths or executable commands. Consumers
must enable JSON Schema `date-time` format validation and separately enforce
`updatedAt >= createdAt`; JSON Schema alone does not compare timestamps.

Before implementing the Feature, decide the persistence backend, mount location
and ownership (including non-root access and survival across container rebuilds),
atomic writes and concurrent-update handling, supported agent adapters, schema
migrations, and retention/export behavior. Session contents can include sensitive
project data: the intended store should be private, outside version control,
with no credentials stored and no automatic remote upload.

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
   `devcontainer-cli.sh` into the repo's `bootstrap/` folder - always
   refreshed, so re-running is the update path;
2. write `Taskfile.yml` (includes the vendored tasks under `devcontainer:`
   with the alias `dc:`), `.devcontainer/devcontainer.json` (go-task,
   devcontainer-cli, git, docker-outside-of-docker, PowerShell) and
   `.devcontainer/.env.example` from [`bootstrap/`](bootstrap) - only if
   they do not exist yet - and gitignore `.devcontainer/.env`;
3. run `task devcontainer:init` (caches the portable Node.js + CLI, reports
   the engine) and `task devcontainer:up`.

That breaks the circular dependency: the repo never needs a checkout of this
one, and from then on every devcontainer operation goes through
`task devcontainer:*` (or `task dc:*`).

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
| Docker-compatible CLI for `--docker-path` (`docker`, `wslc`, `podman`, `nerdctl`, `finch`, or a path). Unset: `docker` on PATH, else `wslc.exe` on Windows. | `DEVCONTAINER_DOCKER_PATH` | `-DockerPath` / `--docker-path` |
| Portable Node.js version | `DEVCONTAINER_NODE_VERSION` | - |
| `@devcontainers/cli` version (default `latest`) | `DEVCONTAINER_CLI_VERSION` | - |
| Root of the host-side tool-state folders (`devcontainer:homes`; default `~/.devcontainer-homes`) | `DEVCONTAINER_HOMES` | - |
| UUID of the Claude Code session `devcontainer:claude` resumes (`HOST_SESSION_<DIR>` per sub-folder) | `HOST_SESSION` | `SESSION=` var |
| Git ref to vendor from (default `main`) | `DEVCONTAINER_BOOTSTRAP_REF` | `-Ref` / `--ref` |
| Source URL base or local checkout | `DEVCONTAINER_BOOTSTRAP_SOURCE` | `-Source` / `--source` |
| Repo root (default cwd) | `DEVCONTAINER_BOOTSTRAP_PATH` | `-Path` / `--path` |
| Stop before `up` | `DEVCONTAINER_BOOTSTRAP_NO_UP=true` | `-NoUp` / `--no-up` |

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
| `devcontainer:homes NAME=<slug> -- <dir>...` | Create `~/.devcontainer-homes/<slug>/<dir>` on the host, for a repo that bind-mounts a Feature's state target to the host disk instead of the Feature's volume; meant as `initializeCommand` (array form: `["task", "devcontainer:homes", "NAME=myrepo", "--", "claude-code"]`). `HOST_GIT_DIR=<path>` also checks a git dir kept outside the checkout. |
| `devcontainer:up` / `rebuild` / `build` | `devcontainer up` (extra flags after `--`), from-scratch rebuild, image build only. |
| `devcontainer:exec CMD='...'` / `shell` / `pwsh` | Run a command (base64-safe), an interactive bash, or PowerShell in the container. |
| `devcontainer:claude [DIR=<sub-folder>] [SESSION=<uuid>] [-- <claude args>]` | Start or resume the Claude Code host session inside (needs the `claude-code` Feature): `HOST_SESSION` from `.devcontainer/.env`, `HOST_SESSION_<DIR>` for a sub-folder. Runs directly when already inside the container. |
| `devcontainer:config` | Resolved configuration. |
| `devcontainer:<anything>` | Passthrough to that CLI subcommand, args after `--`. |
| `devcontainer:reset-storage` | wslc.exe only: reset WSL Containers' storage after a read-only BuildKit error. |

All of them also answer to `dc:` (the include's alias in the generated
Taskfile). Each task dispatches per platform (Task's per-command
`platforms`):

- **Windows** runs `bootstrap/host/Invoke-DevcontainerCli.ps1`: a pinned
  portable Node.js is downloaded once (sha256-verified) into
  `%LOCALAPPDATA%\devcontainer-features\devcontainer-node`, the CLI is
  npm-installed next to it, nothing lands on PATH. Needs PowerShell 7.
  `homes` runs `Initialize-DevcontainerHomes.ps1`.
- **Linux/macOS** run `devcontainer-cli.sh`, the very script that installs
  the `devcontainer-cli` Feature (vendored as `bootstrap/host/devcontainer-cli.sh`):
  `devcontainer` on PATH if present, else the same portable Node.js trick
  under `~/.cache/devcontainer-features`. Needs bash and curl. `homes` runs
  `devcontainer-homes.sh`.

Both honour the settings above. The include must be a *local* include - the
tasks run the scripts next to the Taskfile, which remote includes cannot
reach. It declares no global `env:` on purpose: with Task 3.45 an `env:` key
in an include claims the name and the `.env` value is discarded for the
whole project (the bug the first consuming repos worked around with a
`dc:*` passthrough; that workaround is no longer needed).

### Contributing from a consuming repo

A repo that needs something its devcontainer does not provide asks here
first: an [issue](https://github.com/nabil-becker/devcontainer-features/issues)
for a missing Feature, option, task or host script, then a pull request
following [CONTRIBUTING.md](CONTRIBUTING.md). A local wrapper in the
consuming repo is a stopgap that names the upstream issue it waits on, and
goes away when the next release ships the functionality. Two things are
not accepted upstream and stay local: anything that embeds the repo's own
paths or names, and anything only one repo has ever wanted.

## Developing

```powershell
task test                    # devcontainer features test, all Features
task test FEATURE=go-task    # one Feature
task test:global             # combined scenario in test/_global
task lint                    # shellcheck + PSScriptAnalyzer
task docs                    # regenerate src/<id>/README.md (commit the result)
```

`devcontainer features test` does not run on a Windows host (the CLI shells
out to `chmod`/bash), so `task test` is gated to Linux/macOS. The easiest
place is this repository's own devcontainer (`.devcontainer/`: docker-in-docker,
shellcheck, PowerShell, and the collection's `go-task` and `devcontainer-cli`
Features); otherwise let CI do it.

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
