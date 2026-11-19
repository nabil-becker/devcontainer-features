#!/bin/bash
# Scenario 'no_taskfile' (see scenarios.json): installTaskfile=false, remoteUser=vscode. The Feature's
# Taskfile is not registered; the command still is installed.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "taskfile absent" bash -c "! test -e /usr/local/share/go-task/includes.d/register-engine.yml"
check "register-engine still installed" register-engine version

reportResults
