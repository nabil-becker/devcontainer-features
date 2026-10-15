#!/bin/bash
# Scenario 'non_root' (see scenarios.json): default options, remoteUser=vscode.
# The functional checks of test.sh again, this time as the non-root user the
# post-create hooks actually run as, so dcf-persist's sudo path is what makes
# a root-owned directory usable.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ]'
check "dcf-persist is on PATH" command -v dcf-persist
check "no arguments prints usage and exits 0" bash -c "dcf-persist 2>&1 | grep -q '^usage: dcf-persist' && dcf-persist >/dev/null 2>&1"

tmp="$(mktemp -d)"
check "creates a missing directory and reports it" bash -c "dcf-persist --label x '$tmp/sub' | grep -E '^x: .* \((image|bind|volume), writable\)\$' && test -d '$tmp/sub'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "a root-owned directory is chowned via sudo and reported writable" bash -c '
  rooted="$1"
  sudo -n mkdir -p "$rooted" && [ "$(stat -c %u "$rooted")" = 0 ]
  dcf-persist --label y "$rooted" | grep -E "^y: .* \((image|bind|volume), writable\)\$" \
    && [ "$(stat -c %u "$rooted")" = "$(id -u)" ] && test -w "$rooted"' _ "$tmp/rooted"
# A directory whose parent is not writable is created through sudo too.
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "creates a directory under a root-owned parent" bash -c '
  sudo -n mkdir -p "$1" && sudo -n chmod 0755 "$1"
  dcf-persist --label z "$1/child" | grep -E "^z: .* \((image|bind|volume), writable\)\$" && test -w "$1/child"' _ "$tmp/locked"

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/common.yml

reportResults
