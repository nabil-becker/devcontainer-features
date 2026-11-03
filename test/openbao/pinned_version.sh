#!/bin/bash
# Scenario 'pinned_version' (see scenarios.json): version=2.7.1, remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "bao 2.7.1 installed" bash -c "bao version | grep -F 'v2.7.1'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && bao version'

check "dcf-secret and openbao-setup installed" bash -c "command -v dcf-secret && command -v openbao-setup"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "the volume's folder is writable by the remote user" bash -c '[ "$(id -u)" -ne 0 ] && openbao-setup | grep -E "writable\)$"'
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "the login is linked into the state dir" bash -c '[ "$(readlink ~/.vault-token)" = "$OPENBAO_STATE_DIR/token" ]'

reportResults
