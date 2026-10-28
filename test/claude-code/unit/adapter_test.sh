#!/usr/bin/env bash
# Docker-free tests of the claude-code Feature's agent-adapter-claude (the agents Feature's
# adapter contract for Claude Code): `list` from `claude agents --json --all`, newest first,
# with the state (a pid is running; failed; everything else stopped) and the resolved folder;
# a session is the agent's by name AND folder (another folder, or a name that only starts
# with the agent's, never counts; "host (2)" does); every action takes the session's id,
# never the name; a stopped session is woken with --bg --resume <full session id>, never -c;
# resume refuses a running session; stop keeps the newest unless --extras, never rm;
# start-bg and new tag the session with --name. A fake `claude` keeps sessions in a table,
# renders them as `claude agents --json` does and records every other call with its folder.
# Part of `task lint` (`task test:claude-unit`). ADAPTER_SH points the test at another copy.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
adapter_sh="${ADAPTER_SH:-$root/src/claude-code/agent-adapter-claude.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

bin="$T/bin"; mkdir -p "$bin"
cp "$adapter_sh" "$bin/agent-adapter-claude"; chmod +x "$bin/agent-adapter-claude"
# The fake claude. $FAKE_TABLE: short id, sessionId, name, cwd, kind, pid (0 = none), state,
# startedAt, tab-separated. `agents --json [--all]` renders it (pid and state only when set,
# as Claude Code does; FAKE_NO_ALL=1 refuses --all). `--bg --name N` adds a running background
# session in the current folder; `--bg --resume <sessionId>` gives that session a pid again;
# `stop <id>` clears it. Every call but `agents` is recorded in $FAKE_CALLS as "folder|arg|arg";
# every `agents` call adds a line to $FAKE_READS. The ways a read goes wrong: FAKE_AGENTS_FAIL
# (exit 1, nothing printed), FAKE_WRAPPED (what a wrapper putting `--add-dir <dir>` first
# causes: Claude Code 2.1.312 says "error: unknown option '--json'", exit 1), FAKE_SLOW_FIRST
# (the first read sleeps 3 seconds, the later ones answer), FAKE_NOISE (a line before the
# array and one after it, the array pretty-printed).
cat > "$bin/claude" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = agents ]; then
  echo "$*" >> "$FAKE_READS"
  [ -n "${FAKE_NO_ALL:-}" ] && [ "${3:-}" = --all ] && { echo "error: unknown option '--all'" >&2; exit 1; }
  [ -n "${FAKE_AGENTS_FAIL:-}" ] && exit 1
  [ -n "${FAKE_WRAPPED:-}" ] && { echo "error: unknown option '--json'" >&2; exit 1; }
  [ -n "${FAKE_SLOW_FIRST:-}" ] && [ "$(grep -c . "$FAKE_READS")" -eq 1 ] && sleep 3
  if [ -n "${FAKE_NOISE:-}" ]; then
    echo "Restarting the background service after an update…"
    printf '[\n'; first=1
    while IFS=$'\t' read -r id sid name cwd kind pid state started; do
      [ -n "$sid" ] || continue
      [ -z "$first" ] && printf ',\n'; first=''
      printf '  {\n    "id": "%s",\n    "cwd": "%s",\n    "kind": "%s",\n    "startedAt": %s,\n    "sessionId": "%s",\n    "name": "%s"' "$id" "$cwd" "$kind" "$started" "$sid" "$name"
      [ "$pid" != 0 ] && printf ',\n    "pid": %s' "$pid"
      printf '\n  }'
    done < "$FAKE_TABLE"
    printf '\n]\n'; echo "(1 more line after the list)"; exit 0
  fi
  printf '['; first=1
  while IFS=$'\t' read -r id sid name cwd kind pid state started; do
    [ -n "$sid" ] || continue
    [ -z "$first" ] && printf ',\n'; first=''
    printf '{"id":"%s","cwd":"%s","kind":"%s","startedAt":%s,"sessionId":"%s","name":"%s"' "$id" "$cwd" "$kind" "$started" "$sid" "$name"
    [ "$pid" != 0 ] && printf ',"pid":%s' "$pid"
    [ "$state" != - ] && printf ',"state":"%s"' "$state"
    printf '}'
  done < "$FAKE_TABLE"
  printf ']\n'; exit 0
fi
line="$(pwd -P)"; for a in "$@"; do line="$line|$a"; done
echo "$line" >> "$FAKE_CALLS"
n=$(( $(grep -c . "$FAKE_TABLE") + 1 ))
if [ "$1" = --bg ] && [ "$2" = --name ]; then
  printf 'b%07d\tsess-%s-0000-0000-0000-000000000000\t%s\t%s\tbackground\t%s\trunning\t%s\n' "$n" "$n" "$3" "$(pwd -P)" "$((100 + n))" "$((2000 + n))" >> "$FAKE_TABLE"
  echo "started b$n"
elif [ "$1" = --bg ] && [ "$2" = --resume ]; then
  awk -F'\t' -v OFS='\t' -v s="$3" '$2 == s { $6 = 999; $7 = "running" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
elif [ "$1" = stop ]; then
  awk -F'\t' -v OFS='\t' -v s="$2" '$1 == s { $6 = 0; $7 = "done" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
fi
exit 0
FAKE
chmod +x "$bin/claude"

repo="$T/repo"; mkdir -p "$repo/rooms/review"
export FAKE_TABLE="$T/table" FAKE_CALLS="$T/calls" FAKE_READS="$T/reads" AGENT_ADAPTER_WAIT=0 AGENT_ADAPTER_CLAUDE_PAUSE=0
table() { # rows: id sid name cwd kind pid state started
  : > "$FAKE_TABLE"; : > "$FAKE_CALLS"
  local r; for r in "$@"; do printf '%s\n' "$r" | tr '|' '\t' >> "$FAKE_TABLE"; done
}
ad() { (cd "$T" && PATH="$bin:$PATH" agent-adapter-claude "$@" 2>&1); }
calls() { tr '\n' ';' < "$FAKE_CALLS"; cat "$FAKE_CALLS" >> "$T/all-calls"; }

table \
  "a1|sess-a1|host|$repo|background|0|done|1000" \
  "a2|sess-a2|host|$repo/|background|201|-|3000" \
  "a3|sess-a3|host-review|$repo|background|202|-|4000" \
  "a4|sess-a4|host|$repo/rooms/review|background|203|-|5000" \
  "a5|sess-a5|reviewer|$repo/rooms/review|interactive|204|busy|2500" \
  "a6|sess-a6|old|$repo|background|0|failed|500"
out="$(ad list)"; rc=$?
check 'list: exit 0' 0 "$rc"
check 'list: name, session id, state, folder; newest first; a pid is running, failed kept, done is stopped' \
  "host	sess-a4	running	$repo/rooms/review;host-review	sess-a3	running	$repo;host	sess-a2	running	$repo;reviewer	sess-a5	running	$repo/rooms/review;host	sess-a1	stopped	$repo;old	sess-a6	failed	$repo;" \
  "$(printf '%s\n' "$out" | tr '\n' ';')"
out="$(FAKE_NO_ALL=1 ad list)"
contains 'list: without --all (older Claude Code) the plain list' "$out" 'sess-a2'
: > "$FAKE_READS"
out="$(FAKE_AGENTS_FAIL=1 ad list)"; rc=$?
check 'list: an unreadable list is exit 1' 1 "$rc"
check 'list: a read that printed nothing is tried once more' 2 "$(grep -c . "$FAKE_READS")"
contains 'list: the reason names the call and its exit code' "$out" "'claude agents --json --all' exited 1"

out="$(FAKE_NOISE=1 ad list)"; rc=$?
check 'list: a line before and after a pretty-printed array: exit 0' 0 "$rc"
check 'list: a line before and after a pretty-printed array: the sessions read' \
  "host	sess-a4	running	$repo/rooms/review;host-review	sess-a3	running	$repo;host	sess-a2	running	$repo;reviewer	sess-a5	running	$repo/rooms/review;host	sess-a1	stopped	$repo;old	sess-a6	stopped	$repo;" \
  "$(printf '%s\n' "$out" | tr '\n' ';')"

: > "$FAKE_READS"
out="$(FAKE_SLOW_FIRST=1 AGENT_ADAPTER_CLAUDE_TIMEOUT=1 ad list)"; rc=$?
check 'list: a first read that times out, then answers: exit 0' 0 "$rc"
contains 'list: a first read that times out, then answers: the sessions' "$out" 'sess-a2'
check 'list: a first read that times out is not asked again without --all' '--json --all;--json --all;' "$(tr '\n' ';' < "$FAKE_READS" | sed 's/agents //g')"

: > "$FAKE_READS"
out="$(FAKE_WRAPPED=1 ad list)"; rc=$?
check 'list: a wrapper rewriting the arguments: exit 1' 1 "$rc"
contains 'list: a wrapper: the CLI'"'"'s own line, as it is' "$out" "exited 1: error: unknown option '--json'"
contains 'list: a wrapper: names what claude is here' "$out" "may be rewriting its arguments: claude here is $bin/claude"
check 'list: a quick error with a message is not asked again' 1 "$(grep -c . "$FAKE_READS")"
out="$(ad supports)"
contains 'supports: names the verbs' "$out" 'wake'

: > "$FAKE_CALLS"
out="$(ad attach host "$repo")"; rc=$?
check 'attach: by the short id of the session with that name in that folder (not host-review, not another folder)' "$T|attach|a2;" "$(calls)"

table "a1|sess-a1|host|$repo|background|0|done|1000"
out="$(ad attach host "$repo")"
check 'attach a stopped session: claude attach <id> (restarts it)' "$T|attach|a1;" "$(calls)"

table "a5|sess-a5|reviewer|$repo|interactive|204|busy|2500"
out="$(ad attach reviewer "$repo")"; rc=$?
check 'attach an interactive session: refused (exit 1)' 1 "$rc"
contains 'attach an interactive session: says a terminal holds it' "$out" 'held by a terminal'
check 'attach an interactive session: nothing called' "" "$(calls)"

table "a1|sess-a1|host|$repo|background|201|-|1000" "a7|sess-a7|host (2)|$repo|background|207|-|7000"
out="$(ad attach host "$repo")"
check 'two sessions by one name ("host (2)"): the newest' "$T|attach|a7;" "$(calls)"
contains 'two sessions by one name: the others are reported' "$out" '2 running sessions; using the newest (sess-a7)'

table
out="$(cd "$T" && PATH="$bin:$PATH" agent-adapter-claude start-bg host "$repo" -- --remote-control --model opus 2>/dev/null)"; rc=$?
check 'start-bg: exit 0' 0 "$rc"
check 'start-bg: claude --bg --name <name> <args> in the folder' "$repo|--bg|--name|host|--remote-control|--model|opus;" "$(calls)"
check 'start-bg: prints the session id on stdout (claude'"'"'s own output goes to stderr)' 'sess-1-0000-0000-0000-000000000000' "$out"

table "a1|sess-a1|host|$repo|background|0|done|1000" "a8|sess-a8|host|$repo|background|0|failed|1500" "a9|sess-a9|host|$repo/rooms/review|background|0|done|9000"
out="$(ad wake host "$repo" -- --remote-control)"; rc=$?
check 'wake: the newest stopped or failed session of the agent, by its full id, in the background' "$repo|--bg|--resume|sess-a8;" "$(calls)"
lacks 'wake: never -c' "$(calls)" '|-c'
table
out="$(ad wake host "$repo")"; rc=$?
check 'wake with nothing to wake: exit 1' 1 "$rc"

table "a1|sess-a1|reviewer|$repo/rooms/review|interactive|0|done|1000"
out="$(ad resume reviewer "$repo/rooms/review" -- --model sonnet)"; rc=$?
check 'resume: claude --resume <full session id> <args> in the folder' "$repo/rooms/review|--resume|sess-a1|--model|sonnet;" "$(calls)"
table "a1|sess-a1|reviewer|$repo/rooms/review|interactive|301|busy|1000"
out="$(ad resume reviewer "$repo/rooms/review")"; rc=$?
check 'resume a running session: refused (exit 1, a second copy)' 1 "$rc"
check 'resume a running session: nothing called' "" "$(calls)"
table
out="$(ad resume reviewer "$repo/rooms/review")"; rc=$?
check 'resume with nothing to resume: exit 1' 1 "$rc"
contains 'resume with nothing to resume: says how to start one' "$out" 'task agents -- reviewer'
table "a1|sess-a1|reviewer|$repo/rooms/review|interactive|0|done|1000"
out="$(FAKE_AGENTS_FAIL=1 ad resume reviewer "$repo/rooms/review" -- --model sonnet)"; rc=$?
check 'resume when the list cannot be read: Claude Code'"'"'s own picker (--resume without an id), never a new session' "$repo/rooms/review|--resume|--model|sonnet;" "$(calls)"
contains 'resume when the list cannot be read: says to pick the agent' "$out" "pick 'reviewer'"
out="$(ad hint reviewer "$repo/rooms/review")"; rc=$?
check 'hint: exit 0' 0 "$rc"
contains 'hint: how to resume by hand' "$out" "cd '$repo/rooms/review' && claude --resume (pick 'reviewer')"
contains 'supports: names hint' "$(ad supports)" 'hint'

table
out="$(ad new reviewer "$repo/rooms/review" -- --model sonnet)"
check 'new: claude --name <name> <args> in the folder' "$repo/rooms/review|--name|reviewer|--model|sonnet;" "$(calls)"

table "a1|sess-a1|host|$repo|background|201|-|1000" "a7|sess-a7|host (2)|$repo|background|207|-|7000"
out="$(ad stop host "$repo")"
check 'stop: the newest by its id' "$T|stop|a7;" "$(calls)"
table "a1|sess-a1|host|$repo|background|201|-|1000" "a7|sess-a7|host (2)|$repo|background|207|-|7000"
out="$(ad stop host "$repo" --extras)"
check 'stop --extras: the others, never the newest' "$T|stop|a1;" "$(calls)"
table "a1|sess-a1|host|$repo|background|0|done|1000"
out="$(ad stop host "$repo")"; rc=$?
check 'stop when not running: exit 0, nothing called' "0:" "$rc:$(calls)"

table "a1|sess-a1|host|$repo|background|0|done|1000" "a2|sess-a2|host|$repo|background|201|-|500"
out="$(ad logs host "$repo")"
check 'logs: the running session first, by its id' "$T|logs|a2;" "$(calls)"

out="$(ad frob host "$repo")"; rc=$?
check 'an unknown verb: exit 3 (not supported)' 3 "$rc"
out="$(ad attach)"; rc=$?
check 'a verb without name and folder: exit 2' 2 "$rc"
out="$(ad attach host "$T/nope")"; rc=$?
check 'a missing folder: exit 1' 1 "$rc"

# Across every call above: never rm, never -c or --continue; in the code, never an action by name.
all="$(cat "$T/all-calls" 2>/dev/null)"
lacks 'never claude rm' "$all" '|rm|'
lacks 'never -c' "$all" '|-c'
lacks 'never --continue' "$all" '|--continue'
# shellcheck disable=SC2016  # a literal $NAME is what is looked for
if grep -v '^[[:space:]]*#' "$adapter_sh" | grep -E -- 'claude (attach|stop|logs) "\$NAME"|claude [^|]*[[:space:]]-c( |$)|--continue' >/dev/null; then
  fail=$((fail + 1)); echo "FAIL - the adapter never acts by name and never uses -c/--continue"
else
  pass=$((pass + 1)); echo "ok   - the adapter never acts by name and never uses -c/--continue"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
