#!/bin/bash
# Scenario 'with_kubectl' (see scenarios.json): the official
# ghcr.io/devcontainers/features/kubectl-helm-minikube installs kubectl
# first, this Feature owns the kubeconfig; remoteUser=vscode.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "kubectl is on PATH" command -v kubectl
check "KUBECONFIG set" bash -c "[ \"\$KUBECONFIG\" = /var/lib/devcontainer-features/kube-state/config ]"
check "kube-state-setup reports the state dir" bash -c "kube-state-setup | grep -E '^kube-state: /var/lib/devcontainer-features/kube-state \((volume|bind|image), writable\)$'"
check "no kubeconfig yet is reported" bash -c "rm -f \"\$KUBECONFIG\"; kube-state-setup | grep -F 'kube-state: no kubeconfig yet'"

# A throwaway kubeconfig (no real cluster, no credentials) written by the user.
cat > /tmp/kube-state-test-src.yaml <<'YAML'
apiVersion: v1
kind: Config
current-context: demo
clusters:
  - name: demo
    cluster:
      server: https://127.0.0.1:6443
users:
  - name: demo
    user:
      token: not-a-real-token
contexts:
  - name: demo
    context:
      cluster: demo
      user: demo
YAML
check "kube-state:import works through the Taskfile" bash -c "task -t /usr/local/share/go-task/includes.d/kube-state.yml import FILE=/tmp/kube-state-test-src.yaml | grep -F 'kube-state: merged'"
check "kubeconfig lives in the state dir" test -s /var/lib/devcontainer-features/kube-state/config
check "kubeconfig is 0600" bash -c "[ \"\$(stat -c %a /var/lib/devcontainer-features/kube-state/config)\" = 600 ]"
check "kubectl reads it" bash -c "[ \"\$(kubectl config current-context)\" = demo ]"
check "kube-state-setup reports the context" bash -c "kube-state-setup | grep -F 'kube-state: kubeconfig present, current context: demo'"
check "kube-state-setup repairs permissions" bash -c "chmod 0644 \"\$KUBECONFIG\"; kube-state-setup >/dev/null; [ \"\$(stat -c %a \"\$KUBECONFIG\")\" = 600 ]"
check "kube-state-setup never prints the server or token" bash -c "! kube-state-setup | grep -E '127.0.0.1|not-a-real-token'"
check "kube-state:use switches context" bash -c "task -t /usr/local/share/go-task/includes.d/kube-state.yml use CONTEXT=demo | grep -F 'demo'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "kubectl runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && kubectl version --client >/dev/null'
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/kube-state.yml

rm -f /tmp/kube-state-test-src.yaml
reportResults
