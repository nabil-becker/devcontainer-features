
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

The Taskfile + PowerShell in this repository's `taskfiles/` folder (vendored
into a repo by `bootstrap.ps1`) do the same trick on the Windows host: a
portable Node.js cached under `%LOCALAPPDATA%`, never installed globally.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/devcontainer-cli/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
