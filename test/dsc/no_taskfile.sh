#!/bin/bash
# Scenario 'no_taskfile': installTaskfile=false keeps the binary but
# contributes no Taskfile to the registry.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "dsc installed" dsc --version
check "no taskfile registered" bash -c '! test -e /usr/local/share/go-task/includes.d/dsc.yml'

reportResults
