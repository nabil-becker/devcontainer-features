# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

## [0.8.0] - 2026-11-24

Cloud AIs over OAuth 2.1 (slice N5b of the facilitator-node proposal; ruling PB3, ADR-0070 decisions 1, 2 and 5 to 8). The node is
an OAuth **resource server only**; bearer tokens keep working beside it, and a node that sets no `http.issuers` behaves as
0.7.0 (except that the well-known metadata path now answers 404 until issuers are set). Rebuild the container. No new
Python dependency: the bundle already carries PyJWT and `cryptography` (the `mcp` library's).

### Added

- **`facilitator.http.issuers`**: the allow list of authorization servers whose JWT access tokens are accepted. Each entry has a
  `name` (a handle, at most 24 characters), the `issuer` URL, and optionally `jwks_uri` (else found from the issuer's
  discovery document), `algorithms` (default RS256 and ES256; `none` and `HS*` are refused), `scope` (default
  `facilitator:participate`) and `audience` (default the node's resource URL). It needs `http.url`, the public HTTPS
  address, and beyond loopback TLS or `behind_proxy: true` as before (ADR-0070 decision 8). `check` lints every option and
  fetches nothing.
- **The token checks** (`oauth.py`): issuer, algorithm, signature against the issuer's JWKS (fetched over HTTPS, kept an hour,
  re-read once a minute for an unknown `kid`), `exp`, the audience of this node's `/mcp` URL (RFC 8707), the scope. A refused
  token is a 401 with `WWW-Authenticate: Bearer error="invalid_token", resource_metadata=...` and no detail; a token without
  the scope is a 403 `insufficient_scope`; **keys that cannot be read close the door** (503, not counted against the caller,
  the log says why).
- **The RFC 9728 protected-resource metadata** at `/.well-known/oauth-protected-resource` and `.../mcp`, naming the node's
  resource, the authorization servers and the scope; and a 401 with `resource_metadata` for a request with no token, so a cloud
  AI finds where to log in.
- **An OAuth client is the (issuer, subject)** of its token, enrolled on its first valid token and held until a person approves
  it (first contact, as for a bearer client); handle `<issuer name>-<subject>`; the same HTTP client in every other way (never
  `human`, the participant tools only, `http.<home domain>`, the public limits). Its packets carry `via` = `{transport: http,
  auth: oauth, client, issuer, subject}`; `transcript` and `verify` show it. The conversation type accepts `subject` in `via`.
- **`facilitator http issuers`** reads each issuer's keys now and says which are readable; `facilitator http list` shows an OAuth
  client's issuer and subject; `check` has an `http oauth` line.
- **`facilitator http forget <client>`** (task `facilitator:http-forget`, ruling OA3): a person's act that drops a revoked or denied client's entry so the same login (OAuth: issuer and subject; bearer: the name) is new next time, enrolled again and held for approval; a live client is refused; a `forget` event is written to the audit log and register.
- NOTES: "MCP over HTTP for cloud AIs", a section per setting and how a person connects a claude.ai custom connector.
- Tests: `test_oauth.py` (a local test issuer; the right and the wrong audience, expired, wrong issuer, wrong scope, alg none,
  HS256 forged with the public key, a rotated key, keys that cannot be read, the endpoint's statuses and challenges, enrolment,
  approval, `via`), more in `test_http.py`, and `test/facilitator/oauth_flow.sh` (`task test:facilitator-oauth`): an MCP
  client holding an OAuth token end to end through a built bundle's endpoint.

### Changed

- The well-known metadata path answers **404** on a node with no `http.issuers` (0.7.0 answered the library's metadata naming
  the node itself as its authorization server, which was wrong: a node hosts none).
- A revoked or denied OAuth client is no longer refused for good: a person can `forget` it.
- `facilitator.http.issuers` is no longer refused; a bare list of URLs is refused by name (an entry needs a `name`).

## [0.7.0] - 2026-11-24

The hub on Kubernetes (slice hub-on-kubernetes of the facilitator-node proposal; rulings K2 to K5, ADR-0078). Nothing changes for a
node that is not a hub, and a hub with `node.issuer.openbao` keeps its OpenBao PKI. Rebuild the container.

### Added

- **A built-in issuer for a hub** (K3, K4): with no `node.issuer.openbao` a hub issues its domain's certificates itself and
  needs no unseal. It keeps a root CA and an issuing CA (ed25519, constrained to `DNS:<domain>` and the hub's own name: SLIM
  refuses a URI constraint), signs 24 h leaves with the issuing CA, and backs its roster up to `mesh/roster.backup.json` in its
  own volume. A hub made by 0.6.0 keeps its single CA.
- **`facilitator node issuer export-root --out <new file>`** (a person's act, refused inside an agent's job): the root's key
  and certificate to a new file (mode 600) and the root key removed from the volume; the hub keeps issuing and no spoke changes
  anything. **`facilitator node issuer migrate`** (a person's act) moves a built-in hub onto an OpenBao PKI **keeping the
  same CA**, so no spoke joins again (it imports the issuing CA, makes the node role, checks a certificate OpenBao signs chains
  to the spokes' bundle, backs the roster up into OpenBao, then removes the key). **`node issuer status`** (read only). New task
  `facilitator:node-issuer`.
- **The ssh-agent tier** (K5): `node.issuer.ssh_agent: {socket, key}`. The agent's ed25519 key is the CA, matched by its SHA256
  fingerprint (never the first key; RSA, ECDSA and FIDO keys are refused by name), and no CA key file exists; each leaf is one
  signing round trip. With the agent gone issuing and renewing stop with `ssh-agent unreachable at <socket>` and existing
  certificates stay valid. Order of the tiers: OpenBao when configured, else the ssh-agent, else the file.
- **`facilitator check`** names the issuer tier and **warns** (without failing) when the CA key is a file (the last resort) and
  when the agent holds other keys; `node restore-roster` reads the volume's backup for a built-in hub.
- **The hub on Kubernetes**: a kustomize base in `bundles/facilitator/k8s` (a StatefulSet with a volume claim, uid 10001, a
  read-only root filesystem, no capabilities; `mesh.yml` in a ConfigMap; a Service for SLIM 46358 and the join endpoint 46359 and
  nothing else), an overlay for Rancher Desktop (a LoadBalancer; the hub's name in the certificate is the name spokes map to the
  machine with `--add-host=<name>:host-gateway`) and an overlay with the CA key in an ssh-agent container beside the hub.
  `task bundle:k8s` renders and checks them with kustomize and kubeconform; `task test:facilitator-k8s` runs the hub, spokes and
  both issuer tiers in a throwaway kind cluster (the Rancher Desktop overlay itself is not run against Rancher Desktop).
- `bundleVersion` defaults to 0.7.0 (unpinned until `release-bundle` runs: the Feature builds the bundle from its own source).

### Changed

- A hub's `check` no longer says it needs OpenBao: its issuer "must answer" (the built-in CA always does).

## [0.6.0] - 2026-11-23

Peer to peer and the cross-node public rules (slice N5a of the facilitator-node proposal; rulings AH, H4, HC3, ID2, PB3). Nothing
changes unless `mesh.yml` says `role: peer`, `preset: open` or `node.public`: no port opens. Rebuild the container.

### Added

- **`role: peer`** (nodes linked with no hub) and **`preset: open`** (the public level may be used). A peer is the issuer of
  its own domain with a CA it keeps (name-constrained to that domain; no OpenBao needed), lists the nodes it links to in
  `node.peers` (`host:port`, or `incoming` when the peer dials it) and pairs with another peer by a token:
  `facilitator node invite` on one, `facilitator node peer --token` on the other. Cards are exchanged by `hello`.
- **The cross-node public rules.** A node with `node.public` (`domain`, `join`) and a `public` entry in `node.listen`
  issues certificates for a public domain; a public node joins by its **key plus a person's approval**:
  `node invite --level public` (a 15 minute request window, prints the info), `node request` and `node collect` on the
  public node, `node requests` and `node approve <request>` (or `node deny`) on the issuer. A public certificate lasts
  `limits.public.svid_ttl` (1 h), renewed at half life while the issuer allows it; the public listener and the public join
  endpoint are separate from the private ones (one CA bundle each). A public node is shown the issuer's own card, restricted
  to what is exposed `public`, and no other node's.
- **`copy: addressed`** (the public default): the node replicates only the conversations a public node is a member of, and a
  conversation with a member on such a node carries only messages addressed to it: the write is refused otherwise, and the
  register is withheld before sending if it holds more. `verify` reports a lineage that leaves such a replica as partial
  (exit 0). **Did not hold as written:** register-engine cannot hold a part of a register (see the NOTES).
- **First contact across nodes:** a message from a public node's agent waits until a person approves that agent (`approve`
  tool or `facilitator http approve handle.node`), for `approval_ttl` (30 d).
- **Revoke and cut-off:** `node revoke` on a hub or a peer: no renewal, lock two refuses the node at once, and **the mesh's
  SLIM app secret rotates** (ruling H4): the nodes that remain are handed the new one and restart their peers part on it;
  `node secret` shows or sets it for a node that missed a rotation.
- **A signed audit register** of the type `audit` (the second type of `types.d/facilitator.py`): every HTTP enrolment event
  and every join request, approval, denial, revocation and rotation is a signed entry; `facilitator audit verify|replay|show`;
  the lines of `http/audit.jsonl` are replayed into it once each (ruling HC3).
- **`badge`**, an opaque optional field of each participant entry of a node card (ruling ID2): carried and signed with the card,
  ignored by lock two. The `identity` option stays refused.
- `limits.<level>.svid_ttl` may be as short as 1 minute (tests); `check` shows the public certificate, waiting requests,
  peers and the secret rotation.

### Changed

- `node approve` works (it was refused until now); `node invite`, `node revoke` also serve a peer; `trust` may map a domain
  `public` under `preset: open`; `copy: addressed` is accepted (and the only value at public).
- `bundleVersion` defaults to `0.6.0`: the Feature installs the published node bundle `facilitator-bundle-v0.6.0`
  (amd64 and arm64), pinned by SHA-256 in `digests.txt`.

## [0.5.0] - 2026-11-23

MCP over HTTP for CLIs (slice N4 of the facilitator-node proposal; ADR-0070, ADR-0071, ADR-0068). Nothing changes unless
`facilitator.http.listen` is set in `facilitator.yml`: no port opens and no client exists. Rebuild the container.

### Added

- **The endpoint** (`facilitator http serve`, the `http` part of `infra up`): the node's MCP tools over Streamable HTTP, on
  the `mcp` library 2.3.0, for Claude Code and GitHub Copilot CLI with a static `Authorization: Bearer` token (both run
  for real in `task test:facilitator-http`). Off unless `facilitator.http.listen` is set; refused under `preset: solo`;
  beyond loopback it needs TLS (`http.tls_cert`, `http.tls_key`) or `http.behind_proxy: true`, and `http.url` or
  `http.allowed_hosts`; `http.enabled: false` is the kill switch. `check` says why it refuses; `http.issuers` (OAuth for
  cloud AIs) is refused: slice N5.
- **Clients and tokens:** `facilitator http token <client>` (a person's act, refused inside an agent's job: the token is
  shown once and only its SHA-256 is kept), `list`, `approve`, `deny`, `revoke`, `audit`; a person's MCP session gains the
  `approve` tool. At most 20 clients may wait for approval. Every enrolment, approval, denial and revocation is a line of
  a hash-chained audit log.
- **The node signs for an HTTP client** (ADR-0068): every message and task state it makes carries `data.via`
  (`{transport: http, auth: bearer, client}`); `transcript` shows it and `verify` checks it and accepts a chain that begins
  with such a client. A client is **never a person**: `who`, `say`, `reply`, `receive`, `mail` and a read-only
  `transcript`; never `continue` or `approve`.
- **The single-node public rules** (ruling AH): a client maps through `http.<home domain>`, **public** unless `mesh.yml`
  maps it to private; it sees only agents exposed `public` (an unreachable agent reads as one that does not exist); its
  first message is held until a person approves it (`limits.public.approval: first-contact`, a held message is dropped
  after 7 days, an approval lasts 30 days); the public limits (rate 3 a minute across all its conversations, hops 2,
  budget 10, `max_packet` 16 KiB). `mesh.yml` accepts `expose: public` under `team`, `trust: http.<home domain>`, and the
  limit keys `approval`, `approval_ttl` and `http_receive_wait`.
- **Abuse limits at the edge:** 10 failed authentications in a minute block the address for 10 minutes, 20 open requests
  per address, a 64 KiB body, Host and Origin checks, a `receive` that blocks at most `http_receive_wait` (25 s at public)
  and 2 at a time per client.
- `check` shows the endpoint, the clients' level and the audit chain, and the `mcp` library; `explain` prints the public
  level's limits; `version` prints `mcp`. The bundle carries `mcp` 2.3.0 and 27 dependency wheels, each pinned by SHA-256
  (about 40 MB more).

### Changed

- The conversation type accepts the optional `via` field on a message and a status, and the notice codes `approval`,
  `approved` and `denied`. A conversation with a `via` does not load on a 0.4.0 node.
- `bundleVersion` defaults to `0.5.0`: the Feature installs the published node bundle `facilitator-bundle-v0.5.0`
  (amd64 and arm64), pinned by SHA-256 in `digests.txt`.

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
- `bundleVersion` defaults to `0.4.0`: the Feature installs the published node bundle `facilitator-bundle-v0.4.0`
  (amd64 and arm64), pinned by SHA-256 in `digests.txt`.

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
