# ADR-0071: A facilitator node opens a port beyond loopback only by explicit configuration, and never discovers peers on the LAN

| | |
|---|---|
| **Status** | accepted (amended by [ADR 0075](0075-a-spoke-joins-through-a-join-endpoint-agents-are-bound-to-their-node-by-signed-cards-and-a-handle-can-be-qualified-by-its-node.md): decisions 1 and 4) |
| **Date** | 2026-11-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

The facilitator-agent proposal says "networking is out of scope" (section 2) and that the Feature
"must not open a network port beyond the loopback ports of its own infrastructure" (section 6).
ADR-0067 makes a node a network member, so both rules need revising. ADR-0061 does not state them
and needs no amendment. The Operator ruled on 2026-11-20 that there is no Directory auto-discovery
on the LAN (SP5). The spike found that the Directory daemon finds peers by mDNS with no
configuration, that any peer that dials the bootstrap address joins the gossip and sees labels, and
that the loopback-only configuration of 0.2.0 cannot sync at all.

## Decision

1. **A port beyond loopback opens only when configured.** Only the SLIM dataplane, the Directory's
   libp2p and OCI ports, and the MCP HTTPS port may open, each only when the node's role and its
   `mesh.yml` need it and `listen` or `http.listen` is set explicitly. Installing opens nothing. A
   `spoke` opens nothing: it dials out.
2. **`facilitator node run` and `infra up` refuse a non-loopback bind** unless `mesh.yml` exists, its
   preset allows a level above local, and the listener's authentication is neither "none" nor basic
   over plain text.
3. **The Directory's gRPC, OCI-gateway and HTTP-gateway ports stay on loopback** (8888, 5555 for
   local use, 8889).
4. **There is no auto-discovery on the LAN.** mDNS auto-peering is off by default; the first task of
   slice N3 is a switch that turns it off, and failing that the libp2p and OCI ports are firewalled
   to the listed peers only. Peers are named in configuration.
5. **One listener per trust level** (ADR-0069): a node facing an intranet and a public network does
   not share a port between them.
6. **This revises** the two written rules of facilitator-agent (sections 2 and 6) and extends
   ADR-0067. Directory sync is one way: a spoke syncs from its hub; the hub syncs from a spoke only if
   that spoke opens its OCI port to the hub (ruling BI).

## Options considered

### Option 1: explicit configuration, no discovery (chosen)

A person reading `facilitator.yml` and `mesh.yml` can say what is open and who can reach it.

### Option 2: keep the 0.2.0 rule, loopback only

Rules out any second machine, which is the point of ADR-0067.

### Option 3: let the Directory discover peers on the LAN

Zero configuration, but any host on the network that dials the bootstrap address joins the gossip.

## Consequences

- A devcontainer cannot publish a port by itself; two devcontainers reach each other over a shared
  docker network or forwarded ports, and the server image declares its ports. The Windows-to-WSL
  case is not checked.
- N3 must find the mDNS switch or add the firewall rule; a node needs routable addresses,
  `bootstrap_peers` and a shorter `publication.scheduler_interval` to sync.
- The Operator ruled the no-discovery part (SP5) and accepted the ports rule as written on 2026-11-20.

## Change log

| Date | Change |
|---|---|
| 2026-11-20 | First draft, proposed; SP5 ruled by the Operator, the rest awaiting confirmation. |
| 2026-11-20 | Accepted by the Operator. |
- 2026-11-23: decisions 1 and 4 amended by ADR 0075 (rulings on slice N3).
