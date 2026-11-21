# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

## [0.3.0] - 2026-11-20

The facilitator becomes a node bundle (slice N2 of the facilitator-node proposal, ADR-0067): one built,
checksummed bundle per architecture that both this Feature and a new node image install. Rebuild the container.

### Added

- **The node bundle** at `/opt/facilitator`: the application, its own CPython 3.13.18 (python-build-standalone),
  `dirctl`, `slimctl`, `slim-bindings` and a `MANIFEST.json`, built by `bundles/facilitator/install.sh`. The Feature
  installs the release `facilitator-bundle-v<version>` when `digests.txt` pins it, and otherwise builds the same
  bundle from its own source (every upstream piece checked against its pinned SHA-256). No Python is taken from
  the system any more.
- Option **`bundleVersion`** (default `0.3.0`; `latest` is the bundle this Feature version was made with).
- Option **`mode`**: `node` (the default, as before) or `leaf`, the thin client only: no `slimctl`, no daemon
  started, `infra up` and `node run` refused, `check` ready without them. A leaf reaches a node over the network
  from slice N3.
- `facilitator node run`: the node in the foreground, the node image's entrypoint (a signal stops it, a part that
  dies stops the rest with exit 1).
- `facilitator version` and `check` name the mode and the bundle.
- The node image (`bundles/facilitator/Dockerfile`, a hub: debian slim, user `facilitator`, `tini`, state in the
  volume) and a sample `compose.yml` with OpenBao beside it; the manual workflows `release-bundle` and
  `release-node-image`, which the Operator starts.

### Deprecated

- **`dirVersion` and `slimVersion`**: use `bundleVersion`. The bundle fixes dirctl 1.9.1 and slimctl 3.4.6; those
  versions or `latest` still work, with a `deprecated: use bundleVersion` line from the install, `version` and
  `check`; removed in 1.0.0. Delete them from your `devcontainer.json`.

### Fixed

- The Directory starts after a container was removed: a stale `daemon.pid` is removed before it starts.

## [0.2.0] - 2026-11-20

The facilitator is reached only through MCP (the Operator's ruling of 2026-11-20: "remove the chat,
essentially making it just accessible through the MCP").

### Added

- A person attaches their own Claude Code or Copilot session to `facilitator mcp` with their own handle and
  token, as a participant of kind `human` (a human of `facilitator.yml`, registered), and gets the tools
  `say` (start a conversation, or write in one of theirs), `mail` (the unread messages of their
  conversations, never waiting, then marked read), `transcript` (a conversation, with a limit), `continue`
  (a paused conversation runs another hop limit) and `who`. An agent keeps `receive`, `reply`, `say` and
  `who`; a person's tools are refused to it, and the kind comes from the roster, never from the caller.
- `facilitator mail [--as <handle>] [--notice | --hook]`, read only: `--notice` prints one line
  ("Facilitator: 2 new messages in c-1a2b3c4d") or nothing, `--hook` the same as Claude Code hook JSON;
  both always exit 0. Task `facilitator:mail`.
- `facilitator snippet <person>`: the shared MCP entry, the environment and a Claude Code `UserPromptSubmit`
  hook to paste (the Feature never edits Claude's settings, NFR-13). Copilot CLI has no hook that can show
  the line; ask it to call `mail`.
- `transcript --limit <n>`.

### Changed

- `facilitator mcp` takes the handle from `FACILITATOR_HANDLE` when `--as` is absent (exit 2 naming both when
  neither is set), so one MCP entry serves every agent whose harness sets `FACILITATOR_HANDLE` and
  `FACILITATOR_TOKEN`. `snippet` prints that one entry (no `--as`) and the two environment lines.
- **A person's message counts as a hop** (option A): in an existing conversation it answers the
  conversation's last message, one hop more, and is held by a pause or the hop limit like any other. Only
  `continue` resets the hops. A message in a new conversation still begins a chain at hop 0. With the
  default limit of 6 a person has three exchanges with one agent before `continue`. The message budget and
  the rate are unchanged.
- `register` makes a token for each person too (`register you`, or `--all`, once after the upgrade), and
  `facilitator-start` makes it again at each start, as for a participant.

### Removed

- `facilitator chat` and the task `facilitator:chat`: ask your own Claude Code session instead (NOTES,
  "Talking to the agents from Claude Code").
- `facilitator send` and the task `facilitator:send`.
- `facilitator continue`: the MCP tool `continue` of a person's session replaces it, so continuing needs
  the person's token.

## [0.1.0] - 2026-11-20

### Added

- The facilitator, first version, on AGNTCY (ADR-0061, slice 3 of the facilitator proposal): conversations
  between agents of any vendor in one devcontainer, by `@handle`, with a hop limit, a message budget and a
  rate limit, every message a signed packet in a register-engine `conversation` register, and
  `facilitator verify` walking each message back to the human who began the chain.
- The MCP server `facilitator mcp --as <handle>` (tools `receive`, `reply`, `say`, `who`), authenticated by a
  participant token; the local-model wrapper `facilitator model`; `facilitator chat`, `send` and
  `transcript --json`; `facilitator snippet` for attaching a Claude Code participant.
- The infrastructure on loopback, started by `facilitator infra up` and by `autostart`: the AGNTCY Directory
  (dirctl 1.9.1) and a SLIM node (slimctl 3.4.6), each pinned by SHA-256; slim-bindings 3.3.9 in the
  Feature's own venv.
- Keys in OpenBao when it is ready; otherwise, in mode-600 files in the volume. This fallback stays for the 0.x
  versions and is removed at 1.0, when a key will only ever be in OpenBao.
- Every `@handle` in a message is delivered, each once, as the proposal's routing rule 1 says: "@jester tell
  @domain-expert-one a joke" goes to both (the Operator's ruling of 2026-11-20). The hop count bounds the chain.
- The participant token reaches `facilitator mcp` through the agent's environment, set by its harness, never in
  the CLI's MCP entry, because tokens are made again at each start.
- Version 0.1.0 rather than 1.0.0: the MCP tools, the packet fields and the verbs may change before 1.0.
