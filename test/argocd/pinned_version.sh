#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): version=3.5.4, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "argocd 3.5.4 installed" bash -c "argocd version --client --short | grep -F 'v3.5.4'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && argocd version --client --short'

reportResults
