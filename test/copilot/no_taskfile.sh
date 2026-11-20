#!/bin/bash
# Scenario 'no_taskfile' (see scenarios.json): installTaskfile=false leaves no copilot include in the
# go-task registry.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "copilot is on PATH" command -v copilot
check "no copilot taskfile include" bash -c "! test -e /usr/local/share/go-task/includes.d/copilot.yml"
check "the registry has no copilot namespace" bash -c "! grep -q '^  copilot:' /usr/local/share/go-task/features.yml"

reportResults
