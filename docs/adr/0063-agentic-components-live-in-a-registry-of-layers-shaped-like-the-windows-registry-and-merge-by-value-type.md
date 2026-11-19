# ADR-0063: Agentic components live in a registry of layers, shaped like the Windows Registry, and merge by value type

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-19 |
| **Deciders** | the Operator; proposed by the host |

## Context

Skills, agent definitions, prompts and settings are written once but need adapting by several
owners: an organization's lexicon and classification, a department's diagram standard, one
person's colour-blind palette. Today that is either committed into the component (a taste in a
shared repo) or repeated in every session; the earlier [personalization](../proposals/personalization.md)
proposal covered one person with one file. Owners keep their material in different places (an
HTTP service, a file share, a database, a cloud folder). Features here use shell tools only
(NFR), and the agents Feature already solves "one contract, one small executable per vendor" for
CLIs (ADR-0036, ADR-0037). A personal layer can hold health facts, so what it feeds is personal
data (ADR-0045). The full design is [the component registry proposal](../proposals/component-registry.md).

## Decision

A new Feature, `component-registry` (command `dcf-registry`), holds agentic components in a
registry shaped like the Windows Registry, without being it:

1. **Layers** (like hives): any number, ordered, each mounted at a path and fed by one or more
   sources of any kind. Organization, department, team and person are examples, not levels; a
   person's own layer is simply the top layer, from any source they choose.
2. **One tree** of paths (like keys) with `:key` values that carry a **type**: `value` replaces,
   `list` combines (`!` removes an item), `text` stacks in layer order, `ref` points at another
   path. A definition is a key with values, so each value merges by its own type; `@replace` on a
   section replaces a whole component. The `.reg` grammar and match rule are in the proposal.
3. **Precedence**: the higher layer wins; inside a layer the more specific scope wins; a locked key
   (like a Group Policy key) beats both. A permission key (a skill's `allowed-tools`) comes from
   the component's lowest layer only, so no layer widens a permission.
4. **Who you are is a path**, set by the variable `COMPONENT_REGISTRY_WHOAMI` (per person) or an
   agents list entry (per agent), never in a committed file; a line applies when its scope matches
   that path or an ancestor of it.
5. **Patterns** select across the tree in gitignore style: `/`, `*`, `**`, `:key`, `!`. No value
   filters.
6. **Files at the core; registry sources.** `resolve` reads local layer copies only; each source
   kind is an executable `registry-source-<kind>` (`fetch`, `version`, `supports`; exit 3 = not
   supported), installed by the Feature that owns the transport. The layer list pins only what to
   read (a git branch, tag or commit; a folder; a URL) and how to log in (secrets through
   `dcf-secret`); an `http` source takes authentication settings only. Review and release are the
   source owner's. Offline, the last good copy is used; a `required` layer never fetched stops
   `resolve`.
7. **Two verbs**: `resolve` (fetch, merge, check locks, types and refs, swap in the resolved view,
   hand each kind to its consumer) and `explain` (read-only; who said each line and at which
   version; `--uses` lists what refers to a path).
8. **Release 1 is skills only.** Skills go through a new optional CLI adapter verb, `skills`, into
   the CLI's own skills folder, never the repository's `.claude/skills`; this amends the CLI contract
   of ADR-0037. Another CLI answers exit 3 and starts with its plain skills (NFR-12). Agent
   definitions, prompts and settings are later releases. Utility skills `/registry-refresh`,
   `/registry-explain` and `/registry-remember` ship with the Feature.

## Options considered

- **A database as the core.** Rejected: a server for a few hundred entries, and each owner
  already keeps material somewhere; a database is one more source kind instead.
- **Fixed levels (skill, organization, department, person) and per-kind merge rules.** The first
  draft. Rejected by the Operator for any number of layers and sources, and for merge rules taken
  from the value's type, which also removes a "per field" special case.
- **Facets declared by each skill.** Replaced by patterns over the tree: a name in the tree is
  enough.
- **Query languages: CSS selectors, JSONPath, XPath.** Rejected for gitignore-style paths: known,
  tiny, shell-friendly; JSONPath targets one document, XPath needs XML.
- **An RDF graph as the store or as an exposed view.** Rejected: RDF only adds facts and cannot
  express "higher layer wins" or `!`; no agent tool reads RDF; one resolved tree answers the same
  questions. The `ref` type was kept on its own.
- **The real Windows Registry.** Not used: binary, Windows-only, two fixed hives, no patterns.

## Consequences

- Owners publish once; every devhost picks the change up at its next start or `/registry-refresh`.
- Resolved output is personal data: kept in tier 4 volumes, never committed, owner-only; cons and
  backs see resolved components only.
- A layer is instructions fed to agents. Which source to trust, and how it is reviewed, is the
  layer owner's and the person's choice; the registry authenticates as configured and never widens
  a permission.
- ADR-0037 and `src/agents/NOTES.md` are amended when the `skills` verb is built.
- The word "registry" now sits next to `agentic-register`; the lexicon keeps them apart.
- Supersedes the personalization proposal; its single preferences file becomes one person's top layer.

## Change log

| Date | Change |
|---|---|
| 2026-11-19 | First draft as "layered skills keep files at the core and any backend plugs in through a layer source adapter" (numbered 0061, then 0062, while other ADRs landed first). |
| 2026-11-19 | Rewritten for the decided model: the component registry, layers of any number and source, merge by value type, patterns, `ref`; accepted by the Operator in the session. |
| 2026-11-19 | Back to proposed by the Operator after the architecture review (fit with changes), until the review's changes land in the proposal. |
| 2026-11-19 | The architecture review's changes and the Operator's rulings applied: who-you-are as a variable, the match rule, registry sources pinning version and log-in, http authentication only, review out of scope, permissions never widened, release 1 skills only, ADR-0037 amended. |
| 2026-11-19 | Accepted by the Operator with the proposal, including the rule that no layer widens a permission. |
