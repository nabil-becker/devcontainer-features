#!/bin/sh
# The shutdown check of this repository: devcontainer:stop and :rebuild run it
# inside the container, from the workspace folder, before stopping it (run it
# yourself with `task shutdown:check` or `task devcontainer:prepshutdown`).
# Contract: bootstrap/SHUTDOWN.md in github.com/nabil-becker/devcontainer-features.
#
#   exit 0      safe to stop (anything worth knowing is printed, not refused)
#   non-zero    refuse the stop; say what to fix above the exit
#
# Refuse only what a stop can break: work in flight (a git operation in
# progress, a stash left behind, a background job holding its lock). Report the
# rest: committed files, volumes and the host disk survive a stop. Run it
# again with FORCE=1 to stop anyway (`task devcontainer:stop FORCE=1`).
#
# Written by the bootstrap only where .devcontainer/shutdown-check.sh does not
# exist; yours to edit. POSIX sh, no dependencies beyond git.

problems=0
refuse() { echo "REFUSE: $*"; problems=$((problems + 1)); }
note() { echo "note: $*"; }

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  note 'not a git work tree; nothing to check here.'
  exit 0
fi

# A git operation in progress. `git rev-parse --git-path` resolves each path
# against the real git dir, which may live outside the workspace.
for p in index.lock rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  if [ -e "$(git rev-parse --git-path "$p")" ]; then
    refuse "a git operation is in progress ($p); finish or abort it."
  fi
done

# A stash left behind is work only this container's git dir knows about.
if git rev-parse --verify --quiet refs/stash >/dev/null 2>&1; then
  refuse 'a stash is left behind (git stash list); apply it, commit it or drop it.'
fi

# Reported, not refused: uncommitted and unpushed work survives a stop on the
# volumes and the checkout, but the Operator may want to know.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  note 'uncommitted changes (git status).'
fi
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || upstream=''
if [ -n "$upstream" ] && [ "$(git rev-list --count "$upstream..HEAD" 2>/dev/null)" != 0 ]; then
  note "commits not pushed to $upstream."
fi

# TODO: repo-specific checks, for example
#   - a background job that holds a lock file (refuse while it runs, or wait for
#     it: a check MAY wait briefly, up to 120 s, for in-flight work to finish);
#   - a long-running local process (a dev server, a migration) started by hand;
#   - a pending queue or an unsent draft that lives only in the container.

if [ "$problems" -gt 0 ]; then
  echo "Shutdown check: $problems problem(s) above."
  exit 1
fi
echo 'Shutdown check: safe to stop.'
