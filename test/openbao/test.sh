#!/bin/bash
# Auto-generated scenario: the openbao Feature with default options
# (version=latest). Run with:
#   devcontainer features test -f openbao --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "bao is on PATH" command -v bao
check "bao reports a version" bash -c "bao version | grep -E '[0-9]+\.[0-9]+\.[0-9]+'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "binary is root-owned" bash -c '[ "$(stat -c %U "$(readlink -f "$(command -v bao)")")" = root ]'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/openbao.yml

# State (NFR-1): the variable, the pieces the hook needs, the options baked for it.
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "OPENBAO_STATE_DIR set" bash -c '[ "$OPENBAO_STATE_DIR" = /var/lib/devcontainer-features/openbao ]'
check "dcf-persist on PATH" command -v dcf-persist
check "openbao-setup on PATH" command -v openbao-setup
check "dcf-secret on PATH" command -v dcf-secret
check "mode baked for openbao-setup" grep -q '^MODE=client$' /usr/local/share/openbao-feature/options.env
check "openbao-setup reports the state dir" bash -c "openbao-setup | grep -E '^openbao: /var/lib/devcontainer-features/openbao \((volume|bind|image), writable\)$'"
check "openbao-setup links the login token into it" bash -c "openbao-setup >/dev/null; [ \"\$(readlink ~/.vault-token)\" = /var/lib/devcontainer-features/openbao/token ]"
check "second run keeps it" bash -c "openbao-setup | grep -F 'kept)'"
check "task openbao:setup is in the Taskfile" grep -q '^  setup:' /usr/local/share/go-task/includes.d/openbao.yml

# dcf-secret with no server: unreachable, exit 10, one line (a closed port, no waiting on a host)
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "dcf-secret status without a server is unreachable (exit 10)" bash -c 'out="$(BAO_ADDR=http://127.0.0.1:1 dcf-secret status 2>/dev/null)"; rc=$?; [ "$rc" = 10 ] && [ "$out" = unreachable ]'
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "dcf-secret get without a server is exit 10 and prints nothing" bash -c 'out="$(BAO_ADDR=http://127.0.0.1:1 dcf-secret get ssh/x 2>/dev/null)"; rc=$?; [ "$rc" = 10 ] && [ -z "$out" ]'

reportResults
