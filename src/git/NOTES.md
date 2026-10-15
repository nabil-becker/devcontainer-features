## Why a wrapper

When a checkout's real git dir lives outside the workspace (on this
collection's Windows hosts: outside OneDrive, bind-mounted into the
container) the checkout's `.git` is a pointer file holding a host path, so
`devcontainer.json` sets `GIT_DIR` and `GIT_WORK_TREE` in `containerEnv`.
Those two variables reach *every* process. Git inside a linked worktree
(Claude Code's agent worktrees under `.claude/worktrees/<name>`) or a nested
repository then silently runs against the main checkout, and a test fixture
that does `git init` / `git commit` in a temporary folder re-initialises the
real repository (rewriting its config with `core.worktree` and
`core.filemode`, which breaks git on the Windows host) and commits onto its
branch. The wrapper at `/usr/local/bin/git` scopes the variables to the main
checkout. It finds the directory git will run in (`$PWD`, moved by `-C`) and
the subcommand, then unsets both variables when:

1. the subcommand is `init` or `clone` (creating a repository means "here",
   never the main checkout: kept, `clone` would check out into
   `GIT_WORK_TREE` and a re-init would write a container path as
   `core.worktree` into the shared git dir's config, breaking git on the
   host);
2. the directory is outside `GIT_WORK_TREE`;
3. inside it, the nearest ancestor with a `.git` (file or directory) is not
   `GIT_WORK_TREE` itself (a worktree or nested repo). The main checkout has
   a `.git` pointer file too, so its root keeps using `GIT_DIR`.

Everywhere else git runs unchanged, and without `GIT_DIR` the wrapper only
`exec`s the real git. `GIT_WRAPPER_REAL_GIT` overrides the baked-in path to
the real git.

## What post-create does

The Feature's `postCreateCommand` hook runs `git-setup` as the remote user
from the workspace folder (`task git:setup` re-runs it; it is idempotent and
never fails post-create - a missing git-dir mount is reported instead):

- creates the folder of `GIT_CONFIG_GLOBAL` (git creates the file, not its
  parent) and hands it to the remote user, through the shared `dcf-persist`
  helper, which also reports what backs it (`volume`, `bind` or `image`) and
  whether it is writable;
- `safe.directory`: with `safeDirectory: workspace` adds the workspace folder
  and `GIT_DIR` (when set) to the global config, each once; `*` adds `*`
  once; empty adds nothing;
- `core.hooksPath`: with `hooksPath` set (e.g. `.githooks`) configures it in
  the workspace repository (with `GIT_DIR` set, inside that git dir), only
  when it differs;
- reports which git runs (wrapper or not), whether `GIT_DIR` is set and
  whether the workspace is a usable work tree.

`GIT_SETUP_SAFE_DIRECTORY` and `GIT_SETUP_HOOKS_PATH` in `containerEnv`
override the Feature options at run time, so a repo can change either
without rebuilding the image.

## Pairs with

- Its own global git config: the Feature sets
  `GIT_CONFIG_GLOBAL=/var/lib/devcontainer-features/git/gitconfig` in
  `containerEnv` and mounts the named volume `git-config-${devcontainerId}`
  on that folder, so identity (`user.name`, `user.email`) and the credential
  helper survive rebuilds (`safe.directory` is re-added by the hook anyway).
  A storage reset of the container engine deletes the volume, and
  `${devcontainerId}` changes when the checkout moves, leaving the old one
  behind. For the host disk, bind-mount a host folder on the same target (a
  repo's `mounts` merge after the Features', last source on a target wins):
  `"source=${localEnv:USERPROFILE}${localEnv:HOME}/.devcontainer-homes/myrepo/git,target=/var/lib/devcontainer-features/git,type=bind"`,
  created before the first start by
  `"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "git"]`.
- A checkout whose git dir is bind-mounted, with `GIT_DIR` (the mount
  target) and `GIT_WORK_TREE` (`${containerWorkspaceFolder}`) in
  `containerEnv`; the wrapper is what makes worktrees usable there.
- `ghcr.io/devcontainers/features/git` or common-utils for git itself; this
  Feature lists both in `installsAfter`.
- A checkout synced by OneDrive: mount a named volume over the worktrees
  folder so the sync never sees a second copy of the repo
  (`"source=myrepo-worktrees,target=${containerWorkspaceFolder}/.claude/worktrees,type=volume"`,
  and gitignore the folder). Each worktree's `.git` pointer file is inside
  the volume, so the wrapper's rule works unchanged; after an engine reset
  the worktrees are gone but their commits are in the git dir, and
  `git worktree prune` clears the stale records.

## Why not `ghcr.io/devcontainers/features/git`

That Feature installs git (from the distribution or built from source). This
one does not install git at all; it augments whichever git is present - a
wrapper in front of it and the per-container setup - and sits after it in the
install order. A git it finds at `/usr/local/bin/git` (the source-built one)
is moved to `/usr/local/libexec/git-feature/git` and the wrapper forwards to
it.
