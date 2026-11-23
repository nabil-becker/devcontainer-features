#!/usr/bin/env bash
# The facilitator node image with the sample compose file (task test:facilitator-image). Needs the image
# facilitator-node:<version>-local (task bundle:build, then task bundle:image) and a Docker daemon with compose.
# Starts bundles/facilitator/compose.yml under a project of its own (a hub, a spoke and an OpenBao, sealed and
# uninitialised as after a first start), waits for the hub and the spoke to be healthy, then: the hub runs role hub
# from its mounted mesh.yml and, with its OpenBao sealed, has no certificate and opens nothing (fail closed: every
# listening port on loopback, and check says why); the spoke runs until it joins with nothing beyond loopback;
# neither runs as root; no port is published to the host; the bundle's MANIFEST.json; OpenBao answers the hub over
# the compose network. The joining itself is test/facilitator/mesh_flow.sh. Removes the containers, volumes and
# network it made, whatever happens. FACILITATOR_OPENBAO_IMAGE names another OpenBao image.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
version="$(bash "$root/bundles/facilitator/install.sh" --version)"
image="${FACILITATOR_NODE_IMAGE:-facilitator-node:$version-local}"
project="fac-node-test-$$"
compose=(docker compose -p "$project" -f "$root/bundles/facilitator/compose.yml")
export FACILITATOR_NODE_IMAGE="$image"
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() { "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker image inspect "$image" >/dev/null 2>&1 || { echo "no image $image: task bundle:build, then task bundle:image"; exit 1; }
"${compose[@]}" up -d --quiet-pull
for svc in hub spoke-a; do
  id="$("${compose[@]}" ps -q "$svc")"
  for _ in $(seq 1 90); do
    state="$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo gone)"
    [ "$state" = healthy ] && break
    [ "$state" = gone ] && break
    sleep 2
  done
  if [ "$state" = healthy ]; then ok "$svc is healthy (facilitator infra status)"; else
    no "$svc is $state"; "${compose[@]}" logs "$svc" | tail -30; exit 1
  fi
done
out="$("${compose[@]}" exec -T hub facilitator check || true)"
if echo "$out" | grep -q 'mesh .*ready .*preset team, role hub, node hub-1'; then ok "the hub runs role hub from its mounted mesh.yml"
else no "the hub's role"; fi
if echo "$out" | grep -q 'certificate .*NOT READY'; then ok "with its OpenBao sealed the hub has no certificate, and check says so: $(echo "$out" | grep certificate | sed 's/.*NOT READY *//')"
else no "check on the hub with OpenBao sealed"; fi
printf '%s\n' "$out" | while IFS= read -r line; do echo "     $line"; done
# Every listening TCP socket on 127.0.0.0/8 (/proc/net/tcp state 0A; the address is little-endian, so 127.x.y.z ends in
# 7F: 0100007F is 127.0.0.1, 0B00007F Docker's own resolver at 127.0.0.11). No tcp6 listener.
loopback_only() {
  local listening
  listening="$("${compose[@]}" exec -T "$1" sh -c 'cat /proc/net/tcp /proc/net/tcp6' | awk '$4 == "0A" { print $2 }')"
  [ -n "$listening" ] && ! echo "$listening" | grep -Eqv '^[0-9A-F]{6}7F:'
}
if loopback_only hub; then ok "every port of the hub on loopback while it has no certificate (it fails closed)"
else no "a port of the hub beyond loopback without a certificate"; fi
if loopback_only spoke-a; then ok "every port of the spoke on loopback (it has not joined; a spoke dials out)"
else no "a port of the spoke beyond loopback"; fi
spoke="$("${compose[@]}" exec -T spoke-a facilitator check || true)"
if echo "$spoke" | grep -q 'mesh .*none: solo, standalone'; then ok "the spoke runs standalone until it joins (no mesh.yml in its volume yet)"
else no "the spoke's mesh line"; fi
for svc in hub spoke-a; do
  if [ "$("${compose[@]}" exec -T "$svc" id -u)" != 0 ]; then ok "$svc runs as a non-root user"; else no "$svc runs as root"; fi
done
published="$(docker ps --filter "label=com.docker.compose.project=$project" --format '{{.Ports}}' | grep -- '->' || true)"
if [ -z "$published" ]; then ok "no port is published to the host"; else no "published: $published"; fi
manifest="$("${compose[@]}" exec -T hub cat /opt/facilitator/MANIFEST.json)"
if echo "$manifest" | grep -q "\"version\": \"$version\""; then ok "the bundle $version (MANIFEST.json)"; else no "MANIFEST.json"; fi
code="$("${compose[@]}" exec -T hub /opt/facilitator/python/bin/python3 -I -c '
import urllib.request, urllib.error
try:
    print(urllib.request.urlopen("http://openbao:8200/v1/sys/health", timeout=10).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:
    print("unreachable", e)
')"
case "$code" in
  200 | 429 | 472 | 473 | 501 | 503) ok "OpenBao answers the hub over the compose network (sys/health $code)" ;;
  *) no "OpenBao from the hub: $code" ;;
esac
exit "$fail"
