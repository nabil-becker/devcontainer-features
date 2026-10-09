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
