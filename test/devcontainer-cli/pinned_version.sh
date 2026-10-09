#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): version=0.89.0, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "devcontainer 0.89.0 installed" bash -c "devcontainer --version | grep -F '0.89.0'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && devcontainer --version'
check "node not on PATH" bash -c '! command -v node'

reportResults
