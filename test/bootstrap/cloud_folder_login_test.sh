#!/usr/bin/env bash
# Docker-free tests of the bash twin's cloud-folder login (src/devcontainer-cli/devcontainer-cli.sh
# `run cloud-folder-login`, behind task cloud-folder:login on a Linux or macOS workstation), the
# counterpart of CloudFolderLogin.Tests.ps1. The "container" is this machine: a stub `devcontainer`
# runs the exec'd command here and a stub `docker` answers `ps` with one id and runs `exec -i <id>
# bash -c` here, so the real cloud-folder-setup (src/cloud-folder) signs in against the fake
# rclone authorize of test/cloud-folder/unit/fake_authorize.py on a free port, and a "browser"
# (Python urllib, DCF_BROWSER) follows the sign-in through the workstation listener on another free port
# (the provider's redirect back is the fake's /auth redirect). Covered: the relay (the browser
# opened at the rewritten link, every request through `docker exec` and /dev/tcp, the token in the
# volume's config), the listener closed after success, a failed sign-in and a timeout; the busy
# port and the paste route instead; --paste; no container running; --workstation-rclone (the
# version from devcontainer.json or the Feature default, the zip verified against SHA256SUMS from a
# local server, cached, a wrong digest refused, the token handed to `login --token` on stdin, never
# an argument); the default pin equal to the Feature's; the root Taskfile's cloud-folder include
# (the template's): the launcher's task on the workstation, the Feature's in the container, no
# clash. Part of `task lint` (`task test:cloud-folder-login`).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../.."
cli_sh="${CLI_SH:-$root/src/devcontainer-cli/devcontainer-cli.sh}"
setup_sh="$root/src/cloud-folder/cloud-folder-setup.sh"
fake_py="$root/test/cloud-folder/unit/fake_authorize.py"

T="$(mktemp -d)"
cleanup() {
  pkill -f "$fake_py" 2>/dev/null
  [ -n "${srv:-}" ] && kill "$srv" 2>/dev/null
  [ -n "${blocker:-}" ] && kill "$blocker" 2>/dev/null
  rm -rf "$T"
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
port_free() { python3 -c 'import socket, sys; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1])))' "$1" 2>/dev/null && echo yes || echo no; }

SECRET='SECRETTOKENMARKER-c0de'
TOKEN="{\"access_token\":\"$SECRET\",\"token_type\":\"Bearer\",\"expiry\":\"2099-01-01T00:00:00Z\"}"
bin="$T/bin"; state="$T/state"; ws="$T/ws"
mkdir -p "$bin" "$ws/.devcontainer"
echo '{ "features": { "ghcr.io/nabil-becker/devcontainer-features/cloud-folder:1": {} } }' > "$ws/.devcontainer/devcontainer.json"

# The stubs. devcontainer: `exec --workspace-folder W [--docker-path E] <cmd...>` runs <cmd> here.
cat > "$bin/devcontainer" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
[ "$1" = exec ] || exit 0
shift
while [ $# -gt 0 ]; do case "$1" in --workspace-folder | --docker-path) shift 2 ;; *) break ;; esac; done
exec "$@"
STUB
# docker: `ps` lists one container when FAKE_RUNNING=1; `exec -i <id> bash -c <script>` runs here.
cat > "$bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS"
case "$1" in
  ps) [ "${FAKE_RUNNING:-1}" = 1 ] && echo cid1; exit 0 ;;
  exec) [ "$2" = -i ] && [ "$3" = cid1 ] || exit 125; shift 3; exec "$@" ;;
esac
exit 0
STUB
printf '#!/bin/sh\nexec bash %q "$@"\n' "$setup_sh" > "$bin/cloud-folder-setup"
# The container's rclone: authorize is the Python fake.
cat > "$bin/rclone" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$STUB_CALLS"
case "\$1" in
  version) echo 'rclone v1.75.2'; exit 0 ;;
  authorize) exec python3 -I '$fake_py' "\$@" ;;
  lsjson) echo '{}'; exit 0 ;;
  config) printf '{\n\t"State": "",\n\t"Option": null,\n\t"Error": "",\n\t"Result": ""\n}\n'; exit 0 ;;
esac
exit 2
FAKE
# The browser: follows every redirect, as a browser does, and records how it went.
cat > "$bin/browser" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$BROWSER_LOG"
python3 -I -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=20).read()' "$1" 2>/dev/null; echo "rc=$?" >> "$BROWSER_LOG"
STUB
chmod +x "$bin"/*

export STUB_CALLS="$T/calls" BROWSER_LOG="$T/browser.log"
# run [VAR=value ...] -- <cloud-folder-login args>: out, rc. Ports: L on the "workstation", C in the "container".
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$STUB_CALLS"; : > "$BROWSER_LOG"; : > "$T/auth.log"
  out="$(env -i PATH="$bin:$PATH" HOME="$T" XDG_CACHE_HOME="$T/cache" STUB_CALLS="$STUB_CALLS" BROWSER_LOG="$BROWSER_LOG" \
    DCF_BROWSER="$bin/browser" DCF_CLOUD_FOLDER_LOGIN_PORT="$L" DCF_CLOUD_FOLDER_LOGIN_CONTAINER_PORT="$C" \
    FAKE_AUTH_PORT="$C" FAKE_AUTH_BACK="http://127.0.0.1:$L/" FAKE_AUTH_STATE=teststate FAKE_AUTH_TOKEN="$TOKEN" FAKE_AUTH_LOG="$T/auth.log" \
    DCF_CLOUD_FOLDER_STATE_DIR="$state" CLOUD_FOLDER_REMOTE_TYPE=onedrive CLOUD_FOLDER_MODE=sync \
    CLOUD_FOLDER_MOUNT_POINT="$T/cloud folder" CLOUD_FOLDER_SYNC_INTERVAL=0 DCF_CLOUD_FOLDER_FUSE_DEV="$T/no-fuse" \
    "${envs[@]}" bash "$cli_sh" run cloud-folder-login --workspace-folder "$ws" -- "$@" 2>&1)"; rc=$?
  printf '%s\n' "$out" >> "$T/all-output"
}
reset_conf() { rm -f "$state/rclone.conf"; }

# --- the relay
L="$(free_port)"; C="$(free_port)"
run -- </dev/null
check "relay: exit 0" 0 "$rc"; [ "$rc" = 0 ] || echo "$out" | tail -5
has 'relay: says it relays the port' "relaying 127.0.0.1:$L on this workstation into the devcontainer" "$out"
check 'relay: the browser opened the link on the workstation port' "http://127.0.0.1:$L/auth?state=teststate" "$(head -n 1 "$BROWSER_LOG")"
check 'relay: the browser got through' 'rc=0' "$(sed -n 2p "$BROWSER_LOG")"
has 'relay: /auth reached rclone in the container' '/auth?state=teststate' "$(cat "$T/auth.log")"
has 'relay: the redirect with the code reached rclone' '/?code=fakecode&state=teststate' "$(cat "$T/auth.log")"
has 'relay: each request went through docker exec and /dev/tcp' "exec -i cid1 bash -c exec 3<>/dev/tcp/127.0.0.1/$C" "$(cat "$STUB_CALLS")"
has 'relay: the container login ran with --relay' 'cloud-folder-setup login --relay' "$(grep '^exec' "$STUB_CALLS")"
check 'relay: the token is in the volume config' yes "$(yesno grep -qF "$SECRET" "$state/rclone.conf")"
check 'relay: the listener is closed after success' yes "$(port_free "$L")"
has 'relay: and says so' "the relay on 127.0.0.1:$L is closed" "$out"

reset_conf
run FAKE_AUTH_FAIL=1 -- </dev/null
check 'relay, the sign-in fails: exit 1' 1 "$rc"
has 'and the container says why' 'rclone authorize failed' "$out"
check 'the listener is closed after a failure' yes "$(port_free "$L")"

start=$SECONDS
run DCF_BROWSER=true CLOUD_FOLDER_LOGIN_TIMEOUT=2 -- </dev/null
check 'relay, nobody signs in: exit 1' 1 "$rc"
has 'and the timeout is named' 'no sign-in within 2s' "$out"
check 'the listener is closed after the timeout' yes "$(port_free "$L")"
check 'within a few seconds' yes "$(yesno test $((SECONDS - start)) -lt 15)"
check 'no config after a timeout' no "$(yesno test -e "$state/rclone.conf")"

# --- the port is busy: the paste route instead
python3 -c 'import socket, sys, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); print("up", flush=True); time.sleep(60)' "$L" > "$T/blocker" &
blocker=$!
for _ in $(seq 1 50); do [ -s "$T/blocker" ] && break; sleep 0.1; done
run -- <<<'http://localhost:53682/?code=pasted&state=teststate'
check "busy port: exit 0 through the paste route" 0 "$rc"; [ "$rc" = 0 ] || { echo "$out" | tail -5; cat "$T/blocker"; }
has 'busy port: says so' "port $L on this workstation is in use" "$out"
check 'busy port: no browser opened' '' "$(cat "$BROWSER_LOG")"
has 'busy port: the pasted address reached rclone' '/?code=pasted&state=teststate' "$(cat "$T/auth.log")"
hasnt 'busy port: the container login was not in relay mode' 'login --relay' "$(cat "$STUB_CALLS")"
kill "$blocker" 2>/dev/null; wait "$blocker" 2>/dev/null; blocker=''

# --- --paste, and no container
reset_conf
run -- --paste <<<'localhost:53682/?code=p2&state=teststate'
check '--paste: exit 0' 0 "$rc"
has '--paste: the address reached rclone' '/?code=p2&state=teststate' "$(cat "$T/auth.log")"
check '--paste: no listener used' '' "$(cat "$BROWSER_LOG")"
run FAKE_RUNNING=0 -- </dev/null
check 'no container running: exit 1' 1 "$rc"
has 'and says how to start it' 'task dc:start' "$out"
run -- --bogus </dev/null
check 'an unknown argument: exit 1' 1 "$rc"

# --- --workstation-rclone: a release on a local server
mkdir -p "$T/srv/files/v1.75.2" "$T/zip/rclone-v1.75.2-linux-amd64"
case "$(uname -m)" in aarch64 | arm64) arch=arm64 ;; *) arch=amd64 ;; esac
os=linux; [ "$(uname -s)" = Darwin ] && os=osx
asset="rclone-v1.75.2-$os-$arch.zip"
mkdir -p "$T/zip/rclone-v1.75.2-$os-$arch"
cat > "$T/zip/rclone-v1.75.2-$os-$arch/rclone" <<WR
#!/usr/bin/env bash
echo "workstation-rclone \$*" >> "$T/ws-rclone.log"
echo 'NOTICE: If your browser does not open automatically go to the following link: http://127.0.0.1:53682/auth?state=x' >&2
printf 'Paste the following into your remote machine --->\n%s\n<---End paste\n' '$TOKEN'
WR
chmod +x "$T/zip/rclone-v1.75.2-$os-$arch/rclone"
python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.write(sys.argv[2], sys.argv[3])' "$T/srv/files/v1.75.2/$asset" "$T/zip/rclone-v1.75.2-$os-$arch/rclone" "rclone-v1.75.2-$os-$arch/rclone"
sha="$(sha256sum "$T/srv/files/v1.75.2/$asset" | cut -d' ' -f1)"
printf -- '-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA1\n\n0000  rclone-v1.75.2-windows-amd64.zip\n%s  %s\n-----BEGIN PGP SIGNATURE-----\n' "$sha" "$asset" > "$T/srv/files/v1.75.2/SHA256SUMS"
python3 -I "$here/flaky_server.py" reset "$T/srv/files" > "$T/srv/port" &
srv=$!
for _ in $(seq 1 50); do [ -s "$T/srv/port" ] && break; sleep 0.1; done
base="http://127.0.0.1:$(head -n 1 "$T/srv/port")"

reset_conf
run DCF_RCLONE_DOWNLOADS="$base" -- --workstation-rclone </dev/null
check '--workstation-rclone: exit 0' 0 "$rc"
has 'downloads the Feature default version' "downloading rclone v1.75.2 ($asset" "$out"
has 'after the first connection was reset (retried)' "/v1.75.2/$asset" "$(cat "$T/srv/requests.log")"
check 'the workstation rclone ran authorize onedrive' 'workstation-rclone authorize onedrive' "$(cat "$T/ws-rclone.log")"
check 'it is cached' yes "$(yesno test -x "$T/cache/devcontainer-features/rclone/v1.75.2/rclone")"
has 'the token went to login --token' 'cloud-folder-setup login --token' "$(grep '^exec' "$STUB_CALLS")"
check 'the token is in the volume config' yes "$(yesno grep -qF "$SECRET" "$state/rclone.conf")"
hasnt 'the container login started no rclone authorize of its own' 'authorize onedrive --auth-no-open-browser' "$(cat "$STUB_CALLS")"
: > "$T/srv/requests.log"
run DCF_RCLONE_DOWNLOADS="$base" -- --workstation-rclone </dev/null
check 'a second run: exit 0' 0 "$rc"
check 'and downloads nothing (the cache)' '' "$(cat "$T/srv/requests.log")"

rm -rf "$T/cache/devcontainer-features/rclone"
printf '%s  %s\n' "$(printf '0%.0s' $(seq 1 64))" "$asset" > "$T/srv/files/v1.75.2/SHA256SUMS"
run DCF_RCLONE_DOWNLOADS="$base" -- --workstation-rclone </dev/null
check 'a wrong digest: refused' 1 "$rc"
has 'and says so' 'SHA-256 mismatch' "$out"
check 'nothing cached' no "$(yesno test -e "$T/cache/devcontainer-features/rclone/v1.75.2/rclone")"

echo '{ "features": { "ghcr.io/nabil-becker/devcontainer-features/cloud-folder:1": { // pinned
  "rcloneVersion": "v1.70.0" } } }' > "$ws/.devcontainer/devcontainer.json"
run DCF_RCLONE_DOWNLOADS="$base" -- --workstation-rclone </dev/null
check 'rcloneVersion from devcontainer.json: the download of that version is tried' 1 "$rc"
has 'and named' 'could not download rclone v1.70.0' "$out"

check "the launcher's default rclone pin is the Feature's" \
  "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["options"]["rcloneVersion"]["default"])' "$root/src/cloud-folder/devcontainer-feature.json")" \
  "$(sed -n 's/^cf_rclone_default=//p' "$cli_sh")"

hasnt 'no output ever showed the token' "$SECRET" "$(cat "$T/all-output")"
hasnt 'no stub call had the token in its arguments' "$SECRET" "$(cat "$STUB_CALLS")"

# --- one name on both sides: the root Taskfile's includes (the bootstrap template)
if command -v task >/dev/null 2>&1; then
  tf="$T/tf"; mkdir -p "$tf/b" "$tf/feat"
  sed -e 's|{{BOOTSTRAP_DIR}}|b|g' -e "s|/usr/local/share/go-task/features.yml|$tf/feat/features.yml|" "$root/bootstrap/Taskfile.yml" > "$tf/Taskfile.yml"
  cp "$root/bootstrap/cloud-folder.yml" "$tf/b/"
  printf 'version: "3"\ntasks:\n  cloud-folder-login:\n    cmds: ["echo launcher-login {{.CLI_ARGS}}"]\n' > "$tf/b/devcontainer.yml"
  printf 'version: "3"\nincludes:\n  cloud-folder:\n    taskfile: ./cf.yml\n' > "$tf/feat/features.yml.in"
  printf 'version: "3"\ntasks:\n  login:\n    cmds: ["echo feature-login"]\n' > "$tf/feat/cf.yml"
  t_out="$(cd "$tf" && env -u RCLONE_CONFIG -u DEVCONTAINER_IN_CONTAINER task -s cloud-folder:login -- --paste 2>&1)"
  check 'workstation (no features.yml): task cloud-folder:login is the launcher' 'launcher-login --paste' "$t_out"
  cp "$tf/feat/features.yml.in" "$tf/feat/features.yml"
  t_out="$(cd "$tf" && RCLONE_CONFIG=/var/lib/devcontainer-features/cloud-folder/rclone.conf task -s cloud-folder:login 2>&1)"
  check 'container (the Feature sets RCLONE_CONFIG): the Feature task, no clash' 'feature-login' "$t_out"
  t_out="$(cd "$tf" && env -u RCLONE_CONFIG DEVCONTAINER_IN_CONTAINER=1 task -s cloud-folder:login 2>&1)"
  check 'container (DEVCONTAINER_IN_CONTAINER=1): the Feature task' 'feature-login' "$t_out"
else
  echo "skip - the Taskfile checks: task is not on PATH"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
