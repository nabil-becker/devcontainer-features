#!/usr/bin/env bash
# Docker-free tests of dcf-secret (src/openbao/dcf-secret.sh) against a stub `bao` that answers
# from environment variables and logs every call: each exit code and its one-line fix on stderr,
# the value alone on stdout, the value on stdin for put and never in an argument, the mount, name
# and field checks, status in every state, DCF_SECRET_AS refused, and no fallback to a file or the
# environment when the server says no. The stub plays only the signals the script is built on
# (the exit code of `bao status`, `initialized` in its JSON, `bao token capabilities`); that the
# real bao gives those is the container test's (test/openbao/dev_server.sh). Part of `task lint`
# (`task test:openbao-unit`). SCRIPT points the test at another copy of the script (used to show a
# test fails when the code it covers is broken).
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
script="${SCRIPT:-$here/../../../src/openbao/dcf-secret.sh}"

T="$(mktemp -d /tmp/dcfsec.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state/ssh"
LOG="$T/calls.log"

cat > "$T/bin/bao" <<'STUB'
#!/usr/bin/env bash
# Stub bao: STUB_* variables choose the answers; every call is logged (arguments only).
echo "$*" >> "$STUB_LOG"
echo "${BAO_ADDR-unset}" >> "$STUB_DIR/addr.log"
case "$1 $2" in
  "status -format=json")
    printf '%s\n' "${STUB_STATUS_JSON:-{\"initialized\": true, \"sealed\": false\}}"
    exit "${STUB_STATUS_RC:-0}" ;;
  "kv get")
    if [ "${STUB_KV_RC:-0}" -eq 0 ]; then printf '%s' "${STUB_VALUE-s3cret}"; exit 0; fi
    echo "Error reading dcf/data/x: stub failure" >&2
    exit "$STUB_KV_RC" ;;
  "kv put" | "kv patch")
    # The value each call received on stdin is kept per call (stdin.<n>, n counting the kv put and kv patch calls); STUB_PATCH_RCS is a
    # list of exit codes, one per patch call (the last one repeats), for the race.
    n="$(grep -cE '^kv (put|patch)' "$STUB_LOG")"
    cat > "$STUB_DIR/stdin.$n"
    if [ "$2" = patch ]; then
      k="$(grep -c '^kv patch' "$STUB_LOG")"
      rcs=(${STUB_PATCH_RCS:-0})
      rc="${rcs[$((k - 1))]:-${rcs[${#rcs[@]} - 1]}}"
    else
      rc="${STUB_PUT_RC:-0}"
    fi
    [ "$rc" -eq 0 ] && { echo "Key  Value"; exit 0; }
    echo "Error writing: stub failure" >&2
    exit "$rc" ;;
  "token capabilities")
    [ "${STUB_CAPS_RC:-0}" -eq 0 ] || { echo "permission denied" >&2; exit 2; }
    echo "${STUB_CAPS-read}"
    exit 0 ;;
  "token lookup")
    if [ "${3:-}" = -format=json ]; then
      printf '{\n  "data": {\n    "creation_ttl": 14400,\n    "ttl": %s\n  }\n}\n' "${STUB_TTL:-14400}"
    else
      echo "token  s.never-printed"
    fi
    exit "${STUB_LOOKUP_RC:-0}" ;;
esac
echo "stub bao: unexpected call: $*" >&2
exit 99
STUB
chmod +x "$T/bin/bao"

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

# run [VAR=value ...] -- <args>: stdout in $out, stderr in $err, exit status in $rc. Stdin is
# $INPUT (default empty). A clean environment with the stub first on PATH.
INPUT=""
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$LOG"
  rm -f "$T"/stdin.*
  out="$(printf '%s' "$INPUT" | env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" STUB_LOG="$LOG" STUB_DIR="$T" \
    OPENBAO_STATE_DIR="$T/state" DCF_SECRET_X="from-the-environment" "${envs[@]}" bash "$script" "$@" 2>"$T/err")"
  rc=$?
  err="$(cat "$T/err")"
  INPUT=""
}
lines() { printf '%s\n' "$1" | grep -c .; }

# --- get: the value, alone
run -- get ssh/key
check "get: exit 0" 0 "$rc"
check "get: the value alone on stdout" "s3cret" "$out"
check "get: nothing on stderr" "" "$err"
has "get: asks the dcf mount, the value field, the name" "kv get -mount=dcf -field=value ssh/key" "$(cat "$LOG")"
check "get: one call to bao" 1 "$(lines "$(cat "$LOG")")"
run -- get register/scribe --field private_key
has "get --field" "-field=private_key register/scribe" "$(cat "$LOG")"
run -- get ssh/key --field=pub
has "get --field=x" "-field=pub ssh/key" "$(cat "$LOG")"
run DCF_SECRET_MOUNT=mine -- get token/gh
has "DCF_SECRET_MOUNT names the mount" "-mount=mine -field=value token/gh" "$(cat "$LOG")"
run 'STUB_VALUE=line one
line two' -- get ssh/key
check "get: a multi-line value is passed through untouched" "$(printf 'line one\nline two')" "$out"

# --- get: each failure and its line
run STUB_KV_RC=2 STUB_STATUS_RC=1 STUB_STATUS_JSON= -- get ssh/key
check "10: unreachable" 10 "$rc"
check "10: stdout empty" "" "$out"
has "10: the fix names BAO_ADDR" "BAO_ADDR" "$err"
has "10: and the task that says whether the server runs" "task openbao:server:status" "$err"
check "10: one line" 1 "$(lines "$err")"
run STUB_KV_RC=2 STUB_STATUS_RC=2 STUB_STATUS_JSON='{"initialized": true, "sealed": true}' -- get ssh/key
check "11: sealed" 11 "$rc"
check "11: stdout empty" "" "$out"
has "11: the fix says who unseals, and the task" "task openbao:unseal" "$err"
check "11: one line" 1 "$(lines "$err")"
run STUB_KV_RC=2 STUB_STATUS_RC=2 STUB_STATUS_JSON='{"initialized": false, "sealed": true}' -- get ssh/key
check "11: not initialised is 11 too" 11 "$rc"
has "11: not initialised says so" "not initialised" "$err"
has "11: not initialised names the init task" "task openbao:init" "$err"
run STUB_KV_RC=2 STUB_CAPS_RC=2 -- get ssh/key
check "12: no valid token" 12 "$rc"
has "12: the fix is the login" "task openbao:login" "$err"
has "12: and the logout that clears a dead token" "task openbao:logout" "$err"
check "12: one line" 1 "$(lines "$err")"
run STUB_KV_RC=2 STUB_CAPS=deny -- get ssh/key
check "13: the token may not read" 13 "$rc"
has "13: the line names the name and the mount" "'ssh/key' at dcf" "$err"
check "13: one line" 1 "$(lines "$err")"
run STUB_KV_RC=2 STUB_CAPS=read -- get ssh/key
check "14: no such secret" 14 "$rc"
has "14: the fix is a put" "dcf-secret put" "$err"
check "14: one line" 1 "$(lines "$err")"
run STUB_KV_RC=2 STUB_CAPS="create, read, update" -- get ssh/key
check "14: capabilities listed with commas" 14 "$rc"
run STUB_KV_RC=2 STUB_CAPS=root -- get ssh/key
check "14: root may read" 14 "$rc"
run STUB_KV_RC=2 STUB_CAPS="create, update" -- get ssh/key
check "13: create and update alone do not read" 13 "$rc"
has "13: the capabilities asked on the KV v2 data path" "token capabilities dcf/data/ssh/key" "$(cat "$LOG")"

# --- server mode: the same lines, and BAO_ADDR defaults to the local server (env.sh, options.env)
mkdir -p "$T/feat-server" "$T/feat-client"
cp "$here/../../../src/openbao/env.sh" "$T/feat-server/env.sh"
cp "$here/../../../src/openbao/env.sh" "$T/feat-client/env.sh"
printf 'MODE=server\n' > "$T/feat-server/options.env"
printf 'MODE=client\n' > "$T/feat-client/options.env"
: > "$T/addr.log"
run OPENBAO_FEATURE_DIR="$T/feat-server" -- get ssh/key
check "server mode: get works" 0 "$rc"
check "server mode: BAO_ADDR defaults to the local listener" "http://127.0.0.1:8200" "$(sort -u "$T/addr.log")"
: > "$T/addr.log"
run OPENBAO_FEATURE_DIR="$T/feat-server" BAO_ADDR=https://bao.example.test -- get ssh/key
check "server mode: a BAO_ADDR that is set is kept" "https://bao.example.test" "$(sort -u "$T/addr.log")"
: > "$T/addr.log"
run OPENBAO_FEATURE_DIR="$T/feat-client" -- get ssh/key
check "client mode: BAO_ADDR is left unset (bao's own default)" "unset" "$(sort -u "$T/addr.log")"
: > "$T/addr.log"
run OPENBAO_FEATURE_DIR="$T/feat-client" OPENBAO_SETUP_MODE=server -- get ssh/key
check "OPENBAO_SETUP_MODE=server overrides the baked mode" "http://127.0.0.1:8200" "$(sort -u "$T/addr.log")"
run OPENBAO_FEATURE_DIR="$T/feat-server" STUB_KV_RC=2 STUB_STATUS_RC=1 STUB_STATUS_JSON= -- get ssh/key
check "server mode: unreachable is still 10" 10 "$rc"
has "server mode: unreachable names the default address" "http://127.0.0.1:8200" "$err"
run OPENBAO_FEATURE_DIR="$T/feat-server" STUB_KV_RC=2 STUB_STATUS_RC=2 STUB_STATUS_JSON='{"initialized": true}' -- get ssh/key
has "server mode: sealed names the unseal task" "task openbao:unseal" "$err"

# --- the order of the questions, and that nothing is read in place of the server
run STUB_KV_RC=2 STUB_STATUS_RC=2 -- get ssh/key
check "sealed: no capabilities question once the server is known sealed" 0 "$(grep -c 'token capabilities' "$LOG")"
printf 'from-the-volume' > "$T/state/ssh/key"
run STUB_KV_RC=2 STUB_STATUS_RC=2 -- get ssh/key
check "no fallback: sealed with a key in the volume and in the environment, stdout empty" "" "$out"
check "no fallback: still 11" 11 "$rc"
run STUB_KV_RC=2 STUB_STATUS_RC=1 -- get ssh/key
check "no fallback: unreachable, stdout empty" "" "$out"
run STUB_KV_RC=2 STUB_CAPS=read -- get x
check "no fallback: a missing secret does not read DCF_SECRET_X" "" "$out"
check "no fallback: a missing secret is 14" 14 "$rc"
check "get never writes a file (the state folder holds only what the test put there)" "key" "$(ls "$T/state/ssh")"

# --- get: bad calls
run -- get
check "get without a name is usage" 2 "$rc"
run -- get ../etc/passwd
check "a name with .. is refused" 2 "$rc"
run -- get /abs/path
check "a leading slash is refused" 2 "$rc"
run -- get 'a b'
check "a name with a space is refused" 2 "$rc"
run -- get 'a;rm'
check "a name with shell characters is refused" 2 "$rc"
run -- get ssh/key --field 'a=b'
check "a field with = is refused" 2 "$rc"
check "bad calls never reach bao" 0 "$(wc -l < "$LOG")"
run -- frobnicate
check "an unknown command is usage" 2 "$rc"
run -- get ssh/key --field
check "--field without a value is usage" 2 "$rc"
run --
check "no command is usage" 2 "$rc"

# --- put: merge by default (kv patch), create when absent (kv put -cas=0), --replace
calls() { cat "$LOG"; }
kvcalls() { grep -E '^kv (put|patch)' "$LOG"; }
stdin_of() { cat "$T/stdin.$1"; } # the value the <n>th kv put or kv patch call received
INPUT="topsecret" run -- put ssh/key --field private_key
check "put merges: exit 0" 0 "$rc"
check "put: nothing on stdout (bao's table is not ours)" "" "$out"
has "put: kv patch with field=- so bao reads stdin" "kv patch -mount=dcf ssh/key private_key=-" "$(calls)"
lacks "put merging never calls kv put" "kv put" "$(calls)"
check "put: the value reached bao on stdin" "topsecret" "$(stdin_of 1)"
lacks "put: the value is in no argument" "topsecret" "$(calls)"
check "put merging: one call to bao" 1 "$(lines "$(calls)")"
INPUT="x" run -- put ssh/key
check "put without --field is usage" 2 "$rc"
INPUT="x" run -- put ssh/key --field f --bogus
check "put with an unknown flag is usage" 2 "$rc"

# the secret does not exist yet: patch fails, the token may create, so it is created (-cas=0)
INPUT="topsecret" run STUB_PATCH_RCS=2 STUB_CAPS="create, patch, read, update" -- put ssh/key --field private_key
check "put creates an absent secret: exit 0" 0 "$rc"
has "put: creates with -cas=0, only if still absent" "kv put -cas=0 -mount=dcf ssh/key private_key=-" "$(calls)"
check "put: the same value reached the create (kept in memory for the second offer)" "topsecret" "$(stdin_of 2)"
lacks "put create: the value is in no argument" "topsecret" "$(calls)"
printf -v nl 'line one
line two

'
INPUT="$nl" run STUB_PATCH_RCS=2 STUB_CAPS="create, patch" -- put ssh/key --field f
check "put: a multi-line value with trailing newlines is kept byte for byte" "yes" "$(printf '%s' "$nl" | cmp -s - "$T/stdin.2" && echo yes)"

# the secret appeared between the patch and the create: the create fails, one more patch merges
INPUT="v" run STUB_PATCH_RCS="2 0" STUB_PUT_RC=2 STUB_CAPS="create, patch" -- put ssh/key --field f
check "put race: exit 0 after retrying as a patch" 0 "$rc"
check "put race: patch, create, patch" "kv patch|kv put|kv patch" "$(kvcalls | awk '{printf "%s%s %s", (NR>1?"|":""), $1, $2}')"
check "put race: the retry carried the value" "v" "$(stdin_of 3)"
INPUT="x" run STUB_PATCH_RCS=2 STUB_PUT_RC=2 STUB_CAPS="create, patch" -- put ssh/key --field f
check "put: patch, create and the retry all failing is 1, never 14" 1 "$rc"
has "put: 1 carries bao's own message" "stub failure" "$err"
check "put: the retry is only one" 3 "$(lines "$(kvcalls)")"

# --replace: one field, kv put, no patch
INPUT="topsecret" run -- put ssh/key --field private_key --replace
check "put --replace: exit 0" 0 "$rc"
has "put --replace: kv put of the one field" "kv put -mount=dcf ssh/key private_key=-" "$(calls)"
lacks "put --replace: no -cas" "-cas" "$(calls)"
lacks "put --replace: no patch" "kv patch" "$(calls)"
check "put --replace: the value reached bao" "topsecret" "$(stdin_of 1)"

# patch denied while put is allowed: never a silent replace
INPUT="x" run STUB_PATCH_RCS=2 STUB_CAPS="create, update" -- put ssh/key --field f
check "put: no patch capability is 13" 13 "$rc"
has "put: 13 points at --replace" "--replace" "$err"
has "put: 13 names the patch capability" "patch" "$err"
lacks "put: no kv put when only the patch was denied (nothing replaced)" "kv put" "$(calls)"
INPUT="x" run STUB_PATCH_RCS=2 STUB_CAPS="create, update" -- put ssh/key --field f --replace
check "the same token with --replace works" 0 "$rc"
INPUT="x" run STUB_PATCH_RCS=2 STUB_CAPS="patch, read" -- put ssh/key --field f
check "put: absent secret and no create capability is 13" 13 "$rc"
has "put: 13 names the creation" "may not create" "$err"
lacks "put: nothing written" "kv put" "$(calls)"

# the server and the token, for a merge and for --replace
for flag in "" "--replace"; do
  INPUT="x" run STUB_PATCH_RCS=2 STUB_PUT_RC=2 STUB_STATUS_RC=2 -- put ssh/key --field f $flag
  check "put $flag: sealed is 11" 11 "$rc"
  INPUT="x" run STUB_PATCH_RCS=2 STUB_PUT_RC=2 STUB_STATUS_RC=1 -- put ssh/key --field f $flag
  check "put $flag: unreachable is 10" 10 "$rc"
  INPUT="x" run STUB_PATCH_RCS=2 STUB_PUT_RC=2 STUB_CAPS_RC=2 -- put ssh/key --field f $flag
  check "put $flag: no token is 12" 12 "$rc"
  INPUT="x" run STUB_PATCH_RCS=2 STUB_PUT_RC=2 STUB_CAPS=read -- put ssh/key --field f $flag
  check "put $flag: a read-only token is 13" 13 "$rc"
  INPUT="x" run STUB_PATCH_RCS=2 STUB_PUT_RC=2 STUB_CAPS=deny -- put ssh/key --field f $flag
  check "put $flag: 14 does not apply to a put (13)" 13 "$rc"
done
INPUT="x" run STUB_PUT_RC=2 STUB_CAPS="create, update" -- put ssh/key --field f --replace
check "put --replace: allowed but failed is 1" 1 "$rc"
has "put --replace: 1 carries bao's own message" "stub failure" "$err"
# a terminal on stdin is refused: run under a pseudo-terminal when script(1) is there
if command -v script >/dev/null 2>&1; then
  tty_out="$(script -qec "env PATH=$T/bin:/usr/bin:/bin STUB_LOG=$LOG STUB_DIR=$T bash $script put ssh/key --field f" /dev/null 2>&1 </dev/null; echo "rc=$?")"
  has "put: a terminal on stdin is refused" "pipe it in" "$tty_out"
fi

# --- status
run -- status
check "status ready: exit 0" 0 "$rc"
check "status ready: the word" "ready" "$out"
check "status ready: one line on stdout" 1 "$(lines "$out")"
check "status ready: silent on stderr" "" "$err"
lacks "status never prints the token lookup's output" "s.never-printed" "$out$err"
run STUB_STATUS_RC=1 -- status
check "status unreachable" "unreachable" "$out"
check "status unreachable: exit 10" 10 "$rc"
run STUB_STATUS_RC=2 -- status
check "status sealed" "sealed" "$out"
check "status sealed: exit 11" 11 "$rc"
run STUB_STATUS_RC=2 STUB_STATUS_JSON='{"initialized": false, "sealed": true}' -- status
check "status not-initialised" "not-initialised" "$out"
check "status not-initialised: exit 11" 11 "$rc"
run STUB_LOOKUP_RC=2 -- status
check "status logged-out" "logged-out" "$out"
check "status logged-out: exit 12" 12 "$rc"
has "status logged-out: the fix on stderr" "task openbao:login" "$err"
run STUB_CAPS=deny -- status ssh/key
check "status denied for a name" "denied" "$out"
check "status denied: exit 13" 13 "$rc"
run STUB_CAPS=read -- status ssh/key
check "status ready for a name it may read" "ready" "$out"
run STUB_CAPS=deny -- status
check "status without a name asks no capabilities" "ready" "$out"
run -- status a b
check "status with two names is usage" 2 "$rc"

# --- ttl: the token's seconds left, for a caller that must not outlive it (ssh-agent's key:load)
run STUB_TTL=3599 -- ttl
check "ttl: exit 0" 0 "$rc"
check "ttl: the seconds alone on stdout" "3599" "$out"
has "ttl: from bao token lookup's JSON" "token lookup -format=json" "$(cat "$LOG")"
run STUB_TTL=0 -- ttl
check "ttl: 0 for a token that does not expire" "0" "$out"
run STUB_LOOKUP_RC=2 -- ttl
check "ttl: no token is 12" 12 "$rc"
has "ttl: with the login line" "task openbao:login" "$err"
run STUB_STATUS_RC=2 STUB_STATUS_JSON='{"initialized": true, "sealed": true}' -- ttl
check "ttl: sealed is 11" 11 "$rc"
run STUB_STATUS_RC=1 STUB_STATUS_JSON= -- ttl
check "ttl: unreachable is 10" 10 "$rc"
run -- ttl extra
check "ttl with an argument is usage" 2 "$rc"

# --- not supported yet, and a missing bao
run DCF_SECRET_AS=scribe -- get ssh/key
check "DCF_SECRET_AS is refused" 2 "$rc"
has "DCF_SECRET_AS: says it is not in this version" "not supported" "$err"
check "DCF_SECRET_AS: bao never called" 0 "$(wc -l < "$LOG")"
run DCF_SECRET_AS= -- get ssh/key
check "an empty DCF_SECRET_AS is no request" 0 "$rc"
out="$(env -i PATH="/usr/bin:/bin" bash "$script" get ssh/key 2>&1)"
rc=$?
check "no bao on PATH is 10" 10 "$rc"
has "no bao: names the Feature" "openbao Feature" "$out"

echo
echo "dcf_secret_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
