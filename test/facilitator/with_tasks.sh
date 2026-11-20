#!/bin/bash
# Scenario 'with_tasks' (see scenarios.json): go-task and facilitator, remoteUser=vscode. The tasks resolve
# through the registry and run as the non-root user; infra through its task is idempotent.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

registry=/usr/local/share/go-task/features.yml
check "runs as non-root" bash -c "[ \"\$(id -u)\" != 0 ]"
check "facilitator:version runs" bash -c "task -t $registry facilitator:version | grep -q '^facilitator 0'"
check "facilitator:infra -- up" bash -c "task -t $registry facilitator:infra -- up"
check "facilitator:infra -- up again" bash -c "task -t $registry facilitator:infra -- up | grep -c running | grep -qx 3"
check "facilitator:infra (status)" bash -c "task -t $registry facilitator:infra | grep -q 'slim   healthy'"
check "facilitator:check" bash -c "task -t $registry facilitator:check"
check "facilitator:status" bash -c "task -t $registry facilitator:status | grep -q participants"
check "facilitator:infra -- down" bash -c "task -t $registry facilitator:infra -- down"

reportResults
