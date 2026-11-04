#!/bin/bash
# Scenario 'onboarding' (see scenarios.json): onboarding with the real bao (mode=server, OpenBao
# 2.7.1), remoteUser=vscode: what the Docker-free tests (test/openbao/unit/onboard_test.sh) can only
# stub. A terminal is played with script(1), whose output file is the person's screen.
#   - export: a second server in the same container, the named secrets copied (every field), the
#     snapshot in DEST (mode 600, never overwritten), the instance stopped and its folder gone, the
#     fresh shares and the claim token on the screen only;
#   - the receiver: the server wiped, a throwaway init, the snapshot restored by hand (the restore
#     task is the backup-and-restore slice's), unsealed with the sender's fresh shares;
#   - claim: with things the sender held (a user, an AppRole role and secret id, a token, another
#     auth method) put into the restored store first: every one fails afterwards, the roles are
#     rebuilt with one new secret id, the Operator is the receiver's, the marker is replaced, the
#     claim token is revoked, the old shares no longer open the server and the new ones do;
#   - wrap and unwrap between this server (the issuer) and a dev server (the receiver's store): the
#     TTL default and cap, the lookup and the creation-path refusal, a token used once failing the
#     second time, an expired one, a token for a different secret refused with nothing spent.
# OB_PORT (default 8200) moves the server for a run outside the Feature's container: the script
# then writes the server's config itself, which the start hook leaves alone.
# shellcheck disable=SC2016,SC2034  # the multi-part checks are single-quoted on purpose (ev evaluates them), so the variables they use look unused
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

port="${OB_PORT:-8200}"
export BAO_ADDR="http://127.0.0.1:$port"
unset BAO_TOKEN
state="$OPENBAO_STATE_DIR"
tf="${OPENBAO_TEST_TASKFILE:-/usr/local/share/go-task/includes.d/openbao.yml}"
t() { task -x -t "$tf" "$@"; } # -x: the exit code of the failed command, not task's 201
work="$(mktemp -d)"
dest="$(mktemp -d)"
pw='correct horse battery staple'
pw2='a different long password'
recv_port="${OB_RECV_PORT:-18200}"

if [ "$port" != 8200 ]; then
  mkdir -p "$state"
  cat > "$state/server.hcl" <<HCL
# written by the test, no marker line: the start hook leaves it alone
ui = false
api_addr = "$BAO_ADDR"
cluster_addr = "http://127.0.0.1:$((port + 1))"
storage "raft" {
  path    = "$state/raft"
  node_id = "devhost"
}
listener "tcp" {
  address         = "127.0.0.1:$port"
  cluster_address = "127.0.0.1:$((port + 1))"
  tls_disable     = true
}
HCL
fi

# term <command> <answer>...: the command under a pseudo-terminal, typing the answers one by one
# (ENTER is an empty line; SHARES reads two of three shares off the screen when init asks to press
# Enter and types them back; NEWSHARES reads the claim's new shares off the screen, as the person
# would, and types two back when asked); the screen is $work/screen.txt, the exit code $term_rc.
term() {
  local cmd="$1" a s1 s2
  shift
  rm -f "$work/fifo" "$work/screen" "$work/rc"
  mkfifo "$work/fifo"
  script -qefc "$cmd; echo \$? > $work/rc" "$work/screen" < "$work/fifo" > /dev/null 2>&1 &
  local spid=$!
  exec 3> "$work/fifo"
  sleep 1
  for a in "$@"; do
    case "$a" in
      SHARES)
        for _ in $(seq 1 60); do grep -aq 'Press Enter' "$work/screen" && break; sleep 0.5; done
        s1="$(grep -a -m1 '^Unseal Key 1: ' "$work/screen" | sed 's/^Unseal Key 1: //' | tr -d '\r')"
        s2="$(grep -a -m1 '^Unseal Key 2: ' "$work/screen" | sed 's/^Unseal Key 2: //' | tr -d '\r')"
        printf '%s\n' "$s1" "$s2" > "$work/shares"
        printf '\n' >&3
        sleep 1
        printf '%s\n' "$s1" >&3
        sleep 1
        printf '%s\n' "$s2" >&3
        ;;
      NEWSHARES)
        for _ in $(seq 1 120); do grep -aq 'Type new unseal share 1' "$work/screen" && break; sleep 0.5; done
        grep -a '^Unseal Key [123]: ' "$work/screen" | sed 's/^Unseal Key [123]: //' | tr -d '\r' > "$work/new.shares"
        printf '%s\n' "$(sed -n 1p "$work/new.shares")" >&3
        sleep 1
        printf '%s\n' "$(sed -n 2p "$work/new.shares")" >&3
        ;;
      ENTER) printf '\n' >&3 ;;
      *) printf '%s\n' "$a" >&3 ;;
    esac
    sleep 0.8
  done
  sleep 1.5
  exec 3>&-
  wait "$spid" || true
  tr -d '\r' < "$work/screen" > "$work/screen.txt" || true
  term_rc="$(cat "$work/rc" 2>/dev/null || echo '?')"
}
not() { ! "$@"; }
ev() { eval "$*"; } # a check made of several tests
contains() { grep -qF -- "$2" <<<"$1"; } # <text> <needle>
excludes() { ! grep -qF -- "$2" <<<"$1"; }
in_files() { grep -rlaF -- "$1" "$2" > /dev/null 2>&1; } # <needle> <folder>: found in any file
refused() { [ "$1" != 0 ] && contains "$2" "refuses to run inside an agent's job"; } # <rc> <output>
unsealed() { [ "$(openbao-run bao status -format=json | grep -c '"sealed": false')" = 1 ]; }
bao_alive() { alive_pid="$(cat "$state/server.pid" 2>/dev/null)"; [ -n "$alive_pid" ] && [ "$(cat "/proc/$alive_pid/comm" 2>/dev/null)" = bao ]; }
stop_main() {
  bao_alive && kill "$alive_pid"
  for _ in $(seq 1 40); do bao_alive || break; sleep 0.25; done
}
dev_pid=""
cleanup() { [ -z "$dev_pid" ] || kill "$dev_pid" 2>/dev/null || true; bao_alive && kill "$alive_pid" 2>/dev/null || true; }
trap cleanup EXIT

# --- the sender: init, login, the keys ------------------------------------------------------------
openbao-setup > /dev/null
openbao-setup start
term "task -t $tf init" "no backup" "$pw" "$pw" SHARES
check "init exits 0" [ "$term_rc" = 0 ]
cp "$work/shares" "$work/sender.shares"
term "task -t $tf login -- -method=userpass username=operator" "$pw"
check "the sender is logged in" [ "$(dcf-secret status)" = ready ]
printf 'abc def' | dcf-secret put ssh/key --field private_key
printf 'one' | dcf-secret put shared/multi --field a
printf 'two' | dcf-secret put shared/multi --field b
printf 'mine alone' | dcf-secret put own/private --field value

# --- the refusals ------------------------------------------------------------------------------------
# shellcheck disable=SC2086  # $tk is a task name and its variables: words
for tk in "onboard:export NAMES=ssh/key DEST=$dest" "onboard:claim" "wrap NAMES=ssh/key" "unwrap FROM=$work/none"; do
  for v in DEVHOST_JOB_CHILD CLAUDECODE; do
    rc=0; out="$(env "$v=1" task -t "$tf" ${tk} 2>&1 < /dev/null)" || rc=$?
    check "task openbao:${tk%% *} refuses inside an agent's job ($v)" refused "$rc" "$out"
  done
done
rc=0; out="$(t onboard:export NAMES=ssh/key DEST="$dest" 2>&1 < /dev/null)" || rc=$?
check "export without a terminal is refused" [ "$rc" != 0 ]
check "and says it needs a terminal" contains "$out" 'needs a terminal'
rc=0; out="$(t onboard:claim 2>&1 < /dev/null)" || rc=$?
check "claim without a terminal is refused" ev '[ "$rc" != 0 ] && contains "$out" '\''needs a terminal'\'''
rc=0; out="$(t wrap NAMES=ssh/key SHOW=1 OUT="$work/x" 2>&1 < /dev/null)" || rc=$?
check "wrap with SHOW=1 without a terminal is refused" ev '[ "$rc" != 0 ] && contains "$out" '\''needs a terminal'\'''
check "none of them wrote anything" ev '[ -z "$(ls -A "$dest")" ] && [ ! -e "$work/x" ]'

# --- export ------------------------------------------------------------------------------------------
term "task -t $tf onboard:export NAMES=nothing/here DEST=$dest"
check "export of a secret that is not there fails" [ "$term_rc" != 0 ]
check "and leaves nothing in DEST and no instance folder" ev '[ -z "$(ls -A "$dest")" ] && [ ! -e "$state/onboarding" ]'
term "task -t $tf onboard:export NAMES=ssh/key,shared/multi DEST=$dest" ENTER
check "export exits 0" [ "$term_rc" = 0 ]
snap="$(ls "$dest"/onboarding-*.snap)"
check "one snapshot, named onboarding-<machine>-<time>.snap, mode 600" ev '[ "$(ls "$dest"/onboarding-*.snap | wc -l)" = 1 ] && [ "$(stat -c %a "$snap")" = 600 ]'
check "the screen shows 3 fresh shares and a claim token" ev '[ "$(grep -c '\''^Unseal Key [0-9]: '\'' "$work/screen.txt")" = 3 ] && grep -q '\''^Claim token: '\'' "$work/screen.txt"'
grep -a '^Unseal Key [123]: ' "$work/screen.txt" | sed 's/^Unseal Key [123]: //' > "$work/export.shares"
claim_tok="$(sed -n 's/^Claim token: //p' "$work/screen.txt" | tr -d '\r')"
printf '%s' "$claim_tok" > "$work/claim.tok"
check "they are not the sender's own shares" not grep -qxFf "$work/sender.shares" "$work/export.shares"
check "neither a share nor the token is in any file of the volume" not in_files "$(sed -n 1p "$work/export.shares")" "$state"
check "the token is not in the volume either" not in_files "$claim_tok" "$state"
check "the instance is gone: its folder deleted" test ! -e "$state/onboarding"
check "and nothing listens on its port" not bash -c "(exec 3<>/dev/tcp/127.0.0.1/${OPENBAO_ONBOARD_PORT:-8210}) 2>/dev/null"
check "the sender's own server is untouched and unsealed" unsealed
check "the snapshot holds no value in clear" not grep -qaF 'abc def' "$snap"
sleep 1.2
term "task -t $tf onboard:export NAMES=ssh/key DEST=$dest" ENTER
check "a second export writes a second file, the first is not overwritten" ev '[ "$(ls "$dest"/onboarding-*.snap | wc -l)" = 2 ] && [ -f "$snap" ]'
check "the temporary folder of the export is empty or gone" [ ! -e "$state/onboarding" ]

# --- the receiver: a fresh server with the snapshot restored (by hand) ---------------------------------
stop_main
rm -rf "$state/raft" "$state/token" "$state/approle"
openbao-setup start
init="$(bao operator init -key-shares=1 -key-threshold=1 -format=json)"
printf '%s' "$init" | jq -r '.unseal_keys_b64[0]' | bao write sys/unseal key=- > /dev/null
sleep 3
BAO_TOKEN="$(printf '%s' "$init" | jq -r .root_token)" bao operator raft snapshot restore -force "$snap"
sleep 6
check "a restored server is sealed (it needs the snapshot's shares)" [ "$(dcf-secret status 2>/dev/null)" = sealed ]
term "task -t $tf unseal" "$(sed -n 1p "$work/export.shares")" "$(sed -n 2p "$work/export.shares")"
check "the fresh shares unseal it" ev '[ "$term_rc" = 0 ] && unsealed'
sleep 2

# what the sender held in the store, made with the claim token (a token that came in the snapshot)
C="$claim_tok"
cb() { BAO_TOKEN="$C" bao "$@"; }
cb auth enable userpass > /dev/null
printf 'sender-password-1' | cb write auth/userpass/users/sender password=- token_policies=default > /dev/null
cb auth enable approle > /dev/null
cb auth enable jwt > /dev/null
printf 'path "dcf/data/ssh/key" {\n capabilities = ["read"]\n}\n' | cb policy write approle-keyreader - > /dev/null
printf 'path "sys/*" {\n capabilities = ["read"]\n}\n' | cb policy write sender-extra - > /dev/null
cb write auth/approle/role/keyreader token_policies=approle-keyreader secret_id_ttl=0 > /dev/null
old_sid="$(cb write -f -field=secret_id auth/approle/role/keyreader/secret-id)"
old_rid="$(cb read -field=role_id auth/approle/role/keyreader/role-id)"
sender_tok="$(printf 'sender-password-1' | bao write -field=token auth/userpass/login/sender password=-)"
child_tok="$(cb token create -policy=default -ttl=1h -field=token)"
sender_login() { printf 'sender-password-1' | bao write -field=token auth/userpass/login/sender password=- > /dev/null 2>&1; }
approle_login() { bao write -field=token auth/approle/login role_id="$old_rid" secret_id="$old_sid" > /dev/null 2>&1; }
valid() { BAO_TOKEN="$1" bao token lookup > /dev/null 2>&1; }
check "before the claim the sender's login, secret id, tokens and the claim token all work" ev 'sender_login && approle_login && valid "$sender_tok" && valid "$child_tok" && valid "$C"'

# --- claim --------------------------------------------------------------------------------------------
term "task -t $tf onboard:claim" "$C" "$pw2" "$pw2" "$(sed -n 1p "$work/export.shares")" "$(sed -n 2p "$work/export.shares")" NEWSHARES
check "claim exits 0" [ "$term_rc" = 0 ]
cp "$work/screen.txt" "$work/claim.screen"
screen="$(cat "$work/screen.txt")"
check "the claim token is not echoed on the screen" excludes "$screen" "$C"
check "nor the sender's shares, nor the password" excludes "$screen" "$(sed -n 1p "$work/export.shares")"
check "the new shares are 3 and not the sender's" ev '[ "$(wc -l < "$work/new.shares")" = 3 ] && not grep -qxFf "$work/export.shares" "$work/new.shares"'
check "the claim token is revoked" not valid "$C"
check "a token the sender's login made is revoked" not valid "$sender_tok"
check "a token created by the claim token's session is revoked" not valid "$child_tok"
check "the sender's user is gone: its login fails" not sender_login
check "the sender's secret id no longer logs in" not approle_login
check "the other auth method (jwt) was disabled" contains "$screen" "auth method 'jwt/' disabled"
check "the policy that was not the Feature's is named for the receiver to read" contains "$screen" "policy 'sender-extra' came with the snapshot"
check "the screen lists the names that came, as the sender's knowledge" ev 'contains "$screen" '\''ssh/key'\'' && contains "$screen" '\''shared/multi'\'''
check "and does not list the marker or a name the sender never sent" ev 'excludes "$screen" '\''onboarding/marker'\'' && excludes "$screen" '\''own/private'\'''
check "the data key was rotated" contains "$screen" 'data key is rotated'
check "the resume file is gone" test ! -e "$state/onboarding-claim-state"
check "the AppRole role was written again and has a new secret id in the volume (mode 600)" ev '[ "$(stat -c %a "$state/approle/keyreader/secret_id")" = 600 ] && [ "$(cat "$state/approle/keyreader/secret_id")" != "$old_sid" ]'
term "task -t $tf login -- -method=userpass username=operator" "$pw2"
check "the receiver's own password logs in" [ "$(dcf-secret status)" = ready ]
check "the sender's own password for operator does not (it was the sender's: another password)" not bash -c "printf '%s' '$pw' | bao write auth/userpass/login/operator password=- > /dev/null 2>&1"
check "the keys came across, every field" ev '[ "$(dcf-secret get ssh/key --field private_key)" = '\''abc def'\'' ] && [ "$(dcf-secret get shared/multi --field a)" = one ] && [ "$(dcf-secret get shared/multi --field b)" = two ]'
check "a key that was not named did not" not dcf-secret get own/private
check "the onboarding marker is gone and the claim record is there" ev 'not dcf-secret get onboarding/marker --field machine && [ -n "$(dcf-secret get onboarding/claimed --field claimed_at)" ]'
new_login="$(bao write -format=json auth/approle/login role_id="$(cat "$state/approle/keyreader/role_id")" secret_id="$(cat "$state/approle/keyreader/secret_id")")"
check "the rebuilt role logs in with its new secret id, keeps its policy, and its tokens are loopback-bound" ev '[ "$(jq -r ".auth.token_policies | index(\"approle-keyreader\") != null" <<<"$new_login")" = true ] && [ "$(BAO_TOKEN="$(jq -r .auth.client_token <<<"$new_login")" bao token lookup -format=json | jq -r ".data.bound_cidrs[0]")" = 127.0.0.1 ]'
term "task -t $tf onboard:claim" "$C"
check "a second claim is refused (the token is dead)" ev '[ "$term_rc" != 0 ] && grep -q '\''not valid on this server'\'' "$work/screen.txt"'

# the old shares stop opening this server: restart it
stop_main
openbao-setup start > /dev/null
term "task -t $tf unseal" "$(sed -n 1p "$work/export.shares")" "$(sed -n 2p "$work/export.shares")"
check "after rotate-keys the sender's shares no longer unseal the restarted server" ev '[ "$term_rc" != 0 ] && [ "$(dcf-secret status 2>/dev/null)" = sealed ]'
bao write sys/unseal reset=true > /dev/null 2>&1 || bao operator unseal -reset > /dev/null 2>&1 || true
term "task -t $tf unseal" "$(sed -n 1p "$work/new.shares")" "$(sed -n 3p "$work/new.shares")"
check "the new shares do" ev '[ "$term_rc" = 0 ] && unsealed'
sleep 2
check "and the receiver's data is there, under the saved login" [ "$(dcf-secret get ssh/key --field private_key)" = 'abc def' ]

# --- wrap and unwrap ---------------------------------------------------------------------------------------
# the issuer is this server (the receiver of the snapshot is now the owner of a store of its own);
# the receiving store is a dev server with a dcf mount and a token of its own (-dev-no-store-token:
# a dev server otherwise overwrites the saved login in the volume)
recv_addr="http://127.0.0.1:$recv_port"
bao server -dev -dev-no-store-token -dev-root-token-id=recv-root -dev-listen-address="127.0.0.1:$recv_port" > "$work/dev.log" 2>&1 &
dev_pid=$!
for _ in $(seq 1 60); do BAO_ADDR="$recv_addr" bao status > /dev/null 2>&1 && break; sleep 0.5; done
BAO_ADDR="$recv_addr" BAO_TOKEN=recv-root bao secrets enable -path=dcf -version=2 kv > /dev/null
as_recv() { env BAO_ADDR="$recv_addr" BAO_TOKEN=recv-root "$@"; }
lookup() { printf '%s' "$1" | BAO_TOKEN="$1" bao write -format=json sys/wrapping/lookup token=- 2>/dev/null; }

rc=0; out="$(t wrap NAMES=ssh/key TTL=2h OUT="$work/w0.txt" 2>&1)" || rc=$?
check "a TTL over the 1 hour cap is refused (exit 2) and writes nothing" ev '[ "$rc" = 2 ] && [ ! -e "$work/w0.txt" ] && contains "$out" '\''cap of 1 hour'\'''
rc=0; out="$(t wrap NAMES=ssh/key TTL=soon OUT="$work/w0.txt" 2>&1)" || rc=$?
check "a TTL that is not a duration is refused" [ "$rc" = 2 ]
rc=0; out="$(t wrap NAMES=own/missing OUT="$work/w0.txt" 2>&1)" || rc=$?
check "a secret that is not there is refused with dcf-secret's code (14)" ev '[ "$rc" = 14 ] && [ ! -e "$work/w0.txt" ]'
rc=0; out="$(t wrap NAMES=ssh/key,shared/multi OUT="$work/w1.txt" 2>&1)" || rc=$?
[ "$rc" = 0 ] || echo "wrap said: $out" >&2
check "wrap exits 0 and prints the file and the expiry, not a token" ev '[ "$rc" = 0 ] && contains "$out" "$work/w1.txt" && contains "$out" '\''expires'\'''
check "the token file is mode 600 with one line per secret" ev '[ "$(stat -c %a "$work/w1.txt")" = 600 ] && [ "$(wc -l < "$work/w1.txt")" = 2 ]'
tok1="$(sed -n 's/^ssh\/key //p' "$work/w1.txt")"
check "the output shows no token" excludes "$out" "$tok1"
check "the default TTL is 15 minutes (900)" [ "$(lookup "$tok1" | jq -r .data.creation_ttl)" = 900 ]
check "and the creation path is the secret's own" [ "$(lookup "$tok1" | jq -r .data.creation_path)" = dcf/data/ssh/key ]
t wrap NAMES=shared/multi TTL=30m OUT="$work/w2.txt" > /dev/null 2>&1
check "TTL=30m gives 1800" [ "$(lookup "$(cut -d' ' -f2 "$work/w2.txt")" | jq -r .data.creation_ttl)" = 1800 ]

rc=0; out="$(as_recv env task -x -t "$tf" unwrap FROM="$work/w1.txt" ISSUER_ADDR="$BAO_ADDR" 2>&1 < /dev/null)" || rc=$?
check "unwrap exits 0" [ "$rc" = 0 ]
check "the receiver's own store holds the values, every field" ev '[ "$(as_recv dcf-secret get ssh/key --field private_key)" = '\''abc def'\'' ] && [ "$(as_recv dcf-secret get shared/multi --field b)" = two ]'
check "nothing was put on the issuer's side by it" [ "$(dcf-secret get shared/multi --field a)" = one ]
check "the unwrap printed no value or token" ev 'excludes "$out" '\''abc def'\'' && excludes "$out" "$tok1"'
rc=0; out="$(as_recv task -x -t "$tf" unwrap FROM="$work/w1.txt" ISSUER_ADDR="$BAO_ADDR" 2>&1 < /dev/null)" || rc=$?
check "a token used once fails the second time (exit 3, do not unwrap)" ev '[ "$rc" = 3 ] && contains "$out" '\''do not unwrap; ask the sender'\'''

# a token for a different secret under a name: refused, and the others in the file are not spent
t wrap NAMES=ssh/key,shared/multi OUT="$work/w3.txt" > /dev/null 2>&1
{ echo "shared/multi $(sed -n 's/^ssh\/key //p' "$work/w3.txt")"; sed -n '/^shared\/multi /p' "$work/w3.txt" | sed 's#^shared/multi #ssh/key #'; } > "$work/w3x.txt"
rc=0; out="$(as_recv task -x -t "$tf" unwrap FROM="$work/w3x.txt" ISSUER_ADDR="$BAO_ADDR" 2>&1 < /dev/null)" || rc=$?
check "tokens under the wrong names are refused (exit 3) with the creation path said" ev '[ "$rc" = 3 ] && contains "$out" '\''was made by a read of'\'''
printf 'pre' | as_recv dcf-secret put shared/multi --field marker
rc=0; out="$(as_recv task -x -t "$tf" unwrap FROM="$work/w3.txt" ISSUER_ADDR="$BAO_ADDR" 2>&1 < /dev/null)" || rc=$?
check "the refusal spent nothing: the right file still unwraps afterwards" [ "$rc" = 0 ]
# a token that was made by sys/wrapping/wrap, not by a read of the secret
forged="$(bao write -wrap-ttl=5m -format=json sys/wrapping/wrap value=planted | jq -r .wrap_info.token)"
echo "ssh/key $forged" > "$work/w4.txt"
rc=0; out="$(as_recv task -x -t "$tf" unwrap FROM="$work/w4.txt" ISSUER_ADDR="$BAO_ADDR" 2>&1 < /dev/null)" || rc=$?
check "a token made by sys/wrapping/wrap is refused by its creation path" ev '[ "$rc" = 3 ] && contains "$out" '\''was made by a read of'\'''
check "and its value was not put" [ "$(as_recv dcf-secret get ssh/key --field private_key)" = 'abc def' ]
# an expired one
t wrap NAMES=ssh/key TTL=2 OUT="$work/w5.txt" > /dev/null 2>&1
sleep 3.5
rc=0; out="$(as_recv task -x -t "$tf" unwrap FROM="$work/w5.txt" ISSUER_ADDR="$BAO_ADDR" 2>&1 < /dev/null)" || rc=$?
check "an expired token is refused (exit 3)" ev '[ "$rc" = 3 ] && contains "$out" '\''do not unwrap'\'''

rm -rf "$work" "$dest"
reportResults
