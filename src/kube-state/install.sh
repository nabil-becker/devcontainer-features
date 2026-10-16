#!/usr/bin/env bash
# Adds the ecosystem pieces that make the kubeconfig part of this
# collection's state model: the dcf-persist helper, the post-create setup of
# the KUBECONFIG folder (kube-state-setup), and the Feature Taskfile. Feature
# options arrive as upper-cased environment variables (see
# devcontainer-feature.json): RESTRICTPERMISSIONS.
#
# This Feature installs no kubectl: it owns state, not a tool. The velero,
# kustomize, kubeconform and argocd Features each bring their own binary and
# read KUBECONFIG; kubectl itself comes from
# ghcr.io/devcontainers/features/kubectl-helm-minikube when wanted (ordered
# before this one by installsAfter). Nothing here fails without it.
#
# Never writes into /var/lib/devcontainer-features/kube-state: the volume is not
# mounted at image build; kube-state-setup makes it usable at post-create.
set -euo pipefail

RESTRICTPERMISSIONS="${RESTRICTPERMISSIONS:-true}"

if [ "$(id -u)" -ne 0 ]; then
  echo "kube-state: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

if command -v kubectl >/dev/null 2>&1; then
  echo "kube-state: kubectl found at $(command -v kubectl)"
else
  echo "kube-state: no kubectl in the image (fine: velero, kustomize, argocd read KUBECONFIG themselves; add ghcr.io/devcontainers/features/kubectl-helm-minikube:1 before this Feature for kubectl)"
fi

# ------------------------------------------------------- ecosystem pieces ----
# dcf-persist makes the state directory usable (verbatim copy of
# src/common/dcf-persist.sh); kube-state-setup is this Feature's postCreateCommand
# (see devcontainer-feature.json) and reads its option defaults from
# options.env, so the hook and `task kube-state:setup` behave the same.
feature_dir="$(cd "$(dirname "$0")" && pwd)"
share=/usr/local/share/kube-state-feature
mkdir -p "$share"
{
  echo "# Written by the kube-state Feature's install.sh from its options; sourced by kube-state-setup."
  printf 'RESTRICTPERMISSIONS=%q\n' "$RESTRICTPERMISSIONS"
} > "$share/options.env"
chmod 0644 "$share/options.env"
install -m 0755 "$feature_dir/kube-state-setup.sh" /usr/local/bin/kube-state-setup
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/kube-state.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
