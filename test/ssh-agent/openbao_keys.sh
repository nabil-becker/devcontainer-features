#!/bin/bash
# Scenario 'openbao_keys' (see scenarios.json): ssh-agent 1.4.0's keys from OpenBao with the real
# bao (a `bao server -dev`, in memory, unsealed), the openbao Feature's openbao-ssh and dcf-secret,
# and the in-container agent of key mode, remoteUser=vscode. What the Docker-free tests
# (test/ssh-agent/unit/bao_load_test.sh, test/openbao/unit/ssh_test.sh) only stub: the real KV v2
# calls of a record (create-only put, metadata, list, destroy), the real `bao token lookup` ttl,
# and a key piped from OpenBao into ssh-add with that lifetime and out again.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

export BAO_ADDR=http://127.0.0.1:18200
root=dev-root-token
log="$(mktemp)"
bao server -dev -dev-root-token-id="$root" -dev-listen-address=127.0.0.1:18200 >"$log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  bao status >/dev/null 2>&1 && break
  sleep 0.5
done
export BAO_TOKEN="$root"
bao secrets enable -path=dcf -version=2 kv >/dev/null
DCF_SSH_AGENT_LOADED_DIR="$(mktemp -d)"
export DCF_SSH_AGENT_LOADED_DIR
cd "$(mktemp -d)" && git init -q . 2>/dev/null || true

check "openbao-ssh is on PATH" command -v openbao-ssh
check "openbao:ssh:new makes a record" bash -c "openbao-ssh new --name ci-sign >/dev/null"
check "the record has its three fields" bash -c "bao kv get -mount=dcf -field=private_key ssh/ci-sign | grep -q 'PRIVATE KEY' && bao kv get -mount=dcf -field=public_key ssh/ci-sign | grep -q '^ssh-ed25519 ' && [ \"\$(bao kv get -mount=dcf -field=purpose ssh/ci-sign)\" = git-signing ]"
check "its creation date is in the custom metadata" bash -c "bao kv metadata get -mount=dcf -format=json ssh/ci-sign | grep -Eq '\"created\": \"[0-9]{4}-[0-9]{2}-[0-9]{2}\"'"
check "new used /dev/shm and left nothing there" bash -c "! ls -d /dev/shm/openbao-ssh.* >/dev/null 2>&1"
check "a name is never reused" bash -c "! openbao-ssh new --name ci-sign 2>/dev/null"
check "list reads the real kv list" bash -c "openbao-ssh list | grep -qx ssh/ci-sign"
check "dcf-secret ttl of a root token is 0" bash -c "[ \"\$(dcf-secret ttl)\" = 0 ]"

fp="$(bao kv get -mount=dcf -field=public_key ssh/ci-sign | ssh-keygen -l -f - | awk '{print $2}')"
check "key:load pipes the key into the agent" bash -c "ssh-agent-setup key-load ssh/ci-sign 5 && ssh-add -l | grep -qF '$fp'"
check "key:lock takes it out" bash -c "ssh-agent-setup key-lock ssh/ci-sign && ! ssh-add -l | grep -qF '$fp'"
child="$(bao token create -ttl=10m -field=token)"
check "a 10 minute token gives at most 10 minutes" bash -c "BAO_TOKEN='$child' ssh-agent-setup key-load ssh/ci-sign 60 | grep -Eq 'until .* \((9|10) minute'"
ssh-add -D >/dev/null 2>&1 || true

vol="$(mktemp -d)"
ssh-keygen -q -t ed25519 -N '' -C vol -f "$vol/vol-sign"
check "import FROM=ssh-agent stores the volume's key" bash -c "OPENBAO_SSH_NO_ASK=1 openbao-ssh import --from ssh-agent --dir '$vol' && [ \"\$(bao kv get -mount=dcf -field=private_key ssh/vol-sign)\" = \"\$(cat '$vol/vol-sign')\" ]"
check "the volume's copy is left without an answer" test -f "$vol/vol-sign"
check "import again skips it" bash -c "OPENBAO_SSH_NO_ASK=1 openbao-ssh import --from ssh-agent --dir '$vol' 2>&1 | grep -q '1 already there'"

check "retire destroys the private key's versions" bash -c "openbao-ssh retire --name ci-sign && ! bao kv get -mount=dcf -field=private_key ssh/ci-sign >/dev/null 2>&1 && bao kv metadata get -mount=dcf -format=json ssh/ci-sign | grep -q '\"destroyed\": true'"
check "the retired record keeps its public key" bash -c "bao kv get -mount=dcf -field=public_key ssh/ci-sign | grep -q '^ssh-ed25519 '"
check "age lists both, the retired one dated" bash -c "openbao-ssh age | grep -q 'ssh/ci-sign: created .*, retired ' && openbao-ssh age | grep -q 'ssh/vol-sign: created '"

reportResults
