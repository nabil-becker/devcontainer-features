#!/bin/bash
# Scenario 'non_root' (see scenarios.json): the Feature as the vscode user, as a real
# devcontainer runs it: the state volume handed over by the hook, the backs' runner and
# the tester working without root.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib
# shellcheck source=test/devhost/functional.sh
source "$(dirname "$0")/functional.sh"

# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root" bash -c '[ "$(id -u)" -ne 0 ]'
check "devhost-run-job on PATH" command -v devhost-run-job
check "DEVHOST_STATE points at the Feature's state dir" bash -c "[ \"\$DEVHOST_STATE\" = /var/lib/devcontainer-features/devhost ]"
check "setup makes the state dir usable for vscode" bash -c "devhost-setup | grep -Eq '^devhost: /var/lib/devcontainer-features/devhost \((volume|bind|image), writable\)\$' && [ -w /var/lib/devcontainer-features/devhost ]"
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/devhost.yml

devhost_functional

reportResults
