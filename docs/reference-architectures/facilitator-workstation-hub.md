# Facilitator: a hub on the workstation for local devcontainers

One hub node on the engineer's own machine, and the workstation's devcontainers as its spokes, so agents in
different devcontainers (this repository's, a consumer's, a throwaway one) can address each other by `@handle`. The
hub runs beside the devcontainers, in Rancher Desktop's Kubernetes or in Docker Compose; it issues the certificates
itself by default and needs no OpenBao. The design is the approved proposal
[facilitator-node](../proposals/facilitator-node.md) (hub and spoke, section 4; rulings K2 to K5) and ADRs
[0067](../adr/0067-the-facilitator-is-a-network-node-built-as-a-bundle-with-topology-as-configuration-and-trust-levels-over-spiffe.md),
[0069](../adr/0069-node-certificates-are-issued-by-an-openbao-pki-per-trust-domain-and-two-locks-keep-each-trust-level-apart.md),
[0075](../adr/0075-a-spoke-joins-through-a-join-endpoint-agents-are-bound-to-their-node-by-signed-cards-and-a-handle-can-be-qualified-by-its-node.md);
the hub's issuer is ADR 0078 (on its own branch, not yet on `main`).

## Who it is for, and when to use it

Use it when one person works in two or more devcontainers on one machine and wants their agents to talk across them,
or wants an agent they do not fully trust to live in a devcontainer of its own and still be reachable. Each
devcontainer stays a complete node (a spoke is a node): when the hub is down its agents keep working locally, and
only talk across containers stops.

Not for: one devcontainer (that is [solo](facilitator-solo.md)), a team (that is a hub on a server with its own
OpenBao: [a team intranet hub](facilitator-team-hub.md)), or an engine whose containers cannot reach each other (the
case of Windows with `wslc` is not checked).

## What exists today

Dated 2026-11-23. The current release is `facilitator` 0.5.0; the server image is
`ghcr.io/nabil-becker/facilitator-node:0.5.0`.

| Piece | State | Version |
| --- | --- | --- |
| Hub and spoke, `mesh.yml`, join token, mutual TLS, the two locks, `check`, `explain`, qualified handles (`@b1.spoke-b`) | built, released | 0.4.0 |
| The hub as the node image in **Docker Compose** with an OpenBao beside it (`bundles/facilitator/compose.yml`) | built, released: the sample runs the hub, OpenBao and one spoke on an internal network that publishes nothing | image 0.5.0 |
| The hub's certificates from an **OpenBao PKI**, unsealed by hand after each start | built, released | 0.4.0 |
| A **built-in issuer** for a hub (no OpenBao, no unseal), `facilitator node issuer migrate` and `export-root` | planned; the local issuer exists for peers in 0.6.0 (being built) | rulings K3, K4; ADR 0078 |
| The CA key in an **ssh-agent** (`node.issuer.ssh_agent`), a file in the volume as the last resort | planned; the spike showed it works for ed25519 (2026-11-23) | ruling K5; ADR 0078 |
| The hub on **Kubernetes**: a kustomize base (StatefulSet, volume, ConfigMap, Service), an overlay for Rancher Desktop, a test in a throwaway cluster | planned (backlog `hub-on-kubernetes`); a Helm chart later, with a `helm` Feature that does not exist yet | ruling K2 |
| A devcontainer reaching a hub that runs next to it, on a workstation | **not checked** end to end: the sample compose puts its own spoke in the hub's network | |

## Diagram

```text
 WORKSTATION (host)
 +-----------------------------------------------------------------------------------------------------+
 | launcher (task dc:up, per repository)         the person's terminals                                |
 |                                                                                                     |
 |  RANCHER DESKTOP  (one engine, one Kubernetes)                                                      |
 |  +---------------------------------------------------------+     +---------------------------+     |
 |  | HUB  (planned: kustomize base; today: compose)          |     | devcontainer A (repo 1)   |     |
 |  |  facilitator-node image 0.5.0, role hub, preset team    |<----| spoke laptop-nb-a         |     |
 |  |  one StatefulSet / one container, volume hub-state (4)  | SLIM| facilitator Feature       |     |
 |  |  Directory + SLIM embedded, loopback only               | mTLS| claude, copilot, model    |     |
 |  |  SLIM private listener 46358   join endpoint 46359      |     +---------------------------+     |
 |  |  issuer: built-in CA (planned) | ssh-agent (planned)    |     +---------------------------+     |
 |  |          | OpenBao PKI (built; a second container,      |<----| devcontainer B (repo 2)   |     |
 |  |            sealed until you unseal it)                  |     | spoke laptop-nb-b         |     |
 |  |  mesh.yml in a ConfigMap (tier 1: the manifests)        |     +---------------------------+     |
 |  +---------------------------------------------------------+                                       |
 |        |  CA key (planned tier): a DEDICATED ssh-agent holding only that key                        |
 |        v                                                                                           |
 |  NOTHING published beyond the machine: the hub's ports reach the spokes only                       |
 +-----------------------------------------------------------------------------------------------------+
   external: GitHub Releases (the node image and the bundle, at pull and build time only)
```

## `devcontainer.json`

A spoke is a devcontainer with the Feature and its own `mesh.yml`, which `facilitator node join` writes. Each
spoke needs the hub's DNS name to resolve to the hub (the name in the hub's certificate is the `server_name` its
spokes dial); `--add-host` with `host-gateway` points it at the machine's published port. That line is not run
end to end (see "What exists today").

```jsonc
{
  "name": "repo-1-spoke",
  "image": "mcr.microsoft.com/devcontainers/base:debian",
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {
      "participants": true
    },
    "ghcr.io/nabil-becker/devcontainer-features/facilitator:0": {
      "bundleVersion": "0.5.0"
    }
  },
  // The hub's name as its certificate carries it; not run end to end, not checked by the tool.
  "runArgs": ["--add-host=hub.workstation.example:host-gateway"],
  "containerEnv": {
    // A spoke's mesh.yml is written by `node join`, so it lives in the spoke's own volume.
    "FACILITATOR_MESH_FILE": "/var/lib/devcontainer-features/facilitator/mesh.yml"
  },
  "remoteUser": "vscode"
}
```

The engineer's own tooling to render and check the hub's manifests is a second, planned fragment. It names a `helm`
Feature that does not exist, so `task architectures:check` keeps it failing until it does.

```jsonc planned
{
  "name": "hub-manifests",
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/kustomize:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/kubeconform:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/helm:1": {}
  }
}
```

The hub's `mesh.yml` (a ConfigMap in the planned base; a mounted file in the compose sample, which is
`bundles/facilitator/hub/mesh.yml`). The `issuer` block with `openbao` is built; leaving it out, and `ssh_agent`, are
planned (K3, K5):

```yaml
preset: team
role: hub
node:
  id: hub-1
  name: hub.workstation.example       # the DNS name in the certificate: the spokes' server_name
  listen: {private: 0.0.0.0:46358}    # lock one: the private level's listener
  join: 0.0.0.0:46359                 # open only while a join token is live
  issuer:
    domain: workstation.example
    # built today: openbao: http://openbao:8200, mount: pki-corp, role: node, kv: secret, approle: <file>
    # planned: no openbao key = the hub's own CA, no unseal;  ssh_agent: {socket: <path>, key: <fingerprint>}
trust:
  workstation.example: private
```

Then, in a plain terminal and never in an agent's job: `facilitator node invite` on the hub (a token, 15 minutes,
single use), `facilitator node join --token <token>` on each spoke, restart the spoke, `facilitator check`.

## Data and its storage tier

| Data | Where it lives | Tier | A rebuild | Losing the machine |
| --- | --- | --- | --- | --- |
| The hub's manifests: `mesh.yml`, `facilitator.yml`, `participants.yml`, the kustomize base and overlay | the repository | 1 | untouched | kept once pushed |
| A spoke's `mesh.yml`, its certificate (24 h) and its key (mode 600, a file: SLIM reads it from a file) | the spoke's volume `facilitator-state-${devcontainerId}` | 4 | kept | join again |
| The hub's roster (every admitted card) | the hub's volume; today also backed up into OpenBao's KV (`secret/facilitator/mesh/roster`) | 4 | kept | `facilitator node restore-roster` from OpenBao's snapshot (today); built-in: from the volume only (planned) |
| The domain's CA key, built-in issuer (planned) | the hub's volume, mode 600, a last resort that `check` warns about | 4 | kept | **lost with the volume**: every spoke joins again |
| The domain's CA key, ssh-agent tier (planned) | a dedicated agent's memory; the key's own backup is yours | custody, outside the tiers | untouched | load the key again; spokes need not re-join |
| The domain's PKI, OpenBao tier (built) | OpenBao's raft volume `openbao-data`; the root kept offline | 4 under ADR 0048's bounded loss; the root off the machine | kept | restore the snapshot, unseal with the shares |
| OpenBao's unseal shares (OpenBao tier only) | the person's password manager and paper | off the machine | untouched | untouched |
| A join token | shown once, valid 15 minutes, single use | none | not kept | not kept |
| Conversations, one replica per member node | each node's own volume | 4 | kept | lost with that node |

## On the workstation, and in the container

| On the workstation (host) | In the container |
| --- | --- |
| Rancher Desktop (or Docker Compose): the hub and, with OpenBao, its sealed server; their volumes | a spoke: the Feature, the node, the participants, `node join`, `check` |
| the person's custody of the OpenBao shares, or of the CA key's agent | the hub's node (image): Directory, SLIM, `node run`; the issuer; the join endpoint |
| the person's `node invite` and `node revoke` in a terminal | nothing of the above runs inside an agent's job: those commands refuse there |
| git: the host commits the manifests | `facilitator explain`, `who`, `verify` |

## Best practices

- **Start with the OpenBao-free hub when it exists; until then use the sample compose and accept the unseal.** An
  OpenBao PKI is unsealed by hand after each start and issues nothing while sealed; the 24 h certificates give you a
  day's margin, not more.
- **Give the CA key a dedicated agent or OpenBao, never your own ssh-agent.** An agent signs anything for a key it holds,
  so a CA key in the agent you also use for `ssh` is a CA to whoever reaches that socket (the spike's note).
- **Use ed25519 for the CA key.** RSA and ECDSA keys in an agent hash first and a FIDO key cannot sign the bytes; only
  ed25519 (or a hardware key doing raw EdDSA) is "sign these bytes".
- **Publish nothing from the hub beyond the machine.** The sample compose runs on an internal network that publishes
  nothing; a hub opens its SLIM listener and join endpoint only on the network it is given (ADR 0071).
- **Make each spoke `expose` only what it means to share.** The default is `"*": local`: an agent opts outward, never
  inward; a local-only agent is unlisted and answers as an unknown handle.
- **Use qualified handles when two spokes have the same agent name.** `@b1.spoke-b`; a bare `@b1` that names two is refused.
- **Keep the hub's manifests in git and the spokes' joins out of it.** A `mesh.yml` is a reviewed change; a join token is
  never written down.
- **Run `facilitator check` on the hub and on a spoke after every start.** It names the certificate, the open ports, the
  roster and any TLS refusal.

## Anti-patterns

### W1. A CA key in the agent you also use for ssh

- **Don't:** load the hub's CA key into the ssh-agent that holds your own keys.
- **Why:** the ssh-agent spike (2026-11-23, [ssh-agent-ca](../spikes/2026-11-23-ssh-agent-ca.md)): the agent never says
  what it signs, and it signs anything for a key it holds; the CA key is then a CA to whoever can reach the socket.
- **Instead:** a dedicated agent with its own socket and only that key, or OpenBao.
- **Caught by:** nothing yet; ruling K5 and ADR 0078 say "the agent should hold nothing else".

### W2. A name constraint on the CA by URI

- **Don't:** make the hub's CA by hand with a URI name constraint (`permitted;URI:<domain>`) to keep it to the domain's
  SPIFFE IDs.
- **Why:** the same spike: SLIM's TLS stack (rustls-webpki) refuses every certificate from a CA that carries a URI
  name constraint (`NameConstraintViolation`), with an agent-signed CA and a plain `openssl` one alike.
- **Instead:** a DNS constraint only; lock two (the application's check of the domain in every card and entry) keeps the
  domain.
- **Caught by:** the spike; the built-in issuer's change (ruling K3's note) is planned.

### W3. Directory peering on a shared segment

- **Don't:** set `node.directory.peering: true` on the hub, or run the hub's containers on a network other Directory
  daemons share, without `node.directory.firewall`.
- **Why:** ruling H2 (2026-11-21, ADR 0075): dirctl 1.9.1 has no switch for mDNS and the Directory finds peers by it,
  including a daemon bound to loopback; its OCI registry also accepts an anonymous push.
- **Instead:** leave peering `false`: the mesh learns another node's agents from its signed card, not from the
  Directory. With peering, `directory.firewall: auto` (UDP 5353 dropped) or `external`.
- **Caught by:** the Directory refuses to start without a firewall setting when peering is on.

### W4. Trusting the handshake alone

- **Don't:** treat a valid certificate on the SLIM link as proof of who a node is, or put two levels' domains in one CA
  bundle.
- **Why:** the SLIM spike of 2026-11-21 ([slim-spiffe](../spikes/2026-11-21-slim-spiffe.md)): SLIM checks only that a
  certificate chains to a CA the listener holds, never the SPIFFE ID or the domain; an impostor ID signed by a
  trusted CA was accepted.
- **Instead:** keep both locks: one listener per level with only that level's CA bundle, and the application's check
  of every card and entry against `mesh.yml`.
- **Caught by:** the N3 exit test (an impostor ID is refused), `check` ("lock two" refusals).

### W5. One user for every agent, on a hub you share

- **Don't:** run an agent you do not trust as a participant in a spoke that holds other agents' tokens.
- **Why:** the Operator's question of 2026-11-23: every participant shares one Linux user, so a process can read
  another's token file; backlog `per-identity-users`.
- **Instead:** that agent gets its own devcontainer, its own spoke, and `expose` limited to what it should reach.
- **Caught by:** nothing yet.
