#!/bin/bash
# Scenario 'no_wrapper' (see scenarios.json): worktreeAware=false, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "no wrapper at /usr/local/bin/git" bash -c '! grep -qs "^# devcontainer-features git wrapper" /usr/local/bin/git'
check "git still works" bash -c "git --version | grep -E '^git version [0-9]+\.[0-9]+'"
check "git-setup is on PATH" command -v git-setup
check "dcf-persist on PATH" command -v dcf-persist
check "GIT_CONFIG_GLOBAL points into the Feature's state dir" bash -c "[ \"\$GIT_CONFIG_GLOBAL\" = /var/lib/devcontainer-features/git/gitconfig ]"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && git --version'

reportResults
