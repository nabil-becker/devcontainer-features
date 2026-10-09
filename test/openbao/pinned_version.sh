#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): version=2.7.1, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "bao 2.7.1 installed" bash -c "bao version | grep -F 'v2.7.1'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && bao version'

reportResults
