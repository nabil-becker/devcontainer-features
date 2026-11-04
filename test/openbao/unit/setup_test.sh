#!/usr/bin/env bash
# Docker-free tests of openbao-setup (src/openbao/openbao-setup.sh) over temp folders: the state
# directory made and reported (dcf-persist, the real copy), a token left in ~/.vault-token moved
# into it once (only with the token helper in effect, never over a token the state dir already
# has, mode 600), the token helper reported (in effect, BAO_CONFIG_PATH unset or another file),
# the mode (client; an unknown one reported and run as client; server), the report (bao missing,
# BAO_ADDR and its server-mode default, BAO_TOKEN, a saved login), never fatal, and the token's text
# never printed. Server mode's start hook (`openbao-setup start`) against a stub bao that plays
# `bao server` and `bao status`: the config written (raft on the state dir, one loopback listener
# without TLS, the file audit device, no disable_mlock), the server started once and reused, its
# pid and log in the state dir, the line for not initialised, sealed and unsealed, a server that
# does not answer reported with its log and still exit 0, a config without the marker left alone, a
# config with it rewritten, client mode and a missing bao doing nothing, never fatal. Part of
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
run OPENBAO_SETUP_MODE=sideways
check "an unknown mode: exit 0" 0 "$rc"
has "an unknown mode is reported" "mode 'sideways' is not known" "$out"
has "and it runs as client" "running as client" "$out"

# server mode: the report, then the start hook against a stub bao that plays `bao server` / `bao status`
mkdir -p "$T/feat" "$T/srvbin"
cp "$here/../../../src/openbao/env.sh" "$T/feat/env.sh"
printf 'MODE=server\n' > "$T/feat/options.env"
ln -s "$persist" "$T/srvbin/dcf-persist"
# (#!/bin/bash, not env: the hook recognises the server by its process name, bao)
cat > "$T/srvbin/bao" <<'STUB'
#!/bin/bash
case "$1" in
  version) echo "OpenBao v9.9.9 (stub)"; exit 0 ;;
  server)
    echo "server $*" >> "$STUB_LOG"
    echo "stub server log line" >&2
    sleep 300 &
    wait ;;
  status)
    echo "status ${BAO_ADDR-unset}" >> "$STUB_LOG"
    printf '%s\n' "${STUB_STATUS_JSON:-{\"initialized\": true\}}"
    exit "${STUB_STATUS_RC:-0}" ;;
esac
exit 0
STUB
chmod +x "$T/srvbin/bao"
stop_server() { # the stub server leaves a sleep behind: stop both, whatever the test did
  local pid
  pid="$(cat "$T/state/server.pid" 2>/dev/null)" && [ -n "$pid" ] && pkill -P "$pid" 2>/dev/null
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  return 0
}
trap 'stop_server; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
srv() { # [VAR=value ...] -- <args>: the Feature in server mode with the stub bao first on PATH
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  out="$(env -i PATH="$T/srvbin:/usr/bin:/bin" HOME="$T/home" OPENBAO_STATE_DIR="$T/state" OPENBAO_FEATURE_DIR="$T/feat" \
    STUB_LOG="$T/calls.log" OPENBAO_START_TRIES=4 "${envs[@]}" bash "$script" "$@" 2>&1)"
  rc=$?
}
conf="$T/state/server.hcl"
fresh; : > "$T/calls.log"
srv -- 
check "server mode post-create: exit 0" 0 "$rc"
has "post-create says server mode" "mode server" "$out"
has "post-create names the default address" "BAO_ADDR is not set; server mode uses its default http://127.0.0.1:8200" "$out"
has "post-create says how to log in" "-method=userpass username=operator" "$out"
check "post-create does not start the server" 0 "$(grep -c '^server' "$T/calls.log")"
srv BAO_ADDR=https://elsewhere.test -- 
has "a BAO_ADDR that is set is reported as it is" "BAO_ADDR https://elsewhere.test" "$out"

fresh; : > "$T/calls.log"
srv STUB_STATUS_RC=2 'STUB_STATUS_JSON={"initialized": false}' -- start
check "start: exit 0" 0 "$rc"
has "start: not initialised, names the init task" "not initialised; the Operator runs task openbao:init" "$out"
check "start: the server was started once, with the config in the state dir" "server server -config=$conf" "$(grep '^server' "$T/calls.log")"
check "start: the pid is recorded" yes "$([ -s "$T/state/server.pid" ] && echo yes)"
check "start: the server's own log is in the state dir" yes "$([ -f "$T/state/server.log" ] && echo yes)"
check "start: the config is mode 600" 600 "$(stat -c %a "$conf")"
check "start: raft storage on the state dir" 1 "$(grep -c "path    = \"$T/state/raft\"" "$conf")"
check "start: a fixed node id" 1 "$(grep -c 'node_id = "devhost"' "$conf")"
check "start: one loopback listener without TLS" "1 1" "$(grep -c 'address     = "127.0.0.1:8200"' "$conf") $(grep -c 'tls_disable = true' "$conf")"
check "start: the audit device is declared in the config, in the state dir" 1 "$(grep -c "file_path = \"$T/state/audit.log\"" "$conf")"
check "start: no disable_mlock (OpenBao has none since 2.0.0)" 0 "$(grep -c '^disable_mlock' "$conf")"
check "start: the raft folder exists, private" 700 "$(stat -c %a "$T/state/raft")"
check "start: the status was asked at the local listener, whatever BAO_ADDR says" yes "$(grep -q '^status http://127.0.0.1:8200$' "$T/calls.log" && echo yes)"
srv STUB_STATUS_RC=2 -- start
has "start again: the live server is reused" "already running" "$out"
has "start again: sealed, names the unseal task" "sealed; the Operator runs task openbao:unseal" "$out"
check "start again: still one server" 1 "$(grep -c '^server' "$T/calls.log")"
srv -- start
has "start: unsealed is said" "running and unsealed" "$out"
stop_server
rm -f "$T/state/server.pid"
srv -- start
check "a dead pid is not reused: a second server start" 2 "$(grep -c '^server' "$T/calls.log")"
# the config: rewritten while it carries the marker, left alone without it
sed -i '1s/^/# my own edits\n/' "$conf"
srv -- start
check "a config without the marker line is left alone" "# my own edits" "$(head -n 1 "$conf")"
check "and was not rewritten" 0 "$(grep -c 'Written by the openbao Feature' "$conf" | sed 's/^1$/0/')"
stop_server

fresh; : > "$T/calls.log"
srv STUB_STATUS_RC=1 'STUB_STATUS_JSON=' -- start
check "a server that does not answer: still exit 0" 0 "$rc"
has "a server that does not answer is reported" "does not answer" "$out"
has "with the end of its log" "stub server log line" "$out"
stop_server

fresh; : > "$T/calls.log"
srv OPENBAO_SETUP_MODE=client -- start
check "client mode: start does nothing" "" "$out"
check "client mode: no server, no config" "0 no" "$(grep -c '^server' "$T/calls.log") $([ -e "$T/state/server.hcl" ] && echo yes || echo no)"
out="$(env -i PATH="/usr/bin:/bin" HOME="$T/home" OPENBAO_STATE_DIR="$T/state" OPENBAO_FEATURE_DIR="$T/feat" bash "$script" start 2>&1)"
rc=$?
check "start without bao: exit 0" 0 "$rc"
has "start without bao: said" "bao not found on PATH" "$out"
if [ "$(id -u)" -ne 0 ]; then
  fresh; mkdir -p "$T/state"; chmod 0555 "$T/state"
  srv -- start
  check "start with an unwritable state dir: exit 0" 0 "$rc"
  has "start with an unwritable state dir: said" "not writable" "$out"
  chmod 0755 "$T/state"
fi
fresh

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
