# packet-relay: components

The Feature's own C4 views (AOF ADR 0007: a Feature may draw itself). Each element names the file it
comes from, so the drawing can be checked against the source.

## Context

```mermaid
C4Context
  title packet-relay in its context
  Person(party, "A party", "an operator or an agent of one stack: packet-relay send, sync, status")
  Person(operator, "An operator", "an anchor: packet-relay skip, for a gap lost for good")
  System(packet-relay, "packet-relay", "Reliable, ordered, exactly-once signed packets between parties through a shared folder")
  System_Ext(sign_packet, "sign-packet", "makes and checks the packets")
  System_Ext(shared_folder, "The shared folder", "a host folder bind-mounted into dev containers, or a OneDrive folder; carries files, trusted for nothing")
  System_Ext(other_parties, "Other parties", "other stacks or machines, each with its own packet-relay and home")
  System_Ext(agentic_register, "agentic-register", "to come: the mailbox's shared threads over packet-relay")
  Rel(party, packet-relay, "sends and syncs with")
  Rel(operator, packet-relay, "skips a lost gap with")
  Rel(packet-relay, sign_packet, "signs and checks packets with")
  Rel(packet-relay, shared_folder, "writes its own subfolder of, reads the others' of")
  Rel(other_parties, shared_folder, "write their own subfolders of")
  Rel(agentic_register, packet-relay, "will carry shared threads over")
```

## Components

```mermaid
C4Component
  title packet-relay components
  Container_Boundary(packet-relay, "packet-relay") {
    Component(cli, "packet-relay command", "Python", "version, check, setup, key, send, sync, status, skip")
    Component(relay, "relay", "Python", "send; sync: acknowledgements read, removal, writing again, taking in order, acknowledging; skip")
    ComponentDb(home, "home", "named volume", "keys, members, anchors; per domain the chains, outbox, inbox, what was taken")
  }
  Rel(cli, relay, "runs")
  Rel(relay, home, "keeps its state in")
```

| Element | Source |
|---|---|
| `packet-relay` | `src/packet-relay/devcontainer-feature.json` |
| `cli` | `src/packet-relay/packetrelay/cli.py` |
| `relay` | `src/packet-relay/packetrelay/relay.py` |
| `home` | `devcontainer-feature.json`, `mounts` (`packet-relay-state-${devcontainerId}`) |
| `sign_packet` | `relay.py` (imports `signpacket`); `src/sign-packet/` |
| `shared_folder` | the `root` option; `SPEC.md`, "The folder" |
| `other_parties` | `SPEC.md`, "Terms" (a party, the members file) |
| `agentic_register` | AOF ADR 0024, decision 5; backlog item `mailbox-federation` |
| `party`, `operator` | `SPEC.md`, "Terms" |
