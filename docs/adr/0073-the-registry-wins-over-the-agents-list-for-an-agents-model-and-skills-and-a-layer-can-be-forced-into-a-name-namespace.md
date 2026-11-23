# ADR-0073: The registry wins over the agents list for an agent's model and skills, and a layer can be forced into a name namespace

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-21 |
| **Deciders** | the Operator; proposed by the host |

## Context

The component registry (ADR-0063) can now describe an agent: release 1.6.0 lets a registry layer
set an agent's `model` and `skills` (proposal section 6.1). The same agent is also described in
the committed agents list, so the two can disagree and one must win. The host recommended that
the list win and the registry only fill the fields the list leaves open; the Operator ruled the
other way: managing what a registry layer says is not this repository's responsibility.

A model name is a fact of one CLI: a Claude model id is not a name the Copilot CLI knows, and an
organization-wide line such as `[agents/*]` reaches agents of several CLIs.

Handing a model to a CLI changes the CLI contract (ADR-0037), the way the session name did
(ADR-0041).

A registry layer can point at a source the Operator does not control, such as a community
repository. Such a layer needs isolation, so that what it brings cannot change what the Operator
already has, while the Operator can still adapt what it brings.

## Decision

1. **The registry wins** over the agents list for the two fields it may set, an agent's `model`
   and `skills`. A registry model replaces any `--model` in the agent's arguments (the adapter
   drops it and says so in one line); registry skills replace the list entry's `skills:`, which
   stand only when the registry resolves none. The fields the registry can never set stay out of
   its reach in every layer: name, cli, kind, folder, lifecycle, identity, lease, `args`,
   `definition`, and every permission key. A locked registry value beating the list does not
   arise, since no list value beats the registry.
2. **A model per CLI.** `model:value` is the model for the agent's own CLI (its `cli` in the
   agents list). `model.<cli>:value` (for example `model.claude`, `model.copilot`) applies only to
   agents of that CLI. The usual order decides (higher layer, then the more specific path, then
   fewer wildcards); the suffixed key wins only on a tie. `lock model` also holds every
   `model.<cli>`. A suffix no listed agent has applies to none.
3. **The CLI contract gains `AGENT_MODEL`** (amends ADR-0037): the participant passes the
   resolved model to the adapter in `AGENT_MODEL`, set only on calls about that agent. The adapter
   turns it into its CLI's own model option (Claude Code and the Copilot CLI: `--model`) on start,
   new and resume, not on a bare wake. An adapter whose CLI has no such option says so in one line
   and starts on the CLI's default (NFR-12).
4. **A layer can be forced into a namespace**, set as `namespace: <name>` on the layer in the layer
   list. Every component the layer brings gets that name as a prefix (a community layer's
   `arch-review` becomes `acme:arch-review`). **Layers that share a namespace merge with each
   other** exactly as layers do today (order, specificity, locks, merge by value type, permission
   keys from that namespace's lowest layer); different namespaces never mix, and the layers without
   a namespace are the Operator's own. So a public source is isolated, and the Operator can still
   adapt it with a layer of their own in the same namespace.

## Options considered

### Option 1: the registry wins, a model per CLI, and a layer can be forced into a name namespace

The Operator's rulings (A1, A3, the namespace). The repository does not police the registry's
content; isolation of an untrusted source is a property of its layer, set where the layer is
listed. The prefix is familiar from Claude Code plugins and npm scopes.

### Option 2: the committed agents list wins, the registry fills gaps

The host's recommendation for A1: a choice reviewed in the repository is never changed from
outside. It lost because it makes this repository responsible for managing registry content, and
it leaves an organization-wide line unable to set an agent's model where a list entry exists.

### Option 3: one `model` for every CLI

Pass the same value to every CLI and let a CLI reject a name it does not know. Lost: an
organization could not give agents of two CLIs a model each in one line.

### Option 4: a path jail instead of a name prefix

A layer may write only inside one part of the tree, for example `/Community/acme/**`. Lost:
`/**` patterns and shared component names are hard to fence cleanly, and the Operator found the
name prefix closer to what they planned, although the path jail was what they first pictured.

## Consequences

- A layer's model and skills for an agent take effect without a change to the committed list; a
  repository that wants a fixed model sets it in a layer it controls, with a lock.
- Pointing a layer at a public source is safe by construction once a namespace is set; an
  un-namespaced layer is trusted as before. Several layers in one namespace adapt a public source.
- Component names carry an optional prefix; the resolver, `explain` and the hand-over (ADR-0064)
  must handle it. The namespace is built as its own pull request after this one, before the
  agent-definitions release.
- Adapters gain one environment variable to honour; Claude Code and Copilot both do.

## Amendment (2026-11-23): the namespace as built

The Operator ruled four questions the build of decision 4 (component-registry 1.7.0) raised:

- **N1, keep the folder name.** A namespaced skill is handed to a CLI as `<ns>--<name>` (folder
  and `SKILL.md` name), since a `:` is no skill folder name for the adapters and Claude Code keeps
  it for its own prefixes; the registry's name stays `<ns>:<name>`.
- **N2, references are always explicit** (2026-11-21). A reference without a prefix names the
  referrer's own namespace (the un-namespaced set for the Operator's layers); `<ns>:<name>` names
  namespace `<ns>` from any layer, including from one namespace to another; nothing names the
  un-namespaced set from inside a namespace, so a namespace still cannot reach the Operator's
  components. A missing target is a missing dependency, as a Helm chart's: reported, never fatal;
  installing it is the user's. A layer may carry `aliases: { acme: acme-public }`, applied to its
  own references, one hop. This replaces "a ref never crosses a namespace" of the first build.
- **N3, agent definitions as built.** Whether a layer is namespaced is the choice of whoever lists
  it: a plain-listed layer's agent definitions override, a namespaced one's become
  `acme:<agent>` and match no agent of the agents list.
- **N4 (b), writing is out of the registry's scope.** No writable support for namespaced layers;
  `writable` and `remember` stay as they are and are deprecated in a later slice.

## Change log

| Date | Change |
|---|---|
| 2026-11-21 | First draft (as 0074 in the main checkout), accepted by the Operator in the session. |
| 2026-11-21 | Renumbered 0073 and extended with the per-CLI model (A3), the `AGENT_MODEL` contract change and the shared-namespace rule (A4: one ADR for all of them). |
| 2026-11-23 | Amended with the Operator's rulings N1 to N4 on the built namespace (folder name, explicit references with missing dependencies and aliases, agent definitions, no writing). |
