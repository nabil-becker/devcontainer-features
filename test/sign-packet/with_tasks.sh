#!/bin/bash
# Scenario 'with_tasks' (see scenarios.json): go-task and sign-packet, remoteUser=vscode. The Feature's
# tasks resolve through the registry and run as the non-root user, whose state folder is usable.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

registry=/usr/local/share/go-task/features.yml
check "runs as non-root" bash -c "[ \"\$(id -u)\" != 0 ]"
check "sign-packet:version runs" bash -c "task -t $registry sign-packet:version | grep -q '^sign-packet '"
check "the state folder is the remote user's" test -w "$SIGN_PACKET_HOME"
check "the instance id is recorded once" bash -c "sign-packet instance --quiet >/dev/null && test -s \"\$SIGN_PACKET_HOME/instance-id\""

reportResults
