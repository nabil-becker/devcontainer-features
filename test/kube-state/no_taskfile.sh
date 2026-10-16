#!/bin/bash
# Scenario 'no_taskfile' (see scenarios.json): installTaskfile=false,
# remoteUser=vscode. The Feature's Taskfile is not registered.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "taskfile absent" bash -c "! test -e /usr/local/share/go-task/includes.d/kube-state.yml"
check "kube-state-setup still installed" command -v kube-state-setup
check "KUBECONFIG set" bash -c "[ \"\$KUBECONFIG\" = /var/lib/devcontainer-features/kube-state/config ]"

reportResults
