# Set up `.devcontainer/`

A one-pager for running the project in a dev container built from this collection's Features
(`ghcr.io/nabil-becker/devcontainer-features`). The agent and the person then work on the same
ground, and the environment is a file in the repository: readable, reviewable, rebuildable.

## Requirements

- A container runtime: `wslc` (Windows) or Docker (Docker Desktop, or an engine on Linux).
- PowerShell 7 (`pwsh`) on Windows. On Linux and macOS a bash twin of every script is used.
- Task (`task`) on the host, which the bootstrap scripts use to drive everything.
- The devcontainer CLI. You do not install it: the bootstrap caches a portable Node.js and the CLI
  per user and installs nothing globally.

## Bootstrap

From the repository root, run the collection's bootstrap. It vendors the host-side tasks into
`bootstrap/`, writes `Taskfile.yml`, `.devcontainer/devcontainer.json` and
`.devcontainer/.env.example` (only if they do not exist yet), gitignores `.devcontainer/.env`, then
runs `task devcontainer:init` and `task devcontainer:up`. Re-running refreshes the vendored files.

```powershell
# Windows
irm https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap/bootstrap.ps1 | iex
```

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap/bootstrap.sh | bash
```

Settings (container engine, versions, bootstrap ref) can be a parameter, an environment variable
or a line in `.devcontainer/.env`; `.devcontainer/.env.example` lists them. Set
`DEVCONTAINER_BOOTSTRAP_NO_UP=true` to stop before the container starts.

## Start

Copy `starter/devcontainer.json` to `.devcontainer/devcontainer.json` (replace the one the
bootstrap wrote, or merge the Features in), then bring it up:

```
task devcontainer:up
task devcontainer:claude
```

`task dc:up` is the same. `up` is idempotent; `task devcontainer:rebuild` recreates the container
from scratch, `task devcontainer:shell` opens a shell inside. `devcontainer:claude` starts or
resumes the Claude Code session inside the container.

The starter sets the agents' commit identity: git run by Claude Code commits as `devhost agent
<devhost-agent@noreply.invalid>`, while your own terminal keeps your identity (ADR 0016).

## More

The Features' README (`github.com/nabil-becker/devcontainer-features`) lists every Feature, its
options and its tasks; each Feature has its own README under `src/<id>`.

## The devhost Feature is frozen

The starter's `devhost:1` pin still resolves, to the last published release. `devhost` is no longer
published from this collection (it is local-only tooling of the collection's own repository), so the
pin is frozen at that release and takes no further fixes.
