#!/bin/bash
# Scenario 'participants_only_copilot' (see scenarios.json): copilot alone with participants: true
# installs the component itself (no claude-code, no agents Feature); installed-by names copilot.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

lib=/usr/local/lib/dcf-participant
check "agents on PATH is the component's" bash -c "[ \"\$(readlink -f \"\$(command -v agents)\")\" = $lib/agents.sh ]"
check "installed by copilot" grep -qx copilot $lib/installed-by
check "the component version is there" bash -c "grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\$' $lib/COMPONENT_VERSION"
check "the agents taskfile is registered" grep -q '^  agents:' /usr/local/share/go-task/features.yml
check "no claude-code files" bash -c "! test -e /usr/local/share/claude-code"
check "the state folder is there and sticky" bash -c "[ \"\$(stat -c %a /var/lib/devcontainer-features/agents)\" = 1777 ]"

reportResults
