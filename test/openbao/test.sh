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
check "openbao-server on PATH" command -v openbao-server
check "openbao-run on PATH" command -v openbao-run
check "openbao-onboard on PATH" command -v openbao-onboard
check "openbao-keyfile on PATH (the OpenBao key file's container side)" command -v openbao-keyfile
check "the unlock option is baked as operator by default" grep -q '^UNLOCK=operator$' /usr/local/share/openbao-feature/options.env
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "openbao-setup unlock --status answers mode off in client mode, exit 0" bash -c 'out="$(openbao-setup unlock --status)" && [ "$(jq -r .mode <<<"$out")" = off ]'
check "openbao-lib.sh is installed next to env.sh (the two scripts source it)" test -f /usr/local/share/openbao-feature/openbao-lib.sh
check "jq is installed (the onboarding scripts read bao's JSON with it)" command -v jq
check "openbao-ssh on PATH" command -v openbao-ssh
check "the ssh record tasks are in the Taskfile" bash -c "grep -q '^  ssh:new:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  ssh:import:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  ssh:retire:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  ssh:age:' /usr/local/share/go-task/includes.d/openbao.yml"
check "env.sh is installed for them" test -f /usr/local/share/openbao-feature/env.sh
check "dcf-ssh-sign on PATH" command -v dcf-ssh-sign
check "the SSH CA tasks are in the Taskfile" bash -c "grep -q '^  ssh:ca:init:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  ssh:ca:role:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  ssh:ca:import:' /usr/local/share/go-task/includes.d/openbao.yml"
# dcf-ssh-sign with no server: unreachable, exit 10 (a closed port); and a wrong call is exit 2
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "dcf-ssh-sign status without a server is unreachable (exit 10)" bash -c 'out="$(env -u CLAUDECODE -u DEVHOST_JOB_CHILD BAO_ADDR=http://127.0.0.1:1 dcf-ssh-sign status 2>/dev/null)"; rc=$?; [ "$rc" = 10 ] && [ "$out" = unreachable ]'
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "dcf-ssh-sign with no command is exit 2" bash -c 'env -u CLAUDECODE -u DEVHOST_JOB_CHILD dcf-ssh-sign >/dev/null 2>&1; [ "$?" = 2 ]'
check "the server-mode tasks are in the Taskfile" bash -c "grep -q '^  init:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  unseal:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  seal:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  server:status:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  password:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  approle:issue:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  approle:revoke:' /usr/local/share/go-task/includes.d/openbao.yml"
check "the onboarding tasks are in the Taskfile" bash -c "grep -q '^  onboard:export:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  onboard:claim:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  wrap:' /usr/local/share/go-task/includes.d/openbao.yml && grep -q '^  unwrap:' /usr/local/share/go-task/includes.d/openbao.yml"
check "client mode (the default) runs no server" bash -c "openbao-setup start; ! pgrep -x bao"
check "mode baked for openbao-setup" grep -q '^MODE=client$' /usr/local/share/openbao-feature/options.env
check "openbao-setup reports the state dir" bash -c "openbao-setup | grep -E '^openbao: /var/lib/devcontainer-features/openbao \((volume|bind|image), writable\)$'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "BAO_CONFIG_PATH names the Feature's token-helper config" bash -c '[ "$BAO_CONFIG_PATH" = /usr/local/share/openbao-feature/bao-config.hcl ]'
check "the config names the token helper" grep -qx 'token_helper = "/usr/local/bin/openbao-token-helper"' /usr/local/share/openbao-feature/bao-config.hcl
check "the token helper is on PATH and executable" test -x /usr/local/bin/openbao-token-helper
check "openbao-setup says the token helper is in effect" bash -c "openbao-setup | grep -F 'token helper in effect'"
check "the helper round-trips a token in the state dir (mode 600)" bash -c "d=\$(mktemp -d) && printf tok | OPENBAO_STATE_DIR=\$d openbao-token-helper store && [ \"\$(OPENBAO_STATE_DIR=\$d openbao-token-helper get)\" = tok ] && [ \"\$(stat -c %a \$d/token)\" = 600 ] && OPENBAO_STATE_DIR=\$d openbao-token-helper erase && [ ! -e \$d/token ]"
check "task openbao:setup is in the Taskfile" grep -q '^  setup:' /usr/local/share/go-task/includes.d/openbao.yml

# dcf-secret with no server: unreachable, exit 10, one line (a closed port, no waiting on a host)
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "dcf-secret status without a server is unreachable (exit 10)" bash -c 'out="$(BAO_ADDR=http://127.0.0.1:1 dcf-secret status 2>/dev/null)"; rc=$?; [ "$rc" = 10 ] && [ "$out" = unreachable ]'
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "dcf-secret get without a server is exit 10 and prints nothing" bash -c 'out="$(BAO_ADDR=http://127.0.0.1:1 dcf-secret get ssh/x 2>/dev/null)"; rc=$?; [ "$rc" = 10 ] && [ -z "$out" ]'

reportResults
