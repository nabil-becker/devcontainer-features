# Facilitator: peer to peer and public

Nodes with no hub, each the issuer of its own domain, linked in pairs; and, for a node you do not run, a public domain
with its own listener, certificates of one hour and a person's approval of every stranger. Cloud AIs reach a node
over OAuth 2.1 (facilitator 0.8.0). The design is the proposal [facilitator-node](../proposals/facilitator-node.md) (sections 5, 8, 10,
11) and ADRs
[0067](../adr/0067-the-facilitator-is-a-network-node-built-as-a-bundle-with-topology-as-configuration-and-trust-levels-over-spiffe.md),
[0070](../adr/0070-mcp-over-http-serves-cli-bearer-tokens-first-and-cloud-ai-oauth-later-with-the-node-as-resource-server-only.md),
[0071](../adr/0071-a-facilitator-node-opens-a-port-beyond-loopback-only-by-explicit-configuration-and-never-discovers-peers-on-the-lan.md).
**Most of this page is not released**: read "What exists today" first.

## Who it is for, and when to use it

Use it when two or more people, or two organisations, each run their own node and want their agents to talk without a
hub that one of them owns: a pair of colleagues' laptops, a partner's node, a node on a public domain where an agent
offers a service to strangers. A public node is seen only by what the issuer exposes `public`, copies only what is
addressed to it, and joins only by its key and a person's approval.

Not for: a team that already has a hub and an OpenBao ([a team intranet hub](facilitator-team-hub.md)); one machine
([solo](facilitator-solo.md)); or any node on a laptop behind NAT that is to be reached by a cloud AI (a cloud AI needs a
public HTTPS address and an OAuth authorization server, so such a node is local only for it).

## What exists today

Dated 2026-11-23. The current release is `facilitator` 0.5.0.

| Piece | State | Version |
| --- | --- | --- |
| HTTP clients at `public` on one node: bearer tokens, first-contact approval, the public limits (rate 3 a minute, hops 2, budget 10, 16 KiB), the audit log | built, released | 0.5.0 |
| `role: peer`, `node.peers`, pairing by token (`node invite`, `node peer --token`), the local issuer (a CA the node keeps, name-constrained to its domain, no OpenBao) | being built (branch `node-n4-n5`, N5a) | 0.6.0 |
| `preset: open`, a public domain (`node.public`), a separate public listener and join endpoint, a public node joining by key plus `node approve`, certificates of 1 h | being built | 0.6.0 |
| `copy: addressed`, first contact across nodes, `verify` reporting a partial replica | being built | 0.6.0 |
| Revoke with the rotation of the mesh's SLIM secret, the signed audit register (`audit verify`, `replay`) | being built | 0.6.0 |
| `badge`, an opaque signed field in a card (AGNTCY Identity as a seam; the `identity` option stays refused) | being built; the badge layer itself is not scheduled | 0.6.0 |
| Cloud AIs over OAuth 2.1: the protected-resource metadata, an issuer allow list (`http.issuers`), a public HTTPS address (`http.url`), clients named by (issuer, subject), `http issuers` | built (N5b), end to end against a local test issuer (`test:facilitator-oauth`); not yet run with a real cloud AI | 0.8.0 |
| Three nodes in a mesh with no hub, run end to end | the p2p flow test is written; not released | 0.6.0 |

Anything marked "being built" is on a branch that has not merged and not been released; names and options may move.

## Diagram

```text
  PEER A  (laptop-nb, domain a.mesh.example)                 PEER B  (a colleague's node, b.mesh.example)
  +----------------------------------------+                +----------------------------------------+
  | node: role peer, preset open           |  SLIM, mTLS    | node: role peer                        |
  | Directory + SLIM (loopback)            |<-------------->| each is the issuer of its own domain   |
  | own CA kept in the volume (mode 600)   | a link per pair| CA name-constrained to its domain      |
  |  trust: b.mesh.example -> private      | token pairing: | trust: a.mesh.example -> private       |
  |  listen: private 0.0.0.0:46358         | node invite /  +----------------------------------------+
  |  volume (4): conversations, mesh/ca/   | node peer
  +--------------------+-------------------+                 no hub, no relay, no roster: each node
     |                 | node.public (domain open.example)   decides alone; `node revoke` on one node
     |                 |  public listener (own port, own CA bundle)  refuses that node THERE only
     |                 |  public join endpoint (own port, no token)
     |                 v
     |       PUBLIC NODE P  (a stranger's)                    CLOUD AI (built, N5b: OAuth 2.1,
     |         node request  --- its key, signed --->          protected-resource metadata,
     |         a person on A: node requests; node approve      a named authorization server,
     |         node collect <--- certificate 1 h, bundle ---   a public HTTPS address on the node)
     |         sees only agents exposed `public`; copy: addressed (only what is addressed to it)
     v
  the person on A: Claude Code over stdio, or HTTP with a bearer token (built, 0.5.0)
```

## `devcontainer.json`

The Feature is the same on every node; the role is in `mesh.yml`. What you can build today is the node itself:

```jsonc
{
  "name": "peer-node",
  "image": "mcr.microsoft.com/devcontainers/base:debian",
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {
      "participants": true
    },
    "ghcr.io/nabil-becker/devcontainer-features/facilitator:0": {
      // 0.6.0 (role peer, preset open) is not released: until it is, this is a standalone node.
      "bundleVersion": "0.5.0",
      // On a public node, keep the limits the level sets: mesh.yml `limits.public` says them per level.
      "hopLimit": "6"
    }
  },
  "containerEnv": {
    "FACILITATOR_MESH_FILE": "/var/lib/devcontainer-features/facilitator/mesh.yml"
  },
  "remoteUser": "vscode"
}
```

The `mesh.yml` files (0.6.0, being built; `facilitator check <file>` lints them):

```yaml
# a peer, no hub (preset open allows a public domain; preset team stays at private)
preset: open
role: peer
node:
  id: laptop-nb
  domain: a.mesh.example          # its own domain: this node is its issuer
  name: laptop-nb.a.mesh.example  # the DNS name in its certificate
  listen: {private: 0.0.0.0:46358}
  peers: {desk-ab: incoming}      # or host:port of the peer that listens
trust: {b.mesh.example: private}  # a domain not listed is refused
expose: {"*": local, triage: private, greeter: public}
# the issuer of a public domain (the same node, or a hub)
#  node.public: {domain: open.example, join: 0.0.0.0:46361}   node.listen.public: 0.0.0.0:46360   # example ports
#  limits.public: {copy: addressed, svid_ttl: 1h, approval: first-contact}
```

```sh
# peers: on one, then on the other
facilitator node invite                       # a token: single use, 15 minutes, carries the hash of the CA bundle
facilitator node peer --token <token>
# a public node joining: on the issuer, then on the public node, then on the issuer
facilitator node invite --level public        # a 15 minute window; prints the info to hand over by a channel of your own
facilitator node request <info>               # on the public node: its key, signed
facilitator node requests; facilitator node approve <id>   # on the issuer: a person's act, a signed audit entry
facilitator node collect                      # on the public node: the certificate (1 h), the bundle, the mesh secret
```

For cloud AIs the node is a resource server only: it validates the JWT access tokens of the issuers you list and publishes
the protected-resource metadata; it does not host an authorization server (facilitator 0.8.0):

```yaml
# .devcontainer/facilitator.yml
facilitator:
  humans: [you]
  http:
    listen: 0.0.0.0:8443
    behind_proxy: true                    # a reverse proxy ends TLS; or tls_cert and tls_key
    url: https://node.example             # the public HTTPS address; the resource is https://node.example/mcp
    issuers:
      - name: corp                        # names the server and starts its clients' handles (corp-alice)
        issuer: https://login.example.org # the token's `iss`; its JWKS is found from its discovery document
        # jwks_uri, algorithms (default RS256, ES256), scope (default facilitator:participate), audience (default the resource)
```

```text
facilitator http issuers                  # reads each issuer's keys now: ok, or NOT READABLE and why
facilitator http list                     # an OAuth client: OAuth, subject alice of https://login.example.org
facilitator http approve corp-alice       # first contact, as for a bearer client
```

A cloud AI that gets a 401 with `resource_metadata` reads the metadata, logs the person in at your authorization server
and calls with the token; the first valid token of a new (issuer, subject) enrols a client whose first message waits for a
person. How a person connects a claude.ai custom connector is in the Feature's NOTES ("Connect a cloud AI"); it has not
been run against a real cloud AI yet.

## Data and its storage tier

| Data | Where it lives | Tier | A rebuild | Losing the machine |
| --- | --- | --- | --- | --- |
| `mesh.yml`, `facilitator.yml`, `participants.yml` | the repository, for the parts that are not written by a join | 1 | untouched | kept once pushed |
| The domain's CA (certificate and key, mode 600) | `mesh/ca/<domain>/` in the volume | 4 | kept | **lost with the volume**: every peer pairs again, and a public node joins again |
| A node's certificate and key (24 h; public 1 h), the peers' bundles, the mesh's SLIM secret | the volume | 4 | kept | pair or join again |
| The mesh's SLIM secret after a rotation | the volume of each node that remains; `node secret` shows or sets it | 4 | kept | a node that missed a rotation is refused until a person sets it |
| The signed audit register (joins, approvals, denials, revokes, rotations, first contacts) | a register in the volume | 4 | kept | lost; the other nodes hold their own |
| `http/audit.jsonl` (0.5.0), replayed into the register once each | the volume | 4 | kept | lost |
| Conversations: a full replica on private nodes; on a public node only what is addressed to it | each node's volume | 4 | kept | lost with that node |
| A public join's info (the issuer's CA bundle) and an invite token | handed over by a channel of the person's own; not stored | none | not kept | not kept |
| An HTTP token | the CLI's own config file | a secret on the CLI's disk | kept | make a new token |

## On the workstation, and in the container

| On the host, and with the person | In the node's container |
| --- | --- |
| the channel that carries a token or a public join's info (a message, a call) | the node, its CA, its listeners, `node invite`, `peer`, `request`, `collect`, `approve`, `revoke` |
| the person's judgement on each stranger: `node requests`, `node approve` | `facilitator check`, `explain`, `audit verify`, `verify` |
| a firewall or a router that opens the listener's port for a node others must reach | the Directory on loopback; `directory.peering` stays off beside a public domain |
| the DNS name and TLS endpoint a cloud AI will use (`http.url`, N5b) | the participants and the HTTP endpoint |

## Best practices

- **Hand over a token or a public join's info by a channel you already trust.** Both carry the SHA-256 of the issuer's
  CA bundle, so the receiver checks the certificate against it: no trust on first use, but only if the channel was not
  the attacker's.
- **Expose as little as `public` means.** An agent is never public unless `mesh.yml` says so; a public node sees only
  those, and a message to any other reads like a message to a handle that does not exist.
- **Approve a stranger's node as a decision, not a click.** `node approve` signs an audit entry and issues a 1 h
  certificate that renews while you allow it; `node revoke` stops the renewals.
- **Revoke on every node that trusts it.** With no hub there is no roster to relay: `node revoke` on one peer refuses that
  node there, and the others trust it until they revoke it too.
- **Keep addressed-only conversations separate.** A message to others goes in another conversation (see P2).
- **Keep the public listener and join endpoint on their own ports.** The public one is refused if it is equal to the private
  one, and its CA bundle holds public domains only.
- **Do not put a node on a laptop behind NAT in front of a cloud AI.** It has no public HTTPS address; use a node
  that does (`http.url`).
- **Name each issuer's audience and scope at the authorization server.** The token must carry `aud` = `<http.url>/mcp` (or the
  entry's `audience`) and the scope `facilitator:participate`; a mismatch is a 401 or 403 and the node's log says which.
- **Rotate and read the audit.** After a revoke, `facilitator check` shows the rotation and that every remaining
  node holds the new secret; `facilitator audit verify` checks the chain.

## Anti-patterns

### P1. Directory peering on a node with a public domain

- **Don't:** turn on `node.directory.peering` on a node that has a public domain in `trust`.
- **Why:** ruling H2 (2026-11-21, ADR 0075): dirctl 1.9.1 finds peers by mDNS with no switch to turn it off, any dialer
  at its libp2p port joins the gossip, and its OCI registry accepts an anonymous push; N5a refuses the combination.
- **Instead:** the mesh learns another node's agents from its signed card; for a public node, publish by push to the
  named node and never into a shared DHT.
- **Caught by:** `facilitator check` and `check <mesh.yml>` (0.6.0, being built).

### P2. Mixing addressed and unaddressed messages in one conversation

- **Don't:** expect a public node to see, or to verify in full, a conversation that also carries messages not addressed
  to it.
- **Why:** slice N5a found register-engine cannot hold a part of a register: an entry's `prev` and the heads it `saw`
  must be present or the entry is refused, so the proposal's "ancestors' ids, not bodies" has no form in the engine.
- **Instead:** a message to others goes in another conversation; a conversation with a member on a `copy: addressed`
  node carries only messages addressed to it (the write is refused otherwise), and `verify` reports a partial replica
  naming the node to verify on.
- **Caught by:** the write refusal in `say` and `reply`, and `mesh/refused.log` when `peers` withholds a register.

### P3. A CA with a URI name constraint

- **Don't:** make a domain's CA with a URI name constraint to keep it to its SPIFFE IDs.
- **Why:** the ssh-agent spike (2026-11-23, [ssh-agent-ca](../spikes/2026-11-23-ssh-agent-ca.md)): SLIM refuses every
  certificate from a CA that carries one (`NameConstraintViolation`); `ensure_local_ca` wrote exactly that, and the
  branch changes it to a DNS constraint only.
- **Instead:** a DNS constraint; lock two still checks the domain in every card and entry.
- **Caught by:** the spike and the changed issuer (being built); nothing for a CA made by hand.

### P4. Trusting a revoked node's link

- **Don't:** assume `node revoke` ends a node's link at once.
- **Why:** ruling H4 (2026-11-23): SLIM checks no revocation list and reloads no certificate; the link can form until the
  certificate expires. N5a rotates the mesh's SLIM secret on every revoke because of it.
- **Instead:** revoke on every node that trusts it, let the rotation complete (up to 120 s for a node that is away), and
  for a public node rely on the 1 h certificate.
- **Caught by:** the rotation (0.6.0, being built); `check` shows it.

### P5. One Linux user for an agent you do not know

- **Don't:** run an agent you do not trust as a participant beside others, because it reaches the public through your node.
- **Why:** the Operator's question of 2026-11-23: every participant runs as one Linux user, so a malicious process can read
  another's token; backlog `per-identity-users`.
- **Instead:** a node of its own, joined at `public`, and `expose: public` only on the agent that must be reached.
- **Caught by:** nothing yet.
