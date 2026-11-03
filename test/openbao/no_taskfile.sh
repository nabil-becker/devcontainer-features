#!/bin/bash
# Scenario 'no_taskfile' (see scenarios.json): installTaskfile=false.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "bao is on PATH" command -v bao
check "dcf-secret is on PATH" command -v dcf-secret
check "no Taskfile registered" test ! -e /usr/local/share/go-task/includes.d/openbao.yml

reportResults
