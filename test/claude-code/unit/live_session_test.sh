#!/usr/bin/env bash
# Docker-free tests of the claude-code Feature's live-session rule in claude-host
# (a live session in the folder wins over the pinned id, the stale-pin warning and
# CLAUDE_HOST_UPDATE_PIN, several live sessions, `claude agents --json` missing) and
# of claude-fleet (running by id, running by dir, unset variable, start with --bg in
# the dir, --plan, --no-view, the environment beating .env). A fake `claude` on PATH
# answers `agents --json` from a fixture and records every other call; the scripts
# under test are copied to a temp bin as claude-host and claude-fleet. Part of `task lint`
# (`task test:claude-unit`). CLAUDE_HOST_SH and CLAUDE_FLEET_SH point the tests at
# other copies of the scripts (used to show each test fails when the code it covers
# is broken).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
host_sh="${CLAUDE_HOST_SH:-$root/src/claude-code/claude-host.sh}"
fleet_sh="${CLAUDE_FLEET_SH:-$root/src/claude-code/claude-fleet.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
contains() { # <name> <text> <needle>
  case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac
}
lacks() { # <name> <text> <needle>
  case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac
}

bin="$T/bin"; mkdir -p "$bin" "$T/cfg"
cp "$host_sh" "$bin/claude-host"; chmod +x "$bin/claude-host"
cp "$fleet_sh" "$bin/claude-fleet"; chmod +x "$bin/claude-fleet"
cat > "$bin/claude" <<'FAKE'
#!/bin/sh
# fake claude: `agents --json` answers from $FAKE_AGENTS (a file; FAKE_AGENTS_FAIL=1 fails,
# FAKE_AGENTS_GARBAGE=1 prints text); everything else is recorded in $FAKE_LOG.
if [ "$1" = agents ] && [ "$2" = --json ]; then
  [ -n "${FAKE_AGENTS_FAIL:-}" ] && { echo "error: unknown option '--json'" >&2; exit 1; }
  [ -n "${FAKE_AGENTS_GARBAGE:-}" ] && { echo "not json"; exit 0; }
  cat "$FAKE_AGENTS"; exit 0
fi
if [ "$1" = agents ]; then echo "VIEW" >> "$FAKE_LOG"; exit 0; fi
echo "claude $* | cwd=$(pwd -P) | HOST_SESSION=${HOST_SESSION:-}" >> "$FAKE_LOG"
FAKE
chmod +x "$bin/claude"

A=11111111-1111-1111-1111-111111111111   # the pinned id
B=22222222-2222-2222-2222-222222222222   # the live id after /clear
C=33333333-3333-3333-3333-333333333333
D=44444444-4444-4444-4444-444444444444

mkdir -p "$T/work/sub" "$T/work/other"
work="$T/work"
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
transcript() { mkdir -p "$T/cfg/projects/$(slug "$1")"; : > "$T/cfg/projects/$(slug "$1")/$2.jsonl"; }

# agents <id:cwd>...: write the fixture the fake claude answers with (pretty-printed as Claude Code does).
agents() {
  local first=1 e
  { echo '['; for e in "$@"; do
      [ "$first" = 1 ] || echo '  ,'; first=0
      printf '  {\n    "pid": 1,\n    "cwd": "%s",\n    "kind": "interactive",\n    "startedAt": 1,\n    "sessionId": "%s",\n    "name": "x, y",\n    "status": "busy"\n  }\n' "${e#*:}" "${e%%:*}"
    done; echo ']'; } > "$T/agents.json"
}

# host <dir> [VAR=value ...] -- args: run claude-host in <dir>; output in $out (stderr too), stdout in $so, status in $rc.
host() {
  local d="$1" envs=(); shift
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  : > "$T/log"
  out="$(cd "$d" && env -u CLAUDE_HOST_UPDATE_PIN -u CLAUDE_HOST_PRINT_FLAG -u CLAUDE_HOST_PIN_VAR -u CLAUDE_HOST_ENV_FILE -u CLAUDE_HOST_LIVE_CHECK \
    PATH="$bin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" FAKE_AGENTS="$T/agents.json" FAKE_LOG="$T/log" "${envs[@]}" claude-host "$@" 2>"$T/err")"; rc=$?
  so="$out"; out="$out$(cat "$T/err")"; log="$(cat "$T/log")"
}

# ---------------------------------------------------------------- claude-host
echo "# claude-host"
rm -rf "$T/cfg/projects"; transcript "$work" "$A"
agents "$B:$work"
host "$work" HOST_SESSION=$A -- --model x
check 'after /clear: resumes the live id' "claude --resume $B --model x | cwd=$work | HOST_SESSION=$A" "$log"
contains 'after /clear: says the pinned id is stale' "$out" "pinned $A"
contains 'after /clear: names the live session' "$out" "session $B is live in this folder"
check 'after /clear: exit 0' 0 "$rc"
lacks 'after /clear: .env is not mentioned as updated' "$out" 'updated'

host "$work" HOST_SESSION=$A CLAUDE_HOST_PRINT_FLAG=1 --
check 'print flag after /clear: prints the live resume flag on stdout only' "--resume $B" "$so"
check 'print flag after /clear: starts nothing' '' "$log"

agents "$A:$work"
host "$work" HOST_SESSION=$A -- 
check 'pinned id is live: resumes it' "claude --resume $A | cwd=$work | HOST_SESSION=$A" "$log"
lacks 'pinned id is live: no stale warning' "$out" 'stale'

# the session is live but has no transcript (just started): still attach, never --session-id
rm -rf "$T/cfg/projects"; agents "$A:$work"
host "$work" HOST_SESSION=$A -- 
contains 'live without transcript: resumes, never creates' "$log" "--resume $A"

# a live session in another folder does not count
rm -rf "$T/cfg/projects"; transcript "$work" "$A"; agents "$B:$work/other"
host "$work" HOST_SESSION=$A -- 
check 'live elsewhere only: pinned id resumed (transcript exists)' "claude --resume $A | cwd=$work | HOST_SESSION=$A" "$log"
lacks 'live elsewhere only: no live message' "$out" 'live in this folder'

# nothing live
agents
host "$work" HOST_SESSION=$A -- 
check 'nothing live, transcript exists: resumes the pinned id' "claude --resume $A | cwd=$work | HOST_SESSION=$A" "$log"
rm -rf "$T/cfg/projects"
host "$work" HOST_SESSION=$A -- 
check 'nothing live, no transcript: creates with the pinned id' "claude --session-id $A | cwd=$work | HOST_SESSION=$A" "$log"
agents
host "$work" HOST_SESSION=$A CLAUDE_HOST_PRINT_FLAG=1 --
check 'nothing live, no transcript, print flag' "--session-id $A" "$so"

# two live in the folder
agents "$B:$work" "$C:$work"
host "$work" HOST_SESSION=$A -- 
check 'two live, none pinned: starts nothing' '' "$log"
check 'two live, none pinned: exit 1' 1 "$rc"
contains 'two live, none pinned: lists the first id' "$out" "$B"
contains 'two live, none pinned: lists the second id' "$out" "$C"
host "$work" HOST_SESSION=$A CLAUDE_HOST_PRINT_FLAG=1 --
check 'two live, none pinned, print flag: nothing on stdout, exit 1' "|1" "$so|$rc"
agents "$B:$work" "$A:$work"
host "$work" HOST_SESSION=$A -- 
check 'two live, one is the pinned id: uses it' "claude --resume $A | cwd=$work | HOST_SESSION=$A" "$log"

# claude agents --json unavailable
rm -rf "$T/cfg/projects"; transcript "$work" "$A"; agents "$B:$work"
host "$work" HOST_SESSION=$A FAKE_AGENTS_FAIL=1 -- 
check 'agents --json fails, transcript exists: resumes the pinned id' "claude --resume $A | cwd=$work | HOST_SESSION=$A" "$log"
contains 'agents --json fails: one-line note' "$out" "'claude agents --json' is unavailable"
host "$work" HOST_SESSION=$A FAKE_AGENTS_GARBAGE=1 -- 
check 'agents --json prints no JSON: the same fallback' "claude --resume $A | cwd=$work | HOST_SESSION=$A" "$log"
rm -rf "$T/cfg/projects"
host "$work" HOST_SESSION=$A FAKE_AGENTS_FAIL=1 -- 
check 'agents --json fails, no transcript: creates with the pinned id' "claude --session-id $A | cwd=$work | HOST_SESSION=$A" "$log"
host "$work" HOST_SESSION=$A CLAUDE_HOST_LIVE_CHECK=0 -- 
check 'CLAUDE_HOST_LIVE_CHECK=0 skips the check' "claude --session-id $A | cwd=$work | HOST_SESSION=$A" "$log"

# CLAUDE_HOST_UPDATE_PIN
mkdir -p "$T/repo/.devcontainer" "$T/repo/rooms/solis"
repo="$T/repo"
envf="$repo/.devcontainer/.env"
printf '# sessions\nHOST_SESSION=%s\nHOST_SESSION_SOLIS=%s\nOTHER=%s\n' "$C" "$A" "$A" > "$envf"
cp "$envf" "$T/env.before"
agents "$B:$repo/rooms/solis"
host "$repo/rooms/solis" HOST_SESSION=$A CLAUDE_HOST_UPDATE_PIN=1 -- 
check 'update pin: resumes the live id' "claude --resume $B | cwd=$repo/rooms/solis | HOST_SESSION=$A" "$log"
check 'update pin: only the line holding the old id changed' "# sessions
HOST_SESSION=$C
HOST_SESSION_SOLIS=$B
OTHER=$A" "$(cat "$envf")"
contains 'update pin: says so' "$out" "updated $envf"
host "$repo/rooms/solis" HOST_SESSION=$B CLAUDE_HOST_UPDATE_PIN=1 -- 
check 'update pin: nothing stale, file untouched' "$(printf '# sessions\nHOST_SESSION=%s\nHOST_SESSION_SOLIS=%s\nOTHER=%s' "$C" "$B" "$A")" "$(cat "$envf")"
# without the switch the file stays; an explicit variable name picks the line; two lines holding the id refuse
cp "$T/env.before" "$envf"; agents "$B:$repo/rooms/solis"
host "$repo/rooms/solis" HOST_SESSION=$A -- 
check 'no update switch: .env untouched' "$(cat "$T/env.before")" "$(cat "$envf")"
printf 'HOST_SESSION=%s\nHOST_SESSION_SOLIS="%s"\n' "$A" "$A" > "$envf"
host "$repo/rooms/solis" HOST_SESSION=$A CLAUDE_HOST_UPDATE_PIN=1 -- 
contains 'update pin: two lines hold the id, refuses' "$out" '2 lines'
check 'update pin: two lines hold the id, file untouched' "$(printf 'HOST_SESSION=%s\nHOST_SESSION_SOLIS="%s"' "$A" "$A")" "$(cat "$envf")"
host "$repo/rooms/solis" HOST_SESSION=$A CLAUDE_HOST_UPDATE_PIN=1 CLAUDE_HOST_PIN_VAR=HOST_SESSION_SOLIS -- 
check 'update pin: CLAUDE_HOST_PIN_VAR picks the line, quotes kept' "$(printf 'HOST_SESSION=%s\nHOST_SESSION_SOLIS="%s"' "$A" "$B")" "$(cat "$envf")"
rm -f "$envf"; rmdir "$repo/.devcontainer"
host "$repo/rooms/solis" HOST_SESSION=$A CLAUDE_HOST_UPDATE_PIN=1 -- 
check 'update pin: no .env, nothing created' no "$([ -e "$repo/.devcontainer" ] && echo yes || echo no)"
contains 'update pin: no .env, says so' "$out" 'no .devcontainer/.env found'
check 'update pin: no .env, still resumes the live id' "claude --resume $B | cwd=$repo/rooms/solis | HOST_SESSION=$A" "$log"

# old guarantees
host "$work" HOST_SESSION= -- 
check 'HOST_SESSION unset: plain claude' "claude  | cwd=$work | HOST_SESSION=" "$log"
host "$work" HOST_SESSION=nope -- 
check 'not a UUID: exit 2' 2 "$rc"

# ---------------------------------------------------------------- claude-fleet
echo "# claude-fleet"
mkdir -p "$T/fleet/.devcontainer" "$T/fleet/a" "$T/fleet/b" "$T/fleet/c"
fl="$T/fleet"
rm -rf "$T/cfg/projects"
# fleet <extra env as VAR=value ...> -- args: run in $fl; SESSIONS is $sessions; $out has stdout+stderr, $log what claude saw.
fleet() {
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  : > "$T/log"
  out="$(cd "$fl" && env -u SESSIONS_B64 -u HOST_SESSION -u HOST_SESSION_A -u HOST_SESSION_B -u HOST_SESSION_C -u CLAUDE_HOST_ENV_FILE \
    PATH="$bin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" FAKE_AGENTS="$T/agents.json" FAKE_LOG="$T/log" SESSIONS="$sessions" "${envs[@]}" claude-fleet "$@" 2>&1)"; rc=$?
  log="$(cat "$T/log")"
}
sessions="alpha|HOST_SESSION_A|a|--model sonnet
beta|HOST_SESSION_B|b|
gamma|HOST_SESSION_C|c|--plan-mode x"
printf 'HOST_SESSION_A=%s\nHOST_SESSION_B=%s\n' "$A" "$B" > "$fl/.devcontainer/.env"

agents "$A:$fl/elsewhere"
fleet --
contains 'by id: running even when its cwd differs' "$out" "alpha: running ($A)"
lacks 'by id: not started' "$log" "$A"
contains 'start: --resume or --session-id carries the pinned id and --bg is passed through' "$log" "claude --session-id $B --bg | cwd=$fl/b | HOST_SESSION=$B"
contains 'unset variable: said and skipped' "$out" 'gamma: skipped, HOST_SESSION_C is not set'
lacks 'unset variable: nothing started for it' "$log" "cwd=$fl/c"
check 'opens the view last' 'VIEW' "$(printf '%s\n' "$log" | tail -n 1)"
check 'exit 0' 0 "$rc"

agents "$C:$fl/a"
fleet -- --no-view
contains 'by dir: running although the id differs (after /clear)' "$out" "alpha: running (live in a as $C, not as $A"
lacks 'by dir: no start in that dir' "$log" "cwd=$fl/a"
contains 'by dir: the other one is started' "$log" "cwd=$fl/b"
lacks '--no-view: the view is not opened' "$log" 'VIEW'

agents "$C:$fl/a" "$D:$fl/a" "$B:$fl/b"
fleet -- --no-view
contains 'two live in one dir: counts as running' "$out" 'alpha: running'
contains 'two live in one dir: reported' "$out" '2 live sessions work in a'
lacks 'two live in one dir: nothing started there' "$log" "cwd=$fl/a"
lacks 'running by id: no start' "$log" "cwd=$fl/b"

agents
fleet -- --plan
check '--plan: nothing started, no view' '' "$log"
contains '--plan: says what it would start' "$out" "alpha: would start: cd $fl/a && HOST_SESSION=$A claude-host --bg --model sonnet"
contains '--plan: for the other too' "$out" "beta: would start: cd $fl/b && HOST_SESSION=$B claude-host --bg"
contains '--plan: states it started nothing' "$out" 'plan only, nothing started'
fleet -- --plan --no-view
check '--plan with --no-view: nothing started' '' "$log"

fleet --
contains 'extra args reach claude after --bg' "$log" "claude --session-id $A --bg --model sonnet | cwd=$fl/a | HOST_SESSION=$A"
contains 'a transcript makes claude-host resume' "$out" 'alpha: starting'
transcript "$fl/a" "$A"
fleet -- --no-view
contains 'with a transcript: --resume ... --bg' "$log" "claude --resume $A --bg --model sonnet | cwd=$fl/a | HOST_SESSION=$A"

agents
fleet HOST_SESSION_A=$D -- --plan
contains 'environment beats .env' "$out" "HOST_SESSION=$D claude-host --bg --model sonnet"
lacks 'environment beats .env: the .env value is not used' "$out" "HOST_SESSION=$A "

agents
sessions="alpha|HOST_SESSION_A|a|
twin|HOST_SESSION_B|a|"
fleet -- --no-view
check 'two lines for one folder: one start' 1 "$(printf '%s\n' "$log" | grep -c -- '--bg')"
contains 'two lines for one folder: the second is running' "$out" "twin: running (live in a as $A"

agents "$A:$fl/a" "$B:$fl/b"
sessions="alpha|HOST_SESSION_A|a|
beta|HOST_SESSION_B|b|
"
fleet -- --no-view
check 'all running: nothing started' '' "$log"
fleet FAKE_AGENTS_FAIL=1 -- --no-view
check 'agents --json unavailable: starts nothing, exit 1' "|1" "$log|$rc"
contains 'agents --json unavailable: says why' "$out" "'claude agents --json' is unavailable"
fleet SESSIONS_B64="$(printf 'alpha|HOST_SESSION_A|a|' | base64 -w0)" SESSIONS= -- --no-view
contains 'SESSIONS_B64 is read' "$out" 'alpha: running'
fleet SESSIONS= -- --plan
check 'no SESSIONS: exit 2' 2 "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
