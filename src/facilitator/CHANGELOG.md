# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

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
