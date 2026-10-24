#!/bin/bash
# Global scenario 'all_features': every Feature in this collection installed
# into one image, as the vscode user, plus the go-task Feature-Taskfile
# registry wired together and the state volumes the Features declare.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "task" task --version
check "claude" claude --version
check "claude-host" command -v claude-host
check "devcontainer" devcontainer --version
check "coder" coder version
check "bao" bao version
check "velero" velero version --client-only
check "kustomize" kustomize version
check "kubeconform" kubeconform -v
check "argocd" argocd version --client --short
check "dsc" dsc --version
check "dsc resources discoverable" bash -c "dsc resource list | grep -q Microsoft"
check "git wrapper" bash -c "[ \"\$(command -v git)\" = /usr/local/bin/git ] && git --version"
check "gh" gh --version
check "ssh-agent-setup" command -v ssh-agent-setup
check "ssh-add" command -v ssh-add
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "SSH_AUTH_SOCK is the Feature's fixed path" bash -c '[ "$SSH_AUTH_SOCK" = /var/lib/devcontainer-features/ssh-agent/agent.sock ]'
check "az" bash -c "az version -o tsv | cut -f1 | grep -E '^[0-9]'"
check "kube-state-setup" command -v kube-state-setup
check "dcf-persist" command -v dcf-persist
check "node not leaked onto PATH" bash -c "! command -v node"

# Every state-owning Feature points its tool at its own mounted directory,
# and the post-create hooks (run by `devcontainer up` before this script)
# have made them usable by the remote user.
for v in CLAUDE_CONFIG_DIR GH_CONFIG_DIR AZURE_CONFIG_DIR KUBECONFIG GIT_CONFIG_GLOBAL CODER_CONFIG_DIR ARGOCD_CONFIG_DIR; do
  check "$v points under /var/lib/devcontainer-features" bash -c "case \"\$$v\" in /var/lib/devcontainer-features/*) ;; *) exit 1 ;; esac"
done
check "claude-code state dir writable" test -w "$CLAUDE_CONFIG_DIR"
check "gh state dir writable" test -w "$GH_CONFIG_DIR"
check "az state dir writable" test -w "$AZURE_CONFIG_DIR"
check "kube state dir writable" test -w "$(dirname "$KUBECONFIG")"
check "git global config dir writable" test -w "$(dirname "$GIT_CONFIG_GLOBAL")"
check "coder state dir writable" test -w "$CODER_CONFIG_DIR"
check "argocd state dir writable" test -w "$ARGOCD_CONFIG_DIR"
check "ssh-agent socket folder writable" test -w /var/lib/devcontainer-features/ssh-agent
check "ssh-agent key volume present" test -d /var/lib/devcontainer-features/ssh-agent-key

registry=/usr/local/share/go-task/features.yml
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "registry lists every Feature" bash -c 'for f in common go-task claude-code devcontainer-cli coder-cli openbao velero kustomize kubeconform argocd dsc git gh ssh-agent az kube-state; do grep -q "^  $f:" /usr/local/share/go-task/features.yml || { echo "missing $f"; exit 1; }; done'
check "feature tasks resolve through the registry" bash -c "task -t $registry --list-all | grep -c -E 'dsc:get|velero:backups|kustomize:build:all|argocd:apps|openbao:status|coder-cli:workspaces|claude-code:host|devcontainer-cli:version|kubeconform:validate:kustomize|go-task:registered|git:setup|gh:status|ssh-agent:check|az:account|kube-state:contexts|common:persist' | grep -qx 16"
check "feature task runs" task -t "$registry" dsc:version
check "registered list task" bash -c "task -t $registry go-task:registered | grep -qx dsc"

# A consuming repository whose root Taskfile includes the registry flattened.
# Feature tasks must run where task was started (dir: USER_WORKING_DIR), not
# in /usr/local/share/go-task/includes.d: git:setup there reported "no
# repository" and added that folder to safe.directory in the shared volume.
repo="$(mktemp -d)"
git -C "$repo" init -q
printf "version: '3'\nincludes:\n  features:\n    taskfile: %s\n    flatten: true\n" "$registry" > "$repo/Taskfile.yml"
check "git:worktrees runs in the consuming repo" bash -c "cd '$repo' && task git:worktrees | grep -F '$repo'"
check "git:setup runs in the consuming repo" bash -c "cd '$repo' && task git:setup | grep -F 'workspace $repo: ok'"
check "git:setup trusts only the repo" bash -c "git config --global --get-all safe.directory | grep -qxF '$repo' && ! git config --global --get-all safe.directory | grep -F /usr/local/share"

reportResults
