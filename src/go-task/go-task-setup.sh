#!/usr/bin/env bash
# go-task-setup: the go-task Feature's postCreateCommand, run as the remote user after every
# create/rebuild; also behind `task go-task:setup`. Idempotent, never fatal.
#
# With the taskAliases option off (no aliases.enabled marker) it does nothing and says nothing.
# With it on, it hands the folder of the generated aliases Taskfile to the current user and keeps
# it owner-only: install.sh chowns it to the remote user at image build, but the devcontainer CLI
# then remaps that user's UID to the host's, so the build-time owner can be stale and `task
# go-task:aliases` could not write. dcf-persist (vendored from src/common) does the handover.
# GO_TASK_SHARE / GO_TASK_STATE override the two folders (the unit test uses them).
set -u

share="${GO_TASK_SHARE:-/usr/local/share/go-task}"
state="${GO_TASK_STATE:-/var/lib/devcontainer-features/go-task}"

[ -f "$share/aliases.enabled" ] || exit 0

persist="$(command -v dcf-persist 2>/dev/null || true)"
[ -n "$persist" ] || persist="$(dirname "$0")/dcf-persist.sh"
if [ -f "$persist" ]; then bash "$persist" --label go-task "$state"; else mkdir -p "$state" 2>/dev/null || true; fi

if [ -d "$state" ]; then
  chmod 0700 "$state" 2>/dev/null || echo "go-task: could not restrict $state to its owner" >&2
  [ ! -e "$state/aliases.yml" ] || chmod 0600 "$state/aliases.yml" 2>/dev/null || echo "go-task: could not restrict $state/aliases.yml to its owner" >&2
fi
exit 0
