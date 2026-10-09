## Why a private Node.js?

`@devcontainers/cli` is an npm package, so it needs Node.js. Installing Node
system-wide would put it on every user's PATH and collide with whatever Node
toolchain the project itself pins. Instead the Feature unpacks a pinned,
checksum-verified nodejs.org build under `/opt/devcontainer-cli/node` and
installs the CLI next to it; only the `/usr/local/bin/devcontainer` wrapper
knows about it. `node` is deliberately *not* on PATH afterwards.

## Which Docker Feature to pair it with

| Host | Use | Why |
| --- | --- | --- |
| Windows / macOS (Docker Desktop) | `docker-in-docker` | `devcontainer features test` and nested `devcontainer up` bind-mount paths from *inside* this container; only a daemon that shares its filesystem can resolve them. |
| Linux (same paths on host and container) | `docker-outside-of-docker` | Lighter, shares the host's image cache; works as long as the workspace is mounted at the same absolute path. |

## Host-side counterpart

The same `devcontainer-cli.sh` that installs this Feature also has `init`
and `run` modes for a Linux/macOS host, where it caches a portable Node.js
under `~/.cache/devcontainer-features` (or just uses a `devcontainer` already
on PATH). Together with the PowerShell flavour for Windows it backs the
`task devcontainer:*` tasks that `bootstrap/bootstrap.ps1` / `bootstrap.sh`
vendor into a repo; nothing is installed globally on any host.
