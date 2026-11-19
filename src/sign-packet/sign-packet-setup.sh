#!/usr/bin/env bash
# sign-packet-setup: the post-create hook (also `task sign-packet:setup`). Never fatal: a problem is
# one line, and the container's creation goes on; `sign-packet check` is what fails.
# It makes the state folder usable and resolves this instance's id once (.env, OpenBao, or made here).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
persist="$here/../libexec/sign-packet/dcf-persist"
state="${SIGN_PACKET_HOME:-/var/lib/devcontainer-features/sign-packet}"
case "$state" in
  /var/lib/devcontainer-features/*) "$persist" --label sign-packet "$state" || true ;;
  *) echo "sign-packet: SIGN_PACKET_HOME ($state) is not under /var/lib/devcontainer-features/; its ownership is left alone" ;;
esac
"$here/sign-packet" instance || echo "sign-packet: the instance id is not settled; run sign-packet instance"
exit 0
