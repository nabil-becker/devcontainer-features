#!/bin/bash
# Scenario 'with_tasks' (see scenarios.json): go-task and audio, remoteUser=vscode. The Feature's
# tasks resolve through the registry; audio:check fails (no host socket here) and says why.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

registry=/usr/local/share/go-task/features.yml
check "audio:version runs" bash -c "task -t $registry audio:version | grep -q 'PULSE_SERVER=unix:/mnt/wslg/PulseServer'"
check "audio:check fails without a socket" bash -c "! task -t $registry audio:check"
check "audio:check says what is missing" bash -c "task -t $registry audio:check 2>&1 | grep -q 'socket not reachable'"
check "runs as the remote user" bash -c "[ \"\$(id -un)\" = vscode ]"

reportResults
