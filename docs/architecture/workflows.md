# Workflows

The main flows, in order. Sources: [PROCESS.md](../../PROCESS.md), [CLAUDE.md](../../CLAUDE.md),
[CONTRIBUTING.md](../../CONTRIBUTING.md), `.github/workflows/`, `.claude/skills/*/SKILL.md`.
Part of the [six](README.md). Node ids are ontology ids where they name a model thing; sequence diagrams use short ids, since a hyphen breaks a participant name there.

## 1. A session, start to close

The host commits and pushes; the host merges its own green, ready pull requests (ADR 0085); the Operator starts releases.

```mermaid
sequenceDiagram
  actor operator as Operator
  participant host as Host
  participant guards as Guards
  participant gh as git and GitHub
  Note over host: SessionStart hook
  host->>host: briefing (ledger, backlog, spend)
  host->>gh: branch task devhost:branch
  operator->>host: asks
  host->>host: work through tasks
  operator->>host: close-session
  host->>guards: task devhost:verify
  guards-->>host: green
  host->>gh: commit, push, open PR
  host->>gh: squash merge when green (ADR 0085)
```

The briefing arrives on its own. Work happens on a topic branch, never on `main`. Close runs the
records check, the guards and the diff scan before the commit.

## 2. A proposal

```mermaid
flowchart LR
  write["Write the proposal<br/>docs/proposals/"] --> review["architecture-review<br/>a subagent, the proposal alone"]
  review --> section["Adds an Architecture review section<br/>design sections untouched"]
  section --> rule{"The Operator rules"}
  rule -->|decided| backlog["backlog-item<br/>and an adr if long"]
  rule -->|declined| keep["Stays, with status line"]
  backlog --> build["Build in a PR<br/>updates the architecture documents"]
```

No proposal is in force until the Operator accepts it. The review comes before every ruling
([ADR 0039](../adr/0039-an-architecture-review-comes-before-every-ruling-and-nfr-13-says-we-manage-the-environment-not-the-cli.md)).
A proposal names which of the six architecture documents it changes ([README](README.md)).

## 3. A Feature change to a release

```mermaid
flowchart TB
  b["Topic branch<br/>type/id/n"] --> c["Change src/id/"]
  c --> v["Bump version<br/>and CHANGELOG entry"]
  v --> d["task docs<br/>commit src/id/README.md"]
  d --> pr["Pull request"]
  pr --> checks{"Required checks"}
  checks --> val["validate"]
  checks --> lint["lint"]
  checks --> tests["tests"]
  checks --> dco["DCO"]
  val --> m["Host squash merges when green<br/>(Operator, if governance)"]
  lint --> m
  tests --> m
  dco --> m
  m --> rel["release workflow<br/>manual, on main, the Operator starts"]
  rel --> reg["feature-registry<br/>ghcr.io tags: major, major.minor, full, latest"]
```

An agent says a release is due and what it would publish; it never runs it. Until the release, a
Feature cannot be named in `installsAfter` or pulled by a consumer. The release workflow needs
no write access: READMEs are committed, and the lint workflow checks they are current.

**A Feature that installs a release asset** (the facilitator and its node bundle, ruling AC of
[facilitator-node](../proposals/facilitator-node.md)) adds two manual workflows around the release, each
started by the Operator:

```mermaid
flowchart TB
  b["Topic branch: the application or bundles/facilitator/install.sh"] --> pr1["Pull request, required checks<br/>(the Feature tests build the bundle from source)"]
  pr1 --> m1["Host squash merges when green<br/>(Operator, if governance)"]
  m1 --> rb["release-bundle workflow<br/>manual, the Operator starts<br/>amd64 on ubuntu-latest, arm64 on ubuntu-24.04-arm"]
  rb --> asset["Release facilitator-bundle-v version<br/>two tarballs, SHA256SUMS, build attestations"]
  asset --> pr2["Pull request: task bundle:pin<br/>the digests into src/facilitator/digests.txt"]
  pr2 --> m2["Host squash merges when green<br/>(Operator, if governance)"]
  m2 --> rel["release workflow<br/>manual, the Operator starts"]
  rel --> reg["feature-registry"]
  m2 --> img["release-node-image workflow<br/>manual, the Operator starts<br/>refuses an asset that differs from the pin"]
  img --> ghcr["ghcr.io facilitator-node: version<br/>amd64 and arm64, attested"]
```

**One workflow does all of it.** `release-facilitator.yaml` (manual, the Operator starts it) calls `release-bundle`,
opens and waits for the pin pull request (the Operator approves it; the ruleset's review stays), then calls
`release.yaml` and `release-node-image` on the merge commit and verifies the image's provenance. The diagram above is
the sequence it runs and the manual fallback.

`release-bundle` needs `contents: write`, `id-token: write` and `attestations: write`; `release-node-image`
`packages: write` too; `release.yaml` keeps `contents: read` and `packages: write`. Sources:
`.github/workflows/release-bundle.yaml`, `.github/workflows/release-node-image.yaml`, `src/facilitator/NOTES.md`
("The bundle").

## 4. A con's job

```mermaid
sequenceDiagram
  participant host as Host
  participant con as Con
  participant hook as Stop hook
  participant scribe as Scribe
  host->>con: brief (job, bounds, model, branch, who you serve)
  con->>con: work, waits for its own jobs
  con-->>host: hand-off (Outcome, Outputs, Friction, For the repository, Decisions needed)
  host->>host: checks it, a report is not evidence
  con->>hook: job ends
  hook->>scribe: start
  scribe->>scribe: ledger entry with measured cost
```

One job per con, sized by blast radius (Sonnet by default, Opus only when the change reaches
every consumer, with the reason in the brief). A con replies once. Each job gets its own ledger
entry.

## 5. The backs after a turn

```mermaid
flowchart LR
  turn["Turn or con's job ends"] --> hook["hook"]
  hook --> scribe["scribe -> ledger"]
  hook --> secretary["secretary -> backlog"]
  hook --> librarian["librarian -> lexicon, adr"]
  hook --> tester["tester -> suite"]
  scribe --> g{"guard:<br/>only added?"}
  secretary --> g
  librarian --> g
  g -->|yes| qn["quiet-notice"]
  g -->|no| undo["guard undoes it"]
  qn --> host["host reads it before the next commit"]
  stake["stake: one plain line"] -.-> hook
```

Backs run in the background, inside the devhost, and never make the host wait. They only add
(the secretary also ticks). Anyone leaves a stake when something might be missed. On a
workstation there are no backs; `/close-session` does their chores by hand.

## 6. After a merge, and shutdown

```mermaid
flowchart LR
  merged["PR merged"] --> pull["git switch main, git pull"]
  pull --> prune["task devhost:branches PRUNE=1"]
  stop["Operator: shut down"] --> check["shutdown-devhost skill<br/>devhost-shutdown-check"]
  check --> wait["wait for the backs"]
  wait --> halt["task devcontainer:stop"]
  halt --> back["restart-devhost, or task devcontainer:up"]
```

A merged branch is never pushed to again; a new branch starts the next piece of work.

## 7. Resolving the component registry

Built in slices 1 and 2 ([component-registry](../proposals/component-registry.md), ADR-0063,
ADR-0064): the participant component's start sequence (`agents start`, `agents up`) runs `resolve`
with the agent's who-you-are path (its `registry-path`, else `COMPONENT_REGISTRY_WHOAMI`), then
`dcf-registry handover`, which calls the CLI adapter's `skills` verb when `supports` lists it, and
only then starts the CLI. `task component-registry:resolve` runs the resolve by hand;
`/registry-refresh` runs resolve and the hand-over mid-session. No step ever blocks the start.
From release 2 (proposal section 6.1; component-registry 1.6.0, participant 1.3.0) the resolve is
handed the listed agents' names, and before the CLI starts the participant reads the agent's
definition from the view (only when the view is for the agent's path): its model goes to the adapter
in `AGENT_MODEL`, its skills replace the entry's; for those two fields the registry wins over the list.

```mermaid
sequenceDiagram
  actor person as Person, or the participant component at an agent's start
  participant R as component-registry
  participant S as registry source
  participant C as CLI adapter
  person->>R: layer-list (is there a list?)
  alt no layer list
    R-->>person: one line, the agent starts with its plain skills
  end
  person->>R: resolve, for registry-path, COMPONENT_REGISTRY_WHOAMI or --as (COMPONENT_REGISTRY_AGENTS: the listed agents)
  R->>R: take the lock (flock)
  loop each layer, each source
    R->>S: version
    alt unchanged
      R->>R: keep the layer copy
    else changed
      R->>S: fetch into a new copy
      S-->>R: layer copy
    else unreachable
      R->>R: use the last good copy, say so
    else never fetched and required
      R-->>person: fail, the view left as it was; the agent still starts, said
    end
  end
  R->>R: match for who you are, merge by value type, per namespace (1.7.0: a namespaced layer only among its own)
  opt a higher line breaks a lock, a type or a permission
    R->>R: skip the line, report it
  end
  R->>R: write a new view, swap the symlink and the path's own pointer, drop copies no layer names
  R-->>person: resolved N components, lines skipped
  person->>R: handover <cli> <name> <folder> --as <the agent's path>
  R->>C: supports
  alt skills listed
    R->>C: skills, COMPONENT_REGISTRY_SKILLS = that path's view (lock held shared)
    C->>C: copy, mark owned, remove owned copies no longer resolved; per agent (ADR-0074): what every agent's view shares personal, the rest in the agent's own folder (--add-dir)
    R->>R: record the hand-over (handovers.tsv)
  else not listed or exit 3
    R-->>person: one line, the CLI keeps its plain skills
  end
  opt release 2: the view is for this agent's path
    person->>person: read view/agents/<name>/: model, skills (they replace the list's)
  end
  person->>C: start, AGENT_MODEL = the definition's model (it replaces a model in the CLI args)
  Note over R,C: /registry-refresh: resolve and handover for the calling agent's own path (its session id), mid-session; with no agent, every recorded hand-over
```

In this repository (slice 4, the first real use) the list has two required layers, and the
resolved `architecture-review` reaches Claude Code's personal skills folder, which wins the name
over the committed project copy:

```mermaid
flowchart LR
  devhost["devhost layer (rank 1)<br/>/usr/local/share/devhost/registry<br/>the review method"]
  repo["devcontainer-features layer (rank 2)<br/>.devcontainer/registry/repo<br/>In this repository"]
  component-registry["dcf-registry resolve<br/>body:text stacked, heading: false (no ## Layer line)<br/>name, description into the front matter"]
  personal["Claude Code personal skills<br/>architecture-review (wins the name)"]
  project["devhost template copy<br/>(planted by devhost-init where there is no registry)"]
  devhost --> component-registry
  repo --> component-registry
  component-registry -->|handover, skills verb| personal
  personal -.->|byte-equal, task test:registry-first-use| project
```

## 8. A node joins a hub (facilitator 0.4.0, slice N3)

A person on each side; neither step runs inside an agent's job (`node invite` refuses there). The token carries the
hash of the domain's trust bundle, so the spoke trusts the hub's certificate only after checking it.

```mermaid
sequenceDiagram
  participant P as person (hub side)
  participant H as hub (peers part, join endpoint)
  participant B as OpenBao PKI (intermediate; root offline)
  participant Q as person (spoke side)
  participant S as spoke
  P->>H: facilitator node invite
  H-->>P: join token (single use, 15 min, bundle hash); the join endpoint opens
  P->>Q: hand the token over
  Q->>S: facilitator node join --token
  S->>H: GET the trust bundle (unverified), check it against the token's hash
  S->>H: POST join over TLS checked against that bundle: token, node id, a request for its own key
  H->>H: token single use and unexpired; node not revoked, not joined
  H->>B: sign the request: spiffe://domain/node/id, 24 h (AppRole)
  B-->>H: certificate
  H->>B: roster backed up into KV
  H-->>S: certificate, bundle, mesh secret, the hub's address and name
  S->>S: certificate files; the hub into mesh.yml (role spoke)
  Q->>S: restart: SLIM links to the hub (type peer); the peers part says hello with its card
  S->>H: hello (card)
  H->>H: lock two on the card
  H-->>S: roster: every admitted card, the revoked nodes
```

## 9. An HTTP client enrols and its first contact is approved (facilitator 0.5.0, slice N4)

A person makes the token (never an agent's job); the CLI keeps it in its own config. The first message is written and
held; a person sees it in `mail` and approves. Bearer tokens here; the OAuth enrolment of cloud AIs is section 12.

```mermaid
sequenceDiagram
  participant P as person
  participant N as node (http part, application)
  participant C as Claude Code or Copilot CLI
  participant A as public agent
  P->>N: facilitator http token claude-laptop
  N-->>P: the token, once (only its SHA-256 is kept); the audit line
  P->>C: claude mcp add --transport http ... --header "Authorization: Bearer ..."
  C->>N: POST /mcp: who
  N-->>C: only the agents exposed public
  C->>N: say "@jester ..."
  N->>N: reach rule, limits; the message written with via, held (first contact)
  N-->>C: held: a person must approve
  P->>N: mail names the client that waits; approve (the MCP tool or facilitator http approve)
  N->>N: an approved notice; the held message dispatched
  N->>A: delivered
  A->>N: reply
  C->>N: receive (at most 25 s)
  N-->>C: the answer; every packet of the client says via http
```

## 10. Peers pair and a public node is approved (facilitator 0.6.0, slice N5a)

Two peers: a person runs `node invite` on one and `node peer --token` on the other; the nodes exchange CA bundles and the
mesh secret. A public node: a person opens a request window (`node invite --level public`), the other side runs `node request`,
the person runs `node approve <request>`, the public node `node collect`s its 1 h certificate. A revoke rotates the mesh secret.

## 11. The hub on Kubernetes (facilitator 0.7.0)

```mermaid
sequenceDiagram
  participant P as a person (terminal)
  participant K as the cluster (kustomize base, overlay)
  participant H as hub pod (StatefulSet)
  participant G as ssh-agent container (optional)
  participant S as a spoke (devcontainer, --add-host name:host-gateway)
  P->>K: kustomize build overlay | kubectl apply
  K->>H: pod, volume claim, ConfigMap (mesh.yml), Service 46358 and 46359
  Note over H: built-in CA made at first start, no unseal
  P->>G: ssh-add (the CA key into the agent's memory), only in the ssh-agent overlay
  H->>G: sign this certificate (per leaf)
  P->>H: node invite (kubectl exec), a join token
  P->>S: node join --token (the machine's port, the hub's name in its certificate)
  S->>H: join endpoint, then SLIM mutual TLS; cards, roster
  P->>H: node issuer export-root --out file (root key off the volume), or migrate (the same CA into OpenBao)
```

## 12. A cloud AI connects and its first contact is approved (facilitator 0.8.0, slice N5b)

```mermaid
sequenceDiagram
  participant C as cloud AI (a claude.ai connector)
  participant A as authorization server (a named issuer)
  participant N as node (resource server, http.url)
  participant P as a person (terminal)
  C->>N: POST /mcp, no token
  N-->>C: 401, WWW-Authenticate: Bearer resource_metadata=".../oauth-protected-resource/mcp"
  C->>N: GET the metadata (RFC 9728)
  N-->>C: resource, authorization_servers [issuer], scope
  C->>A: log the person in (OAuth 2.1, PKCE, resource = the node)
  A-->>C: JWT access token (iss, sub, aud, exp, scope)
  C->>N: POST /mcp with the token
  Note over N: issuer, alg, signature (JWKS), exp, aud, scope; unknown (issuer, subject): enrolled
  N-->>C: tools; its first say is held
  P->>N: http list, http approve corp-alice
  N-->>C: delivered; the agent's answer; every packet carries via: oauth, issuer, subject
```

## 13. A person approves a message that crosses between nodes (facilitator 0.9.0, gate A)

```mermaid
sequenceDiagram
  participant A as agent a1 (node A)
  participant FA as node A (sender)
  participant FB as node B (receiver, limits.private.approval: every-message)
  participant P as a person on B (terminal or session)
  participant B as agent b1 (node B)
  A->>FA: say @b1.node-b
  FA->>FB: the conversation's entries (message, route with b1's task)
  Note over FB: its own mesh.yml decides; the message is in the record
  FB-->>FA: signed notice approval: held at node-b
  B->>FB: receive (nothing: the task is not handed over)
  P->>FB: mail lists it (sender, node, conversation, first line, age)
  P->>FB: facilitator approve m-... (or the approve tool)
  FB-->>FA: signed notice approved (and an audit entry)
  B->>FB: receive: the message
  Note over P,FB: deny instead: signed notice denied, never delivered; 7 days held: never delivered
```
