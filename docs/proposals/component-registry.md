# Proposal: the component registry, a registry for agentic components

Status: proposed 2026-11-19. The design was decided piece by piece by the Operator on 2026-11-19
(section 2, ADR-0063); one point is open (section 12). Supersedes the
[personalization](personalization.md) proposal. Nothing is built.

Who this serves: the Operator, who rules on it and is its first user (a personal layer: "I'm
colour-blind, adapt diagram colours"); a consumer's maintainer, who publishes an organization or
department layer once and has every devhost pick it up; and the engineers whose agents read the
result without knowing layers exist.

The review boards (Whiteboards, private to the Operator) are the six standing documents for this
design; this file is their reviewed source:
[state](https://claude.ai/artifact/GVg1XvgHpjAHZRwJbKnjpQ),
[C4](https://claude.ai/artifact/WpPM7h7JodFqNamxbypnYL),
[workflows](https://claude.ai/artifact/8q9pn2s9jrUntEJf5mUR7Q),
[lifecycles](https://claude.ai/artifact/JBV3JnEMFqu62BWrYESe1h),
[data flows](https://claude.ai/artifact/EvaLTHSeLn2zfhr2MccNQQ),
[data inventory and models](https://claude.ai/artifact/4u4akyDoqNLbeu5Enkc5FZ).

## 1. The problem

A skill that produces architecture artifacts is written once. An organization wants it to use its
lexicon and mark every page "internal"; a department wants C4, not UML; one person needs a
colour-blind-safe palette. Today each of those is either written into the skill (a personal or
corporate taste committed to a shared repo) or said again in every session. The
[personalization](personalization.md) proposal solved one person's preferences with one file. The
need is wider: any number of owners, each publishing from wherever they keep things, for every kind
of agentic component, not only skills.

## 2. Decided by the Operator (2026-11-19)

1. **A registry for agentic components, shaped like the Windows Registry**: layers are like hives,
   paths like keys, typed values like registry values, locks like Group Policy, `resolve` like the
   merged `HKCR` view, `explain` like `regedit`. The shape is borrowed, not the Windows Registry
   itself (binary, Windows-only, two fixed hives).
2. **Layers: any number, each with one or more sources of any kind** (git, http/REST, a path or
   file share, the cloud folder, a database). Organization, department, team and person are
   examples, never fixed levels.
3. **One tree** of paths with `:key` values. Each layer's content is mounted at a path.
4. **Who wins**: the higher layer wins; inside one layer the more specific path wins; a locked key
   beats both.
5. **Who you are is a path** (`/Corp/MyDepartment/team/me`), set per person and per agent.
6. **Any component kind**: skills, agent definitions, prompts, settings, lexicons, more.
7. **Merge by value type**: `value` replaces, `list` combines (with `!` to take one out), `text`
   stacks in layer order, `ref` points at another path (and replaces). A definition is a key with
   values, so every field merges by its own type. A layer may force replace for a whole component.
8. **Query syntax**: gitignore-style paths, then `:key`; five symbols (`/`, `*`, `**`, `:key`,
   `!`); no value filters (no use case). Patterns replace the earlier facets idea.
9. **Files at the core; any backend through a source adapter** (`registry-source-<kind>`), each
   fetched into a local snapshot; an http source is accepted only when its files match a sha256
   manifest; offline, the last good snapshot is used.
10. **`resolve` and `explain`** as the two verbs; `explain --uses` answers "who uses this?".
11. **The adapter step in agents and the utility skills** (`/registry-refresh`, `/registry-explain`,
    `/registry-remember`); a refresh is picked up live where the CLI supports it.
12. **No RDF graph**: no agent tool uses RDF, and one resolved tree answers the same questions.
13. **Name**: the Feature is `component-registry`, the command `dcf-registry`.

## 3. The model

```mermaid
flowchart LR
  subgraph layers["Layers, lowest to highest (examples)"]
    l1["1 corp base<br/>http, at /Corp"]
    l2["2 dept<br/>file share, at /Corp/MyDepartment"]
    l3["3 dept extras<br/>database, at /Corp/MyDepartment"]
    l4["4 me<br/>cloud folder, at /Corp/MyDepartment/team/me"]
  end
  layers -->|"fetch: registry-source-&lt;kind&gt;"| snap["Snapshots<br/>one folder per layer, tier 4"]
  snap -->|"dcf-registry resolve<br/>for who you are"| view["Resolved view<br/>one tree"]
  view -->|skills| cli["CLI adapter<br/>Claude's skills folder"]
  view -->|agent definitions| agents["agents Feature"]
  view -->|prompts, settings| other["their own consumers"]
```

| Windows Registry | Component registry |
|---|---|
| hive (HKLM, HKCU) | layer, any number, any source |
| key `HKCU\Software\Corp\MyDepartment` | path `/Corp/MyDepartment` |
| value: name, type, data | `:key`, type, data |
| value types (`REG_SZ`, `REG_MULTI_SZ`) | `value`, `list`, `text`, `ref`: the type picks the merge rule |
| Group Policy keys | locked keys |
| `HKCR`, the merged view | `dcf-registry resolve` |
| `regedit` | `dcf-registry explain` |
| key permissions | who may write a layer (its source's own access control) |
| (no wildcards) | patterns: `/**/diagrams:color` |

### 3.1 The layer list

One file per repository, path set by `COMPONENT_REGISTRY_FILE` (default
`.devcontainer/registry.yml`), read only by the Feature. Lowest layer first:

```yaml
whoami: /Corp/MyDepartment/team/me      # per person; an agent may override it (section 12)
layers:
  - id: corp-base
    at: /Corp
    sources:
      - { kind: http, url: "https://example.invalid/registry/manifest.json", required: true }
  - id: dept
    at: /Corp/MyDepartment
    sources:
      - { kind: path, path: /mnt/dept-share/registry }
  - id: me
    at: /Corp/MyDepartment/team/me
    sources:
      - { kind: cloud-folder, remote: registry/me }
```

Several sources in one layer merge in their listed order. A layer marked `required` that was never
fetched stops `resolve`; any other unreachable source falls back to its last good snapshot and
`resolve` says so.

### 3.2 A layer's content

Plain text in each layer's source, one or more `*.reg` files, read with awk (NFR: shell tools only):

```ini
[/**/skills/diagrams]
color:value = colour-blind-safe

[/Corp/MyDepartment/lexicon]
terms:list = C4, SLA, !ADR

[/Corp/skills/architecture-artifacts]
body:text = @file skills/architecture-artifacts/SKILL.md
classification:value! = internal          ; "!" after the type locks the key

[/Corp/MyDepartment/agents/reviewer]
model:value = <model id>
skills:list = ref /Corp/skills/architecture-artifacts
```

A section header is a path or a pattern; `@file` points at a file beside the `.reg` file; a `ref`
names a path. The format is ours and small; its grammar is in the build's NOTES.

### 3.3 Precedence and merge

For one resolved key: take every line whose pattern matches it, from every layer. Order by layer
(higher wins), then by specificity inside a layer (more fixed path names wins), and apply the
value type's rule: `value` and `ref` keep the winner, `list` combines in that order applying `!`,
`text` stacks in layer order. A locked key stops at the layer that locked it: a higher layer's line
for it is refused, and `explain` names the lock. A layer may write `!replace` on a section to drop
everything below it for that component.

## 4. Source adapters

Same shape as the agents Feature's CLI adapters (`agent-adapter-<cli>`): one executable on `PATH`
per source kind, installed by the Feature that owns the transport.

```
registry-source-<kind> fetch <layer> <dest> key=value...   write the layer's files into <dest>
registry-source-<kind> version <layer> key=value...        print an etag, commit or digest
registry-source-<kind> supports                            the verbs it implements
exit codes: 0 done, 1 failed, 2 bad use, 3 not supported (the Feature falls back)
```

| Kind | Installed by | Notes |
|---|---|---|
| `git` | component-registry | clone or pull a pinned ref |
| `http` | component-registry | HTTPS only; a `manifest.json` lists files and sha256, every file must match; token from OpenBao through `dcf-secret`, never a file |
| `path` | component-registry | a folder; a file share is mounted on the host by the launcher (`DCF_HOST_*`), never SMB in the container |
| `cloud-folder` | cloud-folder | uses its existing rclone modes |
| `db` | a later slice | one more kind; the resolver does not change |

## 5. The verbs

- `dcf-registry resolve [--as <path>]`: fetch (each adapter, `version` first so an unchanged layer
  is skipped), merge (section 3.3), check locks and refs, write the resolved view (tier 4), hand
  each component kind to its consumer. A broken lock refuses that component; the last good copy
  stays.
- `dcf-registry explain <path> [--uses]`: read-only. Every line of a resolved component with the
  layer it came from; each source's state (fetched, or offline with the snapshot's date); refs that
  point at nothing; `--uses` lists what refers to the path.

## 6. Consumers: the adapter step

At an agent's start the agents Feature runs `resolve`, then hands over:

- **skills**: a new optional CLI adapter verb, `agent-adapter-<cli> skills <name> <folder> --from
  <dir>`, copies them into the CLI's own skills folder (Claude: `$CLAUDE_CONFIG_DIR/skills/`, a
  volume). Never the repository's `.claude/skills`: a resolved skill can carry personal facts.
  Claude ranks personal skills above project skills, so a resolved copy wins a name clash. The
  adapter creates the folder even when empty, so later changes are seen live. An adapter that
  answers exit 3 leaves the plain skills and says so.
- **agent definitions**: read by the agents Feature itself.
- **prompts, settings, lexicons**: each kind names its consumer in the build; until then
  `dcf-registry explain` and the resolved view are how they are read.

Utility skills, shipped by the Feature in its own base layer:

| Skill | Does |
|---|---|
| `/registry-refresh` | `resolve` now; Claude picks up changed skill files in the running session (documented); another CLI gets the files and a note that it needs a restart |
| `/registry-explain <path>` | `explain`, shown to the person |
| `/registry-remember <line>` | appends a line to the person's own layer source, then refreshes |

A skill already used in a conversation keeps its old text until it is used in a new conversation;
`/registry-refresh` says so.

## 7. Data, sensitivity and trust

- A resolved component, a snapshot and `explain` output are as sensitive as their most sensitive
  input. A personal layer may hold health facts (colour blindness), so resolved output is personal
  data: never committed, never in the checkout, owner-only modes.
- Cons and backs get resolved components, never raw layers or other people's layers.
- An http layer is instructions fed to agents: HTTPS, a sha256 manifest, a token from OpenBao. A
  mismatch refuses the layer.
- A layer is written only through its own source (a pull request, a share, the cloud folder);
  the container writes only the person's own layer (`/registry-remember`).

## 8. Placement (NFR-13)

| Element | Layer it belongs in | Why |
|---|---|---|
| layer list, resolve, explain, `git`/`http`/`path` sources, utility skills | new Feature `component-registry` | manages the agent's environment (its skills, its definitions), not a CLI capability |
| `cloud-folder` source | `cloud-folder` Feature | it owns the transport |
| `skills` adapter verb | each CLI Feature's adapter (`claude-code` first) | where the CLI's skills folder lives is a CLI fact |
| calling `resolve` at start, reading agent definitions | `agents` Feature | it already owns the start sequence |
| file-share host mount | the launcher (`devcontainer-cli`, `DCF_HOST_*`) | host mounts live there |

NFR-12 (two vendors or a named fallback): Claude's adapter first; any other adapter answers exit 3
and the agent starts with its plain skills, saying so.

## 9. Changes to the six standing documents (deltas)

Applied in the pull request that builds each slice, not by this proposal.

**State of the Architecture**: a new row.

| Element | State | Builds on |
|---|---|---|
| component-registry Feature (resolve, explain, source adapters, utility skills) | proposed | agents CLI adapters, cloud-folder |

**C4 Models** (container view): two containers and their relations.

```mermaid
flowchart LR
  component-registry["component-registry<br/>resolve, explain"]
  agents["agents Feature"]
  adapter["CLI adapter<br/>skills verb"]
  external-sources["layer sources<br/>git, http, path, cloud folder"]
  external-sources -->|fetched by| component-registry
  agents -->|runs resolve at start| component-registry
  component-registry -->|hands skills to| adapter
  component-registry -->|hands agent definitions to| agents
```

**Workflows**: an agent's start gains two steps; a refresh flow is new.

```mermaid
sequenceDiagram
  participant A as agents Feature
  participant R as component-registry
  participant S as registry-source-kind
  participant C as CLI adapter
  A->>R: resolve --as whoami
  R->>S: version, then fetch if changed
  S-->>R: snapshot (or last good copy)
  R->>R: merge by value type, check locks and refs
  R->>C: skills --from resolved
  A->>A: start the CLI
  Note over R,C: /registry-refresh runs the same, mid-session
```

**Lifecycles**: two new state machines.

```mermaid
stateDiagram-v2
  [*] --> draft
  draft --> in_review: layer owner proposes
  in_review --> published
  published --> superseded: next version
  state "resolved component (tier 4)" as rc
  [*] --> stale
  stale --> resolving
  resolving --> current
  resolving --> refused: lock broken
  refused --> stale: layer fixed
  current --> stale: a layer changed
```

**Data Flows**: layer sources, through source adapters, to snapshots, to the resolved view, to
consumers; the person's own layer is the only one written from the container.

```mermaid
flowchart LR
  src["layer sources"] -->|registry-source-kind| snap["snapshots, tier 4"]
  snap --> res["resolve"] --> view["resolved view, tier 4"]
  view --> cli["CLI skills folder"]
  view --> ag["agents Feature"]
  host["host session"] -->|/registry-remember| own["own layer source"]
```

**Data Inventory and Models**: rows and the model.

| Data | Where | Source | Tier | Sensitivity | Lost with the machine? |
|---|---|---|---|---|---|
| Registry list | `.devcontainer/registry.yml` | git | 1 | public | no |
| A layer's `.reg` files | its source | any | 1, 2 or 3 by owner | internal; a personal layer is personal | no |
| Snapshots | named volume, one folder per layer | fetched | 4 | as its layer | refetched |
| Resolved view | named volume | resolve | 4 | as its most sensitive input | rebuilt |

```mermaid
classDiagram
  class Layer { id; rank; at; sources }
  class Entry { pattern; key; type; data; locked }
  class ResolvedComponent { path; values; source of each value }
  Layer "1" --> "*" Entry : holds
  Entry "*" --> "1" ResolvedComponent : merged into
```

## 10. Slices

1. **Core**: the Feature, the layer list, `.reg` parsing, the four value types, patterns, precedence,
   locks, `resolve` and `explain` (`--uses`), sources `git` and `path`. Tests on fixture layers.
2. **Adapter step**: the `skills` verb in `agent-adapter-claude`, `resolve` in the agents start
   sequence, the three utility skills.
3. **Remote sources**: `http` with the manifest and the OpenBao token; `cloud-folder` in the
   cloud-folder Feature.
4. **First real use**: split the `architecture-review` skill into a base layer and this
   repository's layer, and check the resolved skill matches today's.
5. **Later**: the `db` source; agent definitions read from the registry.

## 11. Relation to other work

- Supersedes [personalization](personalization.md): the one preferences file becomes one person's
  layer.
- [Task aliases](task-aliases.md) keep their own team and personal files; they could become a
  component kind later, not in this proposal.
- The lexicon keeps "layer" for the theme layers (the bar); here the word is always "registry
  layer" in prose that could be confused.

## 12. Open questions

1. **How each layer owner reviews changes** before they take effect. Recommended: a pull request in
   the owner's own git repository, published read-only through a source.
2. **An agent's own path** (`whoami` per agent): a key in the agents list entry, or a registry
   value under the agent's definition. Recommended: the agents list entry, so the list stays the
   one place an agent is defined.
