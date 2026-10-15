#!/bin/bash
# Scenario 'augment_official' (see scenarios.json): the official
# ghcr.io/devcontainers/features/github-cli (apt) installs gh first; with
# install=auto this Feature keeps it and only adds the pieces.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "gh is on PATH" command -v gh
check "release binary NOT installed" test ! -e /usr/local/bin/gh
check "gh comes from elsewhere" bash -c "[ \"\$(command -v gh)\" != /usr/local/bin/gh ]"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "gh runs as non-root" bash -c '[ "$(id -u)" -ne 0 ] && gh --version'
check "GH_CONFIG_DIR set" bash -c "[ \"\$GH_CONFIG_DIR\" = /var/lib/devcontainer-features/gh ]"
check "dcf-persist on PATH" command -v dcf-persist
check "gh-setup on PATH" command -v gh-setup
check "gh-setup reports the kept gh" bash -c "gh-setup | grep -E '^gh: gh version .* at ' | grep -vF /usr/local/bin/gh"
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/gh.yml

reportResults
