# ADR-0047: Every Feature keeps a hand-written changelog checked by lint, and the version bump stays in the pull request

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-03 |
| **Deciders** | the Operator; proposed by the host |

## Context

A person opening a Feature should learn what changed without comparing code or reading git
commits, and without reverse-engineering how the Feature is used in an architecture landscape.

Today four Features (agents, claude-code, cloud-folder, devcontainer-cli) keep 30 "Changes in
x.y.z" sections in their `NOTES.md`; the other 15 keep no record beyond the squash commits.
The version is bumped by the pull request itself in `devcontainer-feature.json` (CLAUDE.md,
CONTRIBUTING.md).

The Operator also asked that no resources be spent on what a script can do.

## Decision

Every Feature has a `src/<id>/CHANGELOG.md` in one format. `NOTES.md` keeps only how the Feature
works. Entries are written for a user of the Feature: what changed, and whether they must act
(an option renamed, a task removed, a rebuild needed).

The version bump stays in the pull request, and the rule becomes: bump the version and add its
changelog entry in the same change (CONTRIBUTING.md and the pull request template say so). `task
lint` fails when a version has no changelog entry, or when the generated README is behind the
changelog. `task docs` copies the latest three versions into the Feature's README under
"Changes", with a full URL to `CHANGELOG.md`.

A script does the bulk of the work: it backfills the history from git, grouping commits under
each version bump, and moves the existing "Changes in" sections over as they are. Only the
latest entry per Feature is written by hand, in user words; older entries stay as commit
subjects with a note that they were backfilled. The script stays only if it earns it, for
example as `task changelog:draft FEATURE=<id>`.

## Options considered

### Option 1: a changelog file per Feature, kept by hand, checked by lint

Keeps the existing rule (the pull request bumps the version), needs no new tool, and lint makes
the record impossible to forget. Chosen.

### Option 2: semversioner

Each pull request adds a change file and `semversioner release` picks the version and writes the
changelog. It moves the version decision from the pull request to release time and writes it
back, so the bump rule and the release workflow change; it is also built around one project per
folder, which these many Features in one repository do not match without running it once per
Feature. It lost on that cost.

## Consequences

- Readers get a Feature's history on its README page or one link away.
- Every pull request that changes a Feature writes one more entry; lint refuses it if missing.
- All Features get a patch bump when the changelogs land, so one release covers them all once
  merged.
- The "How it fits" sections, best practices and anti-patterns, and reference architectures
  follow in later work and are not decided here.

## Change log

| Date | Change |
|---|---|
| 2026-11-03 | First draft. |
