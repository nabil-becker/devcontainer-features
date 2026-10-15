#!/bin/bash
# Scenario 'install_none' (see scenarios.json): only the ecosystem pieces,
# no binary.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "no claude binary" bash -c "! command -v claude"
check "claude-host on PATH" command -v claude-host
check "claude-code-setup on PATH" command -v claude-code-setup
check "dcf-persist on PATH" command -v dcf-persist
check "CLAUDE_CONFIG_DIR points at the Feature's state dir" bash -c "[ \"\$CLAUDE_CONFIG_DIR\" = /var/lib/devcontainer-features/claude-code ]"
check "setup still works without claude" bash -c "claude-code-setup | grep -Eq '^claude-code: /var/lib/devcontainer-features/claude-code \((volume|bind|image), writable\)\$'"
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/claude-code.yml

reportResults
