#!/bin/bash
# Auto-generated scenario: the claude-code Feature with default options
# (version=stable). Run with:
#   devcontainer features test -f claude-code --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "claude is on PATH" command -v claude
check "claude reports a version" bash -c "claude --version | grep -E '^[0-9]+\.[0-9]+\.[0-9]+'"
check "binary is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/claude)\" = root ]"
check "autoupdater disabled" bash -c "[ \"\$DISABLE_AUTOUPDATER\" = 1 ]"

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/claude-code.yml

reportResults
