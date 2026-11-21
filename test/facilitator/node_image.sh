#!/usr/bin/env bash
# The facilitator node image with the sample compose file (task test:facilitator-image). Needs the image
# facilitator-node:<version>-local (task bundle:build, then task bundle:image) and a Docker daemon with compose.
# Starts bundles/facilitator/compose.yml under a project of its own, waits for the hub to be healthy, then:
# facilitator check green in the hub, the hub's user is not root, every listening port of the hub on loopback,
# the bundle's MANIFEST.json, and OpenBao answering the hub over the compose network (sealed and uninitialised:
# HTTP 501). Removes the containers, volumes and network it made, whatever happens.
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
hub="$("${compose[@]}" ps -q hub)"
for _ in $(seq 1 90); do
  state="$(docker inspect -f '{{.State.Health.Status}}' "$hub" 2>/dev/null || echo gone)"
  [ "$state" = healthy ] && break
  [ "$state" = gone ] && break
  sleep 2
done
if [ "$state" = healthy ]; then ok "the hub is healthy (facilitator infra status)"; else
  no "the hub is $state"; "${compose[@]}" logs hub | tail -30; exit 1
fi
if out="$("${compose[@]}" exec -T hub facilitator check)"; then ok "facilitator check is green"; else no "facilitator check"; fi
printf '%s\n' "$out" | while IFS= read -r line; do echo "     $line"; done
if [ "$("${compose[@]}" exec -T hub id -u)" != 0 ]; then ok "the hub runs as a non-root user"; else no "the hub runs as root"; fi
# Every listening TCP socket of the hub on 127.0.0.0/8 (/proc/net/tcp state 0A; the address is little-endian, so
# 127.x.y.z ends in 7F: 0100007F is 127.0.0.1, 0B00007F Docker's own resolver at 127.0.0.11). No tcp6 listener.
listening="$("${compose[@]}" exec -T hub sh -c 'cat /proc/net/tcp /proc/net/tcp6' | awk '$4 == "0A" { print $2 }')"
if [ -n "$listening" ] && ! echo "$listening" | grep -Eqv '^[0-9A-F]{6}7F:'; then ok "every port of the hub on loopback"
else no "a port of the hub beyond loopback: $listening"; fi
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
