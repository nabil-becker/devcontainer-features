#!/usr/bin/env bash
# packet-relay-setup: the post-create hook (also `task packet-relay:setup`). Never fatal: a problem is
# one line, and the container's creation goes on; `packet-relay check` is what fails.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
persist="$here/../libexec/packet-relay/dcf-persist"
"$persist" --label packet-relay "${PACKET_RELAY_HOME:-/var/lib/devcontainer-features/packet-relay}" || true
"$here/packet-relay" setup || echo "packet-relay: setup did not finish; run packet-relay check"
exit 0
