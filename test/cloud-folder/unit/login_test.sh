#!/usr/bin/env bash
# Docker-free tests of cloud-folder-setup login's browser sign-in (src/cloud-folder/cloud-folder-setup.sh)
# with a fake rclone whose `authorize` is fake_authorize.py: rclone's own flow on a local port (a
# link to /auth, /auth redirecting to the provider, / taking the code, the token between the paste
# markers). Covered: the paste route (the sign-in address of the provider printed; the address the
# browser shows after the sign-in pasted as a full URL, without the scheme, as 127.0.0.1; the login
# requesting it on rclone's listener, which receives the code; the token written into the config);
# a token pasted at the same prompt (rclone authorize stopped); garbage and a stale address refused
# with nothing changed; the token exchange failing; the relay route (--relay: the link printed, the
# login waiting while a "browser" goes through the listener, a timeout); --token (no authorize at
# all); rclone authorize not starting (the token prompt instead); no token in any output, process
# argument or leftover file, no rclone left running; the Feature Taskfile handing -- --token on.
# Part of `task lint` (`task test:cloud-folder-unit`). SETUP_SH points the tests at another copy.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
setup_sh="${SETUP_SH:-$here/../../../src/cloud-folder/cloud-folder-setup.sh}"
taskfile="$here/../../../src/cloud-folder/taskfile.yml"
fake_py="$here/fake_authorize.py"

T="$(mktemp -d)"
cleanup() {
  pkill -f "$fake_py" 2>/dev/null
  chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"
}
trap cleanup EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
has() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (no '$2' in: $3)"; fi
}
hasnt() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then fail=$((fail + 1)); echo "FAIL - $1 ('$2' found in: $3)"
  else pass=$((pass + 1)); echo "ok   - $1"; fi
}
yesno() { if "$@"; then echo yes; else echo no; fi; }
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
fakes_running() { if pgrep -f "$fake_py" >/dev/null 2>&1; then echo yes; else echo no; fi; }

SECRET='SECRETTOKENMARKER-4b9e'
TOKEN="{\"access_token\":\"$SECRET\",\"token_type\":\"Bearer\",\"refresh_token\":\"r-$SECRET\",\"expiry\":\"2099-01-01T00:00:00Z\"}"
state="$T/state"
mkdir -p "$T/bin"

# The fake rclone: authorize is the Python fake (FAKE_NO_AUTH=1: it fails as an rclone without a
# listener would), the rest as in sync_test.sh.
cat > "$T/bin/rclone" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FAKE_CALLS"
case "\$1" in
  version) echo 'rclone v1.75.2'; exit 0 ;;
  authorize)
    [ "\${FAKE_NO_AUTH:-}" = 1 ] && { echo 'ERROR : Failed to start auth webserver: listen tcp 127.0.0.1:53682: bind: address already in use' >&2; exit 1; }
    exec python3 -I '$fake_py' "\$@" ;;
  lsjson) echo '{}'; exit 0 ;;
  config) printf '{\n\t"State": "",\n\t"Option": null,\n\t"Error": "",\n\t"Result": ""\n}\n'; exit 0 ;;
esac
echo "fake rclone: unexpected call: \$*" >&2
exit 2
FAKE
chmod +x "$T/bin/rclone"
export FAKE_CALLS="$T/calls"
: > "$FAKE_CALLS"

ALL_OUT="$T/all-output"
: > "$ALL_OUT"
base_env() {
  env -i PATH="$T/bin:$PATH" HOME="$T" FAKE_CALLS="$FAKE_CALLS" FAKE_AUTH_TOKEN="$TOKEN" FAKE_AUTH_LOG="$T/auth.log" \
    FAKE_AUTH_STATE=teststate DCF_CLOUD_FOLDER_STATE_DIR="$state" CLOUD_FOLDER_REMOTE_TYPE=onedrive \
    CLOUD_FOLDER_MODE=sync CLOUD_FOLDER_MOUNT_POINT="$T/cloud folder" CLOUD_FOLDER_SYNC_INTERVAL=0 \
    DCF_CLOUD_FOLDER_FUSE_DEV="$T/no-fuse" "$@"
}
# login_with <stdin text> [VAR=value ...] -- [login args]: out, rc.
login_with() {
  local input="$1"; shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$T/auth.log"
  out="$(printf '%s' "$input" | base_env "${envs[@]}" bash "$setup_sh" login "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out" >> "$ALL_OUT"
}
reset_conf() { rm -f "$state/rclone.conf"; }
leftover_dirs() { find "$state/run" -maxdepth 1 -name 'login.*' 2>/dev/null | wc -l | tr -d ' '; }

# --- the paste route: the address the browser shows after the sign-in
login_with $'http://localhost:53682/?code=abc&state=teststate\n' --
check 'paste a full address: exit 0' 0 "$rc"
has 'prints the provider sign-in address (from rclone /auth)' 'sign-in URL: https://login.example.invalid/common/oauth2/v2.0/authorize' "$out"
has 'says the failing redirect page is expected' 'that is expected' "$out"
has 'still offers the workstation token, with the version' 'rclone authorize "onedrive"' "$out"
has 'the login requested the pasted address on the listener' '/?code=abc&state=teststate' "$(cat "$T/auth.log")"
has 'rclone was run with the browser not opened' 'authorize onedrive --auth-no-open-browser' "$(cat "$FAKE_CALLS")"
check 'the config holds the token from rclone' yes "$(yesno grep -qF "token = $TOKEN" "$state/rclone.conf")"
check 'the config is mode 600' 600 "$(stat -c %a "$state/rclone.conf")"
has 'says how it went' 'written to' "$out"
check 'no rclone authorize left running' no "$(fakes_running)"
check 'the private login folder is gone' 0 "$(leftover_dirs)"

reset_conf
login_with $'localhost:53682/?code=def&state=teststate\n' --
check 'paste an address without the scheme: exit 0' 0 "$rc"
has 'and its path and query reach the listener' '/?code=def&state=teststate' "$(cat "$T/auth.log")"
check 'the token is written' yes "$(yesno grep -qF "$SECRET" "$state/rclone.conf")"

reset_conf
login_with $'  http://127.0.0.1:53682/?state=teststate&code=ghi\r\n' --
check 'paste a 127.0.0.1 address with spaces and CR, code second: exit 0' 0 "$rc"
has 'and it reaches the listener' '/?state=teststate&code=ghi' "$(cat "$T/auth.log")"

# --- a token at the same prompt
reset_conf
login_with "$TOKEN"$'\n' --
check 'paste a token line: exit 0' 0 "$rc"
check 'the pasted token is written' yes "$(yesno grep -qF "token = $TOKEN" "$state/rclone.conf")"
check 'rclone authorize stopped' no "$(fakes_running)"
check 'no code reached the listener' '' "$(grep code= "$T/auth.log")"

# --- refusals
reset_conf
login_with $'hello there\n' --
check 'garbage: exit 1' 1 "$rc"
has 'garbage: refused, nothing changed' 'nothing changed' "$out"
check 'garbage: no config written' no "$(yesno test -e "$state/rclone.conf")"
check 'garbage: rclone authorize stopped' no "$(fakes_running)"
login_with $'http://example.com/?code=abc&state=teststate\n' --
check 'another host: exit 1' 1 "$rc"
login_with $'http://localhost:53682/\n' --
check 'an address without a code: exit 1' 1 "$rc"
login_with $'http://localhost:53682/?code=abc&state=old\n' --
check 'an address of another sign-in (stale state): exit 1' 1 "$rc"
has 'and says rclone refused it' 'rclone refused that address (HTTP/1.0 400' "$out"
check 'no config written' no "$(yesno test -e "$state/rclone.conf")"
login_with '' --
check 'nothing pasted: exit 1' 1 "$rc"
has 'says nothing was pasted' 'no address or token pasted; nothing changed' "$out"
login_with $'http://localhost:53682/?code=abc&state=teststate\n' FAKE_AUTH_FAIL=1 --
check 'the token exchange fails: exit 1' 1 "$rc"
has 'and says rclone failed, with its error' 'rclone authorize failed (exit 1: ERROR : Failed to get token: invalid_grant)' "$out"
check 'no config written' no "$(yesno test -e "$state/rclone.conf")"
login_with '' -- --bogus
check 'an unknown login argument: exit 2' 2 "$rc"

# --- the relay route: the launcher forwards the browser; here a "browser" opens the link
port="$(free_port)"
base_env FAKE_AUTH_PORT="$port" FAKE_AUTH_BACK="http://127.0.0.1:$port/" bash "$setup_sh" login --relay > "$T/relay.out" 2>&1 &
lpid=$!
for _ in $(seq 1 100); do grep -q 'sign-in URL: ' "$T/relay.out" && break; sleep 0.1; done
link="$(sed -n 's/.*sign-in URL: //p' "$T/relay.out" | head -n 1)"
check 'relay: the link is rclone own /auth link' "http://127.0.0.1:$port/auth?state=teststate" "$link"
curl -sfL -o /dev/null "$link"; check 'relay: the browser goes through /auth and back with the code' 0 "$?"
wait "$lpid"; rc=$?
out="$(cat "$T/relay.out")"; printf '%s\n' "$out" >> "$ALL_OUT"
check 'relay: exit 0' 0 "$rc"
has 'relay: says it waits for the browser' 'the launcher relays it here' "$out"
hasnt 'relay: no paste prompt' 'address or token' "$out"
check 'relay: the token is written' yes "$(yesno grep -qF "$SECRET" "$state/rclone.conf")"

reset_conf
login_with '' CLOUD_FOLDER_LOGIN_TIMEOUT=2 -- --relay
check 'relay with nobody signing in: exit 1 after the timeout' 1 "$rc"
has 'relay timeout: says so' 'no sign-in within 2s; nothing changed' "$out"
check 'relay timeout: rclone authorize stopped' no "$(fakes_running)"
check 'relay timeout: no config' no "$(yesno test -e "$state/rclone.conf")"
login_with '' FAKE_NO_AUTH=1 -- --relay
check 'relay, rclone authorize cannot listen: exit 1' 1 "$rc"
has 'and rclone error is shown' 'address already in use' "$out"

# --- --token and an rclone that cannot listen
: > "$FAKE_CALLS"
login_with "$TOKEN"$'\n' -- --token
check '--token: exit 0' 0 "$rc"
hasnt '--token: no rclone authorize' 'authorize' "$(cat "$FAKE_CALLS")"
has '--token: tells how to get one' 'rclone authorize "onedrive"' "$out"
reset_conf
login_with "$TOKEN"$'\n' FAKE_NO_AUTH=1 --
check 'paste route, rclone authorize cannot start: falls back to the token, exit 0' 0 "$rc"
has 'and says why' 'rclone authorize could not start here' "$out"

# --- the Feature Taskfile hands the arguments on
if command -v task >/dev/null 2>&1; then
  printf '#!/bin/sh\nexec bash %q "$@"\n' "$setup_sh" > "$T/bin/cloud-folder-setup"
  chmod +x "$T/bin/cloud-folder-setup"
  : > "$FAKE_CALLS"
  out="$(cd "$T" && printf '%s\n' "$TOKEN" | base_env task -s -t "$taskfile" login -- --token 2>&1)"; rc=$?
  printf '%s\n' "$out" >> "$ALL_OUT"
  check 'task login -- --token: exit 0' 0 "$rc"
  hasnt 'task login -- --token: no rclone authorize' 'authorize' "$(cat "$FAKE_CALLS")"
else
  echo "skip - the Taskfile checks: task is not on PATH"
fi

# --- the token never leaves the config
hasnt 'no output ever showed the token' "$SECRET" "$(cat "$ALL_OUT")"
hasnt 'no rclone call had the token on its command line' "$SECRET" "$(cat "$FAKE_CALLS")"
leaks="$(grep -rlF "$SECRET" "$state" 2>/dev/null | grep -v '/rclone.conf$')"
check 'only rclone.conf holds the token in the volume' '' "$leaks"
check 'no login folder left in the volume' 0 "$(leftover_dirs)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
