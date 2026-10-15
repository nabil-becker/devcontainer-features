#!/usr/bin/env bash
# argocd-setup: the argocd Feature's postCreateCommand, run as the remote
# user from the workspace folder after every create/rebuild; also behind
# `task argocd:setup`. Idempotent, never fatal: a problem is reported, not
# allowed to abort the rest of post-create.
#
# Makes the Argo CD CLI state directory usable: ARGOCD_CONFIG_DIR (the
# Feature's named volume at /var/lib/devcontainer-features/argocd, a repo's
# bind mount over it, or ~/.config/argocd when unset) exists and belongs to
# the remote user. Mounts arrive owned by root or by the host's uid, and
# `argocd login` then cannot write its config there. dcf-persist (shared by
# every Feature of this collection) does the create/chown and reports path,
# backing and writability.
set -u

dir="${ARGOCD_CONFIG_DIR:-$HOME/.config/argocd}"
dcf-persist --label argocd "$dir"
# `argocd login` writes $dir/config (YAML: contexts, servers, users with
# their tokens). A login is a non-empty `contexts:` list in that file; the
# file is only scanned, never printed, and no server is contacted (`argocd
# context` exits 0 with an empty list, so its exit code says nothing).
if [ -s "$dir/config" ] && awk '
    /^contexts:/ { in_contexts = 1; next }
    /^[^ \t-]/   { in_contexts = 0 }
    in_contexts && /^[ \t]*- / { found = 1 }
    END { exit !found }' "$dir/config"; then
  echo "argocd-setup: login present (current context: $(sed -n 's/^current-context: *//p' "$dir/config" | head -n 1))"
else
  echo "argocd-setup: no login yet (run: argocd login <server>; the session persists in $dir)"
fi
exit 0
