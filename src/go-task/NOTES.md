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
registered; `task go-task:version` which `task` runs and its version.

Feature tasks run in your current directory, so paths such as `CONFIG=` or
`DIR=` are relative to the project.

## Driving devcontainers with Task

The `devcontainer-cli` Feature in this repository puts `devcontainer` on PATH
inside the container; the `bootstrap/devcontainer.yml` include (vendored into
a repo by `bootstrap/bootstrap.ps1` or `bootstrap.sh`) gives
`task devcontainer:up|exec|...` on the host.

## Team task aliases (`taskAliases`)

Give the team's words (the lexicon) their own short task names, without hand-wiring includes in each
repository. Off by default, because it installs one more download, a pinned and sha256-verified
`yq` (a private copy at `/usr/local/share/go-task/yq`, never on PATH, so it cannot collide with
another `yq`):

```json
"ghcr.io/nabil-becker/devcontainer-features/go-task:1": { "taskAliases": true }
```

Commit a team file, `.devcontainer/task-aliases.yml` (the `teamAliasesFile` option; the path is
relative to the folder of the root Taskfile):

```yaml
aliases:
  briefing: devhost:briefing          # short form: the existing task
  cost-report:                        # long form
    task: devhost:report
    desc: The month's agent spend     # default: "alias for devhost:report"
  ts:
    task: timesheet:week
    vars: { PERSON: me }              # fixed variables; no free arguments
```

Run `task go-task:aliases`: it reads the file, checks every alias against the root Taskfile's
`task --list-all --json` and writes one wrapper task per accepted alias into
`/var/lib/devcontainer-features/go-task/aliases.yml`, which the `features` include already carries,
so each alias is in `task --list`. It prints a table (alias, target, status, note). Slice 1 runs it by
hand; run it again after editing the file.

The exit status: `task go-task:aliases` passes `--strict` and exits 1 when any alias is `invalid`,
`broken` or `shadows`, or when yq or the root Taskfile cannot be read, so a bad alias is not missed
in a terminal or a script. Without `--strict` (the default, for a run at container start) the
generator always exits 0, so a bad alias never blocks startup; the valid ones are still written.

- An alias points at an existing task only. Another alias is refused; a missing target is `broken`
  (no wrapper, nothing fails).
- A name that is a real task, a Task `aliases:` entry of one, or an include alias (`dcx:up` when
  the include has `aliases: [dcx]`) is refused as `shadows`: Task fails the whole run with "Found
  multiple tasks" when a flattened include repeats a task name, so a clash is never emitted.
- The file has no command field. Names and targets match `[a-z][a-z0-9_-]*` (colons allowed between
  words); `vars` take plain strings, numbers and booleans, never `{{`, `sh:` or `ref:`; a `desc` is one
  line; any other key (`cmds`, `deps`, `dir`, `env`, `preconditions`) is rejected. Every emitted value
  is a single-quoted YAML scalar. A bad alias is skipped and reported, the others still work.
- The generator never fails a build or a start (exit 0, and the generated file is always valid,
  `tasks: {}` at worst).
- Flatten the `features` include (as above). Unflattened, the aliases appear under its namespace.
- A call's `vars` do not override a static `vars:` default of the target task in Task 3.54; a target
  that should take an alias's variable reads it as `{{.PERSON | default "..."}}`.
- The generated folder belongs to the remote user, so the wrappers can be regenerated without root.
  The personal layer, the volume and the start hook come in a later version.
