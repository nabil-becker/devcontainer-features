# Changelog

The participant component (`components/participant/`): the agent list reader, the kinds, the lease,
the session names, the adapter verbs, `agents up` and the verbs the `devcontainer-cli` launcher calls,
with the `agents:` Taskfile. It is never published alone: each Feature that uses it carries a copy
(`task components:sync`) and installs it into `/usr/local/lib/dcf-participant`, one copy whichever
Feature installs it (ADR-0061). Its version is `COMPONENT_VERSION`; bump it in the same change as any
change here, add the entry below, run `task components:sync`, and bump every Feature that carries a
copy. Backward compatible within a major (NFR-5): `agents.yml` and `AGENTS_FILE` stay (as aliases of
`participants.yml` and `PARTICIPANTS_FILE` from 1.1.0) until the next major.

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
