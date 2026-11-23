# Facilitator: a team intranet hub

A hub on a server the team runs, with an OpenBao beside it that issues the domain's certificates; a spoke on each
engineer's machine (a devcontainer with the Feature); and the engineers' command-line agents, Claude Code and GitHub
Copilot CLI, reaching a node over MCP on HTTP with bearer tokens and a person's approval. The design is the proposal
[facilitator-node](../proposals/facilitator-node.md) (sections 4, 5, 8 and 11) and ADRs
[0067](../adr/0067-the-facilitator-is-a-network-node-built-as-a-bundle-with-topology-as-configuration-and-trust-levels-over-spiffe.md),
[0069](../adr/0069-node-certificates-are-issued-by-an-openbao-pki-per-trust-domain-and-two-locks-keep-each-trust-level-apart.md),
[0070](../adr/0070-mcp-over-http-serves-cli-bearer-tokens-first-and-cloud-ai-oauth-later-with-the-node-as-resource-server-only.md),
[0071](../adr/0071-a-facilitator-node-opens-a-port-beyond-loopback-only-by-explicit-configuration-and-never-discovers-peers-on-the-lan.md),
[0076](../adr/0076-an-http-client-may-begin-a-conversation-under-a-persons-approval-and-public-under-team-reaches-only-a-nodes-own-http-clients.md).

## Who it is for, and when to use it

Use it when a team of engineers, in one organisation and on one intranet, wants their agents to address each other
across machines (`@triage` on a colleague's node), with an audit trail of who began each conversation, and wants a
CLI that cannot run `facilitator mcp` in a devcontainer to reach a node over HTTP. The hub holds no more rights than
`mesh.yml` gives it: it routes, issues certificates and keeps the roster; it holds a replica of a conversation only
when one of its own participants is in it.

Not for: one machine ([solo](facilitator-solo.md) or [a hub on the workstation](facilitator-workstation-hub.md)), nodes
of different organisations (that is the public level: [peer to peer and public](facilitator-peer-and-public.md)), or a
cloud AI such as a web assistant (it needs OAuth and a public HTTPS address; not built).

## What exists today

Dated 2026-11-23. The current release is `facilitator` 0.5.0; the server image is
`ghcr.io/nabil-becker/facilitator-node:0.5.0` (amd64 and arm64).

| Piece | State | Version |
| --- | --- | --- |
| Hub, spoke, `mesh.yml`, join token, the two locks, revoke, qualified handles, `check` | built, released | 0.4.0 |
| The hub's OpenBao PKI (an intermediate; the root offline), 24 h certificates renewed at half life, the roster backed up into OpenBao's KV | built, released | 0.4.0 |
| The node image and the sample compose (hub, OpenBao, one spoke; nothing published) | built, released | image 0.5.0 |
| MCP over HTTP: bearer tokens, a person's `token`, `approve`, `deny`, `revoke`, the signed-for-by-the-node record (`via`), the hash-chained audit log, the abuse limits | built, released | 0.5.0 |
| An HTTP client at `private` (no approval) or `public` (first-contact approval, 30 days) through `trust: http.<home domain>` | built, released | 0.5.0 |
| The hub on Kubernetes (a kustomize base) and a built-in issuer instead of OpenBao | planned | rulings K2, K3; ADR 0078 |
| Automatic unseal of the hub's OpenBao | not decided: unsealed by hand stays (ruling PB2) | |
| Cloud AIs over OAuth | planned | 0.7.0, N5b |

## Diagram

```text
 ENGINEER'S MACHINE (laptop-nb)                      INTRANET                       SERVER (the team's)
 +-----------------------------------+                                    +--------------------------------------+
 | CLIs outside a devcontainer       |                                    | CONTAINER ENGINE or KUBERNETES       |
 |  Claude Code, Copilot CLI         |                                    |                                      |
 |   |  HTTPS /mcp                   |                                    | HUB  node image, role hub, team      |
 |   |  Authorization: Bearer <tok>  |                                    |  Directory + SLIM embedded (loopback)|
 |   +------------> a node's endpoint (facilitator.http.listen, TLS)      |  SLIM private listener 46358  (mTLS) |
 |                                   |                                    |  join endpoint 46359 (token live)    |
 | DEVCONTAINER = SPOKE laptop-nb    |   SLIM, mTLS, link type peer       |  facilitator.http (optional)         |
 |  facilitator Feature (node)       |------------------------------------>  volume hub-state (4)               |
 |  claude / copilot / model         |   dials OUT, opens nothing         |         | AppRole, PKI sign          |
 |  stdio facilitator mcp            |                                    |         v                            |
 |  volume facilitator-state (4)     |                                    | OPENBAO (second container)           |
 +-----------------------------------+                                    |  pki-corp intermediate, KV roster    |
   the person: node invite / revoke / http token / approve                |  raft volume (4); sealed at start    |
   (in a plain terminal, never an agent's job)                            +-----------------+--------------------+
                                                                                            |
   the Operator's custody: the 3 unseal shares, the offline ROOT CA key   <-----------------+ (off the server)
```

## `devcontainer.json`

The engineer's spoke. The node's role and the hub's address are in `mesh.yml`, which `node join` writes.

```jsonc
{
  "name": "team-spoke",
  "image": "mcr.microsoft.com/devcontainers/base:debian",
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {
      "participants": true
    },
    "ghcr.io/nabil-becker/devcontainer-features/copilot:0": {
      "participants": true,
      "attach": "facilitator"
    },
    "ghcr.io/nabil-becker/devcontainer-features/facilitator:0": {
      "bundleVersion": "0.5.0",
      // The team's defaults; mesh.yml `limits` override them per level.
      "hopLimit": "6",
      "rateLimit": "10"
    }
  },
  "containerEnv": {
    "FACILITATOR_MESH_FILE": "/var/lib/devcontainer-features/facilitator/mesh.yml"
  },
  "remoteUser": "vscode"
}
```

The hub's side is the node image with three mounted files; the sample is `bundles/facilitator/compose.yml` and
`bundles/facilitator/hub/`. A spoke's `mesh.yml` after `node join`, and the settings that open an HTTP endpoint on a
node:

```yaml
# spoke: .../facilitator/mesh.yml (written by `facilitator node join`; the expose map is yours)
preset: team
role: spoke
node: {id: laptop-nb, hub: hub.corp.example:46358, hub_name: hub.corp.example, hub_node: hub-1, domain: corp.example}
trust: {corp.example: private}
expose: {"*": local, triage: private}   # an agent opts outward, never inward
# the endpoint for CLIs, in .devcontainer/facilitator.yml of the node that serves them
facilitator:
  humans: [you]                          # who approves first contacts
  http:
    listen: 0.0.0.0:8443
    url: https://laptop-nb.corp.example:8443
    tls_cert: /etc/facilitator/tls/cert.pem       # beyond loopback: TLS, or behind_proxy: true
    tls_key: /etc/facilitator/tls/key.pem
```

Make a client and connect a CLI, in a plain terminal:

```sh
facilitator http token claude-laptop      # the token, shown once; only its SHA-256 is kept
claude mcp add --transport http facilitator https://laptop-nb.corp.example:8443/mcp --header "Authorization: Bearer <token>"
copilot mcp add --transport http facilitator https://laptop-nb.corp.example:8443/mcp --header "Authorization: Bearer <token>"
facilitator http approve claude-laptop    # after the first message arrives and is held
```

An HTTP client reaches the agents of the node it connects to (exposed `public`, or `private` when
`trust: {http.laptop-nb.local: private}`), never another node's agents at `public` in this release. Whether a
client mapped private reaches agents on other nodes through the hub is not checked.

## Data and its storage tier

| Data | Where it lives | Tier | A rebuild | Losing the machine |
| --- | --- | --- | --- | --- |
| Manifests, `mesh.yml` of the hub, `participants.yml`, `facilitator.yml` | the repository | 1 | untouched | kept once pushed |
| The domain's PKI: the intermediate and its issued certificates | OpenBao's raft volume `openbao-data` on the server | 4, under ADR 0048's bounded loss; back it up with OpenBao's snapshot | kept | restore the snapshot, unseal |
| The root CA key | offline, on a machine of its own | off the machine, custody | untouched | untouched |
| OpenBao's 3 unseal shares (threshold 2) | the Operator's password manager, paper, a second person | off the machine | untouched | untouched; never with the snapshot |
| The hub's AppRole file | the hub's volume at `.../facilitator/approle` | 4 | kept | issue it again |
| The hub's roster | the hub's volume and OpenBao's KV `secret/facilitator/mesh/roster` | 4 | kept | `node restore-roster` |
| A spoke's certificate and key (24 h, mode 600) | the spoke's volume | 4 | kept | join again |
| Conversations | a replica on every node that has a member | 4 | kept | lost with that node's volume; other members' replicas remain |
| HTTP clients' token hashes, approvals, `http/audit.jsonl` | the serving node's volume | 4 | kept | clients are made again; the audit chain is lost |
| An HTTP token | the CLI's own config (`.claude.json`, `.mcp.json`, Copilot's `mcp-config.json`) | the CLI's volume or the host's disk, a secret | kept | make a new token |
| TLS certificate and key for the endpoint | the server's own secret store (a mount, a secret) | the server's own | the server's | the server's |

## On the workstation, and in the container

| On the engineer's machine | In the spoke's container, and on the server |
| --- | --- |
| the CLIs that use HTTP (Claude Code, Copilot CLI) and their config files with the bearer token | the spoke: the Feature, the node, the participants, `node join`, the optional HTTP endpoint |
| the person's `http token`, `approve`, `node invite` in a terminal | the hub: node image, OpenBao beside it, the sample compose or your own manifests |
| the launcher and git | `facilitator check` on each node; `explain <handle>` to see a level and its limits |
| custody of nothing for the hub | the server's operator: the unseal shares, the root offline, TLS, the backup of OpenBao |

## Best practices

- **Unseal OpenBao after every hub start, in your own terminal, and plan who does it.** While it is sealed nothing is
  issued or renewed; certificates last 24 h and are renewed at half life, so a hub gets a day's margin and a public
  one (1 h) fails first. Automatic unseal was left undecided on purpose (ruling PB2).
- **Keep the root CA offline and the intermediate in OpenBao.** The trust bundle needs both (`int-root.pem`); the role
  refuses any URI outside `spiffe://corp.example/*`.
- **Join with the token's hash, never by trusting the first certificate you see.** A token is single use, valid
  15 minutes, and carries the SHA-256 of the trust bundle; the join endpoint is open only while a token is live.
- **Open an HTTP endpoint only with TLS, or behind a proxy that ends it.** Beyond loopback the node needs `tls_cert` and
  `tls_key` or `behind_proxy: true`, and `url` or `allowed_hosts`; `http.enabled: false` is the kill switch.
- **Map your own CLIs to `private` and leave strangers at `public`.** At public a first message is held until a person
  approves, the limits are strict (3 a minute, 2 hops, budget 10) and only agents exposed `public` are reachable.
- **Treat a CLI's config file as a secret.** The bearer token sits in it in plain text; a token has no expiry, so
  `facilitator http revoke <client>` when a laptop is lost.
- **An approval is a grant for 30 days, to begin conversations.** An approved client's `say` starts a chain no person
  wrote; it is bounded by the public limits and the reach rule (ADR 0076, to be revisited with use).
- **Read `facilitator http audit` and `facilitator check` after each change.** The chain shows a cut or an edit.
- **Use `facilitator node revoke` and also stop the hub's listener when the cut-off is urgent.** See T2 below.

## Anti-patterns

### T1. One CA bundle for two levels

- **Don't:** trust the handshake as identity, or give one listener the CA bundle of more than one level.
- **Why:** the SLIM spike of 2026-11-21 ([slim-spiffe](../spikes/2026-11-21-slim-spiffe.md)): SLIM never checks the
  SPIFFE ID or the trust domain, so an impostor ID signed by a trusted CA was accepted.
- **Instead:** one listener per level with only that level's CA bundle (lock one) and the application's check of every
  card and entry (lock two).
- **Caught by:** the N3 exit test and `check`; both locks are built (0.4.0).

### T2. Revoke alone for an urgent cut-off

- **Don't:** rely on `node revoke` to stop a stolen laptop's node at once.
- **Why:** ruling H4 (2026-11-23): SLIM 3.4.6 checks no revocation list and reloads no certificate, so a revoked
  node's TLS link can still form until its certificate expires (24 h); lock two refuses everything it sends.
- **Instead:** revoke, then restart the hub without that bundle or stop the listener; shorter lifetimes come with
  public trust, and the rotation of the mesh's SLIM secret is built in 0.6.0 (being built).
- **Caught by:** the command's output says what it does not recall.

### T3. Directory peering on the intranet

- **Don't:** set `node.directory.peering: true` on the hub without `node.directory.firewall`.
- **Why:** ruling H2 (2026-11-21, ADR 0075): dirctl 1.9.1 finds peers by mDNS with no switch to turn it off, and its OCI
  registry accepts an anonymous push.
- **Instead:** peering `false` (the default); the mesh learns agents from the signed cards.
- **Caught by:** the Directory refuses to start when peering is on and no firewall is named.

### T4. An untrusted agent among the team's agents

- **Don't:** list an agent you do not trust in a spoke with other participants.
- **Why:** the Operator's question of 2026-11-23: every participant shares one Linux user, so a malicious process can
  read another's token; backlog `per-identity-users`.
- **Instead:** its own devcontainer and spoke, `expose` limited; or an HTTP client at `public` with approval.
- **Caught by:** nothing yet.

### T5. The endpoint without a `mesh.yml`

- **Don't:** open `facilitator.http.listen` on a node that has no `mesh.yml`, or under `preset: solo`.
- **Why:** ADR 0076 and 0.5.0: the endpoint is off by default and refused under solo.
- **Instead:** `preset: team` first; then `listen`, TLS and `url`.
- **Caught by:** `facilitator check` says why the endpoint refuses.
