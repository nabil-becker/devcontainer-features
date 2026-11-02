#!/usr/bin/env bash
# agentic-register-setup: the post-create hook (also `task agentic-register:setup`). Never fatal:
# a problem is one line, and the container's creation goes on; `agentic-register check` is what fails.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
persist="$here/../libexec/agentic-register/dcf-persist"
"$persist" --label agentic-register "${AGENTIC_REGISTER_HOME:-/var/lib/devcontainer-features/agentic-register}" || true
"$here/agentic-register" setup || echo "agentic-register: setup did not finish; run agentic-register check"
exit 0
