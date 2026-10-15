#!/bin/bash
# Scenario 'hooks_and_safe_all' (see scenarios.json): hooksPath=.githooks,
# safeDirectory=*, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

# A fresh repository stands in for the workspace; git-setup runs from the cwd.
tmp="$(mktemp -d)"
cd "$tmp"
git init -q -b main .

check "git-setup adds safe.directory * and sets hooksPath" bash -c "git-setup | grep -F 'safe.directory: * (added)' && [ \"\$(git config core.hooksPath)\" = .githooks ]"
check "second run keeps both without duplicates" bash -c "git-setup | grep -F 'safe.directory: * (kept)' && [ \"\$(git config --global --get-all safe.directory | grep -cxF '*')\" -eq 1 ]"
check "hooksPath reported as kept on the second run" bash -c "git-setup | grep -F 'hooksPath: .githooks (kept)'"
check "GIT_CONFIG_GLOBAL points into the Feature's state dir" bash -c "[ \"\$GIT_CONFIG_GLOBAL\" = /var/lib/devcontainer-features/git/gitconfig ]"
check "state dir reported by git-setup" bash -c "git-setup | grep -Eq '^git: /var/lib/devcontainer-features/git \((volume|bind|image), writable\)\$'"
check "safe.directory * is in the global config inside the state dir" bash -c "git config --file /var/lib/devcontainer-features/git/gitconfig --get-all safe.directory | grep -qxF '*'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && git --version'

reportResults
