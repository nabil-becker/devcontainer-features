#!/bin/bash
# Scenario 'no_taskfile' (see scenarios.json): installTaskfile=false, remoteUser=vscode. The
# Feature's Taskfile is not registered; the commands are.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "taskfile absent" bash -c "! test -e /usr/local/share/go-task/includes.d/component-registry.yml"
check "dcf-registry still installed" command -v dcf-registry
check "COMPONENT_REGISTRY_STATE_DIR set" bash -c "[ \"\$COMPONENT_REGISTRY_STATE_DIR\" = /var/lib/devcontainer-features/component-registry ]"

reportResults
