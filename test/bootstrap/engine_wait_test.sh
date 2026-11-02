#!/usr/bin/env bash
# Docker-free tests of the engine wait in the bash twin (src/devcontainer-cli/devcontainer-cli.sh),
# the counterpart of the Pester tests 'The container engine wait' in DevcontainerCli.Tests.ps1:
# before up, build, exec, set-up and run-user-commands the launcher checks that the engine answers
# (one check when it does: `docker info`, or `ps -q` for an engine that is not docker or podman),
# else prints "waiting for the container engine to answer..." once and checks every second for
# DEVCONTAINER_ENGINE_WAIT seconds (default 60; 0 = no wait), then fails naming the engine, its own
# error and how to start it, without running the CLI; a failed up or build asks the engine once
# more and prints what it says. A stub engine counts its calls and fails while told to; a stub
# `devcontainer` records that it ran. Part of `task lint` (`task test:engine-wait`). CLI_SH points
# the tests at another copy of the script (used to show a test fails when the code it covers is
# broken).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
cli_sh="${CLI_SH:-$here/../../src/devcontainer-cli/devcontainer-cli.sh}"
bash_bin="$(command -v bash)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }

bin="$T/bin"; mkdir -p "$bin" "$T/cache" "$T/ws/.devcontainer"
echo '{ "name": "plain" }' > "$T/ws/.devcontainer/devcontainer.json"
for tool in uname grep cat dirname mkdir id awk tr sed env sleep touch rm; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
echo 'Linux version 6.1.0 (builder@host) (gcc) #1 SMP' > "$T/proc-linux"
# The engine: every call is a line in $T/engine-calls; it fails (as a stopped daemon does, the
# message on stderr) for the first STUB_FAILS calls, and always while $T/down exists.
# shellcheck disable=SC2016  # the stub's own variables
engine='#!/bin/sh
echo "$*" >> "$T_DIR/engine-calls"
n=$(grep -c . "$T_DIR/engine-calls")
if [ -e "$T_DIR/down" ] || [ "$n" -le "${STUB_FAILS:-0}" ]; then
  echo "Client: ok"
  echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" >&2
  exit 1
fi
echo "Server: ok"
'
printf '%s' "$engine" > "$bin/docker"; printf '%s' "$engine" > "$bin/wslc"
# The CLI: records that it ran; STUB_CLI_FAIL=1 makes the engine fall over during it and fails.
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$1" >> "$T_DIR/cli-calls"\nif [ "${STUB_CLI_FAIL:-}" = 1 ]; then [ "${STUB_STAYS_DOWN:-}" = 1 ] && touch "$T_DIR/down"; echo "Error: Command failed: docker ps -q -a --filter label=devcontainer.local_folder=x" >&2; exit 1; fi\nexit 0\n' > "$bin/devcontainer"
chmod +x "$bin/docker" "$bin/wslc" "$bin/devcontainer"

# run [VAR=value ...] -- <subcommand> [args]: out = stdout+stderr, rc, calls = engine calls (|-joined), cli = CLI runs.
run() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rm -f "$T/engine-calls" "$T/cli-calls" "$T/down"
  touch "$T/engine-calls"
  rc=0
  out="$(env -i PATH="$bin" HOME="$T/home" XDG_CACHE_HOME="$T/cache" DCF_HOST_UNAME=Linux DCF_HOST_PROC_VERSION="$T/proc-linux" \
    HOST_MOUNTS=false DEVCONTAINER_BUILD_LOCK=0 T_DIR="$T" "${envs[@]}" "$bash_bin" "$cli_sh" run "$1" --workspace-folder "$T/ws" "${@:2}" 2>&1)" || rc=$?
  calls="$(paste -sd'|' "$T/engine-calls" 2>/dev/null || tr '\n' '|' < "$T/engine-calls")"
  cli="$(cat "$T/cli-calls" 2>/dev/null)"
}

# --- the healthy path: one check, nothing printed
run -- up
check 'healthy: up runs' 0 "$rc"
check 'healthy: one check, docker info' 'info' "$calls"
check 'healthy: no waiting line' 0 "$(grep -c 'waiting for the container engine' <<<"$out")"
check 'healthy: the CLI ran' 'up' "$cli"

# --- an engine that answers on the third check
run STUB_FAILS=2 -- up
check 'late engine: up runs' 0 "$rc"
check 'late engine: three checks' 'info|info|info' "$calls"
check 'late engine: one waiting line' 1 "$(grep -c '^waiting for the container engine to answer\.\.\.$' <<<"$out")"
check 'late engine: the CLI ran after it answered' 'up' "$cli"

# --- an engine that never answers
run STUB_FAILS=99 DEVCONTAINER_ENGINE_WAIT=2 -- up
check 'no engine: fails' 1 "$rc"
check 'no engine: the CLI never ran' '' "$cli"
check 'no engine: one check, then one a second for 2 s, then one for its error' 'info|info|info|info' "$calls"
contains 'no engine: names the engine and the wait' "$out" "the container engine (docker) did not answer within 2 s (docker info)"
contains 'no engine: the engine own error' "$out" 'Cannot connect to the Docker daemon'
contains 'no engine: how to start it (linux)' "$out" 'sudo systemctl start docker'
contains 'no engine: names the setting' "$out" 'DEVCONTAINER_ENGINE_WAIT'
check 'no engine: no client chatter from stdout' 0 "$(grep -c 'Client: ok' <<<"$out")"

run STUB_FAILS=99 DEVCONTAINER_ENGINE_WAIT=1 DCF_HOST_UNAME=Darwin -- up
contains 'no engine on macos: start Docker Desktop' "$out" 'Start Docker Desktop'

# --- DEVCONTAINER_ENGINE_WAIT=0 and a bad value
run STUB_FAILS=99 DEVCONTAINER_ENGINE_WAIT=0 -- up
check 'DEVCONTAINER_ENGINE_WAIT=0: no check at all' '' "$calls"
check 'DEVCONTAINER_ENGINE_WAIT=0: the CLI runs' 'up' "$cli"
run DEVCONTAINER_ENGINE_WAIT=soon -- up
check 'DEVCONTAINER_ENGINE_WAIT=soon: refused' 1 "$rc"
contains 'DEVCONTAINER_ENGINE_WAIT=soon: names the setting and the value' "$out" "DEVCONTAINER_ENGINE_WAIT must be a whole number of seconds (0 = no wait), not 'soon'"
check 'DEVCONTAINER_ENGINE_WAIT=soon: the CLI never ran' '' "$cli"

# --- which subcommands wait
for sub in build exec set-up run-user-commands; do
  run -- "$sub"
  check "$sub: checks the engine" 'info' "$calls"
done
for sub in read-configuration features outdated; do
  run -- "$sub"
  check "$sub: needs no engine, no check" '' "$calls"
done

# --- another engine is asked ps -q
run DEVCONTAINER_DOCKER_PATH=wslc -- up
check 'wslc engine: asked ps -q' 'ps -q' "$calls"

# --- a failed up asks the engine again and says what it says
run STUB_CLI_FAIL=1 STUB_STAYS_DOWN=1 -- up
check 'failed up, engine down: the exit code is passed on' 1 "$rc"
contains 'failed up, engine down: says it does not answer' "$out" 'the container engine (docker) does not answer (docker info): Cannot connect to the Docker daemon'
contains 'failed up, engine down: how to start it' "$out" 'sudo systemctl start docker'
run STUB_CLI_FAIL=1 -- up
contains 'failed up, engine answers: says so and to run again' "$out" 'the container engine (docker) answers now (docker info)'
contains 'failed up, engine answers: run the task again' "$out" 'run the task again'
run STUB_CLI_FAIL=1 -- exec
check 'failed exec: no extra engine diagnosis (exec explains itself)' 0 "$(grep -c 'answers now\|does not answer' <<<"$out")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
