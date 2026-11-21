#!/usr/bin/env bash
# Slice N3 end to end (task test:facilitator-mesh): an OpenBao, a hub and two spokes on one internal Docker network,
# every node the node image facilitator-node:<version>-local (task bundle:build, then task bundle:image).
#
#   OpenBao: initialised and unsealed by this script (the Operator's part, by hand in real use); a PKI for corp.test
#     whose intermediate is signed by a root that stays outside (openssl here), a role for node certificates (ed25519,
#     URI spiffe://corp.test/*, 24 h), a KV for the roster's backup, and an AppRole for the hub.
#   hub-1 (role hub): its certificate from the PKI; a private listener whose bundle holds corp.test and partner.test.
#   spoke-a, spoke-b (role spoke): join with a single-use token from `facilitator node invite`, restart, link to the hub.
#
# Then: spoke A's agent a1 mentions spoke B's agent b1 through the hub and b1 answers; verify passes on both
# spokes; a private caller does not see A's local-only agent; a used token, a certificate from an untrusted CA
# (lock one) and the spike's impostor (a partner.test certificate claiming corp.test: lock two) are refused; the
# hub restarts and the spokes reconnect; a spoke that goes away gets its held message when it comes back; check
# names a TLS refusal from the SLIM log; a revoked spoke is refused, by the hub and by the other spoke, and gets no
# renewal. Removes every container, volume and network it made, whatever happens.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
version="$(bash "$root/bundles/facilitator/install.sh" --version)"
image="${FACILITATOR_NODE_IMAGE:-facilitator-node:$version-local}"
openbao="${FACILITATOR_TEST_OPENBAO:-quay.io/openbao/openbao:2.7.2@sha256:5046911075e137e154ce49ab051502f4ec7cf367d484ae4a4dce665d9b90561f}"
p="fac-mesh-$$"
net="$p"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fac-mesh-XXXXXX")"
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
nodes=(openbao hub spoke-a spoke-b probe)
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() {
  for n in "${nodes[@]}"; do docker rm -fv "$p-$n" >/dev/null 2>&1 || true; done
  for n in hub spoke-a spoke-b; do docker volume rm "$p-$n" >/dev/null 2>&1 || true; done
  docker network rm "$net" >/dev/null 2>&1 || true
  # files the containers wrote are the container user's: removed from a container of the same image
  docker run --rm -v "$tmp:/t" --entrypoint /bin/sh -u 0 "$image" -c 'rm -rf /t/* /t/.[!.]*' >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

docker image inspect "$image" >/dev/null 2>&1 || { echo "no image $image: task bundle:build, then task bundle:image"; exit 1; }
docker image inspect "$openbao" >/dev/null 2>&1 || docker pull -q "$openbao" >/dev/null
docker network create --internal "$net" >/dev/null

bao() { docker exec -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="${root_token:-}" "$p-openbao" bao "$@"; }
fx() { local n="$1"; shift; docker exec "$p-$n" facilitator "$@"; }
agent() { local n="$1"; shift; docker exec "$p-$n" /opt/facilitator/python/bin/python3 -I /test/mesh_agent.py "$@"; }
jget() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}))" "$1"; }
wait_for() { # <seconds> <command...>: until the command succeeds
  local n="$1"; shift
  for _ in $(seq 1 "$n"); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 1; done
  return 1
}

# ---------------------------------------------------------------- OpenBao and the corp.test PKI (the Operator's part)
mkdir -p "$tmp/openbao" "$tmp/root"
cat >"$tmp/openbao/hub.hcl" <<'EOF'
storage "raft" {
  path    = "/openbao/file"
  node_id = "test-openbao"
}
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}
api_addr     = "http://openbao:8200"
cluster_addr = "http://openbao:8201"
ui           = false
EOF
chmod -R a+rX "$tmp/openbao"
docker run -d --name "$p-openbao" --network "$net" --network-alias openbao -v "$tmp/openbao:/etc/openbao-test:ro" \
  "$openbao" server -config=/etc/openbao-test/hub.hcl >/dev/null
wait_for 30 sh -c "docker exec $p-openbao bao status -address=http://127.0.0.1:8200 >/dev/null 2>&1; [ \$? -ne 1 ]" || true
init="$(bao operator init -key-shares=1 -key-threshold=1 -format=json)"
unseal="$(echo "$init" | jget 'd["unseal_keys_b64"][0]')"
root_token="$(echo "$init" | jget 'd["root_token"]')"
bao operator unseal "$unseal" >/dev/null
# the root CA stays outside OpenBao (ruling AB): openssl here, a key no container holds
openssl genpkey -algorithm ed25519 -out "$tmp/root/root.key" 2>/dev/null
openssl req -x509 -new -key "$tmp/root/root.key" -subj "/O=corp.test/CN=corp.test root" -days 30 -out "$tmp/root/root.pem" \
  -addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
bao secrets enable -path=pki-corp pki >/dev/null
bao secrets tune -max-lease-ttl=720h pki-corp >/dev/null
bao write -format=json pki-corp/intermediate/generate/internal common_name="corp.test intermediate" key_type=ed25519 \
  | jget 'd["data"]["csr"]' >"$tmp/root/int.csr"
printf 'basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' >"$tmp/root/int.ext"
openssl x509 -req -in "$tmp/root/int.csr" -CA "$tmp/root/root.pem" -CAkey "$tmp/root/root.key" -days 20 \
  -extfile "$tmp/root/int.ext" -set_serial "0x$(openssl rand -hex 8)" -out "$tmp/root/int.pem" 2>/dev/null
cat "$tmp/root/int.pem" "$tmp/root/root.pem" >"$tmp/root/int-root.pem"
docker cp "$tmp/root/int-root.pem" "$p-openbao:/tmp/int-root.pem"
bao write pki-corp/intermediate/set-signed certificate=@/tmp/int-root.pem >/dev/null
bao write pki-corp/roles/node allowed_domains=corp.test allow_subdomains=true allow_bare_domains=true \
  allowed_uri_sans='spiffe://corp.test/*' key_type=ed25519 ttl=24h max_ttl=24h require_cn=false server_flag=true \
  client_flag=true key_usage=DigitalSignature ext_key_usage=ServerAuth,ClientAuth use_csr_common_name=false \
  use_csr_sans=false >/dev/null
bao secrets enable -path=secret -version=2 kv >/dev/null
docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN="$root_token" "$p-openbao" bao policy write facilitator-hub - >/dev/null <<'EOF'
path "pki-corp/sign/node" { capabilities = ["create", "update"] }
path "pki-corp/revoke" { capabilities = ["create", "update"] }
path "secret/data/facilitator/mesh/*" { capabilities = ["create", "update", "read"] }
EOF
bao auth enable approle >/dev/null
bao write auth/approle/role/facilitator-hub token_policies=facilitator-hub token_ttl=1h >/dev/null
role_id="$(bao read -format=json auth/approle/role/facilitator-hub/role-id | jget 'd["data"]["role_id"]')"
secret_id="$(bao write -f -format=json auth/approle/role/facilitator-hub/secret-id | jget 'd["data"]["secret_id"]')"
ok "OpenBao initialised and unsealed; pki-corp's intermediate signed by a root outside it; an AppRole for the hub"

# ---------------------------------------------------------------- partner.test: another private domain's CA, and the impostor
openssl genpkey -algorithm ed25519 -out "$tmp/root/partner.key" 2>/dev/null
openssl req -x509 -new -key "$tmp/root/partner.key" -subj "/CN=partner.test CA" -days 30 -out "$tmp/root/partner.pem" \
  -addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign" 2>/dev/null
leaf() { # <ca name> <out name> <uri> <dns>
  openssl genpkey -algorithm ed25519 -out "$tmp/root/$2.key" 2>/dev/null
  openssl req -new -key "$tmp/root/$2.key" -subj "/CN=$4" -out "$tmp/root/$2.csr" 2>/dev/null
  printf 'basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:%s,URI:%s\n' "$4" "$3" >"$tmp/root/$2.ext"
  openssl x509 -req -in "$tmp/root/$2.csr" -CA "$tmp/root/$1.pem" -CAkey "$tmp/root/$1.key" -days 1 \
    -extfile "$tmp/root/$2.ext" -set_serial "0x$(openssl rand -hex 8)" -out "$tmp/root/$2.pem" 2>/dev/null
}
leaf partner impostor spiffe://corp.test/node/spoke-a impostor.partner.test     # the spike's impostor
openssl genpkey -algorithm ed25519 -out "$tmp/root/stranger-ca.key" 2>/dev/null
openssl req -x509 -new -key "$tmp/root/stranger-ca.key" -subj "/CN=stranger CA" -days 30 -out "$tmp/root/stranger-ca.pem" \
  -addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign" 2>/dev/null
leaf stranger-ca stranger spiffe://corp.test/node/spoke-x stranger.corp.test       # a CA no listener trusts

# ---------------------------------------------------------------- the nodes' configuration
for n in hub spoke-a spoke-b; do mkdir -p "$tmp/$n"; done
cat >"$tmp/hub/mesh.yml" <<'EOF'
preset: team
role: hub
node:
  id: hub-1
  name: hub.corp.test
  listen:
    private: 0.0.0.0:46358
  join: 0.0.0.0:46359
  issuer:
    domain: corp.test
    openbao: http://openbao:8200
    mount: pki-corp
    role: node
    kv: secret
    approle: /etc/facilitator/approle
trust:
  corp.test: private
  partner.test: private
EOF
printf 'role_id=%s\nsecret_id=%s\n' "$role_id" "$secret_id" >"$tmp/hub/approle"
cp "$tmp/root/partner.pem" "$tmp/hub/partner.pem"
printf 'participants: []\n' >"$tmp/hub/participants.yml"
printf 'facilitator:\n  humans: []\n' >"$tmp/hub/facilitator.yml"
cat >"$tmp/spoke-a/mesh.yml" <<'EOF'
preset: team
role: spoke
node:
  id: spoke-a
expose:
  "*": local
  pa: private
  a1: private
EOF
cat >"$tmp/spoke-a/participants.yml" <<'EOF'
participants:
  - name: a1
    cli: claude
    kind: resident
    attachment: mcp
    description: spoke A's agent
  - name: a2
    cli: claude
    kind: resident
    attachment: mcp
    description: spoke A's local-only agent
EOF
printf 'facilitator:\n  humans: [pa]\n' >"$tmp/spoke-a/facilitator.yml"
cat >"$tmp/spoke-b/mesh.yml" <<'EOF'
preset: team
role: spoke
node:
  id: spoke-b
expose:
  "*": local
  b1: private
  pb: private
EOF
cat >"$tmp/spoke-b/participants.yml" <<'EOF'
participants:
  - name: b1
    cli: claude
    kind: resident
    attachment: mcp
    description: spoke B's agent
EOF
printf 'facilitator:\n  humans: [pb]\n' >"$tmp/spoke-b/facilitator.yml"
chmod -R a+rwX "$tmp/hub" "$tmp/spoke-a" "$tmp/spoke-b"
dev=()
# FACILITATOR_TEST_SOURCE=1: the application from this checkout over the image's (iterating without a rebuild)
[ -n "${FACILITATOR_TEST_SOURCE:-}" ] && dev=(-v "$root/src/facilitator/facilitator:/opt/facilitator/lib/facilitator:ro")
start() { # <node> <alias> <config mode ro|rw>
  docker run -d --name "$p-$1" --hostname "$2" --network "$net" --network-alias "$2" \
    -e FACILITATOR_MESH_FILE=/etc/facilitator/mesh.yml \
    -v "$p-$1:/var/lib/devcontainer-features/facilitator" -v "$tmp/$1:/etc/facilitator:$3" \
    -v "$root/test/facilitator/integration:/test:ro" "${dev[@]}" --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges:true "$image" >/dev/null
}
start hub hub.corp.test ro
start spoke-a spoke-a.corp.test rw
start spoke-b spoke-b.corp.test rw

# ---------------------------------------------------------------- the hub: its certificate, the partner bundle, its listener
if wait_for 90 sh -c "docker exec $p-hub facilitator check | grep -q 'certificate *ready'"; then
  ok "the hub's certificate issued by OpenBao PKI (spiffe://corp.test/node/hub-1, DNS hub.corp.test)"
else no "the hub's certificate"; docker logs "$p-hub" 2>&1 | tail -20; fx hub check || true; exit 1; fi
fx hub node bundle partner.test --file /etc/facilitator/partner.pem >/dev/null
docker restart "$p-hub" >/dev/null
if wait_for 90 sh -c "docker exec $p-hub facilitator infra status | grep -q 'peers *healthy'"; then ok "the hub restarted with the partner.test bundle"
else no "the hub after its restart"; docker logs "$p-hub" 2>&1 | tail -20; fi
ports="$(fx hub check | grep 'open ports' || true)"
case "$ports" in *"0.0.0.0:46358"*) ok "check on the hub shows its open ports: ${ports#*ready}" ;; *) no "check's open ports on the hub: $ports" ;; esac
if docker exec "$p-hub" sh -c 'cat /var/lib/devcontainer-features/facilitator/mesh/certs/level-private.pem' | grep -c BEGIN | grep -qx 3; then
  ok "the private listener's bundle holds corp.test (intermediate and root) and partner.test, nothing else"
else no "the private listener's bundle"; fi

# ---------------------------------------------------------------- joins
for n in spoke-a spoke-b; do fx "$n" register --all --no-directory >/dev/null; done
tok_a="$(docker exec "$p-hub" facilitator node invite 2>/dev/null)"
if [ -n "$tok_a" ] && wait_for 15 docker exec "$p-spoke-a" bash -c 'exec 3<>/dev/tcp/hub.corp.test/46359'; then
  ok "node invite made a join token, and the join endpoint opened for it"
else no "node invite or the join endpoint"; fi
if out="$(fx spoke-a node join --token "$tok_a" 2>&1)"; then ok "spoke-a joined: ${out#facilitator: }"; else no "spoke-a join: $out"; fi
# with no token live the join endpoint is closed; with another one live it is open, and the used one is refused
tok_b="$(docker exec "$p-hub" facilitator node invite 2>/dev/null)"
if out="$(fx spoke-b node join --token "$tok_a" 2>&1)"; then no "a used token joined spoke-b"
else case "$out" in *"single use"*) ok "the used token refused for spoke-b (single use)" ;; *) no "spoke-b with a used token: $out" ;; esac; fi
if out="$(fx spoke-b node join --token "$tok_b" 2>&1)"; then ok "spoke-b joined with its own token"; else no "spoke-b join: $out"; fi
if grep -q 'role: spoke' "$tmp/spoke-a/mesh.yml" && grep -q 'hub: "hub.corp.test:46358"\|hub: hub.corp.test:46358' "$tmp/spoke-a/mesh.yml"; then
  ok "node join wrote the hub into spoke-a's mesh.yml"; else no "spoke-a's mesh.yml: $(cat "$tmp/spoke-a/mesh.yml")"; fi
if docker exec "$p-openbao" sh -c "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$root_token bao kv get -format=json secret/facilitator/mesh/roster" | grep -q spoke-b; then
  ok "the hub's roster backed up into OpenBao's KV (its snapshot carries it, ruling BH)"; else no "the roster's backup in OpenBao"; fi
docker restart "$p-spoke-a" "$p-spoke-b" >/dev/null
seen() { docker exec "$p-$1" /opt/facilitator/python/bin/python3 -I /test/mesh_agent.py who | grep -q "\"handle\": \"$2\""; }
if wait_for 120 seen spoke-a b1 && wait_for 60 seen spoke-b a1; then ok "each spoke lists the other's exposed agent (the hub's roster of cards, lock two on each)"
else no "the spokes do not see each other"; fx spoke-a check || true; docker logs "$p-spoke-a" 2>&1 | tail -15; fi
if seen spoke-b a2; then no "spoke-b sees spoke-a's local-only agent a2"; else ok "a private caller does not see a local-only agent (a2 is not listed on spoke-b)"; fi
if fx spoke-a check | grep -q 'open ports.*none beyond loopback'; then ok "check on a spoke: nothing open beyond loopback (it dials out)"; else no "check's open ports on spoke-a"; fi

# ---------------------------------------------------------------- a conversation across nodes, through the hub
conv="$(agent spoke-a open pa a1 b1 -- "@a1 please ask b1 for a joke" | jget 'd["conversation"]')"
r1="$(agent spoke-a answer a1 30 "@b1 tell us a joke about hubs")"
if [ "$(echo "$r1" | jget 'd["dispatch"]["to"]')" = "['b1']" ]; then ok "a1 (spoke-a) mentioned b1 (spoke-b) in $conv: routed to b1"; else no "a1's mention: $r1"; fi
r2="$(agent spoke-b answer b1 60 "why did the packet go through the hub? it had no other peer")"
if [ "$(echo "$r2" | jget 'd["received"]["from"]')" = a1 ]; then ok "b1 received a1's message on spoke-b, through the hub's SLIM node"; else no "b1 received: $r2"; fi
r3="$(agent spoke-a answer a1 60 "@pa here is b1's joke")"
case "$r3" in *"no other peer"*) ok "b1's answer reached a1 on spoke-a (rule 3, to the asker)" ;; *) no "a1 did not get b1's answer: $r3" ;; esac
sleep 3
for n in spoke-a spoke-b; do
  if out="$(fx "$n" verify --conv "$conv" 2>&1)"; then ok "verify on $n: ${out##*: }"; else no "verify on $n: $out"; fi
done
if fx spoke-b verify --conv "$conv" | grep -q 'spiffe://corp.test/node/spoke-a (private)'; then ok "verify on spoke-b names each remote signer's SPIFFE ID and level"
else no "verify's signer IDs on spoke-b"; fi
if docker exec "$p-hub" sh -c "test -d /var/lib/devcontainer-features/facilitator/conversations/$conv"; then no "the hub holds a copy of $conv"
else ok "the hub holds no copy of $conv (none of its participants is a member: copy member)"; fi

# ---------------------------------------------------------------- lock one and lock two
docker run -d --name "$p-probe" --network "$net" -v "$tmp/root:/certs:ro" -v "$root/test/facilitator/integration:/test:ro" \
  --entrypoint /bin/sh "$image" -c 'sleep 600' >/dev/null
docker cp "$p-hub:/var/lib/devcontainer-features/facilitator/mesh/certs/corp.test/bundle.pem" "$tmp/root/corp-bundle.pem"
docker exec "$p-spoke-a" cat /var/lib/devcontainer-features/facilitator/mesh/secret >"$tmp/root/mesh-secret"
chmod a+r "$tmp/root"/*
before="$(docker exec "$p-hub" sh -c 'cat /var/lib/devcontainer-features/facilitator/mesh/refused.log 2>/dev/null | wc -l')"
PYTHONPATH="$root/src/facilitator" python3 -I - "$tmp/root" <<'EOF'
import json, os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from pathlib import Path
from facilitator import identity
d = Path(sys.argv[1])
st = identity.Store(d / "imp")
st.ensure()
st.dom("corp.test").mkdir(parents=True, exist_ok=True)
(st.key("corp.test")).write_bytes((d / "impostor.key").read_bytes())
st.cert("corp.test").write_text((d / "impostor.pem").read_text())
card = identity.make_card(st, "corp.test", "spoke-a", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA" + "B" * 42 + "=", [])
env = identity.sign_envelope(st, "corp.test", {"v": 1, "from": "spoke-a", "to": "hub-1", "at": identity.now_utc(),
                                                "type": "hello", "card": card})
(d / "impostor-hello.json").write_text(json.dumps(env))
EOF
chmod a+r "$tmp/root"/*.json
imp() { docker exec "$p-probe" /opt/facilitator/python/bin/python3 -I /test/mesh_impostor.py hub.corp.test:46358 hub.corp.test "$@" /certs/corp-bundle.pem /certs/mesh-secret hub-1 /certs/impostor-hello.json; }
out="$(imp /certs/stranger.pem /certs/stranger.key)"
case "$out" in CONNECT-REFUSED*) ok "lock one: a certificate from a CA no private domain has is refused at the listener ($out)" ;; *) no "lock one let the stranger in: $out" ;; esac
out="$(imp /certs/impostor.pem /certs/impostor.key)"
case "$out" in SENT*) ok "lock one let the impostor in (partner.test is a trusted private domain), as the spike found" ;; *) no "the impostor's envelope: $out" ;; esac
if wait_for 10 sh -c "docker exec $p-hub sh -c 'tail -n +$((before + 1)) /var/lib/devcontainer-features/facilitator/mesh/refused.log' | grep -q 'impostor: the certificate claims corp.test but chains to the CA of partner.test'"; then
  ok "lock two refused the impostor: $(docker exec "$p-hub" tail -1 /var/lib/devcontainer-features/facilitator/mesh/refused.log)"
else no "lock two did not refuse the impostor"; docker exec "$p-hub" cat /var/lib/devcontainer-features/facilitator/mesh/refused.log || true; fi
if seen spoke-b b1 && docker exec "$p-hub" sh -c 'cat /var/lib/devcontainer-features/facilitator/mesh/cards/spoke-a.json' | grep -q '"level": "private"'; then
  ok "spoke-a's own card is untouched by the impostor"; else no "spoke-a's card on the hub"; fi

# ---------------------------------------------------------------- the hub restarts; a spoke goes away and comes back
docker restart "$p-hub" >/dev/null
t0="$(date +%s)"
agent spoke-a say pa "$conv" "@b1 one more, after the hub came back" >/dev/null
if r="$(agent spoke-b answer b1 90 "the hub is back")" && [ "$(echo "$r" | jget 'd["received"]["from"]')" = pa ]; then
  ok "after the hub's restart the spokes reconnected and pa's message reached b1 ($(( $(date +%s) - t0 )) s)"
else no "after the hub's restart: $r"; docker logs "$p-spoke-a" 2>&1 | tail -10; fi
docker stop "$p-spoke-b" >/dev/null
agent spoke-a say pa "$conv" "@b1 this waits while you are away" >/dev/null
sleep 6
if docker exec "$p-spoke-a" sh -c 'ls /var/lib/devcontainer-features/facilitator/mesh/outbox/spoke-b' | grep -q "$conv"; then
  ok "spoke-b away: the message waits in spoke-a's outbox"; else no "no held message for spoke-b"; fi
docker start "$p-spoke-b" >/dev/null
if r="$(agent spoke-b answer b1 120 "back again")" && echo "$r" | grep -q 'this waits while you are away'; then
  ok "spoke-b came back and received the held message"; else no "the held message after spoke-b came back: $r"; fi

# ---------------------------------------------------------------- check reads TLS refusals from the SLIM log
sed -i 's/hub_name: .*/hub_name: wrong.corp.test/' "$tmp/spoke-a/mesh.yml"
docker restart "$p-spoke-a" >/dev/null
if wait_for 60 sh -c "docker exec $p-spoke-a facilitator check | grep -q 'tls refusals.*\(NotValidForName\|not valid for name\)'"; then
  ok "check on spoke-a names the TLS refusal of a wrong server_name: $(fx spoke-a check | grep 'tls refusals' | sed 's/.*ready *//')"
else no "check did not name the server_name refusal"; fx spoke-a check || true; fi
sed -i 's/hub_name: .*/hub_name: hub.corp.test/' "$tmp/spoke-a/mesh.yml"
docker restart "$p-spoke-a" >/dev/null
wait_for 60 seen spoke-a b1 || true

# ---------------------------------------------------------------- revoke spoke-b
if out="$(fx hub node revoke spoke-b --yes 2>&1)"; then ok "node revoke spoke-b: ${out#facilitator: }"; else no "node revoke: $out"; fi
if wait_for 60 sh -c "! docker exec $p-spoke-a /opt/facilitator/python/bin/python3 -I /test/mesh_agent.py who | grep -q '\"handle\": \"b1\"'"; then
  ok "spoke-a dropped spoke-b's card at the hub's next roster"; else no "spoke-a still lists b1"; fi
agent spoke-b open pb a1 -- "@a1 hello from a revoked node" >/dev/null 2>&1 || true
fx spoke-b node renew >/dev/null 2>&1 || true
if wait_for 30 sh -c "docker exec $p-spoke-a cat /var/lib/devcontainer-features/facilitator/mesh/refused.log | grep -q 'spoke-b'"; then
  ok "spoke-a refuses what the revoked spoke-b sends: $(docker exec "$p-spoke-a" sh -c 'grep spoke-b /var/lib/devcontainer-features/facilitator/mesh/refused.log | tail -1')"
else no "spoke-a did not refuse spoke-b"; fi
if wait_for 30 sh -c "docker exec $p-hub cat /var/lib/devcontainer-features/facilitator/mesh/refused.log | grep -q 'from spoke-b.*revoked'"; then
  ok "the hub refuses the revoked spoke-b (its hello and its renewal): $(docker exec "$p-hub" sh -c 'grep spoke-b /var/lib/devcontainer-features/facilitator/mesh/refused.log | tail -1')"
else no "the hub did not refuse spoke-b"; fi
out="$(fx spoke-b node join --token "$(docker exec "$p-hub" facilitator node invite 2>/dev/null)" 2>&1 || true)"
case "$out" in *revoked*|*"has joined"*|*"is a hub"*|*refused*) ok "a revoked node cannot join again: ${out#facilitator: }" ;; *) no "a revoked node joined again: $out" ;; esac

exit "$fail"
