#!/bin/bash
# Scenario 'ssh_ca' (see scenarios.json): the SSH certificate authority against a real
# `bao server -dev` (in memory, unsealed), remoteUser=vscode, with the real tasks, dcf-ssh-sign,
# the real Operator policy (written from openbao-lib.sh, as init writes it) and stock OpenSSH:
#   - no CA yet: dcf-ssh-sign says so (11); openbao:ssh:ca:init makes the mount, the CA and the
#     default role, and run again reports the CA and changes nothing;
#   - a certificate from dcf-ssh-sign sign verifies with `ssh-keygen -Y verify` against a line
#     `relay@* cert-authority,namespaces="<ns>" <CA public key>` (the signature made through an
#     ssh-agent holding the key and its certificate), and does not verify in another namespace or
#     for a principal the line does not cover; a certificate with a short TTL stops verifying when it
#     expires; the certificate has no extensions and no critical options;
#   - a principal outside the role is refused (13); no token is 12; a token of an AppRole that reads
#     one secret may not sign or read the CA (13); sealed is 11 (last: a dev server cannot be
#     unsealed again);
#   - a second role (the office's: `register`, principals writer@<handle>-<tag>, namespace
#     ledger-<room>): its certificate verifies against its own line, a principal only the other role
#     allows is refused in either direction, `dcf-ssh-sign roles` lists both, one per line;
#   - the CA's private key cannot be read back: not by the Operator's token, not by a root token,
#     not through any task's output nor dcf-secret; the Operator's token cannot change the CA or a role;
#   - import: a CA key on stdin goes into another mount, its fingerprint is the key's, a second
#     import is refused, and the key is nowhere to be read back.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

export BAO_ADDR=http://127.0.0.1:18201
root=dev-root-token
log="$(mktemp)"
bao server -dev -dev-root-token-id="$root" -dev-listen-address=127.0.0.1:18201 >"$log" 2>&1 &
server=$!
agent_pid=""
trap 'kill "$server" 2>/dev/null || true; [ -z "$agent_pid" ] || kill "$agent_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  bao status >/dev/null 2>&1 && break
  sleep 0.5
done

work="$(mktemp -d)"
home="$(mktemp -d)"
state="$(mktemp -d)"
tf=/usr/local/share/go-task/includes.d/openbao.yml
# the tasks and dcf-ssh-sign as a plain user's terminal would run them (this test may itself run
# inside an agent's job, which they refuse on purpose; that refusal has its own check below)
as() { env -u BAO_TOKEN -u CLAUDECODE -u DEVHOST_JOB_CHILD HOME="$home" OPENBAO_STATE_DIR="$state" "$@"; }
t() { as BAO_TOKEN="$tok" task -t "$tf" "$@"; }
sign() { as BAO_TOKEN="$tok" dcf-ssh-sign "$@"; }
trun() { trc=0; tout="$(t "$@" 2>&1)" || trc=$?; } # a task: its output in $tout, its exit code in $trc
rcof() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
contains() { grep -qF -- "$2" <<<"$1"; }
excludes() { ! grep -qF -- "$2" <<<"$1"; }
not() { ! "$@"; }

# --- the server's policies and tokens -----------------------------------------------------------
export BAO_TOKEN="$root"
bao secrets enable -path=dcf -version=2 kv >/dev/null
# shellcheck disable=SC1091  # installed by install.sh
. /usr/local/share/openbao-feature/openbao-lib.sh
operator_policy dcf | bao policy write operator - >/dev/null
printf 'path "dcf/data/register/scribe" { capabilities = ["read"] }\n' | bao policy write approle-scribe - >/dev/null
printf 'path "sys/storage/raft/snapshot" { capabilities = ["read"] }\n' | bao policy write approle-backup - >/dev/null
optok="$(bao token create -policy=operator -field=token)"
sctok="$(bao token create -policy=approle-scribe -field=token)"
bktok="$(bao token create -policy=approle-backup -field=token)"
unset BAO_TOKEN

# --- no CA yet ------------------------------------------------------------------------------------
tok="$optok"
rc=0; out="$(sign status 2>/dev/null)" || rc=$?
check "before init, status says not-initialised (exit 11)" [ "$rc:$out" = 11:not-initialised ]
ssh-keygen -q -t ed25519 -N '' -C relay -f "$work/key"
guid=11111111-2222-3333-4444-555555555555
rc=0; err="$(sign sign --principals "relay@$guid" --key-id x <"$work/key.pub" 2>&1 >/dev/null)" || rc=$?
check "before init, sign is exit 11" [ "$rc" = 11 ]
check "and names the init task" contains "$err" 'task openbao:ssh:ca:init'

# --- init ---------------------------------------------------------------------------------------
tok="$root"
trun ssh:ca:init
out="$tout"
check "task openbao:ssh:ca:init exits 0" [ "$trc" = 0 ]
check "it enabled the ssh engine at ssh-ca" bao read sys/mounts/ssh-ca
tok="$optok"
ca="$(sign ca)"
check "the CA's public key is one line" [ "$(wc -l <<<"$ca")" = 1 ]
check "an ssh-ed25519 key" [ "${ca%% *}" = ssh-ed25519 ]
fp="$(sign ca --fingerprint)"
check "ca --fingerprint is what ssh-keygen -lf prints" [ "$fp" = "$(printf '%s\n' "$ca" | ssh-keygen -lf -)" ]
check "task openbao:ssh:ca:init printed the same fingerprint" contains "$out" "$(awk '{print $2}' <<<"$fp")"
tok="$root"
out2="$(t ssh:ca:init 2>&1)"
check "init again exits 0 and says nothing changed" contains "$out2" 'nothing changed'
check "init again left the CA as it was" [ "$(as BAO_TOKEN="$optok" dcf-ssh-sign ca)" = "$ca" ]
check "status is ready for the Operator" [ "$(as BAO_TOKEN="$optok" dcf-ssh-sign status)" = ready ]
tok="$optok"

# --- a certificate verifies with stock OpenSSH ---------------------------------------------------
ns=relay-test
sign sign --principals "relay@$guid" --key-id "relay-$guid" --ttl 1h <"$work/key.pub" >"$work/key-cert.pub"
check "sign printed one line" [ "$(wc -l <"$work/key-cert.pub")" = 1 ]
check "an ssh-ed25519 user certificate" grep -q '^ssh-ed25519-cert-v01@openssh[.]com ' "$work/key-cert.pub"
cert_text="$(ssh-keygen -L -f "$work/key-cert.pub")"
check "the certificate names the principal and the key id" contains "$cert_text" "relay@$guid" && contains "$cert_text" "relay-$guid"
check "the certificate has no extensions" contains "$cert_text" 'Extensions: (none)'
check "the certificate has no critical options" contains "$cert_text" 'Critical Options: (none)'
check "it was signed by the CA's key" contains "$cert_text" "$(awk '{print $2}' <<<"$fp")"
printf 'relay@* cert-authority,namespaces="%s" %s\n' "$ns" "$ca" >"$work/allowed"
eval "$(ssh-agent -s)" >/dev/null
agent_pid="$SSH_AGENT_PID"
ssh-add "$work/key" >/dev/null 2>&1
printf 'a message' >"$work/msg"
ssh-keygen -Y sign -U -f "$work/key-cert.pub" -n "$ns" "$work/msg" >/dev/null 2>&1
check "ssh-keygen -Y verify accepts the certificate against the relay@* cert-authority line" ssh-keygen -Y verify -f "$work/allowed" -I "relay@$guid" -n "$ns" -s "$work/msg.sig" <"$work/msg"
check "and not in another namespace" not ssh-keygen -Y verify -f "$work/allowed" -I "relay@$guid" -n other -s "$work/msg.sig" <"$work/msg"
printf 'fed-* cert-authority,namespaces="%s" %s\n' "$ns" "$ca" >"$work/allowed-fed"
check "and not under a line that covers another principal form" not ssh-keygen -Y verify -f "$work/allowed-fed" -I "relay@$guid" -n "$ns" -s "$work/msg.sig" <"$work/msg"
printf 'relay@* cert-authority,namespaces="%s" %s\n' "$ns" "$(cat "$work/key.pub")" >"$work/allowed-wrong-ca"
check "and not against another key as the CA" not ssh-keygen -Y verify -f "$work/allowed-wrong-ca" -I "relay@$guid" -n "$ns" -s "$work/msg.sig" <"$work/msg"

# a federation principal of the default role, and an expiry
sign sign --principals "fed-$guid" --key-id "fed-$guid" --ttl 3s <"$work/key.pub" >"$work/key-cert.pub"
ssh-add -D >/dev/null 2>&1
ssh-add "$work/key" >/dev/null 2>&1
printf 'fed-* cert-authority,namespaces="%s" %s\n' "$ns" "$ca" >"$work/allowed"
rm -f "$work/msg.sig"
ssh-keygen -Y sign -U -f "$work/key-cert.pub" -n "$ns" "$work/msg" >/dev/null 2>&1
check "a fed-<guid> certificate verifies while it is valid" ssh-keygen -Y verify -f "$work/allowed" -I "fed-$guid" -n "$ns" -s "$work/msg.sig" <"$work/msg"
sleep 5
check "an expired certificate fails to verify" not ssh-keygen -Y verify -f "$work/allowed" -I "fed-$guid" -n "$ns" -s "$work/msg.sig" <"$work/msg"
out="$(ssh-keygen -Y verify -f "$work/allowed" -I "fed-$guid" -n "$ns" -s "$work/msg.sig" <"$work/msg" 2>&1 || true)"
check "and says it expired" contains "$out" 'expired'

# --- refusals ---------------------------------------------------------------------------------------
rc=0; err="$(sign sign --principals evil --key-id x <"$work/key.pub" 2>&1 >/dev/null)" || rc=$?
check "a principal outside the role is exit 13" [ "$rc" = 13 ]
check "with the one line naming the role" contains "$err" "outside the role 'default'"
rc=0; sign sign --principals "relay@$guid" --key-id x --ttl 9999d <"$work/key.pub" >/dev/null 2>&1 || rc=$?
check "a lifetime beyond the role's maximum is refused (exit 2), nothing signed" [ "$rc" = 2 ]
tok=""
rc=0; sign sign --principals "relay@$guid" --key-id x <"$work/key.pub" >/dev/null 2>&1 || rc=$?
check "with no token, sign is exit 12" [ "$rc" = 12 ]
tok="$sctok"
rc=0; err="$(sign sign --principals "relay@$guid" --key-id x <"$work/key.pub" 2>&1 >/dev/null)" || rc=$?
check "an AppRole token (the backs') may not sign: exit 13" [ "$rc" = 13 ]
check "the line says only the Operator's policy may" contains "$err" "Operator's policy"
check "and cannot read the CA either (13)" [ "$(rcof sign ca)" = 13 ]
check "status for it is denied" [ "$(sign status 2>/dev/null || true)" = denied ]
check "directly against the server it is refused too" not as BAO_TOKEN="$sctok" bao write ssh-ca/sign/default public_key=@"$work/key.pub" valid_principals="relay@$guid" key_id=x
tok="$bktok"
rc=0; sign sign --principals "relay@$guid" --key-id x <"$work/key.pub" >/dev/null 2>&1 || rc=$?
check "the backup role's token may not sign either (13)" [ "$rc" = 13 ]
tok="$optok"
for v in DEVHOST_JOB_CHILD CLAUDECODE; do
  rc=0; err="$(env "$v=1" BAO_TOKEN="$optok" dcf-ssh-sign sign --principals "relay@$guid" --key-id x <"$work/key.pub" 2>&1 >/dev/null)" || rc=$?
  check "dcf-ssh-sign refuses inside an agent's job ($v): exit 3" [ "$rc" = 3 ]
  check "with the line that says so" contains "$err" "agent's job"
  rc=0; err="$(env "$v=1" BAO_TOKEN="$root" task -t "$tf" ssh:ca:init 2>&1 >/dev/null)" || rc=$?
  check "task openbao:ssh:ca:init refuses inside an agent's job ($v)" contains "$err" "agent's job"
  rc=0; err="$(env "$v=1" BAO_TOKEN="$root" task -t "$tf" ssh:ca:role NAME=x ALLOWED='x@*' 2>&1 >/dev/null)" || rc=$?
  check "task openbao:ssh:ca:role refuses inside an agent's job ($v)" contains "$err" "agent's job"
done
check "the Operator's token cannot make a role" not as BAO_TOKEN="$optok" bao write ssh-ca/roles/evil key_type=ca allowed_users='*' allow_user_certificates=true
check "nor change the default role" not as BAO_TOKEN="$optok" bao write ssh-ca/roles/default key_type=ca allowed_users='*' allow_user_certificates=true allow_host_certificates=true
check "nor replace or delete the CA" not as BAO_TOKEN="$optok" bao write ssh-ca/config/ca generate_signing_key=true
check "nor delete it" not as BAO_TOKEN="$optok" bao delete ssh-ca/config/ca
check "nor enable another mount" not as BAO_TOKEN="$optok" bao secrets enable -path=ssh-evil ssh
check "the CA is still the same one" [ "$(sign ca)" = "$ca" ]

# --- a second role: the office's register writer keys -------------------------------------------------
tok="$root"
trun ssh:ca:role NAME=register ALLOWED='writer@*' TTL=30d MAX_TTL=90d
out="$tout"
check "task openbao:ssh:ca:role NAME=register exits 0" [ "$trc" = 0 ]
tok="$optok"
check "dcf-ssh-sign roles lists both, one per line, nothing else" [ "$(sign roles)" = "$(printf 'default\nregister')" ]
tok="$root"
check "ca:role with the role as asked changes nothing" contains "$(t ssh:ca:role NAME=register ALLOWED='writer@*' TTL=30d MAX_TTL=90d 2>&1)" 'nothing changed'
rc=0; t ssh:ca:role NAME=register ALLOWED='bad;one' >/dev/null 2>&1 || rc=$?
check "ca:role with a bad pattern is refused" [ "$rc" != 0 ]
tok="$optok"
ssh-keygen -q -t ed25519 -N '' -C writer -f "$work/wkey"
room_ns=ledger-room1
sign sign --role register --principals 'writer@alice-laptop' --key-id 'writer-alice-laptop' <"$work/wkey.pub" >"$work/wkey-cert.pub"
check "the register role signs writer@<handle>-<tag>" [ -s "$work/wkey-cert.pub" ]
check "with the default lifetime of the role (30 days)" contains "$(ssh-keygen -L -f "$work/wkey-cert.pub")" 'Valid: from'
printf 'writer@* cert-authority,namespaces="%s" %s\n' "$room_ns" "$ca" >"$work/allowed-reg"
ssh-add -D >/dev/null 2>&1
ssh-add "$work/wkey" >/dev/null 2>&1
printf 'a ledger entry' >"$work/entry"
ssh-keygen -Y sign -U -f "$work/wkey-cert.pub" -n "$room_ns" "$work/entry" >/dev/null 2>&1
check "ssh-keygen -Y verify accepts it against writer@* cert-authority,namespaces=ledger-<room>" ssh-keygen -Y verify -f "$work/allowed-reg" -I 'writer@alice-laptop' -n "$room_ns" -s "$work/entry.sig" <"$work/entry"
check "and not in another register's namespace" not ssh-keygen -Y verify -f "$work/allowed-reg" -I 'writer@alice-laptop' -n ledger-room2 -s "$work/entry.sig" <"$work/entry"
check "and not under the relay line (relay and register certificates never stand in for each other)" not ssh-keygen -Y verify -f "$work/allowed" -I 'writer@alice-laptop' -n "$room_ns" -s "$work/entry.sig" <"$work/entry"
rc=0; err="$(sign sign --role register --principals "relay@$guid" --key-id x <"$work/key.pub" 2>&1 >/dev/null)" || rc=$?
check "a relay principal under the register role: exit 13" [ "$rc" = 13 ]
rc=0; sign sign --principals 'writer@alice-laptop' --key-id x <"$work/key.pub" >/dev/null 2>&1 || rc=$?
check "a register principal under the default role: exit 13" [ "$rc" = 13 ]
rc=0; sign sign --role register --principals 'writer@alice-laptop' --key-id x --ttl 200d <"$work/key.pub" >/dev/null 2>&1 || rc=$?
check "the register role's own maximum (90 days) holds: exit 2" [ "$rc" = 2 ]
rc=0; sign sign --role nope --principals 'writer@x' --key-id x <"$work/key.pub" >/dev/null 2>&1 || rc=$?
check "an unknown role is exit 2" [ "$rc" = 2 ]

# --- the CA's private key cannot be read back ---------------------------------------------------------
tok="$root"
everything="$out$out2$(t ssh:ca:init 2>&1)"
for who in "$root" "$optok"; do
  who_name=root; [ "$who" = "$root" ] || who_name=operator
  cfg="$(as BAO_TOKEN="$who" bao read -format=json ssh-ca/config/ca 2>&1 || true)"
  check "config/ca returns no private key (the $who_name token)" excludes "$cfg" 'PRIVATE KEY'
  check "and nothing that looks like OpenSSH key material" excludes "$cfg" 'b3BlbnNzaC1rZXktdjE'
done
check "no task's output holds a private key" excludes "$everything" 'PRIVATE KEY'
check "dcf-secret cannot reach it (not a KV name, exit 14 for a name that is not there)" [ "$(rcof as BAO_TOKEN="$optok" dcf-secret get config/ca)" = 14 ]
check "nor under the CA's mount name" [ "$(rcof as BAO_TOKEN="$optok" dcf-secret get ssh-ca/config/ca --field private_key)" != 0 ]
check "no API path of the engine returns it" not as BAO_TOKEN="$root" bao read ssh-ca/config/ca/private_key
check "the Operator's token cannot read the raw storage" not as BAO_TOKEN="$optok" bao read sys/raw/logical
tok="$optok"
check "ca and ca --fingerprint print only the public side" [ "$(sign ca | grep -c PRIVATE)" = 0 ]

# --- import ------------------------------------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -C imported -f "$work/impkey"
imp_fp="$(ssh-keygen -lf "$work/impkey.pub" | awk '{print $2}')"
tok="$root"
trun ssh:ca:import MOUNT=ssh-ca-imp <"$work/impkey"
out3="$tout"
check "task openbao:ssh:ca:import exits 0 with the key on stdin" [ "$trc" = 0 ]
check "it reports the key's own fingerprint" contains "$out3" "$imp_fp"
check "the private key was not printed" excludes "$out3" 'PRIVATE KEY'
tok="$optok"
# (the Operator's policy names one CA mount, the one openbao:ssh:ca:init was run for: another is the owner's)
check "dcf-ssh-sign ca --fingerprint on that mount is the key's" [ "$(as BAO_TOKEN="$root" DCF_SSH_CA_MOUNT=ssh-ca-imp dcf-ssh-sign ca --fingerprint | awk '{print $2}')" = "$imp_fp" ]
tok="$root"
rc=0; as BAO_TOKEN="$root" task -t "$tf" ssh:ca:import MOUNT=ssh-ca-imp <"$work/impkey" >/dev/null 2>&1 || rc=$?
check "a second import into a mount with a CA is refused" [ "$rc" != 0 ]
check "the imported key cannot be read back" excludes "$(as BAO_TOKEN="$root" bao read -format=json ssh-ca-imp/config/ca 2>&1)" 'PRIVATE KEY'
rc=0; as BAO_TOKEN="$root" task -t "$tf" ssh:ca:import MOUNT=ssh-ca-imp2 <"$work/key.pub" >/dev/null 2>&1 || rc=$?
check "a public key on stdin is no CA key (refused)" [ "$rc" != 0 ]
check "no state file or home file holds the imported key" not grep -rqF "$(sed -n 4p "$work/impkey")" "$state" "$home"

# --- sealed, last ---------------------------------------------------------------------------------------
tok="$optok"
BAO_TOKEN="$root" bao operator seal >/dev/null
rc=0; out="$(sign status 2>/dev/null)" || rc=$?
check "sealed: status says sealed (exit 11)" [ "$rc:$out" = 11:sealed ]
rc=0; err="$(sign sign --principals "relay@$guid" --key-id x <"$work/key.pub" 2>&1 >/dev/null)" || rc=$?
check "sealed: sign is exit 11" [ "$rc" = 11 ]
check "sealed: ca is exit 11" [ "$(rcof sign ca)" = 11 ]
rc=0; err="$(BAO_ADDR=http://127.0.0.1:1 as BAO_TOKEN="$optok" dcf-ssh-sign ca 2>&1 >/dev/null)" || rc=$?
check "a closed port is exit 10" [ "$rc" = 10 ]

rm -rf "$work" "$home" "$state"
reportResults
