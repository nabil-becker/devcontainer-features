#!/bin/bash
# Scenario 'no_taskfile' (see scenarios.json): installTaskfile=false, remoteUser=vscode. The Feature's
# Taskfile is not registered; the command still is installed.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "taskfile absent" bash -c "! test -e /usr/local/share/go-task/includes.d/phi-check.yml"
check "phi-check still installed" command -v phi-check
check "phi-check runs" phi-check --version

reportResults
