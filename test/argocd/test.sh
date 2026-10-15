#!/bin/bash
# Auto-generated scenario: the argocd Feature with default options
# (version=latest). Run with:
#   devcontainer features test -f argocd --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "argocd is on PATH" command -v argocd
check "argocd reports a version" bash -c "argocd version --client --short | grep -E '[0-9]+\.[0-9]+\.[0-9]+'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "binary is root-owned" bash -c '[ "$(stat -c %U "$(readlink -f "$(command -v argocd)")")" = root ]'

check "argocd-setup is on PATH" command -v argocd-setup
check "dcf-persist on PATH" command -v dcf-persist
# shellcheck disable=SC2016
check "ARGOCD_CONFIG_DIR points at the Feature's state dir" bash -c '[ "$ARGOCD_CONFIG_DIR" = /var/lib/devcontainer-features/argocd ]'
# The Feature's volume is mounted in `devcontainer features test` (volume);
# any backing is accepted so the check is not engine-specific.
# shellcheck disable=SC2016
check "argocd-setup reports the state dir as writable" bash -c 'cd "$(mktemp -d)" && argocd-setup | grep -Eq "^argocd: /var/lib/devcontainer-features/argocd \((volume|bind|image), writable\)$"'
check "argocd-setup reports the login state" bash -c 'argocd-setup | grep -Eq "^argocd-setup: (login present|no login yet)"'
# shellcheck disable=SC2016
check "state dir is writable by the current user" bash -c 'touch "$ARGOCD_CONFIG_DIR/.write-test" && rm -f "$ARGOCD_CONFIG_DIR/.write-test"'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/argocd.yml

reportResults
