#!/usr/bin/env bash
# Docker-free tests of the agents Feature's 2.0 keys and lease (docs/proposals/agents-v2.md
# sections 4 to 6, 8 and 10): lifecycle, identity, lease and definition parsed, checked and
# shown; a 1.x list read as 2.0 decided (every agent stateful, an exclusive lease); concurrent
# starts of one stateful agent giving exactly one copy (resident: one start, the rest join;
# on-demand: one opens, the rest are refused; up racing start); a dead holder's lease taken
# over, one case per liveness rule, and never a live one; eight takers of one dead lease giving
# one winner and one "stale" line; interleavings paused at a chosen step (AGENTS_LEASE_PAUSE); an ephemeral agent taking no lease; release by stop, by the foreground wrapper's
# exit and its SIGTERM, and by `agents release` (--force for a live holder); `leases` and the
# list's LEASE column. A fake adapter keeps sessions in a file, records every call and can be
# slowed down. Part of `task lint` (`task test:agents-lease`). AGENTS_SH points at another copy.
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
# The fake adapter: sessions in $FAKE_SESSIONS (name<TAB>id<TAB>state<TAB>folder, newest first),
# every call but list in $FAKE_CALLS as "verb|name"; FAKE_SLOW seconds of sleep in start-bg and
# new (a slow start, a session that lasts); FAKE_UNSUPPORTED verbs answer 3; FAKE_LIST_ERR fails list;
# FAKE_WAKE_NEW=1 makes wake start a fresh session id-<name>-new (the old one gone) and print its
# id, FAKE_WAKE_NEW=quiet the same without printing it.
cat > "$bin/agent-adapter-fake" <<'FAKE'
#!/usr/bin/env bash
verb="$1"; shift
case " ${FAKE_UNSUPPORTED:-} " in *" $verb "*) exit 3 ;; esac
if [ "$verb" = list ]; then
  [ -z "${FAKE_LIST_ERR:-}" ] || { echo "agent-adapter-fake: $FAKE_LIST_ERR" >&2; exit 1; }
  cat "$FAKE_SESSIONS" 2>/dev/null; exit 0
fi
[ "$verb" = hint ] && exit 3
name="$1" folder="$2"
echo "$verb|$name" >> "$FAKE_CALLS"
case "$verb" in
  start-bg) sleep "${FAKE_SLOW:-0}"
    n=$(( $(grep -c . "$FAKE_SESSIONS" 2>/dev/null) + 1 ))
    { printf '%s\tid-%s-%s\trunning\t%s\n' "$name" "$name" "$n" "$folder"; cat "$FAKE_SESSIONS" 2>/dev/null; } > "$FAKE_SESSIONS.new"
    mv "$FAKE_SESSIONS.new" "$FAKE_SESSIONS"; echo "id-$name-$n" ;;
  new | resume) sleep "${FAKE_SLOW:-0}" ;;
  wake)
    if [ -n "${FAKE_WAKE_NEW:-}" ]; then # the session is gone: a fresh one under a new id, the old stays failed
      { printf '%s\tid-%s-new\trunning\t%s\n' "$name" "$name" "$folder"; cat "$FAKE_SESSIONS"; } > "$FAKE_SESSIONS.new"
      mv "$FAKE_SESSIONS.new" "$FAKE_SESSIONS"; [ "$FAKE_WAKE_NEW" = quiet ] || echo "id-$name-new"
    else sed -i "s/^\($name\t[^\t]*\t\)\(stopped\|failed\)\t/\1running\t/" "$FAKE_SESSIONS"; fi ;;
  stop) sed -i "s/^\($name\t[^\t]*\t\)running\t/\1stopped\t/" "$FAKE_SESSIONS" ;;
esac
exit 0
FAKE
chmod +x "$bin/agent-adapter-fake"

repo="$T/repo"; mkdir -p "$repo/.devcontainer"
S="$T/state"; L="$S/leases"
export FAKE_SESSIONS="$T/sessions" FAKE_CALLS="$T/calls" AGENTS_STATE_DIR="$S" AGENTS_START_ID=start-1
export AGENTS_SETTLE_INTERVAL=0 AGENTS_SETTLE_TIMEOUT=0 AGENTS_LEASE_WAIT=20
unset AGENTS_FILE AGENTS_FILE_TASK_VAR AGENTS_TTY CLAUDE_CODE_CHILD_SESSION
write_list() { cat > "$repo/.devcontainer/agents.yml"; }
reset() { : > "$T/sessions"; : > "$T/calls"; rm -rf "$S" "$T/out"; mkdir -p "$T/out"; unset FAKE_UNSUPPORTED FAKE_LIST_ERR FAKE_SLOW FAKE_WAKE_NEW; }
run() { (cd "$repo" && PATH="$bin:$PATH" agents "$@" 2>&1); }
count() { grep -c "^$1|" "$T/calls"; }
here_host="$(cat /proc/sys/kernel/hostname 2>/dev/null || uname -n)"
pstart() { sed 's/.*) //' "/proc/$1/stat" | awk '{ print $20 }'; }
fmt() { date -d "@$1" +%H:%M:%S 2>/dev/null || printf '%s' "$1"; }
sh -c 'exit 0' & deadpid=$!; wait "$deadpid"
# holder <name> [key=value...]: a lease written by hand (defaults: held, a dead pid, this container)
holder() {
  local h="$1" k; shift
  declare -A v=([state]=held [pid]="$deadpid" [pidstart]=1 [boot]=start-1 [container]="$here_host" [carrier]=session:id-old [time]="$(date +%s)")
  for k in "$@"; do v[${k%%=*}]="${k#*=}"; done
  mkdir -p "$L/$h"
  printf 'state=%s\npid=%s\npidstart=%s\nboot=%s\ncontainer=%s\ncarrier=%s\ntime=%s\n' \
    "${v[state]}" "${v[pid]}" "${v[pidstart]}" "${v[boot]}" "${v[container]}" "${v[carrier]}" "${v[time]}" > "$L/$h/holder"
}

# ------------------------------------------------------------ the list format ----
write_list <<'YAML'
agents:
  - name: tooling
    cli: fake
    definition: tooling
    lifecycle: stateful
    kind: resident
    identity: tooling
    lease: container
  - name: tooling-night
    cli: fake
    definition: tooling
    lifecycle: ephemeral
    kind: on-demand
    identity: tooling
  - name: old
    cli: fake
    kind: on-demand
    args: [--agent, old]
YAML
out="$(run check)"; rc=$?
check 'format: the new keys are read (exit 0)' 0 "$rc"
contains 'format: a stateful entry shows definition, lifecycle, identity and lease' "$out" \
  'tooling: cli fake, definition tooling, resident, stateful (identity tooling, lease container), folder ., args: none'
contains 'format: an ephemeral entry defaults to lease none and may share a stateful identity' "$out" \
  'tooling-night: cli fake, definition tooling, on-demand, ephemeral (identity tooling, lease none)'
contains 'format: a 1.x entry is stateful with a container lease, identity its name, --agent in args still legal' "$out" \
  'old: cli fake, on-demand, stateful (identity old, lease container), folder ., args: [--agent] [old]'
lacks 'format: the new keys are no longer unknown' "$out" 'unknown key'
out="$(run list --json)"
contains 'format: list --json gains lifecycle, identity, lease and carrier' "$out" \
  '"lifecycle":"ephemeral","identity":"tooling","lease":"none","carrier":"none"'

bad() { # <name> <expected text> : the list on stdin is refused with exit 2
  write_list
  local o r; o="$(run check)"; r=$?
  check "refused: $1 (exit 2)" 2 "$r"
  contains "refused: $1 (message)" "$o" "$2"
}
e='agents:\n  - name: a\n    cli: fake\n'
printf '%b' "${e}    kind: on-demand\n    lifecycle: forever\n" | bad 'an unknown lifecycle' "lifecycle 'forever' is neither stateful nor ephemeral"
printf '%b' "${e}    kind: resident\n    lifecycle: ephemeral\n" | bad 'ephemeral with resident' 'an ephemeral agent cannot be resident'
printf '%b' "${e}    kind: on-demand\n    lease: none\n" | bad 'a stateful agent without a lease' 'a stateful agent always holds its lease'
printf '%b' "${e}    kind: on-demand\n    lifecycle: ephemeral\n    lease: container\n" | bad 'an ephemeral agent with a lease' 'an ephemeral agent takes no lease'
printf '%b' "${e}    kind: on-demand\n    lease: machine\n" | bad 'lease machine (reserved)' "lease 'machine' is not supported"
printf '%b' "${e}    kind: on-demand\n    lease: cluster\n" | bad 'lease cluster (reserved)' "lease 'cluster' is not supported"
printf '%b' "${e}    kind: on-demand\n    lease: forever\n" | bad 'an unknown lease' "lease 'forever' is neither container nor none"
printf '%b' "${e}    kind: on-demand\n    lease: { scope: container }\n" | bad 'an inline map for lease, pointing at the flat form' 'agents.yml:5: lease is one word, not a map: lease: container'
printf '%b' "${e}    kind: on-demand\n    identity: a b\n" | bad 'an identity with a space' "identity 'a b' may hold only"
printf '%b' "${e}    kind: on-demand\n    definition: a/b\n" | bad 'a definition with a slash' "definition 'a/b' may hold only"
printf '%b' "${e}    kind: on-demand\n    definition: a\n    args: [--model, x, --agent=a]\n" | bad 'definition and --agent in args' 'name the profile twice'
printf '%b' "${e}    kind: on-demand\n    identity: p\n  - name: b\n    cli: fake\n    kind: resident\n    identity: p\n" |
  bad 'two stateful agents with one identity' "identity 'p' is already the identity of the stateful agent 'a' (entry 1)"
printf '%b' "${e}    kind: on-demand\n    lifecycle: ephemeral\n    identity: p\n  - name: b\n    cli: fake\n    kind: on-demand\n    lifecycle: ephemeral\n    identity: p\n" > "$repo/.devcontainer/agents.yml"
out="$(run check)"; rc=$?
check 'format: two ephemeral agents may share an identity' 0 "$rc"

# --------------------------------------------- a 1.x list, as 2.0 decided ----
write_list <<'YAML'
agents:
  - name: host
    cli: fake
    kind: resident
  - name: pair
    cli: fake
    kind: on-demand
  - name: crowd
    cli: fake
    kind: on-demand
    lifecycle: ephemeral
YAML
reset
out="$(AGENTS_TTY=0 run start host)"; rc=$?
check '1.x list: a resident start takes its lease' "0:held" "$rc:$(sed -n 's/^state=//p' "$L/host/holder" 2>/dev/null)"
check '1.x list: the lease names the session as carrier' carrier=session:id-host-1 "$(grep '^carrier=' "$L/host/holder" 2>/dev/null)"
out="$(run list)"
contains 'list: the LEASE column shows the holder' "$out" \
  "$(printf '%-16s %-10s %-10s %-8s %-9s %-24s %-38s %s' host resident stateful fake running 'held session:id-host-1' id-host-1 .)"
contains 'list: an ephemeral agent has no lease' "$out" "$(printf '%-16s %-10s %-10s %-8s %-9s %-24s' crowd on-demand ephemeral fake none -)"
out="$(run list --json)"
contains 'list --json: lease held and its carrier' "$out" '"identity":"host","lease":"held","carrier":"session:id-host-1"'
out="$(run leases)"
contains 'leases: a table' "$out" 'HANDLE'
contains 'leases: the resident, held by its session, its starter exited' "$out" "$(printf '%-16s %-10s %-24s' host held session:id-host-1)"
contains 'leases: the holder in words' "$out" '(exited), this container'
out="$(run leases --json)"
contains 'leases --json' "$out" '[{"handle":"host","state":"held","carrier":"session:id-host-1"'
: > "$T/calls"
out="$(AGENTS_TTY=0 run start host)"; rc=$?
check 'a second resident start joins: exit 0, nothing started' "0:0" "$rc:$(count start-bg)"
contains 'a second resident start joins: says it runs' "$out" 'host: running (id-host-1)'
out="$(run up --no-wait)"; rc=$?
check 'up on a held lease joins silently: exit 0, nothing started' "0:0" "$rc:$(count start-bg)"
contains 'up on a held lease: one line' "$out" 'host: running (id-host-1)'
: > "$T/calls"
out="$(AGENTS_TTY=1 run start host)"
check 'a second resident start with a terminal: attach only' "attach|host" "$(tr '\n' ';' < "$T/calls" | sed 's/;$//')"

# ------------------------------------------------ concurrent starts: one copy ----
reset; export FAKE_SLOW=1
for k in 1 2 3 4 5 6 7 8; do (AGENTS_TTY=0 run start host > "$T/out/$k"; echo $? >> "$T/out/rc") & done; wait
check 'eight concurrent resident starts: exactly one start-bg' 1 "$(count start-bg)"
check 'eight concurrent resident starts: one running session' 1 "$(grep -c running "$T/sessions")"
check 'eight concurrent resident starts: every one exits 0' 0 "$(sort -u "$T/out/rc" | tr -d '\n')"
check 'eight concurrent resident starts: one started it' 1 "$(cat "$T/out"/[0-9] | grep -c 'started in the background')"
check 'eight concurrent resident starts: seven joined' 7 "$(cat "$T/out"/[0-9] | grep -c 'host: running (id-host-1)')"
reset; export FAKE_SLOW=1
(run up --no-wait > "$T/out/up") & (AGENTS_TTY=0 run start host > "$T/out/start") & (run up --no-wait > "$T/out/up2") & wait
check 'up racing start: exactly one start-bg' 1 "$(count start-bg)"
reset; export FAKE_SLOW=3
for k in 1 2 3 4 5 6 7 8; do (AGENTS_TTY=1 run start pair > "$T/out/$k"; echo $? >> "$T/out/rc") & done; wait
check 'eight concurrent on-demand starts: exactly one opens a session' 1 "$(count new)"
check 'eight concurrent on-demand starts: seven refused (exit 2)' 7 "$(grep -c '^2$' "$T/out/rc")"
contains 'on-demand refused: says it is stateful and held, and the way out' "$(cat "$T/out"/[0-9])" \
  'pair is a stateful agent and already runs: its lease is held by process:'
contains 'on-demand refused: names release and ephemeral' "$(cat "$T/out"/[0-9])" 'task agents:release -- pair frees the lease (--force for a live holder). To run several at once, make it lifecycle: ephemeral.'
check 'the foreground wrapper released the lease when the session ended' no "$([ -d "$L/pair" ] && echo yes || echo no)"

# ------------------------------------------------ an ephemeral agent: no lease ----
reset; export FAKE_SLOW=2
(AGENTS_TTY=1 run start crowd > "$T/out/1"; echo $? >> "$T/out/rc") & (AGENTS_TTY=1 run start crowd > "$T/out/2"; echo $? >> "$T/out/rc") &
sleep 1
check 'ephemeral: no lease folder while it runs' no "$([ -d "$L/crowd" ] && echo yes || echo no)"
wait
check 'ephemeral: two starts side by side both open a session' 2 "$(count new)"
check 'ephemeral: both exit 0' 0 "$(sort -u "$T/out/rc" | tr -d '\n')"
out="$(AGENTS_TTY=1 run start crowd --resume)"; rc=$?
check 'ephemeral --resume: refused (exit 2)' 2 "$rc"
contains 'ephemeral --resume: says why' "$out" 'nothing of it is kept'

# ---------------------------------------------- release: stop, wrapper, verb ----
reset
AGENTS_TTY=0 run start host >/dev/null
out="$(run stop host)"; rc=$?
check 'stop releases the lease' "0:no" "$rc:$([ -d "$L/host" ] && echo yes || echo no)"
reset
AGENTS_TTY=0 run start host >/dev/null
out="$(run stop host --extras)"
check 'stop --extras keeps the lease (the agent still runs)' yes "$([ -d "$L/host" ] && echo yes || echo no)"
reset; export FAKE_SLOW=1
out="$(AGENTS_TTY=1 run start pair)"; rc=$?
check 'the foreground wrapper: exit 0, the lease gone after the session' "0:no" "$rc:$([ -d "$L/pair" ] && echo yes || echo no)"
reset; export FAKE_SLOW=2
(cd "$repo" && AGENTS_TTY=1 PATH="$bin:$PATH" exec agents start pair > "$T/out/term" 2>&1) & wp=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$L/pair/holder" ] && grep -q '^state=held' "$L/pair/holder" && break; sleep 0.2; done
check 'SIGTERM: the wrapper held the lease while the session ran' yes "$([ -d "$L/pair" ] && echo yes || echo no)"
kill -TERM "$wp"; wait "$wp"; rc=$?
check 'SIGTERM: the wrapper released the lease on its way out (exit 143)' "143:no" "$rc:$([ -d "$L/pair" ] && echo yes || echo no)"
reset; sleep 30 & live=$!
holder pair state=held pid="$live" pidstart="$(pstart "$live")" carrier="process:$live"
out="$(run release pair)"; rc=$?
check 'release of a live holder: refused (exit 2)' "2:yes" "$rc:$([ -d "$L/pair" ] && echo yes || echo no)"
contains 'release of a live holder: says how' "$out" 'Add --force if you know it does not run'
out="$(run release pair --force)"; rc=$?
check 'release --force: released' "0:no" "$rc:$([ -d "$L/pair" ] && echo yes || echo no)"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
holder pair state=held carrier="process:$deadpid"
out="$(run release pair)"; rc=$?
check 'release of a dead holder: released without --force' "0:no" "$rc:$([ -d "$L/pair" ] && echo yes || echo no)"
contains 'release of a dead holder: says why' "$out" 'its holder was gone: session-gone'
out="$(run release pair)"; rc=$?
check 'release with no lease: exit 0, says so' "0" "$rc"
contains 'release with no lease: one line' "$out" 'holds no lease'
out="$(run leases)"
contains 'leases: none held' "$out" 'no lease is held'

# ------------------------------------------- a dead holder: one case per rule ----
takeover() { # <case> <holder args...>: the next start of host takes the lease over
  local c="$1"; shift
  reset; holder host "$@"
  out="$(AGENTS_TTY=0 run start host)"; rc=$?
  check "takeover ($c): exit 0, exactly one new session" "0:1" "$rc:$(count start-bg)"
  contains "takeover ($c): says it was stale and why" "$out" "host: its lease was stale ($c"
  check "takeover ($c): the new holder is this start's session" carrier=session:id-host-1 "$(grep '^carrier=' "$L/host/holder" 2>/dev/null)"
  lacks "takeover ($c): no stale folder or lock left" "$(ls -a "$L")" 'host.'
}
takeover new-container boot=start-0
takeover new-container container=another-container
takeover start-died state=starting carrier=pending
sleep 30 & reused=$!
takeover start-died state=starting pid="$reused" pidstart=1
takeover session-gone state=held
reset; mkdir -p "$L/host"; touch -d "@$(($(date +%s) - 10))" "$L/host"
out="$(AGENTS_TTY=0 run start host)"
check 'takeover (no-holder): a folder without a holder, older than 5 s, is taken over' 1 "$(count start-bg)"
contains 'takeover (no-holder): says so' "$out" '(no-holder'
reset; holder host state=held; printf 'host\tid-old\tstopped\t%s\n' "$repo" > "$T/sessions"
out="$(AGENTS_TTY=0 run start host)"
check 'takeover of a stopped resident wakes it (no second session)' "1:0" "$(count wake):$(count start-bg)"
reset; holder host state=held; printf 'host\tid-old\trunning\t%s\n' "$repo" > "$T/sessions"
out="$(AGENTS_TTY=0 run start host)"
check 'held, its starter gone, the session running (also after a /clear: found by name): not taken over' "0:id-old" \
  "$(count start-bg):$(sed -n 's/^carrier=session://p' "$L/host/holder")"
reset; holder host state=held pid="$reused" pidstart="$(pstart "$reused")"
out="$(AGENTS_TTY=0 run start host)"
check 'held by a live pid: never taken over (joined)' "0:$reused" "$(count start-bg):$(sed -n 's/^pid=//p' "$L/host/holder")"
reset; holder pair state=held pid="$reused" pidstart="$(pstart "$reused")" carrier="process:$reused"
out="$(AGENTS_TTY=1 run start pair)"; rc=$?
check 'on-demand, held by a live wrapper: refused, nothing opened' "2:0" "$rc:$(count new)"
reset; holder host state=starting pid="$reused" pidstart="$(pstart "$reused")" carrier=pending
out="$(AGENTS_LEASE_WAIT=1 AGENTS_TTY=0 run start host)"; rc=$?
check 'a start still in progress: waited, then joined (nothing started, exit 0)' "0:0" "$rc:$(count start-bg)"
contains 'a start still in progress: says so' "$out" 'a start of it is in progress'
reset; holder pair state=starting pid="$reused" pidstart="$(pstart "$reused")" carrier=pending
out="$(AGENTS_LEASE_WAIT=1 AGENTS_TTY=1 run start pair)"; rc=$?
check 'on-demand, a start still in progress: waited, then refused' "2:0" "$rc:$(count new)"
kill "$reused" 2>/dev/null; wait "$reused" 2>/dev/null
reset; export FAKE_UNSUPPORTED=list; holder host state=held
out="$(AGENTS_TTY=0 run start host)"; rc=$?
check 'cannot list, holder gone: cannot tell, never taken over' "0:0" "$rc:$(count start-bg)"
contains 'cannot list: says it started earlier in this container start' "$out" 'started earlier in this container start'
out="$(AGENTS_TTY=0 AGENTS_START_ID=start-2 run start host)"
check 'cannot list: the next container start takes it over' 1 "$(count start-bg)"
reset; export FAKE_LIST_ERR='timed out'; holder host state=held
out="$(AGENTS_TTY=0 run start host)"; rc=$?
check 'the listing failed: nothing taken on a guess (exit 1, nothing started, holder kept)' "1:0:held" \
  "$rc:$(count start-bg):$(sed -n 's/^state=//p' "$L/host/holder")"
reset; holder host state=held; mkdir -p "$L/host.takeover"; printf '%s 1\n' "$deadpid" > "$L/host.takeover/pid"
out="$(AGENTS_TTY=0 run start host)"
check 'a takeover lock left by a dead taker does not block' 1 "$(count start-bg)"
reset; export FAKE_SLOW=1; holder host state=held boot=start-0
for k in 1 2 3 4 5 6 7 8; do (AGENTS_TTY=0 run start host > "$T/out/$k"; echo $? >> "$T/out/rc") & done; wait
check 'eight concurrent takers of one dead lease: exactly one new session' 1 "$(count start-bg)"
check 'eight concurrent takers: exactly one reports the stale lease (the one that claimed it)' 1 \
  "$(cat "$T/out"/[0-9] | grep -c 'its lease was stale')"
check 'eight concurrent takers: every one exits 0' 0 "$(sort -u "$T/out/rc" | tr -d '\n')"
unset FAKE_SLOW

# Interleavings made deterministic: with AGENTS_LEASE_PAUSE=<point>, the n-th time a taker gets
# there it appends a line to $AGENTS_LEASE_PAUSE_FILE.at and waits for $AGENTS_LEASE_PAUSE_FILE.go.<n>.
P="$T/pause"
paused() { local n=0; while [ "$(cat "$P.at" 2>/dev/null | grep -c .)" -lt "$1" ] && [ "$n" -lt 400 ]; do sleep 0.05; n=$((n + 1)); done; }
go() { touch "$P.go.$1"; }
go_all() { local n; for n in $(seq 1 99); do go "$n"; done; }
taker() { # <out> [point]: a start of host in the background, paused at point
  (AGENTS_LEASE_PAUSE="${2:-}" AGENTS_LEASE_PAUSE_FILE="$P" AGENTS_TTY=0 run start host > "$T/out/$1"; echo $? >> "$T/out/rc") &
}
stale_lines() { grep -c 'its lease was stale' "$T/out/$1"; }
# A taker holds the takeover lock for longer than 5 s: the others wait for it, never clear it.
reset; rm -f "$P".*; holder host state=held boot=start-0
taker 1 takeover; paused 1; taker 2
sleep 6; go_all; wait
check 'a takeover lock held over 5 s is waited for: one session, every taker exits 0' "1:0" "$(count start-bg):$(sort -u "$T/out/rc" | tr -d '\n')"
check 'a takeover lock held over 5 s: only the lock holder reports the stale lease' "1:0" "$(stale_lines 1):$(stale_lines 2)"
lacks 'a takeover lock held over 5 s: no lock or stray folder left' "$(ls -a "$L")" 'host.'
# A taker stalls between its mkdir and its holder file for longer than 5 s: another takes the
# folder over (no holder, older than 5 s), and the stalled one, finding a holder there, joins.
reset; rm -f "$P".*
taker 1 mkdir; paused 1; touch -d "@$(($(date +%s) - 10))" "$L/host"
AGENTS_TTY=0 run start host > "$T/out/2"; echo $? >> "$T/out/rc"
stalled="$(head -1 "$P.at")"; go_all; wait
check 'a taker stalled after its mkdir: one session, both exit 0' "1:0" "$(count start-bg):$(sort -u "$T/out/rc" | tr -d '\n')"
contains 'a taker stalled after its mkdir: the other took the folder over' "$(cat "$T/out/2")" 'its lease was stale (no-holder'
contains 'a taker stalled after its mkdir: it then joins' "$(cat "$T/out/1")" 'host: running (id-host-1)'
check 'a taker stalled after its mkdir: it never wrote the holder' "session:id-host-1:no" \
  "$(sed -n 's/^carrier=//p' "$L/host/holder"):$(grep -qx "pid=$stalled" "$L/host/holder" && echo yes || echo no)"
# A holder that hands over to its session and exits between a taker's read of it and the look at
# its pid: the pid is gone, but the holder changed, so it is judged again (held), not stale. First
# outside the lock, then (a dead lease another taker has just claimed) inside it.
handover() { # <pause number>: the starting holder writes its session and exits
  printf 'host\tid-host-1\trunning\t%s\n' "$repo" > "$T/sessions"
  holder host state=held pid="$live" pidstart="$(pstart "$live")" carrier=session:id-host-1
  kill "$live"; wait "$live" 2>/dev/null; go "$1"
}
reset; rm -f "$P".*; sleep 30 & live=$!
holder host state=starting pid="$live" pidstart="$(pstart "$live")" carrier=pending
taker 1 verdict; paused 1; handover 1; paused 2; go_all; wait
check 'a holder that handed over and exited (read outside the lock): joined, nothing started, not stale' "0:0:0" \
  "$(sort -u "$T/out/rc" | tr -d '\n'):$(count start-bg):$(stale_lines 1)"
reset; rm -f "$P".*; sleep 30 & live=$!
holder host state=held boot=start-0
taker 1 verdict; paused 1
holder host state=starting pid="$live" pidstart="$(pstart "$live")" carrier=pending; go 1
paused 2; handover 2; paused 3; go_all; wait
check 'a holder that handed over and exited (read under the lock): joined, nothing started, not stale' "0:0:0" \
  "$(sort -u "$T/out/rc" | tr -d '\n'):$(count start-bg):$(stale_lines 1)"
check 'a holder that handed over: its session still holds the lease' carrier=session:id-host-1 "$(grep '^carrier=' "$L/host/holder")"

# ----------------------------- a failed wake started fresh: the carrier follows ----
# after a rebuild the resident's session failed and cannot be woken; the adapter starts it fresh
# under a new id and prints that id. The lease names the session that runs, never the failed one.
for mode in 1 quiet; do
  reset; holder host boot=start-0 carrier=session:id-old; printf 'host\tid-old\tfailed\t%s\n' "$repo" > "$T/sessions"
  out="$(FAKE_WAKE_NEW=$mode run up --no-wait)"; rc=$?
  w='fresh after a failed wake'; [ "$mode" = 1 ] || w="$w (the adapter printed no id)"
  check "$w: woken once, nothing else started (exit 0)" "0:1:0" "$rc:$(count wake):$(count start-bg)"
  check "$w: the carrier is the new session" carrier=session:id-host-new "$(grep '^carrier=' "$L/host/holder" 2>/dev/null)"
  contains "$w: says it runs as a new session" "$out" 'host: running as a new session (id-host-new); id-old was not woken'
  out="$(run list)"
  contains "$w: list: LEASE and ID agree" "$out" \
    "$(printf '%-16s %-10s %-10s %-8s %-9s %-24s %-38s %s' host resident stateful fake running 'held session:id-host-new' id-host-new .)"
  out="$(run leases)"
  contains "$w: leases: held by the new session, its starter (up) exited" "$out" \
    "$(printf '%-16s %-10s %-24s %-9s %s' host held session:id-host-new "$(fmt "$(sed -n 's/^time=//p' "$L/host/holder")")" "pid $(sed -n 's/^pid=//p' "$L/host/holder") (exited), this container")"
done
# liveness: the holder's pid (agents up) is gone, its carrier runs: live, never taken over
: > "$T/calls"
out="$(AGENTS_TTY=0 run start host)"; rc=$?
check 'exited starter, running carrier: joined, nothing woken or started' "0:0:0" "$rc:$(count wake):$(count start-bg)"
contains 'exited starter, running carrier: says it runs (the new session)' "$out" 'host: running (id-host-new)'
out="$(run release host)"; rc=$?
check 'exited starter, running carrier: release refused (a live holder)' "2:yes" "$rc:$([ -d "$L/host" ] && echo yes || echo no)"
contains 'release names the running session, not the failed one' "$out" 'held by session:id-host-new'
out="$(run release host --force)"; rc=$?
contains 'release --force names the running session' "$out" 'lease released (forced; its lease is held by session:id-host-new'

# ------------------------------------------------------ --new on a resident ----
reset; AGENTS_TTY=0 run start host >/dev/null; : > "$T/calls"
out="$(AGENTS_TTY=0 run start host --new --yes)"; rc=$?
check '--new: stops, then starts afresh under a lease taken again (no waiting)' "0:stop|host;start-bg|host" "$rc:$(tr '\n' ';' < "$T/calls" | sed 's/;$//')"
check '--new: the lease names the fresh session' carrier=session:id-host-2 "$(grep '^carrier=' "$L/host/holder" 2>/dev/null)"

# ------------------------------------------------------------- default: true ----
reset
out="$(run)"; rc=$?
check 'no default, no arguments: usage, exit 2' 2 "$rc"
contains 'no default: the usage says how to mark one' "$out" 'default: true'
out="$(run start)"; rc=$?
check 'no default, start without a name: exit 2' 2 "$rc"
write_list <<'YAML'
agents:
  - name: host
    cli: fake
    kind: resident
  - name: pair
    cli: fake
    kind: on-demand
    default: true
YAML
out="$(run check)"
contains 'check names the default agent' "$out" '2 agent(s), default pair'
: > "$T/calls"  # check now asks each CLI adapter `supports` (1.0.3)
out="$(AGENTS_TTY=1 run)"; rc=$?
check 'no arguments: the default agent is started like agents start pair (its lease, a new session)' "0:new|pair" "$rc:$(tr '\n' ';' < "$T/calls" | sed 's/;$//')"
reset; holder pair state=held pid=$$ pidstart="$(pstart $$)" carrier="process:$$"
out="$(AGENTS_TTY=1 run start)"; rc=$?
check 'start without a name: the default, refused like a named start while its lease is held' "2:0" "$rc:$(count new)"
reset
out="$(AGENTS_TTY=1 run start --resume)"; rc=$?
check 'start with only flags: the default with them' "0:resume|pair" "$rc:$(tr '\n' ';' < "$T/calls" | sed 's/;$//')"
out="$(run --help)"; rc=$?
check '--help stays the usage' 0 "$rc"
contains '--help: the usage text' "$out" 'agents start <name>'
printf 'agents:\n  - name: a\n    cli: fake\n    kind: on-demand\n    default: true\n  - name: b\n    cli: fake\n    kind: on-demand\n    default: true\n' |
  bad 'two defaults' "'b' is marked default, and so is 'a' (entry 1)"
printf 'agents:\n  - name: a\n    cli: fake\n    kind: on-demand\n    default: yes\n' | bad 'a default that is not true or false' "default 'yes' is neither true nor false"
write_list <<'YAML'
agents:
  - name: crowd
    cli: fake
    kind: on-demand
    lifecycle: ephemeral
    default: true
YAML
reset; out="$(AGENTS_TTY=1 run)"; rc=$?
check 'an ephemeral default is allowed and takes no lease' "0:new|crowd:no" "$rc:$(tr '\n' ';' < "$T/calls" | sed 's/;$//'):$([ -d "$L/crowd" ] && echo yes || echo no)"
if command -v task >/dev/null 2>&1; then
  mkdir -p "$T/inc"; cp "$root/src/agents/taskfile.yml" "$T/inc/agents.yml"
  printf "version: '3'\nincludes:\n  agents:\n    taskfile: %s/inc/agents.yml\n" "$T" > "$repo/Taskfile.yml"
  reset; out="$(cd "$repo" && AGENTS_TTY=1 PATH="$bin:$PATH" task agents 2>&1)"
  check 'task agents with no arguments starts the default' "new|crowd" "$(tr '\n' ';' < "$T/calls" | sed 's/;$//')"
  rm -f "$repo/Taskfile.yml"
else
  echo "skip - task agents with no arguments (no task on PATH)"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
