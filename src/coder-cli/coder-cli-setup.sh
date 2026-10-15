#!/usr/bin/env bash
# coder-cli-setup: the coder-cli Feature's postCreateCommand, run as the
# remote user from the workspace folder after every create/rebuild; also
# behind `task coder-cli:setup`. Idempotent, never fatal: a problem is
# reported, not allowed to abort the rest of post-create.
#
# Makes the Coder CLI state directory usable: CODER_CONFIG_DIR (the Feature's
# named volume at /var/lib/devcontainer-features/coder-cli, a repo's bind
# mount over it, or ~/.config/coderv2 when unset) exists and belongs to the
# remote user. Mounts arrive owned by root or by the host's uid, and
# `coder login` then cannot write its session there. dcf-persist (shared by
# every Feature of this collection) does the create/chown and reports path,
# backing and writability.
set -u

dir="${CODER_CONFIG_DIR:-$HOME/.config/coderv2}"
dcf-persist --label coder-cli "$dir"
# `coder login` writes the session token to $dir/session (and the server to
# $dir/url). The file's presence is the login check: `coder whoami` would
# need the server reachable and stall post-create offline. The token is
# never printed, only the server it belongs to.
if [ -s "$dir/session" ]; then
  echo "coder-cli-setup: login present (server: $(cat "$dir/url" 2>/dev/null || echo unknown))"
else
  echo "coder-cli-setup: no login yet (run: coder login <url>; the session persists in $dir)"
fi
exit 0
