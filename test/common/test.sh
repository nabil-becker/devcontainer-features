#!/bin/bash
# Auto-generated scenario: the common Feature with default options
# (installTaskfile=true). Run with:
#   devcontainer features test -f common --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "dcf-persist is on PATH" command -v dcf-persist
check "dcf-persist is executable" test -x /usr/local/bin/dcf-persist
check "dcf-persist is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/dcf-persist)\" = root ]"
check "no arguments prints usage and exits 0" bash -c "dcf-persist 2>&1 | grep -q '^usage: dcf-persist' && dcf-persist >/dev/null 2>&1"

# Functional: a fresh directory under a temp folder is created and reported.
tmp="$(mktemp -d)"
check "creates a missing directory and reports it" bash -c "dcf-persist --label x '$tmp/sub' | grep -E '^x: .* \((image|bind|volume), writable\)\$' && test -d '$tmp/sub'"

# A directory that arrived root-owned (as a named volume or bind mount does)
# is handed to the current user. The image's remoteUser may be root or not,
# so create it with sudo only when needed.
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "a root-owned directory is chowned and reported writable" bash -c '
  rooted="$1"
  if [ "$(id -u)" -eq 0 ]; then mkdir -p "$rooted"; else sudo -n mkdir -p "$rooted"; fi
  dcf-persist --label y "$rooted" | grep -E "^y: .* \((image|bind|volume), writable\)\$" \
    && [ "$(stat -c %u "$rooted")" = "$(id -u)" ] && test -w "$rooted"' _ "$tmp/rooted"

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/common.yml

reportResults
