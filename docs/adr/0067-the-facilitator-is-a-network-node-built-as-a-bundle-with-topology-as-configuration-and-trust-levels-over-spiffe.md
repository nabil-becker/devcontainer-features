# ADR-0067: The facilitator is a network node, shipped as a built bundle, with topology as configuration and trust levels over SPIFFE

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

Facilitator 0.2.0 (ADR-0061, ADR-0066) runs on one machine: the Directory daemon and the SLIM node on
loopback, agents and a person's CLI session attached over MCP. The Operator wants the facilitator to
work across machines and for AIs that cannot run a program locally. The host put five calls on the
decisions board (Z1 to Z5); the Operator ruled on 2026-11-20. The forces:

- the install has to be the same on every architecture and not depend on a Feature build per host;
- a local CLI can hold its own signing key, a cloud AI cannot;
- an endpoint that faces the internet needs a stricter default than one on loopback;
- the topology (a hub, peers) should not need a code change to switch.

## Decision

1. **Z1, the base package is a built bundle** per architecture, made in CI by the shared install
   script. DSC may wrap it later for Windows hosts.
2. **Z2, agents reach a node in both ways, with the same tools.** Local CLIs (Claude Code, Copilot)
   use the thin client plus SLIM, so the key stays with the agent. Cloud AIs, and anything that only
   speaks remote MCP, use MCP over HTTP (Streamable HTTP transport, OAuth for sign-in). For those
   clients the node signs the message, and the record says who sent it, over HTTP, authenticated by
   OAuth, which is weaker proof than a key the agent holds.
3. **Z3, the topology is configuration.** Every install is a node with a role and either peers or a
   primary. Hub-and-spoke comes first and peer-to-peer next, with no code change to switch.
4. **Z4, a mesh with trust levels:** local, private and public. Local and private are built first,
   public last. A client that arrives over MCP over HTTP gets the public level by default unless a
   specific one is marked trusted.
5. **Z5, the mesh is configured with SPIFFE identities and one `mesh.yml`** (one trust file), with
   three presets: solo, team and open.

The work follows the process: a proposal `facilitator-node` with these rulings and an architecture
review, a spike of SLIM's SPIFFE support (and the Directory and SLIM linking across two containers),
then slices: the bundle and server image, hub-and-spoke with local and private trust, MCP over HTTP,
then public trust and peer-to-peer.

## Options considered

### Option 1: a built bundle, both connection routes, configured topology, trust levels over SPIFFE (chosen)

One artifact per architecture, one set of tools however an agent connects, and the topology and the
trust live in one file.

### Option 2: the thin client plus SLIM only (the host's first Z2 recommendation)

Keeps every key with the agent, but leaves out cloud AIs; changed when the Operator asked whether
MCP over HTTP would let any MCP-capable AI join.

### Option 3: MCP over HTTP only

Simplest for clients, but every agent's signature would be made by the node, losing the stronger proof
a local CLI can give.

### Option 4: topology fixed in code, or no trust levels

A hub or peer-to-peer built in would need a code change to switch; one trust level would either
expose the public endpoint or lock out private peers.

## Consequences

- Cloud AIs can join, at the public trust level and with weaker proof of the sender.
- A built bundle and a server image become new CI outputs.
- A SLIM and SPIFFE spike comes before any build; its findings may reopen Z5.
- The facilitator Feature, its NOTES and the standing architecture documents (ADR-0060) need the
  deltas when the proposal is written.

## Change log

| Date | Change |
|---|---|
| 2026-11-20 | First draft, accepted on the Operator's rulings of the same day. |
