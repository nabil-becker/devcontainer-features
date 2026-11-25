#!/usr/bin/env bash
# shellcheck disable=SC2015  # `cmd && ok "..." || no "..."`: ok and no always succeed, so no never runs after ok
# Slice N5b end to end (task test:facilitator-oauth): the node as an OAuth resource server, from a built bundle, with an
# MCP client that holds an OAuth access token, as a cloud AI would.
#
#   A node (the bundle's own python, the poll transport, keys in files; nothing but the endpoint, the record and the
#   agent) on 127.0.0.1 with facilitator.http.url and two issuers: `corp`, a local test issuer this script starts (an RSA
#   key made on the spot, its JWKS and discovery document on loopback; test/facilitator/integration/oauth_issuer.py), and
#   `ghost`, whose address nothing answers (a JWKS that cannot be read). Then:
#
#   edge      no token: 401 with resource_metadata; the RFC 9728 metadata naming the node and both issuers; a token of
#             another audience, expired, from another issuer, alg none: 401 invalid_token; the wrong scope: 403
#             insufficient_scope; a token of the unreadable issuer: 503 (closed, and the node's log says why)
#   leaf      a bare MCP client (the `mcp` library) with an OAuth token for the subject alice: who showing only the public
#             agent, a hidden agent as unknown, the first message HELD, a person sees the client wait (http list names
#             issuer and subject; mail), approves, the agent answers, receive, reply, transcript and verify show `via`
#             (oauth, issuer, subject), the public rate and size refused, another subject another client, a bearer token
#             working beside, a revoked OAuth client refused at once
#   check     `check` names the issuers and fetches nothing; `http issuers` fetches (corp readable, ghost NOT READABLE)
#
# A real cloud AI (a claude.ai custom connector) cannot run here: NOTES, "Connect a cloud AI", says how a person connects one
# and what to look for. The bundle: FACILITATOR_BUNDLE (a folder holding bin/facilitator, or a facilitator-<version>-linux-<arch>.tar.gz),
# else dist/ of this checkout, else it is built (slow). No Docker. Tokens go only to files in this script's own throwaway
# folder, removed at the end; they are throwaway tokens of a throwaway key.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tests="$root/test/facilitator"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fac-oauth-XXXXXX")"
chmod 700 "$tmp"
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
skip() { echo "skip $1"; }
serve_pid=""
bg_pids=()
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() {
  for p in "${bg_pids[@]}" $serve_pid; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [ -n "${FACILITATOR_OAUTH_KEEP:-}" ]; then echo "kept $tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- the bundle
version="$(bash "$root/bundles/facilitator/install.sh" --version)"
arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
tree=""
src="${FACILITATOR_BUNDLE:-}"
[ -n "$src" ] || { [ -f "$root/dist/facilitator-$version-linux-$arch.tar.gz" ] && src="$root/dist/facilitator-$version-linux-$arch.tar.gz"; }
if [ -z "$src" ]; then
  echo "no bundle: building facilitator-$version-linux-$arch (every upstream download; slow)"
  bash "$root/bundles/facilitator/install.sh" --arch "$arch" --out "$tmp/dist" >"$tmp/build.log" 2>&1 || { tail -5 "$tmp/build.log"; exit 1; }
  src="$tmp/dist/facilitator-$version-linux-$arch.tar.gz"
fi
if [ -d "$src" ]; then tree="$src"; else mkdir -p "$tmp/tree" && tar -xzf "$src" -C "$tmp/tree" && tree="$tmp/tree/facilitator"; fi
py="$tree/python/bin/python3"
[ -x "$py" ] || { echo "no python in the bundle $tree"; exit 1; }
"$py" -I -c "import mcp, uvicorn, jwt, cryptography" || { echo "the bundle lacks mcp, jwt or cryptography"; exit 1; }

# ---------------------------------------------------------------- the unit tests under the bundle's own python
for t in test_oauth.py test_http_endpoint.py; do
  "$py" -I "$tests/unit/$t" >"$tmp/unit.log" 2>&1 && ok "unit: $t under the bundle's python ($(grep -c '^ok' "$tmp/unit.log") tests)" || { no "unit: $t"; tail -20 "$tmp/unit.log"; }
done

# ---------------------------------------------------------------- the issuer and the node
free_port() { "$py" -I -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])"; }
port="$(free_port)"; iport="$(free_port)"; gport="$(free_port)"
issuer() { "$py" -I "$tests/integration/oauth_issuer.py" "$@"; }
mint() { issuer mint "$iport" "$tmp/issuer" "$@"; }
issuer serve "$iport" "$tmp/issuer" >"$tmp/issuer.log" 2>&1 &
bg_pids+=("$!")
for _ in $(seq 1 30); do [ -f "$tmp/issuer/ready" ] && break; sleep 0.5; done
[ -f "$tmp/issuer/ready" ] && ok "the test issuer is up on 127.0.0.1:$iport" || { no "the test issuer did not start"; cat "$tmp/issuer.log"; exit 1; }
base="http://127.0.0.1:$port"
resource="$base/mcp"
issuer_url="http://127.0.0.1:$iport"
ghost_url="http://127.0.0.1:$gport"

repo="$tmp/repo"; mkdir -p "$repo/.devcontainer"
cat >"$repo/.devcontainer/participants.yml" <<'EOF'
participants:
  - name: jester
    cli: openai-compatible
    kind: resident
    description: tells jokes
  - name: domain-expert-one
    cli: claude
    kind: resident
EOF
cat >"$repo/.devcontainer/facilitator.yml" <<EOF
facilitator:
  humans: [you]
  http:
    listen: 127.0.0.1:$port
    url: $base
    issuers:
      - name: corp
        issuer: $issuer_url
      - name: ghost
        issuer: $ghost_url
EOF
cat >"$repo/.devcontainer/mesh.yml" <<'EOF'
preset: team
expose:
  jester: public
  "*": local
limits:
  public:
    http_receive_wait: 25s
EOF
export FACILITATOR_HOME="$tmp/home" FACILITATOR_KEYS=file FACILITATOR_TRANSPORT=poll FACILITATOR_DIRCTL=/nonexistent FACILITATOR_SLIMCTL=/nonexistent
unset CLAUDECODE DEVHOST_JOB_CHILD FACILITATOR_HANDLE FACILITATOR_TOKEN
fx() { (cd "$repo" && "$py" -I "$tree/bin/facilitator" "$@"); }
agent() { (cd "$repo" && exec "$py" -I "$tests/integration/http_agent.py" "$@" "$tree/lib"); }
jget() { "$py" -I -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}))" "$1"; }
wait_for() { local n="$1"; shift; for _ in $(seq 1 "$n"); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 1; done; return 1; }
status_of() { "$py" -I -c "
import http.client
c=http.client.HTTPConnection('127.0.0.1',$port); c.request('POST','/mcp',body=b'{}',headers={'Authorization':'Bearer '+open('$1').read().strip(),'Content-Type':'application/json'}); r=c.getresponse(); r.read(); print(r.status)"; }

fx register --all --no-directory >/dev/null
ok "the node: register jester, domain-expert-one and you"

# check names the issuers and fetches nothing: the ghost's address answers nothing, and the check does not wait for it
t0=$SECONDS
chk="$(fx check --json || true)"
echo "$chk" | jget '[p["detail"] for p in d if p["part"]=="http oauth"][0]' | grep -q "corp ($issuer_url), ghost ($ghost_url); resource $resource" && ok "check names the issuers, the resource and the metadata" || no "check names the issuers"
[ $((SECONDS - t0)) -lt 15 ] && ok "check fetched nothing (it did not wait for the unreadable issuer)" || no "check was slow: it fetched"
if fx http issuers >"$tmp/issuers.out" 2>&1; then no "http issuers should fail on the unreadable issuer"
elif grep -q "corp .*ok: JWKS" "$tmp/issuers.out" && grep -q "ghost .*NOT READABLE" "$tmp/issuers.out"; then ok "http issuers fetches: corp readable, ghost NOT READABLE"
else no "http issuers output"; cat "$tmp/issuers.out"; fi

(cd "$repo" && exec "$py" -I "$tree/bin/facilitator" http serve) >"$tmp/serve.log" 2>&1 &
serve_pid=$!
wait_for 30 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" && ok "the endpoint is open on 127.0.0.1:$port" || { no "the endpoint did not open"; tail -5 "$tmp/serve.log"; exit 1; }

# ---------------------------------------------------------------- the edge
mint "$resource" alice >"$tmp/t.good"
mint "https://elsewhere.example/mcp" alice >"$tmp/t.wrongaud"
mint "$resource" alice --exp -3600 >"$tmp/t.expired"
mint "$resource" alice --iss "https://stranger.example" >"$tmp/t.wrongiss"
mint "$resource" alice --scope "read" >"$tmp/t.wrongscope"
mint "$resource" alice --alg none >"$tmp/t.none"
mint "$resource" alice --iss "$ghost_url" >"$tmp/t.ghost"
"$py" -I "$tests/integration/oauth_edge.py" "$base" "$issuer_url,$ghost_url" "401=$tmp/t.wrongaud" "401=$tmp/t.expired" "401=$tmp/t.wrongiss" "401=$tmp/t.none" "403=$tmp/t.wrongscope" >"$tmp/edge.out" 2>&1 \
  && ok "edge: the challenge, the metadata, and 401 and 403 for each refused token ($(grep -c '"ok"' "$tmp/edge.out") checks)" || { no "edge"; cat "$tmp/edge.out"; }
code="$(status_of "$tmp/t.ghost")"
[ "$code" = 503 ] && ok "edge: a token of an issuer whose keys cannot be read: 503 (closed)" || no "ghost gave $code"
grep -q "issuer ghost: .*cannot be read" "$tmp/serve.log" && ok "the node's log says why (the ghost's keys cannot be read)" || { no "the log does not say why"; tail -3 "$tmp/serve.log"; }

# ---------------------------------------------------------------- the leaf client with an OAuth token
c() { HTTP_CLIENT_VIA=OAuth "$py" -I "$tests/integration/http_client.py" "$base" "$(cat "$tmp/t.good")" "$@"; }
c hello >"$tmp/leaf.hello" 2>&1 && ok "oauth: who (the public agent only), a hidden agent as unknown, the first message held" || { no "oauth: hello"; cat "$tmp/leaf.hello"; }
conv="$(grep conversation "$tmp/leaf.hello" | tail -1 | jget 'd["conversation"]')"
fx http list | grep -q "corp-alice .*OAuth, subject alice of $issuer_url.*1 message(s) wait for approval" && ok "a person sees the client wait (http list names issuer and subject)" || { no "http list"; fx http list; }
fx mail --as you | grep -q "corp-alice waits for your approval" && ok "a person's mail names the client that waits" || no "mail names the waiting client"
agent jester 40 "Why did the packet cross the network? To get to the other site." >"$tmp/agent.out" 2>&1 &
bg_pids+=("$!")
sleep 2
fx http approve corp-alice | grep -q "delivered" && ok "a person approves: the held message is delivered" || no "approve"
c converse "$conv" >"$tmp/leaf.conv" 2>&1 && ok "oauth: receive the answer, reply, transcript shows via OAuth, mail, another's conversation refused" || { no "oauth: converse"; cat "$tmp/leaf.conv"; }
fx transcript --conv "$conv" | grep -q "(via HTTP, authenticated by OAuth, client corp-alice, issuer $issuer_url, subject alice)" && ok "transcript (the command) shows via with issuer and subject" || no "transcript via"
fx verify --conv "$conv" >"$tmp/verify.out" 2>&1 && grep -q "via http (oauth, client corp-alice, issuer $issuer_url, subject alice)" "$tmp/verify.out" && ok "verify passes and shows via (oauth, issuer, subject)" || { no "verify"; cat "$tmp/verify.out"; }
fx status --json | jget 'all(set(c["members"]) <= {"jester","corp-alice"} for c in d["conversations"])' | grep -q True && ok "the OAuth client is in conversations with the public agent only" || no "only the public agent"
c limits "$conv" >"$tmp/leaf.limits" 2>&1 && ok "oauth: max_packet and the public rate are refused" || { no "oauth: limits"; cat "$tmp/leaf.limits"; }

# another subject is another client, held on its own; a bearer client works beside OAuth
mint "$resource" bob --client-id claude-web >"$tmp/t.bob"
if HTTP_CLIENT_VIA=OAuth "$py" -I "$tests/integration/http_client.py" "$base" "$(cat "$tmp/t.bob")" hello >"$tmp/bob.hello" 2>&1 && fx http list | grep -q "corp-bob .*enrolled.*wait for approval"; then
  ok "another subject is another client, held on its own"
else no "bob"; cat "$tmp/bob.hello"; fi
btok="$(fx http token bearer-one 2>/dev/null | head -n1)"
"$py" -I "$tests/integration/http_client.py" "$base" "$btok" hello >"$tmp/bearer.hello" 2>&1 && ok "a bearer client works beside OAuth (who, held)" || { no "bearer beside"; cat "$tmp/bearer.hello"; }

# ---------------------------------------------------------------- revoke
fx http revoke corp-alice >/dev/null && c closed >"$tmp/leaf.closed" 2>&1 && ok "a revoked OAuth client is refused at once" || { no "revoke"; cat "$tmp/leaf.closed"; }
mint "$resource" alice >"$tmp/t.again"
code="$(status_of "$tmp/t.again")"
[ "$code" = 401 ] && ok "a new token of the revoked subject does not bring the client back" || no "revoked subject gave $code"

# ---------------------------------------------------------------- the record
fx http audit >"$tmp/audit.out" 2>&1 && grep -q "the chain holds" "$tmp/audit.out" && grep -q "enrolled .*corp-alice by oauth: corp" "$tmp/audit.out" && ok "the audit chain holds and shows the OAuth enrolment" || { no "the audit chain"; cat "$tmp/audit.out"; }
leak=0
for f in "$tmp"/t.*; do
  grep -rqF "$(cat "$f")" "$tmp/serve.log" "$FACILITATOR_HOME" 2>/dev/null && { no "a token is in the node's logs or state ($(basename "$f"))"; leak=1; }
done
[ "$leak" = 0 ] && ok "no OAuth token is in the node's logs or state"
skip "a real cloud AI (a claude.ai custom connector) cannot run here: run it once by hand (NOTES, 'Connect a cloud AI')"
[ "$fail" = 0 ] && echo "facilitator oauth flow: passed" || { echo "facilitator oauth flow: FAILED"; exit 1; }
