#!/bin/bash
# Global scenario 'all_features': every Feature in this collection installed
# into one image, as the vscode user, plus the go-task Feature-Taskfile
# registry wired together.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "task" task --version
check "claude" claude --version
check "devcontainer" devcontainer --version
check "coder" coder version
check "bao" bao version
check "velero" velero version --client-only
check "kustomize" kustomize version
check "kubeconform" kubeconform -v
check "argocd" argocd version --client --short
check "dsc" dsc --version
check "dsc resources discoverable" bash -c "dsc resource list | grep -q Microsoft"
check "node not leaked onto PATH" bash -c "! command -v node"

registry=/usr/local/share/go-task/features.yml
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "registry lists every Feature" bash -c 'for f in go-task claude-code devcontainer-cli coder-cli openbao velero kustomize kubeconform argocd dsc; do grep -q "^  $f:" /usr/local/share/go-task/features.yml || { echo "missing $f"; exit 1; }; done'
check "feature tasks resolve through the registry" bash -c "task -t $registry --list-all | grep -c -E 'dsc:get|velero:backups|kustomize:build:all|argocd:apps|openbao:status|coder-cli:workspaces|claude-code:version|devcontainer-cli:version|kubeconform:validate:kustomize|go-task:registered' | grep -qx 10"
check "feature task runs" task -t "$registry" dsc:version
check "registered list task" bash -c "task -t $registry go-task:registered | grep -qx dsc"

reportResults
