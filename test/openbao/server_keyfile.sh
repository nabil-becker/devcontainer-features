#!/bin/bash
# Scenario 'server_keyfile' (see scenarios.json): the OpenBao key file's container side against the
# server this Feature runs (mode=server, unlock=keyfile, OpenBao 2.7.1), remoteUser=vscode, with the
# real bao: what the Docker-free test (test/openbao/unit/keyfile_test.sh) can only stub. The
# workstation's launcher is played by piping JSON into /usr/local/bin/openbao-setup, as it does.
#   - an init by the key file cancelled before its confirmation (the store emptied again);
#   - a store made the operator way (task openbao:init, 3 shares) moved to the key file in two steps
#     (Amendment 1): step 1 leaves the old shares in force (they unseal after a restart, which drops
#     the waiting rekey; its confirmation is then refused), a lost step 1 is replaced by a new one,
#     the confirmation makes 5 shares, threshold 2, the operator AppRole, no userpass user; confirm
#     again is ok; keyfile status's pending (Amendment 2) follows it all; a rotation cancelled with
#     a wrong nonce (refused) and its own (the key file in force stays);
#   - a restart: the server comes back sealed, unlock --stdin unseals it from the key file's two
#     shares through sys/unseal and logs in with the AppRole (a periodic, loopback-bound token, the
#     renewer started); the old 3-share set refused; the Operator's token cannot touch its own role;
#   - a rotation from the key file's own shares: the previous token and key file refused after it;
#   - "key file lost and token dead": two custody shares and no login make a new key file;
#   - the token across a stop longer than its period (the renewer suspended with SIGSTOP; why a wall
#     clock jump is not simulated is below): the renewer exits, status says dead, unlock brings it back;
#   - a restore into a key-file server after a machine loss: no password asked, the pointer to
#     task dc:openbao:keyfile:rotate, which then makes the restored store's key file;
#   - no share or secret id in the state volume; openbao:password and init refused; the agent refusal;
#     BAO_ADDR, VAULT_ADDR and BAO_TOKEN ignored.
set -e
trap '' PIPE
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

export BAO_ADDR=http://127.0.0.1:8200
unset BAO_TOKEN
state="$OPENBAO_STATE_DIR"
tf="${OPENBAO_TEST_TASKFILE:-/usr/local/share/go-task/includes.d/openbao.yml}"
t() { task -t "$tf" "$@"; }
work="$(mktemp -d)"
pw='correct horse battery staple'
export OPENBAO_BACKUP_TMP="$work/tmpfs" OPENBAO_MACHINE=testbox
mkdir -p "$OPENBAO_BACKUP_TMP" "$work/dest"
# a short period, so the stop longer than it takes seconds (the default is 1 hour)
export OPENBAO_KEYFILE_TOKEN_PERIOD=15s
setup=/usr/local/bin/openbao-setup

# term <command> <answer>...: as in backup_restore.sh (ENTER, SHARES, @<text> waits for <text>)
term() {
  local cmd="$1" a s1 s2 n_seen
  local -A seen=()
  shift
  rm -f "$work/fifo" "$work/screen" "$work/rc"
  mkfifo "$work/fifo"
  script -qefc "$cmd; echo \$? > $work/rc" "$work/screen" < "$work/fifo" > /dev/null 2>&1 &
  local spid=$!
  exec 3> "$work/fifo"
  sleep 1
  local sz0=-1 sz1=0 _w
  for _w in $(seq 1 30); do
    sz1="$(stat -c %s "$work/screen" 2>/dev/null || echo 0)"
    [ "$sz1" = "$sz0" ] && [ "$sz1" -gt 0 ] && break
    sz0="$sz1"
    sleep 1
  done
  for a in "$@"; do
    case "$a" in
      SHARES)
        for _ in $(seq 1 60); do grep -aq 'Press Enter' "$work/screen" && break; sleep 0.5; done
        s1="$(grep -a -m1 '^Unseal Key 1: ' "$work/screen" | sed 's/^Unseal Key 1: //' | tr -d '\r')"
        s2="$(grep -a -m1 '^Unseal Key 2: ' "$work/screen" | sed 's/^Unseal Key 2: //' | tr -d '\r')"
        grep -a '^Unseal Key [0-9]: ' "$work/screen" | sed 's/^Unseal Key [0-9]: //' | tr -d '\r' > "$work/shares3"
        printf '\n' >&3 2>/dev/null || true
        sleep 1
        printf '%s\n' "$s1" >&3 2>/dev/null || true
        sleep 1
        printf '%s\n' "$s2" >&3 2>/dev/null || true
        ;;
      ENTER) printf '\n' >&3 2>/dev/null || true ;;
      @*)
        n_seen="${seen[$a]:-0}"
        for _ in $(seq 1 120); do
          [ "$(grep -ac -- "${a#@}" "$work/screen" 2>/dev/null || true)" -gt "$n_seen" ] && break
          sleep 0.5
        done
        seen[$a]="$(grep -ac -- "${a#@}" "$work/screen" 2>/dev/null || true)"
        sleep 0.5
        continue
        ;;
      *) printf '%s\n' "$a" >&3 2>/dev/null || true ;;
    esac
    sleep "${TERM_DELAY:-1.2}"
  done
  sleep 1
  exec 3>&-
  wait "$spid" || true
  tr -d '\r' < "$work/screen" > "$work/screen.txt" || true
  term_rc="$(cat "$work/rc" 2>/dev/null || echo '?')"
}
not() { ! "$@"; }
contains() { grep -qF -- "$2" <<<"$1"; }
in_files() { grep -rlaF -- "$1" "$2" > /dev/null 2>&1; }
api() { curl -s --noproxy '*' "$BAO_ADDR/v1/$1"; } # <path>: an unauthenticated read
jf() { jq -r "$1" "$2"; } # <filter> <file>
status_is() { [ "$("$setup" unlock --status | jq -r "$1")" = "$2" ]; } # <filter> <value>
stop_server() {
  local pid
  pid="$(cat "$state/server.pid")"
  kill "$pid"
  for _ in $(seq 1 40); do [ -d "/proc/$pid" ] || break; sleep 0.25; done
}
restart() { stop_server; openbao-setup start > /dev/null; }
keyfile() { jq -c .keyfile "$1"; } # <create or rotate output>: the key file the launcher would keep
unlock_with() { "$setup" unlock --stdin > "$work/unlock.json" 2> "$work/unlock.err"; } # stdin: the key file
# step 1 and step 2 as the launcher runs them (Amendment 1): <create|rotate> <name>, the input on
# stdin; step 1's answer is $work/<name>.json, the confirmation's $work/<name>.confirm.json
confirm_input() { jq -c '{v: 1, server: .server, nonce: .nonce, shares: .keyfile.shares}' "$1"; }
two_step() {
  "$setup" keyfile "$1" --stdin > "$work/$2.json" 2> "$work/$2.err" || return $?
  confirm_input "$work/$2.json" | "$setup" keyfile confirm --stdin > "$work/$2.confirm.json" 2>> "$work/$2.err"
}
kstatus() { "$setup" keyfile status | jq -r "$1"; } # <filter>

# --- the start hook, keyfile mode -------------------------------------------------------------------
openbao-setup > "$work/setup.out"
check "post-create says unlock keyfile" grep -q 'unlock keyfile' "$work/setup.out"
openbao-setup start > "$work/start.out"
check "the start hook names keyfile:create for a server not initialised" grep -q 'dc:openbao:keyfile:create' "$work/start.out"
check "status answers: mode keyfile, not initialised" status_is '.mode + " " + (.initialized | tostring)' 'keyfile false'
check "openbao-keyfile is installed" test -x /usr/local/bin/openbao-keyfile
check "the option is baked" grep -qx 'UNLOCK=keyfile' /usr/local/share/openbao-feature/options.env
rc=0; out="$(t init 2>&1 < /dev/null)" || rc=$?
check "task openbao:init is refused with unlock keyfile, naming keyfile:create" contains "$out" 'dc:openbao:keyfile:create'

# --- an init by the key file, cancelled before its confirmation: the server is empty again ---------
rc=0; printf '{"v":1,"init":true,"repo":"demo"}' | "$setup" keyfile create --stdin > "$work/init.json" 2> /dev/null || rc=$?
check "keyfile create with init (step 1) exits 0" [ "$rc" = 0 ]
check "  pending, nonce init" [ "$(jf '"\(.pending) \(.nonce)"' "$work/init.json")" = "true init" ]
check "  keyfile status: pending init, 5 shares" [ "$(kstatus '"\(.pending) \(.shares)"')" = "init 5" ]
rc=0; printf '{"v":1,"server":"%s"}' "$(jf .server "$work/init.json")" | "$setup" keyfile cancel --stdin > /dev/null 2>&1 || rc=$?
check "keyfile cancel of that init exits 0" [ "$rc" = 0 ]
check "  the server is not initialised again" status_is .initialized false

# --- a store made the operator way (3 shares, a password), then moved to the key file ------------
term "OPENBAO_SETUP_UNLOCK=operator task -t $tf init" "$work/dest" "$pw" "$pw" SHARES
check "task openbao:init (unlock operator for it) exits 0" [ "$term_rc" = 0 ]
check "it made 3 shares" [ "$(wc -l < "$work/shares3")" = 3 ]
old1="$(sed -n 1p "$work/shares3")"
old2="$(sed -n 2p "$work/shares3")"
old3="$(sed -n 3p "$work/shares3")"
restart
check "after a restart the 3-share server is sealed" status_is .sealed true

# step 1 whose answer is "lost": the old shares still open the store until a confirmation
rc=0
printf '{"v":1,"shares":["%s","%s"],"repo":"demo"}' "$old1" "$old3" | "$setup" keyfile create --stdin > "$work/lost.json" 2> /dev/null || rc=$?
check "keyfile create step 1 exits 0, pending" [ "$rc:$(jf .pending "$work/lost.json")" = 0:true ]
check "  the shares in force are still 3 (verification pending)" [ "$(api sys/seal-status | jq -r .n)" = 3 ]
check "  keyfile status: pending is the verification nonce" [ "$(kstatus .pending)" = "$(jf '.nonce | split(":")[0]' "$work/lost.json")" ]
check "  no confirmation token in the volume" not in_files "$(jf '.nonce | split(":")[1]' "$work/lost.json")" "$state"
restart
check "  after a server restart the old shares still unseal" [ "$(curl -s -X PUT -d "{\"key\":\"$old1\"}" "$BAO_ADDR/v1/sys/unseal" > /dev/null; curl -s -X PUT -d "{\"key\":\"$old2\"}" "$BAO_ADDR/v1/sys/unseal" | jq -r .sealed)" = false ]
check "  keyfile status: the restart dropped it (pending empty, 3 shares)" [ "$(kstatus '"[\(.pending)] \(.shares)"')" = "[] 3" ]
rc=0; confirm_input "$work/lost.json" | "$setup" keyfile confirm --stdin > "$work/lost.confirm.json" 2> /dev/null || rc=$?
check "  its confirmation fails (not-confirmed), nothing changes" [ "$rc:$(jf .code "$work/lost.confirm.json"):$(api sys/seal-status | jq -r .n)" = 1:not-confirmed:3 ]
# step 1 lost while the server runs, then step 1 again: the waiting rekey is cancelled first
printf '{"v":1,"shares":["%s","%s"],"repo":"demo"}' "$old1" "$old3" | "$setup" keyfile create --stdin > "$work/lost2.json" 2> /dev/null
rc=0
printf '{"v":1,"shares":["%s","%s"],"repo":"demo"}' "$old1" "$old3" | two_step create create || rc=$?
check "keyfile create from two of the three shares, then confirm, exits 0" [ "$rc" = 0 ]
cid0="$(jf .server "$work/create.json")"
check "  confirm answered ok" [ "$(jf .ok "$work/create.confirm.json")" = true ]
check "  keyfile status: pending empty after the confirmation" [ "$(kstatus .pending)" = "" ]
rc=0; confirm_input "$work/lost2.json" | "$setup" keyfile confirm --stdin > /dev/null 2>&1 || rc=$?
check "  the lost step 1's confirmation is refused" [ "$rc" = 1 ]
rc=0; confirm_input "$work/create.json" | "$setup" keyfile confirm --stdin > "$work/again.json" 2> /dev/null || rc=$?
check "  confirm run again (a lost answer) is ok" [ "$rc:$(jf .ok "$work/again.json")" = 0:true ]
check "its stdout is one JSON line" [ "$(wc -l < "$work/create.json")" = 1 ]
check "ok" [ "$(jf .ok "$work/create.json")" = true ]
check "three custody shares and two in the key file" [ "$(jf '(.custody | length | tostring) + (.keyfile.shares | length | tostring)' "$work/create.json")" = 32 ]
check "the server now has 5 shares, threshold 2" [ "$(api sys/seal-status | jq -r '"\(.n)/\(.t)"')" = 5/2 ]
check "the key file names the running cluster" [ "$(jf .keyfile.server "$work/create.json")" = "$(api sys/seal-status | jq -r .cluster_id)" ]
check "a backup was taken under the new shares" test -s "$(jf .backup "$work/create.confirm.json")"
check "it says to keep the previous custody shares until those backups are pruned" grep -q 'keep the previous ones' "$work/create.err"
"$setup" keyfile status > "$work/kstatus.json"
check "keyfile status: the operator AppRole exists" [ "$(jf .approle "$work/kstatus.json")" = true ]
check "keyfile status: no userpass user operator" [ "$(jf .userpass "$work/kstatus.json")" = false ]
check "the Operator is logged in and ready" status_is .ready true
check "the renewer runs" status_is .renewer true
rc=0; printf '%s' "$pw" | bao login -no-store -method=userpass username=operator password=- > /dev/null 2>&1 || rc=$?
check "the password login is gone" [ "$rc" != 0 ]
check "dcf-secret works with the key file's login" bash -c "printf 'v1' | dcf-secret put kf/probe --field value && [ \"\$(dcf-secret get kf/probe --field value)\" = v1 ]"
check "the token is periodic (15s here, 1 hour by default) with no maximum" [ "$(bao token lookup -format=json | jq -r '"\(.data.period) \(.data.explicit_max_ttl)"')" = "15 0" ]
check "the token is bound to the loopback" [ "$(bao token lookup -format=json | jq -r '.data.bound_cidrs | join(",")')" = 127.0.0.1 ]
rc=0; bao read auth/approle/role/operator/role-id > /dev/null 2>&1 || rc=$?
check "the Operator's token cannot read its own role (denied)" [ "$rc" != 0 ]
rc=0; bao write -f auth/approle/role/operator/secret-id > /dev/null 2>&1 || rc=$?
check "the Operator's token cannot mint an operator secret id" [ "$rc" != 0 ]
check "the backs' backup role still works" [ "$(t backup DEST="$work/dest" > /dev/null 2>&1; echo $?)" = 0 ]

# --- a restart: unseal and log in from the key file -------------------------------------------------
restart
check "after a restart: sealed, not ready" status_is '(.sealed | tostring) + (.ready | tostring)' truefalse
check "a sealed server still tells its cluster id (remembered)" status_is .server "$(jf .server "$work/create.json")"
rc=0; keyfile "$work/create.json" | BAO_ADDR=http://127.0.0.1:1 VAULT_ADDR=http://127.0.0.1:1 BAO_TOKEN=s.nothing unlock_with || rc=$?
check "unlock --stdin from the key file exits 0 (BAO_ADDR, VAULT_ADDR, BAO_TOKEN ignored)" [ "$rc" = 0 ]
check "it says unsealed, logged in" [ "$(jf .done "$work/unlock.json")" = "unsealed, logged in" ]
check "ready" status_is .ready true
check "the store's data is there" [ "$(dcf-secret get kf/probe --field value)" = v1 ]

restart
rc=0; printf '{"v":1,"server":"%s","shares":["%s","%s"],"role_id":"%s","secret_id":"%s"}' \
  "$(jf .server "$work/create.json")" "$old1" "$old2" "$(jf .keyfile.role_id "$work/create.json")" "$(jf .keyfile.secret_id "$work/create.json")" | unlock_with || rc=$?
check "the old 3-share set is refused (exit 1)" [ "$rc" = 1 ]
check "  code shares-refused, the reason in error" [ "$(jf .code "$work/unlock.json")" = shares-refused ]
check "  still sealed" status_is .sealed true
keyfile "$work/create.json" | unlock_with
check "the key file opens it after that" status_is .ready true

rc=0; keyfile "$work/create.json" | CLAUDECODE=1 "$setup" unlock --stdin > /dev/null 2>&1 || rc=$?
check "unlock --stdin is refused inside an agent's job (exit 3)" [ "$rc" = 3 ]
rc=0; out="$(t password 2>&1 < /dev/null)" || rc=$?
check "task openbao:password refuses in keyfile mode" contains "$out" 'OpenBao key file'

# --- the token across a stop longer than its period -------------------------------------------------
# A suspended laptop cannot be played here: changing the container's wall clock needs CAP_SYS_TIME,
# which a test container does not have, and the server would need the same jump. Suspending the
# renewer (SIGSTOP) for longer than the period is the part that matters: the token expires on the
# server while nothing renews it.
for _ in $(seq 1 40); do grep -q 'renewing the Operator' "$state/renewer.log" 2>/dev/null && break; sleep 0.25; done
rp="$(cat "$state/renewer.pid")"
kill -STOP "$rp"
sleep 22
kill -CONT "$rp"
for _ in $(seq 1 60); do [ -d "/proc/$rp" ] || break; sleep 0.5; done
check "after a stop longer than the period the renewer exits" not test -d "/proc/$rp"
check "  and says the renewal was refused" grep -q 'refused the renewal' "$state/renewer.log"
check "  status: token dead, not ready" status_is '.token + " " + (.ready | tostring)' 'dead false'
keyfile "$work/create.json" | unlock_with
check "  unlock --stdin brings the login back (no typing)" status_is .ready true

# --- a rotation from the key file's own shares ------------------------------------------------------
# a rotation cancelled: a wrong nonce is refused, the right one cancels, the key file in force stays
printf '{"v":1,"shares":%s,"repo":"demo"}' "$(jq -c .keyfile.shares "$work/create.json")" | "$setup" keyfile rotate --stdin > "$work/cancelled.json" 2> /dev/null
check "keyfile rotate step 1: keyfile status pending, still 5 shares" [ "$(kstatus '"\(.pending) \(.shares)"')" = "$(jf '.nonce | split(":")[0]' "$work/cancelled.json") 5" ]
rc=0; printf '{"v":1,"server":"%s","nonce":"not-this-one"}' "$cid0" | "$setup" keyfile cancel --stdin > "$work/c.json" 2> /dev/null || rc=$?
check "  keyfile cancel with another nonce is refused (nonce-mismatch)" [ "$rc:$(jf .code "$work/c.json")" = 1:nonce-mismatch ]
rc=0; jq -c '{v: 1, server: .server, nonce: .nonce}' "$work/cancelled.json" | "$setup" keyfile cancel --stdin > /dev/null 2>&1 || rc=$?
check "  keyfile cancel with its nonce exits 0" [ "$rc" = 0 ]
check "  keyfile status: pending empty" [ "$(kstatus .pending)" = "" ]
restart
keyfile "$work/create.json" | unlock_with
check "  the key file in force still opens the server" status_is .ready true

before="$(cat "$state/token")"
rc=0
printf '{"v":1,"shares":%s,"repo":"demo"}' "$(jq -c .keyfile.shares "$work/create.json")" | two_step rotate rotate || rc=$?
check "keyfile rotate from the key file's shares, then confirm, exits 0" [ "$rc" = 0 ]
check "  all five shares are new" [ "$(jq -r '[.custody[], .keyfile.shares[]] | join(" ")' "$work/rotate.json" | tr ' ' '\n' | grep -cxFf <(jq -r '.custody[], .keyfile.shares[]' "$work/create.json") || true)" = 0 ]
check "  the previous Operator token is revoked" not env BAO_TOKEN="$before" bao token lookup
check "  ready with the new login" status_is .ready true
restart
rc=0; keyfile "$work/create.json" | unlock_with || rc=$?
check "the previous key file is refused after the rotation" [ "$rc" = 1 ]
jq -c --arg s "$(jf .keyfile.secret_id "$work/create.json")" '.keyfile | .secret_id = $s' "$work/rotate.json" > "$work/mixed.json"
rc=0; unlock_with < "$work/mixed.json" || rc=$?
check "the previous secret id is refused (its shares are the new ones)" [ "$(jf .code "$work/unlock.json")" = login-refused ]
keyfile "$work/rotate.json" | unlock_with
check "the new key file opens it" status_is .ready true

# --- key file lost and token dead: two custody shares, no login ------------------------------------
restart
rm -f "$state/token"
check "sealed and no token" status_is '(.sealed | tostring) + .token' truemissing
rc=0
printf '{"v":1,"shares":["%s","%s"],"repo":"demo"}' "$(jf '.custody[0]' "$work/rotate.json")" "$(jf '.custody[2]' "$work/rotate.json")" | two_step rotate recover || rc=$?
check "two custody shares make a new key file with no login (exit 0)" [ "$rc" = 0 ]
check "  ready again" status_is .ready true
check "  the data is there" [ "$(dcf-secret get kf/probe --field value)" = v1 ]

# --- no share at rest ---------------------------------------------------------------------------
leaks=0
for f in "$work/create.json" "$work/rotate.json" "$work/recover.json"; do
  while IFS= read -r sec; do
    in_files "$sec" "$state" && { leaks=1; echo "found in the volume: a value of $f" >&2; }
  done < <(jq -r '.custody[], .keyfile.shares[], .keyfile.secret_id' "$f")
done
for sec in "$old1" "$old2" "$old3"; do in_files "$sec" "$state" && leaks=1; done
check "no share or secret id anywhere in the state volume" [ "$leaks" = 0 ]
out="$(t server:status 2>&1)" || true
check "server:status shows unlock keyfile" contains "$out" 'unlock:   keyfile'
check "and the renewer" contains "$out" 'renewer:  running'

# --- a restore into a key-file server after a machine loss -----------------------------------------
t backup DEST="$work/dest" > /dev/null
snap="$(sed -n 's/^file=//p' "$state/last-backup")"
cid="$(jf .server "$work/recover.json")"
stop_server
rm -rf "${state:?}/raft" "$state/token" "$state/cluster-id" "$state/approle" "$state/last-backup"
openbao-setup start > /dev/null
check "the new machine's server is not initialised" status_is .initialized false
term "task -t $tf restore FROM=$snap" @'Unseal Key (will' "$(jf '.custody[1]' "$work/recover.json")" @'Unseal Key (will' "$(jf '.keyfile.shares[0]' "$work/recover.json")"
check "task openbao:restore into a keyfile server exits 0" [ "$term_rc" = 0 ]
check "  it asked for no password" not grep -q 'Password (will' "$work/screen.txt"
check "  it ends with the pointer to task dc:openbao:keyfile:rotate" grep -q 'dc:openbao:keyfile:rotate' "$work/screen.txt"
check "  the restored store keeps its cluster id" status_is .server "$cid"
rc=0
printf '{"v":1,"shares":["%s","%s"],"repo":"demo"}' "$(jf '.custody[0]' "$work/recover.json")" "$(jf '.keyfile.shares[1]' "$work/recover.json")" | two_step rotate restored || rc=$?
check "keyfile rotate makes the restored store's key file (exit 0)" [ "$rc" = 0 ]
check "  ready" status_is .ready true
check "  the backup role's files are back (reissued)" test -s "$state/approle/backup/secret_id"
check "  the data of the backup is there" [ "$(dcf-secret get kf/probe --field value)" = v1 ]

reportResults
