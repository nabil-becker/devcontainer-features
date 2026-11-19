#!/bin/bash
# Scenario 'with_tasks' (see scenarios.json): go-task and register-engine, remoteUser=vscode. The
# Feature's tasks resolve through the registry and run as the non-root user.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

registry=/usr/local/share/go-task/features.yml
check "runs as non-root" bash -c "[ \"\$(id -u)\" != 0 ]"
check "register-engine:version runs" bash -c "task -t $registry register-engine:version | grep -q '^register-engine '"
check "register-engine:types runs" bash -c "task -t $registry register-engine:types | grep -q log"

reportResults
