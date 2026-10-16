#!/bin/bash
# Scenario 'no_taskfile': installTaskfile=false keeps the helper but
# contributes no Taskfile to the registry.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "dcf-persist is on PATH" command -v dcf-persist
check "no taskfile registered" bash -c '! test -e /usr/local/share/go-task/includes.d/common.yml'

reportResults
