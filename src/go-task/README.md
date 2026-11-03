
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
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| taskAliases | Opt in to team task aliases: install the task-aliases generator and a sha256-verified yq (one more download), and include the generated aliases in the features include (flattened). A team file (teamAliasesFile) maps short names to existing tasks; `task go-task:aliases` regenerates the wrappers, each alias shows in `task --list`. See the Feature's notes. | boolean | false |
| teamAliasesFile | Path of the team aliases file, relative to the folder of the root Taskfile (or absolute). Absent file means no aliases. Only read when taskAliases is true. | string | .devcontainer/task-aliases.yml |
| version | Task release to install (e.g. '3.54.0', with or without a leading 'v'), or 'latest'. | string | latest |
| yqVersion | yq release the aliases generator uses (e.g. '4.54.1', with or without a leading 'v'), or 'latest' (resolves to the newest release at build time). Only installed when taskAliases is true. | string | 4.54.1 |

## How it fits

```text
  every Feature drops a Taskfile --> /usr/local/share/go-task/includes.d/
  task-features-registry --> features.yml  <-- one include in the root Taskfile
  host side: bootstrap/devcontainer.yml gives task devcontainer:up|exec|...
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Nothing | the registry files are in the image and rebuilt with it; no volume | none |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: [windows-workstation-devhost](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/reference-architectures/windows-workstation-devhost.md), [agentic-devhost](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/reference-architectures/agentic-devhost.md)

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

## Changes

### [1.2.1] - 2026-11-03

#### Added

- This changelog: every release of this Feature now has an entry here, written for its users, and the Feature's README shows the latest three under "Changes". Nothing to do.

### [1.2.0] - 2026-10-29

#### Added

- Opt-in `taskAliases` option: give your team's words their own short task names without wiring includes by hand in each repository. Off by default; with it off the generated `features.yml` is byte-identical, so nothing changes unless you set `"taskAliases": true`. Turned on, it installs a private, sha256-verified `yq` at `/usr/local/share/go-task/yq` (never on PATH). `task go-task:aliases` regenerates the aliases and exits non-zero on a bad one; an alias that shadows a task, task alias or include alias is refused. ([#98](https://github.com/nabil-becker/devcontainer-features/pull/98))

### [1.1.3] - 2026-10-28

#### Fixed

- Every build-time download retries through dcf_curl (13 Features) ([#94](https://github.com/nabil-becker/devcontainer-features/pull/94))

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/go-task/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/go-task/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
