#!/usr/bin/env bash
# facilitator-setup: the post-create hook (also `task facilitator:setup`). Never fatal: a problem is one
# line and the container's creation goes on; `facilitator check` is what fails.
# It makes the state folder (the volume) the remote user's and makes the facilitator's own key.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
persist="$here/../libexec/facilitator/dcf-persist"
state="${FACILITATOR_HOME:-/var/lib/devcontainer-features/facilitator}"
case "$state" in
  /var/lib/devcontainer-features/*) "$persist" --label facilitator "$state" || true ;;
  *) echo "facilitator: FACILITATOR_HOME ($state) is not under /var/lib/devcontainer-features/; its ownership is left alone" ;;
esac
"$here/facilitator" setup || echo "facilitator: setup did not complete; run facilitator check"
exit 0
