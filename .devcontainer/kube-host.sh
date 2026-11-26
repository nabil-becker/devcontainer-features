#!/usr/bin/env bash
# The workstation's Kubernetes cluster (Rancher Desktop) for kubectl here (devhost-kubernetes, 2026-11-25).
# The Windows ~/.kube is mounted read-only at ~/.kube-host. At every start its rancher-desktop context
# (KUBE_HOST_CONTEXT) replaces the kube-state kubeconfig (KUBECONFIG), with every API server on 127.0.0.1 or localhost
# rewritten to host.docker.internal, which Rancher Desktop's API certificate names: from inside
# this container 127.0.0.1 is the container itself. The file holds cluster credentials and stays
# in the kube-state volume (mode 600), never in the checkout or the shared folder.
# Used by postStartCommand. Never fails the start.
set -uo pipefail

src="$HOME/.kube-host/config"
target="${KUBECONFIG%%:*}"
if [ ! -f "$src" ]; then
  echo "kube-host: no workstation kubeconfig at $src; kubectl has no cluster"
  exit 0
fi
if [ -z "$target" ] || ! command -v kubectl >/dev/null; then
  echo "kube-host: kubectl or KUBECONFIG missing; skipped"
  exit 0
fi

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
# Only Rancher Desktop's cluster (ruling 2026-11-25): no other context's credentials reach the devhost.
ctx_name="${KUBE_HOST_CONTEXT:-rancher-desktop}"
if ! KUBECONFIG="$src" kubectl config view --raw --flatten --minify --context "$ctx_name" > "$tmp.one" 2>/dev/null; then
  echo "kube-host: no context $ctx_name in $src; nothing imported"
  rm -f "$tmp.one"; exit 0
fi
sed -E 's#(server: https://)(127\.0\.0\.1|localhost)(:[0-9]+)#\1host.docker.internal\3#' "$tmp.one" > "$tmp"
rm -f "$tmp.one"
mkdir -p "$(dirname "$target")"
merged="$(mktemp)"
if KUBECONFIG="$tmp" kubectl config view --flatten --raw > "$merged" 2>/dev/null && [ -s "$merged" ]; then
  install -m 600 "$merged" "$target"
fi
rm -f "$merged"

ctx="$(kubectl config current-context 2>/dev/null)"
if [ -n "$ctx" ] && kubectl version --request-timeout=5s >/dev/null 2>&1; then
  echo "kube-host: kubectl reaches the cluster of context $ctx"
else
  echo "kube-host: kubeconfig imported (context ${ctx:-none}), but the API does not answer"
fi
exit 0
