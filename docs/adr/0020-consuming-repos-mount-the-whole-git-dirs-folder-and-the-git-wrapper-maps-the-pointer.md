# ADR-0020: Consuming repos mount the whole git-dirs folder, and the git wrapper maps the pointer

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-21 |
| **Deciders** | the Operator; proposed by the host |

## Context

On a Windows workstation, checkouts live in OneDrive and each checkout's `.git` is a pointer file
naming a host path under `.git-dirs` in the user profile; the path means nothing inside the
container. Until now every consuming repo declared its own bind mount of one git dir plus
`GIT_DIR` and `GIT_WORK_TREE` in `containerEnv`, and the git Feature's wrapper scoped those to the
main checkout and restored them when Claude Code replaced `GIT_DIR` with a placeholder. Anything a
repo has to script around is a gap to close in the Features (`CLAUDE.md`). A Feature cannot mount
the host folder itself: the dev container CLI (0.89.0, checked in source) substitutes only
`${devcontainerId}` in a Feature's own `mounts` and `containerEnv`, never `${localEnv}`.

## Decision

Every consuming repo adds one identical line,
`"mounts": ["source=${localEnv:USERPROFILE}/.git-dirs,target=/git-dirs,type=bind"]`, and no
`GIT_DIR` or `GIT_WORK_TREE`. The git Feature (1.4.0) maps the pointer itself: when `GIT_DIR` is
unset or is the placeholder, and the nearest `.git` is a file whose `gitdir:` value contains a
`.git-dirs` segment (matched case-insensitively, `\` and `/` alike), the wrapper joins the part
after that segment onto the container root and, if `HEAD` exists there, exports `GIT_DIR` and
`GIT_WORK_TREE` for that call only. A pointer that already works, nested repos, `init` and
`clone` keep the existing rules; a pointer outside the root or a missing directory changes
nothing. The container path is the variable `GIT_DIRS_ROOT`, default `/git-dirs`, shared by the
wrapper and `git-setup` through `git-dirs.sh`; it is a plain variable, not a Feature option. The
Operator accepts that every container sees all of `.git-dirs`. The old per-repo form still works
and wins over the mapping.

## Options considered

### Option 1: one identical mount of the whole folder, mapped by the wrapper (chosen)

The line is the same in every repo, needs no repo name, and the wrapper does the work the repo
used to script. Cost: every container sees every git dir under `.git-dirs`.

### Option 2: keep the per-repo mount and `GIT_DIR`/`GIT_WORK_TREE`

Scopes each container to its own git dir, but every repo repeats a repo-specific mount and two
variables, and folder names under `.git-dirs` need not match the repo folder. It is the gap this
decision closes.

### Option 3: the Feature mounts the host folder itself

Impossible today: a Feature's own `mounts` never get `${localEnv}` substituted.

### Option 4: a `gitDirsRoot` Feature option instead of a variable

The mount target is written by the consuming repo, so its override belongs next to it in
`containerEnv`: it needs no rebuild and the wrapper reads no extra file per call. Left open for
the Operator if a visible option is wanted; it would be a small change in `install.sh`.

## Consequences

- Consuming repos shrink to one line, and the wrapper's per-call cost stays within noise
  (about 0.1 ms for a repo needing no mapping, 0.25 to 0.3 ms mapped, cheaper than the old form).
- A release of git 1.4.0 is due before consumers can drop their per-repo mounts, and they need
  the updated `devcontainer:homes` so `~/.git-dirs` exists before the start.
- On Linux and macOS hosts `${localEnv:USERPROFILE}` is empty, so the line there needs
  `${localEnv:HOME}`; `git worktree add` in the container records the container path, so git on
  Windows sees those worktrees as prunable. Both are stated in the Feature's NOTES.
- This devhost's own `.devcontainer/devcontainer.json` is not switched yet; doing so exposes
  every consumer's git dir to this devhost and needs a rewording of `CLAUDE.md`.

## Change log

| Date | Change |
|---|---|
| 2026-10-21 | First draft, design accepted by the Operator; the `gitDirsRoot` option question is open. |
