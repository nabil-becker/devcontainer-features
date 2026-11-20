# ADR-0064: The CLI contract gains an optional skills verb and the component registry hands resolved skills to it at an agent's start

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-20 |
| **Deciders** | the Operator; proposed by the host |

Amends [ADR-0037](0037-a-contract-for-agent-clis-must-work-on-two-vendors-or-name-its-fallback.md)
(the CLI contract gains a verb); ADR-0037 itself is not edited.

## Context

[ADR-0063](0063-agentic-components-live-in-a-registry-of-layers-shaped-like-the-windows-registry-and-merge-by-value-type.md)
and the accepted [component registry proposal](../proposals/component-registry.md) (sections 6, 10
and 12, slice 2) leave the resolved view in the `component-registry` Feature's volume; nothing yet
puts its skills where a CLI reads them. Where a CLI's skills folder lives and when it reads it are
CLI facts (proposal section 10, NFR-13), so the step belongs in each CLI's adapter, whose contract
ADR-0037 fixes: a verb works on two vendors or names its fallback (NFR-12). The agents start
sequence now lives in the shared participant component
([ADR-0061](0061-the-facilitator-is-built-on-agntcy-first-with-the-mcp-split-in-two-and-the-agents-feature-moves-into-a-shared-participant-component.md)),
installed by `claude-code` with `participants: true`.

Claude Code facts, from its skills documentation (https://code.claude.com/docs/en/skills, checked
2026-11-19): a skills folder is watched and a change is picked up in the running session; a skills
folder that did not exist when the session started needs `/reload-skills`; a personal skill wins
over a project skill of the same name. No other CLI in the capability matrix
([agents-v2](../proposals/agents-v2.md) section 14) is known to read a skills folder this way.

## Decision

1. **The CLI contract gains an optional verb, `skills <name> <folder>`**, listed by `supports`, in
   the shape of the other optional verbs. Its input is the environment variable
   `COMPONENT_REGISTRY_SKILLS`, the resolved view's `skills/` folder (one folder per skill). The
   adapter copies each resolved skill into the CLI's own skills folder, marks each copy as owned by
   the registry (a marker file), removes owned copies that are no longer resolved, never touches a
   skill it does not own, never writes the repository's skills folder (a resolved skill can carry
   personal facts), creates the skills folder even when there is nothing to copy, and is idempotent.
   Exit 3 or not listed: the CLI keeps its plain skills, and the caller says so in one line.
2. **Claude Code implements it first** (`agent-adapter-claude`, claude-code 1.12.0): the folder is
   `$CLAUDE_CONFIG_DIR/skills` (the Feature's volume, tier 4, owner-only), the marker
   `.component-registry`; `claude-code-setup` creates the folder at every create.
3. **The registry calls the adapter, not the other way round**: `dcf-registry handover <cli>
   [<name> <folder>]` checks `supports`, holds the resolve lock shared so the view is not swapped
   mid-copy, and calls the verb. `dcf-registry refresh` resolves and hands over to every adapter on
   PATH.
4. **The participant component resolves at an agent's start** (participant 1.2.0): when
   `dcf-registry` is on PATH and the layer list exists, `agents start` and `agents up` run `resolve`
   (`--as` the agents list entry's new optional key `registry-path`, else
   `COMPONENT_REGISTRY_WHOAMI`) and then `handover` before the CLI starts. A failure never blocks the
   start: no layer list, a failed resolve, a CLI without the verb or a failed hand-over is one line.
   Resolve and the hand-over together wait at most `COMPONENT_REGISTRY_START_WAIT` seconds per
   agent (default 15), a hanging fetch and a held lock included; past it the CLI starts with the
   last good skills already in its folder, said in one line.
   Without `dcf-registry` nothing is run or said.
5. **The utility skills ship in a built-in base layer** of `component-registry` (rank 0, id
   `component-registry`, at `/`, read from the Feature's install folder, reserved id), so they
   resolve and hand over like any skill and a listed layer can adapt them.

## Options considered

### Option 1: an optional adapter verb, called by the registry (chosen)

Keeps the CLI fact (where the folder is, how it is watched) in the CLI's Feature and the merge in
the registry, matches ADR-0037's "one executable per vendor, optional verbs answer 3", and lets
`/registry-refresh` reuse the same path mid-session with no agents list involved.

### Option 2: the registry writes into each CLI's folder itself

Lost: the registry would have to know every CLI's folder, precedence and reload rule, which is the
CLI knowledge the adapters exist to hold (NFR-13).

### Option 3: the participant component calls the adapter directly

Lost: `/registry-refresh` runs without the participant component, so the hand-over would be written
twice; and only the registry can hold its own lock while the view is read.

### Option 4: write into the repository's `.claude/skills`

Lost: a resolved skill can carry personal facts (a health fact in a person's own layer), and the
repository is tier 1, shared and committed.

## Consequences

- Every Claude agent started through `agents` gets the registry's skills with no setup beyond the
  layer list and the who-you-are path; `/registry-refresh` updates a running Claude session live.
- Another CLI's agents start with their plain skills, said in one line, until its adapter implements
  `skills`; the capability matrix has a "skills folder" row.
- The resolved view and a CLI's skills folder are one per container: agents of one CLI with
  different `registry-path`s see the latest start's skills. A per-agent configuration folder would
  be needed to keep them apart; not decided here.
- An agent's start now waits for `resolve` (a git layer fetch) when the registry is configured, at
  most `COMPONENT_REGISTRY_START_WAIT` seconds (default 15).
- `src/agents/NOTES.md` (the adapter contract), `src/claude-code/NOTES.md`, the component registry
  notes and the six standing architecture documents carry the change.

## Change log

| Date | Change |
|---|---|
| 2026-11-20 | First draft, with slice 2 of the component registry (`component-registry` 1.1.0, `claude-code` 1.12.0, participant 1.2.0). |
| 2026-11-20 | Accepted by the Operator on 2026-11-20. |
