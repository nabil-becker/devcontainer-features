# Proposals

Drafts the Operator decides on. A proposal is never in force until the Operator accepts it; once accepted, the change is made through the backlog and, where the reasoning is long, an ADR in `docs/adr/`. A proposal that is declined stays here with its status line, so the question is not asked twice.

| Proposal | Status |
|---|---|
| [King Arthur theme](king-arthur-theme.md) | superseded 2026-10-23 by the bar (ADR 0023); was accepted 2026-10-16: a layer, ten names in LEXICON.md, used in conversation only; no committed output speaks in it |
| [Journalist back](journalist-back.md) | decided 2026-10-20 (ADR 0009 superseded by ADR 0014): a brief (`drop-a-seed/journalist.md`) a writing subagent follows during `drop-a-seed`; not a back, not a skill of its own (decided 2026-10-17: a skill, not a back); earlier, accepted 2026-10-16: it writes the iteration's white paper (docs/iterations.md), in plain words, when the Operator calls the iteration; the hand-run journal piece was a trial |
| [Personalization](personalization.md) | open |
| [Task aliases](task-aliases.md) | draft 2026-10-28; shape decided by the Operator (aliases point at tasks, team file plus personal file, generated wrappers); the rest awaits confirmation; build not started |
| [Feature principles](feature-principles.md) | accepted 2026-10-19; now the non-functional requirements NFR-1 to NFR-10 in `docs/principles/non-functional-requirements.md` (ADR 0011); MCP none for now |
| [Agent principles](agent-principles.md) | accepted 2026-10-19; superseded 2026-10-20 by the five generic principles in `docs/principles/agents.md` (ADR 0013) |
| [Iteration package](iteration-package.md) | accepted (2026-10-16): the flow and rule (papers carry over; the foundation is merged, never nested; it holds what the iteration finds foundational, not the OS tooling); no true-up: this repository exports the first package, and its paper records what came over |
| [Host profile](host-profile.md) | decided 2026-10-23: the host is an adapter owned by devcontainer-cli (ADR 0024); `HOST_TYPE` with `HOST_TYPE_PRIORITY`, `DCF_HOST_*` variables, launcher mounts, the bootstrap in `.devcontainer/cli_bootstrap.ignore/`; build not started |
| [Cloud folder](cloud-folder.md) | decided 2026-10-27: a Feature giving the container one fixed folder filled from SharePoint or OneDrive through rclone (`host`, `sync`, `mount`; `auto` in that order); `remoteType` `sharepoint`; FUSE granted by the launcher on request; three slices, build not started |
| [Agents](agents.md) | decided 2026-10-27: one agent list per repository (path set by `AGENTS_FILE`), two kinds (`resident` attaches, `on-demand` opens a new session), one `task agent` verb, CLI adapters in a new `agents` Feature; the host stays `on-demand` until Remote Control reaches a background session; claude-code 2.0 drops claude-host, claude-fleet and the pin hook; build not started |
