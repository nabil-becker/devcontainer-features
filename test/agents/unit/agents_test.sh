#!/usr/bin/env bash
# Docker-free tests of the agents Feature's `agents` command: the agent list (parsing, the
# YAML subset, required keys, unknown keys warned, errors with file and line), where the list
# is found (AGENTS_FILE from the task variable, .env, .devcontainer/.env, the environment, the
# default; a missing file named with its source), every verb per kind (start, --resume,
# --new and its question, up, list, stop, logs), the no-terminal rule, the fallbacks when the
# adapter answers exit 3 (not supported), the once-per-container-start marker, and the
# Feature Taskfile handing AGENTS_FILE and CLI_ARGS on. A fake adapter (agent-adapter-fake)
# keeps sessions in a file and records every call. Part of `task lint`
# (`task test:agents-unit`). AGENTS_SH points the test at another copy of the script.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
agents_sh="${AGENTS_SH:-$root/src/agents/agents.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

bin="$T/bin"; mkdir -p "$bin"
cp "$agents_sh" "$bin/agents"; chmod +x "$bin/agents"
# The fake adapter: sessions in $FAKE_SESSIONS (name<TAB>id<TAB>state<TAB>folder, newest first);
# FAKE_UNSUPPORTED (a space-separated list of verbs) answers exit 3, FAKE_FAIL exit 1; every call
# is recorded in $FAKE_CALLS as "verb|name|folder|arg|arg..."; FAKE_LIST_ERR makes `list` fail
# (exit 1) with that message on stderr, as an adapter whose CLI cannot be read does. `hint`
# prints how to resume by hand and is not recorded.
cat > "$bin/agent-adapter-fake" <<'FAKE'
#!/usr/bin/env bash
verb="$1"; shift
case " ${FAKE_UNSUPPORTED:-} " in *" $verb "*) echo "fake: $verb not supported" >&2; exit 3 ;; esac
case " ${FAKE_FAIL:-} " in *" $verb "*) exit 1 ;; esac
if [ "$verb" = list ] && [ -n "${FAKE_LIST_ERR:-}" ]; then echo "list" >> "$FAKE_CALLS"; echo "agent-adapter-fake: $FAKE_LIST_ERR" >&2; exit 1; fi
if [ "$verb" = hint ]; then echo "resume it by hand: cd $2 && fake --resume (pick $1)"; exit 0; fi
case "$verb" in
  session-busy) case " ${FAKE_BUSY:-} " in *" $1 "*) exit 0 ;; esac; exit 1 ;;
  session-stop) echo "session-stop|$1" >> "$FAKE_CALLS"; sed -i "s/^\([^\t]*\t$1\t\)running\t/\1stopped\t/" "$FAKE_SESSIONS"; exit 0 ;;
  session-remove) echo "session-remove|$1" >> "$FAKE_CALLS"; sed -i "/^[^\t]*\t$1\t/d" "$FAKE_SESSIONS"; exit 0 ;;
esac
if [ "$verb" = list ]; then echo "list" >> "$FAKE_CALLS"; cat "$FAKE_SESSIONS" 2>/dev/null; exit 0; fi
if [ "$verb" = supports ]; then echo start-bg; exit 0; fi
name="$1" folder="$2"; shift 2
line="$verb|$name|$folder"; for a in "$@"; do line="$line|$a"; done
echo "$line" >> "$FAKE_CALLS"
case "$verb" in
  start-bg) n=$(( $(cat "$FAKE_SESSIONS" 2>/dev/null | grep -c .) + 1 ))
    { printf '%s\tid-%s-%s\trunning\t%s\n' "$name" "$name" "$n" "$folder"; cat "$FAKE_SESSIONS" 2>/dev/null; } > "$FAKE_SESSIONS.new"
    mv "$FAKE_SESSIONS.new" "$FAKE_SESSIONS"; echo "id-$name-$n" ;;
  wake) sed -i "s/^\($name\t[^\t]*\t\)\(stopped\|failed\)\t/\1running\t/" "$FAKE_SESSIONS" ;;
  stop) sed -i "0,/^\($name\t[^\t]*\t\)running\t/s//\1stopped\t/" "$FAKE_SESSIONS" ;;
  logs) echo "fake log of $name" ;;
esac
exit 0
FAKE
chmod +x "$bin/agent-adapter-fake"

repo="$T/repo"; mkdir -p "$repo/.devcontainer" "$repo/rooms/review" "$repo/sub"
export FAKE_SESSIONS="$T/sessions" FAKE_CALLS="$T/calls" AGENTS_STATE_DIR="$T/state" AGENTS_START_ID=start-1
export AGENTS_SETTLE_INTERVAL=0 AGENTS_SETTLE_TIMEOUT=0
unset AGENTS_FILE AGENTS_FILE_TASK_VAR AGENTS_TTY CLAUDE_CODE_CHILD_SESSION
write_list() { cat > "$repo/.devcontainer/agents.yml"; }
reset() { : > "$T/sessions"; : > "$T/calls"; rm -rf "$T/state"; unset FAKE_UNSUPPORTED FAKE_FAIL FAKE_LIST_ERR FAKE_BUSY; }
run() { (cd "${DIRIN:-$repo}" && PATH="$bin:$PATH" agents "$@" 2>&1); }
calls() { grep -v '^list$' "$T/calls" | tr '\n' ';'; }

# ------------------------------------------------------------------- parsing ----
write_list <<'YAML'
# the agents of this repository
---
agents:
  - name: host            # the main one
    cli: fake
    kind: resident
    args: [--model, "opus 4", 'it''s', --flag=a:b]   # a flow list
  - name: reviewer
    cli: fake
    kind: on-demand
    folder: rooms/review
    args:
      - --effort
      - "high"
    note: kept for us
    owner:
      team: x
  -
    name: "pair"
    kind: 'on-demand'
    cli: fake
other: thing
YAML
out="$(run check)"; rc=$?
check 'check: a valid list exits 0' 0 "$rc"
contains 'check: names the file and its source' "$out" "$repo/.devcontainer/agents.yml (from the default"
contains 'check: counts the agents' "$out" '3 agent(s)'
contains 'check: a flow list with quotes and a colon' "$out" 'host: cli fake, resident, folder ., args: [--model] [opus 4] [it'"'"'s] [--flag=a:b]'
contains 'check: a block list of args' "$out" 'reviewer: cli fake, on-demand, folder rooms/review, args: [--effort] [high]'
contains 'check: folder defaults to ., no args' "$out" 'pair: cli fake, on-demand, folder ., args: none'
contains 'check: an unknown key is a warning with its line' "$out" "agents.yml:15: unknown key 'note' (ignored)"
contains 'check: an unknown top-level key is a warning' "$out" "unknown top-level key 'other'"
lacks 'check: a nested unknown key is skipped, not read' "$out" "'team'"

bad() { # <name> <expected text> : the list on stdin must be refused with exit 2
  write_list
  local o r; o="$(run check)"; r=$?
  check "refused: $1 (exit 2)" 2 "$r"
  contains "refused: $1 (message)" "$o" "$2"
}
printf 'agents:\n  - name: a\n    kind: resident\n' | bad 'no cli' "agents.yml:2: entry 1 has no 'cli'"
printf 'agents:\n  - cli: fake\n    kind: resident\n' | bad 'no name' "has no 'name'"
printf 'agents:\n  - name: a\n    cli: fake\n' | bad 'no kind' "has no 'kind'"
printf 'agents:\n  - name: a\n    cli: fake\n    kind: daemon\n' | bad 'an unknown kind' "kind 'daemon' is neither resident nor on-demand"
printf 'agents:\n  - name: a b\n    cli: fake\n    kind: resident\n' | bad 'a name with a space' "may hold only letters"
printf 'agents:\n  - name: a\n    cli: fake\n    kind: resident\n  - name: a\n    cli: fake\n    kind: on-demand\n' | bad 'a duplicate name' "name 'a' is already used by entry 1"
printf 'agents:\n  - name: a\n    cli: fake\n    kind: resident\n    folder: /etc\n' | bad 'an absolute folder' "must be relative"
printf 'agents:\n  - name: a\n    cli: fake\n    kind: resident\n    folder: ../x\n' | bad 'a folder outside' "must stay inside"
printf 'agents:\n  - name: a\n    cli: fake\n    kind: resident\n    args: --model opus\n' | bad 'args as a string' "agents.yml:5: args must be a list"
printf 'agents:\n  - name: "a\n    cli: fake\n' | bad 'an open quote' "agents.yml:2: a quoted value is not closed"
printf 'agents:\n  - name: a\n    cli: fake\n     kind: resident\n' | bad 'bad indentation' "agents.yml:4: unexpected indentation"
printf 'agents:\n  - name: a\n    name: b\n' | bad 'a key twice' "'name' appears twice"
printf 'agents:\n\t- name: a\n' | bad 'a tab' "a tab in the indentation"
printf 'agents:\n  - {name: a, cli: fake}\n' | bad 'a flow mapping' "not { }"
printf 'agents:\n  - name: a\n    cli: fake\n    kind: resident\n    args: [a, [b]]\n' | bad 'a nested list' "nested lists"
printf 'agents:\n  - name: a\n    cli: fake\n    kind: resident\n    args: [a,\n' | bad 'an open flow list' "must close on the same line"
printf 'name: a\n' | bad 'no agents key' "no agents: list"
printf 'agents:\n  - name: a\n    cli: fake\n    kind: resident\n    args: [""]\n' | bad 'an empty argument' "an empty argument"
write_list <<'YAML'
agents: []
YAML
out="$(run check)"; rc=$?
check 'agents: [] is an empty list' 0 "$rc"
contains 'agents: [] counts none' "$out" '0 agent(s)'

# ------------------------------------------------------ where the list is ----
rm -f "$repo/.devcontainer/agents.yml"
mkdir -p "$repo/ops" "$repo/env" "$repo/dc"
for f in ops env dc; do printf 'agents:\n  - name: from-%s\n    cli: fake\n    kind: on-demand\n' "$f" > "$repo/$f/agents.yml"; done
printf 'agents:\n  - name: from-default\n    cli: fake\n    kind: on-demand\n' > "$T/default.yml"

out="$(run check)"; rc=$?
check 'missing default list: exit 2' 2 "$rc"
contains 'missing default list: names the path' "$out" "no agent list at $repo/.devcontainer/agents.yml"
contains 'missing default list: names the source' "$out" 'from the default (AGENTS_FILE is not set)'
out="$(AGENTS_FILE=env/agents.yml run check)"
contains 'environment: used when nothing else sets it' "$out" 'from AGENTS_FILE in the environment'
contains 'environment: its list is read' "$out" 'from-env'
printf 'AGENTS_FILE=dc/agents.yml\n' > "$repo/.devcontainer/.env"
out="$(AGENTS_FILE=env/agents.yml run check)"
contains '.devcontainer/.env beats the environment' "$out" 'from-dc'
contains '.devcontainer/.env named as the source' "$out" 'from AGENTS_FILE in .devcontainer/.env'
printf 'OTHER=1\nexport AGENTS_FILE="ops/agents.yml"  # the ops list\n' > "$repo/.env"
out="$(AGENTS_FILE=env/agents.yml run check)"
contains 'the root .env beats .devcontainer/.env' "$out" 'from-ops'
contains 'the root .env: export, quotes and a comment dropped' "$out" "$repo/ops/agents.yml (from AGENTS_FILE in .env)"
out="$(AGENTS_FILE=env/agents.yml AGENTS_FILE_TASK_VAR=dc/agents.yml run check)"
contains 'a task variable different from .env and the environment wins' "$out" 'from-dc'
contains 'a task variable is named as such' "$out" 'from the task variable AGENTS_FILE'
out="$(AGENTS_FILE=env/agents.yml AGENTS_FILE_TASK_VAR=env/agents.yml run check)"
contains 'a task variable equal to the environment is the environment (Task fills it from there): .env wins' "$out" 'from-ops'
out="$(AGENTS_FILE_TASK_VAR=ops/agents.yml run check)"
contains 'a task variable equal to .env is named as .env' "$out" 'from AGENTS_FILE in .env'
out="$(AGENTS_FILE_TASK_VAR=nope.yml run check)"; rc=$?
check 'a missing file from the task variable: exit 2' 2 "$rc"
contains 'a missing file from the task variable: path and source' "$out" "no agent list at $repo/nope.yml (from the task variable AGENTS_FILE)"
out="$(AGENTS_FILE_TASK_VAR="$T/default.yml" run check)"
contains 'an absolute path is used as it is' "$out" 'from-default'
out="$(DIRIN="$repo/rooms/review" run check)"
contains 'from a sub-folder the root is the folder holding .devcontainer' "$out" "$repo/ops/agents.yml"
rm -f "$repo/.env" "$repo/.devcontainer/.env"

# ------------------------------------------------------------- the verbs ----
write_list <<'YAML'
agents:
  - name: host
    cli: fake
    kind: resident
    args: [--remote-control]
  - name: reviewer
    cli: fake
    kind: on-demand
    folder: rooms/review
    args: [--model, sonnet]
  - name: ghost
    cli: nosuch
    kind: on-demand
  - name: lost
    cli: fake
    kind: resident
    folder: not-there
YAML

reset
out="$(AGENTS_TTY=1 run start host)"; rc=$?
check 'resident, none running, terminal: exit 0' 0 "$rc"
check 'resident, none running, terminal: start-bg then attach, args from the list' "start-bg|host|$repo|--|--remote-control;attach|host|$repo|--|--remote-control;" "$(calls)"
contains 'resident: says it started' "$out" 'host: started in the background (id-host-1)'

reset
out="$(AGENTS_TTY=0 run start host)"; rc=$?
check 'resident, no terminal: exit 0' 0 "$rc"
check 'resident, no terminal: started, never attached' "start-bg|host|$repo|--|--remote-control;" "$(calls)"
contains 'resident, no terminal: prints how to attach' "$out" 'attach from a terminal with: task agents -- host'

reset; printf 'host\tid-old\trunning\t%s\n' "$repo" > "$T/sessions"
out="$(AGENTS_TTY=1 run start host -- --effort high)"; rc=$?
check 'resident running: attach only, extra args after the list args' "attach|host|$repo|--|--remote-control|--effort|high;" "$(calls)"
contains 'resident running: says so' "$out" 'host: running (id-old)'

reset; printf 'host\tid-old\trunning\t%s\n' "$repo" > "$T/sessions"
out="$(AGENTS_TTY=1 run start host --resume)"
check 'resident --resume: the same as plain' "attach|host|$repo|--|--remote-control;" "$(calls)"

reset; printf 'host (2)\tid-new\trunning\t%s\nhost\tid-old\trunning\t%s\nhost-review\tid-x\trunning\t%s\nhost\tid-y\trunning\t%s/sub\n' "$repo" "$repo" "$repo" "$repo" > "$T/sessions"
out="$(AGENTS_TTY=0 run start host)"
contains 'a collision "host (2)" counts, the newest is kept' "$out" 'host: running (id-new)'
contains 'the other running session is reported as an extra' "$out" '1 more running session(s)'
lacks 'host-review (part of the name) does not count' "$out" 'id-x'
check 'nothing started when running' "" "$(calls)"

reset; printf 'host\tid-old\tstopped\t%s\n' "$repo" > "$T/sessions"
out="$(AGENTS_TTY=1 run start host)"
check 'resident stopped: wake (same conversation), then attach' "wake|host|$repo|--|--remote-control;attach|host|$repo|--|--remote-control;" "$(calls)"
contains 'resident stopped: says so' "$out" 'host: stopped (id-old); waking it'

reset; printf 'host\tid-old\tfailed\t%s\n' "$repo" > "$T/sessions"; export FAKE_UNSUPPORTED=wake
out="$(AGENTS_TTY=0 run start host)"
check 'wake unsupported: a fresh start in the background' "start-bg|host|$repo|--|--remote-control;" "$(calls)"
contains 'wake unsupported: one line says so' "$out" 'cannot wake a stopped session; starting a fresh one'

reset; export FAKE_UNSUPPORTED=start-bg
out="$(AGENTS_TTY=1 run start host)"; rc=$?
check 'start-bg unsupported: the resident runs as on-demand (new)' "new|host|$repo|--|--remote-control;" "$(calls)"
contains 'start-bg unsupported: one line says so' "$out" 'has no background mode; opening a new session'
reset; export FAKE_UNSUPPORTED=start-bg
out="$(AGENTS_TTY=0 run start host)"; rc=$?
check 'start-bg unsupported, no terminal: refused (exit 2)' 2 "$rc"
check 'start-bg unsupported, no terminal: nothing opened' "" "$(calls)"

reset; printf 'host\tid-old\trunning\t%s\n' "$repo" > "$T/sessions"; export FAKE_UNSUPPORTED=attach
out="$(AGENTS_TTY=1 run start host)"; rc=$?
check 'attach unsupported: exit 1' 1 "$rc"
contains 'attach unsupported: the reason' "$out" 'cannot attach to a background session'
contains 'attach unsupported: its logs instead' "$out" 'fake log of host'

reset; export FAKE_UNSUPPORTED=list
out="$(AGENTS_TTY=0 run start host)"; rc=$?
check 'list unsupported: started once' "start-bg|host|$repo|--|--remote-control;" "$(calls)"
contains 'list unsupported: says it cannot promise' "$out" "cannot be promised"
: > "$T/calls"
out="$(AGENTS_TTY=0 run start host)"
check 'list unsupported: never twice in one container start (marker)' "" "$(calls)"
contains 'list unsupported: the second run says why' "$out" 'started earlier in this container start'
: > "$T/calls"
out="$(AGENTS_TTY=0 AGENTS_START_ID=start-2 run start host)"
check 'list unsupported: a new container start starts it again' "start-bg|host|$repo|--|--remote-control;" "$(calls)"

# the listing failed (not "cannot list"): never a fresh start, never a second copy
reset; printf 'host\tid-old\tstopped\t%s\n' "$repo" > "$T/sessions"; export FAKE_LIST_ERR='the session list could not be read: timed out after 30s'
for tty in 1 0; do
  out="$(AGENTS_TTY=$tty run start host)"; rc=$?
  check "listing failed, resident start (terminal $tty): exit 1" 1 "$rc"
  check "listing failed, resident start (terminal $tty): nothing started, woken or attached" "" "$(calls)"
  contains "listing failed, resident start (terminal $tty): the adapter's reason" "$out" 'host: the fake sessions could not be listed (the session list could not be read: timed out after 30s); starting nothing'
  contains "listing failed, resident start (terminal $tty): how to resume by hand" "$out" "agents: host: resume it by hand: cd $repo && fake --resume (pick host)"
done
out="$(AGENTS_TTY=1 run start host --resume)"; rc=$?
check 'listing failed, resident --resume: nothing started, exit 1' "1:" "$rc:$(calls)"
out="$(AGENTS_TTY=0 run start host --new --yes)"; rc=$?
check 'listing failed, resident --new: nothing stopped or started, exit 1' "1:" "$rc:$(calls)"
out="$(run up --no-wait)"; rc=$?
check 'listing failed, up: exit 1' 1 "$rc"
check 'listing failed, up: no resident started' "" "$(calls)"
contains 'listing failed, up: the hint' "$out" 'fake --resume (pick host)'
out="$(run up --post-start)"; rc=$?
check 'listing failed, up --post-start: the container start goes on' 0 "$rc"
check 'listing failed, up --post-start: no resident started' "" "$(calls)"
contains 'listing failed, up --post-start: says so' "$out" 'did not start'
export FAKE_UNSUPPORTED=hint
out="$(AGENTS_TTY=0 run start host)"; rc=$?
contains 'listing failed, no hint from the adapter: a general line' "$out" 'check with fake itself whether it runs'
check 'listing failed, no hint from the adapter: still nothing started' "1:" "$rc:$(calls)"
unset FAKE_UNSUPPORTED
export FAKE_FAIL=resume; : > "$T/calls"
out="$(AGENTS_TTY=1 run start reviewer --resume)"; rc=$?
check 'listing failed, on-demand --resume that fails: exit 1' 1 "$rc"
check 'listing failed, on-demand --resume that fails: never a fresh session in its place' "" "$(calls)"
unset FAKE_FAIL
: > "$T/calls"
out="$(AGENTS_TTY=1 run start reviewer)"; rc=$?
check 'listing failed, on-demand plain start: a new session as always' "new|reviewer|$repo/rooms/review|--|--model|sonnet;" "$(calls)"

reset; printf 'host\tid-old\trunning\t%s\n' "$repo" > "$T/sessions"
out="$(printf 'y\n' | AGENTS_TTY=1 run start host --new)"; rc=$?
contains '--new asks first' "$out" 'Stop host (id-old) and start a fresh session? [y/N]'
check '--new, yes: stop, start-bg, attach' "stop|host|$repo|--|--remote-control;start-bg|host|$repo|--|--remote-control;attach|host|$repo|--|--remote-control;" "$(calls)"
reset; printf 'host\tid-old\trunning\t%s\n' "$repo" > "$T/sessions"
out="$(printf 'n\n' | AGENTS_TTY=1 run start host --new)"; rc=$?
check '--new, no: exit 0' 0 "$rc"
check '--new, no: nothing done' "" "$(calls)"
contains '--new, no: says so' "$out" 'nothing changed'
reset; printf 'host\tid-old\trunning\t%s\n' "$repo" > "$T/sessions"
out="$(AGENTS_TTY=0 run start host --new)"; rc=$?
check '--new without a terminal: refused (exit 2)' 2 "$rc"
check '--new without a terminal: nothing stopped' "" "$(calls)"
out="$(AGENTS_TTY=0 run start host --new --yes)"; rc=$?
check '--new --yes without a terminal: stop and start, no attach' "stop|host|$repo|--|--remote-control;start-bg|host|$repo|--|--remote-control;" "$(calls)"
out="$(run start host --new --resume)"; rc=$?
check '--new and --resume together: exit 2' 2 "$rc"

reset
out="$(AGENTS_TTY=1 run start reviewer --effort high)"; rc=$?
check 'on-demand: new in its folder, list args then extra args' "new|reviewer|$repo/rooms/review|--|--model|sonnet|--effort|high;" "$(calls)"
reset
out="$(AGENTS_TTY=1 run start reviewer --new)"
check 'on-demand --new: the same as plain' "new|reviewer|$repo/rooms/review|--|--model|sonnet;" "$(calls)"
reset
out="$(AGENTS_TTY=1 run start reviewer --resume -- --resume)"
check 'on-demand --resume: resume; after -- a flag goes to the CLI' "resume|reviewer|$repo/rooms/review|--|--model|sonnet|--resume;" "$(calls)"
reset; export FAKE_UNSUPPORTED=resume
out="$(AGENTS_TTY=1 run start reviewer --resume)"
check 'resume unsupported: new instead' "new|reviewer|$repo/rooms/review|--|--model|sonnet;" "$(calls)"
contains 'resume unsupported: one line says so' "$out" 'cannot resume a conversation; opening a new one'
reset
out="$(AGENTS_TTY=0 run start reviewer)"; rc=$?
check 'on-demand without a terminal: refused (exit 2)' 2 "$rc"
contains 'on-demand without a terminal: says why' "$out" 'needs a terminal'
check 'on-demand without a terminal: nothing called' "" "$(calls)"
out="$(run start reviewer </dev/null)"; rc=$?
check 'no terminal detected from stdin (no AGENTS_TTY): refused' 2 "$rc"

out="$(AGENTS_TTY=1 run start nobody)"; rc=$?
check 'an unknown agent: exit 2' 2 "$rc"
contains 'an unknown agent: names the agents' "$out" 'agents: host reviewer ghost lost'
out="$(AGENTS_TTY=1 run start ghost)"; rc=$?
check 'a missing adapter: exit 1' 1 "$rc"
contains 'a missing adapter: names the program and the Feature' "$out" 'agent-adapter-nosuch is not on PATH'
out="$(AGENTS_TTY=1 run start lost)"; rc=$?
check 'a missing folder: exit 1' 1 "$rc"
contains 'a missing folder: names it' "$out" "folder 'not-there' does not exist"
out="$(run start)"; rc=$?
check 'start without a name: exit 2' 2 "$rc"

# up
reset; mkdir -p "$repo/not-there"
out="$(run up)"; rc=$?
check 'up: exit 0' 0 "$rc"
check 'up: starts every resident not running, no attach, skips on-demand' "start-bg|host|$repo|--|--remote-control;start-bg|lost|$repo/not-there|--;" "$(calls)"
contains 'up: on-demand skipped' "$out" 'reviewer: on-demand, not started'
contains 'up: waits for restored sessions first' "$out" 'waiting for restored fake sessions'
: > "$T/calls"
out="$(run up --no-wait)"
check 'up twice: starts nothing (idempotent)' "" "$(calls)"
lacks 'up --no-wait: no wait' "$out" 'waiting for restored'
reset; printf 'host\tid-old\tfailed\t%s\n' "$repo" > "$T/sessions"
out="$(run up --no-wait)"
contains 'up: a failed resident is woken' "$(calls)" "wake|host|$repo"
reset; export FAKE_UNSUPPORTED=start-bg
out="$(run up --no-wait)"; rc=$?
contains 'up: start-bg unsupported is skipped with a line' "$out" 'host: skipped, fake has no background mode'
check 'up: start-bg unsupported is not a failure' 0 "$rc"
reset; export FAKE_FAIL=start-bg
out="$(run up --no-wait)"; rc=$?
check 'up: a failed start is exit 1' 1 "$rc"
out="$(run up --post-start)"; rc=$?
check 'up --post-start: never fails the container start' 0 "$rc"
contains 'up --post-start: says what did not start' "$out" 'did not start'
reset
mv "$repo/.devcontainer/agents.yml" "$T/saved.yml"
out="$(run up --post-start)"; rc=$?
check 'up --post-start without a list: exit 0' 0 "$rc"
contains 'up --post-start without a list: one line' "$out" 'no agent list at'
out="$(run up)"; rc=$?
check 'up without a list: exit 2' 2 "$rc"
mv "$T/saved.yml" "$repo/.devcontainer/agents.yml"
rmdir "$repo/not-there"

# list, stop, logs
reset; printf 'host\tid-old\trunning\t%s\nreviewer\tid-r\tstopped\t%s/rooms/review\n' "$repo" "$repo" > "$T/sessions"
out="$(run list)"; rc=$?
check 'list: exit 0' 0 "$rc"
contains 'list: a header' "$out" 'NAME'
contains 'list: a running resident with its id' "$out" "$(printf '%-16s %-10s %-8s %-9s %-38s %s' host resident fake running id-old .)"
contains 'list: an on-demand agent with only a stopped session is none (not yesterday'"'"'s session)' "$out" "$(printf '%-16s %-10s %-8s %-9s %-38s %s' reviewer on-demand fake none - rooms/review)"
contains 'list: no adapter' "$out" 'no-adapter'
contains 'list: no folder' "$out" 'no-folder'
out="$(run list --json)"
contains 'list --json: an array of objects' "$out" '[{"name":"host","kind":"resident","cli":"fake","folder":".","state":"running","id":"id-old","extras":0},'
reset; printf 'reviewer\tid-r2\trunning\t%s/rooms/review\nreviewer\tid-r\tstopped\t%s/rooms/review\n' "$repo" "$repo" > "$T/sessions"
out="$(run list)"
contains 'list: an on-demand agent with a running session shows it' "$out" "$(printf '%-16s %-10s %-8s %-9s %-38s %s' reviewer on-demand fake running id-r2 rooms/review)"
export FAKE_UNSUPPORTED=list
out="$(run list --json)"
contains 'list: unknown when the adapter cannot list' "$out" '"state":"unknown"'
reset; export FAKE_LIST_ERR="'fake agents' exited 1: error: unknown option '--json'"
out="$(run list)"; rc=$?
check 'list, the listing failed: exit 0 (the list is still shown)' 0 "$rc"
contains 'list, the listing failed: state error, not unknown' "$out" "$(printf '%-16s %-10s %-8s %-9s %-38s %s' host resident fake error - .)"
contains 'list, the listing failed: the adapter'"'"'s message, once' "$out" "the fake sessions could not be listed: 'fake agents' exited 1: error: unknown option '--json'"
out="$(run list --json 2>/dev/null)"
contains 'list --json, the listing failed: state and message' "$out" '"state":"error","id":"","extras":0,"error":"'"'"'fake agents'"'"' exited 1: error: unknown option '"'"'--json'"'"'"}'
reset; printf 'host\tid-old\trunning\t%s\n' "$repo" > "$T/sessions"
out="$(run stop host)"; rc=$?
check 'stop: the adapter stop' "stop|host|$repo|--|--remote-control;" "$(calls)"
: > "$T/calls"
out="$(run stop host --extras)"
check 'stop --extras: handed to the adapter' "stop|host|$repo|--extras|--|--remote-control;" "$(calls)"
export FAKE_UNSUPPORTED=stop
out="$(run stop host)"; rc=$?
check 'stop unsupported: exit 3' 3 "$rc"
contains 'stop unsupported: says so' "$out" 'cannot stop'
reset
out="$(run logs host)"; rc=$?
contains 'logs: the adapter logs' "$out" 'fake log of host'
export FAKE_UNSUPPORTED=logs
out="$(run logs host)"; rc=$?
check 'logs unsupported: exit 3' 3 "$rc"
out="$(run frobnicate)"; rc=$?
check 'an unknown verb: exit 2' 2 "$rc"

# ------------------------------------------------------------------ reset ----
cp "$repo/.devcontainer/agents.yml" "$T/list.before-reset"
write_list <<'YAML'
agents:
  - name: host
    cli: fake
    kind: resident
  - name: reviewer
    cli: fake
    kind: resident
    folder: rooms/review
  - name: pair
    cli: fake
    kind: on-demand
YAML
mkdir -p "$T/elsewhere"
sessions_for_reset() {
  printf '%s\n' \
    "host	id-h1	running	$repo" \
    "host (2)	id-h2	running	$repo" \
    "host	id-h0	stopped	$repo" \
    "pair	id-p0	stopped	$repo" \
    "stranger	id-x	running	$repo" \
    "old-stranger	id-x0	stopped	$repo" \
    "host	id-y	running	$T/elsewhere" \
    "host	id-y0	stopped	$T/elsewhere" \
    "reviewer	id-r0	stopped	$repo/rooms/review" > "$T/sessions"
}
reset; sessions_for_reset; cp "$T/sessions" "$T/sessions.before"
out="$(run reset host)"; rc=$?
check 'reset: a dry run by default (exit 0)' 0 "$rc"
check 'reset dry run: nothing called' "" "$(calls)"
check 'reset dry run: the sessions unchanged' "$(cat "$T/sessions.before")" "$(cat "$T/sessions")"
contains 'reset plan: the keep reason is a full sentence' "$out" "the agent's session (the one it attaches to)"
contains 'reset dry run: says so' "$out" 'a dry run, nothing changed; add --yes'
contains 'reset plan: keeps the session the agent is' "$out" "$(printf '%-16s %-38s %-8s %-9s' host id-h1 running keep)"
contains 'reset plan: stops the duplicate' "$out" "$(printf '%-16s %-38s %-8s %-9s' host id-h2 running stop)"
contains 'reset plan: an ended session kept without --purge' "$out" "$(printf '%-16s %-38s %-8s %-9s' host id-h0 stopped keep)"
contains 'reset plan: a session of no listed agent is reported, untouched' "$out" "$(printf '%-16s %-38s %-8s %-9s' '(stranger)' id-x running untouched)"
lacks 'reset plan: another folder is not in the plan' "$out" 'id-y'
lacks 'reset plan: another listed agent (not named) is not in the plan' "$out" 'id-p0'
out="$(run reset host --yes)"; rc=$?
check 'reset tidy: exit 0' 0 "$rc"
check 'reset tidy: stops only the duplicate, then records the agent' "session-stop|id-h2;record|host|$repo|--;" "$(calls)"
reset; sessions_for_reset
out="$(run reset host --purge --yes)"; rc=$?
check 'reset --purge: stops the duplicate, removes only the agent'"'"'s ended session in its folder' "session-stop|id-h2;session-remove|id-h0;record|host|$repo|--;" "$(calls)"
contains 'reset --purge: other folders and unlisted sessions still there' "$(cut -f2 "$T/sessions" | tr '\n' ' ')" 'id-p0 id-x id-x0 id-y id-y0'
reset; sessions_for_reset
out="$(run reset host --purge --include-unlisted --yes)"
check 'reset --include-unlisted: the folder'"'"'s other sessions too, never another folder' "session-stop|id-h2;session-remove|id-h0;session-stop|id-x;session-remove|id-x0;record|host|$repo|--;" "$(calls)"
reset; sessions_for_reset
out="$(run reset --all --yes)"; rc=$?
check 'reset --all: each listed agent; a resident with no running session is started (woken)' \
  "session-stop|id-h2;record|host|$repo|--;record|reviewer|$repo/rooms/review|--;record|pair|$repo|--;wake|reviewer|$repo/rooms/review|--;" "$(calls)"
out="$(run reset host --all)"; rc=$?
check 'reset: names and --all together: exit 2' 2 "$rc"
out="$(run reset)"; rc=$?
check 'reset without names: exit 2' 2 "$rc"
reset; sessions_for_reset
out="$(CLAUDE_CODE_CHILD_SESSION=1 run reset host --yes)"; rc=$?
check 'reset inside a Claude Code session: refused (exit 2)' 2 "$rc"
check 'reset inside a Claude Code session: nothing called' "" "$(calls)"
contains 'reset inside a Claude Code session: says where to run it' "$out" 'run it from a container terminal or task devcontainer:shell'
out="$(CLAUDE_CODE_CHILD_SESSION=1 run reset host --yes --force)"; rc=$?
check 'reset inside a session --force: goes ahead' "session-stop|id-h2;record|host|$repo|--;" "$(calls)"
# a long unlisted name widens the AGENT column for every row
reset; sessions_for_reset; printf 'd47 d50 personalization medallion\tid-long\trunning\t%s\n' "$repo" >> "$T/sessions"
out="$(run reset host)"
contains 'reset plan: a long unlisted name keeps the columns aligned (keep row)' "$out" "$(printf '%-35s %-38s %-8s %-9s' host id-h1 running keep)"
contains 'reset plan: a long unlisted name keeps the columns aligned (header)' "$out" "$(printf '%-35s %-38s %-8s %-9s %s' AGENT SESSION STATE ACTION WHY)"
# a session mid-turn is not stopped
reset; sessions_for_reset; export FAKE_BUSY=id-h2
out="$(run reset host --yes)"; rc=$?
check 'reset, a duplicate mid-turn, applied: exit 2 (a refusal, nothing failed)' 2 "$rc"
check 'reset, a duplicate mid-turn: not stopped' "" "$(calls)"
contains 'reset, a duplicate mid-turn: says which and why' "$out" "$(printf '%-16s %-38s %-8s %-9s' host id-h2 running refused) would stop it, but it is mid-turn right now (busy)"
: > "$T/calls"
out="$(run reset host)"; rc=$?
check 'reset, a duplicate mid-turn, dry run: exit 2' 2 "$rc"
contains 'reset, only a refusal: counts it' "$out" 'agents: reset: 1 refused (see above); nothing else to stop, remove or start.'
lacks 'reset, only a refusal: not "nothing to stop" alone' "$out" 'agents: reset: nothing to stop'
: > "$T/calls"
out="$(run reset host --yes --force)"; rc=$?
check 'reset, a duplicate mid-turn, --force: stopped' "session-stop|id-h2;record|host|$repo|--;" "$(calls)"
reset; sessions_for_reset; export FAKE_UNSUPPORTED=session-busy
out="$(run reset host --yes)"; rc=$?
check 'reset, an adapter that cannot tell: not busy, stopped' "0:session-stop|id-h2;record|host|$repo|--;" "$rc:$(calls)"
contains 'reset, an adapter that cannot tell: says so' "$out" 'whether it is mid-turn is unknown (fake does not say)'
# uncommitted changes in the folder
if command -v git >/dev/null 2>&1; then
  reset; sessions_for_reset
  git -C "$repo" init -q && printf 'a\n' > "$repo/tracked" && git -C "$repo" add tracked &&
    git -C "$repo" -c user.name=t -c user.email=t@invalid commit -qm t && printf 'b\n' > "$repo/tracked"
  out="$(run reset host --yes)"; rc=$?
  check 'reset, uncommitted changes, plain: the duplicate stopped (exit 0)' "0:session-stop|id-h2;record|host|$repo|--;" "$rc:$(calls)"
  contains 'reset, uncommitted changes, plain: a warning naming the folder' "$out" "warning: uncommitted changes in $repo"
  reset; sessions_for_reset
  out="$(run reset host --purge --yes)"; rc=$?
  check 'reset --purge, uncommitted changes: exit 2' 2 "$rc"
  check 'reset --purge, uncommitted changes: the stop goes ahead, the removal does not' "session-stop|id-h2;record|host|$repo|--;" "$(calls)"
  contains 'reset --purge, uncommitted changes: says which folder' "$out" "would remove it (its conversation), but $repo has uncommitted changes (git status)"
  reset; sessions_for_reset
  out="$(run reset host --purge --yes --force)"
  check 'reset --purge, uncommitted changes, --force: goes ahead' "session-stop|id-h2;session-remove|id-h0;record|host|$repo|--;" "$(calls)"
  rm -rf "$repo/.git" "$repo/tracked"
fi
cp "$T/list.before-reset" "$repo/.devcontainer/agents.yml"

# ------------------------------------------------- the Feature Taskfile ----
if command -v task >/dev/null 2>&1; then
  reset
  mkdir -p "$T/inc"
  cp "$root/src/agents/taskfile.yml" "$T/inc/agents.yml"
  printf "version: '3'\nincludes:\n  agents:\n    taskfile: %s/inc/agents.yml\n" "$T" > "$T/features.yml"
  printf "version: '3'\ndotenv: ['.env', '.devcontainer/.env']\nincludes:\n  features:\n    taskfile: %s/features.yml\n    flatten: true\n" "$T" > "$repo/Taskfile.yml"
  out="$(cd "$repo" && AGENTS_TTY=1 PATH="$bin:$PATH" task agents -- reviewer --resume 2>&1)"
  check 'task agents -- <name> --resume: the start verb with the flags' "resume|reviewer|$repo/rooms/review|--|--model|sonnet;" "$(calls)"
  out="$(cd "$repo" && PATH="$bin:$PATH" task agents:check AGENTS_FILE=ops/agents.yml 2>&1)"
  contains 'task agents:check AGENTS_FILE=...: the task variable reaches the command' "$out" 'from the task variable AGENTS_FILE'
  printf 'AGENTS_FILE=dc/agents.yml\n' > "$repo/.env"
  out="$(cd "$repo" && AGENTS_FILE=env/agents.yml PATH="$bin:$PATH" task agents:check 2>&1)"
  contains 'task agents:check: .env beats the environment through Task' "$out" 'from AGENTS_FILE in .env'
  rm -f "$repo/.env"
  out="$(cd "$repo" && PATH="$bin:$PATH" task agents:list -- --json 2>&1)"
  contains 'task agents:list -- --json: CLI_ARGS reach the command' "$out" '"name":"host"'
else
  echo "skip - the Feature Taskfile (no task on PATH)"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
