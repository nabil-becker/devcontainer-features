# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

## [0.4.0] - 2026-11-21

Hub and spoke with local and private trust (slice N3 of the facilitator-node proposal; ADR-0067 to ADR-0071).
Nothing changes without a `mesh.yml`: a node stays standalone with every port on loopback. Rebuild the container.

### Added

- **`mesh.yml`** (`.devcontainer/mesh.yml`, `FACILITATOR_MESH_FILE`): `preset` (`solo`, `team`; `open` refused: not yet,
  slice N5), `role` (`standalone`, `spoke`, `hub`; `peer` refused: slice N5), `node`, `trust` (SPIFFE trust domains
  mapped to `local` or `private`), `expose` (a handle or a full SPIFFE ID mapped to its widest level) and `limits` per
  level. The Feature options `hopLimit`, `messageBudget` and `rateLimit` are the defaults; `mesh.yml` overrides them per
  level. A file with findings never opens anything: the node runs standalone (fail narrow).
- **Node certificates** (ed25519, URI `spiffe://<domain>/node/<id>` and the DNS name its dialers use) issued by a hub's
  **OpenBao PKI** (an intermediate; the root kept offline), 24 h, renewed at half life; a home domain may be self-issued.
- **The two locks:** a SLIM listener per trust level on a hub, each with only that level's CA bundle; and the
  application's check of every card and every entry against `mesh.yml` (the ID's domain must be the domain whose CA
  signed it; every packet key bound to a SPIFFE ID by its node's signed card). Refusals in `mesh/refused.log`.
- **`facilitator node invite`** (a single-use join token valid 15 minutes; refused inside an agent's job), **`node join`**
  (a spoke's certificate from the hub's issuer, the trust bundle checked against the token, the hub written into
  `mesh.yml`, a static SLIM link of type `peer`), **`node revoke`** (no renewal; refused by lock two; asks to confirm),
  `node status`, `node bundle` (a federated domain's trust bundle), `node renew`, `node restore-roster`; **`node approve`
  is refused: not yet, slice N5**. Tasks `facilitator:node-invite`, `node-join`, `node-revoke`, `node-approve`,
  `node-status` and `facilitator:explain`.
- **The peers part** (`infra` part `peers`, started on a hub and a joined spoke): cards and the hub's roster (backed up
  into the hub's OpenBao KV, so its snapshot carries it), replicas of the conversations a node's participants are in
  (pushed on write, retried until delivered: a held message waits), renewals. An @handle on another node is reached
  through the hub; `verify` passes on every node holding the conversation and names each remote signer's SPIFFE ID.
- **`check`** shows the mesh, the certificate, what is open beyond loopback, the hub, TLS refusals from the SLIM log
  and lock two's refusals; `check <mesh.yml>...` (or `-`) lints mesh files by NFR-11's contract.
  **`explain`** prints the level a handle or SPIFFE ID gets and each level's effective limits with their source.
- **Qualified handles** (ruling H5): `@b1.spoke-b` names the agent `b1` of the node `spoke-b`. A bare handle works
  when it names one reachable agent; when several share it, it is refused with their qualified names (no
  precedence for this node's own). Two nodes may announce the same handle; `who` and `check` show qualified names
  where a handle is shared. In a conversation shared with other nodes every member is `handle.node`; nothing changes
  for conversations a node keeps alone or for a standalone node.
- **The Directory per role** (`node.directory.peering`): a hub's OCI and libp2p on its name, a spoke on loopback with
  the hub as its bootstrap peer, syncing the hub's records by registry, one way. dirctl 1.9.1 has no mDNS switch, so
  peering needs `directory.firewall` (`auto`: iptables drops UDP 5353; or `external`).

### Changed

- The node image's role is its mounted `/etc/facilitator/mesh.yml`; the sample compose runs the hub as a hub (from
  `bundles/facilitator/hub/mesh.yml`) beside OpenBao and a spoke, publishing nothing. A hub whose OpenBao is sealed runs
  on loopback until its certificate is issued.
- In a mesh, a node's participants have SLIM names of their own (`agntcy/facilitator-<node>/<handle>`).
- `bundleVersion` defaults to `0.4.0`, not released yet: the Feature builds the bundle from its own source until
  `release-bundle` runs and `digests.txt` pins it.

## [0.3.1] - 2026-11-21

### Changed

- The Feature now installs the published node bundle `facilitator-bundle-v0.3.0` (amd64 and arm64), pinned
  in `digests.txt` after checking its SHA256SUMS, GitHub's recorded digest and its build attestation. 0.3.0
  was published before the bundle, so it built the bundle from source during every install (about 250 MB of
  downloads); 0.3.1 downloads the one verified bundle instead. Nothing to change in your configuration;
  rebuild the container to pick it up.

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
