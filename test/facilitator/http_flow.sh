#!/usr/bin/env bash
# shellcheck disable=SC2015  # `cmd && ok "..." || no "..."`: ok and no always succeed, so no never runs after ok
# Slice N4 end to end (task test:facilitator-http): the node's MCP endpoint over HTTP, from a built bundle, with real clients.
#
#   A node (the bundle's own python, the poll transport, keys in files, no Directory and no SLIM: nothing but the
#   endpoint, the record and the agent) on 127.0.0.1 with a mesh.yml (preset team; the agent jester exposed public,
#   domain-expert-one not) and `facilitator.http.listen`. Then, each client with a bearer token a person made:
#
#   leaf     a bare MCP client (the `mcp` library; proposal 11.1's fallback): the edge (401 no detail, 413, Origin, 404),
#            the tool list (never continue or approve), who showing only the public agent, a message to the hidden one
#            refused as unknown, a first message HELD, approved by a person (`facilitator http approve`), answered by the
#            agent, received, replied to; transcript and verify showing `via`; the public rate and the size refused;
#            a revoked token refused at once; the ten-failure back-off blocking an address.
#   claude   Claude Code, run for real (`claude -p --mcp-config`, a header with the token): who, say (held), approve, receive.
#   copilot  GitHub Copilot CLI, run for real (`copilot -p`, `copilot mcp add --transport http --header`): who, say (held).
#            Needs a copilot binary (COPILOT_BIN, or on PATH) and a GitHub token (GH_TOKEN, or `gh auth token`).
#
# claude and copilot are skipped, said aloud, when the binary or its login is missing (FACILITATOR_HTTP_CLIENTS=leaf runs
# only the leaf; =leaf,claude,copilot is the default). The bundle: FACILITATOR_BUNDLE (a folder holding bin/facilitator, or
# a facilitator-<version>-linux-<arch>.tar.gz), else dist/ of this checkout, else it is built (task bundle:build; slow:
# every upstream download). No Docker. Real tokens go only to files in this script's own throwaway folder, which is
# removed at the end; nothing is printed with a token in it.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tests="$root/test/facilitator"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fac-http-XXXXXX")"
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
  if [ -n "${FACILITATOR_HTTP_KEEP:-}" ]; then echo "kept $tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT

clients="${FACILITATOR_HTTP_CLIENTS:-leaf,claude,copilot}"
want() { case ",$clients," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

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
"$py" -I -c "import mcp, uvicorn" || { echo "the bundle has no mcp library"; exit 1; }

# ---------------------------------------------------------------- the endpoint's unit tests under the bundle's own python
"$py" -I "$tests/unit/test_http_endpoint.py" >"$tmp/unit.log" 2>&1 && ok "unit: test_http_endpoint.py under the bundle's python ($(grep -c '^ok' "$tmp/unit.log") tests)" || { no "unit: test_http_endpoint.py"; tail -20 "$tmp/unit.log"; }

# ---------------------------------------------------------------- the node
repo="$tmp/repo"; mkdir -p "$repo/.devcontainer"
port="$("$py" -I -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])")"
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
agent() { (cd "$repo" && exec "$py" -I "$tests/integration/http_agent.py" "$@" "$tree/lib"); }      # exec: the pid the cleanup kills
jget() { "$py" -I -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}))" "$1"; }
wait_for() { local n="$1"; shift; for _ in $(seq 1 "$n"); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 1; done; return 1; }

fx register --all --no-directory >/dev/null
ok "the node: register jester, domain-expert-one and you"
chk="$(fx check --json || true)"      # not ready as a whole: no Directory or SLIM in this test
echo "$chk" | jget '[p["detail"] for p in d if p["part"]=="http endpoint"][0]' | grep -q "127.0.0.1:$port" && ok "check names the endpoint" || no "check names the endpoint"
echo "$chk" | jget '[p["detail"] for p in d if p["part"]=="mcp"][0]' | grep -q "2.3.0" && ok "check names the mcp library" || no "check names the mcp library"

(cd "$repo" && exec "$py" -I "$tree/bin/facilitator" http serve) >"$tmp/serve.log" 2>&1 &
serve_pid=$!
wait_for 30 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" && ok "the endpoint is open on 127.0.0.1:$port (http serve)" || { no "the endpoint did not open"; tail -5 "$tmp/serve.log"; exit 1; }
base="http://127.0.0.1:$port"
ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "^0\.0\.0\.0:$port\$|^\[::\]:$port\$" && no "the endpoint listens beyond loopback" || ok "the endpoint listens on loopback only"

token() { fx http token "$1" 2>/dev/null | head -n1; }

# ---------------------------------------------------------------- the leaf client
if want leaf; then
  t="$(token leaf-client)"
  c() { "$py" -I "$tests/integration/http_client.py" "$base" "$t" "$@"; }
  c edge >"$tmp/leaf.edge" 2>&1 && ok "leaf: the edge and the tools offered ($(grep -c '"ok"' "$tmp/leaf.edge") checks)" || { no "leaf: edge"; cat "$tmp/leaf.edge"; }
  c hello >"$tmp/leaf.hello" 2>&1 && ok "leaf: who, a hidden agent as unknown, the first message held" || { no "leaf: hello"; cat "$tmp/leaf.hello"; }
  conv="$(grep conversation "$tmp/leaf.hello" | tail -1 | jget 'd["conversation"]')"
  fx http list | grep -q "1 message(s) wait for approval" && ok "a person sees the client wait (http list)" || no "http list shows the held message"
  fx mail --as you | grep -q "leaf-client waits for your approval" && ok "a person's mail names the client that waits" || no "mail names the waiting client"
  agent jester 40 "Why did the packet cross the network? To get to the other site." >"$tmp/agent.out" 2>&1 &
  bg_pids+=("$!")
  sleep 2
  fx http approve leaf-client | grep -q "delivered" && ok "a person approves: the held message is delivered" || no "approve"
  c converse "$conv" >"$tmp/leaf.conv" 2>&1 && ok "leaf: receive the answer, reply, transcript shows via, mail, another's conversation refused" || { no "leaf: converse"; cat "$tmp/leaf.conv"; }
  fx transcript --conv "$conv" | grep -q "(via HTTP, authenticated by bearer token, client leaf-client)" && ok "transcript (the command) shows via" || no "transcript via"
  fx verify --conv "$conv" >"$tmp/verify.out" 2>&1 && grep -q "via http (bearer, client leaf-client)" "$tmp/verify.out" && ok "verify passes and shows via" || { no "verify"; cat "$tmp/verify.out"; }
  fx status --json | jget 'all(set(c["members"]) <= {"jester","leaf-client"} for c in d["conversations"])' | grep -q True && ok "the client is in conversations with the public agent only" || no "only the public agent"
  c limits "$conv" >"$tmp/leaf.limits" 2>&1 && ok "leaf: max_packet and the public rate are refused" || { no "leaf: limits"; cat "$tmp/leaf.limits"; }
  fx http revoke leaf-client >/dev/null && c closed >"$tmp/leaf.closed" 2>&1 && ok "a revoked token is refused at once" || { no "revoke"; cat "$tmp/leaf.closed"; }
  # the back-off: ten wrong tokens, then even the right one is refused from this address (it is the only address)
  fx http token blocked-one >"$tmp/blocked.tok" 2>/dev/null
  for _ in $(seq 1 10); do "$py" -I -c "
import http.client,sys
c=http.client.HTTPConnection('127.0.0.1',$port); c.request('POST','/mcp',body=b'{}',headers={'Authorization':'Bearer nope.x','Content-Type':'application/json'}); c.getresponse().read()"; done
  code="$("$py" -I -c "
import http.client
c=http.client.HTTPConnection('127.0.0.1',$port); c.request('POST','/mcp',body=b'{}',headers={'Authorization':'Bearer '+open('$tmp/blocked.tok').read().strip(),'Content-Type':'application/json'}); print(c.getresponse().status)")"
  [ "$code" = 429 ] && ok "ten failed authentications block the address (429, even for the right token)" || no "back-off gave $code"
  # the address stays blocked for 10 minutes: restart the endpoint so the real clients below start clean
  kill "$serve_pid"; wait "$serve_pid" 2>/dev/null || true
  (cd "$repo" && exec "$py" -I "$tree/bin/facilitator" http serve) >>"$tmp/serve.log" 2>&1 &
  serve_pid=$!
  wait_for 30 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" && ok "the endpoint restarts (the back-off is in memory)" || no "restart"
fi

# ---------------------------------------------------------------- Claude Code, for real
if want claude; then
  if ! command -v claude >/dev/null 2>&1; then skip "claude: no claude binary on PATH"
  else
    t="$(token claude-code)"
    printf '{"mcpServers":{"facilitator":{"type":"http","url":"%s/mcp","headers":{"Authorization":"Bearer %s"}}}}\n' "$base" "$t" >"$tmp/claude-mcp.json"
    chmod 600 "$tmp/claude-mcp.json"
    agent jester 90 "Why did the packet cross the network? To get to the other site." >"$tmp/agent2.out" 2>&1 &
    bg_pids+=("$!")
    ( cd "$tmp" && timeout 240 claude -p --model "${FACILITATOR_HTTP_CLAUDE_MODEL:-haiku}" --mcp-config "$tmp/claude-mcp.json" --strict-mcp-config \
        --allowedTools "mcp__facilitator__who,mcp__facilitator__say,mcp__facilitator__receive" --output-format json \
        "Use the facilitator tools. 1) Call who. 2) Call say with the text '@jester tell me a joke from claude code'. 3) Call receive with wait_seconds 25 (call it once more if it says nothing yet). Report in one line what who listed, what say answered and what receive returned." \
        >"$tmp/claude.out" 2>"$tmp/claude.err" ) &
    cpid=$!
    if wait_for 120 bash -c "cd '$repo' && '$py' -I '$tree/bin/facilitator' http list | grep -q 'claude-code.*wait for approval'"; then
      ok "claude: its first message is held until a person approves"
      fx http approve claude-code >/dev/null && ok "claude: a person approves"
    else no "claude: nothing waited for approval"; fi
    wait "$cpid" || true
    "$py" -I -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('result','')); sys.exit(1 if d.get('is_error') else 0)" "$tmp/claude.out" >"$tmp/claude.result" 2>/dev/null \
      && ok "claude: ran to completion ($(tr '\n' ' ' <"$tmp/claude.result" | cut -c1-160))" || { no "claude: it did not complete"; head -c 600 "$tmp/claude.out" "$tmp/claude.err"; }
    grep -qi "jester" "$tmp/claude.result" && ok "claude: who listed the public agent" || no "claude: who"
    grep -qi "other site" "$tmp/claude.result" && ok "claude: receive returned the agent's answer" || no "claude: receive"
    cconv="$(fx status --json | jget '[c["conversation"] for c in d["conversations"] if "claude-code" in c["members"]][0]')"
    fx verify --conv "$cconv" | grep -q "via http (bearer, client claude-code)" && ok "claude: verify passes and shows via" || no "claude: verify"
    fx status --json | jget 'all(set(c["members"]) <= {"jester","claude-code","leaf-client"} for c in d["conversations"])' | grep -q True && ok "claude: only the public agent was reached" || no "claude: only the public agent"
  fi
fi

# ---------------------------------------------------------------- Copilot CLI, for real
if want copilot; then
  cop="${COPILOT_BIN:-$(command -v copilot 2>/dev/null || true)}"
  ghtok="${GH_TOKEN:-${COPILOT_GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}}"
  if [ -z "$cop" ]; then skip "copilot: no copilot binary (COPILOT_BIN, or on PATH); the leaf client above is the fallback (proposal 11.1)"
  elif [ -z "$ghtok" ]; then skip "copilot: no GitHub token for it (GH_TOKEN, or gh logged in); the leaf client above is the fallback"
  else
    t="$(token copilot-cli)"
    export COPILOT_HOME="$tmp/copilot-home"; mkdir -m 700 "$COPILOT_HOME"
    "$cop" mcp add --transport http facilitator "$base/mcp" --header "Authorization: Bearer $t" >/dev/null 2>&1 && ok "copilot: mcp add --transport http with the bearer header" || no "copilot: mcp add"
    ( cd "$tmp" && GH_TOKEN="$ghtok" timeout 240 "$cop" -p "Call the facilitator who tool, then the facilitator say tool with the text '@jester tell me a joke from copilot'. Report in one line what each returned." \
        --allow-tool facilitator --no-ask-user --silent >"$tmp/copilot.out" 2>&1 ) && ok "copilot: ran to completion" || { no "copilot: it did not complete"; head -c 600 "$tmp/copilot.out"; }
    grep -qi "jester" "$tmp/copilot.out" && ok "copilot: who listed the public agent" || no "copilot: who"
    grep -qi "held\|approv" "$tmp/copilot.out" && ok "copilot: its first message is held for approval" || no "copilot: held"
    fx http list | grep -q "copilot-cli.*wait for approval" && ok "copilot: a person sees it wait" || no "copilot: waiting"
    fx http approve copilot-cli | grep -q "approved" && ok "copilot: a person approves" || no "copilot: approve"
    cconv="$(fx status --json | jget '[c["conversation"] for c in d["conversations"] if "copilot-cli" in c["members"]][0]')"
    fx verify --conv "$cconv" | grep -q "via http (bearer, client copilot-cli)" && ok "copilot: verify passes and shows via" || no "copilot: verify"
  fi
fi

# ---------------------------------------------------------------- the record of every client
grep -q "enrolled\|approved\|revoked" "$FACILITATOR_HOME/http/audit.jsonl" && fx http audit | grep -q "the chain holds" && ok "the audit chain holds" || no "the audit chain"
grep -rq "leaf-client\.[A-Za-z0-9_-]\{20,\}" "$tmp/serve.log" "$FACILITATOR_HOME" 2>/dev/null && no "a token is in the node's logs or state" || ok "no token in the node's logs or state (only hashes)"
[ "$fail" = 0 ] && echo "facilitator http flow: passed" || { echo "facilitator http flow: FAILED"; exit 1; }
