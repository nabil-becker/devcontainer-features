#!/usr/bin/env bash
# What the rendered hub manifests must be, whatever the YAML looks like (kubeconform checks the schema; this checks the
# decisions): the hub's pod runs as uid 10001 with a read-only root, no capabilities and no privilege escalation, with none of
# hostNetwork, hostPID, hostPath or privileged; the Service exposes the SLIM listener (46358) and the join endpoint (46359)
# and nothing else; the image is the node image of this release, tagged by `images:` alone; mesh.yml in the ConfigMap is a
# hub with the built-in issuer (no openbao) or, in the ssh-agent overlay, the agent's. Run by `task bundle:k8s`.
# shellcheck disable=SC2015  # `A && ok || no` is the pattern of every flow script here
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$root/test/facilitator/k8s/tools.sh"
fac_tools kustomize
version="$(sed -n 's/^__version__ = "\([^"]*\)".*/\1/p' "$root/src/facilitator/facilitator/__init__.py")"
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
doc() { # <rendered> <kind>: the document of that kind
  awk -v k="$2" 'BEGIN{RS="\n---\n"} $0 ~ "(^|\n)kind: " k "(\n|$)" {print}' <<<"$1"
}
for o in base overlays/rancher-desktop overlays/ssh-agent; do
  r="$(kustomize build "$root/bundles/facilitator/k8s/$o")"
  sts="$(doc "$r" StatefulSet)"; svc="$(doc "$r" Service)"; cm="$(doc "$r" ConfigMap | grep -Ev '^\s*#')"
  n="$(grep -c 'runAsUser: 10001' <<<"$sts")"; [ "$n" = 1 ] && ok "$o: the pod runs as uid 10001" || no "$o: runAsUser 10001 ($n)"
  grep -q 'runAsNonRoot: true' <<<"$sts" && ok "$o: runAsNonRoot" || no "$o: runAsNonRoot"
  c="$(grep -c 'image: ' <<<"$sts")"
  [ "$(grep -c 'readOnlyRootFilesystem: true' <<<"$sts")" = "$c" ] && [ "$(grep -c 'allowPrivilegeEscalation: false' <<<"$sts")" = "$c" ] \
    && ok "$o: every container ($c) has a read-only root and no privilege escalation" || no "$o: container hardening"
  [ "$(grep -c -- '- ALL' <<<"$sts")" = "$c" ] && ok "$o: every container drops all capabilities" || no "$o: capabilities"
  if grep -Eq 'hostNetwork|hostPID|hostIPC|hostPath|privileged: true|hostPort' <<<"$sts"; then no "$o: a host namespace, path or port"; else ok "$o: no host network, PID, path, port or privileged"; fi
  ports="$(grep -E '^\s+port: ' <<<"$svc" | sed 's/.*port: //' | sort | tr '\n' ' ')"
  [ "$ports" = "46358 46359 " ] && ok "$o: the Service exposes 46358 (SLIM) and 46359 (join) only" || no "$o: Service ports '$ports'"
  grep -q "image: ghcr.io/nabil-becker/facilitator-node:$version\$" <<<"$sts" && ok "$o: the node image is tagged $version by images:" || no "$o: image tag"
  grep -q 'role: hub' <<<"$cm" && ok "$o: mesh.yml is a hub" || no "$o: mesh.yml role"
  if [ "$o" = overlays/ssh-agent ]; then
    grep -q 'ssh_agent:' <<<"$cm" && ! grep -q 'openbao:' <<<"$cm" && ok "$o: the issuer is the ssh-agent" || no "$o: issuer"
    grep -q 'name: ca-agent' <<<"$sts" && ok "$o: an agent container beside the hub" || no "$o: the agent container"
  else
    ! grep -Eq 'openbao:|ssh_agent:' <<<"$cm" && ok "$o: the issuer is the built-in CA (no openbao, no ssh_agent)" || no "$o: issuer"
  fi
done
exit "$fail"
