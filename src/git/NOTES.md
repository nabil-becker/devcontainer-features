## A git dir outside the workspace: one mount line

On this collection's Windows hosts a checkout lives in OneDrive and its git
dir does not: the checkout's `.git` is a pointer file,
`gitdir: C:/Users/<user>/.git-dirs/<owner>/<repo>`, a path that means nothing
in the container. Every consuming repo adds the same line, and nothing else:

```jsonc
"mounts": ["source=${localEnv:DCF_HOST_HOME}/.git-dirs,target=/git-dirs,type=bind"]
```

`DCF_HOST_HOME` is the host user's home (`%USERPROFILE%` on Windows, `$HOME` on Linux and
macOS), set by the launcher (`task devcontainer:up`, devcontainer-cli 1.5.0 or later) before it
runs the devcontainer CLI, so the same line works on every host type. The older form
`source=${localEnv:USERPROFILE}/.git-dirs,...` keeps working on Windows.

The wrapper then maps the pointer for each git call. When `GIT_DIR` is not
set (or is Claude Code's placeholder, below) and the nearest `.git` above the
directory git runs in is a *file* whose `gitdir:` value has a `.git-dirs`
segment (matched case-insensitively, `\` and `/` alike, any drive or user
profile), it takes everything after that segment, joins it onto
`GIT_DIRS_ROOT` (default `/git-dirs`) and, when `<root>/<rest>/HEAD` exists,
exports `GIT_DIR=<root>/<rest>` and `GIT_WORK_TREE=<checkout root>` for that
call only. The folder names under `.git-dirs` need not match the checkout's
folder: the pointer says where it is. Left alone: a pointer that already
works (a Linux path, a linked worktree, `.claude/worktrees/<name>`), a nested
repository (its `.git` is a directory), `init` and `clone`, an explicit
`--git-dir`/`--work-tree`, and a `GIT_WORK_TREE` set on its own. A pointer
with no `.git-dirs` segment, one that climbs out with `..`, or a mapped
folder with no `HEAD` (the mount is missing) changes nothing: git fails as it
would without the wrapper. The mapping lives in
`/usr/local/share/git-feature/git-dirs.sh`, sourced by both the wrapper and
`git-setup`; it is one read of the pointer file and string operations, no
subprocess. Measured with the real git replaced by `true` (1,000 calls, three
runs): the wrapper adds about 0.1 ms in a repository that needs no mapping and
about 0.3 ms in a mapped checkout, against about 1 ms more for the per-repo
`GIT_DIR` form, which spawns two subshells per call.

At post-create, `git-setup` resolves the workspace's pointer the same way,
records the result for the placeholder restore, and adds the workspace's top
level (`git rev-parse --show-toplevel`, else the nearest folder with a
`.git`, else the workspace folder) and the mapped git dir to
`safe.directory`. When it cannot map, it prints one line and goes on:

- `git dir: NOT MOUNTED - <checkout>/.git points to <pointer>, expected at
  /git-dirs/<owner>/<repo>; add to devcontainer.json "mounts": [...]` with
  the exact mount line, when the pointer is under `.git-dirs` but the folder
  is not there (no mount, or a folder name that differs on the host);
- `git dir: OUTSIDE .git-dirs - <checkout>/.git points to <pointer>, which
  the container cannot reach; keep the git dir under
  %USERPROFILE%\.git-dirs\<owner>\<repo> (update the pointer) and add ...`
  when the git dir is somewhere else on the host.

**The trade-off, plainly:** the mount exposes *every* git dir under
`%USERPROFILE%\.git-dirs` to every container that declares it, read-write,
not only this repository's. A process in one devcontainer can read and change
the history, hooks and config of the others. That is the price of one
identical line instead of a per-repo path; the Operator accepted it for this
collection's hosts. A repo that must not see its neighbours keeps the
per-repo form below.

`GIT_DIRS_ROOT` is a plain variable, not a Feature option: the mount target
is written by the consuming repo in its own `devcontainer.json`, so the
override belongs next to it (`containerEnv`), takes effect without a rebuild,
and the wrapper reads no options file per call. Changing it defeats the
point of the one identical line; it exists for an image where `/git-dirs` is
taken and for tests.

**Migrating from the per-repo mount:** delete the repo's
`source=.../.git-dirs/<owner>/<repo>,target=/git/<repo>.git` mount and the
`GIT_DIR` and `GIT_WORK_TREE` entries from `containerEnv`, add the line above,
and rebuild (git 1.4.0 or later). Keep `task devcontainer:homes` in
`initializeCommand`: it creates `%USERPROFILE%\.git-dirs` when missing, so the
bind mount never fails on a fresh machine; `HOST_GIT_DIR` is optional now.
Nothing else changes: the per-repo form (`GIT_DIR` and `GIT_WORK_TREE` in
`containerEnv`) keeps working exactly as before and wins over the mapping.

**Host safety:** the git dir is shared with git on Windows, so nothing in the
container writes a container path into its `config`: the mapping only sets
environment variables for one call, `init` and `clone` are never mapped, and
`git-setup` writes `safe.directory` to the global config only
(`core.hooksPath`, when the option is set, is a relative path). The unit test
compares the git dir's `config` byte for byte before and after `git-setup` and
a run of wrapper calls. `git worktree add` does record the new worktree's
container path in `<git dir>/worktrees/<name>/gitdir` (outside `config`), as
it did with the per-repo form; git on Windows sees those worktrees as
prunable.

Limits: `${localEnv:USERPROFILE}` is empty on a Linux or macOS host, which is why the
line uses `${localEnv:DCF_HOST_HOME}`; it is empty too when the folder is opened straight
in VS Code (the launcher did not run), so start through `task devcontainer:up`. A checkout
whose git dir is a plain `.git` folder needs none of this.

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

## The placeholder Claude Code puts in GIT_DIR

Claude Code does not pass an inherited `GIT_DIR` on (with either form). It reads `<cwd>/.git`
itself and, when that pointer holds a path it cannot use (the git dir lives
outside the workspace, so the pointer is a host path), runs git with
`GIT_DIR=<somewhere>/not-a-git-repository`; its subagent worktree isolation
then fails ("Failed to resolve base branch"). By the time the wrapper runs, the
placeholder has overwritten the real values, so `git-setup` records them at
post-create, from the container's `GIT_DIR` and `GIT_WORK_TREE`
(`containerEnv`) or from the mapped `.git-dirs` pointer, in
`/var/lib/devcontainer-features/git/dirs.env` (the Feature's state volume;
rewritten on every post-create, removed when there is nothing to record,
never written from a placeholder). Without the file the mapping still applies
to the placeholder: after the rules below, a `GIT_DIR` that is unset or still
the placeholder is mapped as above. The wrapper reads it only when
`GIT_DIR` ends in `/not-a-git-repository`, and when the directory git runs in
(`$PWD`, moved by `-C`) is inside the main checkout's work tree but not inside
a linked worktree (`<work tree>/.claude/worktrees/<name>`), puts `GIT_DIR` and
`GIT_WORK_TREE` back and unsets `GIT_COMMON_DIR`; the rules above then apply as
usual (a nested repository still drops them). In a linked worktree, or outside
the work tree, nothing is restored. A consumer sets nothing new: `GIT_DIR` and
`GIT_WORK_TREE` in `containerEnv` are what it already has, and post-create has
to run once (rebuild or `task git:setup`). `GIT_WRAPPER_DIRS_FILE` overrides
the file's path. The decision is made on the directory, not on the inherited
`GIT_WORK_TREE`, because that is what git is about to run in.

## Commit identity for agents

With `commitEmail` (and `commitName`) set, the wrapper exports
`GIT_AUTHOR_NAME/EMAIL` and `GIT_COMMITTER_NAME/EMAIL` for every git it runs,
each only when the caller has not set it. Environment variables beat every
config level, so a repository-local `user.email` (for example the Operator's
address in a git dir shared with the host checkout) cannot leak into an
agent's commit, `git commit -s` signs off with the same identity, and nothing
has to touch the shared config or pass `-c` overrides. `install.sh` writes the
values to `/usr/local/share/git-feature/identity.env`, which the wrapper
sources (one file read per call). The wrapper is installed for this even with
`worktreeAware: false`. Empty (the default) leaves identity alone.

`commitWhenEnv` narrows it to agents: with a variable name set (for example
`CLAUDECODE`, which Claude Code sets on every process it starts: its tool
calls, its subagents and headless `claude -p` runs such as the devhost's
backs), the wrapper applies the identity only when that variable is set and
non-empty. A person's own terminal does not have it, so their commits keep the
repository's or their global identity, while every agent commit is the bot's.
Empty (the default) applies the identity to every git invocation, as before.

Why not the alternatives: `containerEnv` in a consumer's `devcontainer.json`
works but cannot be driven by a Feature option, so each repo would repeat four
variables; `profile.d` reaches only login shells, missing headless agents,
hooks and `docker exec` without a shell. The wrapper is on `PATH` for every
process. A caller that sets the variables itself (a human exporting their own
identity) keeps them.

## What post-create does

The Feature's `postCreateCommand` hook runs `git-setup` as the remote user
from the workspace folder (`task git:setup` re-runs it; it is idempotent and
never fails post-create - a missing git-dir mount is reported instead):

- creates the folder of `GIT_CONFIG_GLOBAL` (git creates the file, not its
  parent) and hands it to the remote user, through the shared `dcf-persist`
  helper, which also reports what backs it (`volume`, `bind` or `image`) and
  whether it is writable;
- the git dir: records `GIT_DIR`/`GIT_WORK_TREE` from `containerEnv`, or
  maps the workspace's `.git-dirs` pointer (above) and records that, or says
  in one line what mount is missing;
- `safe.directory`: with `safeDirectory: workspace` adds the workspace folder
  (its top level when mapped) and the git dir (`GIT_DIR`, or the mapped one)
  to the global config, each once; `*` adds `*` once; empty adds nothing;
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
  `"source=${localEnv:USERPROFILE}/.devcontainer-homes/myrepo/git,target=/var/lib/devcontainer-features/git,type=bind"`,
  created before the first start by
  `"initializeCommand": ["task", "devcontainer:homes", "NAME=myrepo", "--", "git"]`.
- A checkout whose git dir lives under `%USERPROFILE%\.git-dirs`: the one
  `.git-dirs` mount (top of this page), created by `task devcontainer:homes`.
  The older per-repo form still works: the git dir bind-mounted on its own,
  with `GIT_DIR` (the mount target) and `GIT_WORK_TREE`
  (`${containerWorkspaceFolder}`) in `containerEnv`; the wrapper is what
  makes worktrees usable there.
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
