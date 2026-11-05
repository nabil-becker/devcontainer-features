#!/usr/bin/env bash
# Docker-free tests of the OpenBao key file's container side (src/openbao/openbao-keyfile.sh, reached
# through openbao-setup unlock|keyfile|renew) against a stub curl that plays OpenBao's HTTP API with a
# small state (kf_curl_stub.sh). That the real bao gives the answers the stub plays is the container
# test test/openbao/server_keyfile.sh (CI), and was checked against a real bao 2.7.2 server while this
# was written. Covered:
#  - unlock --status: the mode (off in client mode, operator, keyfile), initialised, sealed, the token
#    (missing, live, dead), the renewer, ready, the cluster id (remembered for a sealed server); never
#    refused, exit 0, one JSON line on stdout;
#  - the refusal inside an agent's job for unlock --stdin, keyfile create and rotate: each of
#    DEVHOST_JOB_CHILD, CLAUDECODE and a variable named in OPENBAO_AGENT_JOB_VARS, exit 3, a JSON
#    line, and no request made; exit 4 in client mode and with unlock operator;
#  - the stdin protocol of unlock: not JSON, the wrong version, one share, a share that is not
#    base64, the same share twice, no role id: exit 1 and nothing sent; a good key file: unsealed by
#    sys/unseal (reset first), logged in, the previous token revoked with itself, the token saved
#    mode 600 through the token helper, the renewer started detached (the call returns at once with
#    its stdout a pipe); a key file of another server refused before any share is sent; shares the
#    server refuses and a refused login: exit 1, nothing saved;
#  - nothing secret leaves memory: no share, secret id or token in any argument of any request (the
#    token only in the curl config read from a pipe), and none in the state folder after a good and
#    after a failed unlock (but the token, in the token helper's file);
#  - BAO_ADDR, VAULT_ADDR and BAO_TOKEN in the environment ignored: every request goes to the
#    loopback listener of server.hcl and none carries the environment's token;
#  - the renewer: renews every third of the token's period, exits on the first refused renewal, on
#    a token already dead when it starts, and when the token is erased (task openbao:logout);
#  - keyfile create and rotate: two shares, a root token from the unauthenticated generate-root
#    endpoints (revoked after), the operator AppRole (1 hour periodic token, loopback only), its
#    earlier secret ids destroyed, the Operator's policy with the deny on its own role, rotate-keys
#    to 5 shares threshold 2, the userpass user deleted, earlier logins' tokens revoked, the other
#    roles reissued into files, the Operator logged in, the custody shares and the key file on
#    stdout in one JSON line; init:true on an empty server; a failed rotation leaves nothing
#    behind (the new secret id destroyed, the root token revoked) and prints no share;
#  - keyfile status; and openbao-server: task openbao:password and init refused with unlock keyfile,
#    server:status's unlock and renewer lines.
# Part of `task lint` (`task test:openbao-unit`). SCRIPT points the test at another copy of the
# script. Needs jq and setsid.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../../.."
script="${SCRIPT:-$root/src/openbao/openbao-keyfile.sh}"

if ! command -v jq >/dev/null 2>&1; then
  echo "skip - keyfile_test: jq is not installed"
  exit 0
fi

T="$(mktemp -d /tmp/obkf.XXXXXX)"
cleanup() {
  local p
  p="$(cat "$T/state/renewer.pid" 2>/dev/null)" && [ -n "$p" ] && kill -- "-$p" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/bin" "$T/feat" "$T/state" "$T/stub"
cp "$root/src/openbao/env.sh" "$root/src/openbao/openbao-lib.sh" "$T/feat/"
install -m 0755 "$script" "$T/bin/openbao-keyfile"
install -m 0755 "$root/src/openbao/openbao-setup.sh" "$T/bin/openbao-setup"
install -m 0755 "$root/src/openbao/openbao-server.sh" "$T/bin/openbao-server"
install -m 0755 "$root/src/openbao/openbao-token-helper.sh" "$T/bin/openbao-token-helper"
install -m 0755 "$here/kf_curl_stub.sh" "$T/bin/curl"
cat > "$T/bin/bao" <<'STUB'
#!/bin/bash
# only what openbao-server's status asks; the key file never calls bao
case "$1 $2" in
  "status -format=json") echo '{"initialized": true, "sealed": false}'; exit 0 ;;
  "token lookup") exit 0 ;;
esac
exit 0
STUB
chmod 0755 "$T/bin/bao"
S="$T/stub"
export STUB_DIR="$S" STUB_LOG="$T/calls.log"
port=18399
printf 'listener "tcp" {\n  address     = "127.0.0.1:%s"\n  tls_disable = true\n}\n' "$port" > "$T/state/server.hcl"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1${2:+ ($2)}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi; } # <name> <expected> <actual>
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "no '$2' in: $3"; fi; }
lacks() { if grep -qF -- "$2" <<<"$3"; then bad "$1" "'$2' found"; else ok "$1"; fi; }
jq_is() { check "$1" "$2" "$(jq -r "$3" <<<"$out" 2>/dev/null)"; } # <name> <expected> <filter on $out>

# reset <inited> <sealed>: a fresh stub server (cluster c-1111, the five shares S1..S5 valid, the
# operator AppRole's secret id SECRETID-0) and an empty state folder (its server.hcl kept)
reset() {
  stop_renewer
  rm -rf "${S:?}"/* "$T/calls.log"
  find "$T/state" -mindepth 1 ! -name server.hcl -exec rm -rf {} +
  echo "$1" > "$S/inited"
  echo "$2" > "$S/sealed"
  echo c-1111 > "$S/cluster"
  printf '%s\n' S1AAAAAA S2BBBBBB S3CCCCCC S4DDDDDD S5EEEEEE > "$S/shares"
  echo SECRETID-0 > "$S/sid"
  : > "$S/live"
}
stop_renewer() {
  local p
  p="$(cat "$T/state/renewer.pid" 2>/dev/null)" && [ -n "$p" ] && { kill -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null; }
  rm -f "$T/state/renewer.pid"
  sleep 0.2
}
# run [VAR=value ...] -- <openbao-setup arguments>: stdin from $in; out = stdout, err = stderr, rc
in='' out='' err='' rc=0
run() {
  local -a vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done
  shift
  out="$(printf '%s' "$in" | env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" OPENBAO_STATE_DIR="$T/state" OPENBAO_FEATURE_DIR="$T/feat" \
    STUB_DIR="$S" STUB_LOG="$T/calls.log" "${vars[@]}" timeout 20 "$T/bin/openbao-setup" "$@" 2>"$T/err")"
  rc=$?
  err="$(cat "$T/err")"
}
opts() { printf 'MODE=%s\nUNLOCK=%s\n' "$1" "$2" > "$T/feat/options.env"; } # <mode> <unlock>
keyfile_json() { # [server] [share] [share] [secret id]
  printf '{"v":1,"server":"%s","repo":"demo","created":"2026-11-05T00:00:00Z","shares":["%s","%s"],"role_id":"ROLEID-op1","secret_id":"%s"}' \
    "${1:-c-1111}" "${2:-S4DDDDDD}" "${3:-S5EEEEEE}" "${4:-SECRETID-0}"
}
one_line() { [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && jq -e . <<<"$out" >/dev/null 2>&1; }
no_calls() { [ ! -s "$T/calls.log" ]; }
secrets_in() { # <file or folder>: any share, secret id or token of the stub found there
  grep -rlaE 'S[1-5][A-E]{6}|NEW[1-5][A-E]{4}|INIT[1-5][A-E]{3}|SECRETID-[0-9]+|s\.LOGIN[0-9]+|s\.GENROOT|s\.OLDTOKEN|s\.ENVTOKEN' "$1" 2>/dev/null
}

# ------------------------------------------------------------------- unlock --status ----
reset true true
opts client operator
in='' run -- unlock --status
check "status in client mode: exit 0" 0 "$rc"
jq_is "status in client mode: mode off" off .mode
check "status in client mode: no request (no server to ask)" yes "$(no_calls && echo yes)"
opts server operator
run -- unlock --status
jq_is "status with unlock operator: mode operator" operator .mode
jq_is "  and not ready (ready is for keyfile mode only)" false .ready
opts server keyfile
run -- unlock --status
check "status, keyfile, sealed: exit 0" 0 "$rc"
check "  one JSON line on stdout" yes "$(one_line && echo yes)"
jq_is "  v 1" 1 .v
jq_is "  mode keyfile" keyfile .mode
jq_is "  initialised" true .initialized
jq_is "  sealed" true .sealed
jq_is "  token missing" missing .token
jq_is "  no renewer" false .renewer
jq_is "  not ready" false .ready
jq_is "  a sealed server tells no cluster id (none remembered yet)" "" .server
for v in DEVHOST_JOB_CHILD CLAUDECODE; do
  run "$v=1" -- unlock --status
  check "status is not refused inside an agent's job ($v)" 0 "$rc"
done
run OPENBAO_SETUP_UNLOCK=operator -- unlock --status
jq_is "OPENBAO_SETUP_UNLOCK overrides the option" operator .mode
opts server operator
run OPENBAO_SETUP_UNLOCK=keyfile -- unlock --status
jq_is "  both ways" keyfile .mode
opts server keyfile
echo true > "$S/down"
run -- unlock --status
check "status with the server down: exit 0 (it answered)" 0 "$rc"
jq_is "  sealed (nothing known)" true .sealed
rm -f "$S/down"

# ------------------------------------------------------------------- the refusals ----
for cmd in "unlock --stdin" "keyfile create --stdin" "keyfile rotate --stdin"; do
  for v in DEVHOST_JOB_CHILD CLAUDECODE "OPENBAO_AGENT_JOB_VARS=OTHER_AGENT OTHER_AGENT"; do
    reset true true
    in="$(keyfile_json)"
    # shellcheck disable=SC2086  # the variables split on purpose
    if [ "${v%% *}" = "OPENBAO_AGENT_JOB_VARS=OTHER_AGENT" ]; then run "${v%% *}" OTHER_AGENT=1 -- $cmd; else run "$v=1" -- $cmd; fi
    check "$cmd refused inside an agent's job (${v##* }): exit 3" 3 "$rc"
    jq_is "  the JSON says refused" refused .code
    check "  no request made" yes "$(no_calls && echo yes)"
  done
done
reset true true
opts client operator
in="$(keyfile_json)" run -- unlock --stdin
check "unlock --stdin in client mode: exit 4 (not applicable)" 4 "$rc"
opts server operator
run -- unlock --stdin
check "unlock --stdin with unlock operator: exit 4" 4 "$rc"
has "  it says the option is not keyfile" "not keyfile" "$err"
run -- keyfile create --stdin
check "keyfile create with unlock operator: exit 4" 4 "$rc"
check "  no request made" yes "$(no_calls && echo yes)"
opts server keyfile

# ------------------------------------------------------------- the stdin protocol ----
bad_input() { # <name> <input>
  reset true true
  in="$2" run -- unlock --stdin
  check "unlock refuses $1: exit 1" 1 "$rc"
  jq_is "  error input" input .code
  check "  nothing sent" yes "$(no_calls && echo yes)"
  check "  the plain reason is in error" yes "$(jq -e '.error | length > 10' <<<"$out" >/dev/null && echo yes)"
}
bad_input "what is not JSON" 'S4DDDDDD S5EEEEEE'
bad_input "another version" "$(keyfile_json | sed 's/"v":1/"v":2/')"
bad_input "one share" '{"v":1,"server":"c-1111","shares":["S4DDDDDD"],"role_id":"ROLEID-op1","secret_id":"SECRETID-0"}'
bad_input "a share that is not base64" "$(keyfile_json c-1111 'S4D"DDDDD')"
bad_input "the same share twice" "$(keyfile_json c-1111 S4DDDDDD S4DDDDDD)"
bad_input "no role id" '{"v":1,"server":"c-1111","shares":["S4DDDDDD","S5EEEEEE"],"secret_id":"SECRETID-0"}'
bad_input "no server" '{"v":1,"shares":["S4DDDDDD","S5EEEEEE"],"role_id":"ROLEID-op1","secret_id":"SECRETID-0"}'

# a good unlock, with a previous token saved and the environment pointing elsewhere
reset true true
echo 3 > "$S/period"
echo "s.OLDTOKEN 3" >> "$S/live"
printf 's.OLDTOKEN' > "$T/state/token"
in="$(keyfile_json)"
t0="$(date +%s)"
run BAO_ADDR=http://127.0.0.9:8200 VAULT_ADDR=http://127.0.0.9:8201 BAO_TOKEN=s.ENVTOKEN VAULT_TOKEN=s.ENVTOKEN -- unlock --stdin
t1="$(date +%s)"
check "unlock with a good key file: exit 0" 0 "$rc"
check "  one JSON line" yes "$(one_line && echo yes)"
jq_is "  ok" true .ok
jq_is "  done: unsealed, logged in" "unsealed, logged in" .done
check "  it returns at once with its stdout a pipe (the renewer is detached)" yes "$([ $((t1 - t0)) -le 5 ] && echo yes)"
check "  the server is unsealed" false "$(cat "$S/sealed")"
has "  the unseal progress was reset first" '{"reset":true}' "$(head -n 3 "$S/bodies.log")"
check "  the new token is saved through the token helper" s.LOGIN1 "$(cat "$T/state/token")"
check "  mode 600" 600 "$(stat -c %a "$T/state/token")"
has "  the previous token was revoked with itself (revoke-self)" "POST auth/token/revoke-self s.OLDTOKEN" "$(cat "$S/tokens.log")"
check "  the cluster id is remembered" c-1111 "$(cat "$T/state/cluster-id")"
sleep 0.5
rp="$(cat "$T/state/renewer.pid" 2>/dev/null)"
check "  the renewer runs" yes "$([ -n "$rp" ] && [ -d "/proc/$rp" ] && echo yes)"
check "  detached: its stdin, stdout and stderr are not the caller's pipe" yes "$(
  n=0; for fd in 0 1 2; do case "$(readlink "/proc/$rp/fd/$fd")" in pipe:*) n=1 ;; esac; done; [ "$n" = 0 ] && echo yes)"
check "  every request went to the listener of server.hcl" "" "$(grep -v "^http://127.0.0.1:$port/v1/" "$S/urls.log")"
lacks "  the environment's token was never sent" s.ENVTOKEN "$(cat "$S/tokens.log")"
check "  no share, secret id or token in any request's arguments" "" "$(secrets_in "$T/calls.log")"
check "  none in the state folder but the token helper's file" "$T/state/token" "$(secrets_in "$T/state")"
in='' run -- unlock --status
jq_is "status after unlock: unsealed" false .sealed
jq_is "  token live" live .token
jq_is "  renewer running" true .renewer
jq_is "  ready" true .ready
jq_is "  the cluster id" c-1111 .server
run -- keyfile status
jq_is "keyfile status: shares" 5 .shares
jq_is "  threshold" 2 .threshold

# the renewer: every third of the period (3s here), and it stops on the first refused renewal
sleep 2.5
check "the renewer renewed the token" yes "$([ -s "$S/renewals" ] && echo yes)"
lacks "  with the saved token in no argument" s.LOGIN1 "$(cat "$T/calls.log")"
touch "$S/renew_fail"
for _ in $(seq 1 30); do [ -d "/proc/$rp" ] || break; sleep 0.2; done
check "the renewer exits on a refused renewal" no "$([ -d "/proc/$rp" ] && echo yes || echo no)"
has "  and says so in renewer.log" "the renewer stops" "$(cat "$T/state/renewer.log")"
check "  its pid file is removed" no "$([ -e "$T/state/renewer.pid" ] && echo yes || echo no)"
in='' run -- unlock --status
jq_is "  status: renewer false" false .renewer
rm -f "$S/renew_fail"

# a renewer that finds the token dead at its start stops at once (the sleep longer than the period)
: > "$S/live"
in='' run -- renew
check "a renewer started with a dead token exits" 1 "$rc"
has "  saying the token is not valid" "not valid" "$out$err"
in='' run -- unlock --status
jq_is "  status: token dead" dead .token
jq_is "  not ready" false .ready

# the renewer stops when the token is erased (task openbao:logout)
reset true false
echo 3 > "$S/period"
in="$(keyfile_json)" run -- unlock --stdin
check "unlock of an unsealed server (only the login): exit 0" 0 "$rc"
lacks "  no share was sent" S4DDDDDD "$(cat "$S/bodies.log")"
sleep 0.5
rp="$(cat "$T/state/renewer.pid" 2>/dev/null)"
OPENBAO_STATE_DIR="$T/state" "$T/bin/openbao-token-helper" erase
for _ in $(seq 1 30); do [ -d "/proc/$rp" ] || break; sleep 0.2; done
check "the renewer exits once the token is erased (logout)" no "$([ -n "$rp" ] && [ -d "/proc/$rp" ] && echo yes || echo no)"

# a key file of another server: refused before any share is sent
reset true true
echo c-2222 > "$T/state/cluster-id"
in="$(keyfile_json c-1111)" run -- unlock --stdin
check "a key file of another server: exit 1" 1 "$rc"
jq_is "  error other-server" other-server .code
lacks "  no share was sent" S4DDDDDD "$(cat "$S/bodies.log" 2>/dev/null)"
check "  still sealed" true "$(cat "$S/sealed")"
# unsealed, the running cluster differs: the login is not sent
reset true false
in="$(keyfile_json c-9999)" run -- unlock --stdin
check "a key file whose server is not the running one: exit 1" 1 "$rc"
lacks "  the secret id was not sent" SECRETID-0 "$(cat "$S/bodies.log")"

# shares the server refuses (a key file of an earlier rotation): nothing saved, nothing left
reset true true
in="$(keyfile_json c-1111 OLD1AAAA OLD2BBBB)" run -- unlock --stdin
check "shares the server refuses: exit 1" 1 "$rc"
jq_is "  error shares-refused" shares-refused .code
check "  still sealed" true "$(cat "$S/sealed")"
check "  no token saved" no "$([ -e "$T/state/token" ] && echo yes || echo no)"
check "  no secret in the state folder" "" "$(secrets_in "$T/state")"
check "  none in any request's arguments" "" "$(secrets_in "$T/calls.log")"
# a refused login
reset true true
in="$(keyfile_json c-1111 S4DDDDDD S5EEEEEE SECRETID-77)" run -- unlock --stdin
check "a refused login: exit 1" 1 "$rc"
jq_is "  error login-refused" login-refused .code
check "  no token saved" no "$([ -e "$T/state/token" ] && echo yes || echo no)"
check "  no secret in the state folder" "" "$(secrets_in "$T/state")"

# not initialised
reset false true
in="$(keyfile_json)" run -- unlock --stdin
check "unlock of a server not initialised: exit 1" 1 "$rc"
has "  it names keyfile:create" "dc:openbao:keyfile:create" "$err"

# -------------------------------------------------------------- keyfile create / rotate ----
reset true true
printf '%s\n' S1AAAAAA S2BBBBBB S3CCCCCC > "$S/shares"
echo 3 > "$S/n"
echo ACC-operator-old > "$S/acc.operator"
echo ACC-scribe-old > "$S/acc.scribe"
in='{"v":1,"shares":["S1AAAAAA","S3CCCCCC"],"repo":"demo"}'
run BAO_ADDR=http://127.0.0.9:8200 BAO_TOKEN=s.ENVTOKEN -- keyfile create --stdin
check "keyfile create from two custody shares of a sealed 3-share store: exit 0" 0 "$rc"
check "  one JSON line" yes "$(one_line && echo yes)"
jq_is "  ok" true .ok
jq_is "  the server" c-1111 .server
jq_is "  three custody shares (1 to 3 of the five)" "NEW1AAAA NEW2BBBB NEW3CCCC" '.custody | join(" ")'
jq_is "  the key file holds shares 4 and 5" "NEW4DDDD NEW5EEEE" '.keyfile.shares | join(" ")'
jq_is "  the key file's server" c-1111 .keyfile.server
jq_is "  its repo" demo .keyfile.repo
jq_is "  its version" 1 .keyfile.v
jq_is "  the operator AppRole's role id" ROLEID-op1 .keyfile.role_id
jq_is "  its new secret id" "$(cat "$S/sid")" .keyfile.secret_id
check "  rotate-keys asked for 5 shares, threshold 2" yes "$(grep -q '"secret_shares":5,"secret_threshold":2' "$S/bodies.log" && echo yes)"
has "  the operator role: a 1 hour periodic token" '"token_period":"1h"' "$(cat "$S/role.operator")"
has "  bound to loopback" '"token_bound_cidrs":"127.0.0.1/32"' "$(cat "$S/role.operator")"
has "  secret ids bound to loopback" '"secret_id_bound_cidrs":"127.0.0.1/32"' "$(cat "$S/role.operator")"
has "  the Operator's policy denies its own role" 'auth/approle/role/operator/*' "$(jq -r .policy "$S/policy.operator")"
lacks "  every earlier operator secret id destroyed" ACC-operator-old "$(cat "$S/acc.operator")"
has "  the userpass user operator deleted" deleted "$(cat "$S/userpass.deleted" 2>/dev/null)"
has "  earlier password logins' tokens revoked" auth/userpass/login "$(cat "$S/revoked.prefix")"
has "  earlier AppRole logins' tokens revoked" auth/approle/login "$(cat "$S/revoked.prefix")"
check "  the scribe role reissued into its files" yes "$(grep -qxE 'SECRETID-[0-9]+' "$T/state/approle/scribe/secret_id" 2>/dev/null && echo yes)"
lacks "  its earlier secret id destroyed" ACC-scribe-old "$(cat "$S/acc.scribe")"
check "  the root token revoked" yes "$(grep -qx root "$S/revoked" && echo yes)"
check "  the Operator logged in with the new key file" s.LOGIN1 "$(cat "$T/state/token")"
lacks "  no share, secret id or token in any request's arguments" NEW "$(secrets_in "$T/calls.log")"
check "  none of them in the state folder (but the tokens' and the backs' files)" "" "$(secrets_in "$T/state" | grep -v -e "/token$" -e "/approle/")"
lacks "  the environment's token was never sent" s.ENVTOKEN "$(cat "$S/tokens.log")"
jq_is "  no backup destination: said" none .backup
has "  the warning names a backup" "backup" "$(jq -r '.warnings | join(" ")' <<<"$out")"
has "  the human lines say to keep the previous custody shares" "keep the previous ones" "$err"

# rotate from the key file's own shares, then init and a failing rotation
in='{"v":1,"shares":["NEW4DDDD","NEW5EEEE"],"repo":"demo"}'
run -- keyfile rotate --stdin
check "keyfile rotate from the key file's two shares: exit 0" 0 "$rc"
jq_is "  ok" true .ok
in='{"v":1,"init":true,"repo":"demo"}' run -- keyfile rotate --stdin
check "keyfile rotate refuses init: exit 1" 1 "$rc"
reset false true
in='{"v":1,"init":true,"repo":"demo"}' run -- keyfile create --stdin
check "keyfile create with init on an empty server: exit 0" 0 "$rc"
jq_is "  five shares made by init: custody 1 to 3" "INIT1AAA INIT2BBB INIT3CCC" '.custody | join(" ")'
jq_is "  key file 4 and 5" "INIT4DDD INIT5EEE" '.keyfile.shares | join(" ")'
check "  sys/init asked for 5 shares, threshold 2" yes "$(grep -q '"secret_shares":5,"secret_threshold":2' "$S/bodies.log" && echo yes)"
check "  the root token revoked" yes "$(grep -qx root "$S/revoked" && echo yes)"
in='{"v":1,"init":true,"repo":"demo"}' run -- keyfile create --stdin
check "init on a server already initialised: exit 1" 1 "$rc"
reset true false
in='{"v":1,"shares":["S1AAAAAA","S2BBBBBB"],"repo":"demo"}'
run STUB_ROTATE_FAIL=1 -- keyfile rotate --stdin
check "a failing rotation: exit 1" 1 "$rc"
jq_is "  ok false" false .ok
lacks "  no share printed" S1AAAAAA "$out"
check "  the new secret id destroyed again" "" "$(grep -v -e ACC-operator-old "$S/acc.operator" 2>/dev/null)"
check "  the root token revoked" yes "$(grep -qx root "$S/revoked" && echo yes)"
check "  the shares in force still hold" S1AAAAAA "$(head -n 1 "$S/shares")"
in='{"v":1,"shares":["X1AAAAAA","X2BBBBBB"],"repo":"demo"}' run -- keyfile rotate --stdin
check "rotate with shares the server refuses: exit 1" 1 "$rc"
check "  the root-token attempt is cancelled" yes "$([ -s "$S/gr.cancelled" ] || [ ! -e "$S/gr.attempt" ] && echo yes)"

# ------------------------------------------------------------- openbao-server, keyfile ----
reset true false
srv() { env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" OPENBAO_STATE_DIR="$T/state" OPENBAO_FEATURE_DIR="$T/feat" "$@" 2>&1; }
out="$(srv "$T/bin/openbao-server" password)"
rc=$?
check "task openbao:password with unlock keyfile: exit 3" 3 "$rc"
has "  it says so" "OpenBao key file" "$out"
out="$(srv "$T/bin/openbao-server" init)"
check "task openbao:init with unlock keyfile: refused" yes "$(grep -q 'dc:openbao:keyfile:create' <<<"$out" && echo yes)"
out="$(srv "$T/bin/openbao-server" status)"
has "server:status says the unlock mode" "unlock:   keyfile" "$out"
has "  and whether the renewer runs" "renewer:  not running" "$out"
opts server operator
out="$(srv "$T/bin/openbao-server" status)"
has "server:status with unlock operator says so" "unlock:   operator" "$out"
lacks "  and has no renewer line" "renewer:" "$out"

echo "keyfile_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
