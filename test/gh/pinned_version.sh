#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): version=2.80.0, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "gh 2.80.0 installed" bash -c "gh --version | grep -F 'gh version 2.80.0'"
check "release binary installed" bash -c "[ \"\$(command -v gh)\" = /usr/local/bin/gh ]"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && gh --version'
check "gh-setup hands the state dir to the user" bash -c "gh-setup | grep -E '^gh: /var/lib/devcontainer-features/gh \((volume|bind|image), writable\)$' && [ -w /var/lib/devcontainer-features/gh ]"

reportResults
