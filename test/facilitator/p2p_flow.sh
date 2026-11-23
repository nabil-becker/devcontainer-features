#!/usr/bin/env bash
# Slice N5a end to end (task test:facilitator-p2p): three peers with no hub and a public node, every node the node image
# facilitator-node:<version>-local (task bundle:build, then task bundle:image), on one internal Docker network. No OpenBao: a
# peer is the issuer of its own domain with a CA it keeps.
#
#   node-a, node-b, node-c  role peer, each its own domain (a|b|c.mesh.test); paired by tokens (a-b, a-c, b-c); node-a also
#                           issues the public domain open.test (certificates of 60 s here, 1 h by default) with a separate
#                           public SLIM listener and join endpoint
#   pub-1                   a public node: a spoke of open.test after a person approves its key
#
# Then: a1 (node-a), b1 (node-b) and c1 (node-c) talk with no hub and verify passes; the public node is shown only the agent
# exposed public, a conversation with it carries only what is addressed to it (a message to another member is refused at the
# write, the public node holds no other conversation), first contact holds its message until a person approves, an agent not
# marked public is unreachable and unlisted; revoke: the public node's certificate is not renewed and expires within the
# (shortened) lifetime; the mesh secret rotated on the nodes that remain, which keep talking; the audit register verifies (and
# the N4 log is replayed into it). FACILITATOR_TEST_SOURCE=1 mounts this checkout's application over the image's. Removes
# every container, volume and network it made, whatever happens.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
version="$(bash "$root/bundles/facilitator/install.sh" --version)"
image="${FACILITATOR_NODE_IMAGE:-facilitator-node:$version-local}"
p="fac-p2p-$$"
net="$p"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fac-p2p-XXXXXX")"
ttl="${FACILITATOR_TEST_PUBLIC_TTL:-120s}"
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
nodes=(a b c pub)
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() {
  local rc=$?
  if [ "$rc" != 0 ]; then
    for n in "${nodes[@]}"; do
      if [ "$(docker inspect -f '{{.State.Running}}' "$p-$n" 2>/dev/null)" = false ]; then echo "node $n exited:"; docker logs "$p-$n" 2>&1 | tail -15; fi
    done
  fi
  for n in "${nodes[@]}"; do docker rm -fv "$p-$n" >/dev/null 2>&1 || true; docker volume rm "$p-$n" >/dev/null 2>&1 || true; done
  docker network rm "$net" >/dev/null 2>&1 || true
  docker run --rm -v "$tmp:/t" --entrypoint /bin/sh -u 0 "$image" -c 'rm -rf /t/* /t/.[!.]*' >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
docker image inspect "$image" >/dev/null 2>&1 || { echo "no image $image: task bundle:build, then task bundle:image"; exit 1; }
docker network create --internal "$net" >/dev/null

fx() { local n="$1"; shift; docker exec "$p-$n" facilitator "$@"; }
agent() { local n="$1"; shift; docker exec "$p-$n" /opt/facilitator/python/bin/python3 -I /test/mesh_agent.py "$@"; }
jget() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}))" "$1"; }
wait_for() { local n="$1"; shift; for _ in $(seq 1 "$n"); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 1; done; return 1; }
sh_in() { local n="$1"; shift; docker exec "$p-$n" "$@"; }
st=/var/lib/devcontainer-features/facilitator

for n in a b c pub; do mkdir -p "$tmp/$n"; done
cat >"$tmp/a/mesh.yml" <<YAML
preset: open
role: peer
node:
  id: node-a
  name: a.mesh.test
  domain: a.mesh.test
  listen:
    private: 0.0.0.0:46358
    public: 0.0.0.0:46360
  join: 0.0.0.0:46359
  public:
    domain: open.test
    join: 0.0.0.0:46361
trust:
  a.mesh.test: private
  open.test: public
expose:
  "*": local
  a1: private
  pa: public
  j1: public
  j2: public
limits:
  public:
    svid_ttl: $ttl
YAML
for n in b c; do
  cat >"$tmp/$n/mesh.yml" <<YAML
preset: team
role: peer
node:
  id: node-$n
  name: $n.mesh.test
  domain: $n.mesh.test
  listen:
    private: 0.0.0.0:46358
  join: 0.0.0.0:46359
trust:
  $n.mesh.test: private
expose:
  "*": local
  ${n}1: private
  p$n: private
YAML
done
cat >"$tmp/pub/mesh.yml" <<'YAML'
preset: open
node:
  id: pub-1
expose:
  "*": local
  p1: public
  p2: local
  pp: public
YAML
part() { # <file> <agents...>
  local f="$1"; shift
  printf 'participants:\n' >"$f"
  for x in "$@"; do printf '  - name: %s\n    cli: claude\n    kind: resident\n    attachment: mcp\n    description: agent %s\n' "$x" "$x" >>"$f"; done
}
part "$tmp/a/participants.yml" a1 j1 j2
part "$tmp/b/participants.yml" b1
part "$tmp/c/participants.yml" c1
part "$tmp/pub/participants.yml" p1 p2
printf 'facilitator:\n  humans: [pa]\n' >"$tmp/a/facilitator.yml"
printf 'facilitator:\n  humans: [pb]\n' >"$tmp/b/facilitator.yml"
printf 'facilitator:\n  humans: [pc]\n' >"$tmp/c/facilitator.yml"
printf 'facilitator:\n  humans: [pp]\n' >"$tmp/pub/facilitator.yml"
chmod -R a+rwX "$tmp"
dev=()
[ -n "${FACILITATOR_TEST_SOURCE:-}" ] && dev=(-v "$root/src/facilitator/facilitator:/opt/facilitator/lib/facilitator:ro" \
  -v "$root/src/facilitator/types.d:/opt/facilitator/lib/types.d:ro")
start() { # <node> <alias>
  docker run -d --name "$p-$1" --hostname "$2" --network "$net" --network-alias "$2" \
    -e FACILITATOR_MESH_FILE=/etc/facilitator/mesh.yml -v "$p-$1:$st" -v "$tmp/$1:/etc/facilitator:rw" \
    -v "$root/test/facilitator/integration:/test:ro" "${dev[@]}" --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges:true "$image" >/dev/null
}
start a a.mesh.test; start b b.mesh.test; start c c.mesh.test; start pub pub.mesh.test

# ---------------------------------------------------------------- each peer holds its own certificate (its own CA)
for n in a b c; do
  if wait_for 90 sh -c "docker exec $p-$n facilitator check | grep -q 'certificate *ready'"; then ok "node-$n issued its own certificate in $n.mesh.test (a CA it keeps, no OpenBao)"
  else no "node-$n's certificate"; docker logs "$p-$n" 2>&1 | tail -15; exit 1; fi
done
for n in a b c pub; do fx "$n" register --all --no-directory >/dev/null; done

# ---------------------------------------------------------------- pairing: a-b, a-c, b-c (three nodes, no hub)
pair() { # <accepter> <requester>
  local tok
  tok="$(docker exec "$p-$1" facilitator node invite 2>/dev/null)"
  wait_for 60 docker exec "$p-$2" bash -c "exec 3<>/dev/tcp/$1.mesh.test/46359" || true
  local out
  for _ in 1 2 3 4 5 6; do   # the join endpoint may be reopening after the accepter's own restart (a pairing re-executes its peers part)
    if out="$(fx "$2" node peer --token "$tok" 2>&1)"; then echo "$out"; return 0; fi
    case "$out" in *"not reachable"*) sleep 5 ;; *) echo "$out"; return 1 ;; esac
  done
  echo "$out"; return 1
}
for pr in "a b" "a c" "b c"; do
  # shellcheck disable=SC2086  # the pair's two names
  set -- $pr
  if out="$(pair "$1" "$2")"; then ok "node-$2 paired with node-$1: ${out#facilitator: }"; else no "pairing $2 to $1: $out"; fi
done
if grep -q 'node-b: incoming' "$tmp/a/mesh.yml" && grep -q 'node-a: a.mesh.test:46358' "$tmp/b/mesh.yml"; then ok "mesh.yml: the accepter lists the peer as incoming, the requester dials it"
else no "peers in mesh.yml: $(cat "$tmp/a/mesh.yml")"; fi
sa="$(sh_in a cat $st/mesh/secret)"
if [ "$sa" = "$(sh_in b cat $st/mesh/secret)" ] && [ "$sa" = "$(sh_in c cat $st/mesh/secret)" ]; then ok "the mesh secret was handed over: one secret on the three nodes"
else no "the mesh secrets differ"; fi
docker restart "$p-a" "$p-b" "$p-c" >/dev/null
seen() { docker exec "$p-$1" /opt/facilitator/python/bin/python3 -I /test/mesh_agent.py who | grep -q "\"handle\": \"$2\""; }
if wait_for 150 seen a b1 && wait_for 60 seen a c1 && wait_for 60 seen b c1 && wait_for 60 seen c a1 && wait_for 60 seen c b1 && wait_for 60 seen b a1 && wait_for 60 seen a b1; then ok "each node lists the others' exposed agents (cards by hello, no hub)"
else no "the peers do not see each other"; for n in a b c; do fx "$n" check || true; docker logs "$p-$n" 2>&1 | tail -8; done; fi

if [ -n "${P2P_PAUSE:-}" ]; then echo "paused: $p"; sleep "${P2P_PAUSE}"; fi
# ---------------------------------------------------------------- a conversation across the three, verify
conv="$(agent a open pa a1 b1 c1 -- "@b1 and @c1 hello from a, no hub")" || true
convid="$(echo "$conv" | jget 'd["conversation"]')"
r1="$(agent b answer b1 60 "b1 here")"; r2="$(agent c answer c1 60 "c1 here")"
if echo "$r1" | grep -q 'hello from a' && echo "$r2" | grep -q 'hello from a'; then ok "b1 and c1 each received a1's message in $convid, node to node, with no hub"
else no "the three-node conversation: $r1 / $r2"; fi
for n in a b c; do
  wait_for 60 fx "$n" verify --conv "$convid" || true
  if out="$(fx "$n" verify --conv "$convid" 2>&1)"; then ok "verify on node-$n: ${out##*: }"; else no "verify on node-$n: $out"; fi
done

# ---------------------------------------------------------------- the public node: a key, then a person's approval
info="$(fx a node invite --level public 2>/dev/null)"
docker exec -i "$p-pub" sh -c 'cat >/tmp/info.json' <<<"$info"
wait_for 15 docker exec "$p-pub" bash -c 'exec 3<>/dev/tcp/a.mesh.test/46361' || true
if out="$(fx pub node request /tmp/info.json 2>&1)"; then ok "pub-1 sent its key: ${out#facilitator: }"; else no "node request: $out"; fi
rid="$(fx a node requests --json | jget 'd[0]["id"]')"
if [[ "$(fx pub node collect 2>&1 || true)" == *"is pending"* ]]; then ok "nothing is issued before a person acts (collect says pending)"; else no "collect before the approval"; fi
if [[ "$(docker exec -e CLAUDECODE=1 "$p-a" facilitator node approve "$rid" --yes 2>&1 || true)" == *"agent's job"* ]]; then ok "node approve is refused inside an agent's job"; else no "approve in an agent's job"; fi
if out="$(fx a node approve "$rid" --yes --as pa 2>&1)"; then ok "a person approved: ${out#facilitator: }"; else no "approve: $out"; fi
if out="$(fx pub node collect 2>&1)"; then ok "pub-1 collected: ${out#facilitator: }"; else no "collect: $out"; fi
docker restart "$p-pub" >/dev/null
if wait_for 120 seen pub j1; then ok "the public node is shown j1, which node-a exposes public"; else no "pub does not see j1"; fx pub check || true; docker logs "$p-pub" 2>&1 | tail -10
  if [ -n "${P2P_PAUSE_PUB:-}" ]; then echo "paused: $p"; sleep "$P2P_PAUSE_PUB"; fi; fi
for h in a1 b1 c1 j2x; do
  if seen pub "$h"; then no "the public node lists $h"; fi
done
ok "the public node lists none of a1, b1, c1 (not marked public): unlisted"
out="$(agent pub open pp a1.node-a -- "hello" 2>&1 || true)"
case "$out" in *"not registered"*|*"no participant"*|*error*) ok "a1 (not public) is unreachable from the public node: $(echo "$out" | jget 'd.get("error","")' | cut -c1-90)" ;;
  *) no "a1 reachable from pub: $out" ;; esac

# first contact, then a conversation that carries only what is addressed
pc="$(agent pub open pp j1.node-a -- "@j1.node-a hello from the public node")"
pconv="$(echo "$pc" | jget 'd["conversation"]')"
wait_for 60 sh_in a test -d "$st/conversations/$pconv" || true     # replicated to node-a, where it waits for approval
if ! agent a answer j1 5 "should not arrive" | grep -q '"received": {'; then ok "first contact: pp's message waits (j1 receives nothing) until a person approves"; else no "j1 received before approval"; fi
if fx a http approve pp.pub-1 --as pa 2>&1 | grep -q approved; then ok "a person approved pp.pub-1 at first contact"; else no "first-contact approval"; fi
r="$(agent a answer j1 60 "hello public node, j1 here")"
if echo "$r" | grep -q 'hello from the public node'; then ok "after the approval j1 received it and answered"; else no "j1 after approval: $r"; fi
mailed() { agent pub mail pp | grep -q 'j1 here'; }
if wait_for 40 mailed; then ok "the answer reached pp on the public node (replicated: copy addressed)"; else no "pp did not get the answer"; agent pub mail pp | cut -c1-600; fx pub transcript --conv "$pconv" | cut -c1-200 | tail -12
  fx a transcript --conv "$pconv" | cut -c1-200 | tail -12; { sh_in a tail -3 "$st/mesh/refused.log"; sh_in pub tail -3 "$st/mesh/refused.log"; } 2>&1 | cut -c1-300 || true
  if [ -n "${P2P_PAUSE_MAIL:-}" ]; then echo "paused: $p"; sleep "$P2P_PAUSE_MAIL"; fi; fi
for n in a pub; do
  if out="$(fx "$n" verify --conv "$pconv" 2>&1)"; then ok "verify on $n: ${out##*: }"; else no "verify on $n: $out"; fi
done
if [ "$(sh_in pub ls "$st/conversations")" = "$pconv" ]; then ok "the public node holds exactly one conversation: the one it is a member of ($pconv); not $convid"
else no "the public node's conversations: $(sh_in pub ls "$st/conversations")"; fi
gc="$(agent a open pa j1 j2 pp.pub-1 -- "@pp.pub-1 a group with the public node")" || true
gid="$(echo "$gc" | jget 'd["conversation"]')"
out="$(agent a say pa "$gid" "@j2 a word only for j2" 2>&1 || true)"
case "$out" in *"copy addressed"*) ok "a message to another member of a conversation with the public node is refused at the write: $(echo "$out" | jget 'd["error"]' | cut -c1-80)" ;;
  *) no "the write rule: $out" ;; esac

# ---------------------------------------------------------------- revoke: cut off within the lifetime; the secret rotates
old="$(sh_in a cat $st/mesh/secret)"
if out="$(fx a node revoke pub-1 --yes --as pa 2>&1)"; then ok "node-a revoked pub-1: ${out#facilitator: }"; else no "revoke: $out"; fi
# the secret each node's SLIM app was actually made with (the peers part writes its hash into status.json when it connects)
used() { docker exec "$p-$1" sh -c "python3 -c \"import json; print(json.load(open('$st/mesh/status.json')).get('secret_sha',''))\"" 2>/dev/null \
  || docker exec "$p-$1" /opt/facilitator/python/bin/python3 -I -c "import json; print(json.load(open('$st/mesh/status.json')).get('secret_sha',''))"; }
sha() { printf '%s' "$1" | sha256sum | cut -c1-16; }
oldsha="$(sha "$old")"
same() { local n; n="$(sha "$(docker exec "$p-a" cat $st/mesh/secret)")"
  [ "$n" != "$oldsha" ] && [ "$(used a)" = "$n" ] && [ "$(used b)" = "$n" ] && [ "$(used c)" = "$n" ] \
  && [ "$(docker exec "$p-b" cat $st/mesh/secret)" = "$(docker exec "$p-a" cat $st/mesh/secret)" ] \
  && [ "$(docker exec "$p-c" cat $st/mesh/secret)" = "$(docker exec "$p-a" cat $st/mesh/secret)" ]; }
if wait_for 240 same; then ok "the mesh secret rotated: node-a, node-b and node-c hold one new secret and each node's SLIM app was made with it (status.json secret_sha)"
else no "the secret did not rotate on the three nodes (old $oldsha; a $(used a), b $(used b), c $(used c))"; fx a check | grep rotation || true
  if [ -n "${P2P_PAUSE_ROT:-}" ]; then echo "paused: $p"; sleep "$P2P_PAUSE_ROT"; fi; fi
if [ "$(used pub)" = "$oldsha" ]; then ok "the revoked node still runs on the old secret, so it cannot form a SLIM session with the three"; else no "pub's secret_sha $(used pub) is not the old one $oldsha"; fi
for n in a b c; do wait_for 90 sh -c "docker exec $p-$n facilitator infra status | grep -q 'peers *healthy'" || true; done
c2="$(agent b open pb b1 c1 -- "@c1 are you still there after the rotation")" || true
c2id="$(echo "$c2" | jget 'd["conversation"]')"
if agent c answer c1 90 "yes, c1 on the new secret" | grep -q 'after the rotation'; then ok "the remaining nodes keep talking on the new secret (b1 to c1)"; else no "b1 to c1 after the rotation"; fi
wait_for 60 fx b verify --conv "$c2id" || true
if fx b verify --conv "$c2id" >/dev/null; then ok "verify passes on the conversation made after the rotation"; else no "verify after the rotation"; fi
secs="$(python3 -I -c "import sys; v=sys.argv[1]; print(int(v[:-1])*{'s':1,'m':60,'h':3600}[v[-1]])" "$ttl")"
if wait_for $((secs + 90)) sh -c "docker exec $p-pub facilitator check | grep -q 'certificate *NOT READY.*EXPIRED'"; then ok "the revoked node's certificate expired within its lifetime ($ttl; 1 h by default) and was not renewed"
else no "pub's certificate did not expire"; fx pub check | grep -i cert || true; fi
if ! docker exec "$p-pub" openssl x509 -checkend 0 -noout -in "$st/mesh/certs/open.test/node.pem" >/dev/null 2>&1; then
  ok "the revoked node's certificate is past its notAfter: the listener's chain check refuses it at the next handshake"
else no "the certificate is still valid"; fi

# ---------------------------------------------------------------- the audit register
docker exec "$p-a" /opt/facilitator/python/bin/python3 -I -c "
import sys; sys.path.insert(0, '/opt/facilitator/lib')
from facilitator import settings
from facilitator.app import Facilitator
f = Facilitator(settings.load()); f.clients.sink = None
f.clients.create('cli-one', 'pa'); f.clients.approve('cli-one', 'pa'); f.clients.revoke('cli-one', 'pa')" 2>&1 | tail -2 || true
if [[ "$(fx a audit verify 2>&1 || true)" == *"DOES NOT VERIFY"* ]]; then ok "audit verify shows the three lines of the N4 log not yet in the register"; else no "audit verify before the replay"; fi
if fx a audit replay | grep -q '3 line(s)'; then ok "audit replay put the N4 log's lines into the signed register"; else no "audit replay"; fi
if out="$(fx a audit verify 2>&1)"; then ok "the audit register verifies: ${out#facilitator: }"; else no "audit verify: $out"; fi
ev="$(fx a audit show)"
for w in join-requested join-approved node-revoked secret-rotated; do
  case "$ev" in *"$w"*) ok "the audit register holds $w" ;; *) no "the audit register lacks $w" ;; esac
done
if [ "$fail" = 0 ]; then echo "p2p flow: all checks passed"; else echo "p2p flow: FAILED"; exit 1; fi
