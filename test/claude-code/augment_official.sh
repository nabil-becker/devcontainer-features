#!/bin/bash
# Scenario 'augment_official' (see scenarios.json): the official
# ghcr.io/anthropics/devcontainer-features/claude-code (npm) installs claude
# first; with install=auto this Feature keeps it and only adds the pieces.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "claude is on PATH" command -v claude
check "native binary NOT installed" test ! -e /usr/local/bin/claude
check "claude comes from the npm install" bash -c "command -v claude | grep -q node"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "claude runs as non-root" bash -c '[ "$(id -u)" -ne 0 ] && claude --version'
check "claude-host on PATH" command -v claude-host
check "claude-code-setup on PATH" command -v claude-code-setup
check "dcf-persist on PATH" command -v dcf-persist
check "autoupdater disabled" bash -c "[ \"\$DISABLE_AUTOUPDATER\" = 1 ]"
check "CLAUDE_CONFIG_DIR points at the Feature's state dir" bash -c "[ \"\$CLAUDE_CONFIG_DIR\" = /var/lib/devcontainer-features/claude-code ]"
check "setup makes the state dir usable and reports it" bash -c "claude-code-setup | grep -Eq '^claude-code: /var/lib/devcontainer-features/claude-code \((volume|bind|image), writable\)\$'"
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/claude-code.yml

reportResults
