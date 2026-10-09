# devcontainer-features

Reusable [Dev Container Features](https://containers.dev/implementors/features/),
a host-side Taskfile for driving the devcontainer CLI from Windows without
installing Node.js, and a one-line bootstrap that wires both into any repo.

## Features

| Feature | What it installs |
| --- | --- |
| [`go-task`](src/go-task) | [Task](https://taskfile.dev) (`task`), sha256-verified from GitHub releases, with bash/zsh completions. |
| [`devcontainer-cli`](src/devcontainer-cli) | `@devcontainers/cli` as `devcontainer`, on a private Node.js under `/opt/devcontainer-cli` that is never put on PATH. |
| [`claude-code`](src/claude-code) | [Claude Code](https://code.claude.com/docs) as its native release binary (no Node.js), auto-updater off, version pinnable. |

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/devcontainer-cli:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {}
}
```

While developing, a local reference works as long as the Feature folder sits
under `.devcontainer/` (the CLI refuses paths that escape it). The
`nabil-becker` workbench folder does this with a directory junction
`.devcontainer/features -> devcontainer-features/src`.

## Bootstrap a repo

Windows is the primary host (PowerShell 7 + Task + Docker Desktop or
`wslc.exe`); Linux and macOS are supported through a bash twin of every
host-side script. From the repo root:

```powershell
# Windows
irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap.ps1 | iex
```

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap.sh | bash
```

[`bootstrap.ps1`](bootstrap.ps1) / [`bootstrap.sh`](bootstrap.sh):

1. vendor `taskfiles/devcontainer.yml` and `taskfiles/devcontainer/*` (both
   flavours) into the repo - always refreshed, so re-running is the update
   path;
2. write `Taskfile.yml`, `.devcontainer/devcontainer.json` (go-task,
   devcontainer-cli, docker-outside-of-docker, PowerShell),
   `.devcontainer/env_mnt/.gitignore` and `.devcontainer/.env.example` from
   [`bootstrap/`](bootstrap) - only if they do not exist yet - and gitignore
   `.devcontainer/.env`;
3. run `task devcontainer:init` (caches the portable Node.js + CLI, reports
   the engine) and `task devcontainer:up`.

That breaks the circular dependency: the repo never needs a checkout of this
one, and from then on every devcontainer operation goes through
`task devcontainer:*`.

### Settings: CLI, environment, or `.env`

Every setting of the bootstrap and of the tasks can be given three ways, in
this precedence: explicit parameter / flag, environment variable, `.env`
file (`./.env` or `./.devcontainer/.env`, loaded by the bootstrap scripts and
by Task's `dotenv:` in the generated Taskfile). That is how a piped
`irm | iex` or `curl | bash` run is configured:

| Setting | Env var | Parameter |
| --- | --- | --- |
| Docker-compatible CLI for `--docker-path` (`docker`, `wslc`, `podman`, `nerdctl`, `finch`, or a path). Unset: `docker` on PATH, else `wslc.exe` on Windows. | `DEVCONTAINER_DOCKER_PATH` | `-DockerPath` / `--docker-path` |
| Portable Node.js version | `DEVCONTAINER_NODE_VERSION` | - |
| `@devcontainers/cli` version (default `latest`) | `DEVCONTAINER_CLI_VERSION` | - |
| Git ref to vendor from (default `main`) | `DEVCONTAINER_BOOTSTRAP_REF` | `-Ref` / `--ref` |
| Source URL base or local checkout | `DEVCONTAINER_BOOTSTRAP_SOURCE` | `-Source` / `--source` |
| Repo root (default cwd) | `DEVCONTAINER_BOOTSTRAP_PATH` | `-Path` / `--path` |
| Stop before `up` | `DEVCONTAINER_BOOTSTRAP_NO_UP=true` | `-NoUp` / `--no-up` |

```powershell
$env:DEVCONTAINER_DOCKER_PATH = 'wslc'; irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap.ps1 | iex
# or with parameters
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap.ps1))) -DockerPath wslc -NoUp
```

See [`bootstrap/env.example`](bootstrap/env.example) for a commented `.env`.

## Host-side devcontainer CLI (`taskfiles/devcontainer.yml`)

| Task | Does |
| --- | --- |
| `devcontainer:init` | Cache portable Node.js + `@devcontainers/cli`, report engine. `FORCE=true` reinstalls the CLI. |
| `devcontainer:up` / `rebuild` / `build` | `devcontainer up` (extra flags after `--`), from-scratch rebuild, image build only. |
| `devcontainer:exec CMD='...'` / `shell` | Run a command (base64-safe) or an interactive bash in the container. |
| `devcontainer:config` | Resolved configuration. |
| `devcontainer:<anything>` | Passthrough to that CLI subcommand, args after `--`. |
| `devcontainer:reset-storage` | wslc.exe only: reset WSL Containers' storage after a read-only BuildKit error. |

Each task dispatches per platform (Task's per-command `platforms`):

- **Windows** runs `Invoke-DevcontainerCli.ps1`: a pinned portable Node.js is
  downloaded once (sha256-verified) into
  `%LOCALAPPDATA%\devcontainer-features\devcontainer-node`, the CLI is
  npm-installed next to it, nothing lands on PATH. Needs PowerShell 7.
- **Linux/macOS** run `devcontainer-cli.sh`: `devcontainer` on PATH if present
  (e.g. from the `devcontainer-cli` Feature), else the same portable Node.js
  trick under `~/.cache/devcontainer-features`. Needs bash and curl.

Both honour the `DEVCONTAINER_*` settings above. The include must be a
*local* include - the tasks run the scripts next to the Taskfile, which
remote includes cannot reach.

## Developing

```powershell
task test                    # devcontainer features test, all Features
task test FEATURE=go-task    # one Feature
task test:global             # combined scenario in test/_global
task lint                    # shellcheck
```

`devcontainer features test` does not run on a Windows host (the CLI shells
out to `chmod`/bash), so `task test` is gated to Linux/macOS: run it inside
the workbench devcontainer (docker-in-docker + the `devcontainer-cli`
Feature) or let CI do it.

Layout follows [devcontainers/feature-starter](https://github.com/devcontainers/feature-starter):
`src/<id>/devcontainer-feature.json` + `install.sh` (+ `NOTES.md`, folded into
the generated README on release), `test/<id>/test.sh` + `scenarios.json`.

## Releasing

Run the **Release dev container features** workflow (`workflow_dispatch` on
`main`, `release` environment). It publishes every `src/<id>` to
`ghcr.io/nabil-becker/devcontainer-features/<id>` and opens a PR regenerating
each Feature's README. Bump `version` in the Feature's
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
- name: Nabil Becker's Dev Container Features
  maintainer: Nabil Becker
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
  `validate` / `lint` / `tests`, squash merges, no force-push. Repo admins may
  bypass only through a PR.
- Workflows run with a read-only `GITHUB_TOKEN`; the release job alone gets
  `packages: write`, inside the `release` environment restricted to `main`.
  Actions are SHA-pinned and limited to GitHub-owned ones plus
  `devcontainers/action`; Dependabot bumps them weekly.
- Secret scanning with push protection, Dependabot alerts and private
  vulnerability reporting are on.

All of this is applied by `task repo:govern`
([`.github/scripts/Set-RepoGovernance.ps1`](.github/scripts/Set-RepoGovernance.ps1)),
which is idempotent, so settings drift can be corrected by re-running it.
