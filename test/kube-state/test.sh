#!/bin/bash
# Auto-generated scenario: the kube-state Feature alone with default options on the
# base image. There is no kubectl here by design (this Feature installs none;
# its install.sh says so instead of failing), so this checks only the pieces.
# The 'with_kubectl' scenario covers the real thing with the official Feature.
# Run with:
#   devcontainer features test -f kube-state --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "kubectl present or absent is reported" bash -c "command -v kubectl || echo 'kubectl absent (expected without the kubectl-helm-minikube Feature)'"
check "KUBECONFIG set" bash -c "[ \"\$KUBECONFIG\" = /var/lib/devcontainer-features/kube-state/config ]"
check "dcf-persist on PATH" command -v dcf-persist
check "kube-state-setup on PATH" command -v kube-state-setup
check "options baked for kube-state-setup" grep -q '^RESTRICTPERMISSIONS=true$' /usr/local/share/kube-state-feature/options.env
check "kube-state-setup reports the state dir" bash -c "kube-state-setup | grep -E '^kube-state: /var/lib/devcontainer-features/kube-state \((volume|bind|image), writable\)$'"
check "kube-state-setup says what to do without a kubeconfig" bash -c "rm -f \"\$KUBECONFIG\"; kube-state-setup | grep -F 'kube-state: no kubeconfig yet'"
check "kube-state-setup exits 0 without kubectl" bash -c "kube-state-setup >/dev/null 2>&1"
check "state dir writable by the user" test -w /var/lib/devcontainer-features/kube-state
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/kube-state.yml

reportResults
