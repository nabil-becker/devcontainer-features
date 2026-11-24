# C4 container: inside the devhost

The host briefs cons; the backs keep the records after each turn; the back guard undoes a back
that changed what it may only add to; the guards check the records at commit time. Node ids are
ontology ids.

```mermaid
flowchart TB
  subgraph devhost["Devhost"]
    host["Host"]
    con["Con"]
    subgraph back["Backs"]
      scribe["Scribe"]
      secretary["Secretary"]
      librarian["Librarian"]
      tester["Tester"]
    end
    guard["Back guard"]
    guards["The guards"]
    ledger["Ledger"]
    backlog["Backlog"]
    lexicon["Lexicon"]
    adr["ADR"]
    journal["Journal"]
    drop-a-seed["Drop a seed"]
    journalist["Journalist (a brief, not a back)"]
    white-paper["White paper"]
  end
  host -->|briefs| con
  con -->|returns hand-off to| host
  scribe -->|writes| ledger
  secretary -->|keeps| backlog
  librarian -->|keeps| lexicon
  librarian -->|keeps| adr
  drop-a-seed -->|uses| journalist
  journalist -->|writes| white-paper
  guard -->|checks| backlog
  guard -->|checks| lexicon
  guard -->|checks| adr
  guards -->|checks| ledger
  guards -->|checks| adr
```

## The component registry (ADR-0063)

Built (slices 1 to 4, the `db` source and agent definitions; `component-registry` 1.6.0 published): `component-registry`
fetches its layers from all five registry sources (`git`, `path`, `http`, `cloud-folder` from the
cloud-folder Feature, `db` for sqlite and postgres) and resolves them; the participant component
runs `resolve` at every agent's start and `dcf-registry handover` gives the skills to the CLI
adapter's `skills` verb (ADR-0064). OpenBao gives a `git`, `http` or `db` source its secret,
through `dcf-secret`. The dashed relation comes later: the launcher's share mount and who-you-are
path. Each who-you-are path keeps its own view and each agent its own
skills (ADR-0074).
Slice 4 (the first real use) adds the devhost Feature as a layer's owner: its image folder holds
the generic `architecture-review`, which this repository's own layer stacks on.
Release 2 (agent definitions, proposal section 6.1; published in component-registry 1.6.0, ADR-0073) adds one relation: the participant component
reads an agent's definition from the resolved view and hands its model to the CLI adapter in
`AGENT_MODEL` (the adapter's own contract, no new verb).
Layer namespaces (component-registry 1.7.0, ADR-0073): a layer listed with `namespace: <name>` brings its
components as `<name>:<component>` (on disk `<name>--<component>`); layers sharing a namespace merge with
each other and never reach the un-namespaced layers, which are the Operator's own. No new container or relation.
Vendor templates (component-registry 1.11.0, ADR-0077, built): `dcf-registry handover` renders the
CLI's winning templates (a layer's, else the built-in base layer's) with `minijinja-cli`, a pinned
binary inside the component-registry container, before the adapter's `skills` verb copies the
result; templates come from the same layer sources. The hand-over relation is unchanged in shape;
its label now says the skills are rendered. From component-registry 2.1.0 the Copilot adapter is a second `skills` receiver (copilot 0.3.0); no new container or relation.

```mermaid
flowchart LR
  component-registry["component-registry: resolve, explain, render, handover, refresh"]
  participant-component["agents (participant component)"]
  cli-adapter["CLI adapter: skills verb"]
  launcher["Launcher: share mount, whoami"]
  master-of-secrets["OpenBao: source secrets"]
  external-sources["Layer sources: git, path, http, cloud folder, db"]
  external-sources -->|fetched by| component-registry
  master-of-secrets -->|gives secrets to| component-registry
  launcher -.->|later: mounts shares, sets whoami for| component-registry
  participant-component -->|runs resolve at start| component-registry
  component-registry -->|hands skills rendered from its templates to| cli-adapter
  participant-component -->|reads agent definitions from the view of| component-registry
  participant-component -->|AGENT_MODEL to| cli-adapter
  devhost["devhost Feature: the generic layer"] -->|a path layer for| component-registry
```

## The facilitator mesh (slice N3, ADR-0067 to ADR-0071)

Built in `facilitator` 0.4.0: a hub (the node image) beside the OpenBao whose PKI issues its domain's node
certificates, and spokes (a devcontainer, or the image) that join it with a join token and link to it over SLIM. The
hub's listener holds only its level's CA bundle (lock one); every node's application checks each card and entry
against its own `mesh.yml` (lock two). The hub's Directory is synced by its spokes by registry, one way, only with
`directory.peering`.

```mermaid
flowchart LR
  operator["Operator"]
  facilitator-node["Facilitator node: the hub (node image, role hub)"]
  facilitator["facilitator Feature: a spoke (a devcontainer, role spoke)"]
  master-of-secrets["OpenBao beside the hub: PKI per trust domain, the roster's backup"]
  node-bundle["Node bundle"]
  join-token["Join token"]
  mesh["mesh.yml of each node"]
  operator -->|unseals by hand; node invite| facilitator-node
  facilitator-node -->|makes| join-token
  join-token -->|node join| facilitator
  facilitator-node -->|asks for certificates, backs up the roster| master-of-secrets
  facilitator -->|SLIM, mTLS, a link of type peer| facilitator-node
  facilitator-node -->|routes between spokes, the roster of cards| facilitator
  facilitator -.->|with directory.peering: syncs the hub's records by registry| facilitator-node
  mesh -->|role, trust, expose, limits| facilitator
  mesh -->|role, trust, expose, limits| facilitator-node
  node-bundle -.->|installed by| facilitator-node
  node-bundle -.->|installed by| facilitator
```

## The facilitator endpoint over HTTP (slice N4, ADR-0070)

Built in `facilitator` 0.5.0: only when `facilitator.http.listen` is set, a node serves its MCP tools to CLIs with a
static bearer token a person made; the node signs for the client and the client is mapped through
`http.<home domain>` (public unless `mesh.yml` maps it private).

```mermaid
flowchart LR
  operator["Operator"]
  facilitator["facilitator Feature: a node with the http part"]
  mesh["mesh.yml of each node"]
  trust-level["Trust level"]
  external-http-cli["Claude Code or Copilot CLI (bearer token)"]
  external-http-cli -->|MCP over HTTP, TLS beyond loopback| facilitator
  operator -->|http token, approve, revoke| facilitator
  mesh -->|http.home-domain trust, expose public, approval and limits| facilitator
  facilitator -->|maps an HTTP client to| trust-level
```
