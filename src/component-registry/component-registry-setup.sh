#!/usr/bin/env bash
# component-registry-setup: the component-registry Feature's postStartCommand, run as the remote
# user at every container start; also behind `task component-registry:setup`. Idempotent, never
# fatal: a problem is reported, not allowed to abort the rest of the start.
#
# 1. dcf-persist makes the state folder (COMPONENT_REGISTRY_STATE_DIR, the Feature's named volume,
#    or a bind mount a repository put on the same target) exist and belong to the remote user.
# 2. The folder is made owner-only (0700): the layer copies and the resolved view are as
#    sensitive as their most sensitive layer, and a person's own layer may hold health facts.
# 3. Says whether a resolved view is there and how to make one; it never resolves by itself (the
#    agents start sequence does that in a later release).
set -u

dir="${COMPONENT_REGISTRY_STATE_DIR:-/var/lib/devcontainer-features/component-registry}"

persist="$(command -v dcf-persist 2>/dev/null || true)"
[ -n "$persist" ] || persist="$(dirname "$0")/dcf-persist.sh"
if [ -f "$persist" ]; then bash "$persist" --label component-registry "$dir"; else mkdir -p "$dir" 2>/dev/null || true; fi

if [ -d "$dir" ]; then
  chmod 0700 "$dir" 2>/dev/null || echo "component-registry: could not restrict $dir to its owner" >&2
else
  echo "component-registry: no state folder at $dir" >&2
  exit 0
fi
if [ -f "$dir/view/whoami" ]; then
  echo "component-registry: resolved view for $(cat "$dir/view/whoami") ($(cat "$dir/view/resolved" 2>/dev/null))"
else
  echo "component-registry: no resolved view yet; set COMPONENT_REGISTRY_WHOAMI and run 'task component-registry:resolve'"
fi
exit 0
