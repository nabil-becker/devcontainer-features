#!/usr/bin/env bash
# Docker-free tests of openbao-onboard (src/openbao/openbao-onboard.sh), what the onboarding tasks
# run (openbao:onboard:export, :onboard:claim, openbao:wrap, openbao:unwrap), against a stub `bao`
# that logs every call with the token it was given and answers wrapping calls from a small state,
# and a stub `dcf-secret`. That the real bao gives the answers the stub plays is the container test
# test/openbao/onboarding.sh (CI), and was run against a real bao 2.7.2 while this was written.
# Covered:
#  - the refusal inside an agent's job for EVERY task that handles a share or a token (export, claim,
#    wrap, unwrap): each of DEVHOST_JOB_CHILD, CLAUDECODE and a variable named in
#    OPENBAO_AGENT_JOB_VARS, directly and through the Taskfile, and never a call to bao; the refusal
#    without a terminal (export, claim, a prompted unwrap, wrap with SHOW=1); claim in client mode;
#  - wrap: the TTL default (15 minutes), the cap (1 hour) and what is not a duration; one wrapping
#    token per secret, asked of bao with -wrap-ttl; the tokens in a mode 600 file and never on stdout;
#    a name under onboarding/ and a bad name refused; an existing OUT never overwritten;
#  - unwrap: every token looked up (with the wrapping token as the call's own token, so no saved
#    login is sent to the issuer) before any is unwrapped; the creation-path refusal, the expired
#    token, a token used once failing the second time, nothing unwrapped when one of two is refused,
#    the token never in an argument, the values put with dcf-secret put, field by field.
# Part of `task lint` (`task test:openbao-unit`). SCRIPT points the test at another copy of the
# script (used to show a test fails when the code it covers is broken). Needs jq and task (task for
# the Taskfile checks, which are skipped without it).
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../../.."
script="${SCRIPT:-$root/src/openbao/openbao-onboard.sh}"

if ! command -v jq >/dev/null 2>&1; then
  echo "skip - onboard_test: jq is not installed"
  exit 0
fi

T="$(mktemp -d /tmp/obonb.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/feat-server" "$T/feat-client" "$T/state"
cp "$root/src/openbao/env.sh" "$T/feat-server/env.sh"
cp "$root/src/openbao/openbao-lib.sh" "$T/feat-server/openbao-lib.sh"
cp "$root/src/openbao/env.sh" "$T/feat-client/env.sh"
cp "$root/src/openbao/openbao-lib.sh" "$T/feat-client/openbao-lib.sh"
printf 'MODE=server\n' > "$T/feat-server/options.env"
printf 'MODE=client\n' > "$T/feat-client/options.env"
install -m 0755 "$script" "$T/bin/openbao-onboard"
LOG="$T/calls.log"

cat > "$T/bin/bao" <<'STUB'
#!/bin/bash
# Stub bao. $STUB_DIR/wrap.<token> holds "<creation path>|<created epoch>|<ttl>" for a live wrapping
# token; unwrapping or an expired one removes it. $STUB_DIR/values.<name> is a KV data JSON.
echo "$*" >> "$STUB_LOG"
echo "$1 $2 token=${BAO_TOKEN-unset}" >> "$STUB_DIR/tokens.log"
case "$1 $2" in
  "status -format=json") echo '{"initialized": true, "sealed": false}'; exit 0 ;;
  "token lookup") exit "${STUB_LOOKUP_RC:-0}" ;;
esac
case "$1" in
  kv)
    # kv get -mount=dcf -wrap-ttl=900s -format=json NAME   (without -wrap-ttl: a plain read)
    name="${!#}"
    ttl=""
    for a in "$@"; do case "$a" in -wrap-ttl=*) ttl="${a#-wrap-ttl=}"; ttl="${ttl%s}" ;; esac; done
    [ -n "$ttl" ] || exit "${STUB_KV_RC:-0}"
    n=$(( $(cat "$STUB_DIR/wrap.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/wrap.n"
    tok="hvs.WRAP-$n"
    echo "dcf/data/$name|$(date -u +%s)|$ttl" > "$STUB_DIR/wrap.$tok"
    printf '{"wrap_info": {"token": "%s", "ttl": %s, "creation_path": "dcf/data/%s"}}\n' "$tok" "$ttl" "$name"
    exit 0 ;;
  write)
    # write -format=json sys/wrapping/lookup token=-   (stdin: the token)
    if [ "$3" = sys/wrapping/lookup ]; then
      tok="$(cat)"
      f="$STUB_DIR/wrap.$tok"
      [ -f "$f" ] || { echo "* wrapping token is not valid or does not exist" >&2; exit 2; }
      IFS='|' read -r p c l < "$f"
      [ -z "${STUB_EXPIRE:-}" ] || c=$((c - l - 5))
      printf '{"data": {"creation_path": "%s", "creation_time": "%s", "creation_ttl": %s}}\n' "$p" "$(date -u -d "@$c" +%Y-%m-%dT%H:%M:%SZ)" "$l"
      exit 0
    fi ;;
  unwrap)
    tok="${BAO_TOKEN:-}"
    f="$STUB_DIR/wrap.$tok"
    [ -f "$f" ] || { echo "* wrapping token is not valid or does not exist" >&2; exit 2; }
    IFS='|' read -r p _ _ < "$f"
    rm -f "$f"
    printf '{"data": {"data": %s, "metadata": {"version": 1}}}\n' "$(n="${p#dcf/data/}"; cat "$STUB_DIR/values.${n//\//_}" 2>/dev/null || echo '{"value": "v"}')"
    exit 0 ;;
esac
echo "stub bao: unexpected call: $*" >&2
exit 99
STUB
chmod +x "$T/bin/bao"

cat > "$T/bin/dcf-secret" <<'STUB'
#!/bin/bash
echo "dcf-secret $*" >> "$STUB_LOG"
case "$1" in
  status) exit "${STUB_STATUS_RC:-0}" ;;
  get) exit "${STUB_STATUS_RC:-0}" ;;
  put)
    printf '%s %s=%s\n' "$2" "${4:-}" "$(cat)" >> "$STUB_DIR/puts"
    exit "${STUB_PUT_RC:-0}" ;;
esac
exit 99
STUB
chmod +x "$T/bin/dcf-secret"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
has() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (no '$2' in: $3)"; fi
}
lacks() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then fail=$((fail + 1)); echo "FAIL - $1 ('$2' found in: $3)"
  else pass=$((pass + 1)); echo "ok   - $1"; fi
}

reset() {
  rm -rf "${T:?}/state" "${T:?}"/wrap.* "${T:?}"/values.* "${T:?}"/puts "${T:?}"/tokens.log "${T:?}"/out
  mkdir -p "$T/state" "$T/out"
  : > "$LOG"
}
envs() {
  echo "PATH=$T/bin:/usr/local/bin:/usr/bin:/bin" "HOME=$T/home" "STUB_LOG=$LOG" "STUB_DIR=$T" "OPENBAO_STATE_DIR=$T/state" "OPENBAO_FEATURE_DIR=$T/feat-${MODE_FEAT:-server}"
}
MODE_FEAT=server
# run [VAR=value ...] -- <command>: stdout+stderr in $out, exit status in $rc, no terminal
run() {
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done
  shift
  # shellcheck disable=SC2046  # envs prints words
  out="$(env -i $(envs) "${e[@]}" bash "$T/bin/openbao-onboard" "$@" 2>&1)"
  rc=$?
}
calls() { cat "$LOG"; }
have_script=0
command -v script >/dev/null 2>&1 && have_script=1

# ------------------------------------------------------------------------------ refusals ----
# Inside an agent's job: every task that handles a share or a token. No call to bao, whatever else.
declare -A args=(
  [export]="OPENBAO_TASK_NAMES=ssh/key OPENBAO_TASK_DEST=$T/out"
  [claim]="X=1"
  [wrap]="OPENBAO_TASK_NAMES=ssh/key"
  [unwrap]="OPENBAO_TASK_FROM=$T/none"
)
for t in export claim wrap unwrap; do
  for v in DEVHOST_JOB_CHILD CLAUDECODE; do
    reset
    # shellcheck disable=SC2086  # args are words
    run ${args[$t]} "$v=1" -- "$t"
    check "$t refuses inside an agent's job ($v): exit 3" 3 "$rc"
    has "$t ($v): the line names the variable and the reason" "refuses to run inside an agent's job ($v is set)" "$out"
    check "$t ($v): bao is never called" "" "$(calls)"
  done
  reset
  # shellcheck disable=SC2086
  run ${args[$t]} OPENBAO_AGENT_JOB_VARS="OTHERCLI MYCLI" MYCLI=1 -- "$t"
  check "$t refuses for a variable named in OPENBAO_AGENT_JOB_VARS: exit 3" 3 "$rc"
  has "$t (OPENBAO_AGENT_JOB_VARS): names MYCLI" "(MYCLI is set)" "$out"
  reset
  # shellcheck disable=SC2086
  run ${args[$t]} DEVHOST_JOB_CHILD= -- "$t"
  lacks "$t: an empty DEVHOST_JOB_CHILD is no agent's job" "agent's job" "$out"
done
# through the Taskfile: the tasks are wired to the refusal (task runs openbao-onboard from PATH)
if command -v task >/dev/null 2>&1; then
  for spec in "onboard:export NAMES=ssh/key DEST=$T/out" "onboard:claim" "wrap NAMES=ssh/key" "unwrap FROM=$T/none"; do
    reset
    # shellcheck disable=SC2046,SC2086  # envs prints words; spec is words
    out="$(cd "$T" && env -i $(envs) DEVHOST_JOB_CHILD=1 task -t "$root/src/openbao/taskfile.yml" $spec 2>&1)"
    rc=$?
    check "task openbao:${spec%% *} refuses inside an agent's job: not exit 0" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
    has "task openbao:${spec%% *}: the refusal is the one shown" "refuses to run inside an agent's job (DEVHOST_JOB_CHILD is set)" "$out"
    check "task openbao:${spec%% *}: bao is never called" "" "$(calls)"
  done
else
  echo "skip - the Taskfile refusals (no task on PATH)"
fi
# no terminal
reset
run OPENBAO_TASK_NAMES=ssh/key OPENBAO_TASK_DEST="$T/out" -- export
check "export without a terminal: exit 3" 3 "$rc"
has "export without a terminal: says so" "needs a terminal" "$out"
check "export without a terminal: bao is never called" "" "$(calls)"
reset
run -- claim
check "claim without a terminal: exit 3" 3 "$rc"
has "claim without a terminal: says so" "needs a terminal" "$out"
check "claim without a terminal: bao is never called" "" "$(calls)"
reset
run OPENBAO_TASK_NAMES=ssh/key OPENBAO_TASK_SHOW=1 OPENBAO_TASK_OUT="$T/out/w.txt" -- wrap
check "wrap with SHOW=1 without a terminal: exit 3" 3 "$rc"
reset
run -- unwrap
check "unwrap with no FROM and no terminal (a prompt is needed): exit 3" 3 "$rc"
has "unwrap without a terminal: says so" "needs a terminal" "$out"
# claim in client mode: this container runs no server
MODE_FEAT=client
reset
run -- claim
check "claim in client mode: exit 3" 3 "$rc"
has "claim in client mode: says why" "this container runs no server (mode client)" "$out"
check "claim in client mode: bao is never called" "" "$(calls)"
MODE_FEAT=server
# the wrong calls
reset
run -- bogus
check "an unknown command: exit 2" 2 "$rc"
run -- export extra
check "export with an extra argument: exit 2" 2 "$rc"

# ------------------------------------------------------------------------------------- wrap ----
wr() { # <VAR=value>... : wrap with NAMES=ssh/key,shared/multi unless given
  reset
  run OPENBAO_TASK_NAMES="${NAMES-ssh/key,shared/multi}" OPENBAO_TASK_OUT="$T/out/w.txt" "$@" -- wrap
}
wr
check "wrap: exit 0" 0 "$rc"
check "wrap: one wrapping token per secret, asked of bao with the default 15 minutes" 2 "$(grep -c '^kv get -mount=dcf -wrap-ttl=900s -format=json ' "$LOG")"
has "wrap: the first is for ssh/key" "-wrap-ttl=900s -format=json ssh/key" "$(calls)"
has "wrap: the second for shared/multi" "-wrap-ttl=900s -format=json shared/multi" "$(calls)"
check "wrap: the token file has two lines, name and token" "ssh/key hvs.WRAP-1|shared/multi hvs.WRAP-2" "$(paste -sd'|' "$T/out/w.txt")"
check "wrap: the token file is mode 600" 600 "$(stat -c %a "$T/out/w.txt")"
lacks "wrap: no token on stdout" "hvs.WRAP" "$out"
has "wrap: the output names the file and the expiry" "$T/out/w.txt (mode 600)" "$out"
has "wrap: and says each opens once" "each opens once" "$out"
lacks "wrap: no token in any argument of bao" "hvs.WRAP" "$(calls)"
check "wrap: bao ran with the login (no token set here, so none was added)" 0 "$(grep -c 'token=hvs' "$T/tokens.log")"
# the cap and what is not a duration
for ttl in 1h 60m 3600 3600s; do
  wr OPENBAO_TASK_TTL="$ttl"
  check "wrap TTL=$ttl is the cap itself: accepted (3600s)" "0:2" "$rc:$(grep -c 'wrap-ttl=3600s' "$LOG")"
done
for ttl in 3601 61m 2h 7200s 100000; do
  wr OPENBAO_TASK_TTL="$ttl"
  check "wrap TTL=$ttl is over the cap: exit 2" 2 "$rc"
  has "wrap TTL=$ttl: the line says the cap" "cap of 1 hour" "$out"
  check "wrap TTL=$ttl: no token asked of bao, no file" "0:no" "$(grep -c '^kv get .*-wrap-ttl' "$LOG"):$([ -e "$T/out/w.txt" ] && echo yes || echo no)"
done
for ttl in 0 soon -5 1.5h "15 m" 5d; do
  wr OPENBAO_TASK_TTL="$ttl"
  check "wrap TTL='$ttl' is not a duration (or is zero): exit 2" 2 "$rc"
done
wr OPENBAO_TASK_TTL=30m
check "wrap TTL=30m is 1800 seconds" 2 "$(grep -c 'wrap-ttl=1800s' "$LOG")"
wr OPENBAO_TASK_TTL=45
check "wrap TTL=45 (seconds)" 2 "$(grep -c 'wrap-ttl=45s' "$LOG")"
# names
NAMES=onboarding/marker wr
check "wrap of a name under onboarding/: exit 2" 2 "$rc"
NAMES=ssh/key,"bad name" wr
check "wrap of a name that is not a name: exit 2" 2 "$rc"
check "and nothing asked of bao" "" "$(calls)"
NAMES="" wr
check "wrap with no names: exit 2" 2 "$rc"
NAMES=ssh/key,ssh/key wr
check "a name given twice is wrapped once" 1 "$(grep -c '^kv get .*-wrap-ttl' "$LOG")"
# the server's state and the login
wr STUB_LOOKUP_RC=2
check "wrap without a valid login: exit 12" 12 "$rc"
check "wrap without a valid login: no token asked of bao" 0 "$(grep -c '^kv get .*-wrap-ttl' "$LOG")"
wr STUB_KV_RC=1 STUB_STATUS_RC=14
check "wrap of a secret that cannot be read: dcf-secret status's exit code (14)" 14 "$rc"
wr STUB_KV_RC=1
check "wrap of a secret the policy allows but that is not there: 14 as well" 14 "$rc"
check "wrap of an unreadable secret: no wrapping token asked" 0 "$(grep -c '^kv get .*-wrap-ttl' "$LOG")"
# never overwrites
reset
echo old > "$T/out/w.txt"
run OPENBAO_TASK_NAMES=ssh/key OPENBAO_TASK_OUT="$T/out/w.txt" -- wrap
check "wrap never overwrites an existing OUT: exit 2" 2 "$rc"
check "and the old file is as it was" old "$(cat "$T/out/w.txt")"
# a terminal and SHOW=1: the tokens are printed
if [ "$have_script" -eq 1 ]; then
  reset
  # shellcheck disable=SC2046
  cmd="env -i $(envs | tr '\n' ' ') OPENBAO_TASK_NAMES=ssh/key OPENBAO_TASK_OUT=$T/out/w.txt OPENBAO_TASK_SHOW=1 bash $T/bin/openbao-onboard wrap"
  out="$(script -qefc "$cmd" /dev/null 2>&1 < /dev/null | tr -d '\r')"
  has "wrap SHOW=1 on a terminal prints the token" "ssh/key hvs.WRAP-1" "$out"
fi

# ------------------------------------------------------------------------------------ unwrap ----
mk_wrapped() { # <name> <ttl> -> prints the token: one made by a read of that secret
  local n
  n=$(( $(cat "$T/wrap.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/wrap.n"
  echo "dcf/data/$1|$(date -u +%s)|$2" > "$T/wrap.hvs.W$n"
  printf 'hvs.W%s' "$n"
}
uw() { # <VAR=value>... : unwrap of $T/in.txt
  run OPENBAO_TASK_FROM="$T/in.txt" OPENBAO_TASK_ISSUER_ADDR=http://issuer.example:8200 BAO_ADDR=http://own.example:8200 BAO_TOKEN=OWN-LOGIN "$@" -- unwrap
}
reset
a="$(mk_wrapped ssh/key 900)"
b="$(mk_wrapped shared/multi 900)"
printf '%s\n' '{"private_key": "abc def", "n": 5}' > "$T/values.ssh_key"
printf '%s %s\n%s %s\n' ssh/key "$a" shared/multi "$b" > "$T/in.txt"
uw
check "unwrap: exit 0" 0 "$rc"
check "unwrap: both tokens were looked up before either was unwrapped" "write -format=json sys/wrapping/lookup token=-|write -format=json sys/wrapping/lookup token=-|unwrap -format=json|unwrap -format=json" "$(grep -E '^(write|unwrap)' "$LOG" | paste -sd'|')"
check "unwrap: the lookups and the unwraps used the wrapping token as the call's token, never the saved login" 0 "$(grep -E '^(write|unwrap) ' "$T/tokens.log" | grep -c 'OWN-LOGIN')"
lacks "unwrap: no token in any argument" "hvs.W" "$(calls)"
lacks "unwrap: no token on the output" "hvs.W" "$out"
check "unwrap: one dcf-secret put per field, to the receiver's own store" 3 "$(grep -c '^dcf-secret put' "$LOG")"
check "unwrap: the values reached dcf-secret on stdin, field by field (a number kept as JSON)" "ssh/key n=5|ssh/key private_key=abc def|shared/multi value=v" "$(paste -sd'|' "$T/puts")"
lacks "unwrap: no value is in any argument" "abc def" "$(calls)"
# the second time
uw
check "unwrap again: exit 3, do not unwrap" 3 "$rc"
has "unwrap again: says do not unwrap; ask the sender" "do not unwrap; ask the sender" "$out"
has "unwrap again: names the event" "event to investigate" "$out"
# the creation path
reset
a="$(mk_wrapped ssh/key 900)"
b="$(mk_wrapped other/thing 900)"
printf '%s %s\n%s %s\n' ssh/key "$a" shared/multi "$b" > "$T/in.txt"
uw
check "unwrap with one token from another path: exit 3" 3 "$rc"
has "unwrap: says what path it was made by" "was made by a read of 'dcf/data/other/thing', not of dcf/data/shared/multi" "$out"
check "unwrap: nothing was unwrapped (not even the good one)" 0 "$(grep -c '^unwrap' "$LOG")"
check "unwrap: nothing was put" 0 "$(grep -c '^dcf-secret put' "$LOG")"
check "and the good token is still live (not spent)" yes "$([ -f "$T/wrap.$a" ] && echo yes)"
# the swapped names
reset
a="$(mk_wrapped ssh/key 900)"
printf '%s %s\n' shared/multi "$a" > "$T/in.txt"
uw
check "unwrap of a token under the wrong name: exit 3" 3 "$rc"
check "unwrap of a token under the wrong name: not unwrapped" 0 "$(grep -c '^unwrap' "$LOG")"
# a token with no creation path at all (made by sys/wrapping/wrap)
reset
echo "sys/wrapping/wrap|$(date -u +%s)|900" > "$T/wrap.hvs.FORGED"
printf '%s %s\n' ssh/key hvs.FORGED > "$T/in.txt"
uw
check "unwrap of a token made by sys/wrapping/wrap: exit 3" 3 "$rc"
has "unwrap: says it was made by a read of sys/wrapping/wrap" "was made by a read of 'sys/wrapping/wrap'" "$out"
# expired
reset
a="$(mk_wrapped ssh/key 900)"
printf '%s %s\n' ssh/key "$a" > "$T/in.txt"
uw STUB_EXPIRE=1
check "unwrap of a token whose TTL has run out: exit 3" 3 "$rc"
has "unwrap: says it has run out" "has run out" "$out"
check "unwrap of an expired token: not unwrapped" 0 "$(grep -c '^unwrap' "$LOG")"
# unknown, used
reset
printf '%s %s\n' ssh/key hvs.NOSUCH > "$T/in.txt"
uw
check "unwrap of a token the issuer does not know: exit 3" 3 "$rc"
has "unwrap: do not unwrap; ask the sender" "do not unwrap; ask the sender" "$out"
# the store here must be ready first: nothing is spent when there is nowhere to put the values
reset
a="$(mk_wrapped ssh/key 900)"
printf '%s %s\n' ssh/key "$a" > "$T/in.txt"
uw STUB_LOOKUP_RC=2
check "unwrap without a login of our own: exit 12" 12 "$rc"
check "unwrap without a login: no token touched" "yes" "$([ -f "$T/wrap.$a" ] && echo yes)"
uw STUB_STATUS_RC=11
check "unwrap with our store not ready: exit 12, token not spent" "12:yes" "$rc:$([ -f "$T/wrap.$a" ] && echo yes)"
# a put that fails after the unwrap: said, with the dcf-secret code
reset
a="$(mk_wrapped ssh/key 900)"
printf '%s %s\n' ssh/key "$a" > "$T/in.txt"
uw STUB_PUT_RC=13
check "unwrap whose put is refused: dcf-secret's exit code (13)" 13 "$rc"
has "unwrap whose put is refused: says the token is spent" "the token is spent" "$out"
# a bad file
reset
printf 'justonetoken\n' > "$T/in.txt"
uw
check "unwrap of a file whose line is not '<name> <token>': exit 2" 2 "$rc"
check "unwrap with no ISSUER_ADDR and no BAO_ADDR: exit 2" 2 "$(run OPENBAO_TASK_FROM="$T/in.txt" -- unwrap; echo "$rc")"
printf -- '-bad hvs.X\n' > "$T/in.txt"
uw
check "unwrap of a name that is not a name: exit 2" 2 "$rc"
printf 'onboarding/marker hvs.X\n' > "$T/in.txt"
uw
check "unwrap of a name under onboarding/: exit 2" 2 "$rc"
check "unwrap: none of the bad calls touched a token" 0 "$(grep -c '^write\|^unwrap' "$LOG")"

echo
echo "onboard_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
