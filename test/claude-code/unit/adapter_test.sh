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
# session in the current folder and keeps its flags as its saved options ($CLAUDE_CONFIG_DIR/
# jobs/<id>/state.json, respawnFlags); `--bg --resume <sessionId>` gives that session a pid again,
# and with any flag after it starts a copy under a new id (c...) instead, as Claude Code does;
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
    # busy, idle and waiting are what Claude Code reports as "status" (a live process);
    # the rest (working, blocked, done, failed, stopped) as a background session's "state"
    case "$state" in -) ;; busy | idle | waiting) printf ',"status":"%s"' "$state" ;; *) printf ',"state":"%s"' "$state" ;; esac
    printf '}'
  done < "$FAKE_TABLE"
  printf ']\n'; exit 0
fi
line="$(pwd -P)"; for a in "$@"; do line="$line|$a"; done
echo "$line" >> "$FAKE_CALLS"
n=$(( $(grep -c . "$FAKE_TABLE") + 1 ))
# saved <short id> <flags...>: the session's saved options, as Claude Code keeps them
saved() {
  local d="$CLAUDE_CONFIG_DIR/jobs/$1" a sep=''; shift; mkdir -p "$d"
  { printf '{\n  "state": "running",\n  "respawnFlags": ['
    for a in "$@"; do a="${a//\\/\\\\}"; a="${a//\"/\\\"}"; printf '%s\n    "%s"' "$sep" "$a"; sep=','; done
    printf '\n  ],\n  "backend": "daemon"\n}\n'; } > "$d/state.json"
}
if [ "$1" = --bg ] && [ "$2" = --name ]; then
  printf 'b%07d\tsess-%s-0000-0000-0000-000000000000\t%s\t%s\tbackground\t%s\trunning\t%s\n' "$n" "$n" "$3" "$(pwd -P)" "$((100 + n))" "$((2000 + n))" >> "$FAKE_TABLE"
  shift; saved "$(printf 'b%07d' "$n")" "$@"
  echo "started b$n"
elif [ "$1" = --bg ] && [ "$2" = --resume ] && [ $# -gt 3 ]; then
  # flags with --resume: Claude Code 2.1.308 starts a copy under a new id with those flags
  nm=''; prev=''; for a in "$@"; do [ "$prev" = --name ] && nm="$a"; prev="$a"; done
  printf 'c%07d\tsess-c%s-0000-0000-0000-000000000000\t%s\t%s\tbackground\t%s\trunning\t%s\n' "$n" "$n" "$nm" "$(pwd -P)" "$((100 + n))" "$((2000 + n))" >> "$FAKE_TABLE"
  shift 3; saved "$(printf 'c%07d' "$n")" "$@"
  echo "note: background session keeps its own saved options, so the flags you passed started a copy as c$n." >&2
elif [ "$1" = --bg ] && [ "$2" = --resume ] && [ -n "${FAKE_RESUME_GONE:-}" ]; then
  # the session cannot be resumed: its job is left failed, with the detail Claude Code gives
  d="$CLAUDE_CONFIG_DIR/jobs/$FAKE_RESUME_GONE"; mkdir -p "$d"
  printf '{\n  "state": "failed",\n  "detail": "source session %s not found",\n  "respawnFlags": []\n}\n' "$3" > "$d/state.json"
elif [ "$1" = --bg ] && [ "$2" = --resume ] && [ -n "${FAKE_RESUME_FAIL:-}" ]; then
  echo "error: could not reach the daemon" >&2; exit 1
elif [ "$1" = --bg ] && [ "$2" = --resume ] && awk -F'\t' -v s="$3" '$2 == s && $6 != 0 { f = 1 } END { exit !f }' "$FAKE_TABLE"; then
  # the session still has a live process (state done, not stopped): Claude Code starts a copy
  # with empty saved options and says "already running"
  printf 'c%07d\tsess-c%s-0000-0000-0000-000000000000\t%s\t%s\tbackground\t%s\trunning\t%s\n' "$n" "$n" "copy" "$(pwd -P)" "$((100 + n))" "$((2000 + n))" >> "$FAKE_TABLE"
  saved "$(printf 'c%07d' "$n")"
  echo "already running" >&2
elif [ "$1" = --bg ] && [ "$2" = --resume ]; then
  awk -F'\t' -v OFS='\t' -v s="$3" '$2 == s { $6 = 999; $7 = "running" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
elif [ "$1" = rm ]; then
  echo "removed $2"; echo "kept the transcript"
elif [ "$1" = stop ]; then
  awk -F'\t' -v OFS='\t' -v s="$2" '$1 == s { $6 = 0; $7 = "done" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
fi
exit 0
FAKE
chmod +x "$bin/claude"

repo="$T/repo"; mkdir -p "$repo/rooms/review"
export FAKE_TABLE="$T/table" FAKE_CALLS="$T/calls" FAKE_READS="$T/reads" AGENT_ADAPTER_WAIT=0 AGENT_ADAPTER_CLAUDE_PAUSE=0
# the adapter's records go to a scratch config folder, never the real one
export CLAUDE_CONFIG_DIR="$T/config"
unset AGENT_ADAPTER_CLAUDE_STATE
records="$T/config/agent-adapter-claude/agents.tsv"
table() { # rows: id sid name cwd kind pid state started
  : > "$FAKE_TABLE"; : > "$FAKE_CALLS"
  local r; for r in "$@"; do printf '%s\n' "$r" | tr '|' '\t' >> "$FAKE_TABLE"; done
}
saved_opts() { # saved_opts <short id> <flags...>: what the fake claude keeps for a session (SAVED_STATE: its state, default stopped)
  local d="$CLAUDE_CONFIG_DIR/jobs/$1" a sep=''; shift; mkdir -p "$d"
  { printf '{\n  "state": "%s",\n  "respawnFlags": [' "${SAVED_STATE:-stopped}"
    for a in "$@"; do a="${a//\\/\\\\}"; a="${a//\"/\\\"}"; printf '%s\n    "%s"' "$sep" "$a"; sep=','; done
    printf '\n  ],\n  "name": "x"\n}\n'; } > "$d/state.json"
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
rm -rf "$CLAUDE_CONFIG_DIR/jobs"; mkdir -p "$CLAUDE_CONFIG_DIR/jobs/a1"
printf '{\n  "state": "done",\n  "respawnFlags": [\n    "--name",\n    "host"\n  ]\n}\n' > "$CLAUDE_CONFIG_DIR/jobs/a1/state.json"
out="$(ad attach host "$repo")"
check 'attach a stopped session whose saved options are the agent'"'"'s: claude attach <id> (restarts it with them)' "$T|attach|a1;" "$(calls)"
table "a1|sess-a1|host|$repo|background|0|done|1000"
out="$(ad attach host "$repo" -- --agent host --settings '{"env":{"AGENTIC_REGISTER_AS":"host"}}')"; rc=$?
copy="$(awk -F'\t' '$1 ~ /^c/ { print $1 }' "$FAKE_TABLE")"
check 'attach a stopped session without the agent'"'"'s args saved: woken with --name and the args, then attached (exit 0)' \
  "0:$repo|--bg|--resume|sess-a1|--name|host|--agent|host|--settings|{\"env\":{\"AGENTIC_REGISTER_AS\":\"host\"}};$T|attach|$copy;" "$rc:$(calls)"
rm -f "$records"
table "a1|sess-a1|host|$repo|background|0|done|1000"
SAVED_STATE=running saved_opts a1 --name host --agent host
out="$(ad attach host "$repo" -- --agent host)"; rc=$?
copy="$(awk -F'\t' '$1 ~ /^c/ { print $1 }' "$FAKE_TABLE")"
check 'attach a stopped session whose state.json says running: woken with --name and the args, then attached (exit 0)' \
  "0:$repo|--bg|--resume|sess-a1|--name|host|--agent|host;$T|attach|$copy;" "$rc:$(calls)"
check 'attach, state.json says running: the copy is recorded as the agent'"'"'s' "host	$repo	$copy" "$(grep '^host	' "$records" | cut -f1-3)"
rm -rf "$CLAUDE_CONFIG_DIR/jobs"

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

# A woken session gets the agent's options: Claude Code puts its saved options back on a bare
# --bg --resume, and starts a copy when flags are given; so bare when they are the agent's
# (--name <name> <args>), else with them (the copy then carries them).
reg='{"env":{"AGENTIC_REGISTER_AS":"host"}}'
rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "a1|sess-a1|host|$repo|background|0|done|1000" "a8|sess-a8|host|$repo|background|0|failed|1500" "a9|sess-a9|host|$repo/rooms/review|background|0|done|9000"
saved_opts a8 --name host --settings "$reg" --agent host
out="$(ad wake host "$repo" -- --agent host --settings "$reg")"; rc=$?
check 'wake: the newest stopped or failed session of the agent, by its full id, bare when its saved options are the agent'"'"'s' "$repo|--bg|--resume|sess-a8;" "$(calls)"
lacks 'wake: never -c' "$(calls)" '|-c'
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host
out="$(ad wake host "$repo" -- --agent host --settings "$reg")"; rc=$?
check 'wake: saved options without the agent'"'"'s args: woken with --name and the args (exit 0)' "0:$repo|--bg|--resume|sess-a8|--name|host|--agent|host|--settings|$reg;" "$rc:$(calls)"
contains 'wake: saved options without the args: says why, and that it is a copy' "$out" 'keeps other options than the agent'"'"'s'
copy="$(awk -F'\t' '$1 ~ /^c/ { print $1 "\t" $2 }' "$FAKE_TABLE")"
check 'wake: the copy Claude Code started is recorded as the agent'"'"'s' "host	$repo	$copy" "$(grep '^host	' "$records")"
rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
out="$(ad wake host "$repo" -- --agent host)"; rc=$?
check 'wake: saved options that cannot be read: woken with --name and the args' "$repo|--bg|--resume|sess-a8|--name|host|--agent|host;" "$(calls)"
contains 'wake: saved options that cannot be read: says so' "$out" 'cannot be read'
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --agent host
out="$(ad wake host "$repo" -- --agent host --model opus)"
check 'wake: saved options that differ (the args changed in the list): woken with the new ones' "$repo|--bg|--resume|sess-a8|--name|host|--agent|host|--model|opus;" "$(calls)"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host
out="$(ad wake host "$repo")"
check 'wake: an agent without args, saved --name only: bare' "$repo|--bg|--resume|sess-a8;" "$(calls)"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --settings '{"a":["x]","y\"z"],"b":"\\"}'
out="$(ad wake host "$repo" -- --settings '{"a":["x]","y\"z"],"b":"\\"}')"
check 'wake: saved options with quotes, brackets and backslashes are read as Claude Code wrote them' "$repo|--bg|--resume|sess-a8;" "$(calls)"
# after a rebuild: the list shows the session ended, but Claude Code's own state.json still says
# running (a bare wake would start a copy without any options): woken with the options
rm -f "$records"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
SAVED_STATE=running saved_opts a8 --name host --settings "$reg" --agent host
out="$(ad wake host "$repo" -- --agent host --settings "$reg")"; rc=$?
check 'wake: saved options match but its state.json says running: woken with --name and the args (exit 0)' "0:$repo|--bg|--resume|sess-a8|--name|host|--agent|host|--settings|$reg;" "$rc:$(calls)"
contains 'wake: its state.json says running: says why' "$out" "Claude Code's own state for it says 'running'"
copy="$(awk -F'\t' '$1 ~ /^c/ { print $1 "\t" $2 }' "$FAKE_TABLE")"
check 'wake: its state.json says running: the copy is recorded as the agent'"'"'s' "host	$repo	$copy" "$(grep '^host	' "$records")"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
SAVED_STATE=starting saved_opts a8 --name host
out="$(ad wake host "$repo")"
check 'wake: its state.json says starting (not ended): woken with --name' "$repo|--bg|--resume|sess-a8|--name|host;" "$(calls)"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
SAVED_STATE='done' saved_opts a8 --name host
out="$(ad wake host "$repo")"
check 'wake: its state.json says done: bare' "$repo|--bg|--resume|sess-a8;" "$(calls)"
# the session is gone: Claude Code leaves the job failed with detail "source session <id> not found"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --agent host
out="$(FAKE_RESUME_GONE=a8 ad wake host "$repo" -- --agent host)"; rc=$?
check 'wake: the session is gone: started fresh with the agent'"'"'s args (exit 0)' "0:$repo|--bg|--resume|sess-a8;$repo|--bg|--name|host|--agent|host;" "$rc:$(calls)"
contains 'wake: the session is gone: says so' "$out" 'session sess-a8 is gone; started fresh'
check 'wake: the session is gone: the fresh session is recorded' 1 "$(grep -c "^host	$repo	b" "$records")"
# any other resume failure still fails
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --agent host
out="$(FAKE_RESUME_FAIL=1 ad wake host "$repo" -- --agent host)"; rc=$?
check 'wake: another resume failure fails (exit 1), no fresh start' "1:$repo|--bg|--resume|sess-a8;" "$rc:$(calls)"
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
got="$(calls)"; nsid="$(printf '%s' "$got" | cut -d'|' -f5)"
check 'new: claude --name <name> --session-id <a new id> <args> in the folder' "$repo/rooms/review|--name|reviewer|--session-id|$nsid|--model|sonnet;" "$got"
check 'new: the chosen session id is recorded before it starts' "reviewer	$repo/rooms/review	$nsid	$nsid" "$(grep '^reviewer	' "$records")"
: > "$FAKE_CALLS"
out="$(ad new reviewer "$repo/rooms/review" -- --session-id given)"
check 'new: a --session-id of its own is left alone' "$repo/rooms/review|--name|reviewer|--session-id|given;" "$(calls)"

table "a1|sess-a1|host|$repo|background|201|-|1000" "a7|sess-a7|host (2)|$repo|background|207|-|7000"
out="$(ad stop host "$repo")"
check 'stop: the newest by its id' "$T|stop|a7;" "$(calls)"
table "a1|sess-a1|host|$repo|background|201|-|1000" "a7|sess-a7|host (2)|$repo|background|207|-|7000"
out="$(ad stop host "$repo" --extras)"
check 'stop --extras: the others, never the newest' "$T|stop|a1;" "$(calls)"
table "a1|sess-a1|host|$repo|background|0|done|1000"
out="$(ad stop host "$repo")"; rc=$?
check 'stop when not running: exit 0, nothing called' "0:" "$rc:$(calls)"
table "a1|sess-a1|host|$repo|background|201|done|1000"
out="$(ad stop host "$repo")"; rc=$?
check 'stop: a done session whose process is still alive is stopped by its id' "0:$T|stop|a1;" "$rc:$(calls)"

table "a1|sess-a1|host|$repo|background|0|done|1000" "a2|sess-a2|host|$repo|background|201|-|500"
out="$(ad logs host "$repo")"
check 'logs: the running session first, by its id' "$T|logs|a2;" "$(calls)"

# ------------------------------------------------ a session Claude Code retitles ----
# Claude Code may retitle a background session after a prompt: the session started as "host"
# is then listed under another name. The record (job id, session id) still finds it.
rm -f "$records"; table \
  "o1|sess-o1|host|$repo|background|0|done|100" \
  "o2|sess-o2|host|$repo|background|0|failed|200"
out="$(cd "$T" && PATH="$bin:$PATH" agent-adapter-claude start-bg host "$repo" 2>/dev/null)"
newid="$(awk -F'\t' '$3 == "host" && $6 != 0 { print $1 }' "$FAKE_TABLE")"
newsid="$(awk -F'\t' '$3 == "host" && $6 != 0 { print $2 }' "$FAKE_TABLE")"
check 'start-bg: the new session recorded (name, folder, job id, session id)' "host	$repo	$newid	$newsid" "$(cat "$records")"
check 'the record file is the user'"'"'s only (600)' 600 "$(stat -c %a "$records")"
check 'the record folder is the user'"'"'s only (700)' 700 "$(stat -c %a "$(dirname "$records")")"
# the first real prompt: Claude Code retitles it
awk -F'\t' -v OFS='\t' -v i="$newid" '$1 == i { $3 = "d47 d50 personalization medallion" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
out="$(ad list)"
contains 'retitled: list shows it as the agent, running' "$out" "host	$newsid	running	$repo"
lacks 'retitled: list does not show the new title' "$out" 'personalization'
: > "$FAKE_CALLS"
out="$(ad attach host "$repo")"
check 'retitled, ended sessions by its name beside it: attach the live recorded one' "$T|attach|$newid;" "$(calls)"
: > "$FAKE_CALLS"
out="$(ad start-bg host "$repo")"; rc=$?
check 'retitled: start-bg refuses a second session (exit 1)' 1 "$rc"
check 'retitled: start-bg starts nothing' "" "$(calls)"
contains 'retitled: start-bg says why' "$out" "its recorded session $newsid runs"
# end to end: the agents command over this adapter
cp "$root/src/agents/agents.sh" "$bin/agents"; chmod +x "$bin/agents"
mkdir -p "$repo/.devcontainer"
printf 'agents:\n  - name: host\n    cli: claude\n    kind: resident\n' > "$repo/.devcontainer/agents.yml"
: > "$FAKE_CALLS"
out="$(cd "$repo" && AGENTS_TTY=1 AGENTS_STATE_DIR="$T/agents-state" PATH="$bin:$PATH" agents start host 2>&1)"; rc=$?
check 'agents start of a retitled resident: attaches to it, no second session' "$repo|attach|$newid;" "$(calls)"
contains 'agents start of a retitled resident: says it runs' "$out" "host: running ($newsid)"
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state" PATH="$bin:$PATH" agents list 2>&1)"
contains 'agents list of a retitled resident: running with its id' "$out" "$(printf '%-16s %-10s %-8s %-9s %-38s %s' host resident claude running "$newsid" .)"
: > "$FAKE_CALLS"
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state" PATH="$bin:$PATH" agents up --no-wait 2>&1)"
check 'agents up with a retitled resident: starts nothing' "" "$(calls)"
# /clear in that session: the same job id, a new session id
awk -F'\t' -v OFS='\t' -v i="$newid" '$1 == i { $2 = "sess-cleared" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
: > "$FAKE_CALLS"
out="$(ad attach host "$repo")"
check 'a /clear (new session id, same job id): still attached by its job id' "$T|attach|$newid;" "$(calls)"
contains 'a /clear: says how it was resolved' "$out" "now holds session id sess-cleared"
check 'a /clear: the record follows' "host	$repo	$newid	sess-cleared" "$(cat "$records")"
# the recorded session is gone (removed): back to name and folder
awk -F'\t' -v i="$newid" '$1 != i' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
printf 'o3\tsess-o3\thost\t%s\tbackground\t303\t-\t300\n' "$repo" >> "$FAKE_TABLE"
: > "$FAKE_CALLS"
out="$(ad attach host "$repo")"
check 'the recorded session no longer listed: found by name and folder' "$T|attach|o3;" "$(calls)"
contains 'the recorded session no longer listed: says so' "$out" 'is no longer listed; finding it by name and folder'
# no record: a live session by the name wins over newer ended ones
rm -f "$records"; table \
  "l1|sess-l1|host|$repo|background|401|working|100" \
  "e1|sess-e1|host|$repo|background|0|done|900" \
  "e2|sess-e2|host (2)|$repo|background|0|failed|950"
out="$(ad attach host "$repo")"
check 'by name: a live session wins over newer ended ones' "$T|attach|l1;" "$(calls)"
out="$(ad list)"
contains 'a blocked session (waiting on a decision) is running' "$(table "b1|sess-b1|host|$repo|background|0|blocked|100"; ad list)" "host	sess-b1	running"

# a session whose state is done but whose process is alive (a pid): resuming it starts a copy, so
# wake stops that one session by id first, waits until it has no pid, then wakes it bare
rm -rf "$CLAUDE_CONFIG_DIR/jobs"; rm -f "$records"
table "a8|sess-a8|host|$repo|background|777|done|1500" "z1|sess-z1|other|$repo|background|778|-|1600" "z2|sess-z2|host|$repo/rooms/review|background|779|-|1700"
saved_opts a8 --name host
out="$(ad wake host "$repo")"; rc=$?
check 'wake: a done session with a live pid is stopped by its id, then woken bare (exit 0)' "0:$T|stop|a8;$repo|--bg|--resume|sess-a8;" "$rc:$(calls)"
check 'wake: a done session with a live pid: no copy was started' 0 "$(grep -c '^c' "$FAKE_TABLE")"
lacks 'wake: never stops another session' "$(cat "$FAKE_CALLS")" '|stop|z1'
lacks 'wake: never stops a session of another folder' "$(cat "$FAKE_CALLS")" '|stop|z2'
check 'wake: the other sessions keep their pids' '778 779' "$(awk -F'\t' '$1 ~ /^z/ { printf "%s%s", s, $6; s = " " }' "$FAKE_TABLE")"

# Claude Code saves the options in a fixed order (--name, --settings, --agent, --model), not the
# order of the list's args: that is still a bare wake
table "a8|sess-a8|host|$repo|background|0|stopped|1500"
saved_opts a8 --name host --settings "$reg" --agent host --model haiku
out="$(ad wake host "$repo" -- --model haiku --agent host --settings "$reg")"
check 'wake: args in another order than Claude Code saves them: bare' "$repo|--bg|--resume|sess-a8;" "$(calls)"
table "a8|sess-a8|host|$repo|background|0|stopped|1500"
saved_opts a8 --name host --settings "$reg" --agent host --model haiku
out="$(ad wake host "$repo" -- --agent host --model opus --settings "$reg")"
check 'wake: a differing value still wakes with the flags' "$repo|--bg|--resume|sess-a8|--name|host|--agent|host|--model|opus|--settings|$reg;" "$(calls)"

# end to end: agents up wakes a stopped resident with the args of its entry in agents.yml
# (the report: three residents came back without --agent and the register --settings)
rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "s1|sess-s1|scribe|$repo|background|0|done|100"
saved_opts s1 --name scribe
printf 'agents:\n  - name: scribe\n    cli: claude\n    kind: resident\n    args: [--agent, scribe, --settings, %s]\n' \
  "'{\"env\":{\"AGENTIC_REGISTER_AS\":\"scribe\"}}'" > "$repo/.devcontainer/agents.yml"
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state2" PATH="$bin:$PATH" agents up --no-wait 2>&1)"; rc=$?
check 'agents up of a stopped resident: woken with --name and the args of its entry (exit 0)' \
  "0:$repo|--bg|--resume|sess-s1|--name|scribe|--agent|scribe|--settings|{\"env\":{\"AGENTIC_REGISTER_AS\":\"scribe\"}};" "$rc:$(calls)"
table "s1|sess-s1|scribe|$repo|background|0|done|100"
saved_opts s1 --name scribe --settings '{"env":{"AGENTIC_REGISTER_AS":"scribe"}}' --agent scribe
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state3" PATH="$bin:$PATH" agents up --no-wait 2>&1)"; rc=$?
check 'agents up of a stopped resident that keeps its args: the same session, bare' "0:$repo|--bg|--resume|sess-s1;" "$rc:$(calls)"
rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs"

# ------------------------------------------------------------ reset's verbs ----
table \
  "w1|sess-w1|host|$repo|background|701|working|100" \
  "u1|sess-u1|host|$repo|background|702|busy|100" \
  "d1|sess-d1|host|$repo|background|703|idle|100" \
  "q1|sess-q1|host|$repo|background|704|waiting|100" \
  "k1|sess-k1|host|$repo|background|705|blocked|100" \
  "n1|sess-n1|host|$repo|background|706|-|100" \
  "e1|sess-e1|host|$repo|background|0|done|100"
busy() { ad session-busy "$1" >/dev/null; echo $?; }
check 'session-busy: a background state of working is mid-turn (exit 0)' 0 "$(busy sess-w1)"
check 'session-busy: status busy is mid-turn (exit 0)' 0 "$(busy sess-u1)"
check 'session-busy: idle is not (exit 1)' 1 "$(busy sess-d1)"
check 'session-busy: waiting for input is not (exit 1)' 1 "$(busy sess-q1)"
check 'session-busy: blocked on a decision is not (exit 1)' 1 "$(busy sess-k1)"
check 'session-busy: an ended session is not (exit 1)' 1 "$(busy sess-e1)"
check 'session-busy: running, and nothing says: unknown (exit 3)' 3 "$(busy sess-n1)"
rm -f "$records"; table \
  "r1|sess-r1|host|$repo|background|501|working|100" \
  "r2|sess-r2|host (2)|$repo|background|502|working|200" \
  "r0|sess-r0|host|$repo|background|0|done|50" \
  "i1|sess-i1|reviewer|$repo|interactive|601|busy|300"
out="$(ad session-stop sess-r2)"; rc=$?
check 'session-stop: claude stop <short id> of that session (exit 0)' "0:$T|stop|r2;" "$rc:$(calls)"
: > "$FAKE_CALLS"; out="$(ad session-stop sess-i1)"; rc=$?
check 'session-stop of an interactive session: refused, nothing called' "1:" "$rc:$(calls)"
: > "$FAKE_CALLS"; out="$(ad session-remove sess-r1)"; rc=$?
check 'session-remove of a running session: refused, nothing called' "1:" "$rc:$(calls)"
: > "$FAKE_CALLS"; out="$(ad session-remove sess-r0)"; rc=$?
check 'session-remove of an ended session: claude rm <short id>' "0:$T|rm|r0;" "$rc:$(calls)"
check 'session-remove: one removal line, claude rm'"'"'s own "removed <id>" dropped, its notes kept' "1:0" "$(printf '%s\n' "$out" | grep -c 'removed from the session list'):$(printf '%s\n' "$out" | grep -c '^removed ')"
out="$(ad session-remove nope)"; rc=$?
check 'session-remove of an unknown id: exit 1' 1 "$rc"
out="$(ad record host "$repo")"
check 'record: the running session the lookup picks (the other was stopped above)' "host	$repo	r1	sess-r1" "$(cat "$records")"
out="$(ad list)"
check 'list: the recorded session comes first' "host	sess-r1	running	$repo" "$(printf '%s\n' "$out" | head -n 1)"
table "r0|sess-r0|host|$repo|background|0|done|50"
out="$(ad record host "$repo")"
check 'record with no running session: the record is cleared' "" "$(cat "$records")"
contains 'record with no running session: says so' "$out" 'its record is cleared'
contains 'supports: names the reset verbs' "$(ad supports | tr '\n' ' ')" 'record session-busy session-stop session-remove'

out="$(ad frob host "$repo")"; rc=$?
check 'an unknown verb: exit 3 (not supported)' 3 "$rc"
out="$(ad attach)"; rc=$?
check 'a verb without name and folder: exit 2' 2 "$rc"
out="$(ad attach host "$T/nope")"; rc=$?
check 'a missing folder: exit 1' 1 "$rc"


# The remoteControl option: --remote-control on every session the adapter starts, unless the
# agent's args have it or --no-remote-control; off: unchanged; a wake does not become a copy.
rcfile="$T/rc-file"
rcad() { (cd "$T" && PATH="$bin:$PATH" AGENT_ADAPTER_CLAUDE_REMOTE_CONTROL_FILE="$rcfile" agent-adapter-claude "$@" 2>&1); }
rm -f "$rcfile"; table
out="$(rcad start-bg rcagent "$repo" -- --model opus)"
check 'remoteControl off: start-bg unchanged' "$repo|--bg|--name|rcagent|--model|opus;" "$(calls)"
echo 1 > "$rcfile"; table
out="$(rcad start-bg rcagent "$repo" -- --model opus)"
check 'remoteControl on: start-bg adds --remote-control' "$repo|--bg|--name|rcagent|--model|opus|--remote-control;" "$(calls)"
table
out="$(rcad start-bg rcagent "$repo" -- --remote-control)"
check 'remoteControl on: not doubled when the agent has it' "$repo|--bg|--name|rcagent|--remote-control;" "$(calls)"
table
out="$(rcad start-bg rcagent "$repo" -- --no-remote-control --model opus)"
check 'remoteControl on: --no-remote-control opts out and is not passed on' "$repo|--bg|--name|rcagent|--model|opus;" "$(calls)"
table
out="$(rcad new rcagent "$repo" -- --model opus)"
contains 'remoteControl on: new adds --remote-control' "$(calls)" '|--name|rcagent|--session-id|'
contains 'remoteControl on: new passes --remote-control' "$(cat "$FAKE_CALLS")" '|--model|opus|--remote-control'
rm -f "$rcfile"; table
out="$(AGENT_ADAPTER_CLAUDE_REMOTE_CONTROL=1 rcad start-bg rcagent "$repo")"
check 'remoteControl: the env override turns it on for one run' "$repo|--bg|--name|rcagent|--remote-control;" "$(calls)"
echo 1 > "$rcfile"; table
out="$(AGENT_ADAPTER_CLAUDE_REMOTE_CONTROL=0 rcad start-bg rcagent "$repo")"
check 'remoteControl: the env override turns it off for one run' "$repo|--bg|--name|rcagent;" "$(calls)"
# wake with the option on: saved options with or without --remote-control stay a bare wake
for sv in "--name rcagent" "--name rcagent --remote-control" "--name rcagent --model opus --remote-control"; do
  table "a8|sess-a8|rcagent|$repo|background|0|stopped|1000"
  # shellcheck disable=SC2086
  saved_opts a8 $sv
  # shellcheck disable=SC2086
  out="$(rcad wake rcagent "$repo" -- ${sv#--name rcagent})"
  check "remoteControl on: a bare wake when the saved options are '$sv'" "$repo|--bg|--resume|sess-a8;" "$(calls)"
done
rm -f "$rcfile"

# Across every call above: never rm (but the one session-remove asked for), never -c or
# --continue; in the code, never an action by name.
all="$(grep -v '|rm|r0$' "$T/all-calls" 2>/dev/null)"
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
