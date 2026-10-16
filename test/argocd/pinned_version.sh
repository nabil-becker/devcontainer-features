#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): version=3.5.4, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "argocd 3.5.4 installed" bash -c "argocd version --client --short | grep -F 'v3.5.4'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && argocd version --client --short'
# The hook runs as the remote user and must hand it the (root-owned) mount.
# shellcheck disable=SC2016
check "argocd-setup makes the state dir writable for the non-root user" bash -c 'argocd-setup | grep -Eq "^argocd: /var/lib/devcontainer-features/argocd \((volume|bind|image), writable\)$" && [ "$(stat -c %u "$ARGOCD_CONFIG_DIR")" = "$(id -u)" ]'

reportResults
