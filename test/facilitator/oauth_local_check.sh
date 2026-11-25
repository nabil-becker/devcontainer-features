#!/usr/bin/env bash
# shellcheck disable=SC2015  # `cmd && ok "..." || no "..."`: ok and no always succeed, so no never runs after ok
# The automatable part of `task facilitator:oauth-local`, with no browser (task test:facilitator-oauth-local; needs Docker, the internal
# context; not part of lint): it starts Keycloak and the node as the task does, then does what Claude Code does at login against them:
# the 401 challenge and the metadata, dynamic client registration, authorization code + PKCE with the resource parameter (the Keycloak
# login form posted), the token (RS256 JWT, aud = <node>/mcp, scope facilitator:participate); then calls the node's MCP endpoint with it:
# the client enrolled and held, a person approves, the test agent answers, `verify` shows `via http (oauth, ...)`. It ends with `down`.
# What it cannot do is Claude Code's own browser login: NOTES, "Test it locally (Keycloak and Claude Code)".
# The bundle: FACILITATOR_BUNDLE (folder or .tar.gz), else dist/ (see oauth_local.sh).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tests="$root/test/facilitator"
export FACILITATOR_OAUTH_LOCAL_DIR="${FACILITATOR_OAUTH_LOCAL_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/fac-oauth-local-XXXXXX")}"
state="$FACILITATOR_OAUTH_LOCAL_DIR"
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() { bash "$tests/oauth-local/oauth_local.sh" down >/dev/null 2>&1 || true; }
trap cleanup EXIT
local_sh() { bash "$tests/oauth-local/oauth_local.sh" "$@"; }

local_sh up >"$state/up.log" 2>&1 && ok "up: Keycloak and the node answer" || { no "up"; tail -20 "$state/up.log"; exit 1; }
# the same python the node runs under
version="$(bash "$root/bundles/facilitator/install.sh" --version)"
bundle="${FACILITATOR_BUNDLE:-}"
if [ -z "$bundle" ] || [ ! -d "$bundle" ]; then bundle="$state/tree/facilitator"; fi
py="$bundle/python/bin/python3"
[ -x "$py" ] || { no "no bundle python ($version)"; exit 1; }
base="http://localhost:8765"
fx() { local_sh fx "$@"; }
jget() { "$py" -I -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}))" "$1"; }

"$py" -I "$tests/integration/oauth_local_drive.py" "$base" tester "$state/password" "$state/token" >"$state/drive.out" 2>&1 \
  && ok "login as Claude Code does it: challenge, metadata, dynamic registration, code + PKCE + resource, token ($(grep -c '"ok"' "$state/drive.out") steps)" \
  || { no "login"; cat "$state/drive.out"; exit 1; }
grep '"token:' "$state/drive.out" | grep -q '"alg": "RS256".*"aud": "http://localhost:8765/mcp".*"scope": "facilitator:participate"' && ok "the token: RS256, aud = the node's resource, scope facilitator:participate" || no "the token's claims"

c() { HTTP_CLIENT_VIA=OAuth "$py" -I "$tests/integration/http_client.py" "$base" "$(cat "$state/token")" "$@"; }
c hello >"$state/hello.out" 2>&1 && ok "the node accepts the token: who shows only the public agent, a hidden agent as unknown, the first message held" || { no "hello"; cat "$state/hello.out"; }
conv="$(grep conversation "$state/hello.out" | tail -1 | jget 'd["conversation"]')"
list="$(fx http list)"
handle="$(echo "$list" | awk '/: kc-/ && /OAuth, subject/ {print $2; exit}')"
[ -n "$handle" ] && echo "$list" | grep -q "kc-.*OAuth, subject .* of http://localhost:8080/realms/facilitator-test.*1 message(s) wait for approval" && ok "http list: the client is enrolled by Keycloak and its subject and waits ($handle)" || { no "http list"; echo "$list"; }
fx http approve "$handle" | grep -q delivered && ok "a person approves: the held message is delivered" || no "approve"
c converse "$conv" >"$state/conv.out" 2>&1 && ok "the test agent answered; receive, reply, transcript showing via OAuth" || { no "converse"; cat "$state/conv.out"; }
fx verify --conv "$conv" >"$state/verify.out" 2>&1 && grep -q "via http (oauth, client $handle, issuer http://localhost:8080/realms/facilitator-test, subject " "$state/verify.out" && ok "verify passes and shows via http (oauth, ...)" || { no "verify"; cat "$state/verify.out"; }
fx http audit | grep -q "the chain holds" && ok "the audit chain holds" || no "audit"
grep -qF "$(cat "$state/token")" "$state/node.log" && no "the token is in the node's log" || ok "the token is not in the node's log"

[ "$fail" = 0 ] && echo "facilitator oauth-local check: passed" || { echo "facilitator oauth-local check: FAILED"; exit 1; }
