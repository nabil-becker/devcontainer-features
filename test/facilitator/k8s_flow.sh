#!/usr/bin/env bash
# The hub on Kubernetes end to end (task test:facilitator-k8s): a throwaway kind cluster inside this machine's Docker, the hub
# deployed from bundles/facilitator/k8s (the rancher-desktop overlay, then the ssh-agent overlay), and spokes that are plain
# containers of the node image reaching it through the machine, as the devcontainers of a workstation do.
#
#   kind cluster (one node; NodePorts 30358/30359 published on the machine's 46358/46359)
#     facilitator-hub-0 (StatefulSet, uid 10001, read-only root)  <---- spoke-a, spoke-b, spoke-c (docker run, host-gateway)
#
# Phase A, the built-in issuer: the pod's hardening, the Service's two ports, check (a warning that the CA key is a file), a
# spoke joins with a token and an agent on it talks to the hub's agent, verify; export-root takes the root key out of the
# volume, the hub keeps issuing and a second spoke joins. Phase B, the ssh-agent tier: a key loaded into the agent container
# beside the hub, a spoke's certificate signed by it, a CA key file nowhere, the agent removed and issuing refused cleanly while
# the issued certificate stays valid. Removes the cluster, the containers, the volumes and the node image kind pulled, whatever
# happens. FACILITATOR_TEST_SOURCE=1 mounts this checkout's application over the image's on the spokes only (the hub pod runs the
# image: rebuild it with task bundle:build and bundle:image after a change).
# shellcheck disable=SC2015  # `A && ok || no` is the pattern of every flow script here
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
version="$(bash "$root/bundles/facilitator/install.sh" --version)"
image="${FACILITATOR_NODE_IMAGE:-facilitator-node:$version-local}"
p="fac-k8s-$$"
cluster="$p"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fac-k8s-XXXXXX")"
ns=facilitator-hub
pod=facilitator-hub-0
st=/var/lib/devcontainer-features/facilitator
name=hub.workstation.example
fail=0
ok() { echo "ok   $1"; }
no() { echo "FAIL $1"; fail=1; }
spokes=()
pulled_node=0
# shellcheck disable=SC1091
. "$root/test/facilitator/k8s/tools.sh"

# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() {
  local rc=$?
  if [ "$rc" != 0 ] && [ -n "${KUBECONFIG:-}" ]; then
    kubectl -n "$ns" get pods -o wide 2>&1 | tail -5 || true
    kubectl -n "$ns" logs "$pod" -c hub --tail=15 2>&1 || true
  fi
  for s in "${spokes[@]}"; do docker rm -fv "$p-$s" >/dev/null 2>&1 || true; docker volume rm "$p-$s" >/dev/null 2>&1 || true; done
  kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
  docker rmi "facilitator-node:kind-test" >/dev/null 2>&1 || true
  if [ "$pulled_node" = 1 ]; then docker rmi "$KIND_NODE_IMAGE" >/dev/null 2>&1 || true; fi
  docker run --rm -v "$tmp:/t" --entrypoint /bin/sh -u 0 "$image" -c 'rm -rf /t/* /t/.[!.]*' >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

jget() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}))" "$1"; }
wait_for() { local n="$1"; shift; for _ in $(seq 1 "$n"); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 1; done; return 1; }
hub() { kubectl -n "$ns" exec "$pod" -c hub -- "$@"; }          # a command in the hub's container
fxh() { hub facilitator "$@"; }
fxs() { local n="$1"; shift; docker exec "$p-$n" facilitator "$@"; }
agent_h() { kubectl -n "$ns" exec -i "$pod" -c hub -- /opt/facilitator/python/bin/python3 -I - "$@" <"$root/test/facilitator/integration/mesh_agent.py"; }
agent_s() { local n="$1"; shift; docker exec "$p-$n" /opt/facilitator/python/bin/python3 -I /test/mesh_agent.py "$@"; }
# shellcheck disable=SC2329  # used through wait_for
seen_s() { agent_s "$1" who | grep -q "\"handle\": \"$2\""; }

# ---------------------------------------------------------------- the machine and the tools
echo "df -h /: $(df -h / | tail -1)"
docker image inspect "$image" >/dev/null 2>&1 || { echo "no image $image: task bundle:build, then task bundle:image"; exit 1; }
for port in 46358 46359; do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port\$"; then echo "port $port is in use on this machine: the test publishes it"; exit 1; fi
done
fac_tools kind kubectl kustomize kubeconform
ok "tools: kind $(fac_version_of kind), kubectl $(fac_version_of kubectl), kustomize $(fac_version_of kustomize), kubeconform $(fac_version_of kubeconform) (pinned, checksummed)"

# ---------------------------------------------------------------- the manifests: rendered, schema checked, shape checked
for o in base overlays/rancher-desktop overlays/ssh-agent; do
  if kustomize build "$root/bundles/facilitator/k8s/$o" | kubeconform -strict -summary -kubernetes-version "$KUBERNETES_SCHEMA_VERSION" >"$tmp/kc.out" 2>&1; then ok "kustomize build $o | kubeconform: $(tail -1 "$tmp/kc.out")"
  else no "kubeconform $o: $(cat "$tmp/kc.out")"; fi
done
if bash "$root/test/facilitator/k8s/shape.sh" >"$tmp/shape.out" 2>&1; then ok "the rendered manifests' shape: $(grep -c '^ok' "$tmp/shape.out") checks (uid 10001, read-only root, no capabilities, SLIM and join ports only, built-in issuer)"
else no "the manifests' shape"; grep FAIL "$tmp/shape.out"; fi

# ---------------------------------------------------------------- the cluster
docker image inspect "$KIND_NODE_IMAGE" >/dev/null 2>&1 || pulled_node=1
export KUBECONFIG="$tmp/kubeconfig"
kind create cluster --name "$cluster" --image "$KIND_NODE_IMAGE" --config "$root/test/facilitator/k8s/kind-config.yaml" \
  --kubeconfig "$KUBECONFIG" --wait 120s >"$tmp/kind.log" 2>&1 || { cat "$tmp/kind.log"; exit 1; }
docker tag "$image" facilitator-node:kind-test
kind load docker-image facilitator-node:kind-test --name "$cluster" >/dev/null
ok "kind cluster $cluster up (node image pinned by digest); the node image loaded into it"

deploy() { # <overlay dir>
  kustomize build "$1" | kubectl apply -f - >/dev/null
  kubectl -n "$ns" rollout status statefulset/facilitator-hub --timeout=240s >/dev/null
}

# ---------------------------------------------------------------- phase A: the built-in issuer
deploy "$root/test/facilitator/k8s/kind"
ok "the hub deployed from the base through the rancher-desktop overlay: the StatefulSet is ready"
uid="$(hub id -u)"; [ "$uid" = 10001 ] && ok "the hub runs as uid 10001" || no "the hub's uid is $uid"
if hub sh -c 'touch /etc/facilitator-rw 2>/dev/null || touch /usr/rw 2>/dev/null'; then no "the root filesystem is writable"; else ok "the root filesystem is read-only (the state volume and /tmp are the only writable paths)"; fi
hub sh -c "touch $st/.w && rm $st/.w && touch /tmp/.w && rm /tmp/.w" && ok "the state volume and /tmp are writable" || no "the state volume or /tmp is not writable"
caps="$(hub sh -c 'grep CapEff /proc/self/status' | awk '{print $2}')"; [ "$caps" = 0000000000000000 ] && ok "the hub holds no capabilities (CapEff $caps)" || no "capabilities: $caps"
ports="$(kubectl -n "$ns" get svc facilitator-hub -o jsonpath='{range .spec.ports[*]}{.port} {end}')"
[ "$ports" = "46358 46359 " ] && ok "the Service exposes 46358 and 46359 and nothing else" || no "Service ports: $ports"
pvc="$(kubectl -n "$ns" get pvc -o jsonpath='{.items[*].metadata.name}')"; [ "$pvc" = state-facilitator-hub-0 ] && ok "the state is on a volume claim ($pvc)" || no "pvc: $pvc"
if wait_for 120 sh -c "kubectl -n $ns exec $pod -c hub -- facilitator check | grep -q 'certificate *ready'"; then
  ok "the hub issued its own certificate: the built-in CA, nothing to unseal"
else no "the hub's certificate"; fxh check || true; exit 1; fi
chk="$(fxh check 2>&1 || true)"
case "$chk" in *"built-in CA"*) ok "check names the tier: $(echo "$chk" | grep 'issuer  ' | head -1 | cut -c1-130)" ;; *) no "check does not name the built-in CA: $chk" ;; esac
case "$chk" in *"warning: the CA key is a file"*) ok "check warns that the CA key is a file (the last resort)" ;; *) no "check's key-file warning missing" ;; esac
if hub sh -c "ls $st/mesh/ca/workstation.example/" | grep -q root.key && hub sh -c "ls $st/mesh/ca/workstation.example/" | grep -q '^ca.key'; then
  ok "the volume holds the root and the issuing CA (two keys) before export-root"; else no "the CA files before export-root"; fi
fxh register triage >/dev/null

mkspoke() { # <name> <agent>: a spoke container reaching the hub through the machine
  local n="$1" a="$2" d="$tmp/$1"
  mkdir -p "$d"
  printf 'preset: team\nrole: spoke\nnode:\n  id: %s\nexpose:\n  "*": local\n  %s: private\n  p%s: private\n' "$n" "$a" "$a" >"$d/mesh.yml"
  printf 'participants:\n  - name: %s\n    cli: claude\n    kind: resident\n    attachment: mcp\n    description: agent of %s\n' "$a" "$n" >"$d/participants.yml"
  printf 'facilitator:\n  humans: [p%s]\n' "$a" >"$d/facilitator.yml"
  chmod -R a+rwX "$d"
  local dev=()
  [ -n "${FACILITATOR_TEST_SOURCE:-}" ] && dev=(-v "$root/src/facilitator/facilitator:/opt/facilitator/lib/facilitator:ro")
  spokes+=("$n")
  docker run -d --name "$p-$n" --hostname "$n" --add-host "$name:host-gateway" \
    -e FACILITATOR_MESH_FILE=/etc/facilitator/mesh.yml -v "$p-$n:$st" -v "$d:/etc/facilitator:rw" \
    -v "$root/test/facilitator/integration:/test:ro" "${dev[@]}" --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges:true "$image" >/dev/null
  wait_for 60 docker exec "$p-$n" facilitator infra status || true
  fxs "$n" register --all --no-directory >/dev/null
}
join() { # <spoke>: a token from the hub (a person's act: a plain exec, no agent variable), the join, a restart
  local n="$1" tok out
  tok="$(fxh node invite 2>/dev/null)"
  wait_for 30 docker exec "$p-$n" bash -c "exec 3<>/dev/tcp/$name/46359" || true
  if out="$(fxs "$n" node join --token "$tok" 2>&1)"; then ok "$n joined through the machine's port ($name:46359, the token's address): ${out#facilitator: }"; else no "$n join: $out"; return 1; fi
  docker restart "$p-$n" >/dev/null
}

mkspoke spoke-a a1
join spoke-a
if wait_for 150 seen_s spoke-a triage; then ok "spoke-a lists the hub's agent triage (the roster of cards, lock two): the link formed over the Service's SLIM port"
else no "spoke-a does not see triage"; fxs spoke-a check || true; docker logs "$p-spoke-a" 2>&1 | tail -10; exit 1; fi
conv="$(agent_s spoke-a open pa1 a1 triage -- "@triage hello from a spoke on the workstation" | jget 'd["conversation"]')"
r1="$(agent_h answer triage 60 "triage on the hub here: welcome")"
case "$r1" in *"hello from a spoke"*) ok "the hub's agent triage received a1's message in $conv (spoke to hub, over SLIM through the cluster)" ;; *) no "triage received: $r1" ;; esac
r2=""; for _ in $(seq 1 30); do r2="$(agent_s spoke-a mail pa1)"; case "$r2" in *"welcome"*) break ;; esac; sleep 1; done
case "$r2" in *"welcome"*) ok "the person on the spoke (pa1) received the hub agent's answer (rule 3: to the asker)" ;; *) no "pa1 did not get the answer: $r2" ;; esac
sleep 3
for where in hub spoke-a; do
  if [ "$where" = hub ]; then rc=0; out="$(fxh verify --conv "$conv" 2>&1)" || rc=$?; else rc=0; out="$(fxs spoke-a verify --conv "$conv" 2>&1)" || rc=$?; fi
  [ "$rc" = 0 ] && ok "verify on $where: ${out##*: }" || no "verify on $where: $out"
done
if [[ "$(kubectl -n "$ns" exec "$pod" -c hub -- env CLAUDECODE=1 facilitator node issuer export-root --out /tmp/x 2>&1 || true)" == *"agent's job"* ]]; then ok "export-root is refused inside an agent's job"; else no "export-root in an agent's job"; fi

# export-root: the root key leaves the volume (a file in /tmp, copied out and removed: a person's act), the hub keeps issuing
if out="$(fxh node issuer export-root --out /tmp/root-offline.pem 2>&1)"; then ok "export-root: $(echo "${out#facilitator: }" | cut -c1-110)..."; else no "export-root: $out"; fi
kubectl -n "$ns" exec "$pod" -c hub -- cat /tmp/root-offline.pem >"$tmp/root-offline.pem"
hub rm /tmp/root-offline.pem
if grep -q "PRIVATE KEY" "$tmp/root-offline.pem" && grep -q "BEGIN CERTIFICATE" "$tmp/root-offline.pem"; then ok "the root's key and certificate are in a file outside the cluster (mode 600 inside), taken offline"; else no "the exported root"; fi
if hub sh -c "ls $st/mesh/ca/workstation.example/" | grep -q root.key; then no "root.key is still in the volume"; else ok "root.key is no longer in the volume (the issuing CA and its key remain: the hub issues, the spokes' bundle is unchanged)"; fi
mkspoke spoke-b b1
join spoke-b
if wait_for 150 seen_s spoke-b triage && wait_for 60 seen_s spoke-a b1; then ok "after export-root a second spoke joined and the spokes see each other's agents through the hub"
else no "the second spoke after export-root"; fxs spoke-b check || true; fi
conv2="$(agent_s spoke-b open pb1 b1 a1 -- "@a1 hello across spokes after export-root" | jget 'd["conversation"]')"
r3="$(agent_s spoke-a answer a1 60 "a1 here")"
case "$r3" in *"after export-root"*) ok "b1 (spoke-b) reached a1 (spoke-a) through the hub after the root key left" ;; *) no "b1 to a1: $r3" ;; esac
sleep 2
out="$(fxs spoke-a verify --conv "$conv2" 2>&1)" && ok "verify on spoke-a: ${out##*: }" || no "verify spoke-a: $out"

# ---------------------------------------------------------------- phase B: the CA key in an ssh-agent
kubectl delete namespace "$ns" --wait=true --timeout=120s >/dev/null
ok "the built-in hub removed (its volume with it: a new tier is a new CA, every spoke joins again)"
for s in spoke-a spoke-b; do docker rm -fv "$p-$s" >/dev/null; docker volume rm "$p-$s" >/dev/null; done
spokes=()
ssh-keygen -q -t ed25519 -N '' -C hub-ca-test -f "$tmp/hub-ca"
fp="$(ssh-keygen -l -E sha256 -f "$tmp/hub-ca.pub" | awk '{print $2}')"
work="$tmp/work"; mkdir -p "$work/test/facilitator" "$work/bundles/facilitator"
cp -r "$root/test/facilitator/k8s" "$work/test/facilitator/k8s"; cp -r "$root/bundles/facilitator/k8s" "$work/bundles/facilitator/k8s"
sed -i "s|__FINGERPRINT__|$fp|" "$work/test/facilitator/k8s/kind-ssh-agent/mesh.yml"
deploy "$work/test/facilitator/k8s/kind-ssh-agent"
ok "the hub redeployed from the ssh-agent overlay: the pod has the hub container and an ssh-agent container (CA key fingerprint $fp)"
n="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.spec.containers[*].name}')"; [ "$n" = "hub ca-agent" ] && ok "containers: $n" || no "containers: $n"
chk="$(fxh check 2>&1 || true)"
case "$chk" in *"does not hold"*|*"unreachable"*|*"no such socket"*) ok "before the key is loaded check says the agent holds no such key; nothing is issued" ;; *) no "check before the key: $(echo "$chk" | grep -i issuer)" ;; esac
kubectl -n "$ns" exec -i "$pod" -c ca-agent -- ssh-add - <"$tmp/hub-ca" >/dev/null 2>&1 && ok "a person loaded the CA key into the agent container (ssh-add - over kubectl exec): it lives in that agent's memory" || no "ssh-add"
if wait_for 150 sh -c "kubectl -n $ns exec $pod -c hub -- facilitator check | grep -q 'certificate *ready'"; then ok "the hub issued its own certificate through the agent"
else
  fxh node renew >/dev/null 2>&1 || true
  if wait_for 60 sh -c "kubectl -n $ns exec $pod -c hub -- facilitator check | grep -q 'certificate *ready'"; then ok "the hub issued its own certificate through the agent (after node renew)"; else no "the hub's certificate through the agent"; fxh check || true; exit 1; fi
fi
chk="$(fxh check 2>&1 || true)"
case "$chk" in *"never a file"*) ok "check: $(echo "$chk" | grep 'issuer  ' | head -1 | cut -c1-140)" ;; *) no "check's agent row: $(echo "$chk" | grep -i issuer)" ;; esac
case "$chk" in *"warning: the CA key is a file"*) no "check warns about a key file with an agent tier" ;; *) ok "no key-file warning in the agent tier" ;; esac
if hub sh -c "find $st -name ca.key -o -name root.key" | grep -q .; then no "a CA key file exists in the volume"; else ok "no CA key file anywhere in the volume (ca.key and root.key do not exist)"; fi
fxh register triage >/dev/null
mkspoke spoke-c c1
join spoke-c
if wait_for 150 seen_s spoke-c triage; then ok "spoke-c, whose certificate the agent signed, linked to the hub and lists triage"; else no "spoke-c does not see triage"; fxs spoke-c check || true; fi
pub="$(ssh-keygen -y -f "$tmp/hub-ca" | awk '{print $2}')"
cakey="$(hub sh -c "openssl x509 -in $st/mesh/certs/workstation.example/bundle.pem -noout -pubkey" | grep -v -- '-----' | tr -d '\n')"
want="$(python3 -I -c "
import base64,sys
b=base64.b64decode(sys.argv[1]); raw=b[-32:]
print(base64.b64encode(bytes.fromhex('302a300506032b6570032100')+raw).decode())" "$pub")"
[ "$cakey" = "$want" ] && ok "the domain's CA certificate carries the agent key's public half" || no "the CA certificate is not the agent key's"
cert="$(docker exec "$p-spoke-c" cat "$st/mesh/certs/workstation.example/node.pem")"
if printf '%s' "$cert" | docker exec -i "$p-spoke-c" openssl verify -CAfile "$st/mesh/certs/workstation.example/bundle.pem" -purpose any /dev/stdin >/dev/null 2>&1; then ok "spoke-c's certificate verifies against the bundle (openssl checks the agent's signature)"; else no "spoke-c's certificate does not verify"; fi
kubectl -n "$ns" exec "$pod" -c ca-agent -- rm /run/ssh-ca/agent.sock
chk="$(fxh check 2>&1 || true)"
case "$chk" in *"unreachable"*) ok "agent gone: check says so (\"ssh-agent unreachable\"; certificates already issued stay valid)" ;; *) no "check with the agent gone: $(echo "$chk" | grep -i issuer)" ;; esac
tok="$(fxh node invite 2>/dev/null)"
mkspoke spoke-d d1
wait_for 30 docker exec "$p-spoke-d" bash -c "exec 3<>/dev/tcp/$name/46359" || true
out="$(fxs spoke-d node join --token "$tok" 2>&1 || true)"
case "$out" in *"unreachable"*|*"issuer"*) ok "issuing stops cleanly: a join now is refused (${out#facilitator: })" ;; *) no "a join with the agent gone: $out" ;; esac
if fxs spoke-c check | grep -q 'certificate *ready'; then ok "spoke-c's existing certificate is still valid with the agent gone"; else no "spoke-c's certificate"; fi
agent_s spoke-c open pc1 c1 triage -- "@triage still there with the agent gone?" >/dev/null
r4="$(agent_h answer triage 60 "yes")"
case "$r4" in *"still there"*) ok "traffic over the existing links is unaffected: triage received c1's message" ;; *) no "traffic with the agent gone: $r4" ;; esac

echo
if [ "$fail" = 0 ]; then echo "the hub on Kubernetes: all checks passed"; else echo "the hub on Kubernetes: FAILED"; fi
exit "$fail"
