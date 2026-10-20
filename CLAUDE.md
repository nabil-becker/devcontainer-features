# devcontainer-features

A public collection of Dev Container Features and the host-side tooling that
drives devcontainers from a Windows workstation, run as an ecosystem: every
consuming repo gets the same shape, and anything a repo has to script around
is a gap to close here. The rules of that ecosystem are in
[README.md](README.md) ("How the pieces fit") and the development conventions
in [CONTRIBUTING.md](CONTRIBUTING.md); read both before changing a Feature.

@.devhost/CLAUDE.devhost.md

The Features are the product; the devhost here is also the third iteration of the Agentic
Delivery OS, whose learnings become a white paper: [docs/iterations.md](docs/iterations.md).

## This repository in the way of working

- **Sessions run in the devhost.** `.devcontainer/` is this collection's own
  devhost, built from the Features in `src/` by local path (`task
  features:stage` copies them into `.devcontainer/features/` before every
  start), so what runs here is the unreleased tree. The workstation only
  bootstraps and launches (`task devcontainer:up`, `task devcontainer:claude`).
  A session on the workstation is an exception, used only when the work needs
  paths outside this checkout.
- **The checkout is the only thing on disk.** Feature state (Claude Code,
  git's global config, gh) lives in the Features' volumes; the checkout's git
  dir sits outside OneDrive and is bind-mounted, with the git Feature's wrapper
  keeping `GIT_DIR` scoped to it. Because of that, Claude Code cannot create a
  worktree for a subagent (`isolation: worktree` fails); make one with
  `git worktree add -b <branch> <path in the scratchpad> origin/main`, which
  the wrapper handles, and remove it with `git worktree remove` when merged.
- **Consumers are the office (`Client Engagement Assesments`) and DSNP
  (`kgo__dsnp`)**, both under `..\..\kgo\`. Their `.devcontainer/DEVCONTAINER_CONTRIBUTION.md`
  says what they adopt from each release. A wrapper found there is a backlog
  item here.

## Tasks

`task --list` is the API. The ones a session uses most:

- `task lint`: shellcheck, yamllint, PSScriptAnalyzer, the vendored-helper
  check and the devhost unit tests (runs anywhere).
- `task test FEATURE=<id>` / `task test:global`: the real Feature tests;
  need a Docker daemon (CI, or Docker Desktop; not `wslc`).
- `task docs`: regenerate `src/<id>/README.md` after a JSON or NOTES change.
- `task devhost:*`: briefing, report, costs, adr, verify, init.
- `task devcontainer:*` (alias `dc:`): the devhost from the workstation.

## Git here

`main` is protected: pull requests only, squash merges, DCO sign-off on every
commit (`task repo:setup` makes it automatic), required checks `validate`,
`lint`, `tests`, `DCO`. Work on a topic branch; bump the Feature `version` in
the same change; run `task docs` and commit the README; commit and push only
when asked. Releases are a manual workflow on `main` that the Operator starts: an agent says a
release is due and what it would publish, and never runs it. An unpublished Feature cannot be
named in `installsAfter` or pulled by a consumer until then.

Agent commits carry the bot identity `devhost agent <devhost-agent@noreply.invalid>`
(author, committer and sign-off) and a co-author trailer naming the model that wrote the commit,
at an unclaimable address, for example `Co-Authored-By: Claude Opus 5.5 <claude-opus-5-5@noreply.invalid>`.
Never `noreply@anthropic.com`: a stranger's GitHub account appears to have claimed it; it
shows up as a participant (ADR 0002). This overrides Claude Code's default
attribution trailer.
