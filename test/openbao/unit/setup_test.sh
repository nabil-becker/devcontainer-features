#!/usr/bin/env bash
# Docker-free tests of openbao-setup (src/openbao/openbao-setup.sh) over temp folders: the state
# directory made and reported (dcf-persist, the real copy), ~/.vault-token linked into it (made,
# kept on a second run, a real file moved in and linked, a link elsewhere left alone, a state
# folder that is not writable reported), the mode (client; an unknown one reported and run as
# client; OPENBAO_SETUP_MODE over the baked default), the report (bao missing, BAO_ADDR, BAO_TOKEN,
# a saved login), never fatal, and the token's text never printed. Part of `task lint`
# (`task test:openbao-unit`). SCRIPT points the test at another copy of the script.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
script="${SCRIPT:-$here/../../../src/openbao/openbao-setup.sh}"
persist="$here/../../../src/openbao/dcf-persist.sh"

T="$(mktemp -d /tmp/obsetup.XXXXXX)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin"
ln -s "$persist" "$T/bin/dcf-persist"
cat > "$T/bin/bao" <<'STUB'
#!/usr/bin/env bash
[ "$1" = version ] && echo "OpenBao v9.9.9 (stub)"
exit 0
STUB
chmod +x "$T/bin/bao" "$persist" 2>/dev/null

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

# fresh: a new home and state folder; run [VAR=value ...]: out = stdout+stderr, rc = exit status.
fresh() { rm -rf "${T:?}/home" "${T:?}/state"; mkdir -p "$T/home"; }
run() {
  out="$(env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" OPENBAO_STATE_DIR="$T/state" "$@" bash "$script" 2>&1)"
  rc=$?
}

fresh
run
check "first run: exit 0" 0 "$rc"
has "reports the state dir with its backing" "openbao: $T/state (" "$out"
has "the state dir is writable" "writable)" "$out"
check "the state folder exists" yes "$([ -d "$T/state" ] && echo yes)"
check "the home token file is a link into the state dir" "$T/state/token" "$(readlink "$T/home/.vault-token")"
has "says it linked" "login token linked into the state dir" "$out"
has "mode client" "mode client" "$out"
has "reports the bao version" "OpenBao v9.9.9" "$out"
has "no login yet" "no login yet" "$out"
has "BAO_ADDR not set is said" "BAO_ADDR is not set" "$out"

run
check "second run: exit 0" 0 "$rc"
has "second run keeps the link" ", kept)" "$out"
check "the link is unchanged" "$T/state/token" "$(readlink "$T/home/.vault-token")"

# a login written through the link lands in the volume and is reported
printf 'hvs.PRIVATE-TOKEN-TEXT' > "$T/home/.vault-token"
check "writing through the link reaches the state dir" "hvs.PRIVATE-TOKEN-TEXT" "$(cat "$T/state/token")"
run
has "a saved login is reported" "a login is saved" "$out"
lacks "the token's text is never printed" "PRIVATE-TOKEN-TEXT" "$out"
run BAO_TOKEN=hvs.OTHER-TEXT
has "BAO_TOKEN is said to take precedence" "BAO_TOKEN is set" "$out"
lacks "BAO_TOKEN's text is never printed" "OTHER-TEXT" "$out"
run BAO_ADDR=https://bao.example.test
has "BAO_ADDR is reported" "BAO_ADDR https://bao.example.test" "$out"

# a revoke removes the link; a later login is a real file, newer than the volume's copy
rm -f "$T/home/.vault-token"
printf 'hvs.NEWER' > "$T/home/.vault-token"
run
check "a real file is moved into the volume" "hvs.NEWER" "$(cat "$T/state/token")"
check "and linked" "$T/state/token" "$(readlink "$T/home/.vault-token")"
has "says it moved" "moved into the state dir" "$out"
check "the moved token is mode 600" 600 "$(stat -c %a "$T/state/token")"

# a link somewhere else is the user's
fresh
mkdir -p "$T/elsewhere"
ln -s "$T/elsewhere/tok" "$T/home/.vault-token"
run
check "a link elsewhere: exit 0" 0 "$rc"
check "a link elsewhere is left alone" "$T/elsewhere/tok" "$(readlink "$T/home/.vault-token")"
has "and said" "left alone" "$out"

# a state folder nobody can write: reported, never fatal, nothing linked (skipped as root)
if [ "$(id -u)" -ne 0 ]; then
  fresh
  mkdir -p "$T/state"
  chmod 0555 "$T/state"
  run
  check "an unwritable state dir: exit 0" 0 "$rc"
  has "an unwritable state dir is reported" "not writable" "$out"
  check "nothing is linked into it" "" "$([ -e "$T/home/.vault-token" ] || [ -L "$T/home/.vault-token" ] && echo linked)"
  chmod 0755 "$T/state"
fi

# the mode
fresh
run OPENBAO_SETUP_MODE=server
check "an unknown mode: exit 0" 0 "$rc"
has "an unknown mode is reported" "mode 'server' is not available" "$out"

# bao missing: the rest still ran and the exit is 0
fresh
mkdir -p "$T/nobao"
ln -s "$persist" "$T/nobao/dcf-persist"
out="$(env -i PATH="$T/nobao:/usr/bin:/bin" HOME="$T/home" OPENBAO_STATE_DIR="$T/state" bash "$script" 2>&1)"
rc=$?
check "no bao: exit 0" 0 "$rc"
has "no bao: said, not fatal" "bao not found on PATH" "$out"
check "no bao: the link was still made" "$T/state/token" "$(readlink "$T/home/.vault-token")"

echo
echo "setup_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
