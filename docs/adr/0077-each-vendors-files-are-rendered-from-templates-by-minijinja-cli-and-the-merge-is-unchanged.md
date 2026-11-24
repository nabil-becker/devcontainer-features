# ADR-0077: Each vendor's files are rendered from templates by `minijinja-cli`, and the merge is unchanged

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-21 |
| **Deciders** | the Operator; proposed by the host |

Builds on [ADR-0063](0063-agentic-components-live-in-a-registry-of-layers-shaped-like-the-windows-registry-and-merge-by-value-type.md)
and [ADR-0064](0064-the-cli-contract-gains-an-optional-skills-verb-and-the-component-registry-hands-resolved-skills-to-it-at-an-agent-s-start.md);
neither is edited.

## Context

The component registry merges the layers into one resolved view. The step after the merge,
turning the resolved view into the files a vendor's CLI reads (a Claude skill folder, a Copilot
agent file), is shell code written by hand in each CLI's adapter (`agent-adapter-claude` and its
siblings). When a vendor changes its file format, or a new vendor appears, adapter code has to be
written or edited. The Operator's goal for this step is ease of use: the collection supplies a
base and people adapt it or bring their own, otherwise the result is only a complicated template
runner.

Python facts, checked in the repository before the engine was chosen: every Feature that uses
Python relies on the operating system's Python and the standard library only; no Feature installs
a third-party Python package; `claude-code` is kept Python-free
([ADR-0061](0061-the-facilitator-is-built-on-agntcy-first-with-the-mcp-split-in-two-and-the-agents-feature-moves-into-a-shared-participant-component.md)).
Single pinned binaries are the established pattern for tools (`go-task`).

## Decision

1. **Each vendor's files are rendered from templates**, not produced by adapter shell code. The
   template is the vendor's file with blanks in it, filled from the resolved view.
2. **The merge does not change.** Who wins, the locks and what `explain` reports stay as
   ADR-0063 fixes them; only the last step, "write the files the vendor wants", changes.
3. **The template engine is `minijinja-cli`**, a single pinned binary installed the way `go-task`
   is. Jinja for Python is not used.
4. **Templates are registry components** of a new kind, `template`, at
   `templates/<vendor>/<file>.j2`, with `for:` (what it renders once per: a skill, an agent) and
   `output:` (the file written) in the template's header.
5. **The built-in base layer ships the templates** for the vendors the collection supports, so
   nobody has to write Jinja for it to work.
6. **Any layer may do one of three things:** replace a template whole, change one block of it
   through `{% extends %}` and `{% block %}`, or add a template of its own (a file the base does
   not produce).
7. **Precedence is layer precedence.** The highest layer's template wins; a replacement never
   stacks with the one below it; a lock held by a lower layer holds; a namespace isolates
   templates as it isolates every other component. `explain` names the winning layer and the base
   it extends.
8. **A template only writes files.** A new vendor CLI still needs its adapter to be started and
   reached; the template does not replace that.

## Options considered

### Option 1: templates rendered by `minijinja-cli` (chosen)

A vendor format change or a new vendor becomes an edit or an added template, not adapter code. A
single pinned binary matches how the repository installs tools and adds no language runtime.

### Option 2: keep the hand-written shell in each adapter

Lost: every format change or new vendor means new shell code per adapter, which is the cost the
templates remove.

### Option 3: Jinja for Python

Lost: it would be the first third-party Python package any Feature installs and would add Python
to `claude-code`, which stays Python-free.

### Option 4: templates fixed in the adapters, not registry components

Lost: a person who wants a different file shape has to edit a Feature, which is the cost the
templates were meant to remove.

### Option 5: templates that stack or merge across layers

Lost: the result of two templates combined is not explainable, and it would open a second merge
beside the one ADR-0063 defines. Replace-only, with `extends` for a partial change, keeps "who
wins" answerable in one line.

## Consequences

- A vendor's output format lives in a template, so a format change is a small edit.
- A new binary, `minijinja-cli`, joins the pinned tools, installed through the vendored
  `dcf_curl` ([ADR-0034](0034-every-build-time-download-goes-through-the-vendored-dcf-curl-and-a-lint-check-enforces-it.md)).
- The adapters' file-writing step is replaced by rendering, done by `dcf-registry handover` before
  the adapter's `skills` verb runs (component-registry 1.11.0); the adapter places and marks the
  rendered files, whose format is the template's. A CLI no template names gets the view's skills
  as before. Claude Code's base template reproduces the 1.10.0 files byte for byte.
- The component registry gains a `template` kind (component-registry 1.11.0): a template's head
  also takes `lock: true`, the lock of decision 7; a partial change extends a lower layer's
  template by `<layer>/<file>.j2`. A template that does not render fails the hand-over and the CLI
  keeps its files; a head that cannot be read is skipped and reported by `resolve`. Copilot's
  skills followed in 2.1.0. `for: agent` is not built: the Operator ruled on 2026-11-24 that a
  registry agent definition does not become a CLI-native agent file (its model and skills already
  reach the CLI through `--model` and the skills hand-over).
- Overriding a template reuses the layers, locks and `explain` already built; no second override
  mechanism exists. A partial change needs `extends` and `block` in the replacing template.

## Change log

| Date | Change |
|---|---|
| 2026-11-21 | First draft; decisions 1 to 3 ruled by the Operator on 2026-11-21, decision 4 left open. |
| 2026-11-23 | Decisions 4 to 8 ruled by the Operator on 2026-11-23 (templates are registry components); Options 4 and 5 added. |
| 2026-11-23 | Numbered 0077 (0075 and 0076 were taken on main); the consequences say how component-registry 1.11.0 built it: rendering in the hand-over, `lock:` in the head, `extends` by layer name, the failure behaviour, the next slice. |
| 2026-11-24 | Slice 2.1 built (component-registry 2.1.0, copilot 0.3.0): the base layer ships Copilot CLI's `SKILL.md` template and the Copilot adapter gains the `skills` verb (split, shared, off, as Claude Code's). `for: agent` (slice 2.2) waits for the Operator: whether a registry agent definition should become a CLI-native agent file. |
| 2026-11-24 | The Operator's rulings on slice 2: no CLI-native agent files, so `for: agent` stays unbuilt (option A; option B, a prompt key with refused `tools`, `mcp-servers` and `permission*` front matter, and option C, `--agent`, which ADR-0073 forbids, were not taken); Copilot keeps `split` as its default, as Claude Code; the skills split shared by both adapters moves into one vendored helper as a follow-up. |
