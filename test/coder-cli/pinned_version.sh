#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): version=2.36.7, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "coder 2.36.7 installed" bash -c "coder version | grep -F '2.36.7'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && coder version'
# The hook runs as the remote user and must hand it the (root-owned) mount.
# shellcheck disable=SC2016
check "coder-cli-setup makes the state dir writable for the non-root user" bash -c 'coder-cli-setup | grep -Eq "^coder-cli: /var/lib/devcontainer-features/coder-cli \((volume|bind|image), writable\)$" && [ "$(stat -c %u "$CODER_CONFIG_DIR")" = "$(id -u)" ]'

reportResults
