#!/bin/bash
# Scenario 'official_listed' (see scenarios.json): the repo lists the official Feature itself with
# the same options (version 1.0.114) as this Feature's dependsOn, so the devcontainer CLI counts them as one
# install; copilot is there once, and this Feature adds its pieces.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "copilot is on PATH" command -v copilot
check "one copilot binary" bash -c "[ \"\$(type -ap copilot | wc -l)\" = 1 ]"
check "copilot runs as non-root" bash -c "[ \"\$(id -u)\" -ne 0 ] && copilot --version | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'"
check "agent-adapter-copilot on PATH" command -v agent-adapter-copilot
check "the official Feature's auto-update flag is its own business, not this Feature's" bash -c "! grep -rq copilot-feature /etc/devcontainer-copilot-cli 2>/dev/null"
check "the pinned version is installed" bash -c "copilot --version | grep -q '1\.0\.114'"
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/copilot.yml

reportResults
