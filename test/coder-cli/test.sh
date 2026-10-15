#!/bin/bash
# Auto-generated scenario: the coder-cli Feature with default options
# (version=latest). Run with:
#   devcontainer features test -f coder-cli --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "coder is on PATH" command -v coder
check "coder reports a version" bash -c "coder version | grep -E '[0-9]+\.[0-9]+\.[0-9]+'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "binary is root-owned" bash -c '[ "$(stat -c %U "$(readlink -f "$(command -v coder)")")" = root ]'

check "coder-cli-setup is on PATH" command -v coder-cli-setup
check "dcf-persist on PATH" command -v dcf-persist
# shellcheck disable=SC2016
check "CODER_CONFIG_DIR points at the Feature's state dir" bash -c '[ "$CODER_CONFIG_DIR" = /var/lib/devcontainer-features/coder-cli ]'
# The Feature's volume is mounted in `devcontainer features test` (volume);
# any backing is accepted so the check is not engine-specific.
# shellcheck disable=SC2016
check "coder-cli-setup reports the state dir as writable" bash -c 'cd "$(mktemp -d)" && coder-cli-setup | grep -Eq "^coder-cli: /var/lib/devcontainer-features/coder-cli \((volume|bind|image), writable\)$"'
check "coder-cli-setup reports the login state" bash -c 'coder-cli-setup | grep -Eq "^coder-cli-setup: (login present|no login yet)"'
# shellcheck disable=SC2016
check "state dir is writable by the current user" bash -c 'touch "$CODER_CONFIG_DIR/.write-test" && rm -f "$CODER_CONFIG_DIR/.write-test"'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/coder-cli.yml

reportResults
