## Why not `ghcr.io/devcontainers-extra/features/go-task`?

That community Feature works, but it resolves the binary through `nanolayer`
and a second Feature (`gh-release`) at build time and does not verify the
release checksum. This one downloads the pinned (or latest) release tarball
straight from GitHub, checks it against the release's `task_checksums.txt`,
and installs the bundled bash/zsh completions.

## Feature Taskfiles: tasks that come and go with the Features

Every Feature in this collection ships a small Taskfile for its tool
(`dsc:get`, `velero:backups`, `kustomize:build`, ...). With the default
`installTaskfile: true` it lands in `/usr/local/share/go-task/includes.d/<id>.yml`
at image build time, and `task-features-registry` (installed by this
Feature) rebuilds `/usr/local/share/go-task/features.yml` to include every
file there, namespaced by Feature id. Add one include to your root Taskfile
and never touch it again:

```yaml
includes:
  features:
    taskfile: /usr/local/share/go-task/features.yml
    optional: true   # absent outside the devcontainer, e.g. on the Windows host
    flatten: true    # expose as dsc:get rather than features:dsc:get
```

Add a Feature to `devcontainer.json` and rebuild: its tasks are in
`task --list`. Remove it: they are gone. Install order does not matter, since
each Feature refreshes the registry after dropping its file and this Feature
refreshes it when it installs. `task go-task:registered` shows what is
registered.

Feature tasks run in your current directory, so paths such as `CONFIG=` or
`DIR=` are relative to the project.

## Driving devcontainers with Task

The `devcontainer-cli` Feature in this repository puts `devcontainer` on PATH
inside the container; the `taskfiles/devcontainer.yml` include (vendored into
a repo by `bootstrap.ps1`) gives `task devcontainer:up|exec|...` on the host.
