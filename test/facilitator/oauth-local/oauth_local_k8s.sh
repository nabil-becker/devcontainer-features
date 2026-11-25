#!/usr/bin/env bash
# The OAuth test (N5b) on the workstation's Rancher Desktop Kubernetes: Keycloak, the facilitator hub with its HTTP endpoint and a
# public test agent, in the namespace facilitator-oauth-test (k8s/kustomization.yaml). Only the context rancher-desktop is ever used.
#
#   oauth_local_k8s.sh up      create the namespace and the admin secret, apply, wait, set the test user's password, print it (default)
#   oauth_local_k8s.sh down    delete the namespace (everything in it goes)
#   oauth_local_k8s.sh status  what runs, and the external addresses
#   oauth_local_k8s.sh fx ARGS the hub's own `facilitator` command (http list, http approve <handle>, verify --conv <id>)
#
# The image facilitator-node:<version>-local must be in the workstation's Docker (DOCKER_CONTEXT=host task bundle:image).
# The passwords are generated here, kept in the cluster (Secret keycloak-admin) and printed; nothing is written to this repository.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
ctx=rancher-desktop
ns=facilitator-oauth-test
k() { kubectl --context "$ctx" -n "$ns" "$@"; }
die() { echo "oauth-local-k8s: $*" >&2; exit 1; }

cmd="${1:-up}"; [ $# -gt 0 ] && shift || true
case "$cmd" in
fx) k exec statefulset/facilitator-hub -c hub -- facilitator "$@" ;;
status) k get pods,svc -o wide ;;
down) kubectl --context "$ctx" delete namespace "$ns" --wait=false; echo "oauth-local-k8s: namespace $ns is being deleted" ;;
up)
  kubectl --context "$ctx" get nodes >/dev/null || die "the context $ctx does not answer"
  kubectl --context "$ctx" get namespace "$ns" >/dev/null 2>&1 || kubectl --context "$ctx" create namespace "$ns" >/dev/null
  if ! k get secret keycloak-admin >/dev/null 2>&1; then
    admin_pw="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)"
    user_pw="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    k create secret generic keycloak-admin --from-literal=password="$admin_pw" --from-literal=user-password="$user_pw" >/dev/null
  fi
  kustomize build --load-restrictor LoadRestrictionsNone "$root/test/facilitator/oauth-local/k8s" | kubectl --context "$ctx" apply -f - >/dev/null
  k rollout status deployment/keycloak --timeout=300s
  k rollout status statefulset/facilitator-hub --timeout=300s
  admin_pw="$(k get secret keycloak-admin -o jsonpath='{.data.password}' | base64 -d)"
  user_pw="$(k get secret keycloak-admin -o jsonpath='{.data.user-password}' | base64 -d)"
  kc() { k exec deployment/keycloak -- /opt/keycloak/bin/kcadm.sh "$@"; }
  kc config credentials --server http://localhost:8080 --realm master --user admin --password "$admin_pw" >/dev/null
  kc set-password -r facilitator-test --username tester --new-password "$user_pw" >/dev/null
  echo "oauth-local-k8s: up. sign-in server http://localhost:8080/realms/facilitator-test  node http://localhost:8765/mcp"
  echo "oauth-local-k8s: test user: tester  password: $user_pw"
  ;;
*) die "unknown command '$cmd' (up, down, status, fx)" ;;
esac
