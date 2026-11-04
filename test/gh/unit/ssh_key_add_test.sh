#!/usr/bin/env bash
# Docker-free tests of gh-ssh-key-add (src/gh/gh-ssh-key-add.sh, task gh:ssh-key:add) against a
# stub gh that records its calls and the key file it is handed: the key registered with --type
# signing and the title, from FILE, from stdin and from OpenBao (KEY=ssh/<name> through a stub
# dcf-secret, whose exit code is passed on), a key already registered as a signing key left alone,
# one registered only for authentication added as a signing key, a private key refused, gh missing
# or logged out refused plainly, a failing add naming the admin:ssh_signing_key scope, and the
# temporary key file gone afterwards. Never against GitHub. Part of `task lint` (`task
# test:gh-unit`). SCRIPT points the test at another copy of the script.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
script="${SCRIPT:-$here/../../../src/gh/gh-ssh-key-add.sh}"

T="$(mktemp -d /tmp/ghkey.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/tmp"
LOG="$T/gh.log"

# Stub gh: auth status (STUB_AUTH_RC), ssh-key list (STUB_LIST, tab-separated as gh prints it
# without a terminal), ssh-key add (records the file's content; STUB_ADD_RC).
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
case "$1 $2" in
  "auth status") exit "${STUB_AUTH_RC:-0}" ;;
  "ssh-key list") printf '%b' "${STUB_LIST:-}"; exit 0 ;;
  "ssh-key add")
    cat "$3" >"$STUB_DIR/added.pub"
    [ "${STUB_ADD_RC:-0}" -eq 0 ] || { echo "HTTP 404: Not Found (https://api.github.com/user/ssh_signing_keys)" >&2; exit 1; }
    exit 0 ;;
esac
exit 99
STUB
# Stub dcf-secret: the public key of ssh/<name>, or STUB_DCF_RC.
cat >"$T/bin/dcf-secret" <<'STUB'
#!/usr/bin/env bash
echo "dcf-secret $*" >>"$STUB_LOG"
[ "${STUB_DCF_RC:-0}" -eq 0 ] || { echo "dcf-secret: the server is sealed" >&2; exit "$STUB_DCF_RC"; }
cat "$STUB_DIR/k.pub"
STUB
chmod +x "$T/bin/gh" "$T/bin/dcf-secret"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
has() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (no '$2' in: $3)"; fi
}

ssh-keygen -q -t ed25519 -N '' -C mykey -f "$T/k"
pub="$(cat "$T/k.pub")"
blob="$(awk '{print $2}' "$T/k.pub")"

INPUT=""
run() { # [VAR=value ...] -- <args>
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : >"$LOG"
  rm -f "$T/added.pub"
  out="$(printf '%s' "$INPUT" | env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" TMPDIR="$T/tmp" STUB_LOG="$LOG" STUB_DIR="$T" "${envs[@]}" bash "$script" "$@" 2>&1)"
  rc=$?
  INPUT=""
}

run -- --file "$T/k.pub" --title sign-1
check "file: exit 0" 0 "$rc"
has "file: registered as a signing key with the title" "ssh-key add" "$(cat "$LOG")"
has "file: --type signing" "--type signing --title sign-1" "$(cat "$LOG")"
check "file: gh got the public key" "$pub" "$(cat "$T/added.pub")"
check "file: the temporary key file is gone" "" "$(ls -A "$T/tmp")"
has "file: says what it did" "registered 'sign-1' at GitHub as a SIGNING key" "$out"

run -- --file "$T/k.pub"
has "file: the title defaults to the key's comment" "--title mykey" "$(cat "$LOG")"

INPUT="$pub"
run -- --title from-stdin
check "stdin: exit 0" 0 "$rc"
check "stdin: gh got the public key" "$pub" "$(cat "$T/added.pub")"

run -- --key ssh/rec-sign
check "KEY: exit 0" 0 "$rc"
has "KEY: read from OpenBao's field public_key" "dcf-secret get ssh/rec-sign --field public_key" "$(cat "$LOG")"
has "KEY: the title is the record's name" "--title rec-sign" "$(cat "$LOG")"
run STUB_DCF_RC=11 -- --key ssh/rec-sign
check "KEY: dcf-secret's exit code is passed on" 11 "$rc"
check "KEY: nothing registered" "no" "$([ -f "$T/added.pub" ] && echo yes || echo no)"

run "STUB_LIST=sign-1\t$pub\t2026-11-04\t123\tsigning\n" -- --file "$T/k.pub"
check "already a signing key: exit 0" 0 "$rc"
has "already a signing key: says so" "already registered at GitHub as a signing key" "$out"
check "already a signing key: no add" 0 "$(grep -c 'ssh-key add' "$LOG")"
run "STUB_LIST=auth\t$pub\t2026-11-04\t124\tauthentication\n" -- --file "$T/k.pub"
check "registered only for authentication: added as signing" 1 "$(grep -c 'ssh-key add' "$LOG")"

INPUT="$(cat "$T/k")"
run --
check "a private key is refused" 2 "$rc"
has "and says why" "only a public key is registered" "$out"
check "nothing is sent to gh for a private key" 0 "$(grep -c 'ssh-key' "$LOG")"
INPUT="hello"
run --
check "what is not a key is refused" 2 "$rc"
run -- --file "$T/k.pub" --key ssh/x
check "FILE and KEY together are refused" 2 "$rc"
run -- --file "$T/none.pub"
check "a missing FILE is refused" 2 "$rc"

run STUB_AUTH_RC=1 -- --file "$T/k.pub"
check "logged out: exit 1" 1 "$rc"
has "logged out: names the login and the scope" "gh auth refresh -s admin:ssh_signing_key" "$out"
run DCF_GH=no-such-gh -- --file "$T/k.pub"
check "no gh: exit 1" 1 "$rc"
has "no gh: says how to do it by hand" "key type Signing Key" "$out"
run STUB_ADD_RC=1 -- --file "$T/k.pub"
check "a failing add: exit 1" 1 "$rc"
has "a failing add: names the scope" "admin:ssh_signing_key" "$out"
check "a failing add: the temporary key file is gone" "" "$(ls -A "$T/tmp")"
if grep -qF -- "$blob" <<<"$out"; then fail=$((fail + 1)); echo "FAIL - the key blob was printed"
else pass=$((pass + 1)); echo "ok   - the key is never printed"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
