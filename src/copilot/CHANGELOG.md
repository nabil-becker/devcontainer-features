# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

## [0.3.1] - 2026-11-24

### Changed

- The skills hand-over code (`skills`, `skills-show`, the `--add-dir` folder and the start line) is
  now the collection's shared helper `dcf-skills.sh`, carried inside `agent-adapter-copilot` (backlog
  `skills-shared-helper`). No change in behaviour: the same files, modes, folders and lines,
  checked byte for byte before and after in `split`, `shared`, `off` and forget. Nothing to do.

## [0.3.0] - 2026-11-24

### Added

- **Registry skills** (ADR-0077 slice 2.1, backlog `templating-slice-2`): `agent-adapter-copilot`
  gains the `skills` verb (and the read-only `skills-show`). With the component-registry Feature 2.1.0
  and a layer list, each Copilot agent gets its registry skills, rendered from the `copilot` templates:
  the ones every agent shares in `$COPILOT_HOME/skills` (Copilot's personal skills folder), the ones
  only its own path resolves in a folder that `new`, `resume` and `run-once` pass with `--add-dir`.
  A project or personal skill of the same name wins, and that is said.

### Changed

- This is a change for a Copilot agent in a container with a layer list: it now gets skills it did
  not get before. The default is `split`, as for Claude Code. Action, only to keep the old
  behaviour: `registry-skills: off` on the agent's entry, or `COMPONENT_REGISTRY_SKILLS_MODE=off`.

## [0.2.1] - 2026-11-21

### Changed

- The participant component 1.4.0 it carries: an agent's hand-over names its own `registry-path`,
  and `agents up` forgets the agents no longer in the list (ADR-0074). The Copilot adapter has no
  `skills` verb, so nothing changes for a Copilot agent; nothing to do.

## [0.2.0] - 2026-11-20

### Added

- **The model of an agent definition.** `agent-adapter-copilot` reads `AGENT_MODEL` (the component
  registry's agent definition, handed over by the participant component 1.3.0; a layer's
  `model.copilot` key sets it for Copilot agents only) and passes it as `--model` on `new` and
  `resume`, in place of any `--model` in the agent's arguments (the registry wins, said in one line).
  The flag is Copilot CLI 1.0.114's own (`copilot --help`). `run-once` is unchanged.
- With `participants: true`, the participant component 1.3.0: agent definitions from the component
  registry at an agent's start; the registry's skills replace the list entry's and are shown.

## [0.1.0] - 2026-11-20

### Added

- **The first version: GitHub Copilot CLI as a named agent beside Claude Code** (backlog
  `copilot-feature`, ruling D20, ADR-0061). It is 0.1.0, not 1.0.0: the CLI itself is generally available
  (1.0.x), but this Feature's adapter and `attach` have been run only against a fake `copilot` and the
  real CLI's `--version` and `mcp` commands, never with a Copilot login (see the manual checklist in the
  notes); 1.0.0 follows that run.
- **It depends on the official Feature (NFR-4, the Operator's ruling of 2026-11-20).**
  `dependsOn` on `ghcr.io/devcontainers/features/copilot-cli:1` installs the CLI; this Feature installs no
  binary and downloads nothing. That is this repository's exception to "`installsAfter` only", made by
  the Operator, as `az` and `phi-check` do. `installsAfter` `gh` stays. There is **no `version` option**:
  an option cannot be forwarded into `dependsOn`, so the version is pinned in the entry itself,
  **Copilot CLI 1.0.114**, and `COPILOT_AUTO_UPDATE=false` in `containerEnv` stops Copilot's own
  self-update, so everyone gets the same version (the Operator's ruling S/V, 2026-11-20). Each release
  of this Feature bumps the pin after a test. Listing the official Feature yourself with another
  version conflicts with ours and is not supported; to update for yourself, set
  `COPILOT_AUTO_UPDATE=true`.
  The official Feature's own install is not checksum-verified, and it leaves the
  binary owned by uid 1001 (the release archive's owner), which this Feature hands to root; see the notes.
- **`agent-adapter-copilot`**, the participant component's adapter for the Copilot CLI: `new`, `resume`,
  `hint`, `run-once` (one non-interactive turn through `copilot -p`, for the facilitator's pump) and
  `mcp-attach`. Verbs Copilot has no local route for (`start-bg`, `wake`, `attach`, `list`, `stop`,
  `logs`, `record`, `session-*`) and `trust` answer exit 3. A copilot participant is on-demand or
  ephemeral, never resident. The contract tests (`test/agents/unit/contract_test.sh`) now run against the
  real Copilot adapter as well as the two fakes.
- **The `participants` option** (boolean, default `false`): installs the participant component exactly as
  `claude-code` does, one shared copy in `/usr/local/lib/dcf-participant` (component 1.2.0).
- **The `attach` option** (`facilitator`, or empty): registers the facilitator's MCP entry through
  `copilot mcp add facilitator` at post-create and by `task copilot:attach`. It needs no login. The entry
  holds no token and no handle: start copilot with `FACILITATOR_HANDLE` and `FACILITATOR_TOKEN` in its
  environment. It does nothing while the facilitator Feature is not installed.
- **`COPILOT_HOME` is a named volume** (`/var/lib/devcontainer-features/copilot`), so a `copilot login`
  survives rebuilds, and `copilot-setup` makes it usable and owner-only (Copilot refuses a home writable
  by group or other). The Feature never logs in and never stores a token (NFR-13).
- The Feature Taskfile: `copilot:version`, `copilot:login`, `copilot:config`, `copilot:setup`,
  `copilot:attach`.

Nothing to do: a new Feature. To use it, add `ghcr.io/nabil-becker/devcontainer-features/copilot:0`
and sign in with `task copilot:login`, or set `COPILOT_GITHUB_TOKEN`.
