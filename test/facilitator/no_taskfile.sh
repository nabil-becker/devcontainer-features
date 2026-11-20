#!/bin/bash
# Scenario 'no_taskfile' (see scenarios.json): installTaskfile false leaves no Taskfile; the command works.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "no Taskfile" bash -c '! test -e /usr/local/share/go-task/includes.d/facilitator.yml'
check "the command works" facilitator version

reportResults
