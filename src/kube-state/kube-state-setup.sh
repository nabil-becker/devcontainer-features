#!/usr/bin/env bash
# kube-state-setup: the kube-state Feature's postCreateCommand, run as the remote user
# from the workspace folder after every create/rebuild; also behind
# `task kube-state:setup`. Idempotent, never fatal: a problem is reported, not
# allowed to abort the rest of post-create.
#
# 1. dcf-persist makes the folder KUBECONFIG lives in (the Feature's named
#    volume, or a bind mount a repo put on the same target) exist and belong
#    to the remote user, so a kubeconfig imported once survives rebuilds.
# 2. With restrictPermissions (default true), an existing kubeconfig file is
#    set to 0600: it holds credentials.
# 3. Reports whether a kubeconfig is present and, when kubectl is there, its
#    current context name only (never a server address or a user) and the
#    next step when there is none.
set -u

# Defaults baked by install.sh from the Feature options. KUBE_STATE_SETUP_* in the
# environment (containerEnv) override them without a rebuild.
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f /usr/local/share/kube-state-feature/options.env ] && source /usr/local/share/kube-state-feature/options.env
restrict="${KUBE_STATE_SETUP_RESTRICT_PERMISSIONS-${RESTRICTPERMISSIONS:-true}}"

# KUBECONFIG may be a colon-separated list a repo set; the first entry is the
# file kubectl writes to, so that is the one this hook looks after.
file="${KUBECONFIG:-$HOME/.kube/config}"
file="${file%%:*}"
dir="$(dirname "$file")"

dcf-persist --label kube-state "$dir"

if [ ! -e "$file" ]; then
  echo "kube-state: no kubeconfig yet at $file; run 'task kube-state:import FILE=<path>' (or copy one there) once, it persists"
  exit 0
fi

if [ "$restrict" != "true" ]; then
  echo "kube-state: kubeconfig permissions left alone (restrictPermissions=false)"
elif chmod 0600 "$file" 2>/dev/null; then
  echo "kube-state: $file is 0600"
else
  echo "kube-state: could not chmod $file (is it writable?)" >&2
fi

if command -v kubectl >/dev/null 2>&1; then
  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if [ -n "$ctx" ]; then
    echo "kube-state: kubeconfig present, current context: $ctx"
  else
    echo "kube-state: kubeconfig present, no current context set (kubectl config use-context <name>)"
  fi
else
  echo "kube-state: kubeconfig present ($file); kubectl not on PATH, the other Kubernetes tools read KUBECONFIG themselves"
fi
exit 0
