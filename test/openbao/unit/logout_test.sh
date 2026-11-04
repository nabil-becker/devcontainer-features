#!/usr/bin/env bash
# Docker-free tests of `task openbao:logout` (src/openbao/taskfile.yml) with a stub bao and the real
# token helper: the token revoked on the server (bao token revoke -self) and then erased from the
# state dir, the erase done when the revoke fails (a token that is already dead), and no error
# when nothing is stored. The task goes through openbao-run (the real one: it applies server mode's
# BAO_ADDR default and changes nothing else). Part of `task lint` (`task test:openbao-unit`). Needs task.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../../.."
command -v task >/dev/null 2>&1 || { echo "logout_test: task is required"; exit 1; }

T="$(mktemp -d /tmp/oblogout.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
install -m 0755 "$root/src/openbao/openbao-token-helper.sh" "$T/bin/openbao-token-helper"
install -m 0755 "$root/src/openbao/openbao-run.sh" "$T/bin/openbao-run"
cat > "$T/bin/bao" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
exit "${STUB_REVOKE_RC:-0}"
STUB
chmod +x "$T/bin/bao"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

logout() { # [VAR=value ...]: rc = exit status of the task
  : > "$T/calls.log"
  (cd "$T" && env PATH="$T/bin:$PATH" STUB_LOG="$T/calls.log" OPENBAO_STATE_DIR="$T/state" "$@" \
    task -t "$root/src/openbao/taskfile.yml" logout >"$T/out" 2>&1)
  rc=$?
}

printf 'hvs.TOKEN' > "$T/state/token"
logout
check "logout: exit 0" 0 "$rc"
check "logout revokes the token on the server" "token revoke -self" "$(cat "$T/calls.log")"
check "logout erases the saved token" "" "$(ls -A "$T/state")"

printf 'hvs.DEAD' > "$T/state/token"
logout STUB_REVOKE_RC=2
check "a revoke that fails (a dead token): the task is still exit 0" 0 "$rc"
check "and the saved token is erased anyway" "" "$(ls -A "$T/state")"

logout
check "nothing stored: exit 0" 0 "$rc"

echo
echo "logout_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
