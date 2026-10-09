#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): version=v3.54.0, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "task 3.54.0 installed" bash -c "task --version | grep -F '3.54.0'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && task --version'

reportResults
