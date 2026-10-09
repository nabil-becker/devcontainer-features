
# Task (go-task) (go-task)

Installs Task (https://taskfile.dev), the Taskfile task runner, as a sha256-verified release binary at /usr/local/bin/task with bash/zsh completions.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | Task release to install (e.g. '3.54.0', with or without a leading 'v'), or 'latest'. | string | latest |

## Why not `ghcr.io/devcontainers-extra/features/go-task`?

That community Feature works, but it resolves the binary through `nanolayer`
and a second Feature (`gh-release`) at build time and does not verify the
release checksum. This one downloads the pinned (or latest) release tarball
straight from GitHub, checks it against the release's `task_checksums.txt`,
and installs the bundled bash/zsh completions.

## Driving devcontainers with Task

The `devcontainer-cli` Feature in this repository puts `devcontainer` on PATH
inside the container; the `taskfiles/devcontainer.yml` include (vendored into
a repo by `bootstrap.ps1`) gives `task devcontainer:up|exec|...` on the host.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/go-task/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
