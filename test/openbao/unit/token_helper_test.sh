#!/usr/bin/env bash
# Docker-free tests of openbao-token-helper (src/openbao/openbao-token-helper.sh), the token helper
# bao calls with get, store or erase: the token kept at $OPENBAO_STATE_DIR/token with mode 600,
# written atomically (no temp file left), a missing token read as nothing with exit 0, erase
# forgetting it (and a missing one being no error), the folder made when absent, a failing store
# reported with a non-zero exit, no output besides `get`, and the way bao calls it (through
# `sh -c "<path> <op>"` with the environment inherited). Part of `task lint`
# (`task test:openbao-unit`). SCRIPT points the test at another copy of the script.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
script="${SCRIPT:-$here/../../../src/openbao/openbao-token-helper.sh}"

T="$(mktemp -d /tmp/obhelper.XXXXXX)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
cp "$script" "$T/helper"
chmod +x "$T/helper"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

# run <op> [stdin]: out = stdout, err = stderr, rc = exit status; called the way bao does, through
# a shell with the environment inherited.
run() {
  out="$(printf '%s' "${2-}" | env -i PATH="/usr/bin:/bin" OPENBAO_STATE_DIR="$T/state" sh -c "$T/helper $1" 2>"$T/err")"
  rc=$?
  err="$(cat "$T/err")"
}

run get
check "get with no token: exit 0" 0 "$rc"
check "get with no token: prints nothing" "" "$out"

run store 'hvs.TOKEN-ONE'
check "store: exit 0" 0 "$rc"
check "store: prints nothing" "" "$out$err"
check "the folder is made when absent" yes "$([ -d "$T/state" ] && echo yes)"
check "the token is at OPENBAO_STATE_DIR/token" "hvs.TOKEN-ONE" "$(cat "$T/state/token")"
check "the token file is mode 600" 600 "$(stat -c %a "$T/state/token")"
run get
check "get returns exactly what was stored" "hvs.TOKEN-ONE" "$out"
check "get: exit 0" 0 "$rc"

run store 'hvs.TOKEN-TWO'
run get
check "store again replaces it" "hvs.TOKEN-TWO" "$out"
check "no temp file is left behind" "token" "$(ls -A "$T/state")"
check "still mode 600 after a replace" 600 "$(stat -c %a "$T/state/token")"

printf -v nl 'tok\n'
run store "$nl"
check "a trailing newline is kept as given (the helper adds and strips nothing)" yes "$(printf '%s' "$nl" | cmp -s - "$T/state/token" && echo yes)"

run erase
check "erase: exit 0" 0 "$rc"
check "erase removes the token" "" "$(ls -A "$T/state")"
run get
check "get after erase prints nothing" "" "$out"
run erase
check "erase of a missing token is no error" 0 "$rc"

run bogus
check "an unknown operation is exit 2" 2 "$rc"
run ""
check "no operation is exit 2" 2 "$rc"

# a failing store is non-zero and prints a reason only on stderr (skipped as root: it can write anywhere)
if [ "$(id -u)" -ne 0 ]; then
  chmod 0555 "$T/state"
  run store 'hvs.NOPE'
  check "store into an unwritable folder fails" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  check "and the token is not printed" "" "$(grep -F NOPE <<<"$out$err")"
  chmod 0755 "$T/state"
fi

# a path with a space in the state dir: bao runs the helper through a shell, the variable is read
# inside, so the folder is free to have one
out="$(printf 'x' | env -i PATH="/usr/bin:/bin" OPENBAO_STATE_DIR="$T/a state" sh -c "$T/helper store"; cat "$T/a state/token")"
check "a state dir with a space" "x" "$out"

echo
echo "token_helper_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
