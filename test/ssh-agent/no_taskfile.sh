#!/bin/bash
# Scenario 'no_taskfile' (see scenarios.json): installTaskfile=false leaves the Taskfile out.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "taskfile not registered" bash -c "! test -e /usr/local/share/go-task/includes.d/ssh-agent.yml"
check "ssh-agent-setup still installed" command -v ssh-agent-setup

reportResults
