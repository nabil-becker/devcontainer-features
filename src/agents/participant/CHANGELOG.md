# Changelog

The participant component (`components/participant/`): the agent list reader, the kinds, the lease,
the session names, the adapter verbs, `agents up` and the verbs the `devcontainer-cli` launcher calls,
with the `agents:` Taskfile. It is never published alone: each Feature that uses it carries a copy
(`task components:sync`) and installs it into `/usr/local/lib/dcf-participant`, one copy whichever
Feature installs it (ADR-0061). Its version is `COMPONENT_VERSION`; bump it in the same change as any
change here, add the entry below, run `task components:sync`, and bump every Feature that carries a
copy. Backward compatible within a major (NFR-5): `agents.yml` and `AGENTS_FILE` stay (as aliases of
`participants.yml` and `PARTICIPANTS_FILE` from 1.1.0) until the next major.

## [1.4.0] - 2026-11-21

### Changed

- **Each agent its own path's skills** (ADR-0074). The hand-over at an agent's start names the
  agent's `registry-path` (`dcf-registry handover <cli> <name> <folder> --as <path>`), so another
  agent's resolve in between never hands it the wrong view, and the CLI keeps each agent's skills
  apart (claude-code 1.14.0).

### Added

- **The key `registry-skills: split | shared | off`**, with the container default
  `COMPONENT_REGISTRY_SKILLS_MODE` (task variable, `.env`, `.devcontainer/.env`, environment; else
  `split`): `shared` keeps the 1.2.0 behaviour for that agent (its whole view shared, the latest start
  wins), `off` resolves and hands over nothing for it and drops its own copies. Each start says the
  mode and where it came from; `agents check` prints it per agent with the agent's own folder and
  skills (from the adapter's `skills-show`).
- `agents up` forgets (`dcf-registry forget`) an agent the registry handed skills to that is no
  longer in the agent list (in this repository; the sessions no agent started are left alone): its
  CLI drops the agent's own skills folder. Never fatal.

Nothing to do. With `component-registry` older than 1.8.0, `--as` is ignored by `handover` and
nothing is forgotten (its `handovers` verb does not exist).

## [1.3.0] - 2026-11-20

### Added

- **Agent definitions from the component registry** (component-registry 1.6.0). At an agent's
  start, `resolve` is handed the listed agents' names and CLIs (`COMPONENT_REGISTRY_AGENTS`, so a
  layer's `model.<cli>` reaches the agents of that CLI), and after it the
  agent's definition is read from the resolved view's `agents/<name>/`, only when the view was
  resolved for the agent's path (its `registry-path`, else `COMPONENT_REGISTRY_WHOAMI`). Its
  **model** reaches the CLI adapter in the new environment variable `AGENT_MODEL` on every call
  about the agent (empty on every other call, as `AGENT_SESSION_NAME`); an adapter that does not
  read it starts its CLI on the CLI's own default (claude-code 1.13.0 and copilot 0.2.0 pass
  `--model`, in place of any `--model` in the agent's arguments). Its **skills** replace the list entry's `skills:`. The
  registry wins for these two fields (the Operator's ruling of 2026-11-21); the list fills what the
  registry leaves unset, and the registry sets nothing else. One line at the start says what was
  used, from which layers and what it replaced; `agents check` shows it per agent (or why the
  definition was not read), and `agents list --json` gains `"model"` when a definition sets one.

### Fixed

- `agents up` with agents of two registry paths, the first path again after the second: that agent
  was handed the second path's skills (the path counted as resolved in the run). It is resolved
  again when another path's resolve came in between.

Nothing to do: without the `component-registry` Feature, or with a layer list that defines no
agents, nothing changes.

## [1.2.0] - 2026-11-20

### Added

- **The component registry at an agent's start** (ADR-0064). When the `component-registry` Feature is
  installed (`dcf-registry` on PATH) and its layer list exists, `agents start` and `agents up` first
  run `dcf-registry resolve` and then hand the resolved skills to the agent's CLI
  (`dcf-registry handover`, which uses the adapter's new optional `skills` verb when its `supports`
  lists it), so the agent starts with them. It never blocks a start: no layer list, a resolve that
  fails (no `COMPONENT_REGISTRY_WHOAMI`, a required layer never fetched) or a CLI that cannot take
  resolved skills is one line, and the agent starts with the skills it has. Without the
  `component-registry` Feature nothing changes and nothing is said.
- **`registry-path`, an optional key of an agents list entry**: who this agent is in the component
  registry (an absolute path such as `/Corp/MyDepartment/team/review`), passed to `resolve` as
  `--as`; without it `COMPONENT_REGISTRY_WHOAMI` applies. Checked like the other keys (a relative
  path, a pattern or the key twice is refused with its file and line) and shown by `agents check`.

- **A start limit for the registry** (`COMPONENT_REGISTRY_START_WAIT`, default 15 seconds per agent):
  resolve and the hand-over together wait at most that long, a layer fetch that hangs and another
  resolve holding the lock included. Past it the agent starts with the last good skills already in
  its CLI's skills folder, and one line says so; `/registry-refresh` hands the new ones over later.

Nothing to do: lists without `registry-path` work as before.

## [1.1.0] - 2026-11-20

### Added

- **`participants.yml`.** The list may be `.devcontainer/participants.yml`, with the top-level key
  `participants:` as well as `agents:` (one of them per file). `PARTICIPANTS_FILE` names another path,
  resolved like `AGENTS_FILE` (task variable, `.env`, `.devcontainer/.env`, environment). Which one wins:
  `PARTICIPANTS_FILE`, then `AGENTS_FILE`, then, with neither set, `participants.yml` when it exists,
  else `agents.yml`. When both are set, or both default files exist, `participants.yml` is read, the
  other is ignored, and one warning on stderr names both. `participants.yml` is the name to use; a
  repository with only `agents.yml` or `AGENTS_FILE` sees no change at all, not even a warning.
- **Three keys an entry may carry:** `attachment` (`mcp`, `pump` or `model`; any other value is an
  error naming the file and line), `description` and `skills` (a list, flow or block). They are no longer
  an unknown-key warning. `agents list --json` prints them after `sessionName`, only for the entries that
  set them (the output of a list without them is byte for byte as before), so another Feature can read
  them; `agents check` shows `attachment` and `skills`. `agents` itself does nothing else with them.

Nothing to do: no change for an existing `agents.yml`.

## [1.0.0] - 2026-11-19

### Added

- The code of the `agents` Feature 2.1.3, moved here as it was (ADR-0061): `agents.sh`, the `agents:`
  Taskfile, and `install-participant.sh`, which installs them once into `/usr/local/lib/dcf-participant`
  (the `agents` command on PATH, the Taskfile include, the state folders) and leaves an equal or newer
  copy alone. Installed by `claude-code` with `participants: true`, and by the deprecated `agents`
  Feature. The `agents:version` task shows the agents Feature's version and one deprecation line when
  that Feature is installed, otherwise `participant <version>`; `agents:check` prints the same line.
