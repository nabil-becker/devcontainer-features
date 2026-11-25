
# facilitator (conversations between agents of any vendor, on AGNTCY) (facilitator)

The communication layer between agents of any vendor running in the devcontainer: an MCP server each participant's CLI starts (receive, reply, say, who) and a person's own Claude Code or Copilot session attaches to (say, mail, transcript, continue, who), one shared entry with the handle from FACILITATOR_HANDLE, deterministic routing by @handle with hop, budget and rate limits, every message a sign-packet packet in a register-engine conversation register, verified back to the human who began it. Installs the facilitator node bundle (its own CPython, dirctl, slimctl and the application, checksummed; the same bundle as the server image) and runs the AGNTCY Agent Directory and a SLIM node on loopback, started as infrastructure (mode node), or only the thin client (mode leaf); never starts, stops or configures a participant. A node is standalone (nothing open) unless its mesh.yml (FACILITATOR_MESH_FILE) makes it a hub or a spoke: nodes link over SLIM with mutual TLS, certificates from an OpenBao PKI per trust domain, a listener per trust level and the application's SPIFFE ID check (local and private trust; join tokens, revoke). Serves its MCP tools over HTTP to CLIs with static bearer tokens and to cloud AIs with OAuth 2.1 access tokens (facilitator.http.listen in facilitator.yml; off by default, refused under the preset solo; the node is a resource server only: it accepts tokens from the issuers in facilitator.http.issuers and publishes the protected-resource metadata; a person approves each client; the node signs for it and every packet says so) and includes a local-model wrapper for any OpenAI-compatible endpoint and a turn hook line for Claude Code ('Facilitator: N new messages').

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/facilitator:0": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under facilitator: in a root Taskfile that includes /usr/local/share/go-task/features.yml (the go-task Feature). | boolean | true |
| backend | What carries the directory and delivery: agntcy (the AGNTCY Agent Directory and SLIM). lean (packet-relay) is refused in this version: not yet, slice 5. FACILITATOR_BACKEND overrides. | string | agntcy |
| mode | node (the default): the whole bundle, and the Directory, the SLIM node and the facilitator's ssh-agent run here (autostart). leaf: the thin client only (facilitator mcp and what it needs; no slimctl): no daemon is started, infra up and node run are refused; a leaf reaching a node over the network is not built yet (slice N3 built hubs and spokes). FACILITATOR_MODE. | string | node |
| bundleVersion | The facilitator node bundle to install (a release asset of this repository, facilitator-bundle-v<version>), verified against the SHA-256 pinned in digests.txt. latest means the bundle this Feature version was made with (0.8.0). With no pin for it, the bundle is built from the Feature's own source, every upstream download checked against the SHA-256 pinned in bundle-build.sh. | string | 0.8.0 |
| dirVersion | Deprecated in 0.3.0 (removed in 1.0.0): use bundleVersion. The bundle fixes dirctl's version (1.9.1); 1.9.1 or latest are accepted, with a deprecation line from install, version and check, and any other version is refused. | string | - |
| slimVersion | Deprecated in 0.3.0 (removed in 1.0.0): use bundleVersion. The bundle fixes slimctl's version (3.4.6); 3.4.6 or latest are accepted, with a deprecation line from install, version and check, and any other version is refused. | string | - |
| hopLimit | Hops since the message that began the chain (a person's later messages count too) before the conversation pauses; a person's continue resumes it. The default of the local and private trust levels; mesh.yml limits override it per level. FACILITATOR_HOP_LIMIT. | string | 6 |
| messageBudget | Messages a conversation may hold between two continue before participants' messages are held. FACILITATOR_MESSAGE_BUDGET. | string | 40 |
| rateLimit | Messages a participant may write in a minute; one more is refused. FACILITATOR_RATE_LIMIT. | string | 10 |
| receiveWaitSeconds | How long the MCP tool receive blocks when no wait_seconds is given. FACILITATOR_RECEIVE_WAIT_SECONDS. | string | 300 |
| staleSeconds | After this long without a receive a participant counts as not attached: its messages wait, and the sender is told. FACILITATOR_STALE_SECONDS. | string | 900 |
| facilitatorBudget | Model calls the facilitator application may make per conversation. Read and shown; no model is called before slice 6. FACILITATOR_BUDGET. | string | 20 |
| identity | Also run AGNTCY Identity (needs Docker). Refused in this version when true: not yet, slice 7. | boolean | false |
| autostart | postStartCommand starts the infrastructure (facilitator infra up: the Directory, the SLIM node, the facilitator's ssh-agent), never fatally; nothing in mode leaf. Participants are never started. FACILITATOR_AUTOSTART. | boolean | true |
| dirOnlineCheck | Check each pushed agent record against the online OASF schema server (schema.oasf.outshift.com); off, records are checked offline (the Directory's policy.operations: []). FACILITATOR_DIR_ONLINE_CHECK. | boolean | false |

## Trust: how it is done and kept

- **Levels.** `local` (this machine), `private` (your intranet domains) and `public` (named nodes you do not run): policy
  profiles in `mesh.yml`; a trust domain maps to one level, a domain not listed is refused, not public. The preset
  (`solo`, `team`, `open`) is the ceiling.
- **Getting in, per level.** local: itself. private: a single-use join token (15 min) from a hub, or a pairing token between
  peers; the token carries the hash of the issuer's CA bundle (no trust on first use). public: the requester's key plus a
  person's `node approve` (signed audit entry); nothing is issued before that.
- **Two locks on every message.** Lock one: each level has its own SLIM listener whose client CA holds only that level's
  domains. Lock two: the application checks the SPIFFE ID of every signed message against `mesh.yml` (the ID's domain is the
  domain whose CA signed it, the domain is trusted at a level within the preset, the node is not revoked), and takes a
  packet's identity from its signer's key in an admitted card.
- **Who issues.** A hub issues its domain's certificates itself by default (the **built-in CA**: nothing to unseal), or from
  an OpenBao PKI or an ssh-agent when `mesh.yml` names one; the tiers and what each protects are in
  [Hub on Kubernetes and the issuer tiers](#hub-on-kubernetes-and-the-issuer-tiers-slice-hub-on-kubernetes). The CA is
  constrained to DNS names only (SLIM refuses a URI constraint); lock two keeps the SPIFFE ID's domain.
- **Lifetimes and renewal.** Certificates last 24 h (local, private) and 1 h (public), renewed at half life while the issuer
  allows it; short lifetimes are the revocation, because SLIM checks no revocation list.
- **Revoke and rotation.** `node revoke`: no renewal, lock two refuses the node at once, its card is dropped, and the mesh's
  SLIM secret rotates to the nodes that remain. What it already holds is not recalled.
- **Who restricts what.** The receiving node enforces everything from its own `mesh.yml` (a peer's claim about its level,
  limits or exposure is never believed); the sender applies the same rules as a courtesy. `expose` says how far an agent may
  be reached; `limits` per level bound hops, budget, rate, size, copy and approval.

- **Who can use a node locally.** A process becomes a participant only when (1) it is listed in `participants.yml` (a
  reviewed repository change; only listed handles get a token, made at container start) and (2) its MCP entry carries its
  handle and token (`FACILITATOR_HANDLE`, `FACILITATOR_TOKEN`; the claude-code `participants` option wires listed agents
  only). Without both, `facilitator mcp` refuses it. The HTTP endpoint is off by default and needs a person-made bearer
  token plus approval. Caveat: every participant runs as the same Linux user in the container, so a process that is
  malicious on purpose can read another's token file; the container is the trust boundary (run an untrusted agent in its
  own node and let it in at private or public); per-agent Linux users (backlog `per-identity-users`) close it.

Detail: [A hub and its spokes](#a-hub-and-its-spokes-slice-n3), [Identity, and the two locks](#identity-and-the-two-locks),
[Peer to peer and the public level](#peer-to-peer-and-the-public-level-slice-n5a); the proposal's
[section 5](../../docs/proposals/facilitator-node.md#5-identity-spiffe-for-nodes-agntcy-identity-for-agent-badges) and its
rulings; ADR-0069, ADR-0075, ADR-0076; [data flows](../../docs/architecture/data-flows.md) and the trust records in the
[data inventory](../../docs/architecture/data-inventory.md).

## Deprecated in 0.3.0: `dirVersion` and `slimVersion`

The node bundle fixes the versions of `dirctl` (1.9.1) and `slimctl` (3.4.6), so the two options choose
nothing any more. **Replaced by `bundleVersion`.** To move: delete `dirVersion` and `slimVersion` from your
`devcontainer.json`, and set `bundleVersion` only if you need a bundle other than the one this Feature version
was made with. Until then they keep working as before: the pinned version or `latest` is accepted (with one line
`deprecated: use bundleVersion` from the install, `facilitator version` and `facilitator check`, on stderr), and
any other version is refused, as it was for want of a checksum. They are removed in **1.0.0**, the next major,
released only when no consumer's `devcontainer.json` names them.

## How it fits

```text
  you, in your own Claude Code          participants, kept running by THEIR harness (never by this Feature)
  (or Copilot) session                     claude (MCP)            local model (model wrapper)
        | stdio: say, mail, continue           | stdio: receive, reply  | /v1/chat/completions
        v                                      v                        v
  facilitator mcp (one shared entry; the handle from FACILITATOR_HANDLE, the kind from the roster)
        |
  facilitator application: intake -> guard -> router -> dispatcher -> collector     (deterministic, no model)
        |  signer: sign-packet, keys in OpenBao (or the 0.1.0 fallback file)
        |  record: register-engine, one `conversation` register per conversation
        |  transport: SLIM (slim-bindings)     directory: AGNTCY Directory (dirctl)
        v
  infrastructure the Feature starts on loopback: dirctl daemon (8888, 5555, 8999, 8889), SLIM node (46357), ssh-agent
  (and, from 0.4.0, as a hub or a spoke of a mesh: a SLIM listener per level or a link to the hub, and the peers part;
  "A hub and its spokes" below)

  one node bundle per architecture, two installers:
  bundles/facilitator/install.sh --(release-bundle, the Operator)--> facilitator-<v>-linux-<arch>.tar.gz + SHA256SUMS
        |                                                                  |                       |
        | copy: bundle-build.sh (source build, no pin yet)    this Feature (mode node | leaf)   the node image (a hub)
        +-------------------------------------------------->  /opt/facilitator                 /opt/facilitator
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Conversations (signed registers), the roster of identities, attachment times | `/var/lib/devcontainer-features/facilitator` (volume `facilitator-state-${devcontainerId}`) | 4 working set (lost with the volume, never committed; ADR 0045) |
| Identity keys | OpenBao `facilitator/keys/<handle>`; fallback: `keys/<handle>` (mode 600) in the volume | none (OpenBao); 4 working set for the fallback |
| Participant and person tokens | `tokens/<handle>` (mode 600) in the volume, made again at every container start | 4 working set |
| What each person has read (the mail tool) | `mail/<handle>.json`, `mail/<handle>.notice` (mode 600) in the volume | 4 working set |
| SLIM's secrets (basic-auth password, app secret) | OpenBao `facilitator/slim`; fallback `secrets/slim.json` (mode 600) | as the keys |
| The Directory's records and node key | `dir/` in the volume | 4 working set |
| The node bundle | `/opt/facilitator` in the image layer; the release asset on GitHub | none (rebuilt from the release; never in the volume) |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: none yet

## What it is

The communication layer between agents of any vendor running in one devcontainer (proposal
`docs/proposals/facilitator-agent.md`, ADR-0061). Participants are external processes: a Claude Code
session, a local model, later Copilot and Gemini. **The Feature never starts, stops, configures or
resumes a participant** (NFR-13): its job is how a running participant is addressed, how a message reaches
it, how replies come back, routing, limits and the record.

- **Attachment:** a participant's CLI starts `facilitator mcp`, an MCP server over stdio; one shared MCP
  entry serves every agent, each one's handle and token in its environment (`FACILITATOR_HANDLE`,
  `FACILITATOR_TOKEN`; `--as <handle>` still works). An agent asks for its mail: `receive` blocks until a
  message is delivered.
- **A person talks through MCP too** (0.2.0; there is no terminal chat): a human of `facilitator.yml`
  attaches their own Claude Code or Copilot session to the same server with their own handle and token,
  and gets `say`, `mail` (never blocks), `transcript`, `continue` and `who`. "Ask @jester for a joke" is a
  `say`; "any mail?" is a `mail`. In Claude Code a turn hook can print "Facilitator: 2 new messages in
  c-1a2b3c4d" at each prompt.
- **Routing, deterministic** (no model in 0.1.0): every `@handle` in the text is delivered, each once
  ("@jester tell @domain-expert-one a joke" goes to both; the Operator's ruling of 2026-11-20 undid the
  first version's addressed-only reading), plus `to`, or `@all`; the hop count bounds the chain. No mention
  in a direct conversation goes to the other member, in a group to the `fallback` participant or everyone;
  a reply with no mention goes back to the asker. A participant
  that is not attached is never skipped: its message waits, the sender is told, and it is delivered when
  the participant calls `receive`.
- **Limits:** hop limit (6), message budget (40), rate (10 a minute); a person's `continue` resumes. A
  person's message counts as a hop like any other (option A); only `continue` resets the hops.
- **The record:** every message is a sign-packet packet signed with its writer's key, an entry of a
  register-engine register of the `conversation` type that this Feature supplies. `facilitator verify`
  walks each message back to the human who began the chain.
- **AGNTCY:** each participant's OASF record is pushed to the AGNTCY Agent Directory; delivery goes over a
  SLIM node, through `slim-bindings` directly (no `slim-mcp`, ruling E).

## What it installs

| Path | What |
| --- | --- |
| `/opt/facilitator/` | **The node bundle** (below): `bin/facilitator`, `bin/dirctl` (AGNTCY Directory 1.9.1, CLI and daemon), `bin/slimctl` (3.4.6, carries the SLIM node; not in mode `leaf`), `python/` (its own CPython 3.13.18), `lib/site-packages/` (`slim-bindings` 3.3.9, which reports node 3.4.6), `lib/facilitator/` (the application), `lib/registerengine/` and `lib/signpacket/` (its copies, ADR-0062), `lib/types.d/facilitator.py` (the `conversation` type), `lib/agntcy/` (the config templates), `MANIFEST.json` |
| `/opt/facilitator/lib/options.env` | The options as installed |
| `/usr/local/bin/facilitator`, `dirctl`, `slimctl` | Links into `/opt/facilitator/bin` (`slimctl` in mode `node` only) |
| `/usr/local/lib/register-engine/types.d/facilitator.py` | The same type, for `register-engine verify --type conversation`, when the register-engine Feature is installed |
| `/usr/local/bin/facilitator-setup`, `facilitator-start` | The post-create and post-start hooks |
| `/usr/local/share/go-task/includes.d/facilitator.yml` | The Taskfile (`installTaskfile`) |

From the distribution's apt when missing: OpenSSH (the signer), curl, tar and gzip. **No Python from the
system** since 0.3.0: the bundle carries its own. glibc only (the bundle's CPython, slimctl and wheel are the
gnu/manylinux builds).

## The bundle

One built, checksummed **node bundle** per architecture (linux amd64 and arm64), the same bytes for this Feature
and for the node image (ADR-0067, ruling Z1/C). It is built by one portable script,
[`bundles/facilitator/install.sh`](../../bundles/facilitator/install.sh) (bash, curl, tar, gzip, sha256sum; never
root), from this Feature's own source (the application and its copies of register-engine's and sign-packet's
libraries, so the copy checks cover what the bundle carries):

| In the bundle | From | Verified by |
| --- | --- | --- |
| `python/` | python-build-standalone 20261026, CPython 3.13.18 `install_only_stripped`, unchanged but for one `.pth` line naming `lib/site-packages` | its SHA-256, pinned in the script; the release's `SHA256SUMS`, the GitHub API digest and its GitHub build attestation (`gh attestation verify --repo astral-sh/python-build-standalone`) agreed on 2026-11-20 |
| `bin/dirctl` | AGNTCY Directory v1.9.1 release asset | its SHA-256: the GitHub API digest, equal to the subject of the release's SLSA provenance (`dirctl-v1.9.1.intoto.jsonl`; that provenance's signature not verified); dirctl publishes no checksum file |
| `bin/slimctl` | slimctl 3.4.6 gnu tarball | its SHA-256: the GitHub API digest, for a tarball whose sigstore bundle was verified by identity (agntcy/slim's release-rust workflow) in the spike of 2026-11-19 |
| `lib/site-packages/slim_bindings` | slim-bindings 3.3.9 manylinux wheel | PyPI's SHA-256, then `pip --require-hashes --no-index` |

Every download goes through the collection's download helper (`dcf_curl`, ADR-0034). `MANIFEST.json` records
the bundle's version, architecture, source commit, and each piece's version, URL and SHA-256. The same inputs give
the same bytes on one build host (sorted names, owner 0, times clamped to the source commit, `gzip -n`).

**Where this Feature takes it from**, the first that applies:

1. `bundle/facilitator-<v>-linux-<arch>.tar.gz` in the Feature's folder, staged by `task bundle:stage` for the
   Feature tests (git-ignored);
2. `FACILITATOR_ASSETS=<folder>` holding that file, for offline builds;
3. the release `facilitator-bundle-v<bundleVersion>` of this repository, **when `digests.txt` pins the asset**:
   downloaded and checked against the pin;
4. otherwise the bundle is **built here from the Feature's own source** by `bundle-build.sh` (a byte-identical
   copy of the script, `task bundle:check`), each upstream piece checked against the script's pins. This is how
   0.3.0 installed, published before its bundle; since 0.3.1 `digests.txt` pins the release
   `facilitator-bundle-v0.3.0`, so the bundle is downloaded and checked instead.

A local file (1, 2) is checked against the pin when there is one, and refused when it differs; without a pin it is
checked against the `SHA256SUMS` beside it and the install says it is unpinned. The bundle is never cached in the
state volume: the Feature installs while the image is built, when no volume is mounted, so the cache is Docker's
layer cache of the Feature's step (and `FACILITATOR_ASSETS` for offline builds).

**Verify a bundle by hand:**

```sh
v=0.3.0; tag=facilitator-bundle-v$v
gh release download $tag --repo nabil-becker/devcontainer-features --pattern 'SHA256SUMS' --pattern "facilitator-$v-linux-amd64.tar.gz"
sha256sum -c --ignore-missing SHA256SUMS                       # the file against the release's sums
grep "facilitator-$v-linux-amd64.tar.gz" src/facilitator/digests.txt   # the same digest as the Feature's pin
gh attestation verify facilitator-$v-linux-amd64.tar.gz --repo nabil-becker/devcontainer-features   # built by release-bundle
tar -xzOf facilitator-$v-linux-amd64.tar.gz facilitator/MANIFEST.json   # what is inside, and each piece's SHA-256
```

**The release sequence** (ruling AC; the Operator starts each workflow, an agent never does):

1. A pull request changes the application or the bundle script and bumps the application version; it merges.
2. The Operator runs **`release-bundle`** (Actions, on `main`): amd64 on `ubuntu-latest`, arm64 on
   `ubuntu-24.04-arm`, each built natively and smoke-tested, then one release `facilitator-bundle-v<v>` with both
   tarballs, one `SHA256SUMS` and a build attestation per tarball.
3. A pull request pins it: `task bundle:pin -- <v>` checks each asset against `SHA256SUMS`, GitHub's digest and its
   attestation, and appends the lines to `digests.txt`; the Feature's version and CHANGELOG move with it.
4. The Operator merges it and runs the Feature **release**.
5. The Operator runs **`release-node-image`**: the released assets, refused unless they match `digests.txt` on
   `main`, become `ghcr.io/nabil-becker/facilitator-node:<v>` (amd64 and arm64) with an attestation.

## The node image (a hub)

A node with no developer, for an intranet hub, built from the same bundle
([`bundles/facilitator/Dockerfile`](../../bundles/facilitator/Dockerfile)): `debian:trixie-slim` by digest, plus
`ca-certificates`, `openssh-client` and `tini`; the bundle verified against its `SHA256SUMS` in a build stage and
copied to `/opt/facilitator`; user `facilitator` (uid 10001), no login shell; state in the volume
`/var/lib/devcontainer-features/facilitator` (the Feature's path, NFR-1); `/etc/facilitator/facilitator.yml` and
`participants.yml` mounted read-only when wanted; `ENTRYPOINT tini -- facilitator node run`;
`HEALTHCHECK facilitator infra status`; nothing exposed. `facilitator node run` starts the ssh-agent, the Directory
and SLIM, stays in the foreground, stops all three on a signal and exits non-zero when one dies, so the
container's restart policy supervises it. Its role is its mounted `/etc/facilitator/mesh.yml`
(`FACILITATOR_MESH_FILE`): from 0.4.0 a hub (below, "A hub and its spokes"); with no file, standalone, every port on
loopback inside the container.

The sample [`bundles/facilitator/compose.yml`](../../bundles/facilitator/compose.yml) runs the hub (role hub, from
[`bundles/facilitator/hub/mesh.yml`](../../bundles/facilitator/hub/mesh.yml)) beside an OpenBao 2.7.2 (by digest) and
one spoke, on an internal network that publishes nothing (ruling AI). OpenBao starts sealed: initialise it once and
unseal it by hand after every start (ruling AB), from your own terminal; the rest is "Setting up a hub and its
spokes" below:

```sh
docker compose -f bundles/facilitator/compose.yml up -d
docker compose -f bundles/facilitator/compose.yml exec openbao bao operator init     # once; keep the shares
docker compose -f bundles/facilitator/compose.yml exec openbao bao operator unseal   # after every start
docker compose -f bundles/facilitator/compose.yml exec hub facilitator check
```

Locally: `task bundle:build`, `task bundle:image` (tags `facilitator-node:<v>-local`), `task test:facilitator-image`.
Why not AGNTCY's own images or Helm charts (NFR-9): they run one daemon each, with no supervisor for the three
processes a node needs and no bundle shared with this Feature (not checked against their latest releases).

## A hub and its spokes (slice N3)

From 0.4.0 a node can be a **hub** (an intranet node other nodes link to) or a **spoke** (a node that links to one
hub), beside the default **standalone** (0.3.0's behaviour, nothing open). Two levels of trust are built: **local**
(this machine, unrestricted) and **private** (an intranet domain). Public trust across nodes, approving a stranger's node
and peer-to-peer meshes are slice N5a (below); cloud AIs reach a node over HTTP with OAuth 2.1 access tokens from the issuers it lists (slice N5b, 0.8.0; MCP over HTTP
for CLIs is slice N4)
([proposal facilitator-node](../../docs/proposals/facilitator-node.md), ADR-0067 to ADR-0071).

```
   spoke-a (a devcontainer or the image)        hub-1 (the node image)              spoke-b
   agents a1, a2; person pa                     OpenBao beside it: PKI for          agent b1; person pb
                                                corp.example (an intermediate;
   SLIM  ---- mTLS, link of type peer ---->     the root stays offline)   <-------- SLIM
   (dials out, opens nothing)                   SLIM listener "private": the CA
                                                bundle of private domains only
   peers part: hello (its card)  ------------>  peers part: lock two on the card;
              <- roster (every card, revoked)    the roster of cards, backed up
   a1: "@b1 ..." -> the conversation's entries, signed, -> routed by the hub's SLIM -> spoke-b: lock two, replica
```

### mesh.yml

One file per node, `.devcontainer/mesh.yml` (or `FACILITATOR_MESH_FILE`; in the image `/etc/facilitator/mesh.yml`).
No file is `preset: solo`, `role: standalone`. Sections: `preset`, `role`, `node`, `trust`, `expose`, `limits`
(the slice's brief put `role` and `node` here, where the proposal had them in `facilitator.yml`).

```yaml
preset: team                     # solo (only this machine) | team (plus your intranet domains) | open (plus public, N5a)
role: spoke                      # standalone | spoke | hub | peer (no hub, slice N5a)
node:
  id: laptop-nb                  # default: the host name; node join writes it
  hub: hub.corp.example:46358    # these four are written by `facilitator node join`
  hub_name: hub.corp.example
  hub_node: hub-1
  domain: corp.example
  directory:
    peering: false               # the Directory beyond loopback; see "The Directory" below
trust:                           # SPIFFE trust domain -> level; a domain not listed is refused
  corp.example: private
expose:                          # handle or full SPIFFE ID -> the widest level it may be reached from
  "*": local                     # the default: an agent opts outward, never inward
  triage: private
limits:                          # per level: hops, budget, rate, copy, svid_ttl, max_packet
  private:
    hops: 4
```

A hub's `node` adds `name` (the DNS name in its certificate, which its spokes dial as `server_name`), `listen`
(one SLIM listener per level, e.g. `private: 0.0.0.0:46358`), `join` (the join endpoint's address) and `issuer`
(`domain`, `openbao`, `mount`, `role`, `kv`, `approle`: the file with `role_id=` and `secret_id=` lines);
[`bundles/facilitator/hub/mesh.yml`](../../bundles/facilitator/hub/mesh.yml) is a whole one.

- **The reach rule:** a caller whose domain is at level L sees and messages an agent exposed E only when E is at
  least as wide as L (local < private). A spoke's card lists only the participants exposed at least as wide as its
  domain's level, so a local-only agent never leaves its node: no other node lists it, and `@` it answers as an
  unknown handle.
- **Limits** in this order (ruling AD): the level's default, then the Feature options `hopLimit`, `messageBudget`
  and `rateLimit` (for local and private), then `mesh.yml` `limits`. `facilitator explain <handle or SPIFFE ID>`
  prints each effective value and where it came from. A message gets the limits of its **origin level**, the widest
  level of the writers of its lineage.
- `facilitator check mesh.yml` (or `-`) lints the file by NFR-11's contract: `path:line: rule: message`,
  `--format json`, exit 0, 1 or 2. **A file with findings never opens anything**: the node runs standalone and
  `check` says why (fail narrow).

### Identity, and the two locks

A node's identity is an ed25519 certificate file: URI SAN `spiffe://<domain>/node/<id>`, a DNS SAN (the
`server_name` its dialers use), `CA:false`, server and client auth. A hub's domain is issued, in the order of the tiers
below, by an **OpenBao PKI** (an intermediate in the hub's OpenBao, the **root kept offline**; **unsealed by hand** after
every start, and while it is sealed nothing is issued or renewed: a day's margin), else by an **ssh-agent** that holds
the CA key, else by the hub's **built-in CA** (the default from 0.7.0); certificates last **24 h** and are renewed at half
life. A node's home domain `<id>.local` may be self-issued (its own CA in the volume). SLIM reads its TLS key from
a file, so the node's certificate key is a file in the volume, mode 600 (the exception ADR-0069 decision 4 writes).

- **Lock one, the listener:** a hub has one SLIM listener per level, each with the CA bundle of that level's
  domains only; a certificate from any other CA is refused in the TLS handshake.
- **Lock two, the application:** SLIM never checks the SPIFFE ID (spike 2), so the facilitator does, on every card
  and every entry: the certificate must chain to a trust bundle, the domain the ID names must be the domain whose
  CA signed it, the domain must be in `trust` within the preset, and the node must not be revoked. Each node's
  **card** (its certificate, its facilitator's packet key and its exposed participants' packet keys, signed with the
  certificate's key) binds packet keys to SPIFFE IDs, so every packet's signer has an ID: an entry signed by a key no
  admitted card binds to the principal it writes as is refused, and so is a roster entry adding such a key. A card
  or a roster older than the one held is a replay.
- Refusals go to `mesh/refused.log`; `facilitator check` shows the last ones ("lock two") and the TLS refusals in the
  SLIM log (a refused dialer sees only a timeout; the reason is in the dialer's log: `UnknownIssuer`,
  `CertificateRequired`, `not valid for name`).

### Setting up a hub and its spokes, step by step

Everything a person does here is a person's act: `node invite`, `node revoke`, `node bundle` and
`node restore-roster` refuse to run inside an agent's job (`CLAUDECODE`, `DEVHOST_JOB_CHILD`, `FACILITATOR_HANDLE`, or a
name in `FACILITATOR_AGENT_JOB_VARS`).

**With no OpenBao (the default from 0.7.0)** steps 1 to 5 shrink to one: start a hub whose `mesh.yml` has an `issuer`
with only a `domain` (the Kubernetes base below, or the sample compose without its OpenBao service); it makes its CA,
issues its own certificate and opens its listener with nothing to unseal. Go to step 6. The steps below are the OpenBao
tier; `facilitator node issuer migrate` moves a built-in hub onto it later without a spoke joining again.

1. **Start the hub and its OpenBao** (the sample compose, or your own):
   `docker compose -f bundles/facilitator/compose.yml up -d`. The hub reads
   [`hub/mesh.yml`](../../bundles/facilitator/hub/mesh.yml); until it has a certificate it runs on loopback and
   `check` says why.
2. **Initialise and unseal OpenBao** (once; then unseal after every start):
   `docker compose ... exec openbao bao operator init`, then `... bao operator unseal`.
3. **Make the domain's PKI** with the root token (ADR-0050), the root CA on a machine of its own:

   ```sh
   # in OpenBao (bao, logged in with the root token)
   bao secrets enable -path=pki-corp pki && bao secrets tune -max-lease-ttl=8760h pki-corp
   bao write -field=csr pki-corp/intermediate/generate/internal common_name="corp.example intermediate" key_type=ed25519 > int.csr
   # offline, where the root key lives
   openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -days 365 -set_serial 0x$(openssl rand -hex 8) \
     -extfile <(printf 'basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n') -out int.pem
   cat int.pem root.pem > int-root.pem          # the intermediate WITH its root: the trust bundle needs both
   # in OpenBao again
   bao write pki-corp/intermediate/set-signed certificate=@int-root.pem
   bao write pki-corp/roles/node allowed_domains=corp.example allow_subdomains=true allow_bare_domains=true \
     allowed_uri_sans='spiffe://corp.example/*' key_type=ed25519 ttl=24h max_ttl=24h require_cn=false \
     server_flag=true client_flag=true key_usage=DigitalSignature ext_key_usage=ServerAuth,ClientAuth \
     use_csr_common_name=false use_csr_sans=false
   bao secrets enable -path=secret -version=2 kv
   bao policy write facilitator-hub - <<'EOF'
   path "pki-corp/sign/node" { capabilities = ["create", "update"] }
   path "pki-corp/revoke" { capabilities = ["create", "update"] }
   path "secret/data/facilitator/mesh/*" { capabilities = ["create", "update", "read"] }
   EOF
   bao auth enable approle
   bao write auth/approle/role/facilitator-hub token_policies=facilitator-hub token_ttl=1h
   ```

   The role refuses any URI outside `spiffe://corp.example/*` and any DNS name outside `corp.example`, and the hub, not
   the requester, decides each node's ID (run in this slice: OpenBao refused both).
4. **Give the hub its AppRole**, as a file (never baked into the image): `role_id=` from
   `bao read auth/approle/role/facilitator-hub/role-id`, `secret_id=` from
   `bao write -f auth/approle/role/facilitator-hub/secret-id`, written to the `approle` path in the hub's
   `mesh.yml`. Within seconds the hub gets its certificate and opens its listener: `facilitator check` shows the
   certificate and the open ports.
5. **Federated domains** (optional): put another domain's CA bundle on the hub with
   `facilitator node bundle partner.example --file partner.pem`, map it in `trust`, restart the hub.
6. **Invite a spoke** on the hub: `facilitator node invite` (task `facilitator:node-invite`) prints a join token: single
   use, 15 minutes, with the address of the join endpoint and the SHA-256 of the domain's trust bundle. The join
   endpoint is open while a token is live (and 30 s after).
7. **Join** on the spoke (`role: spoke` and its `expose` in its `mesh.yml`; its participants registered):
   `facilitator node join --token <token>` (task `facilitator:node-join`). It fetches the bundle, checks it against
   the token's hash before trusting the hub's certificate (no trust on first use), sends a request for its own key,
   and writes its certificate, the bundle, the mesh's SLIM secret and the hub into `mesh.yml`.
8. **Restart the spoke** (`facilitator infra down` then `up`, or the container): its SLIM node links to the hub
   (type `peer`, `server_name` the hub's name), the peers part says hello with its card, and the hub answers with the
   roster. `facilitator check` shows the hub and the cards admitted; `who` lists the other nodes' exposed agents.

From then on an agent mentions another node's agent like any other (`@b1`); `verify` passes on every node that
holds the conversation and names each remote signer's SPIFFE ID and level.

**Revoke** a spoke on the hub: `facilitator node revoke <node>` (asks to confirm). Its certificate is not renewed and
expires within `svid_ttl` (24 h); lock two refuses it on the hub at once and on every spoke at its next roster
(within 30 s); its card is kept, marked, so what it signed before stays readable. SLIM itself does not check
revocation (no CRL), so until expiry its TLS link may still form; for an urgent cut-off also restart the hub without
its bundle or stop the listener. What it already holds is not recalled.

**Back up** a hub's roster: every join and revoke writes it into OpenBao's KV (`secret/facilitator/mesh/roster`), so
OpenBao's snapshot carries it (ruling BH); `facilitator node restore-roster` reads it back. A built-in or ssh-agent hub
writes it to `mesh/roster.backup.json` in its own volume (mode 600): that guards against a torn write, not against losing
the volume; back the volume up (a snapshot of the claim) as you would any state.

### What crosses between nodes

- A conversation is one register; every node one of its members is on holds a whole replica (copy `member` at
  private, `full` at local), and the hub holds none unless one of its participants is a member. Each write is queued
  for the other member nodes; the register travels whole until delivered (an entry's id is its hash, so it is
  idempotent), so a node that was away catches up and a held message waits (`mesh/outbox/`).
- Every node's dispatcher routes its own members' messages; each node of a conversation anchors the facilitator keys
  of the others (from their cards). An @handle on another node is reached through the hub: the spokes' SLIM nodes link
  only to the hub, which routes between them (static `peer` links, SP3).
- A lineage that leaves a replica into a conversation this node does not hold is reported as "not copied here"
  (exit 0), with the node to verify it on.
- The SLIM names of a node's participants are its own (`agntcy/facilitator-<node>/<handle>`), and the peers part is
  `agntcy/facilitator-node/<node>` with the mesh's secret: another node cannot open a session to a participant's
  process (a different app secret).

### Naming another node's agent: `@handle.node` (ruling H5)

Two nodes may each have an agent with the same handle; both cards are admitted and both agents are reachable.

- **`@b1.spoke-b`** names the agent `b1` of the node `spoke-b`, in a message, in `to`, in `say` and `open`, in
  `explain`. The separator is `.`: neither a handle (`a-z 0-9 _ -`) nor a node id (`a-z 0-9 -`; a host name's dots
  become `-`) can hold one, so the split is never ambiguous. A `.word` after a mention whose word is no known node is
  punctuation, as before ("thanks @jester." still reaches jester).
- **A bare `@b1`** works when it names exactly one reachable agent. When several have that handle (this node's own
  included: there is no local-first rule), it is refused: opening a conversation says
  `@echo names 2 participants: @echo.spoke-a, @echo.spoke-b; name one of them`, and in a conversation with both as
  members the mention is delivered to neither, with a notice listing them.
- **In a conversation shared with other nodes every member is `handle.node`** (its thread, its roster, the routes,
  `from` in `receive`, the transcript and `verify`), so two `b1` can be members of one conversation. A conversation a
  node keeps alone keeps bare handles, and a standalone node sees no change.
- **`who`** shows a participant's bare handle, or `handle.node` where another reachable participant has that handle
  too; `check` lists the shared handles.

### Ports (ADR-0071)

`check` lists what is open beyond loopback ("open ports"). A standalone node and a spoke open nothing (a spoke dials
out). A hub opens its SLIM listeners (`node.listen`, mutual TLS), the join endpoint only while a join token is live,
and, with `directory.peering`, its Directory's libp2p and OCI ports. The Directory's API (8888) and gateway (8889)
never leave loopback. Nothing opens without a `mesh.yml` whose preset allows a level above local.

### The Directory, and mDNS

dirctl 1.9.1 has **no setting that turns mDNS off**: in this slice three daemons on one Docker network found each
other by mDNS, **including one whose libp2p was bound to loopback** (it dials out to what it finds); this is true of a
standalone node too, on any network segment it shares with another Directory. Its OCI registry also accepts an
anonymous push. So:

- By default (`directory.peering: false`) nothing of the Directory leaves loopback, and the mesh learns another node's
  agents from its signed card, not from the Directory.
- With `directory.peering: true` a hub opens its OCI registry and libp2p on its name; a spoke keeps everything on
  loopback, dials the hub as its `bootstrap_peers` (the peer id is computed from the Directory's own key), publishes
  every 10 s, and syncs the records the hub's card names **by registry**
  (`dirctl sync create --registry http://<hub>:<oci> --cids ...`), one way; the hub pulls from a spoke only if the spoke
  sets `directory.open_oci` (ruling BI). Peering needs `directory.firewall`: `auto` adds iptables rules dropping UDP
  5353 in and out (root, `NET_ADMIN` and `iptables` in the container), or `external` when the host or the network does
  it and limits the open ports to the listed peers; otherwise the Directory refuses to start.

### Failure modes, as run

| Failure | What happens |
| --- | --- |
| The hub restarts | the spokes' SLIM links reconnect (about 5 s); a message sent meanwhile is delivered (3 s after, in the test) |
| A spoke goes away | messages for it wait in the others' outbox and are tried every 5 s; it receives them when it returns |
| A node is revoked | refused by lock two (the hub at once, the spokes at their next roster); no renewal; its old entries stay readable |
| The hub's OpenBao is sealed | no certificate issued or renewed; a hub without one runs on loopback and opens nothing |
| A wrong `server_name` or CA | the dialer's SLIM log says `not valid for name` or `UnknownIssuer`; `check` names it |
| An invalid `mesh.yml` | the node runs standalone (fail narrow); `check` lists the findings |

## Hub on Kubernetes and the issuer tiers (slice hub-on-kubernetes)

From 0.7.0 a hub needs no OpenBao, and the node image runs on Kubernetes from a kustomize base
([`bundles/facilitator/k8s`](../../bundles/facilitator/k8s)). Rulings K2 to K5 and ADR-0078; a spike proved the agent tier
([ssh-agent-ca](../../docs/spikes/2026-11-23-ssh-agent-ca.md)).

### The issuer tiers

A hub's `node.issuer` picks, **in this order**, who holds the CA key and signs:

| Tier | `node.issuer` has | The CA key | Needs | `check` says |
| --- | --- | --- | --- | --- |
| 1. OpenBao PKI | `openbao` (and `mount`, `role`, `kv`, `approle`) | in OpenBao | OpenBao unsealed by hand after each start | the seal state |
| 2. ssh-agent | `ssh_agent: {socket, key}` | in an agent's memory, **never a file** | the agent running with the key loaded | the agent, the key's fingerprint; **warns** when the agent holds other keys |
| 3. built-in CA (the default) | only `domain` | a file in the volume, mode 600 | nothing | **warns** that the CA key is a file (the last resort) |

| Setting | Meaning |
| --- | --- |
| `node.issuer.domain` | the trust domain issued for (a hub: required; must be in `trust`) |
| `node.issuer.openbao`, `mount`, `role`, `kv`, `approle` | tier 1 (unchanged from 0.4.0) |
| `node.issuer.ssh_agent.socket` | the agent's socket path, or `$SSH_AUTH_SOCK` (a `
# facilitator (conversations between agents of any vendor, on AGNTCY) (facilitator)

The communication layer between agents of any vendor running in the devcontainer: an MCP server each participant's CLI starts (receive, reply, say, who) and a person's own Claude Code or Copilot session attaches to (say, mail, transcript, continue, who), one shared entry with the handle from FACILITATOR_HANDLE, deterministic routing by @handle with hop, budget and rate limits, every message a sign-packet packet in a register-engine conversation register, verified back to the human who began it. Installs the facilitator node bundle (its own CPython, dirctl, slimctl and the application, checksummed; the same bundle as the server image) and runs the AGNTCY Agent Directory and a SLIM node on loopback, started as infrastructure (mode node), or only the thin client (mode leaf); never starts, stops or configures a participant. A node is standalone (nothing open) unless its mesh.yml (FACILITATOR_MESH_FILE) makes it a hub or a spoke: nodes link over SLIM with mutual TLS, certificates from an OpenBao PKI per trust domain, a listener per trust level and the application's SPIFFE ID check (local and private trust; join tokens, revoke). Serves its MCP tools over HTTP to CLIs with static bearer tokens and to cloud AIs with OAuth 2.1 access tokens (facilitator.http.listen in facilitator.yml; off by default, refused under the preset solo; the node is a resource server only: it accepts tokens from the issuers in facilitator.http.issuers and publishes the protected-resource metadata; a person approves each client; the node signs for it and every packet says so) and includes a local-model wrapper for any OpenAI-compatible endpoint and a turn hook line for Claude Code ('Facilitator: N new messages').

## Example Usage

```json
"features": {
    "#{Registry}/#{Namespace}/facilitator:#{Version}": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under facilitator: in a root Taskfile that includes /usr/local/share/go-task/features.yml (the go-task Feature). | boolean | true |
| backend | What carries the directory and delivery: agntcy (the AGNTCY Agent Directory and SLIM). lean (packet-relay) is refused in this version: not yet, slice 5. FACILITATOR_BACKEND overrides. | string | agntcy |
| mode | node (the default): the whole bundle, and the Directory, the SLIM node and the facilitator's ssh-agent run here (autostart). leaf: the thin client only (facilitator mcp and what it needs; no slimctl): no daemon is started, infra up and node run are refused; a leaf reaching a node over the network is not built yet (slice N3 built hubs and spokes). FACILITATOR_MODE. | string | node |
| bundleVersion | The facilitator node bundle to install (a release asset of this repository, facilitator-bundle-v<version>), verified against the SHA-256 pinned in digests.txt. latest means the bundle this Feature version was made with (0.8.0). With no pin for it, the bundle is built from the Feature's own source, every upstream download checked against the SHA-256 pinned in bundle-build.sh. | string | 0.8.0 |
| dirVersion | Deprecated in 0.3.0 (removed in 1.0.0): use bundleVersion. The bundle fixes dirctl's version (1.9.1); 1.9.1 or latest are accepted, with a deprecation line from install, version and check, and any other version is refused. | string | - |
| slimVersion | Deprecated in 0.3.0 (removed in 1.0.0): use bundleVersion. The bundle fixes slimctl's version (3.4.6); 3.4.6 or latest are accepted, with a deprecation line from install, version and check, and any other version is refused. | string | - |
| hopLimit | Hops since the message that began the chain (a person's later messages count too) before the conversation pauses; a person's continue resumes it. The default of the local and private trust levels; mesh.yml limits override it per level. FACILITATOR_HOP_LIMIT. | string | 6 |
| messageBudget | Messages a conversation may hold between two continue before participants' messages are held. FACILITATOR_MESSAGE_BUDGET. | string | 40 |
| rateLimit | Messages a participant may write in a minute; one more is refused. FACILITATOR_RATE_LIMIT. | string | 10 |
| receiveWaitSeconds | How long the MCP tool receive blocks when no wait_seconds is given. FACILITATOR_RECEIVE_WAIT_SECONDS. | string | 300 |
| staleSeconds | After this long without a receive a participant counts as not attached: its messages wait, and the sender is told. FACILITATOR_STALE_SECONDS. | string | 900 |
| facilitatorBudget | Model calls the facilitator application may make per conversation. Read and shown; no model is called before slice 6. FACILITATOR_BUDGET. | string | 20 |
| identity | Also run AGNTCY Identity (needs Docker). Refused in this version when true: not yet, slice 7. | boolean | false |
| autostart | postStartCommand starts the infrastructure (facilitator infra up: the Directory, the SLIM node, the facilitator's ssh-agent), never fatally; nothing in mode leaf. Participants are never started. FACILITATOR_AUTOSTART. | boolean | true |
| dirOnlineCheck | Check each pushed agent record against the online OASF schema server (schema.oasf.outshift.com); off, records are checked offline (the Directory's policy.operations: []). FACILITATOR_DIR_ONLINE_CHECK. | boolean | false |
#{Customizations}
 and the variable's name) |
| `node.issuer.ssh_agent.key` | the CA key's **SHA256 fingerprint** (`ssh-keygen -l -E sha256 -f key.pub`), never "the first key"; **ed25519 only** |

- **The built-in CA** is a *root* (20 years) that signed one *issuing CA* (10 years) once; leaves are signed by the issuing
  CA and the trust bundle holds both, so the root key can leave the volume (below) without a spoke noticing. Both are
  ed25519 and constrained to `DNS:<domain>` and the hub's own name (SLIM, built on rustls-webpki, refuses a URI
  constraint). A hub made by 0.6.0 (one CA, no separate root) keeps working as it is. The roster is backed up to a file in
  the volume. The certificates are built by `cabuild.py` (DER assembled in Python, the signature asked of a signer), so no
  OpenSSL 3.4 is needed.
- **`facilitator node issuer export-root --out <new file>`** (a person's act, refused inside an agent's job) writes the
  root's key and certificate to a new file (mode 600; never over a file that exists) and **removes the root key from the
  volume**. Take the file offline. The hub keeps issuing, every spoke's bundle is unchanged. It is what signs a new
  issuing CA in ten years or after a compromise.
- **`facilitator node issuer migrate`** (a person's act) moves a built-in hub onto an OpenBao PKI **keeping the same CA**:
  it imports the issuing CA's key and certificate (with the root's certificate) into the mount, makes the node role, checks
  that a certificate OpenBao signs chains to the bundle the spokes hold, backs the roster up into OpenBao's KV, and only
  then removes the key from the volume. Spokes need not join again and issued certificates stay valid. Give it an OpenBao
  address (`--openbao`, `node.issuer.openbao` or `BAO_ADDR`), the mount (`--mount`, default `pki`) and a token that may
  configure the mount (`--token-file` or `FACILITATOR_OPENBAO_TOKEN`: yours, not the hub's AppRole); then add `openbao`,
  `mount` and `approle` to `mesh.yml` and restart. It refuses a hub whose key is in an ssh-agent (an agent never gives the
  key up). `facilitator node issuer status` shows the tier (read only).
- **The ssh-agent tier**: the agent's ed25519 key *is* the CA (the root is self-signed once, by the agent, and every leaf is
  one signing round trip). `facilitator check` shows the key's fingerprint and whether the agent answers. **With the agent
  gone**, issuing and renewing stop with `ssh-agent unreachable at <socket>`; every certificate already issued stays valid
  until it expires, and traffic over existing links is untouched. Changing `key` is a new CA: every node joins again
  (the hub refuses the old CA file with that message). Use an agent of its own that holds only this key: an agent signs
  anything for a key it holds. RSA and ECDSA keys hash first and a FIDO key cannot sign the bytes: refused by name.

### The Kubernetes base

[`bundles/facilitator/k8s`](../../bundles/facilitator/k8s) is a kustomize base and two overlays (a Helm chart is later,
with a `helm` Feature that does not exist yet):

```text
base/                  Namespace (Pod Security "restricted"), StatefulSet, Service, and a ConfigMap generated from
                       mesh.yml, facilitator.yml and participants.yml (a change renames it, which restarts the pod)
overlays/rancher-desktop    Service -> LoadBalancer; mesh.yml for hub.workstation.example (workstation.example)
overlays/ssh-agent          on top of it: a ca-agent container in the pod (ssh-agent on a memory volume) and the
                            ssh_agent tier in mesh.yml
```

- **The StatefulSet**: one replica, the node image `ghcr.io/nabil-becker/facilitator-node` (the tag is `images:` in the base's
  `kustomization.yaml`: `newTag: 0.7.0`), a 1 Gi volume claim for the state at `/var/lib/devcontainer-features/facilitator`,
  uid 10001, `runAsNonRoot`, a **read-only root filesystem** (the image allows it: only the state volume and a `/tmp`
  emptyDir are writable), all capabilities dropped, no privilege escalation, `RuntimeDefault` seccomp, no service-account
  token, the image's own health check (`facilitator infra status`) as startup, liveness and readiness probes.
- **The Service** exposes **SLIM (46358) and the join endpoint (46359) and nothing else**: not the Directory, not the HTTP
  endpoint (off), not the OCI registry. The join endpoint answers only while a join token is live.
- `task bundle:k8s` renders the base and both overlays with `kustomize build`, checks each with `kubeconform -strict`, and
  runs `test/facilitator/k8s/shape.sh` (uid, read-only root, capabilities, the Service's two ports, the image tag, the
  issuer). The `kustomize` and `kubeconform` Features put the tools on `PATH`; otherwise pinned, checksummed ones are fetched.
  `task bundle:k8s -- overlays/rancher-desktop` prints one render. Apply it with
  `kustomize build bundles/facilitator/k8s/overlays/rancher-desktop | kubectl apply -f -`.

### Reaching the hub from the devcontainers of the same machine (Rancher Desktop)

The spokes are containers on the machine's Docker engine; the hub is a pod. They meet at the machine's ports, never in the
cluster's network:

```text
 spoke (a devcontainer)  --- hub.workstation.example:46358 / :46359 --->  host-gateway (the machine)
   "runArgs": ["--add-host=hub.workstation.example:host-gateway"]                |
                                                  Rancher Desktop forwards the LoadBalancer Service's ports
                                                                                 v
                                      Service (LoadBalancer) 46358, 46359  -->  facilitator-hub-0
```

1. **The name in the hub's certificate is the name the spokes dial.** The overlay's `mesh.yml` says
   `node.name: hub.workstation.example` and `issuer.domain: workstation.example`; the join token carries
   `hub.workstation.example:46359` and the spokes' `server_name` is that name, so nothing is typed per spoke. Use your own
   name in both places (any DNS-style name; it need not resolve outside the machine) and the same one in every spoke.
2. **Each spoke maps that name to the machine**: `--add-host=hub.workstation.example:host-gateway` in the devcontainer's
   `runArgs`. `host-gateway` is the machine as the container sees it, on Docker Desktop, Rancher Desktop's dockerd and a
   plain Linux engine alike (`host.docker.internal` as `node.name` works only where the engine defines it).
3. **The Service is a LoadBalancer**: k3s binds the two ports on its node and Rancher Desktop forwards a LoadBalancer
   Service's ports to the machine. **Not run against Rancher Desktop** (this devhost has none): the throwaway-cluster test
   below reproduces the same chain with kind's published ports in place of Rancher Desktop's forwarding, spokes reaching
   the hub through `host-gateway` exactly as above. Whether Rancher Desktop's forward binds the machine's loopback only (so
   that `host-gateway` cannot reach it) is the one thing to check first on a real workstation; if it does, publish the ports
   on all interfaces or use `host.docker.internal` with the loopback forward.
4. The ports are **published on the machine**, so anything that reaches the machine reaches the join endpoint (open only while
   a token is live) and the SLIM listener (mutual TLS, lock one). Keep the machine's firewall closed to the network.

For a team's hub on a real cluster use an `Ingress`-free LoadBalancer or `NodePort` of your own in an overlay, a CA in
OpenBao (`node issuer migrate`) and a `StorageClass` you back up.

### The ssh-agent overlay, step by step

```sh
ssh-keygen -t ed25519 -N '' -f ./hub-ca                 # once, offline; ./hub-ca is the CA: keep it where you keep roots
ssh-keygen -l -E sha256 -f ./hub-ca.pub                 # put this fingerprint in overlays/ssh-agent/mesh.yml (node.issuer.ssh_agent.key)
kustomize build bundles/facilitator/k8s/overlays/ssh-agent | kubectl apply -f -
kubectl -n facilitator-hub exec -i facilitator-hub-0 -c ca-agent -- ssh-add - < ./hub-ca     # load the key into the agent's memory
kubectl -n facilitator-hub exec facilitator-hub-0 -c hub -- facilitator check                # the issuer row, then the certificate
```

The key is in the agent's memory only, so **after every restart of the pod the hub issues nothing until a person loads the
key again** (certificates already issued stay valid; the hub keeps asking). That is the price of a CA key that is never a
file; a pod that restarts unattended wants the OpenBao tier or the built-in CA.

### Tested in a throwaway cluster

`task test:facilitator-k8s` ([`test/facilitator/k8s_flow.sh`](../../test/facilitator/k8s_flow.sh)): kind v0.33.0 with its
Kubernetes 1.37.0 node image by digest, kubectl, kustomize and kubeconform pinned by version and SHA-256
([`k8s/tools.sh`](../../test/facilitator/k8s/tools.sh)), one cluster, deleted afterwards with every container, volume and
image it made. It renders and checks the manifests; deploys the hub (the rancher-desktop overlay, the image loaded into
the cluster, the Service as a NodePort published on the machine's 46358 and 46359); checks the pod's hardening and the
Service's two ports; joins a spoke container with a token; has the spoke's agent and the hub's agent converse, with `verify`
on both; runs `export-root` and joins a second spoke after the root key left; then redeploys from the ssh-agent overlay,
loads a key into the agent container, joins a third spoke on a certificate the agent signed (no CA key file anywhere), and
removes the agent's socket: `check` says so, a join is refused cleanly and the issued certificate stays valid.

## Peer to peer and the public level (slice N5a)

Settings, all in `mesh.yml` (a setting here is in the NOTES by the standard; `facilitator check` lints them):

| Setting | What |
| --- | --- |
| `role: peer` | No hub. The node is the issuer of its own domain (`node.domain`, mapped `private` in `trust`) with a CA it keeps (`mesh/ca/<domain>/`, key mode 600, name-constrained to the domain's SPIFFE URIs); `node.name` is the DNS name in its certificate. |
| `node.peers` | node id to `host:port` of that peer's SLIM listener, or `incoming` (the peer dials this node). `node peer` and the pairing write it. A pair has one link: the node that paired from the other's token dials. |
| `preset: open` | The ceiling is `public`: `trust` may map named domains `public`, `expose: public` means reachable from them. `team` and `solo` refuse it (HTTP clients of this node stay as in 0.5.0). |
| `node.public.domain`, `node.public.join` | A hub or peer that issues a **public domain**: its own CA for it, certificates of `limits.public.svid_ttl` (1 h), issued only after a person approves. `join` is the **separate** public join endpoint (join requests, no token; refused if equal to `node.join`). Needs a `public` entry in `node.listen`. |
| `node.listen.public` | The separate public SLIM listener: its CA bundle holds the public domains only, and it presents a certificate of the public domain (SP1). |
| `limits.public.copy` | Only `addressed` (the default); `full` and `member` are refused at public. |
| `limits.<level>.svid_ttl` | 1 minute to 7 days now (a test shortens it). |
| `node.directory.peering` | Refused beside a public domain in `trust` (the libp2p port would admit any dialer, R3). |

### Peer to peer

```
 node A  (peer: domain a.mesh.example, its own CA)          node B  (peer: b.mesh.example)
   facilitator node invite  ----- token (hash of A's CA bundle) ----->   facilitator node peer --token <t>
   A trusts b.mesh.example (private), peers: {B: incoming}   <--- B's bundle, A's bundle and the mesh secret ---> B trusts a.mesh.example, peers: {A: host:port}
   restart SLIM on both: each listener's client CA holds the other's domain; B dials A; hello and card envelopes
```

Lock two is as in a hub mesh (the certificate's domain is the domain whose CA signed it, the domain is in `trust`, the node is
not revoked) and in addition a hello is admitted only from a node in `node.peers` or in this node's roster. There is no
roster to relay, so each node decides alone: **`node revoke` on one node refuses that node there**; the others still trust it
until they revoke it too. A third peer pairs with either; for three nodes with no hub, each pair is paired once.

### The public level across nodes

```
 public node P                                                  issuer I  (node.public, preset open)
   node request <info>  ---- a key (signed request), TLS to the public join endpoint, checked against the bundle in <info> ---->  waits
   (info: `node invite --level public` on I, handed over by a channel of the person's own: its CA bundle is what P trusts)
                                                               a person: node requests ; node approve <id>  (signed audit entry)
   node collect  <---- certificate (1 h), bundle, mesh secret, I's card (public agents only) ----
   P is a spoke of the public domain: mesh.yml role spoke, trust {open.example: public}, preset open
   renews at half life while I allows; node revoke P on I: no renewal, lock two refuses it, the mesh secret rotates
```

- A public node sees the issuer's own card, restricted to agents `expose`d `public`, and no other node's card. An agent that is
  not marked public is unreachable (a message to it is refused as to an unknown handle) and unlisted.
- **Copy addressed.** What the issuer replicates to a public node: only the conversations that node has a member in, and in
  them only messages addressed to it. register-engine cannot hold a *part* of a register: an entry's `prev` and the heads it
  `saw` must be present, or the entry is refused (sign-packet `graph.order`), and the proposal's "ancestors' ids, not bodies"
  has no form in the engine. So the policy is on the conversation (the closest thing that holds): a conversation with a member
  on a node at `copy: addressed` carries only messages addressed to that node's members: **the write is refused** otherwise
  (`say` and `reply` say so), and `peers` **withholds the register before sending** if it holds more
  (`mesh/refused.log`). A message to others is a message in another conversation. `verify` on a replica says
  `partial` where the lineage leaves it, naming the node to verify on (exit 0); a signature or chain break in what is present
  is a break (exit 1).
- **First contact.** A task whose message is by an agent of a public node waits (it is not given to `receive`, and `mail`
  shows it) until a person approves that agent: `approve` (a person's MCP tool) or `facilitator http approve <handle>.<node>`.
  The approval lasts `approval_ttl` (30 d) and is an entry of the audit register.
- **Cut-off, as run.** Public certificates last 1 h (`limits.public.svid_ttl`; shorten it to test). `node revoke` stops
  renewal, so the node's certificate expires within the hour and no new handshake succeeds after; lock two refuses what it
  sends from the moment of the revoke. What it already holds is not recalled.

### The mesh secret's rotation (ruling H4)

SLIM checks no revocation list, so a revoked node's link could still form until its certificate expired. On every `node revoke`
the peers part makes a new SLIM app secret and hands it, over the links, to the nodes that remain, each with the secret
the node holds now (so it still verifies); a node that takes it passes it on to the nodes it still trusts, then every one
restarts its peers part on the new secret. It waits up to 120 s for a node that is away; one that missed it holds the old
secret and is refused at SLIM until a person runs `facilitator node secret` on any node and `facilitator node secret --file
<file>` there. The rotation is an entry of the audit register (`secret-rotated`).

### The signed audit register (ruling HC3)

`audit-enrolment`, a register of the type `audit` (the second type in `types.d/facilitator.py`, the engine's own type mechanism):
`enrolment` entries {event, subject, by, claimed?, detail?, line?} signed by the facilitator key, an anchor. Every HTTP token,
approval, denial and revocation, a public node's join request, approval, denial, a revocation and a rotation, and a first
contact approval is one. `facilitator audit replay` puts the lines of `http/audit.jsonl` in once each (an entry names the
SHA-256 of its line) so a node that ran 0.5.0 loses nothing; `facilitator audit verify` checks every entry, the chain
(no gap, fork or foreign writer) and that the whole log is in the register, in order.

### Agent badges: a seam, not a feature (ruling ID2)

The `identity` option stays refused. Each participant entry of a card may carry an opaque `badge` string (up to 8 KiB): the card
is signed with the node's certificate key, so a badge travels signed, and lock two ignores it. Lock two is where a badge check
would sit: after `Mesh.admit` on the certificate, before a participant's key is bound to its handle (`identity.check_card`).
A badge (AGNTCY Identity, a W3C verifiable credential) would carry a **binding record**: the agent's SPIFFE ID
(`spiffe://<domain>/node/<node>/agent/<handle>`), its packet key (the ssh-ed25519 line that signs its messages) and the hash of the
card that lists it (SHA-256 of the card's canonical JSON without `sig`), so a verifier can tell that this credential vouches
for this key on this node; the spike is `docs/spikes/2026-11-23-agntcy-identity.md`.

## MCP over HTTP for CLIs (slice N4)

From 0.5.0 a node can serve its MCP tools over HTTP (Streamable HTTP), so a CLI that cannot start `facilitator mcp` here
reaches the node with a **static bearer token**: Claude Code (`claude mcp add --transport http`) and GitHub Copilot CLI
(`copilot mcp add --transport http`), both run for real against this endpoint (test/facilitator/http_flow.sh).
**Cloud AIs (OAuth 2.1, a public HTTPS address) are slice N5b, from 0.8.0**: see "MCP over HTTP for cloud AIs" below. The
endpoint is the `mcp` Python library 2.3.0 (MIT; 28 hash-pinned wheels in the bundle) on uvicorn; an install without the
bundle needs it importable only when the endpoint is on ([proposal](../../docs/proposals/facilitator-node.md) section 11;
ADR-0070, ADR-0071, ADR-0068).

```
 Claude Code / Copilot CLI                         the node (infra part `http`)
   POST /mcp   Authorization: Bearer <client>.<secret>
   ------------------------------------------------>  gate: back-off, 20 open requests per address, 64 KiB, /mcp only
                                                      library: Host and Origin (DNS rebinding), the token (a hash, constant time)
                                                      HttpSession of that client: who, say, reply, receive, mail, transcript
                                                      reach rule (the client's level), first-contact hold, limits
                                                      signer: the node signs for the client; every packet has data.via
```

### Settings: `facilitator.http` in `.devcontainer/facilitator.yml`

Off unless `listen` is set (ADR-0071: a port opens only when configured), refused under `preset: solo`, and a mistake in
this section never stops the node's other parts: the endpoint does not open and `check` says why.

```yaml
facilitator:
  humans: [you]            # the people who approve first contacts; must name one (or check refuses approval: first-contact)
  http:
    listen: 127.0.0.1:8765     # host:port; unset = no endpoint, nothing open
    enabled: true              # false removes the listener (the kill switch) and keeps the clients
    url: https://node.corp.example:8443   # the address clients use; needed beyond loopback (the Host check)
    tls_cert: /etc/facilitator/tls/cert.pem   # TLS is required beyond loopback ...
    tls_key: /etc/facilitator/tls/key.pem
    behind_proxy: false        # ... or true when a reverse proxy ends TLS (then only the proxy may reach the node)
    allowed_hosts: []          # extra Host header values
    allowed_origins: []        # Origin header values allowed (CLIs send none; a browser's is refused unless listed)
    # issuers: [...]           # OAuth authorization servers whose tokens are accepted (slice N5b, below)
```

| Key | Default | Meaning |
| --- | --- | --- |
| `http.listen` | unset | The address to open. Beyond loopback it needs `tls_cert` and `tls_key`, or `behind_proxy: true`, and `url` or `allowed_hosts`. |
| `http.enabled` | `true` | `false`: the listener is gone, the clients and their audit stay. |
| `http.url` | from `listen` | What the clients dial (also the protected-resource metadata's name). |
| `http.tls_cert`, `http.tls_key` | unset | PEM files; both or neither. Mode 600 for the key. |
| `http.behind_proxy` | `false` | A proxy ends TLS; uvicorn then trusts the proxy's `X-Forwarded-For` for the per-address limits, so only the proxy may reach the port. |
| `http.insecure` | `false` | Plain `http://` for a local machine or a test environment (0.8.0): `http.url` may be `http://` on any address, with or without issuers, and the TLS rule beyond loopback is waived. Every start logs, and `check` shows, a warning: "http.insecure: tokens travel in plain text; for a local machine or a test environment only" (bearer tokens included). Refused under `preset: open`: `check` fails and the endpoint does not start. |
| `http.allowed_hosts`, `http.allowed_origins` | none | Host and Origin values accepted besides the derived ones. |
| `http.issuers` | none | The OAuth authorization servers whose access tokens are accepted (0.8.0, below). Needs `http.url`. |

`mesh.yml` gains, for this slice (the single-node public rules, ruling AH):

- `trust: { http.<home domain>: private }` maps the node's own HTTP clients (the domain `http.<node id>.local`) to
  **private**; unlisted they are **public**. Never local.
- `expose: { <handle>: public }` is allowed under `team`: public means reachable by this node's HTTP clients only.
  Under `solo` it is refused. An agent is never public unless a file says so.
- `limits.<level>`: `approval` (`none`, or `first-contact`; default `first-contact` at public), `approval_ttl` (`none`, or
  a duration such as `30d`, the default at public), `http_receive_wait` (the longest a `receive` blocks; 300s, 60s, 25s).
  The public defaults of hops 2, budget 10, rate 3 and `max_packet` 16KiB apply to a client's conversations.

### Tokens, approval and revocation (a person's acts)

```
facilitator http token <client> [--label ..]   # prints the token once; only its SHA-256 is kept; refused inside an agent's job
facilitator http list | audit                  # the clients (no secret), the audit chain
facilitator http approve <client>              # first contact: its held messages are delivered (also the person's MCP tool approve)
facilitator http deny <client> | revoke <client>   # the token stops working at once
facilitator http forget <client>               # a revoked or denied client's entry dropped: the same login is new next time
```

A **token** is `<client>.<secret>` (the secret is 256 random bits). It is a person's act: `token`, `approve`, `deny`,
`revoke` and `forget` refuse to run inside an agent's job (`CLAUDECODE`, `DEVHOST_JOB_CHILD`, `FACILITATOR_HANDLE`, or the variables
`FACILITATOR_AGENT_JOB_VARS` names). At most 20 clients may be enrolled and not yet approved. The approver is the person
acting (`--as`, a human of `facilitator.yml`, default the first): on a node with no person attached, the hub's own
`humans:` list, which `check` requires to name one while a level asks for first contact.

- **First contact (level public).** A client's messages are **written and held** (`held: approval`, a notice in the
  conversation) until a person approves the client. A person's `mail` and the turn hook line name the clients that wait;
  `approve` (the MCP tool, or `facilitator http approve`) records an `approved` notice in each conversation and delivers.
  A message held more than **7 days** is not delivered (ruling BG). An approval lasts `approval_ttl` (30 days at public).
  Mapped to private there is no approval.
- **Audit.** Every enrolment, approval, denial and revocation is a line of `http/audit.jsonl`, each carrying the hash of
  the line before it (`facilitator http audit` checks the chain). It is **not** a signed register (see Limits); the
  approval and denial are also signed notices in the conversations they concern.
- Revocation closes the client's future calls at once and discards its token's hash; what it wrote stays in the record.
- **Forget** (`facilitator http forget <client>`, task `facilitator:http-forget`) lets a refused client back: it drops the
  entry of a **revoked or denied** client (a live one is refused: revoke it first), so the same login is new next time: an
  OAuth login (issuer and subject) enrols again on its next valid token and is held for a person's approval; a bearer client
  name can be given a new `http token`. A `forget` event goes to the audit log and the signed register; past records keep
  naming the client.

### What an HTTP client is, and sees

- **Never a person.** It is offered `who`, `say`, `reply`, `receive`, `mail` and a read-only `transcript`, never
  `continue` or `approve`: only a person's local session resets the hop count (ADR-0066).
- **Signed for by the node** (ADR-0068): the roster entry is kind `http`, its key is held by the node (OpenBao, or the
  0.1.0 fallback file), and every message and task state it makes carries `data.via` =
  `{transport: http, auth: bearer, client}`. `transcript` says "(via HTTP, authenticated by bearer token, client X)";
  `verify` names each such hop, checks that `via` is present and names the writer, and accepts a chain that **begins**
  with an HTTP client (its first message is a root, hop 0, which the node vouches for; see Limits). The client's
  SPIFFE ID is `spiffe://http.<home domain>/node/<id>/http/<client>`.
- **The reach rule.** A public client sees and messages only agents exposed `public`; the others are not listed, and a
  message to one reads exactly like a message to a handle that does not exist ("is no participant"). It never sees
  another HTTP client, a person (unless exposed), or another node's agents.
- **Limits.** The level's rate is counted **for the client across all its conversations** (3 a minute at public), then
  hops 2, budget 10 per conversation and `max_packet` 16 KiB (refused before anything is written). Over HTTP a
  `receive` blocks at most `http_receive_wait` (25 s at public) and a client may have 2 at a time.
- **Abuse limits at the edge** (proposal 11.3): 10 failed authentications from an address in a minute block it for 10
  minutes (even with the right token; the answer has no detail); 20 open requests per address; a 64 KiB body; only
  `/mcp` and the well-known metadata answer; Host and Origin are checked.

### Connecting the CLIs

```
facilitator http token claude-laptop                       # the token, once
claude mcp add --transport http facilitator http://127.0.0.1:8765/mcp --header "Authorization: Bearer <token>"
copilot mcp add --transport http facilitator http://127.0.0.1:8765/mcp --header "Authorization: Bearer <token>"
```

Both put the header in their own config file (Claude Code's `.claude.json` or `.mcp.json`, Copilot's
`mcp-config.json`): treat that file as a secret. A token has no expiry; revoke it with `facilitator http revoke`.

## MCP over HTTP for cloud AIs (slice N5b, OAuth 2.1)

From 0.8.0 the same endpoint also takes **OAuth 2.1 access tokens**, so a cloud AI (a claude.ai custom connector, or another
vendor's hosted assistant) can reach the agents of a node that is on a public HTTPS address. The node is an **OAuth
resource server only** (ADR-0070 decision 2): it hosts no authorization server. A person points it at the
authorization server they already use (the organisation's identity provider, or any provider that issues JWT access tokens
and supports what the cloud AI needs) and the cloud AI logs the person in there. Bearer tokens keep working beside it.

```
 cloud AI (claude.ai)                   authorization server (yours)          the node (http.url = https://node.example)
   POST /mcp (no token)  ------------------------------------------------>   401, WWW-Authenticate: Bearer resource_metadata=".../.well-known/oauth-protected-resource/mcp"
   GET  the metadata     ------------------------------------------------>   { resource, authorization_servers: [issuer], scopes_supported }
   log in (OAuth 2.1 + PKCE, resource=https://node.example/mcp)  ----->  access token (JWT: iss, sub, aud, exp, scope)
   POST /mcp  Authorization: Bearer <JWT>  --------------------------------->  gate: issuer in the list, alg, signature (JWKS), exp,
                                                                                aud = this resource (RFC 8707), scope; then the (iss, sub)
                                                                                client: enrolled on its first token, held until a person
                                                                                approves; the same HttpSession, signer and via as a bearer client
```

### Settings: `facilitator.http.issuers`

```yaml
facilitator:
  humans: [you]
  http:
    listen: 0.0.0.0:8443
    behind_proxy: true                       # or tls_cert and tls_key: beyond loopback TLS is required (ADR-0070 decision 8)
    url: https://node.example                # the PUBLIC HTTPS address: required with issuers; its /mcp is the resource
    issuers:
      - name: corp                           # a handle of at most 24 characters: names the server here and starts its clients' handles
        issuer: https://login.example.org    # the `iss` its tokens carry, exactly
        jwks_uri: https://login.example.org/keys   # optional: else found from <issuer>/.well-known/openid-configuration, then oauth-authorization-server
        algorithms: [RS256, ES256]           # optional: the signature algorithms accepted (default these two)
        scope: facilitator:participate       # optional: the scope a token must carry (default this)
        audience: https://node.example/mcp   # optional: the `aud` a token must carry (default the resource URL)
```

| Key | Default | Meaning |
| --- | --- | --- |
| `issuers[].name` | required | A lowercase handle of at most 24 characters, unique. It is the authorization server's name in `check`, `http issuers`, the metadata's docs and the first part of each of its clients' handles (`corp-alice`). |
| `issuers[].issuer` | required | The authorization server's issuer URL, `https://` (`http://` only on a loopback host, for tests), unique. A token's `iss` must equal it exactly; the protected-resource metadata names it as the authorization server. |
| `issuers[].jwks_uri` | discovered | Where the issuer's signing keys are. Unset: read from the issuer's OIDC discovery document, else its RFC 8414 one; that document must name the same `issuer`. |
| `issuers[].algorithms` | `[RS256, ES256]` | Any of RS256/384/512, PS256/384/512, ES256/384/512, EdDSA. **`none` and every `HS*` are refused, by `check` and again at the gate** (no shared-secret token, no algorithm confusion). |
| `issuers[].scope` | `facilitator:participate` | One scope name the token must carry, in `scope` (space-separated) or `scp` (a list). |
| `issuers[].audience` | the resource URL | The `aud` the token must carry. RFC 8707 says the token is issued for the resource, `<http.url>/mcp`; some servers fix their own audience (an API identifier), and then it is named here. |
| `http.url` | required with `issuers` | The public address a cloud AI dials. With issuers it must be `https://` (`http://` only on a loopback host, or on any address with `http.insecure: true`, for a local machine or a test environment; the metadata then advertises the http URL as given, and `check` and the log warn that tokens travel in plain text): TLS ends here (`tls_cert` and `tls_key`) or at a proxy (`behind_proxy: true`), as ADR-0070 decision 8 says for any address beyond loopback. |

`check` lints all of this and **fetches nothing** (it prints the issuers, the resource and the metadata URLs); a mistake is
named by option and the endpoint does not open. `facilitator http issuers` is the one command that fetches: it reads each
issuer's keys now and says `ok: JWKS <uri>: N key(s)` or `NOT READABLE: <why>` (exit 1 when one is not).

### What the node checks, in this order

1. **The issuer**: `iss` is exactly an allow-listed `issuer` (the token is read unverified only to find that).
2. **The algorithm**: in the entry's `algorithms`, before any key is touched.
3. **The signature**: by a key in the issuer's JWKS, found by `kid` (a token with no `kid` is accepted only when the JWKS
   holds one key). The JWKS is fetched over HTTPS without redirects (5 s, 256 KiB), kept an hour, and read again at most
   once a minute when a `kid` is unknown (a rotation).
4. **`exp`** (and `nbf`, `iat`) with 30 s leeway; `exp`, `iss`, `aud` and `sub` must be present.
5. **The audience** (RFC 8707): `aud` is, or contains, this node's resource URL (or the entry's `audience`).
6. **The scope**: present, else **403 `insufficient_scope`**.

Every refusal is a **401** with `WWW-Authenticate: Bearer error="invalid_token", resource_metadata="<url>"` and no detail in
the answer (the reason goes to the node's log, one line a reason a minute, never a token); a missing token is a 401 with
only `resource_metadata` (that is how a cloud AI finds where to log in, and it is not counted as a failure). Ten refused
tokens from an address block it, as for bearer tokens. **When an issuer's keys cannot be read the node fails closed**: a
token of that issuer is refused with **503** (`retry-after`), not counted against the caller, and the log says why
(`issuer corp: JWKS https://...: the server answered 500`, `no discovery document ..., set jwks_uri`, `its discovery
document names the issuer ...`). Keys already cached keep working for their hour, then are dropped if they still cannot be read.
`/.well-known/oauth-protected-resource` and `.../mcp` (RFC 9728) answer only when issuers are set:
`{resource, authorization_servers, scopes_supported, bearer_methods_supported: [header]}`. The token is read from the
`Authorization` header only and is never passed on or stored.

### Who the client is: the (issuer, subject)

An OAuth client of the node is **the issuer and the subject** of its token. The subject is the account the authorization
server vouches for, so a person approves a person; it is stable across logins. The other candidate, the OAuth `client_id`,
is the *application*: one claude.ai connector has one `client_id` for every user of it, and dynamic registration may give
a new one each time, so approving a `client_id` would approve everyone who uses that connector, or nobody twice. The
`client_id` (or `azp`) is recorded as a label in `http list --json`.

- **Enrolment.** The first valid token of an unknown (issuer, subject) enrols the client (`enrolled`, no secret kept; an
  `enrolled` line in `http/audit.jsonl` and the signed audit register, by `oauth: <issuer name>`). Its first message is
  **held** until a person approves it (`facilitator http approve <client>`, or the approve tool): exactly as for a bearer
  client, for `approval_ttl` (30 days at public, ruling HC4), and a person's `mail` names it. Enrolled-and-unapproved
  clients count towards the same cap of 20 (a new subject past it is refused, 401).
- **Handle.** `<issuer name>-<subject>`: the subject lowercased, other characters turned to `-`, cut at 28 characters; when
  that changed it, an 8-hex hash of (issuer, subject) is added, so two subjects never share a handle by their look alone
  (`corp-alice`, `corp-bob-smith-ops-1f3a9c20`). A handle that is a participant's or a person's is refused. The table keeps
  the issuer and subject: a handle held by another pair is refused too.
- **Mapped like a bearer client**: the roster entry is kind `http`, signed for by the node, level `http.<home domain>`
  (public unless `mesh.yml` maps it private), **never `human`**, the participant tools only (no `continue`, no
  `approve`), the public limits, the reach rule. `data.via` is `{transport: http, auth: oauth, client, issuer, subject}`;
  `transcript` says `(via HTTP, authenticated by OAuth, client corp-alice, issuer https://login.example.org, subject alice)` and
  `verify` shows `via http (oauth, client corp-alice, issuer ..., subject alice)` and fails a packet that says OAuth and
  names no issuer and subject. **The subject is written into the record**: when your issuer's subject is an email address or
  another personal identifier, so is it there (an opaque subject, such as a UUID, is kept as one).
- **Revoke and deny** close the client at once, as for bearer; a revoked or denied OAuth client **stays refused**: a new
  token of the same subject does not bring it back (a person's decision stands) until a person runs `http forget`.

### Connect a cloud AI (a claude.ai custom connector)

Not run from the devhost (no cloud AI reaches it): run it once by hand, and report what differs.

1. **A public HTTPS address** for the node, reachable from the vendor's cloud: a reverse proxy with a certificate in front of
   `http.listen` (`behind_proxy: true`), or `tls_cert` and `tls_key` on a port that is open. Set `http.url` to it. A node on a
   laptop behind NAT has none and stays local-only for cloud AIs.
2. **An authorization server** that issues **JWT access tokens** (not opaque ones) and supports OAuth 2.1 with PKCE and the
   `resource` parameter (RFC 8707), and how the cloud AI registers: a pre-registered client (claude.ai asks for a client ID and
   secret under "advanced settings" of the connector), dynamic client registration, or client ID metadata documents. Its
   discovery document (`/.well-known/openid-configuration` or `/.well-known/oauth-authorization-server`) must be reachable from
   the node, or set `jwks_uri`. The authorization server must allow the cloud AI's redirect URI (claude.ai's callback
   is `https://claude.ai/api/mcp/auth_callback`). Access tokens must carry `aud` = `<http.url>/mcp` (the node's resource), or you name the
   `audience` your server uses, and the scope `facilitator:participate` (or the `scope` you set), so create that scope or
   permission at the server and grant it to the people who may connect.
3. **List it** in `facilitator.yml` (`http.issuers`) with a `name`, run `facilitator check` (names the issuers and the metadata
   URL) and `facilitator http issuers` (reads the keys now), and start the node (`infra up`, or `facilitator http serve`).
4. **In claude.ai**: Settings, Connectors, "Add custom connector": the name `facilitator` and the URL
   `https://<host>/mcp` (the resource, with `/mcp`). claude.ai calls it, receives the 401 with `resource_metadata`, reads the
   protected-resource metadata (`https://<host>/.well-known/oauth-protected-resource/mcp`, which names your authorization
   server), and sends the person to log in there; after that it calls the tools with the access token.
5. **On the node**: `facilitator http list` shows the new client (`OAuth, subject ... of <issuer>`, enrolled); its first `say`
   is held; a person approves it (`facilitator http approve <handle>`); then it converses with the agents the node exposes
   `public`, and `facilitator verify --conv <id>` shows `via http (oauth, ...)`.
6. **If it does not connect**: the node's log (`facilitator infra logs http`) says why a token was refused (the audience, the
   scope, the issuer, the algorithm, or keys that cannot be read); `curl -i https://<host>/mcp` must show a 401 with
   `resource_metadata`, and the metadata URL must answer 200 with your server in `authorization_servers`.

What was checked here and what was not: the resource server (metadata, challenges, every token check, enrolment, approval,
`via`) is exercised end to end by test/facilitator/oauth_flow.sh with a local test issuer and an MCP client that holds an
OAuth token. How claude.ai (or any cloud AI) discovers, registers and logs in was read from the MCP authorization
specification and the vendor's documentation, and has **not** been run against this node.

### Test it locally (Keycloak and Claude Code)

Without a public HTTPS address (the usual case on a workstation) the OAuth path is tried on one machine: **Keycloak** is the
login server and **Claude Code** the OAuth client (which registers itself, as a cloud AI would). `task facilitator:oauth-local`
starts both, waits for them and prints the steps; `-- down` removes the container and the state (no network, no volume).

```
 Claude Code ---- /mcp, Authenticate ---->  browser  --- login (tester) ---> Keycloak 26.8.2 (internal Docker, 127.0.0.1:8080)
      |   registers itself (dynamic client registration), code + PKCE + resource=http://localhost:8765/mcp    |
      +--- Bearer <JWT: aud, scope facilitator:participate> ---> node (127.0.0.1:8765, http.insecure, issuer kc) --> jester (test agent)
```

- **Keycloak**: `quay.io/keycloak/keycloak:26.8.2`, pinned by digest, `start-dev`, the realm `facilitator-test` imported from
  `test/facilitator/oauth-local/realm.json`: a user `tester` whose password is made at each start and printed (never committed), the
  client scope `facilitator:participate` (a default scope, in the token's `scope`) with an audience mapper that puts
  `http://localhost:8765/mcp` in `aud`, the `sub` claim, RS256, and anonymous dynamic client registration for `localhost` redirect
  URIs (Keycloak's Trusted Hosts and Allowed Client Scopes policies, set in the realm file). Tokens are plain JWTs, so the node's
  checks needed no change.
- **The node**: `http.url: http://localhost:8765`, `http.insecure: true` (plain http, warned about in the log and in `check`), one
  issuer `kc`, and the test agent `jester` exposed `public`; run from the bundle's python (`FACILITATOR_BUNDLE` or `dist/`).
- **Where the browser runs**: the page of the login is Keycloak's, so the browser must reach `localhost:8080`, and the port
  Claude Code listens on for the redirect (`--callback-port 8976`); Claude Code must reach `localhost:8765`. This devhost
  forwards no ports (no `forwardPorts` or `appPort`), so the simplest way is Claude Code on the workstation with `"appPort": [8080,
  8765, 8976]` in the devhost's `devcontainer.json` (your own checkout, a rebuild applies it); the printed steps say the same.
- **Steps** (printed with the real password): `claude mcp add --transport http --callback-port 8976 facilitator
  http://localhost:8765/mcp`; in Claude Code `/mcp`, `facilitator`, Authenticate, sign in as `tester`; then ask it to say who is
  there and send "hello" to `jester`. On the node: `task facilitator:oauth-local -- fx http list`, `fx http approve <handle>`,
  `fx verify --conv <id>` (shows `via http (oauth, ...)`).
- **What is proven without a browser**: `task test:facilitator-oauth-local` does what Claude Code does against this Keycloak and
  node: the 401 and the metadata, dynamic registration, the login form posted, code + PKCE + `resource`, the token (RS256, `aud`,
  `scope`), then enrolment, approval, the agent's answer and `verify`. Not proven here: Claude Code's own browser
  login (which of the two redirects and which scope it asks for), which is why the steps above are for you to run once.

## Using it in devcontainer.json

```jsonc
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/openbao:1": {},       // optional: keys in OpenBao
  "ghcr.io/nabil-becker/devcontainer-features/facilitator:0": {}
}
```

Then, in the repository: `.devcontainer/participants.yml` (or the existing `.devcontainer/agents.yml`):

```yaml
participants:                      # or agents: (the participant component's list, ADR-0061)
  - name: jester                   # the handle: lowercase letters, digits, - and _
    cli: openai-compatible
    kind: resident
    definition: personas/jester.md # the persona, sent as the model's system prompt
    description: tells jokes       # into the OASF record
    skills: [humour]
  - name: domain-expert-one
    cli: claude
    kind: resident
    attachment: mcp                # mcp (the default) | pump (a later slice)
```

and, optionally, `.devcontainer/facilitator.yml`:

```yaml
facilitator:
  humans: [you]                    # the people; each attaches their own session over MCP (default [you])
  fallback: domain-expert-one      # gets a group message addressed to no one (default: everyone)
```

## Verify

```sh
facilitator version          # facilitator 0.3.0 (backend agntcy; mode node; ...), bundle 0.3.0 linux-amd64, dirctl 1.9.1, slimctl 3.4.6
facilitator infra status     # agent, dir and slim healthy, every port on 127.0.0.1
facilitator check            # one line per part; exit 0 when ready
```

The jester scenario (the participants are started by you or your harness; you talk from Claude Code):

```sh
facilitator register --all                       # keys and tokens (yours too), OASF records in the Directory
facilitator snippet domain-expert-one            # how to attach its Claude Code (prints commands, runs none)
FACILITATOR_TOKEN="$(cat $FACILITATOR_HOME/tokens/jester)" \
  facilitator model --as jester --endpoint http://localhost:11434/v1 --model llama3.2 --definition personas/jester.md &
facilitator snippet you                          # your own session: the entry, the environment, the hook
FACILITATOR_HANDLE=you FACILITATOR_TOKEN="$(cat $FACILITATOR_HOME/tokens/you)" claude
#   > ask @jester to tell @domain-expert-one a joke      (say)
#   > any mail?                                          (mail)
facilitator verify --conv <id>                   # every message back to your signed one
```

### Talking to the agents from Claude Code (in place of `facilitator chat`)

`facilitator chat` and `facilitator send` are gone in 0.2.0 (the Operator's ruling of 2026-11-20: "remove
the chat, essentially making it just accessible through the MCP"). What you did in the chat, you now ask
your own Claude Code session to do; it calls the facilitator's tools for you.

1. Once: `facilitator register you` (or `register --all`; a person needs a token since 0.2.0), then
   `facilitator snippet you`, and run the `claude mcp add --scope user facilitator -- facilitator mcp` it
   prints (the same entry every agent uses; it names no handle).
2. Start Claude Code with your handle and token in its environment:
   `FACILITATOR_HANDLE=you FACILITATOR_TOKEN="$(cat $FACILITATOR_HOME/tokens/you)" claude`. Tokens are made
   again at each container start: start the session after the container, never put the token in the entry.
3. Optional: paste the `UserPromptSubmit` hook that `snippet` prints into `~/.claude/settings.json` (or
   `.claude/settings.local.json`). At each prompt it shows "Facilitator: N new messages in c-..." or
   nothing; it never fails a turn (`... 2>/dev/null || true`, a 10 s timeout, a cached answer when nothing
   changed). The Feature never writes Claude's settings (NFR-13).
4. Talk: "ask @jester for a joke" (`say`, a new conversation); "tell @jester and @domain-expert-one ..."
   (a group); "say in c-1a2b3c4d: ..." (`say` with `conversation`); "any mail?" (`mail`); "show me
   c-1a2b3c4d" (`transcript`); "who is there?" (`who`); "continue c-1a2b3c4d" when it paused (`continue`).

| `chat` did | Now |
| --- | --- |
| `@jester ...` with no conversation | `say {text: "@jester ..."}` (or `conversation: "new"`, `to`) |
| a line in the current conversation | `say {text, conversation: <id>}` |
| `/new group a b`, `/new direct a` | `say {text, to: [a, b]}` / `say {text, to: [a]}` |
| the transcript followed live | `mail` (unread, never waits) and `transcript {conversation, limit?}`; the turn hook says when there is mail |
| `/continue` | `continue {conversation}` |
| `/who`, `/convs` | `who` (handles and your conversations) |
| `facilitator send` in a script | none: a script attaches over MCP with a person's handle, or is an agent |

Copilot CLI: the same entry (`copilot mcp add facilitator -- facilitator mcp`) and environment. Copilot
has no hook that can show a line at each turn, so ask it "any mail?"; in a shell,
`facilitator mail --as you --notice` prints the same line.

### What changes for a person (option A)

Until 0.1.0 every message of yours began a new chain at hop 0, so a loop through your session (your
assistant answering an agent, the agent answering back) never hit the hop limit. From 0.2.0 a message of
yours in a conversation answers its last message and counts one hop more, like any other; it is held
like any other when the conversation is paused or past the hop limit. Only `continue` (your session's
tool; an agent is refused it) lets the conversation run another `hopLimit` (and resets the budget); its
last held message, often yours, is then delivered. With the default limit of 6, you get three exchanges
with one agent before you are asked to continue. A message in a new conversation (`say` with no
conversation, or `"new"`) still begins a new chain at hop 0. The message budget (40) and the rate (10 a
minute, which a person's messages are not counted against) are unchanged.

## Options

| Option | Default | What, and when to change it |
| --- | --- | --- |
| `installTaskfile` | `true` | The Taskfile, as every Feature. |
| `backend` | `agntcy` | What carries the directory and delivery. `lean` (packet-relay) is refused in this version: "not yet: slice 5". `FACILITATOR_BACKEND`. |
| `mode` | `node` | `node`: the whole bundle; the Directory, the SLIM node and the ssh-agent run here (`autostart`). `leaf`: **the thin client only**, for a machine that runs no node: the bundle without `slimctl`, no daemon at container start, `infra up` and `node run` refused, `check` ready without them. A leaf connecting to a node over the network (`facilitator mcp --node`) is not built yet (slice N3 built hubs and spokes): it installs and answers MCP but has no node to reach. `FACILITATOR_MODE`. |
| `bundleVersion` | `0.4.0` | The node bundle (the release `facilitator-bundle-v<version>`), checked against `digests.txt`; `latest` means the bundle this Feature version was made with. With no pin, the bundle is built from the Feature's own source (above). |
| `dirVersion` | empty | **Deprecated in 0.3.0** (above): `1.9.1` or `latest` accepted with a notice, anything else refused. |
| `slimVersion` | empty | **Deprecated in 0.3.0** (above): `3.4.6` or `latest` accepted with a notice, anything else refused. |
| `hopLimit` | `6` | Hops since the message that began the chain (a person's later messages count too) before the conversation pauses. The default of the local and private levels; `mesh.yml` `limits` overrides it per level (ruling AD). `FACILITATOR_HOP_LIMIT`. |
| `messageBudget` | `40` | Messages between two `continue`; past it participants' messages are kept and held. The local and private default, as `hopLimit`. `FACILITATOR_MESSAGE_BUDGET`. |
| `rateLimit` | `10` | Messages a participant may write in a minute; one more is refused, not written. The local and private default, as `hopLimit`. `FACILITATOR_RATE_LIMIT`. |
| `receiveWaitSeconds` | `300` | How long `receive` blocks without `wait_seconds` (a 300 s call held in the T1 run). `FACILITATOR_RECEIVE_WAIT_SECONDS`. |
| `staleSeconds` | `900` | Without a `receive` for this long a participant counts as not attached. `FACILITATOR_STALE_SECONDS`. |
| `facilitatorBudget` | `20` | Model calls per conversation for the AI facilitator; read and shown, unused before slice 6. `FACILITATOR_BUDGET`. |
| `identity` | `false` | AGNTCY Identity (needs Docker); `true` is refused: "not yet: slice 7". |
| `autostart` | `true` | `postStartCommand` runs `facilitator infra up`, never fatally; nothing in mode `leaf`. Turn off to start it by hand. `FACILITATOR_AUTOSTART`. |
| `dirOnlineCheck` | `false` | Check each pushed record against the online OASF schema server; off, the Directory checks nothing (`policy.operations: []`, ruling F). |

**Settings are plain variables too** (NFR-6), resolved: the command line, the repository's `.env`,
`.devcontainer/.env`, the environment, then the options as installed. Besides those above:
`FACILITATOR_HOME`, `PARTICIPANTS_FILE` (alias `AGENTS_FILE`), `FACILITATOR_FILE`, `FACILITATOR_MESH_FILE` (the
node's `mesh.yml`, default `.devcontainer/mesh.yml`; above), `FACILITATOR_AGENT_JOB_VARS` (more variables that mark an
agent's job, which `node invite` and `node revoke` refuse), `FACILITATOR_HANDLE` and
`FACILITATOR_TOKEN` (who `facilitator mcp` attaches as, set per CLI by its harness or by the person), the ports
(`FACILITATOR_DIR_PORT` 8888, `FACILITATOR_DIR_OCI_PORT` 5555, `FACILITATOR_DIR_P2P_PORT` 8999,
`FACILITATOR_DIR_GATEWAY_PORT` 8889, `FACILITATOR_SLIM_PORT` 46357), `FACILITATOR_KEYS` (`auto` | `openbao` |
`file`), `FACILITATOR_DIRCTL` and `FACILITATOR_SLIMCTL` (other binaries), and, for tests only,
`FACILITATOR_TRANSPORT=poll` (no SLIM: the record is read every half second; `check` says so).

## State

`FACILITATOR_HOME` (`/var/lib/devcontainer-features/facilitator`, the named volume
`facilitator-state-${devcontainerId}`, made the remote user's by `facilitator-setup` through `dcf-persist`):
`conversations/<id>/` (one register-engine store per conversation), `roster.json`, `anchors` (the
facilitator's own key, the anchor of every conversation's roster), `keys/` (public keys; private ones only
in the fallback), `tokens/`, `attach/` (when each participant last called `receive`), `mail/` (what each
person's `mail` handed over, and the turn hook's cached line), `dir/` (the
Directory's data, `node.key` included), `slim/` (its rendered config), `secrets/` (fallback only), `run/`
(pidfiles, the ssh-agent's socket), `logs/`, and in a mesh `mesh/`: `certs/<domain>/` (the node's key, mode 600,
its certificate and the domain's trust bundle), `cards/` (the other nodes' admitted cards), `convs/` (which node
each member of a shared conversation is on), `outbox/`, `refused.log` (lock two's refusals), `status.json` (the
peers part), on a hub `roster.json` and `invites.json` (join tokens, hashed), `secret` (the mesh's SLIM app secret). With the endpoint over HTTP, `http/`: `clients.json` (each client's state and the SHA-256 of its token, mode 600; never a token), `audit.jsonl` (the hash-chained log) and `status.json` (the `http` part's pid and address).
**Conversations are working data**: lost with the volume,
never committed (D12); a tier-2 mirror is a later item.

### Keys: OpenBao, or the 0.1.0 fallback (an ADR-0048 exception)

`facilitator register` makes an Ed25519 key per identity (each participant, each human, and
`facilitator`). When OpenBao answers `ready` (`dcf-secret status`), the private half goes to
`facilitator/keys/<handle>` and is never written to a file: it is loaded through a pipe into the
facilitator's own ssh-agent for the sitting, and packets are signed through the agent. **When OpenBao is
not ready, the private key is kept in `keys/<handle>`, mode 600, in the volume, and `keys/FALLBACK` says
so.** This is a written exception to ADR-0048 for 0.1.0 only: a downloader without the openbao Feature can
still sign. The fallback stays for the 0.x versions and is removed at 1.0 (the Operator's ruling of
2026-11-20): from 1.0 a key is only ever in OpenBao. `facilitator register <handle> --new-key` moves a key
into OpenBao once it is there.
`FACILITATOR_KEYS=openbao` refuses the fallback.

### Participant tokens (the ADR-0048 exception of ADR-0061)

`tokens/<handle>` (mode 600) is made at registration and again at every container start
(`facilitator-start`), valid only in this container, for each participant and, since 0.2.0, each person.
The participant's harness (or the person) puts it in the CLI's environment as `FACILITATOR_TOKEN`, with
`FACILITATOR_HANDLE`; the MCP server it starts inherits both and is refused without a matching token.
Whether a caller is a person or an agent comes from the roster (`register` takes it from
`facilitator.yml`'s `humans`), never from the caller. The
token is never written into the CLI's MCP entry (`claude mcp add`, an MCP config file), because tokens are
made again at each start and an entry would go stale; `facilitator snippet` says so. Every
process of one Linux user can read every token: this stops one participant writing as another by
mistake, not an attacker.

## Commands and tasks

| Task | Command | What |
| --- | --- | --- |
| `facilitator:version` | `facilitator version` | What is installed. |
| `facilitator:check` | `facilitator check [mesh.yml... \| -] [--format json]` | One line per part, each port's owner when it is taken, each participant registered and last seen, and the mesh: the file, the certificate, what is open beyond loopback, the hub, TLS refusals and lock two's refusals; no secret printed; exit 1 when not ready. With paths: lints mesh files (NFR-11). |
| `facilitator:explain` | `facilitator explain <handle or SPIFFE ID>` | The level it gets here, what it reaches, each level's effective limits and where each came from. Read only. |
| `facilitator:node-invite` | `facilitator node invite` | On a hub: a join token (single use, 15 minutes). Refused inside an agent's job. |
| `facilitator:node-join` | `facilitator node join --token <token or file> [<join address>]` | On a spoke: its certificate from the hub's issuer; the hub into `mesh.yml`. |
| `facilitator:node-revoke` | `facilitator node revoke <node> [--yes]` | On a hub: no renewal, refused by lock two. Asks to confirm; refused inside an agent's job. |
| `facilitator:node-approve` | `facilitator node approve <request> [--yes]` | On an issuer of a public domain: approve a public node's join request (its key, for the public domain); issues its certificate. Refused inside an agent's job. |
| `facilitator:node-requests`, `node-deny`, `node-peer`, `node-request`, `node-collect`, `node-secret`, `audit` | `facilitator node requests\|deny <request>\|peer --token <t>\|request <info>\|collect\|secret`, `facilitator audit verify\|replay\|show` | Slice N5a: public join requests, pairing two peers, a public node's request and collection, the mesh secret, the signed audit register. |
| `facilitator:node-issuer` | `facilitator node issuer status\|export-root --out <file>\|migrate [--openbao <url>] [--mount <m>] [--token-file <f>]` | The hub's issuer tier (read only); the built-in root CA's key out of the volume to a new file; the built-in CA moved into an OpenBao PKI, the same CA. `export-root` and `migrate` are a person's acts: refused inside an agent's job. |
| `facilitator:node-status` | `facilitator node status` | The peers part, the admitted cards, a hub's roster, the last refusals (JSON). |
| (no task) | `facilitator node bundle <domain> --file <pem>`, `node renew`, `node restore-roster`, `node peers` | A federated domain's trust bundle; renew this spoke's certificate now; a hub's roster back from OpenBao or from its volume; the peers part in the foreground (`infra up` starts it). |
| `facilitator:http-token` | `facilitator http token <client> [--label ..] [--as <person>]` | A bearer token for an HTTP client, shown once (only its hash is kept). A person's act: refused inside an agent's job. |
| `facilitator:http-forget` | `facilitator http forget <client>` | Lets a revoked or denied client back as new (an OAuth login enrols again, held for approval). A person's act; a live client is refused. |
| `facilitator:http` | `facilitator http list\|audit\|approve <client>\|deny <client>\|revoke <client>` | The clients (no secret), the audit chain, first-contact approval, the end of a client's token. `approve`, `deny` and `revoke` are a person's acts. `http serve` is what the `http` infra part runs. |
| `facilitator:setup` | `facilitator-setup` | The state folder and the facilitator's key (idempotent, never fatal). |
| `facilitator:infra` | `facilitator infra up\|down\|status\|logs [agent\|dir\|slim\|peers\|http]` | The infrastructure; `up` is idempotent, nothing is restarted on a crash (`status` says so). |
| `facilitator:participants` | `facilitator participants` | The list and who is registered. |
| `facilitator:register` | `facilitator register <handle>... \| --all` | Key, token, OASF record. |
| `facilitator:status` | `facilitator status` | Who is attached; each conversation's messages, hops, budget, pause. Read only. |
| `facilitator:mail` | `facilitator mail [--as <h>] [--limit n] [--json] [--notice\|--hook]` | A person's unread messages, read only (the MCP `mail` marks them read). `--notice`: one line or nothing; `--hook`: the same as Claude Code hook JSON. Both always exit 0. |
| `facilitator:transcript` | `facilitator transcript --conv <id> [--limit n] [--json]` | Messages, routes, task states, notices. Read only. |
| `facilitator:verify` | `facilitator verify --conv <id> [--message <id>] [--format json]` | Exit 0 a good chain, 1 a break, 2 bad usage. |
| `facilitator:snippet` | `facilitator snippet <handle>` | The one shared `claude mcp add` command (or MCP entry), the `FACILITATOR_HANDLE` and `FACILITATOR_TOKEN` lines, the persona sentence; for a person, the turn hook and the Copilot note. |
| (a harness, or the person's CLI, runs it) | `facilitator mcp [--as <handle>]` | The MCP server a CLI starts; the handle from `FACILITATOR_HANDLE` when `--as` is absent (exit 2, naming both, when neither is set). |
| (a harness runs it) | `facilitator model --as <h> --endpoint <url> --model <m> --definition <file>` | The local-model wrapper. |
| (`postStartCommand`) | `facilitator-start` | Tokens made again; `infra up` when `autostart`; nothing in mode `leaf`. |
| (the node image's entrypoint; no task) | `facilitator node run` | The node in the foreground: setup, then the ssh-agent, the Directory and SLIM; a signal stops all three (exit 0), one dying stops the rest (exit 1). In a devcontainer use `infra up` instead. Refused in mode `leaf`. |

Removed in 0.2.0: `chat`, `send` and `continue` (a person's `continue` is the MCP tool, so no process
without the person's token can continue a conversation).

### The MCP tools (the attachment contract)

The tools listed follow the handle's kind in the roster; a tool of the other kind is refused.

An agent's:

| Tool | Arguments | Returns |
| --- | --- | --- |
| `receive` | `wait_seconds?` (0 to 3600) | `MESSAGE in conversation ...` with `structuredContent.message` {conversation, message_id, from, text, members, hops, parts}; or `nothing yet`. Several replies to one question waiting at once come as one turn (the collector, plain joining). |
| `reply` | `text`, `to?` | Answers what `receive` handed over (`reply_to`, hops + 1); no mention: back to the asker. Completes the delivery's A2A task. |
| `say` | `text`, `conversation?` (an id or `new`), `to?` | A turn in another conversation; needs a message received first (every chain begins with a human). |
| `who` | none | The handles, attached or not, and your conversations. |

A person's (none of them waits):

| Tool | Arguments | Returns |
| --- | --- | --- |
| `say` | `text`, `conversation?` (an id, or `new`), `to?` | No conversation, or `new`: one is made with the handles named (`@mention` or `to`; direct for one, a group for more) and your message is the chain's root, hop 0. A conversation of yours: your message answers its last message, one hop more (option A). Says where it went, or why it is held. |
| `mail` | `limit?` (1 to 200, default 20) | The unread messages of every conversation you are in, by conversation (the one with the oldest unread first), each in its order, with `from`, `hops`, whether it was addressed to you and whether it was held; then marked read. `more` counts what stays unread; paused conversations are named. `no new messages` when there are none. |
| `transcript` | `conversation`, `limit?` (1 to 500, default 50) | A conversation you are in: its last `limit` messages with their routes and notices, and how many earlier ones are not shown. |
| `continue` | `conversation` | A paused conversation runs another hop limit (and its budget is reset); its last held message is delivered. The only thing that resets the hops. |
| `approve` | `client` | An HTTP client's first contact (slice N4): its held messages are delivered. `mail` names the clients that wait. |
| `who` | none | As an agent's. |

An **HTTP client's** (over `facilitator http serve`, never `human`; "MCP over HTTP for CLIs" above): `who` (only what its
level reaches), `say` (begins a conversation, or writes in one of its own, answering its last message), `reply`, `receive` (at most `http_receive_wait`),
`mail` and a read-only `transcript` that shows each packet's `via`. Never `continue` or `approve`.

### The record: the `conversation` register type

One register per conversation, named by its id (`c-<8 hex>`); the facilitator's key is the anchor and
writes the roster (each member's key, role `agent`). The kinds (field names from AOF's `messages` type):

| Kind | Data | Written by |
| --- | --- | --- |
| `thread` | `thread, kind (group\|direct), members[], humans[], title?` | facilitator |
| `message` | `thread, message_id, parts[{kind: text, text}], root, hops, reply_to?, mentions?, to?, refs?` | the member it is from |
| `route` | `thread, message_id, rule, to[], tasks[{task, assignee}], held[{principal, reason}]` | facilitator |
| `status` | `task, state (working\|completed\|...), text?` | the task's assignee |
| `notice` | `thread, code (stale\|hop-limit\|budget\|paused\|not-member\|unknown-handle\|...), text, refs?` | facilitator |
| `continue` | `thread, upto` | a human member (through the `continue` tool) |

Lineage: `reply_to` (what it answers), `refs` (what it derives from, the root always last), `root` (the
human message the chain began with; a person's message in a new conversation is its own root at hops 0,
and one in an existing conversation answers its last message, hops one more), `hops`, and the A2A task of
each delivery in its route.

## Pairs with

- **openbao**: keeps the keys and SLIM's secrets; without it, the 0.1.0 fallback files.
- **claude-code**: a Claude Code participant, or your own session; `facilitator snippet <handle>` prints
  the shared `claude mcp add` and, for a person, the turn hook. The claude-code Feature's `attach` option (a
  later step) will run that through the CLI's own command.
- **copilot**: a GitHub Copilot CLI participant, or your own session; its `attach: facilitator` registers the
  same shared entry through `copilot mcp add`, with the handle and token from the environment (no token in
  the entry), and its `agent-adapter-copilot run-once` is the pump's route.
- **register-engine**: optional; with it, `register-engine verify <store> --register <id> --type conversation`
  reads a conversation too. This Feature carries its own copy of the engine and of sign-packet's library.
- **go-task**: the Taskfile. Needs OpenSSH, installed with apt when missing; no system Python (the bundle has its own).

## Limits

- Hub and spoke with local and private trust across nodes (slice N3); MCP over HTTP serves CLIs with static bearer
  tokens (slice N4) and cloud AIs with OAuth tokens from an allow-listed issuer (slice N5b) on one node; public trust across
  nodes, a node joining by key and approval, and peer to peer are slice N5a. The endpoint serves one node: a client reaches
  the agents of the node it dials only.
- A bearer token has no expiry and no rotation but revoke and a new token; there is no per-token scope. An OAuth token
  expires as its issuer says, and its issuer's scope is checked on every call; the node does not introspect or revoke
  tokens at the issuer (a person's revoke of the client is the node's own, immediate).
- A revoked or denied OAuth client stays refused until a person runs `facilitator http forget <client>`; its next token then enrols it anew.
- Only JWT access tokens are accepted (no token introspection, no opaque tokens), from issuers named in `facilitator.yml`.
- The audit of enrolments is a hash-chained log in the volume, not a signed register: a person with the volume can
  rewrite it whole (a cut or an edit shows; a rewrite of the chain does not). A signed `audit` register type is a
  backlog item; approvals and denials are also signed notices in the conversations.
- An HTTP client that calls `say` begins a conversation (hop 0, the node vouches for it) where
  an agent may not: it is the only non-person that starts a chain, bounded by the public limits, the reach rule and
  the approval; `continue` stays a person's.
- A leaf (`mode: leaf`) has no way to reach a node yet: N3 built nodes, not leaf clients.
- Revocation is the certificate's 24 h lifetime plus lock two: SLIM checks no revocation list, and a renewed
  certificate or a changed bundle reaches the SLIM node only when it restarts (its `reload_interval` and
  `reload_client_ca_file` did nothing in 3.4.6 here); the peers part restarts it after a renewal.
- The mesh's SLIM app secret is shared by every joined node and is not rotated when one is revoked (lock one and lock
  two still refuse it).
- dirctl 1.9.1 cannot switch mDNS off (above, "The Directory, and mDNS").
- The arm64 bundle is built (a cross build) and checked here, but runs only on the arm64 runner of
  `release-bundle`; nothing on arm64 runs in CI's Feature tests.
- `agntcy` only; `lean` (packet-relay) is slice 5, and there is **no silent fallback**: when the
  Directory or SLIM cannot start, `check` says why.
- No model in the facilitator (slice 6): a group message addressed to no one goes to the `fallback`
  participant or to every member, bounded by the limits. `facilitatorBudget` is unused.
- The pump attachment and the vendor Features' `attach` option are not in this version.
- A slow participant holds its chain; no reply timeout before a person's `continue`.
- A person's session is not woken by a message: it sees mail when it calls `mail` (Claude Code's turn
  hook says so at the next prompt). Copilot CLI has no such hook.
- With option A a person gets `hopLimit / 2` exchanges with one agent before a `continue`; a new
  conversation begins a new chain.
- The participant component's own `agents` command does not know `participants:`, `attachment`,
  `description` or `skills` yet; it warns on the three keys and reads only `agents.yml`.
- SLIM runs basic auth over plain-text loopback (its log warns about it); the SLIM node keeps no state, so a
  restart drops sessions (the record keeps every message).
- Attribution is "which registered identity, via which authenticated route", not proof of intent, with
  one Linux user for every participant.
- Troubleshooting: `facilitator check` names the part and a port's owner; `facilitator infra logs dir|slim`;
  `facilitator verify` names each broken link.

### Manual checklist (real vendors, with your own credentials; none runs in CI)

1. `facilitator infra up && facilitator register --all && facilitator check`.
2. Claude Code: `facilitator snippet domain-expert-one`, run the `claude mcp add` it prints, start Claude with
   the two environment lines, give it the persona sentence: it calls `receive`.
3. A local model: `facilitator model --as jester --endpoint <url> --model <name> --definition <file>`.
4. Your own Claude Code (`facilitator snippet you`, the hook added): "ask @jester to tell @domain-expert-one
   a joke"; at the next prompt the hook line; "any mail?" shows four messages; then `facilitator verify --conv <id>`.
5. A hop limit: two agents told to answer each other; the conversation pauses at `hopLimit`; "continue <id>".

## Why it exists

No published Dev Container Feature connects agents of different vendors in a devcontainer. AGNTCY
publishes the Directory and SLIM but no conversation store, limits or signed record; MCP gateways connect
one client to many servers, not agents to each other. This Feature runs AGNTCY's components as
infrastructure and adds what they leave out.

## Version and upgrade

Pinned, in the bundle: CPython 3.13.18, dirctl 1.9.1, slimctl 3.4.6, slim-bindings 3.3.9 (node and bindings move
together), and `mcp` 2.3.0 with its 27 dependency wheels, each by SHA-256 (the table in `bundle-build.sh`). An upgrade of the Feature replaces `/opt/facilitator` whole; the volume (conversations, keys, tokens,
the Directory's data) is kept. A new AGNTCY or CPython version is a new bundle (the script's pins), released by
`release-bundle` and pinned in `digests.txt`. 0.x: the MCP tools, the packet fields and the CLI verbs may still
change before 1.0.

**From 0.6.0 to 0.7.0:** rebuild the container (the Feature, and the node image). Nothing changes for a node that is not a
hub, and a hub with `node.issuer.openbao` keeps its OpenBao PKI. A hub with **no** `openbao` (it had a single built-in CA
from 0.6.0, or none) keeps working: a hub with no CA yet now makes a root and an issuing CA, and one made by 0.6.0 keeps its
single CA (so it cannot `export-root`: migrate it, or start a new hub). New: `node.issuer.ssh_agent`, `facilitator node
issuer status | export-root | migrate`, `check`'s issuer rows (and its warnings), the Kubernetes base in
`bundles/facilitator/k8s`, `task bundle:k8s` and `task test:facilitator-k8s`. The bundle is 0.7.0 (unreleased: until
`release-bundle` runs and `digests.txt` pins it, the Feature builds it from its own source).

**From 0.4.0 to 0.5.0:** rebuild the container. Nothing changes unless `facilitator.http.listen` is set: no port opens
and no client exists. `mesh.yml`'s `expose` now accepts `public` under `team`, and `limits` the keys `approval`,
`approval_ttl` and `http_receive_wait`. The bundle is 0.5.0 (it adds `mcp` 2.3.0 and its wheels, about 40 MB;
unreleased: until `release-bundle` runs and `digests.txt` pins it, the Feature builds it from its own source). The
person's MCP session gains the `approve` tool; the conversation type gains the optional `via` field and three notice
codes, so a 0.5.0 node's record does not load on a 0.4.0 node that meets a `via`.

**From 0.3.x to 0.4.0:** rebuild the container. Nothing changes without a `mesh.yml`: the node stays standalone.
The bundle is 0.4.0 (unreleased: until `release-bundle` runs and `digests.txt` pins it, the Feature builds it from its
own source). The node image's role is its mounted `mesh.yml`; the sample compose's hub is now a hub, which opens its
listener once its OpenBao issues its certificate.

**From 0.2.0 to 0.3.0:** rebuild the container. The tree moves from `/usr/local/lib/facilitator` to
`/opt/facilitator` (the commands stay on `PATH`); the Feature no longer installs Python from apt; drop
`dirVersion` and `slimVersion` (deprecated). A Directory that refused to start after a container was removed
("daemon already running") now starts: its stale `daemon.pid` is removed.

**From 0.1.0 to 0.2.0:** `chat`, `send` and `continue` are removed from the command line and the Taskfile
(talk from your own Claude Code session, above); `facilitator register you` again (or `--all`) to make
your token; a `snippet` entry with `--as` keeps working, the shared entry without it is the new form; a
person's messages now count as hops.

## Inside

| Path | What |
| --- | --- |
| `facilitator/app.py` | intake, the dispatcher, a person's mail, the session (an agent's receive, reply, say, who; a person's say, mail, transcript, continue, who) |
| `facilitator/router.py`, `guard.py`, `collector.py` | the routing rules, the limits, plain joining |
| `facilitator/record.py`, `signer.py`, `verify.py` | the record over register-engine, keys and signing, `verify` |
| `facilitator/transport.py`, `directory.py`, `infra.py` | SLIM, the Directory client, the infrastructure (the SLIM and Directory configs per role) |
| `facilitator/mesh.py`, `identity.py`, `peers.py` | `mesh.yml` and lock two's decision; certificates, cards, join tokens and the OpenBao issuer; what crosses between nodes and the peers part |
| `facilitator/clients.py`, `endpoint.py` | the HTTP clients (the table of hashed tokens, approval, the audit chain) and the endpoint over HTTP (the `mcp` library, the abuse gate, uvicorn), slice N4 |
| `facilitator/mcp.py`, `model.py`, `transcript.py`, `cli.py` | the MCP server, the model wrapper, the transcript, the command |
| `types.d/facilitator.py` | the `conversation` register type |
| `registerengine/`, `signpacket/` | copies of `src/register-engine` and `src/sign-packet` (`task registerengine:check`, `task signpacket:check`) |
| `bundle-build.sh` | the copy of `bundles/facilitator/install.sh` (`task bundle:check`) |
| `digests.txt` | the SHA-256 of each released bundle asset, one line each (`task bundle:pin`) |

Tests: `test/facilitator/unit/` (`task test:facilitator-unit`, part of `task lint`; `test_feature.py` builds a
skeleton bundle and installs it; `test_mesh.py` the mesh's policy and lock two), `test/facilitator/node_image.sh`
(`task test:facilitator-image`), `test/facilitator/mesh_flow.sh` (`task test:facilitator-mesh`: an OpenBao, a hub and
two spokes) and
`test/facilitator/integration/jester_flow.py` (`task test:facilitator-integration`; the `jester_flow` scenario) and
`test/facilitator/http_flow.sh` (`task test:facilitator-http`: the endpoint of a built bundle with Claude Code and Copilot
CLI for real, and a leaf client otherwise; `test_http.py` and `test_http_endpoint.py` are its unit tests).

## Changes

### [0.8.0] - 2026-11-24

Cloud AIs over OAuth 2.1 (slice N5b of the facilitator-node proposal; ruling PB3, ADR-0070 decisions 1, 2 and 5 to 8). The node is
an OAuth **resource server only**; bearer tokens keep working beside it, and a node that sets no `http.issuers` behaves as
0.7.0 (except that the well-known metadata path now answers 404 until issuers are set). Rebuild the container. No new
Python dependency: the bundle already carries PyJWT and `cryptography` (the `mcp` library's).

#### Added

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
- **`facilitator.http.insecure: true`** (ruling OA6): plain `http://` for `http.url` on any address, and the TLS rule beyond loopback waived, for a local machine or a test environment; every start and `check` warn that tokens travel in plain text; refused under `preset: open`.
- **`task facilitator:oauth-local`** (`oauth-local-keycloak`): Claude Code's OAuth login tried on one machine with no public address: Keycloak 26.8.2 (pinned by digest) in the internal Docker as the login server and a node with `http.insecure`; `task test:facilitator-oauth-local` runs the browserless part (dynamic registration, code + PKCE + resource, the token, the node) against them.
- NOTES: "MCP over HTTP for cloud AIs", a section per setting and how a person connects a claude.ai custom connector.
- Tests: `test_oauth.py` (a local test issuer; the right and the wrong audience, expired, wrong issuer, wrong scope, alg none,
  HS256 forged with the public key, a rotated key, keys that cannot be read, the endpoint's statuses and challenges, enrolment,
  approval, `via`), more in `test_http.py`, and `test/facilitator/oauth_flow.sh` (`task test:facilitator-oauth`): an MCP
  client holding an OAuth token end to end through a built bundle's endpoint.

#### Changed

- The well-known metadata path answers **404** on a node with no `http.issuers` (0.7.0 answered the library's metadata naming
  the node itself as its authorization server, which was wrong: a node hosts none).
- A revoked or denied OAuth client is no longer refused for good: a person can `forget` it.
- `facilitator.http.issuers` is no longer refused; a bare list of URLs is refused by name (an entry needs a `name`).

### [0.7.0] - 2026-11-24

The hub on Kubernetes (slice hub-on-kubernetes of the facilitator-node proposal; rulings K2 to K5, ADR-0078). Nothing changes for a
node that is not a hub, and a hub with `node.issuer.openbao` keeps its OpenBao PKI. Rebuild the container.

#### Added

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

#### Changed

- A hub's `check` no longer says it needs OpenBao: its issuer "must answer" (the built-in CA always does).

### [0.6.0] - 2026-11-23

Peer to peer and the cross-node public rules (slice N5a of the facilitator-node proposal; rulings AH, H4, HC3, ID2, PB3). Nothing
changes unless `mesh.yml` says `role: peer`, `preset: open` or `node.public`: no port opens. Rebuild the container.

#### Added

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

#### Changed

- `node approve` works (it was refused until now); `node invite`, `node revoke` also serve a peer; `trust` may map a domain
  `public` under `preset: open`; `copy: addressed` is accepted (and the only value at public).
- `bundleVersion` defaults to `0.6.0`: the Feature installs the published node bundle `facilitator-bundle-v0.6.0`
  (amd64 and arm64), pinned by SHA-256 in `digests.txt`.

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/facilitator/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/facilitator/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
