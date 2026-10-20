# ADR-0017: Every branch name carries a backlog id and a workstream number

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-20 |
| **Deciders** | the Operator; proposed by the host |

## Context

Branches piled up: fourteen local ones and several on GitHub. GitHub already deletes a PR's branch
when it merges, so the leftovers came from places that setting cannot reach: branches that never
became a PR (one held work unmerged for four days and was nearly deleted as stale), a push to a
branch whose PR had already merged (the push recreated the branch and two commits missed `main`),
and local branches that no skill or task removes after a merge. Nothing tied a branch to the work
it held, so nobody could tell from a name whether it was finished.

The Operator asked that a branch name show its work items, so a branch, its PR, its commits and its
backlog item point at each other.

## Decision

A branch is named `<type>/<backlog-id>/<n>`. `<type>` is one of `feature`, `fix`, `docs`, `chore`;
`<backlog-id>` is the slug of an item in `TODO.md`; `<n>` is the workstream number, always present,
even for a single stream, so a subagent working the same item in parallel in a worktree gets the
next one (`feature/branch-merged-check/2`).

- A branch that covers several items names the main one; the PR description lists all of them and
  each commit names its own.
- Every branch names an item that exists in `TODO.md`; work with no item gets one written first.
  The backs' records use a standing item `records` that never closes (`chore/records/1`).
- `task devhost:branch -- <id>` creates the branch from `origin/main` with the next free `<n>`.
- The pre-push hook refuses a branch name that does not fit the shape or whose id is not in
  `TODO.md`.
- `task devhost:branches` lists every branch, local and remote, with its PR state, its item title and
  what it still adds to `main`; with `PRUNE=1` it deletes only what holds nothing `main` lacks.
- The briefing and the shutdown check report branches that are stale or hold unmerged work.
- Existing branches are renamed to fit the rule; an open PR whose branch was renamed was reopened
  from the new name.

## Options considered

### Option 1: the id and the workstream number in every name, enforced by a hook and a task (chosen)

The name carries the work, the shape is the same everywhere so the hook stays simple, and the task
removes the chance of a typo.

### Option 2: free names, tidied by a cleanup task alone

Fixes the pile but not the question "what is in this branch", and an unmerged branch still looks
like any other.

### Option 3: the workstream number only when there is more than one stream

Shorter names, but two shapes to check and a rename when the second stream starts.

## Consequences

- A branch tells what it holds from its name, and the item's title can be shown beside it.
- Every piece of work needs a backlog item first, even a small one.
- A branch with an open PR is never renamed on GitHub: renaming a PR's head branch closes the PR
  (2026-10-20: #9 and #29 closed, reopened as #31 and #30). Push the new name, open a new PR that
  says which one it replaces, close the old one.
- The standing item `records` must never be ticked or removed.
- Renaming a branch on GitHub closes its PR: the open ones had to be reopened from the new names.
- The build is a worktree job: the branch task, the cleanup task, the pre-push hook, the briefing
  line and the shutdown-check finding.

## Change log

| Date | Change |
|---|---|
| 2026-10-20 | First draft, accepted by the Operator. |
