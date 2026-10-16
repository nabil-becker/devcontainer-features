#!/bin/bash
# Scenario 'unrestricted' (see scenarios.json): restrictPermissions=false,
# remoteUser=vscode. kube-state-setup leaves the kubeconfig mode alone.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "option baked" grep -q '^RESTRICTPERMISSIONS=false$' /usr/local/share/kube-state-feature/options.env
check "kubeconfig placeholder written 0644" bash -c "printf 'apiVersion: v1\nkind: Config\n' > \"\$KUBECONFIG\" && chmod 0644 \"\$KUBECONFIG\""
check "kube-state-setup reports permissions left alone" bash -c "kube-state-setup | grep -qF 'kubeconfig permissions left alone'"
check "mode untouched" bash -c "[ \"\$(stat -c %a \"\$KUBECONFIG\")\" = 644 ]"
check "env override turns it on without a rebuild" bash -c "KUBE_STATE_SETUP_RESTRICT_PERMISSIONS=true kube-state-setup | grep -qF 'is 0600' && [ \"\$(stat -c %a \"\$KUBECONFIG\")\" = 600 ]"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "runs as non-root user" bash -c '[ "$(id -u)" -ne 0 ] && test -w "$(dirname "$KUBECONFIG")"'

rm -f "$KUBECONFIG"
reportResults
