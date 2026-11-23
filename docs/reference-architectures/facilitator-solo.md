# Facilitator, solo: one devcontainer, a standalone node

Agents of any vendor and the person who works with them, on one machine, in one devcontainer, talking through one
node that opens nothing. The facilitator routes the messages, signs each one and keeps the record; the AGNTCY
Directory and a SLIM node run beside it on loopback. The design is the approved proposal
[facilitator-node](../proposals/facilitator-node.md) and [facilitator-agent](../proposals/facilitator-agent.md)
(ADR [0061](../adr/0061-the-facilitator-is-built-on-agntcy-first-with-the-mcp-split-in-two-and-the-agents-feature-moves-into-a-shared-participant-component.md),
[0066](../adr/0066-the-facilitator-is-reached-only-through-mcp-and-only-a-person-s-continue-resets-the-hop-count.md)).

## Who it is for, and when to use it

Use it when an engineer, or a consumer's maintainer, wants Claude Code, GitHub Copilot CLI and a local model to
hand work to each other in one devcontainer, without working out how the pieces combine: one Feature, one list of
participants (`participants.yml`), one shared MCP entry for every agent, and the person asking from their own Claude
Code session. Nothing is open to the network: no `mesh.yml` means `preset: solo`, `role: standalone`, every port on
loopback.

Not for: agents in two devcontainers or on two machines (that is a hub and spokes: see
[a hub on the workstation](facilitator-workstation-hub.md) and [a team intranet hub](facilitator-team-hub.md)), a
cloud AI that wants to reach the node (it needs a public address; see
[peer to peer and public](facilitator-peer-and-public.md)), or agents you do not trust. Every participant runs as
the same Linux user in the container, so the container is the trust boundary.

## What exists today

Dated 2026-11-23. The current release is `facilitator` 0.5.0 (the server image `ghcr.io/nabil-becker/facilitator-node:0.5.0`
is not used here).

| Piece | State | Version |
| --- | --- | --- |
| The node: facilitator application, Directory, SLIM, ssh-agent, started at container start | built, released | 0.2.0 and later (MCP only, 0.2.0; the bundle, 0.3.0; the published bundle, 0.3.1) |
| `participants.yml`, the one shared MCP entry (`FACILITATOR_HANDLE`, `FACILITATOR_TOKEN`), the person's `say`, `mail`, `transcript`, `continue`, `who` | built, released | 0.2.0 |
| Claude Code and Copilot CLI as participants (`participants` option of `claude-code` and `copilot`), a local model through `facilitator model` | built, released | `claude-code` 1.14.1, `copilot` 0.2.1 |
| The record: signed packets in a `conversation` register, `verify` back to the person | built, released | 0.1.0 and later |
| MCP over HTTP for CLIs | built, released, **off** and refused under solo | 0.5.0 |
| Keys in OpenBao instead of the fallback files in the volume | built, optional | `openbao` 1.6.0 |

## Diagram

```text
 WORKSTATION (host)                 CONTAINER ENGINE
 +---------------------------+      |
 | launcher only (task dc:up)|----->|
 | the person's terminal     |      v
 +---------------------------+   +-------------------------------------------------------------------------+
                                 | DEVCONTAINER  (remote user vscode)                                      |
  git remote <-- push/pull ----> |  /workspaces/repo   .devcontainer/participants.yml, facilitator.yml (1) |
                                 |                                                                         |
                                 |  person's Claude Code ---stdio--+    FACILITATOR_HANDLE=you             |
                                 |  claude (participant) ---stdio--+--> facilitator mcp  (ONE shared entry)|
                                 |  copilot (participant) --stdio--+        |                              |
                                 |  local model --- facilitator model       v                              |
                                 |      |  /v1/chat/completions   +----------------------------------+     |
                                 |      v                         | facilitator application          |     |
  LOCAL MODEL SERVER  <----------|--  (Ollama, LM Studio, ...)    | intake > guard > router >        |     |
  (outside the container;        |                                | dispatcher > collector           |     |
   a person or a service)        |                                | signer (sign-packet)             |     |
                                 |                                | record (register-engine)         |     |
                                 |                                +--+------------------+------------+     |
                                 |   loopback only:  Directory (dirctl 8888, 5555, 8999, 8889)             |
                                 |                   SLIM node 46357      ssh-agent (the node's own)       |
                                 |                                                                         |
                                 |  volume facilitator-state-${devcontainerId} (tier 4):                   |
                                 |    conversations, keys/ (or OpenBao), tokens/, mail/, dir/              |
                                 |  /opt/facilitator   the node bundle (image layer, from the release)     |
                                 +-------------------------------------------------------------------------+
   NOTHING open beyond loopback.  OpenBao (optional): the keys, SLIM's secrets (client mode, a server of yours)
   GitHub Releases: facilitator-bundle-v0.5.0, downloaded and checked at image build only
```

(1) tier 1: in git, reviewed.

## `devcontainer.json`

The agents' own CLIs come with their Features; `participants` installs the participant component, which starts the
resident ones. The facilitator never starts, stops or configures a participant (NFR-13): the harness does.

```jsonc
{
  "name": "facilitator-solo",
  "image": "mcr.microsoft.com/devcontainers/base:debian",
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {
      "participants": true
    },
    "ghcr.io/nabil-becker/devcontainer-features/copilot:0": {
      // attach: facilitator registers the shared MCP entry through `copilot mcp add`, no token in it.
      "participants": true,
      "attach": "facilitator"
    },
    "ghcr.io/nabil-becker/devcontainer-features/facilitator:0": {
      // Pin the bundle: a version with no pinned bundle builds it from source (about 250 MB of downloads).
      "bundleVersion": "0.5.0",
      "hopLimit": "6",
      "messageBudget": "40"
    }
  },
  "remoteUser": "vscode"
}
```

Then, in the repository, the list of participants and the people:

```yaml
# .devcontainer/participants.yml
participants:
  - name: reviewer                 # the handle: lowercase letters, digits, - and _
    cli: claude
    kind: resident
    attachment: mcp
  - name: pilot
    cli: copilot                   # on demand: Copilot has no local background mode
    kind: on-demand
  - name: jester
    cli: openai-compatible         # a local model, through `facilitator model`
    kind: resident
    definition: personas/jester.md
# .devcontainer/facilitator.yml
facilitator:
  humans: [you]                    # each person attaches their own session with their own handle and token
```

Once, in a plain terminal: `facilitator register --all` (keys, tokens, the OASF records), then
`facilitator snippet you` and run the `claude mcp add --scope user facilitator -- facilitator mcp` it prints: the same
entry serves every agent and names no handle. Start your own session after the container, with your handle and token in
its environment: `FACILITATOR_HANDLE=you FACILITATOR_TOKEN="$(cat $FACILITATOR_HOME/tokens/you)" claude`. Then ask:
"ask @reviewer to look at this and tell @jester".

## Data and its storage tier

Tiers as in [ADR 0045](../adr/0045-four-storage-tiers-govern-where-data-lives-and-a-machine-loss-must-lose-nothing.md):
1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

| Data | Where it lives | Tier | A rebuild | Losing the machine |
| --- | --- | --- | --- | --- |
| `participants.yml`, `facilitator.yml`, `mesh.yml` (if any), personas | the repository (`.devcontainer/`, `personas/`) | 1 | untouched | kept once pushed |
| Conversations (signed registers), the roster, attachment times | volume `facilitator-state-${devcontainerId}` at `/var/lib/devcontainer-features/facilitator` | 4 | kept | **lost**: copy what matters (a transcript, a decision) into a note in git |
| Identity keys | OpenBao `facilitator/keys/<handle>`; the fallback: `keys/<handle>` (mode 600) in the volume | none (OpenBao); 4 (fallback) | kept | with OpenBao as it is; the fallback is lost and the identities are made again |
| Participant and person tokens | `tokens/<handle>` (mode 600) in the volume, made again at every start | 4 | made again | made again |
| What each person has read | `mail/<handle>.json`, `.notice` in the volume | 4 | kept | lost, harmless |
| The Directory's records and node key | `dir/` in the volume | 4 | kept | rebuilt by `register` |
| The node bundle | `/opt/facilitator` in the image layer | none | rebuilt from the release | rebuilt |
| A Claude Code or Copilot login and the MCP entry | each CLI's own volume (`claude-code`, `copilot`) | 4 | kept | log in again, run the entry's command again |
| The local model's weights | the model server's own disk, outside the container | not governed here | untouched | the server's own |

A message written by a person or an agent is also in the agent's own transcript (the CLI's), which is not the
facilitator's record.

## On the workstation, and in the container

| On the workstation (host) | In the container |
| --- | --- |
| the launcher: `task dc:up`, `exec`, `rebuild` | the node (`facilitator infra up` at start), the Directory, SLIM, the node's ssh-agent |
| the local model server, if you run one (reached from the container by its address) | `facilitator mcp` for every participant and for the person's session |
| the person's terminal | the participants, started by their harness, never by the Feature |
| git: the host commits `participants.yml` | `facilitator register`, `check`, `verify`, `snippet`, the `facilitator:*` tasks |

## Best practices

- **List every participant in `participants.yml` and give each its own handle and token.** A process becomes a
  participant only when it is listed (a reviewed change) and its MCP entry carries its handle and token; without both,
  `facilitator mcp` refuses it. Only listed handles get a token.
- **Put the handle and token in the environment, never in the MCP entry.** The one shared entry names no handle; tokens
  are made again at each container start, so start the session after the container.
- **One person's session, one handle.** A person's messages count as hops like any other; only `continue` resets
  them. With the default of 6 you get three exchanges with one agent before you are asked to continue.
- **Run `facilitator check` after a rebuild and read it.** One line per part; exit 0 when ready; it says why a part
  refused (a bundle built from source, a port not on loopback).
- **Pin `bundleVersion` to a released bundle and rebuild after an upgrade.** The Feature installs
  `facilitator-bundle-v<version>`, checked against the SHA-256 pinned in `digests.txt`.
- **Keep the keys in OpenBao when you have a server.** Client mode against a central server leaves the identities
  outside the volume (see [secrets with OpenBao](secrets-with-openbao.md)); the fallback files are tier 4.
- **Treat the record as tier 4.** Conversations are rebuildable only in the sense that they are lost; keep what matters
  in git by hand.
- **Leave `hopLimit`, `messageBudget` and `rateLimit` at their defaults until a conversation needs more**; a
  conversation that pauses is the limit working.

## Anti-patterns

### F1. An agent you do not trust, in the same node

- **Don't:** list an agent you do not trust as a participant of the node that holds the others' tokens.
- **Why:** the Operator's question of 2026-11-23: every participant runs as the same Linux user, so a process that is
  malicious on purpose can read another participant's token file and write as it.
- **Instead:** run the untrusted agent in its own devcontainer, as its own node, and let it in over a hub at the
  private level, or over HTTP at the public one (see [a hub on the workstation](facilitator-workstation-hub.md)).
- **Caught by:** nothing yet; the backlog item `per-identity-users` (one Linux user per participant) closes it, and the
  NOTES' Trust section states the caveat.

### F2. A devcontainer on the host network

- **Don't:** run the node's container with `--network host` or on a docker network shared with other Directory
  daemons and expect it to stay private.
- **Why:** ruling H2 (2026-11-21, ADR [0075](../adr/0075-a-spoke-joins-through-a-join-endpoint-agents-are-bound-to-their-node-by-signed-cards-and-a-handle-can-be-qualified-by-its-node.md)):
  dirctl 1.9.1 has no switch for mDNS, and in the slice N3 tests three daemons found each other on one network
  segment, including one whose libp2p was bound to loopback; this holds for a standalone node too.
- **Instead:** the default bridge network of one devcontainer; leave `node.directory.peering` at `false`.
- **Caught by:** nothing yet; an upstream issue asks for an mDNS switch.

### F3. Installing a Feature version before its bundle is published

- **Don't:** pin a `facilitator` version, or a `bundleVersion`, whose bundle release has not been published and pinned.
- **Why:** facilitator 0.3.0 was published before its bundle, so every install built the bundle from source (about
  250 MB of downloads each time); 0.3.1 pinned the release (PR #217).
- **Instead:** use the current release with its default `bundleVersion`; the release sequence publishes the bundle,
  pins it in `digests.txt`, then the Feature.
- **Caught by:** `facilitator check` and `version` name the bundle in use; `task bundle:check` for the script's copy.

### F4. Turning the HTTP endpoint on under solo

- **Don't:** set `facilitator.http.listen` to reach the node from outside while the node has no `mesh.yml`.
- **Why:** ADR [0076](../adr/0076-an-http-client-may-begin-a-conversation-under-a-persons-approval-and-public-under-team-reaches-only-a-nodes-own-http-clients.md)
  and 0.5.0: the endpoint is off by default and refused under `preset: solo`, because a node with no `mesh.yml` has
  said nothing about who may reach it.
- **Instead:** write a `mesh.yml` with `preset: team` first, as in [a team intranet hub](facilitator-team-hub.md).
- **Caught by:** `facilitator check` says why the endpoint refuses.
