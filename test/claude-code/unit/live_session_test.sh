#!/usr/bin/env bash
# Docker-free tests of the claude-code Feature's live-session rule in claude-host
# (a live session, one with a pid, in the folder refuses a second copy; the
# stale-pin warning, CLAUDE_HOST_UPDATE_PIN, CLAUDE_HOST_ALLOW_SECOND, ended sessions
# never count, `claude agents --json` missing), of the SessionStart hook claude-host-pin and
# of claude-fleet (running by id, running by dir, unset variable, start with --bg in
# the dir, --plan, --no-view, .env beating the environment, the settle wait for restored
# sessions, duplicates reported and stopped with `claude stop`, never `claude rm`). A fake `claude` on PATH
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
pin_sh="${CLAUDE_PIN_SH:-$root/src/claude-code/claude-host-pin.sh}"

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
cp "$pin_sh" "$bin/claude-host-pin"; chmod +x "$bin/claude-host-pin"
cat > "$bin/claude" <<'FAKE'
#!/bin/sh
# fake claude: `agents --json` answers from $FAKE_AGENTS (a file; FAKE_AGENTS_FAIL=1 fails,
# FAKE_AGENTS_GARBAGE=1 prints text). FAKE_SEQ=1: the Nth call (counted in $FAKE_COUNT) answers
# from $FAKE_AGENTS.N when that file exists. FAKE_ROTATE=1: odd calls answer from $FAKE_AGENTS,
# even ones from $FAKE_AGENTS.alt (a list that never settles). `stop <id>` and `rm <id>` are
# recorded (STOP / RM); stop then copies $FAKE_AGENTS.afterstop over $FAKE_AGENTS when it exists.
# Everything else is recorded in $FAKE_LOG. Never reads stdin.
if [ "$1" = agents ] && [ "$2" = --json ]; then
  [ -n "${FAKE_AGENTS_FAIL:-}" ] && { echo "error: unknown option '--json'" >&2; exit 1; }
  [ -n "${FAKE_AGENTS_GARBAGE:-}" ] && { echo "not json"; exit 0; }
  if [ -n "${FAKE_SEQ:-}${FAKE_ROTATE:-}" ]; then
    n=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_COUNT"
    if [ -n "${FAKE_SEQ:-}" ] && [ -f "$FAKE_AGENTS.$n" ]; then cat "$FAKE_AGENTS.$n"; exit 0; fi
    if [ -n "${FAKE_ROTATE:-}" ] && [ $((n % 2)) = 0 ]; then cat "$FAKE_AGENTS.alt"; exit 0; fi
  fi
  cat "$FAKE_AGENTS"; exit 0
fi
if [ "$1" = stop ]; then
  echo "STOP $2" >> "$FAKE_LOG"
  [ -f "$FAKE_AGENTS.afterstop" ] && cp "$FAKE_AGENTS.afterstop" "$FAKE_AGENTS"
  exit 0
fi
if [ "$1" = rm ]; then echo "RM $2" >> "$FAKE_LOG"; exit 0; fi
if [ "$1" = agents ]; then echo "VIEW" >> "$FAKE_LOG"; exit 0; fi
echo "claude $* | cwd=$(pwd -P) | HOST_SESSION=${HOST_SESSION:-}" >> "$FAKE_LOG"
FAKE
chmod +x "$bin/claude"
# the fake is what runs: first on PATH, executable (a real claude must never be reached)
check 'the fake claude is the one on PATH and executable' "$bin/claude" "$(PATH="$bin:$PATH" command -v claude; [ -x "$bin/claude" ] || echo notexec)"

A=11111111-1111-1111-1111-111111111111   # the pinned id
B=22222222-2222-2222-2222-222222222222   # the live id after /clear
C=33333333-3333-3333-3333-333333333333
D=44444444-4444-4444-4444-444444444444

mkdir -p "$T/work/sub" "$T/work/other"
work="$T/work"
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
transcript() { mkdir -p "$T/cfg/projects/$(slug "$1")"; : > "$T/cfg/projects/$(slug "$1")/$2.jsonl"; }

# agents <id:cwd[@pid]>...: write the fixture the fake claude answers with (pretty-printed as Claude Code does).
# pid defaults to 1; @none leaves the field out, @null and @0 are the other shapes of an ended session.
# A trailing #<ms> sets startedAt (default 1). agents_to <file> writes elsewhere (the fake's N-th answer).
agents_to() {
  local out="$1" first=1 e rest id cwd pid pidline st; shift
  { echo '['; for e in "$@"; do
      [ "$first" = 1 ] || echo '  ,'; first=0
      id="${e%%:*}"; rest="${e#*:}"; st=1; case "$rest" in *'#'*) st="${rest##*#}"; rest="${rest%%#*}" ;; esac
      cwd="${rest%@*}"; pid=1; [ "$rest" != "$cwd" ] && pid="${rest##*@}"
      case "$pid" in none) pidline='' ;; *) pidline="    \"pid\": $pid,"$'\n' ;; esac
      printf '  {\n%s    "cwd": "%s",\n    "kind": "interactive",\n    "startedAt": %s,\n    "sessionId": "%s",\n    "name": "x, y",\n    "status": "busy"\n  }\n' "$pidline" "$cwd" "$st" "$id"
    done; echo ']'; } > "$out"
}
agents() { agents_to "$T/agents.json" "$@"; }

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
agents "$B:$work@4242"
host "$work" HOST_SESSION=$A -- --model x
check 'live session (after /clear): starts nothing' '' "$log"
check 'live session: exit 1' 1 "$rc"
contains 'live session: names the running id' "$out" "session $B (pid 4242)"
contains 'live session: names the exact attach command' "$out" "claude attach $B"
contains 'stale pin: says the pin is stale' "$out" "pinned $A"
contains 'stale pin: says how to update it' "$out" 'CLAUDE_HOST_UPDATE_PIN=1'
host "$work" HOST_SESSION=$A CLAUDE_HOST_PRINT_FLAG=1 --
check 'print flag with a live session: nothing on stdout, exit 1' "|1" "$so|$rc"

agents "$A:$work@77"
host "$work" HOST_SESSION=$A -- 
check 'the pinned id is the live one: still refused' "|1" "$log|$rc"
contains 'the pinned id is live: pid named' "$out" "session $A (pid 77)"
lacks 'the pinned id is live: no stale warning' "$out" 'stale'
agents "$B:$work@10" "$C:$work@11"
host "$work" HOST_SESSION=$A -- 
contains 'two live: an attach command for each (first)' "$out" "claude attach $B"
contains 'two live: an attach command for each (second)' "$out" "claude attach $C"

host "$work" HOST_SESSION=$A CLAUDE_HOST_ALLOW_SECOND=1 -- 
check 'ALLOW_SECOND: today'"'"'s rule (transcript exists: resume)' "claude --resume $A | cwd=$work | HOST_SESSION=$A" "$log"
rm -rf "$T/cfg/projects"
host "$work" HOST_SESSION=$A CLAUDE_HOST_ALLOW_SECOND=1 -- 
check 'ALLOW_SECOND: no transcript creates' "claude --session-id $A | cwd=$work | HOST_SESSION=$A" "$log"
host "$work" HOST_SESSION=$A CLAUDE_HOST_ALLOW_SECOND=1 CLAUDE_HOST_PRINT_FLAG=1 -- 
check 'ALLOW_SECOND with print flag' "--session-id $A" "$so"

# ended sessions (no pid, null, 0) never count
transcript "$work" "$A"
for shape in none null 0; do
  agents "$B:$work@$shape" "$C:$work@$shape"
  host "$work" HOST_SESSION=$A -- 
  check "ended session ($shape) does not block" "claude --resume $A | cwd=$work | HOST_SESSION=$A" "$log"
done
agents "$B:$work@none" "$C:$work@9"
host "$work" HOST_SESSION=$A -- 
contains 'ended and live mixed: only the live one is named' "$out" "session $C (pid 9)"
lacks 'ended and live mixed: the ended one is not named' "$out" "$B"

# a live session elsewhere does not count
agents "$B:$work/other@5"
host "$work" HOST_SESSION=$A -- 
check 'live elsewhere only: pinned id resumed (transcript exists)' "claude --resume $A | cwd=$work | HOST_SESSION=$A" "$log"

# nothing live
agents
host "$work" HOST_SESSION=$A -- 
check 'nothing live, transcript exists: resumes the pinned id' "claude --resume $A | cwd=$work | HOST_SESSION=$A" "$log"
rm -rf "$T/cfg/projects"
host "$work" HOST_SESSION=$A -- 
check 'nothing live, no transcript: creates with the pinned id' "claude --session-id $A | cwd=$work | HOST_SESSION=$A" "$log"
host "$work" HOST_SESSION=$A CLAUDE_HOST_PRINT_FLAG=1 --
check 'nothing live, no transcript, print flag' "--session-id $A" "$so"

# two or more live: the same refusal, all listed
agents "$B:$work@10" "$C:$work@11"
host "$work" HOST_SESSION=$A -- 
check 'two live: starts nothing, exit 1' "|1" "$log|$rc"
contains 'two live: lists the first' "$out" "session $B (pid 10)"
contains 'two live: lists the second' "$out" "session $C (pid 11)"
agents "$B:$work@10" "$A:$work@11"
host "$work" HOST_SESSION=$A -- 
check 'two live, one pinned: still refused' "|1" "$log|$rc"

# claude agents --json unavailable
transcript "$work" "$A"; agents "$B:$work@3"
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

# CLAUDE_HOST_UPDATE_PIN (manual path, through claude-host-pin --replace)
mkdir -p "$T/repo/.devcontainer" "$T/repo/rooms/solis"
repo="$T/repo"
envf="$repo/.devcontainer/.env"
printf '# sessions\nHOST_SESSION=%s\nHOST_SESSION_SOLIS=%s\nOTHER=%s\n' "$C" "$A" "$A" > "$envf"
cp "$envf" "$T/env.before"
agents "$B:$repo/rooms/solis@8"
host "$repo/rooms/solis" HOST_SESSION=$A CLAUDE_HOST_UPDATE_PIN=1 -- 
check 'update pin: still refuses' "|1" "$log|$rc"
check 'update pin: only the line holding the old id changed' "# sessions
HOST_SESSION=$C
HOST_SESSION_SOLIS=$B
OTHER=$A" "$(cat "$envf")"
contains 'update pin: says so' "$out" "updated $envf"
cp "$T/env.before" "$envf"
host "$repo/rooms/solis" HOST_SESSION=$A -- 
check 'no update switch: .env untouched' "$(cat "$T/env.before")" "$(cat "$envf")"
agents "$B:$repo/rooms/solis@none"
host "$repo/rooms/solis" HOST_SESSION=$A CLAUDE_HOST_UPDATE_PIN=1 -- 
check 'update pin: an ended session is not a live id to write' "$(cat "$T/env.before")" "$(cat "$envf")"
printf 'HOST_SESSION=%s\nHOST_SESSION_SOLIS="%s"\n' "$A" "$A" > "$envf"
agents "$B:$repo/rooms/solis@8"
host "$repo/rooms/solis" HOST_SESSION=$A CLAUDE_HOST_UPDATE_PIN=1 -- 
contains 'update pin: two lines hold the id, refuses' "$out" '2 lines'
check 'update pin: two lines hold the id, file untouched' "$(printf 'HOST_SESSION=%s\nHOST_SESSION_SOLIS="%s"' "$A" "$A")" "$(cat "$envf")"
host "$repo/rooms/solis" HOST_SESSION=$A CLAUDE_HOST_UPDATE_PIN=1 CLAUDE_HOST_PIN_VAR=HOST_SESSION_SOLIS -- 
check 'update pin: CLAUDE_HOST_PIN_VAR picks the line, quotes kept' "$(printf 'HOST_SESSION=%s\nHOST_SESSION_SOLIS="%s"' "$A" "$B")" "$(cat "$envf")"
rm -f "$envf"; rmdir "$repo/.devcontainer"
host "$repo/rooms/solis" HOST_SESSION=$A CLAUDE_HOST_UPDATE_PIN=1 -- 
check 'update pin: no .env, nothing created' no "$([ -e "$repo/.devcontainer" ] && echo yes || echo no)"
contains 'update pin: no .env, says so' "$out" 'no .devcontainer/.env found'

# HOST_SESSION in the environment that .env does not hold: warn which was used
mkdir -p "$T/stale/.devcontainer"; printf 'HOST_SESSION=%s\nHOST_SESSION_SOLIS=%s\n' "$C" "$D" > "$T/stale/.devcontainer/.env"
agents
host "$T/stale" HOST_SESSION=$A -- 
contains 'env differs from .env: warns' "$out" "HOST_SESSION in the environment ($A) differs from HOST_SESSION in $T/stale/.devcontainer/.env ($C); using the environment value"
check 'env differs from .env: the environment value is still used' "claude --session-id $A | cwd=$T/stale | HOST_SESSION=$A" "$log"
host "$T/stale" HOST_SESSION=$D -- 
lacks 'id held by another .env line (a per-folder session): no warning' "$out" 'differs'
host "$T/stale" HOST_SESSION=$C -- 
lacks 'env equals .env: no warning' "$out" 'differs'

# old guarantees
host "$work" HOST_SESSION= -- 
check 'HOST_SESSION unset: plain claude' "claude  | cwd=$work | HOST_SESSION=" "$log"
host "$work" HOST_SESSION=nope -- 
check 'not a UUID: exit 2' 2 "$rc"

# ------------------------------------------------------- claude-host-pin (hook)
echo "# claude-host-pin"
mkdir -p "$T/hk/.devcontainer" "$T/hk/rooms/solis" "$T/hk/rooms/no-line"
hk="$T/hk"; henv="$hk/.devcontainer/.env"
# hook <cwd> <session_id> <source> [VAR=value ...]: run the hook with Claude Code's input JSON on stdin.
hook() {
  local c="$1" i="$2" src="$3"; shift 3
  hout="$(printf '{"session_id":"%s","transcript_path":"/x/y.jsonl","cwd":"%s","hook_event_name":"SessionStart","source":"%s"}' "$i" "$c" "$src" |
    (cd "$c" && env -u CLAUDE_HOST_PIN_CREATE -u CLAUDE_HOST_ENV_FILE PATH="$bin:$PATH" "$@" claude-host-pin 2>&1))"; hrc=$?
}
body() { printf '# sessions, kept\n\nHOST_SESSION=%s  # root\nexport HOST_SESSION_SOLIS="%s"\nOTHER=value with spaces\nHOST_SESSION_SOLIS_X=%s\nlast=1' "$A" "$A" "$A" > "$henv"; }
body; before="$(grep -v '^HOST_SESSION=' "$henv" | cksum)"
hook "$hk" "$B" clear
check 'hook: root writes HOST_SESSION' "HOST_SESSION=$B  # root" "$(grep '^HOST_SESSION=' "$henv")"
check 'hook: exit 0' 0 "$hrc"
check 'hook: every other byte kept (checksum of the other lines)' "$before" "$(grep -v '^HOST_SESSION=' "$henv" | cksum)"
check 'hook: no trailing newline invented' "last=1" "$(tail -n 1 "$henv")"
check 'hook: file still lacks a final newline' "1" "$(tail -c1 "$henv")"
hook "$hk/rooms/solis" "$B" clear
check 'hook: DIR mapping writes HOST_SESSION_SOLIS, quotes and export kept' "export HOST_SESSION_SOLIS=\"$B\"" "$(grep '^export HOST_SESSION_SOLIS=' "$henv")"
check 'hook: HOST_SESSION_SOLIS_X (a longer name) untouched' "HOST_SESSION_SOLIS_X=$A" "$(grep '^HOST_SESSION_SOLIS_X' "$henv")"
check 'hook: HOST_SESSION line unchanged by the sub-folder' "HOST_SESSION=$B  # root" "$(grep '^HOST_SESSION=' "$henv")"
cp "$henv" "$T/hk.same"; touch -d '2020-01-01' "$henv"
hook "$hk/rooms/solis" "$B" startup
check 'hook: same id, file not rewritten' "$(stat -c %Y "$T/hk.same" >/dev/null; echo 2020-01-01)" "$(date -d @"$(stat -c %Y "$henv")" +%F)"
hook "$hk/rooms/no-line" "$C" clear
check 'hook: no line for the variable, nothing added' "$(cksum < "$T/hk.same")" "$(cksum < "$henv")"
contains 'hook: no line, says so' "$hout" 'nothing added'
hook "$hk/rooms/no-line" "$C" clear CLAUDE_HOST_PIN_CREATE=1
check 'hook: PIN_CREATE adds the line' "HOST_SESSION_NO_LINE=$C" "$(tail -n 1 "$henv")"
check 'hook: PIN_CREATE keeps the rest' "$(cksum < "$T/hk.same")" "$(head -c "$(stat -c %s "$T/hk.same")" "$henv" | cksum)"
# bad input never fails
for bad in '' 'garbage' '{"session_id":"nope","cwd":"/"}' '{"cwd":"/nonexistent"}' "{\"session_id\":\"$B\",\"cwd\":\"/nonexistent/dir\"}"; do
  printf '%s' "$bad" | (cd / && PATH="$bin:$PATH" claude-host-pin >/dev/null 2>&1); r=$?
  check "hook never fails: input '${bad:0:25}'" 0 "$r"
done
printf '{"session_id":"%s","cwd":"%s"}' "$B" "$hk" | (cd "$hk" && PATH="$bin:$PATH" CLAUDE_HOST_ENV_FILE=/nonexistent/.env claude-host-pin >/dev/null 2>&1); check 'hook never fails: .env missing' 0 $?
body; cp "$henv" "$T/hk.keep"
hook "$hk" "not-a-uuid" clear
check 'hook: an invalid id leaves the file alone' "$(cksum < "$T/hk.keep")" "$(cksum < "$henv")"

# after /clear end to end: the hook writes the new id, the next claude-host resolves to it (nothing live)
body; rm -rf "$T/cfg/projects"; transcript "$hk" "$B"
hook "$hk" "$B" clear
agents "$B:$hk@none"
pinned="$(sed -n 's/^HOST_SESSION=\([^ ]*\).*/\1/p' "$henv")"
host "$hk" HOST_SESSION="$pinned" -- 
check 'after /clear: the pin holds the new id and claude-host resumes it' "claude --resume $B | cwd=$hk | HOST_SESSION=$B" "$log"

# ---------------------------------------------------------------- claude-fleet
echo "# claude-fleet"
mkdir -p "$T/fleet/.devcontainer" "$T/fleet/a" "$T/fleet/b" "$T/fleet/c"
fl="$T/fleet"
rm -rf "$T/cfg/projects"
# fleet <extra env as VAR=value ...> -- args: run in $fl; SESSIONS is $sessions; $out has stdout+stderr, $log what claude saw.
fleet() {
  local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  : > "$T/log"
  out="$(cd "$fl" && env -u SESSIONS_B64 -u HOST_SESSION -u HOST_SESSION_A -u HOST_SESSION_B -u HOST_SESSION_C -u CLAUDE_HOST_ENV_FILE -u FAKE_SEQ -u FAKE_ROTATE \
    PATH="$bin:$PATH" CLAUDE_CONFIG_DIR="$T/cfg" FAKE_AGENTS="$T/agents.json" FAKE_LOG="$T/log" FAKE_COUNT="$T/count" \
    FLEET_SETTLE_INTERVAL=0 SESSIONS="$sessions" "${envs[@]}" claude-fleet "$@" 2>&1)"; rc=$?
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
contains 'two live in one dir: reported as duplicates' "$out" 'duplicates: 2 live sessions'
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
contains '.env beats a stale environment' "$out" "HOST_SESSION=$A claude-host --bg --model sonnet"
lacks '.env beats a stale environment: the environment value is not used' "$out" "HOST_SESSION=$D"
fleet HOST_SESSION_C=$D -- --plan
contains 'environment is the fallback when .env has no line' "$out" "gamma: would start: cd $fl/c && HOST_SESSION=$D"
printf 'HOST_SESSION_A=\nHOST_SESSION_B=%s\n' "$B" > "$fl/.devcontainer/.env"
fleet HOST_SESSION_A=$D -- --plan
contains 'an empty .env line still wins over the environment' "$out" 'alpha: skipped, HOST_SESSION_A is not set'
printf 'HOST_SESSION_A=%s\nHOST_SESSION_B=%s\n' "$A" "$B" > "$fl/.devcontainer/.env"

for shape in none null 0; do
  agents "$A:$fl/a@$shape" "$C:$fl/a@$shape" "$B:$fl/b@$shape"
  fleet -- --no-view
  contains "fleet: an ended session ($shape) is not running, its folder is started" "$log" "cwd=$fl/a"
  lacks "fleet: an ended session ($shape) is not named running" "$out" 'running'
done

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

# ---------------------------------------------- settle wait for restored sessions
echo "# claude-fleet: settle, duplicates, never rm"
sessions="alpha|HOST_SESSION_A|a|
beta|HOST_SESSION_B|b|"
rm -f "$T"/agents.json.*
agents_to "$T/agents.json.1"                      # right after the rebuild: nothing yet
agents_to "$T/agents.json.2" "$A:$fl/a@10"        # the restore brings one back
agents "$A:$fl/a@10" "$B:$fl/b@11"                # then both
rm -f "$T/count"
fleet FAKE_SEQ=1 -- --no-view
check 'restore on the 2nd poll: nothing is started (no --bg)' 0 "$(printf '%s\n' "$log" | grep -c -- '--bg')"
check 'restore on the 2nd poll: both agents running' 2 "$(printf '%s\n' "$out" | grep -c ': running')"
check 'the waiting message is printed once' 1 "$(printf '%s\n' "$out" | grep -c 'waiting for restored sessions')"
check 'the list was read until two equal reads (4 polls) and once more to reconcile' 5 "$(cat "$T/count")"
rm -f "$T/count"
fleet FAKE_SEQ=1 -- --no-view --no-wait
check '--no-wait: one read only, no waiting message' "1|0" "$(cat "$T/count")|$(printf '%s\n' "$out" | grep -c 'waiting for')"
check '--no-wait: the early (empty) list is acted on: both started (the race it avoids)' 2 "$(printf '%s\n' "$log" | grep -c -- '--bg')"
rm -f "$T"/agents.json.*
agents "$A:$fl/a@10"; agents_to "$T/agents.json.alt"
rm -f "$T/count"
fleet FAKE_ROTATE=1 FLEET_SETTLE_TIMEOUT=1 -- --plan
contains 'a list that never settles: reconciles anyway with a note' "$out" 'still changing after 1s; reconciling anyway'
contains 'a list that never settles: still reconciles' "$out" 'plan only'
agents "$A:$fl/a@10" "$B:$fl/b@11"
rm -f "$T/count"
fleet FAKE_SEQ=1 -- --no-view
check 'a stable list: read twice to settle, once to reconcile' 3 "$(cat "$T/count" 2>/dev/null || echo 0)"
rm -f "$T/count"

# ------------------------------------------------------------------ duplicates
now_ms=$(( $(date +%s) * 1000 ))
old_ms=$(( now_ms - 7200000 )); new_ms=$(( now_ms - 300000 ))
rm -rf "$T/cfg/projects"; transcript "$fl/a" "$A"
agents "$A:$fl/a@10#$old_ms" "$C:$fl/a@11#$new_ms" "$B:$fl/b@12"
fleet -- --plan
contains 'duplicates: reported' "$out" 'alpha: duplicates: 2 live sessions'
contains 'duplicates: the pinned (live) id is kept even though it is older' "$out" "keep  $A pid 10 age 2h transcript yes"
contains 'duplicates: the other is an extra, with pid, age and transcript state' "$out" "extra $C pid 11 age 5m transcript no"
contains '--plan: names the --stop-duplicates hint' "$out" '--stop-duplicates'
check '--plan: stops and starts nothing' '' "$log"
fleet -- --no-view
check 'a normal run reports duplicates and stops nothing' 0 "$(printf '%s\n' "$log" | grep -c 'STOP\|RM')"
contains 'a normal run prints the --stop-duplicates hint' "$out" 'claude-fleet --stop-duplicates stops the extras'
fleet -- --plan --stop-duplicates
check '--plan --stop-duplicates: still stops nothing' '' "$log"
contains '--plan --stop-duplicates: says what it would stop' "$out" "would stop the extras"
cp "$T/agents.json" "$T/agents.dup"
agents "$A:$fl/a@10#$old_ms" "$B:$fl/b@12"; cp "$T/agents.json" "$T/agents.json.afterstop"; cp "$T/agents.dup" "$T/agents.json"
fleet -- --no-view --stop-duplicates
check '--stop-duplicates: stops the extra with claude stop, nothing else' "STOP $C" "$log"
contains '--stop-duplicates: re-reads the list and says the extra is gone' "$out" "the stopped extras are gone ($C)"
check '--stop-duplicates: exit 0' 0 "$rc"
check 'a stopped extra is not restarted (no --bg)' 0 "$(printf '%s\n' "$log" | grep -c -- '--bg')"
rm -f "$T/agents.json.afterstop"; cp "$T/agents.dup" "$T/agents.json"
fleet -- --no-view --stop-duplicates
contains 'an extra that is still live after claude stop is reported' "$out" "still live after claude stop: $C"
check 'an extra still live: exit 1' 1 "$rc"
# no live pin: the newest is kept; matched by folder
agents "$D:$fl/a@20#$old_ms" "$C:$fl/a@21#$new_ms" "$B:$fl/b@12"
fleet -- --plan
contains 'no live pin: the newest session is kept' "$out" "keep  $C pid 21"
contains 'no live pin: the older one is an extra' "$out" "extra $D pid 20"
# an ended duplicate never counts
agents "$A:$fl/a@10" "$C:$fl/a@none#$new_ms" "$B:$fl/b@12"
fleet -- --plan
lacks 'a session without a pid is not a duplicate' "$out" 'duplicates'
# never rm
agents "$A:$fl/a@10#$old_ms" "$C:$fl/a@11#$new_ms" "$B:$fl/b@12"
fleet -- --no-view --stop-duplicates
lacks 'never rm: the fake saw no rm' "$log" 'RM'
check 'claude-fleet never invokes rm on a session (guard on the code)' 0 "$(grep -v '^[[:space:]]*#' "$fleet_sh" | grep -cE 'claude[[:space:]]+rm|\brm[[:space:]]+"?\$')"
rm -f "$T"/agents.json.* "$T/agents.dup" "$T/count"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
