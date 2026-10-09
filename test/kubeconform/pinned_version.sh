#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): version=0.8.0, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "kubeconform 0.8.0 installed" bash -c "kubeconform -v | grep -F 'v0.8.0'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && kubeconform -v'

reportResults
