# Spike: SLIM with SPIFFE, two linked nodes, two Directories, MCP over HTTP (2026-11-21)

Backlog id `slim-spiffe-spike`; it follows `docs/spikes/2026-11-19-agntcy.md`. Who it serves: the Operator,
through the host, who ruled that the facilitator becomes a node in a mesh (every install a node; hub and
spoke first, then peer to peer; trust levels are SPIFFE trust domains: local, private, public; local CLIs
reach a node through a thin client over SLIM, cloud AIs through MCP over HTTP). Nothing was built. Everything
below was run in this devhost (x86_64, Docker 29.9.3) with every process in a container on a dedicated Docker
network, or on loopback; every download sat in its own empty directory and was checked first. Where something
was read from documentation and not run, it says **from docs**.

Versions used: `slimctl` 3.4.6 (git `aa932ea`, the version pinned in `src/facilitator`), `slim-bindings` 3.3.9
(reports node 3.4.6), SPIRE 1.16.0, `dirctl` v1.9.1, Python `mcp` 2.3.0, Claude Code 2.1.311.

## Result in one paragraph

All four questions have a working answer, and three of them push back on the ruling's wording. (1) SLIM does
use SPIFFE, but only as transport TLS material: it trusts whatever chains to the bundle it is given and **never
looks at the SPIFFE ID**, so a "trust level" is *which CA bundle a listener holds*, not a per-ID policy; SPIRE
is optional (a CA that signs SPIFFE-shaped certificates from files works the same) and costs 160 MB per install.
(2) Two nodes link and a client on one reaches a client on the other, also across two trust domains and
spoke to spoke through a hub, but only with `connection_type: peer`; the default link type does not carry
routes, and cross-domain links "managed" by SLIM need its separate Controller, which I did not run. (3) Two
Directories find each other and share *labels and CIDs of published records* over libp2p, and move *content*
only when told to by a one-way `sync`; the loopback-only Directory config the facilitator uses today cannot
sync, and mDNS lets nodes on the same network segment find each other with no bootstrap. (4) The MCP spec of
2026-07-28 is a different protocol shape from the one our spike assumed (no sessions, no GET stream); a
maintained MIT Python library serves it with OAuth resource-server checks, and Claude Code and Copilot CLI can
both add a remote HTTP server.

## 1. SLIM with SPIFFE

### What SLIM offers (read from the 3.4.6 source and docs, then run)

| Layer | Config | What it checks | Needs |
|---|---|---|---|
| Transport TLS from files | `tls.source: {type: file, cert, key}` on the server, `tls.client_ca: {type: file, path}` for mTLS; a client has `tls.source` and `tls.ca_source` | the peer's chain to the CA file (WebPKI); the server name against the cert's DNS SAN | PEM files only |
| Transport TLS from SPIRE | the same keys with `type: spire`, `socket_path: unix:///...`, `trust_domains: [...]` | the same chain check, with the roots taken from the SPIFFE bundles of the listed domains; the node's own cert is rotated by the Workload API | a SPIFFE Workload API socket (a `spire-agent`, so also a SPIRE server) |
| Connection auth `auth: {type: spire}` | JWT-SVID per connection, audience `slim` | signature against the JWT bundle, audience; **no claim policy** (the claims map is empty) | the same Workload API |
| Connection auth `basic`, `jwt`, `static_jwt`, `oidc` | as before | `oidc` can add a CEL or Rego policy over the claims (from docs) | an IdP for `oidc` |
| App identity (MLS, name binding) | `shared_secret`, `jwt`, `spire` | per message, not per connection | none for shared secret |

There is no mode called "spiffe"; the word is `spire`, and it always means "ask a Workload API socket". The
Python bindings expose the same choices (`TlsSource.FILE|SPIRE`, `CaSource.FILE|SPIRE`,
`ClientAuthenticationConfig.SPIRE`), so a thin client can use files or a Workload API socket.

### Run A: SVID-shaped certificates from two self-signed CAs, no SPIRE

A 25-line `openssl` script made two CAs (`local.test`, `intranet.test`, EC P-256) and leaf certificates with one
URI SAN `spiffe://<domain>/<path>`, `CA:false`, `digitalSignature`, EKU server and client. One node (container,
`slimctl slim start`), clients are `slim-bindings` Python processes.

```yaml
# node: mTLS from files; client_ca holds the CAs of the trust domains this listener admits
services:
  slim/0:
    node_id: node-a
    dataplane:
      servers:
        - endpoint: "0.0.0.0:46357"
          tls:
            source:    {type: file, cert: /pki/nodeA-dns.pem, key: /pki/nodeA-dns.key}
            client_ca: {type: file, path: /pki/ca-local.test.pem}      # or a bundle of both CAs
```

| Case | Result |
|---|---|
| node cert with only the URI SAN, client dials `spike2-a` or `localhost` | **refused by the client**: `certificate not valid for name ...; only valid for UniformResourceIdentifier(spiffe://local.test/node/a)` |
| node cert with `DNS:nodeA`, client sets `server_name: nodeA` | accepted |
| client from `local.test`, node trusts `local.test` | connected in 0.19 s |
| client from `intranet.test`, node trusts only `local.test` | refused (connection closed in the handshake) |
| client with no certificate | refused: `received fatal alert: CertificateRequired` |
| **impostor**: URI `spiffe://intranet.test/client/impostor`, signed by the `local.test` CA | **accepted**: the ID is never checked |
| node's `client_ca` is the bundle of both CAs | the `intranet.test` client is accepted |
| `intranet.test` client trusting only its own CA | refused by the client (it does not trust the node's CA) |

So federation is one-line and symmetric, and it is only chain trust.

### Run B: SPIRE 1.16.0, two trust domains, static federation

SPIRE is two static musl binaries (`spire-server` 179 MB, `spire-agent` 78 MB), Apache-2.0, sha256 in the
release API (`spire-1.16.0-linux-amd64-musl.tar.gz` `7bcf5e16...d1d5`, matched). Least machinery that worked: per
trust domain one container with `spire-server` (sqlite, `join_token` node attestor, `memory` key manager),
`spire-agent` (join token, `unix` workload attestor), and the workloads started with `setpriv --reuid`, one uid
per workload. Idle: **agent 65 MB, server 98 MB RSS** (against about 20 MB for the SLIM node).

```text
spire-server run -config server.conf                       # trust_domain = local.test, ca_ttl 24h, svid ttl 10m
spire-server token generate -spiffeID spiffe://local.test/agent1 -ttl 600     # -> <token>
spire-agent run -config agent.conf -joinToken <token>      # trust_bundle_path = spire-server bundle show
# entries: the parent is the agent's SPIFFE ID, spiffe://local.test/spire/agent/join_token/<token>
spire-server entry create -parentID <agent id> -spiffeID spiffe://local.test/slim/node-a \
    -selector unix:uid:1001 -dns nodea.local.test -federatesWith spiffe://intranet.test
# federation by hand (static, no bundle endpoint): show on one, set on the other, both directions
spire-server bundle show -format spiffe  > b.json ;  spire-server bundle set -format spiffe -id spiffe://<other> -path b.json
```

```yaml
# node: the SVID comes from the Workload API, the roots from the bundles of the listed domains
tls:
  source:    {type: spire, socket_path: "unix:///spire/agent.sock"}
  client_ca: {type: spire, socket_path: "unix:///spire/agent.sock", trust_domains: [local.test, intranet.test]}
# optional second factor, a JWT-SVID per connection
auth: {type: spire, socket_path: "unix:///spire/agent.sock", jwt_audiences: ["slim"], trust_domains: [local.test, intranet.test]}
```

| Case | Result |
|---|---|
| `local.test` client, node trusts `local.test` | connected (0.10 s) |
| `intranet.test` client, no federation | refused (`UnknownIssuer`, on the client side) |
| client federated, **node not** (its `trust_domains` lists only `local.test`) | refused by the node (connection cancelled) |
| federated on both sides | connected (0.09 s) |
| node demands `auth: spire`, client sends a JWT-SVID | connected |
| node demands `auth: spire`, client sends none | refused: `link negotiation error ... connection send error` |

### What surprised me

- **SLIM never inspects the SPIFFE ID or trust domain of a peer.** The impostor test passed on files, and the
  SPIRE path builds one flat root store from all the listed bundles (`root_store_builder.rs`, read, then seen
  working). The JWT-SVID mode checks signature and audience only. A node cannot say "this client may be
  `spiffe://private.test/*` and that one `public.test/*`" on one listener.
- **A DNS SAN is needed** for the node's name (SPIRE: `-dns` on the entry, then `server_name` on the client);
  a pure SPIFFE URI SAN fails the client's hostname check. The shipped example uses a `server_name` override
  for the same reason.
- A refused client does not get a clear error from `connect`: the call retries in the background and the
  caller sees a timeout; the reason is in the logs (`UnknownIssuer`, `CertificateRequired`).
- The node **waits at start** until the Workload API gives it an identity (it logged "Initializing spire
  identity manager" and sat there until its registration entry existed).
- From the source, the roots are collected **once at start**; I did not test a bundle rotation, so a
  federated domain's CA rotation reaching a running node is unverified (the node's own SVID does rotate).
- Static `bundle set` federation does not refresh. SPIRE's `federates_with` bundle endpoint does, and needs
  an HTTPS endpoint on each server; not run.

## 2. Two nodes linked

Config for the hub (server only) and the spoke (a server for its local clients, plus a client link to the hub):

```yaml
# spoke: the link to the hub is a client entry of type peer; the spoke dials out (no inbound port needed)
services:
  slim/0:
    node_id: slim-spoke
    dataplane:
      servers: [{endpoint: "0.0.0.0:46357", tls: {insecure: true}}]    # local clients; loopback in a real install
      clients:
        - endpoint: "http://spike2-hub:46357"       # https plus server_name and tls source/ca_source for mTLS
          connection_type: peer
          tls: {insecure: true}
```

Hub and spoke came up in 2 s; each side logs `upgrading server-side connection to Peer (negotiation)` and
`completed full sync for peer` (subscriptions are exchanged).

| Test | Result |
|---|---|
| client on the hub to a client on the spoke, MLS on and off | works, session set up in 23 to 45 ms |
| spoke B (node cert from `intranet.test`) to spoke C (`local.test`) **through the hub**, mTLS on both links | works: transitive route sync, session in 118 ms |
| same, but the spoke link left at the default type (`edge`) | **fails**: `message send retries exhausted`; routes are not carried |
| two nodes, no `domain_name` set | peer links still formed |

**Latency** (same container host, Docker bridge; all numbers wall clock from Python):

| Path | First round trip | Steady round trip | 50 pipelined messages, all replies |
|---|---|---|---|
| both clients on one node | 44 to 46 ms | 88 to 96 ms | 46 ms |
| hub to spoke (one peer link) | 53 to 65 ms | 78 to 101 ms | 62 ms |
| spoke to spoke through the hub | 93 ms | 92 to 96 ms | not run |

The sequential round trip is the same with and without a hop, and the pipelined run is fast, so it is not the
network: the pattern (one 45 ms step, then two) looks like TCP delayed acknowledgement meeting Nagle in the
gRPC stream, but I did not prove that. The hop itself costs about 15 ms per 50 messages.

**A node going away.** With a session open from the hub client to the spoke client, `docker stop` of the spoke
node:

- the spoke's clients logged `reconnect ... tcp connect error` within the second, then retried about every
  5 s; the hub logged `connection closed by peer` (info level, no "peer down" wording);
- the session **survived**: the sender's receive timed out once (10 s), and the messages sent during the outage
  were delivered, in order, as soon as the client reconnected (3 s after the node restarted; the peer link
  re-formed at once with a full sync);
- a **new** session to a name behind a stopped node failed after 8 s: `failed to add participant to session:
  message send retries exhausted` (3 retries at 2 s, from the session config);
- there is no explicit "peer is down" event to an application: it sees timeouts or exhausted retries.

**Documented, not run (from docs).** The Controller (a separate service, `slimctl controller ...`) manages
*domains* (nodes with the same `domain_name` form a peer group), *links* between domains (always created by the
Controller; the source node dials the destination's `external_endpoint`), and *segments*; topology is an
adjacency list (full mesh `"*"`, star `domain: cloud, neighbors: ["*"]`, explicit pairs, chain), each domain
elects a gateway and fails over. A node registers with `controller.clients`. The data-plane `connection_type`
is `edge` (default, to a node a client uses), `peer` (same deployment) or `remote` ("always handled by the
control plane"). The multi-cluster guide says cross-cluster routing needs SPIRE federation. So the Operator's
"hub and spoke first" has two routes: a static `peer` client per spoke (works today, tested), or Controller
topology `star` (the intended way, a new service to run).

## 3. Two Directories

Two `dirctl daemon start` containers (`dir-a`, `dir-b`), the facilitator's `dir-daemon.config.yaml.in` rendered
with the API, OCI, gateway and libp2p addresses on `0.0.0.0` (inside the Docker network), the offline policy.

```yaml
# B's additions to the facilitator's template (A has the same, without bootstrap_peers)
server:
  store:
    oci:
      registry_address: "dir-b:5555"        # NOT 0.0.0.0 or 127.0.0.1: this is also what a syncing peer is told to dial
  routing:
    listen_address: "/ip4/0.0.0.0/tcp/8999"
    directory_api_address: "dir-b:8888"     # advertised to peers (shown by routing search)
    directory_oci_address: "dir-b:5555"
    bootstrap_peers:
      - "/dns4/dir-a/tcp/8999/p2p/<A's peer id, 12D3KooW... from its log or node.key>"
  publication:
    scheduler_interval: 10s                 # default 5m: `routing publish` waits for it
reconciler:
  local_registry:
    registry_address: "dir-b:5555"
```

Sequence and result:

1. `dirctl push jester.json` on A returned a CID; `routing publish <cid>` on A; 10 to 40 s later
   `dirctl routing search --skill language_processing/language_generation/story_generation` **on B listed the
   CID, A's peer id, A's advertised `/dir/dir-a:8888` and `/oci/dir-a:5555`, and the matching skill**. The
   announcement travels by GossipSub (`Published record announcement ... topicPeers=1`).
2. B's `search` and `pull` of that CID: **not found**. Discovery moved no content.
3. `dirctl sync create http://dir-a:8888 --cids <cid>` on B: status `COMPLETED` after the reconciler's minute
   tick; `pull` on B then returns the record; B's own `search` finds it after its indexer tick (another minute).
4. A second record pushed on A and **not** published never appeared in B's routing search.
5. A's built-in `org.agntcy/directory` record was not visible either.

**Shared:** for each *published* record, its CID, its labels (skills, domains, locators; the search matched
on skill) and the publisher's peer id and advertised API and OCI addresses, to every peer that is in the
gossip mesh. **Not shared:** unpublished records, the record bodies (until a peer syncs them, one way, pulled
by the receiver through the sender's OCI registry), the databases, the keys. Sync is pull, from one named
directory, and does not flow back.

**What surprised me**

- **mDNS**: B logged `Connected to local peer via mDNS` before the bootstrap peer, over the Docker bridge. On a
  shared network segment two installs find each other with no configuration, and I found no switch for it in
  the config. For a private mesh this wants checking (or a firewall rule) before any install runs on a
  shared LAN.
- The first sync "succeeded" with nothing copied: the sender's `registry_address` was `0.0.0.0:5555`, which
  it handed to the receiver as the place to pull from, so B pulled from itself (`source=http://0.0.0.0:5555/dir`
  in the log). One setting is both the listen address and the advertised one. The facilitator's template binds
  `127.0.0.1` and so cannot be a sync source; a mesh install needs a routable name, and then the OCI port is
  open to the network.
- My first start failed on a stale `daemon.pid` left by a `docker rm -f`; the daemon says `daemon already
  running (pid 1)` (container pid 1 matches any pid file). The Feature's `up` should remove a stale file.
- Nothing authenticated the libp2p link beyond peer-id keys: any peer that dials the bootstrap address joins
  the DHT and gossip and can see the labels. `routing.autosync.peerlist` and the `dirctl` auth modes
  (`--auth-mode x509|jwt|token (SPIFFE)|oidc|tls`, from the help) exist; I did not try them.

## 4. MCP over HTTP

### What a server must implement (spec 2026-07-28, the latest; read from the spec repository)

- **Streamable HTTP** (since 2025-03-26): one endpoint path that accepts POST. Each JSON-RPC request is its own
  POST; the server answers `application/json` or a request-scoped `text/event-stream`; a notification gets
  `202`. `Accept` lists both types. **2026-07-28 changes the shape**: no GET stream, no protocol-level sessions,
  server-to-client requests (sampling, elicitation) become results the client answers by retrying
  (multi round-trip requests), long-lived notifications via a `subscriptions/listen` POST, closing the stream
  cancels the request, no `Last-Event-ID` resume. Required request headers: `MCP-Protocol-Version`, `Mcp-Method`,
  and `Mcp-Name` for tools, resources, prompts. The server must validate `Origin` (403 if invalid), should bind
  to localhost when local, should send `X-Accel-Buffering: no` on streams, and an unsupported version gets
  `400` with the list it supports.
- **Authorization** (optional; for HTTP it should follow this): the server is an **OAuth 2.1 resource server**.
  It must serve **Protected Resource Metadata (RFC 9728)** naming its authorization server(s); on a missing or
  bad token answer `401` with `WWW-Authenticate: Bearer resource_metadata="..."` (and `scope`); `403` with
  `insufficient_scope` for scopes; **validate that the token was issued for it** (audience, RFC 8707 resource
  indicator) and **never accept or pass through another token**; the token comes only in the `Authorization`
  header, never the query string. The authorization server (not part of the MCP server) must be OAuth 2.1 with
  PKCE and RFC 8414 or OIDC discovery; client registration is by Client ID Metadata Documents (preferred),
  pre-registration, or Dynamic Client Registration (deprecated).

### Library: the official Python SDK `mcp` 2.3.0

PyPI `mcp` 2.3.0 (2026-10-02), **MIT**, Python 3.10+, repository `modelcontextprotocol/python-sdk` (pushed
2026-11-17, about 25 000 stars). Alternative: `fastmcp` 4.2.3 (2026-11-20), **Apache-2.0**, Python 3.11+ (not run).
I downloaded the 28 wheels `pip download` resolved, checked each sha256 against PyPI's own JSON, installed
offline into a throwaway venv, and ran a server on loopback:

```python
server = MCPServer("node", token_verifier=Verifier(),           # Verifier.verify_token(str) -> AccessToken | None
                   auth=AuthSettings(issuer_url="https://auth.example", resource_server_url="https://node.example/mcp",
                                     required_scopes=["facilitator"], validate_token_resource=True))
app = server.streamable_http_app()      # a Starlette app; run with uvicorn
```

| Request | Answer |
|---|---|
| no token, bad token, or a token whose resource is another server | `401`, `WWW-Authenticate: Bearer error="invalid_token", ..., resource_metadata=".../.well-known/oauth-protected-resource/mcp"` |
| valid token without the scope | `403`, `error="insufficient_scope"` |
| valid token | `200`, `initialize` result as an SSE event |
| `GET /.well-known/oauth-protected-resource/mcp` | `200`, `{"resource", "authorization_servers", "scopes_supported", "bearer_methods_supported"}` |
| a bad `Origin` header | `403 Invalid Origin header` |

The library is the resource server only: **issuing the tokens needs an authorization server** (an external
IdP, or `OAuthAuthorizationServerProvider` in the same library, which is a large surface). It still created
legacy per-session transports for the 2025 client, so it serves both shapes.

### Can the CLIs add a remote HTTP server?

| CLI | Add | Auth | Source |
|---|---|---|---|
| Claude Code 2.1.311 | `claude mcp add --transport http <name> <url>`, or `.mcp.json` / `--mcp-config` with `{"type":"http","url":...,"headers":{...}}`; also `sse` and `ws` | static `--header "Authorization: Bearer ..."`; or OAuth 2.0 (discovery from the `401`, CIMD or dynamic registration, `--client-id`, `--client-secret`, `--callback-port`, `claude mcp login <name>`, `/mcp`); a `headersHelper` for tokens made at connect time | docs read, and **run**: with the bearer header `claude -p --model haiku` called the tool on my loopback server and reported `nothing yet` (cost 0.0009 USD); with no header the tool was unavailable (`-p` cannot run the OAuth flow, as the docs say) |
| GitHub Copilot CLI | `copilot mcp add --transport http <name> <url>`, `~/.copilot/mcp-config.json`, project `.mcp.json` or `.github/mcp.json`; `http` is Streamable HTTP, `sse` is the deprecated one | `--header "Authorization: Bearer ..."` or headers in the JSON; a `/mcp auth` subcommand exists in interactive mode | **from docs** (docs.github.com, Copilot CLI "add MCP servers" and the command reference); not installed here, whether its OAuth does discovery and dynamic registration is not stated in what I read |

A cloud AI product (for example a claude.ai connector) reaching a node needs an HTTPS URL reachable from the
vendor's cloud and an authorization server; I did not test that, and a node on a laptop behind NAT has neither.

## Requirements for the node build

**Transport and trust**

1. Treat a trust level as **a listener with its own CA bundle**, because SLIM cannot authorize by SPIFFE ID or
   trust domain. Local: loopback, no TLS, or the existing basic auth. Private and public: one `servers` entry each
   with `tls.client_ca` of that level's bundle (several servers per node are allowed by the config; two
   listeners with different bundles on one node were not tried). If per-ID policy is wanted, it has to be
   added in front (a policy hook, or `oidc` with a CEL or Rego claim policy, from docs) or by the application.
2. Start with **files, not SPIRE**: a per-install CA (or the operator's) issuing SVID-shaped certificates with
   a URI SAN and a DNS SAN, `reload_interval` for rotation (from the reference config). SPIRE adds 160 MB RSS,
   a join and attestation story, and a Workload API socket per node; take it only when per-workload
   attestation or automatic federation is wanted.
3. Every node certificate needs a **DNS SAN** equal to the `server_name` its dialers use.
4. Federation of trust domains is the union of CA files (or `bundle set` / a `federates_with` endpoint in
   SPIRE); a federated CA rotation reaching a running node is unverified (roots read at start), so plan a
   node restart or test it.
5. A refused client sees a timeout, not a reason: `check` should read the node log (`UnknownIssuer`,
   `CertificateRequired`, `not valid for name`) and say it.

**Linking**

6. A spoke's link to the hub is `clients: [{endpoint, connection_type: peer, tls...}]`; the default `edge`
   carries no routes. The spoke dials out, so it needs no inbound port. Spoke to spoke goes through the hub.
7. The hub needs a reachable `host:port` with a certificate whose DNS SAN matches; for a laptop hub, a name and
   a firewall rule (the Operator's rule on ports beyond loopback applies to the build).
8. Reconnect is automatic (about 5 s) and sessions survive an outage; applications see timeouts and
   exhausted retries, not a "node down" event. The facilitator's `receive` and `send` tools should map both to
   "peer unreachable" with the retry hint, and set session `max_retries` and `interval` on purpose (3 at 2 s
   gave an 8 s failure).
9. The Controller (domains, star topology, segments) is the documented way to do hub and spoke at scale; it is a
   separate service and was not run. Decide whether version one uses static `peer` links (works now).
10. Sequential round trips cost about 90 ms whatever the topology; pipelining is fast. Do not design a chatty
    protocol on one session.

**Directory**

11. For a node that peers: render `registry_address`, `directory_api_address` and `directory_oci_address` as
    **routable** names, set `bootstrap_peers` with the peer id (from the other node's key), and lower
    `publication.scheduler_interval`. Expect one minute for sync and one for indexing.
12. A record is visible to the mesh only after `routing publish`; content moves only on `sync create` (pull).
    The node's "publish" and "adopt" verbs should be those two steps, not one.
13. **Check mDNS** on the target networks, and the open libp2p port: any peer with the bootstrap address joins
    and reads labels. Decide whether a private mesh needs `autosync.peerlist` or a closed network.
14. Remove a stale `daemon.pid` before start.

**MCP over HTTP**

15. The node serves **Streamable HTTP of the 2026-07-28 spec and still the 2025 shape** (the `mcp` 2.3.0 SDK
    does both), behind **HTTPS** (a reverse proxy or the library), with PRM, `401` and `403` as above, an
    audience check against the node's own URL, an `Origin` check, and no token passthrough.
16. **An authorization server is not optional** for cloud AIs: choose an external IdP, or accept static bearer
    tokens (works in Claude Code and Copilot CLI, not in a cloud AI that wants OAuth).
17. The server must be reachable from the vendor cloud; say so in `check`, and treat a laptop behind NAT as
    local-only for cloud AIs.
18. A blocking `receive` is one long POST with an SSE reply under the new spec; closing it cancels it. Keep the
    60 s block of the earlier spike.

**Packaging**

19. New pins: SPIRE 1.16.0 (two binaries, sha256 from the release API; optional), `mcp` 2.3.0 (28 wheels,
    MIT; hash-pin all), and the existing `slimctl` 3.4.6, `slim-bindings` 3.3.9, `dirctl` v1.9.1.

## Summary table

| Question | Checked | Result |
|---|---|---|
| SLIM auth modes | run | basic, jwt, static_jwt, oidc, spire (JWT-SVID), plus mTLS from files or from SPIRE; no mode named "spiffe" |
| SPIFFE ID or trust domain checked by the node | run | **no**: chain to the bundle only; an impostor signed by a trusted CA passes |
| SPIRE needed | run | no: SVID-shaped certificates from files work; SPIRE costs 65 + 98 MB and a socket |
| Federation, two trust domains | run | works as union of CAs (files) or `federatesWith` plus `bundle set` (SPIRE); needed on both sides |
| Two nodes linked, hub and spoke | run | works with `connection_type: peer`; `edge` carries no routes |
| Spoke to spoke through the hub, mTLS, two domains | run | works, 118 ms to open the session |
| Latency | run | about 90 ms sequential, no change per hop; 50 pipelined in 46 to 62 ms |
| Node goes away | run | clients reconnect in about 5 s, sessions survive, apps see timeouts; new session fails in 8 s |
| SLIM Controller, domains, segments | docs | star topology available; not run |
| Directory peering by bootstrap peer | run | works; mDNS also finds peers with no config |
| Record shared across Directories | run | labels and CID after `routing publish`; content after one-way `sync` |
| Directory sync with the facilitator's loopback config | run | does not work: `registry_address` is also the advertised address |
| MCP spec | docs | 2026-07-28: no sessions, no GET stream, OAuth 2.1 resource server with RFC 9728 |
| Python library | run | `mcp` 2.3.0, MIT; 401, 403, PRM, audience and Origin checks verified; `fastmcp` 4.2.3 Apache-2.0 not run |
| Claude Code, remote HTTP server | run and docs | works with a bearer header (called a tool); OAuth in an interactive session |
| Copilot CLI, remote HTTP server | docs | `copilot mcp add --transport http` with headers; `/mcp auth` exists |
