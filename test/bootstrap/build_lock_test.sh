#!/usr/bin/env bash
# Docker-free tests of the build lock in the bash twin (src/devcontainer-cli/devcontainer-cli.sh),
# the counterpart of the Pester tests 'The build lock holder and waiter files' and 'The build lock
# skipped with BuildKit build contexts' in DevcontainerCli.Tests.ps1: the holder of the flock
# writes who it is (repository folder, subcommand and flags, start) beside the lock and removes it
# when it ends; a waiter registers, prints "waiting for <repo>'s <subcommand> (started HH:MM, N
# ahead)..." and again when that changes, and leaves no file behind (also when it is stopped); a
# holder file of a dead process is ignored; an engine whose `buildx version` is 0.8.0 or later skips
# the lock with one line, never wslc, and DEVCONTAINER_BUILD_LOCK=1 keeps it, =0 drops it. A stub
# engine answers `info` and, with STUB_BUILDX, `buildx version`; a stub `devcontainer` sleeps
# STUB_SLEEP seconds. Part of `task lint` (`task test:build-lock`). CLI_SH points the tests at
# another copy of the script.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
cli_sh="${CLI_SH:-$here/../../src/devcontainer-cli/devcontainer-cli.sh}"
bash_bin="$(command -v bash)"
command -v flock > /dev/null 2>&1 || { echo 'skip - no flock on this host'; exit 0; }

T="$(mktemp -d)"
trap 'jobs -p | xargs -r kill 2>/dev/null; rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

bin="$T/bin"; mkdir -p "$bin" "$T/cache" "$T/home"
for ws in alpha beta gamma; do mkdir -p "$T/$ws/.devcontainer"; echo '{ "name": "plain" }' > "$T/$ws/.devcontainer/devcontainer.json"; done
for tool in uname grep cat dirname mkdir id awk tr sed env sleep touch rm mv date flock; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
echo 'Linux version 6.1.0 (builder@host) (gcc) #1 SMP' > "$T/proc-linux"
# shellcheck disable=SC2016  # the stub's own variables
engine='#!/bin/sh
if [ "$1 $2" = "buildx version" ]; then
  [ -n "${STUB_BUILDX:-}" ] || { echo "unknown command: buildx" >&2; exit 1; }
  echo "github.com/docker/buildx v$STUB_BUILDX 0123abc"; exit 0
fi
echo "Server: ok"
'
printf '%s' "$engine" > "$bin/docker"; printf '%s' "$engine" > "$bin/wslc"
# shellcheck disable=SC2016
printf '#!/bin/sh\nsleep "${STUB_SLEEP:-0}"\nexit 0\n' > "$bin/devcontainer"
chmod +x "$bin/docker" "$bin/wslc" "$bin/devcontainer"

lock_file="$T/cache/devcontainer-features/build.lock"
state="$T/cache/devcontainer-features/build-lock"
mkdir -p "${lock_file%/*}"

# launch [VAR=value ...] -- <workspace> <subcommand> [args]: runs the launcher (env -i), stdout+stderr to stdout.
launch() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  local ws="$1"; shift
  exec env -i PATH="$bin" HOME="$T/home" XDG_CACHE_HOME="$T/cache" DCF_HOST_UNAME=Linux DCF_HOST_PROC_VERSION="$T/proc-linux" \
    HOST_MOUNTS=false DEVCONTAINER_ENGINE_WAIT=0 "${envs[@]}" "$bash_bin" "$cli_sh" run "$1" --workspace-folder "$T/$ws" "${@:2}" 2>&1
}
# run: launch in the foreground; out, rc.
run() { rc=0; out="$(launch "$@")" || rc=$?; }
# wait_for <test command...>: up to 15 s.
wait_for() { local i=0; until "$@"; do i=$((i + 1)); [ "$i" -lt 150 ] || return 1; sleep 0.1; done; }
lock_held() { ! flock -n "$lock_file" true; }
waiters() { local n=0 f; for f in "$state"/waiter-*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
waiters_are() { [ "$(waiters)" = "$1" ]; }
# hold <seconds>: a plain flock holder (no holder file, as an older launcher).
hold() { flock "$lock_file" sleep "$1" & wait_for lock_held; }

# --- a holder that writes who it is, and a waiter that names it
(launch STUB_SLEEP=3 -- alpha up --remove-existing-container --build-no-cache --config x.json > "$T/a.out") &
a=$!
wait_for test -e "$state/holder"
holder="$(cat "$state/holder")"
contains 'holder file: the repository' "$holder" 'repo=alpha'
contains 'holder file: the subcommand and its flags, no values' "$holder" 'subcommand=up --remove-existing-container --build-no-cache --config'
run -- beta up
wait "$a"
check 'waiter: runs after the holder' 0 "$rc"
check "waiter: names the holder's repository, subcommand and start" 1 \
  "$(grep -cE "^waiting for alpha's up --remove-existing-container --build-no-cache --config \(started [0-9]{2}:[0-9]{2}\)\.\.\.$" <<<"$out")"
check 'waiter: one line while nothing changes' 1 "$(grep -c '^waiting for' <<<"$out")"
check 'holder: no waiting line of its own' 0 "$(grep -c 'waiting for' "$T/a.out")"
check 'after both: no holder file' no "$([ -e "$state/holder" ] && echo yes || echo no)"
check 'after both: no waiter file' 0 "$(waiters)"

# --- a waiter that arrived earlier is counted, and the line changes when the holder does
(launch STUB_SLEEP=3 -- alpha up --build-no-cache > /dev/null) &
a=$!
wait_for test -e "$state/holder"
(launch STUB_SLEEP=1 -- gamma build > "$T/c.out") &
c=$!
wait_for waiters_are 1
sleep 1.1
run -- beta up
wait "$a" "$c"
contains 'second waiter: one ahead' "$out" "waiting for alpha's up --build-no-cache (started "
contains 'second waiter: the count' "$out" ', 1 ahead)...'
case "$out" in
  *"waiting for gamma's build (started "*) check 'second waiter: a new line when the holder changes' 2 "$(grep -c '^waiting for' <<<"$out")" ;;
  *) check 'second waiter: overtook the first (not first-come), one line' 1 "$(grep -c '^waiting for' <<<"$out")" ;;
esac
check 'first waiter: nobody ahead of it' 0 "$(grep -c 'ahead' "$T/c.out")"
check 'after all three: no waiter file' 0 "$(waiters)"

# --- a stale holder file (its process is gone) is ignored
printf 'pid=999999\nrepo=gone\nsubcommand=up\nstarted=0\n' > "$state/holder"
hold 2
run -- beta up
contains 'stale holder: the plain line' "$out" 'waiting for another devcontainer build to finish...'
lacks 'stale holder: never names it' "$out" "gone's"
wait

# --- a waiter stopped while it waits leaves no waiter file
hold 10
holder_pid=$!
(launch -- beta up > /dev/null) &
b=$!
wait_for waiters_are 1
check 'stopped waiter: registered while waiting' 1 "$(waiters)"
kill -TERM "$b" 2> /dev/null
wait "$b" 2> /dev/null
check 'stopped waiter: its file removed' 0 "$(waiters)"
kill "$holder_pid" 2> /dev/null; wait 2> /dev/null

# --- BuildKit build contexts skip the lock; wslc, an old buildx, =1 keep it; =0 drops it
hold 2
start=$SECONDS
run STUB_BUILDX=0.35.0 -- beta up
check 'buildx 0.35.0: runs' 0 "$rc"
check 'buildx 0.35.0: the skip line' 1 "$(grep -cF 'build lock skipped: docker builds with BuildKit build contexts (buildx 0.35.0), so builds of different repositories cannot collide (DEVCONTAINER_BUILD_LOCK=1 keeps it).' <<<"$out")"
lacks 'buildx 0.35.0: no waiting' "$out" 'waiting for'
check 'buildx 0.35.0: did not wait for the holder' 1 "$([ $((SECONDS - start)) -lt 2 ] && echo 1 || echo 0)"
wait

for case_ in 'STUB_BUILDX=0.7.1|buildx 0.7.1' 'STUB_BUILDX=|no buildx' 'DEVCONTAINER_DOCKER_PATH=wslc|wslc' 'DEVCONTAINER_BUILD_LOCK=1|DEVCONTAINER_BUILD_LOCK=1'; do
  setting="${case_%%|*}"; name="${case_#*|}"
  hold 1
  run STUB_BUILDX=0.35.0 "$setting" -- beta up
  check "$name: runs" 0 "$rc"
  lacks "$name: no skip line" "$out" 'build lock skipped'
  contains "$name: waits for the lock" "$out" 'waiting for another devcontainer build to finish...'
  wait
done

hold 1
run STUB_BUILDX=0.35.0 DEVCONTAINER_BUILD_LOCK=0 -- beta up
lacks 'DEVCONTAINER_BUILD_LOCK=0: no skip line' "$out" 'build lock'
lacks 'DEVCONTAINER_BUILD_LOCK=0: no waiting' "$out" 'waiting for'
wait

echo "build lock: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
