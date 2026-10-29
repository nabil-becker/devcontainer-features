#!/usr/bin/env bash
# Docker-free contract tests of the agents Feature: the same scenarios run against two fake
# adapters with different capabilities, so `agents` is proven to rest on the adapter contract
# (docs/proposals/agents.md sections 5 and 6) and not on one CLI.
#   fakea: Claude-like. start-bg, wake, attach, resume, new, list, stop, logs (no hint, record or session-*).
#   fakeb: minimal. new, resume, attach only; start-bg, wake, list, stop, logs answer exit 3.
# Both log every call to their own file. A fake `claude` and a fake `agent-adapter-claude`
# are on PATH too and log if anything runs them: a list that uses only fakeb must never reach
# them. Also greps src/agents for a hard-coded claude outside the documented places.
# `supports` must agree with the verbs (listed: never exit 3; not listed: exit 3): checked on both
# fakes, on a deliberately lying fake (it must be caught) and on the real agent-adapter-claude
# with a fake `claude` that starts nothing. `agents check` prints each CLI's `supports`.
# Part of `task lint` (`task test:agents-contract`). AGENTS_SH points at another copy.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
agents_sh="${AGENTS_SH:-$root/src/agents/agents.sh}"
src_dir="$(dirname "$agents_sh")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

bin="$T/bin"; mkdir -p "$bin"
cp "$agents_sh" "$bin/agents"; chmod +x "$bin/agents"

# fakea: sessions in $SESS_A (name<TAB>id<TAB>state<TAB>folder, newest first), calls in $CALLS_A.
cat > "$bin/agent-adapter-fakea" <<'FAKE'
#!/usr/bin/env bash
verb="$1"; shift
[ "$verb" = supports ] && { printf '%s\n' start-bg wake attach resume new list stop logs; exit 0; }
echo "$verb|$*" >> "$CALLS_A"
[ "$verb" = list ] && { cat "$SESS_A" 2>/dev/null; exit 0; }
name="$1" folder="$2"
case "$verb" in
  start-bg) n=$(( $(grep -c . "$SESS_A" 2>/dev/null) + 1 ))
    { printf '%s\tida-%s\trunning\t%s\n' "$name" "$n" "$folder"; cat "$SESS_A" 2>/dev/null; } > "$SESS_A.new"
    mv "$SESS_A.new" "$SESS_A"; echo "ida-$n" ;;
  wake) sed -i "s/^\($name\t[^\t]*\t\)\(stopped\|failed\)\t/\1running\t/" "$SESS_A" ;;
  stop) sed -i "s/^\($name\t[^\t]*\t\)running\t/\1stopped\t/" "$SESS_A" ;;
  logs) echo "fakea log of $name" ;;
  attach | resume | new) ;;
  hint | record | session-busy | session-stop | session-remove) exit 3 ;;
  *) exit 2 ;;
esac
exit 0
FAKE
# fakeb: no background mode, no list, no stop, no logs.
cat > "$bin/agent-adapter-fakeb" <<'FAKE'
#!/usr/bin/env bash
verb="$1"; shift
[ "$verb" = supports ] && { printf '%s\n' new resume attach; exit 0; }
echo "$verb|$*" >> "$CALLS_B"
case "$verb" in
  new | resume | attach) exit 0 ;;
  start-bg | wake | list | stop | logs | hint | record | session-busy | session-stop | session-remove) echo "fakeb: $verb is not supported" >&2; exit 3 ;;
  *) exit 2 ;;
esac
FAKE
# fakec: lies. Its supports lists stop (and omits logs), but stop answers 3 and logs works.
cat > "$bin/agent-adapter-fakec" <<'FAKE'
#!/usr/bin/env bash
verb="$1"
[ "$verb" = supports ] && { printf '%s\n' new stop; exit 0; }
case "$verb" in new) exit 0 ;; logs) exit 0 ;; *) exit 3 ;; esac
FAKE
# anything named claude: must never run for a list of fakeb agents
for f in claude agent-adapter-claude; do
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALLS_CLAUDE"\nexit 1\n' "$f" > "$bin/$f"
done
chmod +x "$bin"/*

repo="$T/repo"; mkdir -p "$repo/.devcontainer"
export SESS_A="$T/sess-a" CALLS_A="$T/calls-a" CALLS_B="$T/calls-b" CALLS_CLAUDE="$T/calls-claude"
export AGENTS_STATE_DIR="$T/state" AGENTS_START_ID=start-1 AGENTS_SETTLE_INTERVAL=0 AGENTS_SETTLE_TIMEOUT=0
unset AGENTS_FILE AGENTS_FILE_TASK_VAR AGENTS_TTY CLAUDE_CODE_CHILD_SESSION
reset() { : > "$SESS_A"; : > "$CALLS_A"; : > "$CALLS_B"; : > "$CALLS_CLAUDE"; rm -rf "$T/state"; }
# run <tty 0|1> args...: sets OUT and RC
run() { local tty="$1"; shift; OUT="$(cd "$repo" && AGENTS_TTY="$tty" PATH="$bin:$PATH" agents "$@" 2>&1 </dev/null)"; RC=$?; }
calls() { tr '\n' ';' < "$1" | sed 's/;$//'; }
verbs() { cut -d'|' -f1 "$1" | tr '\n' ' ' | sed 's/ $//'; }

cat > "$repo/.devcontainer/agents.yml" <<'YAML'
agents:
  - name: a-res
    cli: fakea
    kind: resident
  - name: a-od
    cli: fakea
    kind: on-demand
  - name: b-res
    cli: fakeb
    kind: resident
  - name: b-od
    cli: fakeb
    kind: on-demand
    args: [--model, small]
YAML
D="$repo"

# --- check: one list mixing both CLIs
reset; run 0 check
check "check: exit 0 on a list mixing both CLIs" 0 "$RC"
contains "check: names a fakea agent" "$OUT" "a-res: cli fakea, resident"
contains "check: names a fakeb agent with its args" "$OUT" "b-od: cli fakeb, on-demand, stateful (identity b-od, lease container), folder ., args: [--model] [small]"
contains "check: counts four agents" "$OUT" "4 agent(s)"
check "check: calls no adapter verb (only supports)" "" "$(calls "$CALLS_A")$(calls "$CALLS_B")"
contains "check: shows fakea's capabilities on one line" "$OUT" "  fakea: start-bg wake attach resume new list stop logs"
contains "check: shows fakeb's capabilities on one line" "$OUT" "  fakeb: new resume attach"
check "check: one capabilities line per CLI" 2 "$(printf '%s\n' "$OUT" | grep -cE '^  fake[ab]: ')"

# --- start an on-demand agent, on each adapter: a new session in this terminal
reset; run 1 start a-od
check "start on-demand (fakea): exit 0" 0 "$RC"
check "start on-demand (fakea): new in the folder, nothing else" "new|a-od $D --" "$(calls "$CALLS_A")"
reset; run 1 start b-od
check "start on-demand (fakeb): exit 0" 0 "$RC"
check "start on-demand (fakeb): new with the entry's args, nothing else" "new|b-od $D -- --model small" "$(calls "$CALLS_B")"
for x in a b; do
  reset; run 0 start "$x-od"
  check "start on-demand without a terminal ($x): refused, exit 2" 2 "$RC"
  contains "start on-demand without a terminal ($x): says why" "$OUT" "needs a terminal"
  check "start on-demand without a terminal ($x): no new session" "" "$(grep -h '^new' "$CALLS_A" "$CALLS_B")"
done

# --- --resume on each adapter (both support resume)
reset; run 1 start a-od --resume
check "resume on-demand (fakea): exit 0, resume called" "resume" "$(verbs "$CALLS_A")"
reset; run 1 start b-od --resume
check "resume on-demand (fakeb): exit 0, resume called" "0 resume" "$RC $(verbs "$CALLS_B")"

# --- a resident on fakea: make sure it runs, then attach
reset; run 1 start a-res
check "resident (fakea): exit 0" 0 "$RC"
check "resident (fakea): list, start-bg, list, attach" "list start-bg list attach" "$(verbs "$CALLS_A")"
reset; run 0 start a-res
check "resident (fakea) without a terminal: exit 0" 0 "$RC"
lacks "resident (fakea) without a terminal: no attach" "$(verbs "$CALLS_A")" attach
contains "resident (fakea) without a terminal: prints the attach command" "$OUT" "attach from a terminal with"
printf 'a-res\tida-9\tstopped\t%s\n' "$D" > "$SESS_A"; : > "$CALLS_A"
run 1 start a-res
check "stopped resident (fakea): woken, not started a second time" "list wake attach" "$(verbs "$CALLS_A")"
printf 'a-res\tida-9\trunning\t%s\n' "$D" > "$SESS_A"; : > "$CALLS_A"
run 1 start a-res
check "running resident (fakea): only attached" "list attach" "$(verbs "$CALLS_A")"

# --- a resident on fakeb: no background mode, no list. Section 6: it runs as on-demand,
# with a line saying so; without a terminal that is refused (exit 2).
reset; run 1 start b-res
check "resident (fakeb) with a terminal: exit 0" 0 "$RC"
contains "resident (fakeb): says the CLI has no background mode" "$OUT" "has no background mode"
check "resident (fakeb): runs as on-demand: list, start-bg (both 3), then new, no attach" "list start-bg new" "$(verbs "$CALLS_B")"
reset; run 0 start b-res
check "resident (fakeb) without a terminal: refused, exit 2" 2 "$RC"
check "resident (fakeb) without a terminal: no new session opened" "list start-bg" "$(verbs "$CALLS_B")"
reset; run 1 start b-res --new --yes
contains "resident --new (fakeb): says it has no background mode" "$OUT" "has no background mode"

# --- up: residents made to run, on-demand skipped, an adapter without background mode skipped
reset; run 0 up --no-wait
check "up: exit 0 with a fakeb resident in the list" 0 "$RC"
contains "up: fakea resident started" "$OUT" "a-res: started in the background"
contains "up: on-demand skipped (fakea)" "$OUT" "a-od: on-demand, not started"
contains "up: fakeb resident skipped with the reason" "$OUT" "b-res: skipped, fakeb has no background mode"
lacks "up: never wakes or opens a session on fakeb" "$(verbs "$CALLS_B")" new
lacks "up: never calls wake on fakeb" "$(verbs "$CALLS_B")" wake
run 0 up --no-wait
check "up twice: fakea resident not started a second time" 1 "$(grep -c '^start-bg' "$CALLS_A")"

# --- list/status: an adapter that cannot list gives state unknown, never an error
reset; run 0 list
check "list: exit 0" 0 "$RC"
contains "list: fakeb resident is unknown (no list)" "$OUT" "unknown"
lacks "list: no listing failure is reported for fakeb (exit 3 is not an error)" "$OUT" "could not be listed"
reset; run 0 list --json
contains "list --json: fakeb state unknown" "$OUT" '"name":"b-res","kind":"resident","cli":"fakeb","folder":".","state":"unknown"'
contains "list --json: fakea state none" "$OUT" '"name":"a-res","kind":"resident","cli":"fakea","folder":".","state":"none"'
printf 'a-res\tida-1\trunning\t%s\n' "$D" > "$SESS_A"; : > "$CALLS_B"
run 0 list --json
contains "list --json: fakea running with its id" "$OUT" '"state":"running","id":"ida-1"'
check "list: asked fakeb to list once per run" 1 "$(grep -c '^list' "$CALLS_B")"

# --- stop and logs: with the verb, done; without it, exit 3 and a plain line
reset; printf 'a-res\tida-1\trunning\t%s\n' "$D" > "$SESS_A"
run 0 stop a-res
check "stop (fakea): exit 0" 0 "$RC"
check "stop (fakea): the session is stopped" stopped "$(cut -f3 "$SESS_A")"
run 0 logs a-res
check "logs (fakea): exit 0" 0 "$RC"
contains "logs (fakea): prints the adapter's output" "$OUT" "fakea log of a-res"
reset; run 0 stop b-res
check "stop (fakeb, no stop): exit 3" 3 "$RC"
contains "stop (fakeb): says it cannot" "$OUT" "cannot stop its sessions"
check "stop (fakeb): asked once" "stop|b-res $D --" "$(calls "$CALLS_B")"
reset; run 0 logs b-od
check "logs (fakeb, no logs): exit 3" 3 "$RC"
contains "logs (fakeb): says so" "$OUT" "logs not supported"

# --- attach on a CLI whose attach is unsupported is covered by agents_test.sh; here `supports`:
# the contract has the verb, agents reads exit 3, not `supports`. Assert the behaviour that
# matters (an unsupported verb is asked at most once per command and handled), and record that
# `supports` itself is not consulted.
reset; run 1 start b-res; run 0 up --no-wait; run 0 stop b-res; run 0 logs b-res
check "unsupported verbs are asked once per command (fakeb start-bg: start, up)" 2 "$(grep -c '^start-bg' "$CALLS_B")"
# supports is for `agents check` only; no verb consults it (it is not logged by the fakes, which answer it first)
reset; run 1 start b-res; run 0 up --no-wait; run 0 stop b-res; run 0 logs b-res
check "unsupported verbs are still decided by exit 3, not by supports" 2 "$(grep -c '^start-bg' "$CALLS_B")"

# --- check, with `supports` missing or failing: said in the same line, check carries on (exit 0)
  # shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[ "$1" = supports ] && { echo boom >&2; exit 1; }\nexit 0\n' > "$bin/agent-adapter-fakeerr"; chmod +x "$bin/agent-adapter-fakeerr"
printf 'agents:\n  - name: e\n    cli: fakeerr\n    kind: on-demand\n  - name: n\n    cli: nosuch\n    kind: on-demand\n  - name: a\n    cli: fakea\n    kind: on-demand\n' > "$repo/.devcontainer/agents.yml"
run 0 check
check "check: a failing supports and a missing adapter do not fail check" 0 "$RC"
contains "check: a failing supports is said on its CLI's line" "$OUT" "  fakeerr: supports failed (exit 1)"
contains "check: a missing adapter is said on its CLI's line" "$OUT" "  nosuch: no adapter"
contains "check: carries on to the next CLI" "$OUT" "  fakea: start-bg"
rm -f "$bin/agent-adapter-fakeerr"

# --- supports agrees with the verbs
VERBS="start-bg wake attach resume new list stop logs hint record session-busy session-stop session-remove"
# agreement <adapter>: prints the disagreements, nothing when `supports` and the verbs agree
agreement() {
  local ad="$1" sup v rc bad=''
  sup="$("$ad" supports </dev/null 2>/dev/null)"
  for v in $VERBS; do
    if [ "$v" = list ] || [ "$v" = session-busy ] || [ "$v" = session-stop ] || [ "$v" = session-remove ]; then
      timeout 20 "$ad" "$v" x </dev/null >/dev/null 2>&1; rc=$?
    else
      timeout 20 "$ad" "$v" x "$repo" -- </dev/null >/dev/null 2>&1; rc=$?
    fi
    if printf '%s\n' "$sup" | grep -qx "$v"; then
      [ "$rc" -ne 3 ] || bad="$bad $v(listed, answers 3)"
    else
      [ "$rc" -eq 3 ] || bad="$bad $v(not listed, answers $rc)"
    fi
  done
  printf '%s' "$bad"
}
reset
check "supports agrees with the verbs: fakea" "" "$(agreement "$bin/agent-adapter-fakea")"
check "supports agrees with the verbs: fakeb" "" "$(agreement "$bin/agent-adapter-fakeb")"
contains "supports disagreeing with a verb is caught (fakec lists stop, stop answers 3)" "$(agreement "$bin/agent-adapter-fakec")" "stop(listed, answers 3)"
contains "supports disagreeing with a verb is caught (fakec answers logs without listing it)" "$(agreement "$bin/agent-adapter-fakec")" "logs(not listed, answers 0)"

# the real agent-adapter-claude, with a fake claude that starts nothing (an empty session list)
real_adapter="$root/src/claude-code/agent-adapter-claude.sh"
if [ -f "$real_adapter" ]; then
  rbin="$T/realbin"; mkdir -p "$rbin" "$T/claude-config"
  cp "$real_adapter" "$rbin/agent-adapter-claude"; chmod +x "$rbin/agent-adapter-claude"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[ "$1" = agents ] && { echo "[]"; exit 0; }\nexit 1\n' > "$rbin/claude"; chmod +x "$rbin/claude"
  got="$(PATH="$rbin:$PATH" CLAUDE_CONFIG_DIR="$T/claude-config" agreement "$rbin/agent-adapter-claude")"
  check "supports agrees with the verbs: the real agent-adapter-claude (fake claude)" "" "$got"
fi

# --- nothing is Claude-specific
cat > "$repo/.devcontainer/agents.yml" <<'YAML'
agents:
  - name: b1
    cli: fakeb
    kind: on-demand
  - name: b2
    cli: fakeb
    kind: resident
YAML
reset
run 0 check; run 0 list; run 0 list --json; run 1 start b1; run 1 start b1 --resume; run 1 start b2
run 0 start b2; run 0 up; run 0 stop b2; run 0 logs b2; run 0 reset --all --yes
check "a list using only fakeb never runs anything named claude" "" "$(calls "$CALLS_CLAUDE")"
check "a list using only fakeb never touches fakea" "" "$(calls "$CALLS_A")"
# a missing adapter is named by cli, with no special case
printf 'agents:\n  - name: z\n    cli: nosuch\n    kind: on-demand\n' > "$repo/.devcontainer/agents.yml"
run 1 start z
check "unknown cli: exit 1" 1 "$RC"
contains "unknown cli: names agent-adapter-nosuch" "$OUT" "agent-adapter-nosuch"
lacks "unknown cli: does not suggest the claude Feature" "$OUT" "claude-code"

# Static: every non-comment line of src/agents naming claude must be one of the documented
# places in the code (agents.sh, install.sh; descriptions in the JSON and Taskfile are prose) (the Feature hint for the claude cli, the Claude Code session guard in reset).
hits="$(grep -rniE 'claude' "$src_dir/agents.sh" "$src_dir/install.sh" 2>/dev/null |
  grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
  grep -vE "claude\) echo 'the claude-code Feature" |
  grep -vE 'CLAUDE_CODE_CHILD_SESSION' || true)"
check "src/agents names claude only in the documented places" "" "$hits"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
