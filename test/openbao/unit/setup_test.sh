#!/usr/bin/env bash
# Docker-free tests of openbao-setup (src/openbao/openbao-setup.sh) over temp folders: the state
# directory made and reported (dcf-persist, the real copy), a token left in ~/.vault-token moved
# into it once (only with the token helper in effect, never over a token the state dir already
# has, mode 600), the token helper reported (in effect, BAO_CONFIG_PATH unset or another file),
# the mode (client; an unknown one reported and run as client), the report (bao missing,
# BAO_ADDR, BAO_TOKEN, a saved login), never fatal, and the token's text never printed. Part of
# `task lint` (`task test:openbao-unit`). SCRIPT points the test at another copy of the script.
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

CFG=/usr/local/share/openbao-feature/bao-config.hcl
fresh
run BAO_CONFIG_PATH="$CFG"
check "first run: exit 0" 0 "$rc"
has "reports the state dir with its backing" "openbao: $T/state (" "$out"
has "the state dir is writable" "writable)" "$out"
check "the state folder exists" yes "$([ -d "$T/state" ] && echo yes)"
has "the token helper is in effect" "token helper in effect" "$out"
check "no link is made in the home folder" "" "$(ls -A "$T/home")"
has "mode client" "mode client" "$out"
has "reports the bao version" "OpenBao v9.9.9" "$out"
has "no login yet" "no login yet" "$out"
has "BAO_ADDR not set is said" "BAO_ADDR is not set" "$out"
run BAO_CONFIG_PATH="$CFG"
check "second run: exit 0" 0 "$rc"

# a login saved by the helper is reported, and its text never printed
printf 'hvs.PRIVATE-TOKEN-TEXT' > "$T/state/token"
run BAO_CONFIG_PATH="$CFG"
has "a saved login is reported" "a login is saved" "$out"
lacks "the token's text is never printed" "PRIVATE-TOKEN-TEXT" "$out"
run BAO_CONFIG_PATH="$CFG" BAO_TOKEN=hvs.OTHER-TEXT
has "BAO_TOKEN is said to take precedence" "BAO_TOKEN is set" "$out"
lacks "BAO_TOKEN's text is never printed" "OTHER-TEXT" "$out"
run BAO_CONFIG_PATH="$CFG" BAO_ADDR=https://bao.example.test
has "BAO_ADDR is reported" "BAO_ADDR https://bao.example.test" "$out"

# a token left in ~/.vault-token is moved into the state dir once
fresh
printf 'hvs.OLD-LOGIN' > "$T/home/.vault-token"
chmod 0644 "$T/home/.vault-token"
run BAO_CONFIG_PATH="$CFG"
check "an old token: exit 0" 0 "$rc"
check "an old token is moved into the state dir" "hvs.OLD-LOGIN" "$(cat "$T/state/token")"
check "and is gone from the home folder" "" "$(ls -A "$T/home")"
check "the moved token is mode 600" 600 "$(stat -c %a "$T/state/token")"
has "says it moved it" "moved from" "$out"
lacks "never prints the old token" "OLD-LOGIN" "$out"
printf 'hvs.AGAIN' > "$T/home/.vault-token"
run BAO_CONFIG_PATH="$CFG"
check "a second old token does not replace the state dir's" "hvs.OLD-LOGIN" "$(cat "$T/state/token")"
check "and is left where it is" "hvs.AGAIN" "$(cat "$T/home/.vault-token")"
has "says it left it" "left where it is" "$out"
# without the helper in effect bao still reads ~/.vault-token: it is never moved
fresh
printf 'hvs.KEEP' > "$T/home/.vault-token"
run
check "no helper: the token stays in the home folder" "hvs.KEEP" "$(cat "$T/home/.vault-token")"
check "no helper: nothing in the state dir" "" "$(ls -A "$T/state")"
has "no helper: BAO_CONFIG_PATH unset is said" "BAO_CONFIG_PATH is not set" "$out"
check "no helper: still exit 0" 0 "$rc"
run BAO_CONFIG_PATH=/elsewhere/config.hcl
has "another BAO_CONFIG_PATH is said" "not this Feature's" "$out"
check "another BAO_CONFIG_PATH: the token stays" "hvs.KEEP" "$(cat "$T/home/.vault-token")"

# a state folder nobody can write: reported, never fatal, nothing moved (skipped as root)
if [ "$(id -u)" -ne 0 ]; then
  fresh
  printf 'hvs.STAY' > "$T/home/.vault-token"
  mkdir -p "$T/state"
  chmod 0555 "$T/state"
  run BAO_CONFIG_PATH="$CFG"
  check "an unwritable state dir: exit 0" 0 "$rc"
  has "an unwritable state dir is reported" "not writable" "$out"
  check "the old token stays" "hvs.STAY" "$(cat "$T/home/.vault-token")"
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
check "no bao: the report before it still ran" "yes" "$(grep -q "mode client" <<<"$out" && echo yes)"

echo
echo "setup_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
