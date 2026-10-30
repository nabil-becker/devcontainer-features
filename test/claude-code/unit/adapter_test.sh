#!/usr/bin/env bash
# Docker-free tests of the claude-code Feature's agent-adapter-claude (the agents Feature's
# adapter contract for Claude Code): `list` from `claude agents --json --all`, newest first,
# with the state (a pid is running, finished or not; failed; everything else stopped) and the resolved folder;
# a session is the agent's by name AND folder (another folder, or a name that only starts
# with the agent's, never counts; "host (2)" does); every action takes the session's id,
# never the name; a stopped session is woken with --bg --resume <full session id>, never -c;
# resume refuses a running session; stop keeps the newest unless --extras, never rm;
# start-bg and new tag the session with --name (AGENT_SESSION_NAME, else the handle). A fake `claude` keeps sessions in a table,
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
# jobs/<id>/state.json, respawnFlags); `--bg --resume <sessionId>` gives that session a pid again
# (idle: a done one stays done, any other is working), whatever its state.json says, and with
# any flag after it starts a copy under a new id (c...) instead, as Claude Code does;
# `stop <id>` clears it. Every call but `agents` is recorded in $FAKE_CALLS as "folder|arg|arg";
# every `agents` call adds a line to $FAKE_READS. The ways a read goes wrong: FAKE_AGENTS_FAIL
# (exit 1, nothing printed), FAKE_WRAPPED (what a wrapper putting `--add-dir <dir>` first
# causes: Claude Code 2.1.312 says "error: unknown option '--json'", exit 1), FAKE_SLOW_FIRST
# (the first read sleeps 3 seconds, the later ones answer), FAKE_NOISE (a line before the
# array and one after it, the array pretty-printed). Claude Code 2.1.314 as reported (1.9.4; not
# reproducible on 2.1.308, modelled from the report): FAKE_RESUME_CRASH, a bare wake crashes, the
# attempt briefly listed running under a new id while its job says "source session <id> not found"
# and daemon.log says it crashed; FAKE_RESUME_FORK, a bare wake continues the conversation under a
# new id (its job's resumeSessionId the old id) and leaves the old one listed blocked, with a
# process when FAKE_FORK_OLD_PID is set.
cat > "$bin/claude" <<'FAKE'
#!/usr/bin/env bash
# proc <pid>: the process as the adapter sees it ($AGENT_ADAPTER_CLAUDE_PROC): Claude Code's,
# gone (FAKE_DEAD_PIDS, left by a container restart) or another program's (FAKE_REUSED_PIDS)
proc() {
  [ -n "${AGENT_ADAPTER_CLAUDE_PROC:-}" ] && [ "${1:-0}" != 0 ] || return 0
  case " ${FAKE_DEAD_PIDS:-} " in *" $1 "*) rm -rf "${AGENT_ADAPTER_CLAUDE_PROC:?}/$1"; return 0 ;; esac
  mkdir -p "$AGENT_ADAPTER_CLAUDE_PROC/$1"
  case " ${FAKE_REUSED_PIDS:-} " in *" $1 "*) printf 'sleep\0infinity\0' ;; *) printf 'claude\0--bg\0' ;; esac > "$AGENT_ADAPTER_CLAUDE_PROC/$1/cmdline"
}
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
      [ -z "$first" ] && printf ',\n'; first=''; proc "$pid"
      printf '  {\n    "id": "%s",\n    "cwd": "%s",\n    "kind": "%s",\n    "startedAt": %s,\n    "sessionId": "%s",\n    "name": "%s"' "$id" "$cwd" "$kind" "$started" "$sid" "$name"
      [ "$pid" != 0 ] && printf ',\n    "pid": %s' "$pid"
      printf '\n  }'
    done < "$FAKE_TABLE"
    printf '\n]\n'; echo "(1 more line after the list)"; exit 0
  fi
  printf '['; first=1
  while IFS=$'\t' read -r id sid name cwd kind pid state started; do
    [ -n "$sid" ] || continue
    [ -z "$first" ] && printf ',\n'; first=''; proc "$pid"
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
elif [ "$1" = --bg ] && [ "$2" = --resume ] && [ -n "${FAKE_RESUME_SHELLFORK:-}" ]; then
  # host-restart-copy (2.1.314, as reported): a forked respawn under a new id, its saved options
  # --model only, named FAKE_FORK_NAME (default "fork", none of the agent's), its job naming the old
  # id only in its arguments (FAKE_FORK_NOREF: nowhere); the old one left blocked, no process;
  # nothing said
  short="$(printf 'e%07d' "$n")" nsid="sess-e$n-0000-0000-0000-000000000000"
  printf '%s\t%s\t%s\t%s\tbackground\t%s\tworking\t%s\n' "$short" "$nsid" "${FAKE_FORK_NAME:-fork}" "$(pwd -P)" "$((100 + n))" "$((2000 + n))" >> "$FAKE_TABLE"
  mkdir -p "$CLAUDE_CONFIG_DIR/jobs/$short"
  ref="\"--fork-session\", \"--resume\", \"$3\""; [ -n "${FAKE_FORK_NOREF:-}" ] && ref='"--fork-session"'
  printf '{\n  "state": "working",\n  "respawnFlags": ["--model", "claude-opus-5-5"],\n  "sessionId": "%s",\n  "resumeSessionId": "%s",\n  "argv": ["--session-id", "%s", %s]\n}\n' "$nsid" "$nsid" "$nsid" "$ref" > "$CLAUDE_CONFIG_DIR/jobs/$short/state.json"
  awk -F'\t' -v OFS='\t' -v s="$3" '$2 == s { $6 = 0; $7 = "blocked" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
elif [ "$1" = --bg ] && [ "$2" = --resume ] && [ -n "${FAKE_RESUME_CRASH:-}${FAKE_RESUME_FORK:-}" ]; then
  nm="$(awk -F'\t' -v s="$3" '$2 == s { print $3 }' "$FAKE_TABLE")"
  old="$(awk -F'\t' -v s="$3" '$2 == s { print $1 }' "$FAKE_TABLE")"
  p=k; [ -n "${FAKE_RESUME_FORK:-}" ] && p=f
  short="$(printf '%s%07d' "$p" "$n")"
  printf '%s\tsess-%s%s-0000-0000-0000-000000000000\t%s\t%s\tbackground\t%s\tworking\t%s\n' "$short" "$p" "$n" "$nm" "$(pwd -P)" "$((100 + n))" "$((2000 + n))" >> "$FAKE_TABLE"
  mkdir -p "$CLAUDE_CONFIG_DIR/jobs/$short"
  if [ -n "${FAKE_RESUME_CRASH:-}" ]; then
    [ -n "${FAKE_CRASH_LOG_ONLY:-}" ] || printf '{\n  "state": "failed",\n  "detail": "source session %s not found",\n  "sessionId": "sess-%s%s-0000-0000-0000-000000000000",\n  "resumeSessionId": "%s"\n}\n' "$3" "$p" "$n" "$3" > "$CLAUDE_CONFIG_DIR/jobs/$short/state.json"
    echo "[2026-10-30T00:00:00.000Z] [bg] bg settled $short (crashed): source session $3 not found" >> "$CLAUDE_CONFIG_DIR/daemon.log"
  else
    printf '{\n  "state": "working",\n  "respawnFlags": [],\n  "sessionId": "sess-%s%s-0000-0000-0000-000000000000",\n  "resumeSessionId": "%s"\n}\n' "$p" "$n" "$3" > "$CLAUDE_CONFIG_DIR/jobs/$short/state.json"
    awk -F'\t' -v OFS='\t' -v s="$3" -v pid="${FAKE_FORK_OLD_PID:-0}" '$2 == s { $6 = pid; $7 = "blocked" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
    echo "note: woke session $old with its saved options (--name)." >&2
  fi
  echo "backgrounded · $short · woken (idle — send a prompt to start)"
elif [ "$1" = --bg ] && [ "$2" = --resume ] && awk -F'\t' -v s="$3" -v dead=" ${FAKE_DEAD_PIDS:-} " '$2 == s && $6 != 0 && !index(dead, " " $6 " ") { f = 1 } END { exit !f }' "$FAKE_TABLE"; then
  # the session still has a live process (state done, not stopped): Claude Code starts a copy
  # with empty saved options and says "already running"
  printf 'c%07d\tsess-c%s-0000-0000-0000-000000000000\t%s\t%s\tbackground\t%s\trunning\t%s\n' "$n" "$n" "copy" "$(pwd -P)" "$((100 + n))" "$((2000 + n))" >> "$FAKE_TABLE"
  saved "$(printf 'c%07d' "$n")"
  echo "already running" >&2
elif [ "$1" = --bg ] && [ "$2" = --resume ]; then
  # a bare wake continues the same session whatever its state.json says (after a container
  # restart it still says working): it comes back with a pid, idle; a finished one keeps the
  # state done (Claude Code 2.1.308, checked for 1.9.1). FAKE_RESUME_UNLISTED: the list does not
  # show it yet
  short="$(awk -F'\t' -v s="$3" '$2 == s { print $1 }' "$FAKE_TABLE")"
  echo "note: woke session $short with its saved options (--name)." >&2
  echo "backgrounded · $short · woken (idle — send a prompt to start)"
  [ -n "${FAKE_RESUME_UNLISTED:-}" ] || {
    awk -F'\t' -v OFS='\t' -v s="$3" '$2 == s { $6 = 999; if ($7 != "done") $7 = "working" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"; }
elif [ "$1" = rm ]; then
  echo "removed $2"; echo "kept the transcript"
elif [ "$1" = stop ]; then
  awk -F'\t' -v OFS='\t' -v s="$2" '$1 == s { $6 = 0; $7 = "done" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
fi
exit 0
FAKE
chmod +x "$bin/claude"

repo="$T/repo"; mkdir -p "$repo/rooms/review"
export FAKE_TABLE="$T/table" FAKE_CALLS="$T/calls" FAKE_READS="$T/reads" AGENT_ADAPTER_WAIT=0 AGENT_ADAPTER_CLAUDE_PAUSE=0 AGENT_ADAPTER_SETTLE=0
# the adapter's records go to a scratch config folder, never the real one
export CLAUDE_CONFIG_DIR="$T/config"
# the processes the adapter looks at (1.9.6): the fake's, never this machine's
export AGENT_ADAPTER_CLAUDE_PROC="$T/proc"
unset AGENT_ADAPTER_CLAUDE_STATE AGENT_SESSION_NAME  # the session a test runs in may set it
# the agents Feature installed here (a devhost) has its own session-name template: never read it
export AGENTS_SHARE_DIR="$T/agents-share"
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
check 'attach a stopped session: woken bare first, as wake does, then claude attach <id> (1.9.6)' "$repo|--bg|--resume|sess-a1;$T|attach|a1;" "$(calls)"
table "a1|sess-a1|host|$repo|background|0|done|1000"
out="$(ad attach host "$repo" -- --agent host --settings '{"env":{"AGENTIC_REGISTER_AS":"host"}}')"; rc=$?
check 'attach a stopped session without the agent'"'"'s args saved: woken bare, never with flags (1.9.3, exit 0)' \
  "0:$repo|--bg|--resume|sess-a1;$T|attach|a1;" "$rc:$(calls)"
contains 'attach, args not saved: says which are missing' "$out" 'lack or differ in: --settings {"env":{"AGENTIC_REGISTER_AS":"host"}}; --agent host'
check 'attach, args not saved: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
rm -f "$records"
table "a1|sess-a1|host|$repo|background|0|done|1000"
SAVED_STATE=working saved_opts a1 --name host --agent host
out="$(ad attach host "$repo" -- --agent host)"; rc=$?
check 'attach an ended session whose state.json still says working (a restart): woken bare by its id, then attached (1.9.1)' \
  "0:$repo|--bg|--resume|sess-a1;$T|attach|a1;" "$rc:$(calls)"
check 'attach, state.json says working: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
rm -rf "$CLAUDE_CONFIG_DIR/jobs"; rm -f "$records"

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
# --bg --resume, and starts a copy when flags are given (losing the conversation); so a wake is
# always bare (1.9.3), and says when the saved options lack or differ from the agent's.
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
check 'wake: saved options without the agent'"'"'s args: still bare, same id (exit 0)' "0:$repo|--bg|--resume|sess-a8;" "$rc:$(calls)"
contains 'wake: saved options without the args: one warning naming them' "$out" 'lack or differ in: --settings {"env":{"AGENTIC_REGISTER_AS":"host"}}; --agent host'
contains 'wake: the warning says they apply at the next fresh start' "$out" "applies at the agent's next fresh start"
check 'wake: saved options without the args: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
check 'wake: the session itself is recorded as the agent'"'"'s' "host	$repo	a8	sess-a8	host" "$(grep '^host	' "$records")"
rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
out="$(ad wake host "$repo" -- --agent host)"; rc=$?
check 'wake: saved options that cannot be read: bare all the same' "$repo|--bg|--resume|sess-a8;" "$(calls)"
contains 'wake: saved options that cannot be read: says so' "$out" 'cannot be read'
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --agent host
out="$(ad wake host "$repo" -- --agent host --model opus)"
check 'wake: a saved option missing (the args changed in the list): bare' "$repo|--bg|--resume|sess-a8;" "$(calls)"
contains 'wake: a saved option missing: the warning names it' "$out" 'lack or differ in: --model opus'
check 'wake: a saved option missing: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
# 1.9.3 (the report: residents saved as --name n --remote-control --model sonnet, the model taken
# from the room'"'"'s settings, came back as copies): extra saved options are no difference
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --remote-control --model sonnet
out="$(ad wake host "$repo" -- --remote-control)"
check 'wake: an extra saved --model (from settings): bare, same id' "$repo|--bg|--resume|sess-a8;" "$(calls)"
lacks 'wake: an extra saved --model: no warning' "$out" 'differ'
check 'wake: an extra saved --model: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --agent host --model sonnet --effort high
out="$(ad wake host "$repo" -- --agent host)"
check 'wake: several extra saved options: bare, no warning' "$repo|--bg|--resume|sess-a8;" "$(calls)"
lacks 'wake: several extra saved options: no warning' "$out" 'differ'
# a changed value: the same, with the warning
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --model sonnet
out="$(ad wake host "$repo" -- --model opus)"
check 'wake: a changed value: bare, same id' "$repo|--bg|--resume|sess-a8;" "$(calls)"
contains 'wake: a changed value: the warning names it' "$out" 'lack or differ in: --model opus'
check 'wake: a changed value: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host
out="$(ad wake host "$repo")"
check 'wake: an agent without args, saved --name only: bare' "$repo|--bg|--resume|sess-a8;" "$(calls)"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --settings '{"a":["x]","y\"z"],"b":"\\"}'
out="$(ad wake host "$repo" -- --settings '{"a":["x]","y\"z"],"b":"\\"}')"
check 'wake: saved options with quotes, brackets and backslashes are read as Claude Code wrote them' "$repo|--bg|--resume|sess-a8;" "$(calls)"
# after a container restart (1.9.1, the report: 8 of 9 residents came back as new sessions):
# Claude Code lists a session that was idle as failed, but its own state.json still says working
# until its background service starts again; a bare wake continues it (checked on 2.1.308), so
# state.json is not consulted. A never-prompted room agent (failed, idle) and a finished main
# agent (done) are both woken into their own session ids; --remote-control saved where given
rm -f "$records"
table "r1|sess-r1|room|$repo|background|0|failed|1500"
SAVED_STATE=working saved_opts r1 --name room --remote-control --model opus
out="$(cd "$T" && PATH="$bin:$PATH" agent-adapter-claude wake room "$repo" -- --remote-control --model opus 2>"$T/err")"; rc=$?
check 'restart, idle room agent (failed, state.json working): woken bare (exit 0)' "0:$repo|--bg|--resume|sess-r1;" "$rc:$(calls)"
check 'restart, idle room agent: stdout is its own session id' sess-r1 "$out"
check 'restart, idle room agent: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
check 'restart, idle room agent: recorded as its own session' "room	$repo	r1	sess-r1" "$(grep '^room	' "$records" | cut -f1-4)"
lacks 'restart, idle room agent: no note about a copy' "$(cat "$T/err")" 'copy'
table "m1|sess-m1|main|$repo|background|0|done|1500"
SAVED_STATE='done' saved_opts m1 --name main --remote-control --model opus
out="$(cd "$T" && PATH="$bin:$PATH" agent-adapter-claude wake main "$repo" -- --remote-control --model opus 2>"$T/err")"; rc=$?
check 'restart, finished main agent (done): woken bare (exit 0)' "0:$repo|--bg|--resume|sess-m1;" "$rc:$(calls)"
check 'restart, finished main agent: back idle with its state still done, stdout is its own session id' sess-m1 "$out"
check 'restart, finished main agent: recorded as its own session' "main	$repo	m1	sess-m1" "$(grep '^main	' "$records" | cut -f1-4)"
lacks 'restart, finished main agent: not "not recorded"' "$(cat "$T/err")" 'not recorded'
check 'restart, finished main agent: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
table "m1|sess-m1|main|$repo|background|0|done|1500"
SAVED_STATE='done' saved_opts m1 --name main --remote-control --model opus
out="$(cd "$T" && FAKE_RESUME_UNLISTED=1 PATH="$bin:$PATH" agent-adapter-claude wake main "$repo" -- --remote-control --model opus 2>/dev/null)"; rc=$?
check 'wake: Claude Code says it woke the session but the list lags: its own id, no fresh start (exit 0)' "0:sess-m1:$repo|--bg|--resume|sess-m1;" "$rc:$out:$(calls)"
table "r1|sess-r1|room|$repo|background|0|failed|1500"
SAVED_STATE=starting saved_opts r1 --name room
out="$(ad wake room "$repo")"
check 'wake: its state.json says starting: bare all the same' "$repo|--bg|--resume|sess-r1;" "$(calls)"
rm -rf "$CLAUDE_CONFIG_DIR/jobs"; rm -f "$records"
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
# the contract: wake prints the id of the session that runs, here the fresh one, never the gone one
# (agents records the lease's carrier from it)
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --agent host
out="$(cd "$T" && FAKE_RESUME_GONE=a8 PATH="$bin:$PATH" agent-adapter-claude wake host "$repo" -- --agent host 2>/dev/null)"
check 'wake: the session is gone: stdout is the fresh session'"'"'s id, one line' \
  "$(awk -F'\t' '$3 == "host" && $7 == "running" { print $2 }' "$FAKE_TABLE" | tail -n 1)" "$out"
lacks 'wake: the session is gone: stdout never names the gone session' "$out" sess-a8
# truly gone after a restart (state.json still working): the bare wake first, then fresh
rm -f "$records"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
SAVED_STATE=working saved_opts a8 --name host --agent host
out="$(FAKE_RESUME_GONE=a8 ad wake host "$repo" -- --agent host)"; rc=$?
check 'wake after a restart, the session gone: bare, then started fresh (exit 0)' "0:$repo|--bg|--resume|sess-a8;$repo|--bg|--name|host|--agent|host;" "$rc:$(calls)"
check 'wake after a restart, the session gone: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
# any other resume failure still fails (a fresh record: the gone sess-a8 above is superseded in it)
rm -f "$records"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host --agent host
out="$(FAKE_RESUME_FAIL=1 ad wake host "$repo" -- --agent host)"; rc=$?
check 'wake: another resume failure fails (exit 1), no fresh start' "1:$repo|--bg|--resume|sess-a8;" "$rc:$(calls)"
table
out="$(ad wake host "$repo")"; rc=$?
check 'wake with nothing to wake: exit 1' 1 "$rc"

# --------------------------------------- wakes that crash or fork (1.9.4) ----
# The report (claude-code 1.9.2, Claude Code 2.1.314): a resident never prompted has no transcript,
# its wake crashes ("source session <id> not found"), the crashed attempt was recorded as the carrier
# and woken again by the next `agents up`, in a loop; a resident that resumed came back under a new
# id with the old one left listed beside it. 2.1.314 is modelled in the fake from the report.
fresh_sid() { awk -F'\t' '$1 ~ /^b/ && $6 != 0 { s = $2 } END { print s }' "$FAKE_TABLE"; }
clean() { rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs" "$CLAUDE_CONFIG_DIR/projects" "$CLAUDE_CONFIG_DIR/daemon.log"; }
wk() { (cd "$T" && PATH="$bin:$PATH" agent-adapter-claude wake "$@" 2>"$T/err"); }
# a session with no transcript: never woken, the agent starts fresh
clean; mkdir -p "$CLAUDE_CONFIG_DIR/projects/-other"; echo '{}' > "$CLAUDE_CONFIG_DIR/projects/-other/sess-zz.jsonl"
table "n1|sess-n1|host|$repo|background|0|failed|1500"
saved_opts n1 --name host --agent host
out="$(wk host "$repo" -- --agent host)"; rc=$?
check 'no transcript: started fresh with the agent'"'"'s args, never woken (exit 0)' "0:$repo|--bg|--name|host|--agent|host;" "$rc:$(calls)"
contains 'no transcript: says so' "$(cat "$T/err")" 'session sess-n1 has no transcript'
check 'no transcript: stdout is the fresh session' "$(fresh_sid)" "$out"
check 'no transcript: the fresh session recorded, the old one superseded' "$(fresh_sid)	host	sess-n1" "$(grep '^host	' "$records" | cut -f4,5,7)"
check 'no transcript: list shows the old one as superseded, not as the agent' "host (superseded)	sess-n1	failed	$repo" "$(ad list | grep sess-n1)"
# with a transcript, as before: woken bare
clean; mkdir -p "$CLAUDE_CONFIG_DIR/projects/-repo"; echo '{"type":"user"}' > "$CLAUDE_CONFIG_DIR/projects/-repo/sess-n1.jsonl"
table "n1|sess-n1|host|$repo|background|0|failed|1500"
saved_opts n1 --name host
out="$(wk host "$repo")"; rc=$?
check 'with a transcript: woken bare, the same id' "0:sess-n1:$repo|--bg|--resume|sess-n1;" "$rc:$out:$(calls)"
# a wake that crashes with "not found" (briefly listed running under a new id): the agent starts
# fresh, the crashed attempt is never recorded
clean
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host
out="$(FAKE_RESUME_CRASH=1 wk host "$repo")"; rc=$?
kid="$(awk -F'\t' '$1 ~ /^k/ { print $2 }' "$FAKE_TABLE")"
check 'a wake that crashes: woken bare, then started fresh (exit 0)' "0:$repo|--bg|--resume|sess-a8;$repo|--bg|--name|host;" "$rc:$(calls)"
check 'a wake that crashes: stdout is the fresh session' "$(fresh_sid)" "$out"
lacks 'a wake that crashes: the crashed attempt is not the recorded session' "$(cut -f3,4 "$records")" "$kid"
check 'a wake that crashes: the record holds the fresh session' "$(fresh_sid)" "$(grep '^host	' "$records" | cut -f4)"
contains 'a wake that crashes: says so, naming the crashed attempt' "$(cat "$T/err")" "session sess-a8 is gone (its wake crashed as $kid"
# the crash seen only in daemon.log (no job file says it); an older line there does not count
clean
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host
out="$(FAKE_RESUME_CRASH=1 FAKE_CRASH_LOG_ONLY=1 wk host "$repo")"; rc=$?
check 'a crash only in daemon.log: started fresh (exit 0)' "0:$repo|--bg|--resume|sess-a8;$repo|--bg|--name|host;" "$rc:$(calls)"
clean
echo "[2026-10-29T00:00:00.000Z] [bg] bg settled x1 (crashed): source session sess-a8 not found" > "$CLAUDE_CONFIG_DIR/daemon.log"
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host
out="$(wk host "$repo")"; rc=$?
check 'daemon.log: a line from before the wake does not count, woken bare' "0:sess-a8:$repo|--bg|--resume|sess-a8;" "$rc:$out:$(calls)"
# the record points at a job that failed with "not found" (what 1.9.2 recorded): treated as gone,
# never woken again (no loop)
clean
table "a8|sess-a8|host|$repo|background|0|failed|1000" "k9|sess-k9|host|$repo|background|0|failed|2000"
mkdir -p "$CLAUDE_CONFIG_DIR/jobs/k9"
printf '{\n  "state": "failed",\n  "detail": "source session sess-a8 not found",\n  "respawnFlags": []\n}\n' > "$CLAUDE_CONFIG_DIR/jobs/k9/state.json"
mkdir -p "$(dirname "$records")"; printf 'host\t%s\tk9\tsess-k9\thost\n' "$repo" > "$records"
out="$(wk host "$repo")"; rc=$?
check 'recorded job failed "not found": never woken, started fresh (exit 0)' "0:$repo|--bg|--name|host;" "$rc:$(calls)"
check 'recorded job failed "not found": the fresh session recorded, the failed one superseded' "$(fresh_sid)	host	sess-k9" "$(grep '^host	' "$records" | cut -f4,5,7)"
# the same through `agents up`, twice: one fresh start, then joined (no loop)
clean
table "a8|sess-a8|host|$repo|background|0|failed|1000" "k9|sess-k9|host|$repo|background|0|failed|2000"
mkdir -p "$CLAUDE_CONFIG_DIR/jobs/k9"
printf '{\n  "state": "failed",\n  "detail": "source session sess-a8 not found"\n}\n' > "$CLAUDE_CONFIG_DIR/jobs/k9/state.json"
mkdir -p "$(dirname "$records")"; printf 'host\t%s\tk9\tsess-k9\thost\n' "$repo" > "$records"
mkdir -p "$repo/.devcontainer"; printf 'agents:\n  - name: host\n    cli: claude\n    kind: resident\n' > "$repo/.devcontainer/agents.yml"
cp "$root/src/agents/agents.sh" "$bin/agents"; chmod +x "$bin/agents"
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state5" PATH="$bin:$PATH" agents up --no-wait 2>&1)"; rc=$?
check 'agents up, the record at a crashed attempt: one fresh start, no wake (exit 0)' "0:$repo|--bg|--name|host;" "$rc:$(calls)"
contains 'agents up, the record at a crashed attempt: the lease is carried by the fresh session' "$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state5" PATH="$bin:$PATH" agents leases 2>&1)" "session:$(fresh_sid)"
: > "$FAKE_CALLS"
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state5" PATH="$bin:$PATH" agents up --no-wait 2>&1)"
check 'agents up again: nothing woken or started' "" "$(calls)"
# a wake that comes back under a new id continuing the conversation: the new id recorded, success,
# the old one in the record (superseded), left without a process
clean
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host
out="$(FAKE_RESUME_FORK=1 wk host "$repo")"; rc=$?
fid="$(awk -F'\t' '$1 ~ /^f/ { print $2 }' "$FAKE_TABLE")" fshort="$(awk -F'\t' '$1 ~ /^f/ { print $1 }' "$FAKE_TABLE")"
check 'a wake under a new id: woken bare, nothing else (exit 0)' "0:$repo|--bg|--resume|sess-a8;" "$rc:$(calls)"
check 'a wake under a new id: stdout is the new id' "$fid" "$out"
check 'a wake under a new id: the new id recorded, the old one kept' "$fshort	$fid	host	sess-a8" "$(grep '^host	' "$records" | cut -f3,4,5,7)"
contains 'a wake under a new id: one line naming both' "$(cat "$T/err")" "continues its conversation under a new id, $fid (was sess-a8)"
lacks 'a wake under a new id: not a fresh start' "$(cat "$T/err")" 'started fresh'
out="$(ad list)"
contains 'a wake under a new id: list shows the agent under the new id' "$out" "host	$fid	running	$repo"
contains 'a wake under a new id: the old one (no process) as superseded' "$out" "host (superseded)	sess-a8	stopped	$repo"
check 'a wake under a new id: one session listed as the agent' 1 "$(printf '%s\n' "$out" | grep -c '^host	')"
check 'a wake under a new id: the old one is never removed' 1 "$(grep -c 'sess-a8' "$FAKE_TABLE")"
: > "$FAKE_CALLS"; out="$(ad wake host "$repo")"; rc=$?
check 'a wake under a new id: the superseded one is never woken again' "1:" "$rc:$(calls)"
# the old one still has a process: stopped by its id
clean
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host
out="$(FAKE_RESUME_FORK=1 FAKE_FORK_OLD_PID=998 wk host "$repo")"; rc=$?
fid="$(awk -F'\t' '$1 ~ /^f/ { print $2 }' "$FAKE_TABLE")"
check 'old copy with a process: stopped by its id, after the bare wake (exit 0)' "0:$repo|--bg|--resume|sess-a8;$T|stop|a8;" "$rc:$(calls)"
check 'old copy with a process: stdout is the new id' "$fid" "$out"
contains 'old copy with a process: says it was stopped' "$(cat "$T/err")" 'stopped its old session sess-a8 by its id'
check 'old copy with a process: no process left' 0 "$(awk -F'\t' '$2 == "sess-a8" { print $6 }' "$FAKE_TABLE")"
check 'old copy with a process: then superseded, one session as the agent' "1:1" "$(ad list | grep -c '^host	'):$(ad list | grep -c '^host (superseded)	sess-a8')"
# through `agents up`: the lease follows the new id; no extra running session reported
clean
table "a8|sess-a8|host|$repo|background|0|failed|1500"
saved_opts a8 --name host
out="$(cd "$repo" && FAKE_RESUME_FORK=1 AGENTS_STATE_DIR="$T/agents-state6" PATH="$bin:$PATH" agents up --no-wait 2>&1)"; rc=$?
fid="$(awk -F'\t' '$1 ~ /^f/ { print $2 }' "$FAKE_TABLE")"
check 'agents up, a wake under a new id: exit 0, woken bare only' "0:$repo|--bg|--resume|sess-a8;" "$rc:$(calls)"
lacks 'agents up, a wake under a new id: never "was not woken"' "$out" 'was not woken'
contains 'agents up, a wake under a new id: the lease is carried by the new id' "$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state6" PATH="$bin:$PATH" agents leases 2>&1)" "session:$fid"
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state6" PATH="$bin:$PATH" agents list 2>&1)"
lacks 'agents list, a wake under a new id: no extra session reported' "$out" '+1'
clean

# host-restart-copy (1.9.6). Reported on 2.1.314 after one container restart: the host, whose old
# session was blocked, came back as a forked copy (`--fork-session --resume <old id>`, saved options
# --model only) that nothing recorded and no superseded record named.
trace_log="$CLAUDE_CONFIG_DIR/agent-adapter-claude/trace.log"
hargs=(--agent host --settings '{"env":{"AGENTIC_REGISTER_AS":"host"}}')
host_saved() { saved_opts h1 --name host "${hargs[@]}" --model claude-opus-5-5; }
# (a) a pid listed for a session left by the restart: not running, so it is woken, never attached as it is
clean; rm -f "$trace_log"
table "h1|sess-h1|host|$repo|background|4242|blocked|1500"; host_saved
check 'a listed pid that is gone (a container restart): stopped, not running' "host	sess-h1	stopped	$repo" "$(FAKE_DEAD_PIDS=4242 ad list)"
check 'a listed pid that another program now has: stopped, not running' "host	sess-h1	stopped	$repo" "$(FAKE_REUSED_PIDS=4242 ad list)"
check 'a listed pid that is Claude Code'"'"'s: running, as before' "host	sess-h1	running	$repo" "$(ad list)"
out="$(FAKE_DEAD_PIDS=4242 wk host "$repo" -- "${hargs[@]}")"; rc=$?
check 'a gone pid: woken bare by its id, the same session (exit 0)' "0:sess-h1:$repo|--bg|--resume|sess-h1;" "$rc:$out:$(calls)"
check 'a gone pid: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
clean; rm -f "$trace_log"
table "h1|sess-h1|host|$repo|background|4242|blocked|1500"; host_saved
out="$(cd "$repo" && FAKE_DEAD_PIDS=4242 AGENTS_STATE_DIR="$T/agents-state7" PATH="$bin:$PATH" agents up --no-wait 2>&1)"; rc=$?
check 'agents up, a gone pid: the host is woken, not taken as running (exit 0)' "0:$repo|--bg|--resume|sess-h1;" "$rc:$(calls)"
lacks 'agents up, a gone pid: never "running (sess-h1)" before the wake' "$out" 'host: running (sess-h1)'
# (b) attach of an ended (blocked) session: woken as wake does, then the session that runs is attached
clean; rm -f "$trace_log"
table "h1|sess-h1|host|$repo|background|0|blocked|1500"; host_saved
out="$(ad attach host "$repo" -- "${hargs[@]}")"; rc=$?
check 'attach of a blocked, ended session: woken bare, then attached by its id (exit 0)' "0:$repo|--bg|--resume|sess-h1;$T|attach|h1;" "$rc:$(calls)"
check 'attach of a blocked, ended session: recorded' "h1	sess-h1" "$(grep '^host	' "$records" | cut -f3,4)"
contains 'attach: the trace names the verb and the session' "$(cat "$trace_log")" "attach	host	$repo	-	sess-h1	attached"
clean; rm -f "$trace_log"
table "h1|sess-h1|host|$repo|background|0|blocked|1500"; host_saved
out="$(FAKE_RESUME_FORK=1 ad attach host "$repo" -- "${hargs[@]}")"; rc=$?
fid="$(awk -F'\t' '$1 ~ /^f/ { print $2 }' "$FAKE_TABLE")" fshort="$(awk -F'\t' '$1 ~ /^f/ { print $1 }' "$FAKE_TABLE")"
check 'attach, the wake comes back under a new id: that one attached' "0:$repo|--bg|--resume|sess-h1;$T|attach|$fshort;" "$rc:$(calls)"
check 'attach, the wake comes back under a new id: recorded, the old one superseded' "$fid	sess-h1" "$(grep '^host	' "$records" | cut -f4,7)"
contains 'attach, the wake comes back under a new id: traced as continuing' "$(cat "$trace_log")" "attach	host	$repo	sess-h1	$fid	continues"
# (c) a wake answered by a forked respawn under a new id, without a name of the agent's, its job
# naming the old id only in its arguments, its saved options --model only
clean; rm -f "$trace_log"
table "h1|sess-h1|host|$repo|background|0|blocked|1500"; host_saved
out="$(FAKE_RESUME_SHELLFORK=1 wk host "$repo" -- "${hargs[@]}")"; rc=$?
eid="$(awk -F'\t' '$1 ~ /^e/ { print $2 }' "$FAKE_TABLE")" eshort="$(awk -F'\t' '$1 ~ /^e/ { print $1 }' "$FAKE_TABLE")"
check 'a forked respawn: woken bare only (exit 0)' "0:$repo|--bg|--resume|sess-h1;" "$rc:$(calls)"
check 'a forked respawn: stdout is the new id' "$eid" "$out"
check 'a forked respawn: the new id recorded, the old one superseded' "$eshort	$eid	sess-h1" "$(grep '^host	' "$records" | cut -f3,4,7)"
contains 'a forked respawn: says it continues under a new id' "$(cat "$T/err")" "continues its conversation under a new id, $eid (was sess-h1)"
contains 'a forked respawn: says which of the agent'"'"'s options it lacks' "$(cat "$T/err")" 'lack or differ in: --name host; --settings {"env":{"AGENTIC_REGISTER_AS":"host"}}; --agent host'
contains 'a forked respawn: traced (verb, old id, new id, continues, options)' "$(cat "$trace_log")" "wake	host	$repo	sess-h1	$eid	continues; options lack: --name host"
contains 'a forked respawn: list shows the old one superseded' "$(ad list)" "host (superseded)	sess-h1	stopped	$repo"
# the same, its job not naming the old id, but by the agent's name: the new id, the old one superseded
clean; rm -f "$trace_log"
table "h1|sess-h1|host|$repo|background|0|blocked|1500"; host_saved
out="$(FAKE_RESUME_SHELLFORK=1 FAKE_FORK_NOREF=1 FAKE_FORK_NAME=host wk host "$repo" -- "${hargs[@]}")"; rc=$?
eid="$(awk -F'\t' '$1 ~ /^e/ { print $2 }' "$FAKE_TABLE")"
check 'a new id by the agent'"'"'s name, not known to continue it: stdout is the new id (exit 0)' "0:$eid" "$rc:$out"
check 'a new id by the agent'"'"'s name: recorded, the old one superseded' "$eid	sess-h1" "$(grep '^host	' "$records" | cut -f4,7)"
contains 'a new id by the agent'"'"'s name: says so' "$(cat "$T/err")" "runs it as a new session, $eid (was sess-h1"
contains 'a new id by the agent'"'"'s name: traced as new-id' "$(cat "$trace_log")" "wake	host	$repo	sess-h1	$eid	new-id"
# a plain wake under its own id is traced as the same
clean; rm -f "$trace_log"
table "h1|sess-h1|host|$repo|background|0|blocked|1500"; host_saved
out="$(wk host "$repo" -- "${hargs[@]}")"
contains 'a wake under its own id: traced as the same' "$(cat "$trace_log")" "wake	host	$repo	sess-h1	sess-h1	same"
check 'the trace is the user'"'"'s only (600)' 600 "$(stat -c %a "$trace_log")"
lacks 'the trace is never on the terminal' "$(cat "$T/err")" 'trace'
clean; rm -f "$trace_log"

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
# (1.9.5) An interactive session leaves `claude agents --json --all` when it ends (/exit); its
# transcript stays under projects/<folder slug>/ and names it. A stray background session of the
# same name and folder (left by a resident run) is still listed; resume reaches the ended
# interactive conversation, never the stray.
slug="$(printf '%s' "$repo" | sed 's/[^A-Za-z0-9]/-/g')"
pdir="$CLAUDE_CONFIG_DIR/projects/$slug"
transcript() { # transcript <session id> <title> [<cwd>] [<touch date>]
  mkdir -p "$pdir"
  printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n{"type":"agent-name","agentName":"%s","sessionId":"%s"}\n{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' \
    "${3:-$repo}" "$1" "$2" "$1" "$2" "$1" > "$pdir/$1.jsonl"
  [ -z "${4:-}" ] || touch -d "$4" "$pdir/$1.jsonl"
}
clean
table "b9|sess-b9|host|$repo|background|0|blocked|9000"
saved_opts b9 --name host; sed -i 's/"name": "x"/"name": "x", "sessionId": "sess-b9"/' "$CLAUDE_CONFIG_DIR/jobs/b9/state.json"
transcript sess-b9 host "$repo" '2026-10-30 16:00'
transcript sess-i1 'Office host' "$repo" '2026-10-30 19:00'
out="$(AGENT_SESSION_NAME='Office host' ad resume host "$repo")"; rc=$?
check 'resume: an ended interactive session only on disk, beside a stray background one of the same name: the interactive one (exit 0)' \
  "0:$repo|--resume|sess-i1;" "$rc:$(calls)"
transcript sess-h1 host "$repo" '2026-10-30 18:00'
table "b9|sess-b9|host|$repo|background|0|blocked|9000"
out="$(ad resume host "$repo")"; rc=$?
check 'resume: by the handle alone, the ended interactive session titled so (the stray never; not another title)' "$repo|--resume|sess-h1;" "$(calls)"
# the recorded session (new wrote it), ended: chosen when it is the newest; an older ended one is not
transcript sess-i2 'Office host' "$repo" '2026-10-30 20:00'
mkdir -p "$(dirname "$records")"; printf 'host\t%s\tsess-i2\tsess-i2\tOffice host\n' "$repo" > "$records"
table "b9|sess-b9|host|$repo|background|0|blocked|9000"
out="$(AGENT_SESSION_NAME='Office host' ad resume host "$repo")"; rc=$?
check 'resume: its recorded session, ended and unlisted: resumed by its id' "0:$repo|--resume|sess-i2;" "$rc:$(calls)"
lacks 'resume: an ended recorded session is no "no longer listed" note' "$out" 'no longer listed'
# newest by transcript, whatever the record says
touch -d '2026-10-30 21:00' "$pdir/sess-i1.jsonl"
table "b9|sess-b9|host|$repo|background|0|blocked|9000"
out="$(AGENT_SESSION_NAME='Office host' ad resume host "$repo")"
check 'resume: the newest conversation by its transcript' "$repo|--resume|sess-i1;" "$(calls)"
# never: another name, another folder (same slug), a background job'"'"'s session
clean
transcript sess-o1 'someone else' "$repo" '2026-10-30 22:00'
transcript sess-o2 host "$T/elsewhere" '2026-10-30 22:00'
transcript sess-o3 host "$repo" '2026-10-30 22:00'
saved_opts o3 --name host; sed -i 's/"name": "x"/"name": "x", "sessionId": "sess-o3"/' "$CLAUDE_CONFIG_DIR/jobs/o3/state.json"
transcript sess-i3 host "$repo" '2026-10-30 10:00'
table
out="$(ad resume host "$repo")"
check 'resume: never a transcript of another name, another folder or a background job' "$repo|--resume|sess-i3;" "$(calls)"
# a running interactive session of the agent is refused, even when an ended one is newer on disk
table "i4|sess-i4|host|$repo|interactive|404|idle|1000"
touch -d '2026-10-30 23:00' "$pdir/sess-i3.jsonl"
out="$(ad resume host "$repo")"; rc=$?
check 'resume: a running session of the agent is refused (exit 1), nothing called' "1:" "$rc:$(calls)"
contains 'resume: the refusal names the running session and its pid' "$out" 'sess-i4 is running (pid 404)'
# a listed background session that is its recorded one is still its own
clean
table "b5|sess-b5|host|$repo|background|0|done|5000"
printf 'host\t%s\tb5\tsess-b5\n' "$repo" > "$records"
out="$(ad resume host "$repo")"
check 'resume: its recorded session, background or not' "$repo|--resume|sess-b5;" "$(calls)"
clean

out="$(ad hint reviewer "$repo/rooms/review")"; rc=$?
check 'hint: exit 0' 0 "$rc"
contains 'hint: how to resume by hand' "$out" "cd '$repo/rooms/review' && claude --resume (pick 'reviewer')"
contains 'supports: names hint' "$(ad supports)" 'hint'

table
out="$(ad new reviewer "$repo/rooms/review" -- --model sonnet)"
got="$(calls)"; nsid="$(printf '%s' "$got" | cut -d'|' -f5)"
check 'new: claude --name <name> --session-id <a new id> <args> in the folder' "$repo/rooms/review|--name|reviewer|--session-id|$nsid|--model|sonnet;" "$got"
check 'new: the chosen session id is recorded before it starts' "reviewer	$repo/rooms/review	$nsid	$nsid	reviewer" "$(grep '^reviewer	' "$records")"
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
check 'start-bg: the new session recorded (name, folder, job id, session id)' "host	$repo	$newid	$newsid	host" "$(cat "$records")"
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
contains 'agents list of a retitled resident: running with its id' "$out" "$(printf '%-16s %-10s %-10s %-8s %-9s %-24s %-38s %s' host resident stateful claude running "held session:$newsid" "$newsid" .)"
: > "$FAKE_CALLS"
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state" PATH="$bin:$PATH" agents up --no-wait 2>&1)"
check 'agents up with a retitled resident: starts nothing' "" "$(calls)"
# /clear in that session: the same job id, a new session id
awk -F'\t' -v OFS='\t' -v i="$newid" '$1 == i { $2 = "sess-cleared" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"
: > "$FAKE_CALLS"
out="$(ad attach host "$repo")"
check 'a /clear (new session id, same job id): still attached by its job id' "$T|attach|$newid;" "$(calls)"
contains 'a /clear: says how it was resolved' "$out" "now holds session id sess-cleared"
check 'a /clear: the record follows' "host	$repo	$newid	sess-cleared	host" "$(cat "$records")"
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
contains 'a blocked session with a process (waiting on a decision) is running' "$(table "b1|sess-b1|host|$repo|background|31|blocked|100"; ad list)" "host	sess-b1	running"

# a session whose state is done but whose process is alive (a pid) waits for a prompt: it is up
# (listed running, 1.9.2; 1.8.7 listed it stopped and a wake stopped it first, so every `agents up`
# stopped and woke a finished resident). Resuming it would start a copy, so nothing resumes it.
rm -rf "$CLAUDE_CONFIG_DIR/jobs"; rm -f "$records"
table "a8|sess-a8|host|$repo|background|777|done|1500" "z1|sess-z1|other|$repo|background|778|-|1600" "z2|sess-z2|host|$repo/rooms/review|background|779|-|1700"
saved_opts a8 --name host
check 'done with a live pid: listed running (what agents joins instead of waking)' "host	sess-a8	running	$repo" "$(ad list | grep sess-a8)"
out="$(ad session-busy sess-a8)"; rc=$?
check 'done with a live pid: session-busy says idle (exit 1)' "1:sess-a8: not mid-turn" "$rc:$out"
: > "$FAKE_CALLS"
out="$(ad wake host "$repo")"; rc=$?
check 'wake of it: nothing to wake (exit 1), no stop, no resume, no copy' "1:" "$rc:$(calls)"
contains 'wake of it: says it is running' "$out" 'is running'
: > "$FAKE_CALLS"
out="$(ad attach host "$repo")"; rc=$?
check 'attach: claude attach <id> of that very session, no resume' "$T|attach|a8;" "$(calls)"
: > "$FAKE_CALLS"
out="$(ad stop host "$repo")"; rc=$?
check 'stop: a done session with a live pid is stopped by its id, no other' "0:$T|stop|a8;" "$rc:$(calls)"
check 'after stop it is listed stopped, no pid' "host	sess-a8	stopped	$repo" "$(ad list | grep sess-a8)"
check 'no copy was started anywhere' 0 "$(grep -c '^c' "$FAKE_TABLE")"
check 'the other sessions keep their pids' '778 779' "$(awk -F'\t' '$1 ~ /^z/ { printf "%s%s", s, $6; s = " " }' "$FAKE_TABLE")"
table "a8|sess-a8|host|$repo|background|777|done|1500"
out="$(ad session-stop sess-a8)"; rc=$?
check 'session-stop of a done session with a live pid: stopped by its id' "0:$T|stop|a8;" "$rc:$(calls)"
# after that stop the same session wakes bare into the same id (it has no process now)
saved_opts a8 --name host
: > "$FAKE_CALLS"
out="$(ad wake host "$repo")"; rc=$?
check 'wake after the stop: bare, the same id' "0:$repo|--bg|--resume|sess-a8;" "$rc:$(calls)"
check 'wake after the stop: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"

# the opposite slip: blocked with no process cannot be running; it is stopped, and a wake
# resumes it bare into the same id
rm -rf "$CLAUDE_CONFIG_DIR/jobs"; rm -f "$records"
table "b1|sess-b1|host|$repo|background|0|blocked|100"
saved_opts b1 --name host
check 'blocked without a pid: listed stopped (wakeable)' "host	sess-b1	stopped	$repo" "$(ad list)"
out="$(ad wake host "$repo")"; rc=$?
check 'blocked without a pid: woken bare into the same id' "0:$repo|--bg|--resume|sess-b1;" "$rc:$(calls)"
check 'blocked without a pid: stdout is its own id, no copy' "sess-b1:0" "$(printf '%s' "$out" | tail -n 1):$(grep -c '^c' "$FAKE_TABLE")"
table "b2|sess-b2|host|$repo|background|555|blocked|100"
check 'blocked with a pid: still running' "host	sess-b2	running	$repo" "$(ad list)"

# the agents Feature on top of this adapter: `agents up` finds the finished resident with its live
# process running and joins it: no stop, no resume, no start, no copy (agents.sh is the repo's own)
agents_sh="${AGENTS_SH:-$root/src/agents/agents.sh}"
if [ -f "$agents_sh" ]; then
  cp "$agents_sh" "$bin/agents"; chmod +x "$bin/agents"
  mkdir -p "$repo/.devcontainer"
  printf 'agents:\n  - name: host\n    cli: claude\n    kind: resident\n' > "$repo/.devcontainer/agents.yml"
  rm -rf "$CLAUDE_CONFIG_DIR/jobs"; rm -f "$records"
  table "a8|sess-a8|host|$repo|background|777|done|1500"
  saved_opts a8 --name host
  aup() { (cd "$repo" && PATH="$bin:$PATH" AGENTS_STATE_DIR="$T/agents-state" AGENTS_SHARE_DIR="$T/agents-share" AGENTS_SETTLE_INTERVAL=0 AGENTS_SETTLE_TIMEOUT=0 AGENTS_START_ID=up-1 agents "$@" 2>&1); }
  out="$(aup up --no-wait)"; rc=$?
  check 'agents up: a finished resident with a live process is joined (exit 0)' 0 "$rc"
  contains 'agents up: says it is running' "$out" 'host: running (sess-a8)'
  check 'agents up: no stop, no resume, no start' "" "$(calls)"
  check 'agents up: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
  out="$(aup stop host)"; rc=$?
  check 'agents stop: ends it by its id' "0:$repo|stop|a8;" "$rc:$(calls)"
fi

# Claude Code saves the options in the order given (2.1.308, checked for 1.9.1; 1.8.7 took it for
# a fixed order): any order of the same options is a bare wake
table "a8|sess-a8|host|$repo|background|0|stopped|1500"
saved_opts a8 --name host --settings "$reg" --agent host --model haiku
out="$(ad wake host "$repo" -- --model haiku --agent host --settings "$reg")"
check 'wake: args in another order than Claude Code saves them: bare' "$repo|--bg|--resume|sess-a8;" "$(calls)"
table "a8|sess-a8|host|$repo|background|0|stopped|1500"
saved_opts a8 --name host --model haiku --remote-control --settings "$reg"
out="$(ad wake host "$repo" -- --model haiku --remote-control --settings "$reg")"
check 'wake: saved as given (--model before --settings, --remote-control between): bare' "$repo|--bg|--resume|sess-a8;" "$(calls)"
table "a8|sess-a8|host|$repo|background|0|stopped|1500"
saved_opts a8 --name host --settings "$reg" --agent host --model haiku
out="$(ad wake host "$repo" -- --agent host --model opus --settings "$reg")"
check 'wake: a differing value still wakes bare (1.9.3)' "$repo|--bg|--resume|sess-a8;" "$(calls)"

# end to end: agents up wakes a stopped resident with the args of its entry in agents.yml
# (the report: three residents came back without --agent and the register --settings)
rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "s1|sess-s1|scribe|$repo|background|0|done|100"
saved_opts s1 --name scribe
printf 'agents:\n  - name: scribe\n    cli: claude\n    kind: resident\n    args: [--agent, scribe, --settings, %s]\n' \
  "'{\"env\":{\"AGENTIC_REGISTER_AS\":\"scribe\"}}'" > "$repo/.devcontainer/agents.yml"
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state2" PATH="$bin:$PATH" agents up --no-wait 2>&1)"; rc=$?
check 'agents up of a stopped resident whose saved options lack its args: the same session, bare (1.9.3, exit 0)' \
  "0:$repo|--bg|--resume|sess-s1;" "$rc:$(calls)"
table "s1|sess-s1|scribe|$repo|background|0|done|100"
saved_opts s1 --name scribe --settings '{"env":{"AGENTIC_REGISTER_AS":"scribe"}}' --agent scribe
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state3" PATH="$bin:$PATH" agents up --no-wait 2>&1)"; rc=$?
check 'agents up of a stopped resident that keeps its args: the same session, bare' "0:$repo|--bg|--resume|sess-s1;" "$rc:$(calls)"
# after a container restart: a room agent left failed and idle (state.json still working) and a
# finished main agent come back as their own sessions, and the lease follows those ids
rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "r1|sess-r1|room|$repo|background|0|failed|100" "m1|sess-m1|main|$repo|background|0|done|90"
SAVED_STATE=working saved_opts r1 --name room --remote-control --model opus
SAVED_STATE='done' saved_opts m1 --name main --remote-control --model opus
printf 'agents:\n  - name: room\n    cli: claude\n    kind: resident\n    args: [--remote-control, --model, opus]\n  - name: main\n    cli: claude\n    kind: resident\n    args: [--remote-control, --model, opus]\n' > "$repo/.devcontainer/agents.yml"
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state4" PATH="$bin:$PATH" agents up --no-wait 2>&1)"; rc=$?
check 'agents up after a restart: both woken bare into their own sessions (exit 0)' "0:$repo|--bg|--resume|sess-r1;$repo|--bg|--resume|sess-m1;" "$rc:$(calls)"
lacks 'agents up after a restart: no new session' "$out" 'as a new session'
check 'agents up after a restart: no copy' 0 "$(grep -c '^c' "$FAKE_TABLE")"
out="$(cd "$repo" && AGENTS_STATE_DIR="$T/agents-state4" PATH="$bin:$PATH" agents leases 2>&1)"
contains 'agents up after a restart: the room lease is carried by its own session' "$out" 'session:sess-r1'
contains 'agents up after a restart: the main lease is carried by its own session' "$out" 'session:sess-m1'
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

# ------------------------------------------------------ session names (1.9.0) ----
# The caller (the agents Feature) renders a session name into AGENT_SESSION_NAME; the adapter uses
# it as --name when a session starts, the handle when it is empty or unset. The record keeps the
# name a session started with and the names before it, so a changed template finds the same
# session again and a bare wake stays bare: never a second session because the name changed.
unset AGENT_SESSION_NAME
adn() { local n="$1"; shift; (cd "$T" && PATH="$bin:$PATH" AGENT_SESSION_NAME="$n" agent-adapter-claude "$@" 2>&1); }
rec() { grep "^host	$repo	" "$records" | tr '\037' '+'; }
end_session() { awk -F'\t' -v OFS='\t' -v i="$1" '$1 == i { $6 = 0; $7 = "done" } { print }' "$FAKE_TABLE" > "$FAKE_TABLE.n" && mv "$FAKE_TABLE.n" "$FAKE_TABLE"; }
rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs"; table
out="$(adn 'desk host' start-bg host "$repo" -- --model opus)"
check 'names: start-bg passes AGENT_SESSION_NAME as --name' "$repo|--bg|--name|desk host|--model|opus;" "$(calls)"
sid1="$(awk -F'\t' '$3 == "desk host" { print $1 }' "$FAKE_TABLE")"
check 'names: the record holds the name the session started with' "host	$repo	$sid1	sess-1-0000-0000-0000-000000000000	desk host" "$(rec)"
# the session ends; the template changes ('laptop host'); a bare wake of the recorded session
end_session "$sid1"; SAVED_STATE=stopped saved_opts "$sid1" --name 'desk host' --model opus
: > "$FAKE_CALLS"
out="$(adn 'laptop host' wake host "$repo" -- --model opus)"; rc=$?
check 'names: a changed template still finds the session and wakes it bare (no copy)' "0:$repo|--bg|--resume|sess-1-0000-0000-0000-000000000000;" "$rc:$(calls)"
check 'names: a bare wake leaves the name it has in the record' "host	$repo	$sid1	sess-1-0000-0000-0000-000000000000	desk host" "$(rec)"
check 'names: no copy in the session list' 1 "$(grep -c . "$FAKE_TABLE")"
# a nested call without the variable: the same session, still bare, not renamed
end_session "$sid1"; : > "$FAKE_CALLS"
out="$(ad wake host "$repo" -- --model opus)"
check 'names: AGENT_SESSION_NAME unset on a later call wakes bare and renames nothing' "$repo|--bg|--resume|sess-1-0000-0000-0000-000000000000;" "$(calls)"
check 'names: unset does not touch the record' "host	$repo	$sid1	sess-1-0000-0000-0000-000000000000	desk host" "$(rec)"
# a new start under the new name: the old one moves to the history
end_session "$sid1"; : > "$FAKE_CALLS"
out="$(adn 'laptop host' start-bg host "$repo" -- --model opus)"
check 'names: a fresh start uses the template as it is now' "$repo|--bg|--name|laptop host|--model|opus;" "$(calls)"
sid2="$(awk -F'\t' '$3 == "laptop host" { print $1 }' "$FAKE_TABLE")"
sidfull2="$(awk -F'\t' '$3 == "laptop host" { print $2 }' "$FAKE_TABLE")"
check 'names: the record has the new name and the name before it' "host	$repo	$sid2	$sidfull2	laptop host	desk host" "$(rec | tr '+' '	')"
# the record names are kept when the record is cleared
end_session "$sid2"
out="$(ad record host "$repo")"
check 'names: clearing a record keeps its names' "host	$repo			laptop host	desk host" "$(grep "^host	$repo	" "$records" | tr '\037' '	')"
# empty: the handle, as before
rm -f "$records"; table
out="$(adn '' start-bg host "$repo")"
check 'names: an empty AGENT_SESSION_NAME gives the handle' "$repo|--bg|--name|host;" "$(calls)"
table
out="$(adn '   ' start-bg host "$repo")"
check 'names: a blank AGENT_SESSION_NAME gives the handle' "$repo|--bg|--name|host;" "$(calls)"
table
out="$(adn $'one\ntwo' start-bg host "$repo")"
check 'names: a name with a line break gives the handle' "$repo|--bg|--name|host;" "$(calls)"
contains 'names: a name with a line break is said' "$out" 'AGENT_SESSION_NAME has a line break'
rm -f "$records"; table
out="$(adn 'desk host' new host "$repo" -- --model opus)"
contains 'names: new passes AGENT_SESSION_NAME as --name' "$(calls)" "$repo|--name|desk host|--session-id|"
check 'names: new records the name' "desk host" "$(rec | cut -f5)"
rm -f "$records"; table
out="$(ad new host "$repo")"
contains 'names: new without it uses the handle' "$(calls)" "$repo|--name|host|--session-id|"
# a record that points at a session that is gone, with an older name in its history: found by it
rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "q1|sess-q1|desk host|$repo|background|0|done|100"
SAVED_STATE=stopped saved_opts q1 --name 'desk host'
mkdir -p "$(dirname "$records")"
printf 'host\t%s\tgone\tsess-gone\tlaptop host\tdesk host\n' "$repo" > "$records"
out="$(adn 'third host' wake host "$repo")"
check 'names: a name from the record'"'"'s history finds the session, woken bare (no copy)' "$repo|--bg|--resume|sess-q1;" "$(calls)"
# no record at all: the bare handle is still found, and a bare wake accepts it
rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "q2|sess-q2|host|$repo|background|0|done|100"
SAVED_STATE=stopped saved_opts q2 --name host --model opus
out="$(adn 'desk host' wake host "$repo" -- --model opus)"
check 'names: no record: found by the bare handle, woken bare although the template now says another name' "$repo|--bg|--resume|sess-q2;" "$(calls)"
check 'names: the name the session keeps is then recorded' "host	$repo	q2	sess-q2	host" "$(rec)"
# no record, the session named as the template renders now
rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "q3|sess-q3|desk host|$repo|background|0|done|100"
SAVED_STATE=stopped saved_opts q3 --name 'desk host'
out="$(adn 'desk host' wake host "$repo")"
check 'names: no record: found by the rendered name, woken bare' "$repo|--bg|--resume|sess-q3;" "$(calls)"
# a session under a name the agent never had is not the agent's
rm -f "$records"; table "q4|sess-q4|other name|$repo|background|0|done|100"
out="$(adn 'desk host' wake host "$repo")"; rc=$?
check 'names: a session under a name the agent never had is not the agent'"'"'s' "1:" "$rc:$(calls)"
# saved options that are not the agent's: still bare, under the name it keeps (1.9.3)
rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "q5|sess-q5|host|$repo|background|0|done|100"
SAVED_STATE=stopped saved_opts q5 --name host
out="$(adn 'desk host' wake host "$repo" -- --agent x)"
check 'names: saved options that lack the args: bare, the session keeps its name' "$repo|--bg|--resume|sess-q5;" "$(calls)"
check 'names: the name it keeps is recorded' "host	$repo	q5	sess-q5	host" "$(rec)"
rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "q7|sess-q7|host|$repo|background|0|done|100"
SAVED_STATE=stopped saved_opts q7 --name host
out="$(adn 'desk host' wake host "$repo")"
check 'names: a saved --name that is one the agent has had: bare, no warning' "$repo|--bg|--resume|sess-q7;" "$(calls)"
lacks 'names: a saved --name the agent has had: no warning' "$out" 'differ'
# the session is gone: the fresh start uses the session name
rm -f "$records"; rm -rf "$CLAUDE_CONFIG_DIR/jobs"
table "q6|sess-q6|host|$repo|background|0|failed|100"
SAVED_STATE=stopped saved_opts q6 --name host
out="$(FAKE_RESUME_GONE=q6 adn 'desk host' wake host "$repo")"
check 'names: a fresh start after a gone session uses the session name' "$repo|--bg|--resume|sess-q6;$repo|--bg|--name|desk host;" "$(calls)"
# the history is short
rm -f "$records"; table
for n in n1 n2 n3 n4 n5 n6 n7; do
  out="$(adn "$n" start-bg host "$repo")"
  end_session "$(awk -F'\t' -v n="$n" '$3 == n { print $1 }' "$FAKE_TABLE")"
done
check 'names: the history keeps the last five names before the current one, newest first' "n7	n6+n5+n4+n3+n2" "$(rec | cut -f5,6)"

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
