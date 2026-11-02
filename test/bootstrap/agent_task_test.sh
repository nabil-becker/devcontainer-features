#!/usr/bin/env bash
# Docker-free test of how `task devcontainer:agent`, `devcontainer:agent:list` and `:agent:reset`
# (bootstrap/devcontainer.yml) hand the agent name, its flags and AGENTS_FILE to the agents
# Feature's `agents` command: inside the container directly, from the host through the exec
# task (--dry shows the command, nothing runs); that from the host with no agent name it refuses
# before the container is started unless the list marks a default (stub devcontainer and docker
# record what runs); and that the deprecated devcontainer:claude and
# devcontainer:claude:fleet still run and print one deprecation line. Fake agents, claude-host
# and claude-fleet commands on PATH record what they get. Needs the real `task` (the lint
# environment has it). YAML_FILE points the test at another copy of devcontainer.yml.
# Part of `task lint` (`task test:agent-task`).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
yml="${YAML_FILE:-$root/bootstrap/devcontainer.yml}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }

mkdir -p "$T/bin" "$T/repo"
for c in agents claude-host claude-fleet; do
  # shellcheck disable=SC2016  # the fake expands these when it runs
  printf '#!/bin/sh\necho "%s $*" > "$REC_OUT/%s"\necho "file=${AGENTS_FILE_TASK_VAR:-}" >> "$REC_OUT/%s"\n' "$c" "$c" "$c" > "$T/bin/$c"
  chmod +x "$T/bin/$c"
done
cat > "$T/repo/Taskfile.yml" <<YAML
version: '3'
includes:
  devcontainer:
    taskfile: '$yml'
    vars:
      SESSIONS: "host|HOST_SESSION|.|"
YAML
export REC_OUT="$T"
inside() { (cd "$T/repo" && DEVCONTAINER_IN_CONTAINER=1 PATH="$T/bin:$PATH" task "$@" 2>&1); }
fromhost() { (cd "$T/repo" && DEVCONTAINER_IN_CONTAINER=0 PATH="$T/bin:$PATH" task "$@" 2>&1); }

out="$(inside devcontainer:agent -- host --resume --effort high)"; rc=$?
check 'inside: exits 0' 0 "$rc"
check 'inside: agents start with the name, the flags and the CLI args' 'agents start host --resume --effort high' "$(head -n 1 "$T/agents")"
check 'inside: no AGENTS_FILE, none passed' 'file=' "$(tail -n 1 "$T/agents")"
out="$(inside devcontainer:agent AGENTS_FILE='ops/my agents.yml' -- host)"
check 'inside: AGENTS_FILE reaches the command as AGENTS_FILE_TASK_VAR (spaces kept)' 'file=ops/my agents.yml' "$(tail -n 1 "$T/agents")"
out="$(inside devcontainer:agent:list -- --json)"
check 'inside: agent:list runs agents list with its arguments' 'agents list --json' "$(head -n 1 "$T/agents")"

out="$(inside devcontainer:agent:reset AGENTS_FILE=ops/agents.yml -- host --purge --yes)"
check 'inside: agent:reset runs agents reset with its arguments' 'agents reset host --purge --yes' "$(head -n 1 "$T/agents")"
check 'inside: agent:reset hands AGENTS_FILE on' 'file=ops/agents.yml' "$(tail -n 1 "$T/agents")"

out="$(fromhost devcontainer:agent --dry -- host --new)"
contains 'host: goes through the exec task' "$out" 'devcontainer:exec CMD='
contains 'host: the command is agents start with the arguments' "$out" 'agents start host --new'
out="$(fromhost devcontainer:agent:list --dry)"
contains 'host: agent:list through the exec task' "$out" 'agents list'
out="$(fromhost devcontainer:agent:reset --dry -- --all)"
contains 'host: agent:reset through the exec task' "$out" 'agents reset --all'

# --- From the host with no agent name: refused before anything starts, unless the list marks a
# default. A stub `devcontainer` (and an answering `docker`) stand in for the launcher's CLI, so a
# run that gets through records its up and its exec; one that is refused records nothing.
mkdir -p "$T/stub" "$T/home"
# shellcheck disable=SC2016  # the stub's own $*
printf '#!/bin/sh\necho "$*" >> "$REC_OUT/cli-calls"\nexit 0\n' > "$T/stub/devcontainer"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/docker"
chmod +x "$T/stub/devcontainer" "$T/stub/docker"
nodefault='agents:
  - name: host
    cli: claude
    kind: on-demand'
withdefault="$nodefault
    default: true"
# hoststart <agents.yml text, or - for no file> [task args...]: rc, out, ran (the CLI subcommands,
# space-joined). LIST_AT=<repo-relative path> writes the list there instead of .devcontainer/agents.yml.
hoststart() {
  local list="$1" at="${LIST_AT:-.devcontainer/agents.yml}"; shift
  rm -rf "$T/repo/.devcontainer" "$T/repo/ops" "$T/cli-calls"
  mkdir -p "$T/repo/.devcontainer" "$T/repo/ops"
  [ "$list" = - ] || printf '%s\n' "$list" > "$T/repo/$at"
  rc=0
  out="$(cd "$T/repo" && DEVCONTAINER_IN_CONTAINER=0 HOST_MOUNTS=false HOME="$T/home" DEVCONTAINER_BUILD_LOCK=0 PATH="$T/stub:$T/bin:$PATH" task "$@" 2>&1)" || rc=$?
  ran="$(cut -d' ' -f1 "$T/cli-calls" 2>/dev/null | paste -sd' ')"
}
hoststart "$nodefault" devcontainer:agent
check 'host, no name, no default: refused' 1 "$([ "$rc" -ne 0 ] && echo 1)"
contains 'host, no name, no default: says what to do' "$out" 'devcontainer:agent needs an agent name: task devcontainer:agent -- <name> [--resume|--new]'
contains 'host, no name, no default: names the list and default: true' "$out" '(or mark one agent default: true in .devcontainer/agents.yml)'
check 'host, no name, no default: nothing started (no up)' '' "$ran"
hoststart "$nodefault" devcontainer:agent -- --resume
check 'host, only flags, no default: refused before up' '' "$ran"
contains 'host, only flags, no default: says what to do' "$out" 'needs an agent name'
hoststart "$withdefault" devcontainer:agent
check 'host, no name, a default: up, then the exec' 'up exec' "$ran"
contains 'host, no name, a default: agents start runs inside' "$(cat "$T/cli-calls" 2>/dev/null)" 'agents start'
hoststart "$nodefault" devcontainer:agent -- host
check 'host, a name: up, then the exec' 'up exec' "$ran"
hoststart - devcontainer:agent
check 'host, no list file: let through (the Feature says what is wrong)' 'up exec' "$ran"
LIST_AT=ops/agents.yml hoststart "$withdefault" devcontainer:agent AGENTS_FILE=ops/agents.yml
check 'host, AGENTS_FILE with a default: let through' 'up exec' "$ran"
LIST_AT=ops/agents.yml hoststart "$nodefault" devcontainer:agent AGENTS_FILE=ops/agents.yml
contains 'host, AGENTS_FILE without a default: refused, naming that list' "$out" '(or mark one agent default: true in ops/agents.yml)'
check 'host, AGENTS_FILE without a default: nothing started' '' "$ran"
rm -rf "$T/repo/ops" "$T/repo/.devcontainer"
out="$(inside devcontainer:agent)"; rc=$?
check 'inside, no name: not refused by the task (the Feature decides)' 'agents start' "$(head -n 1 "$T/agents")"

out="$(inside devcontainer:claude)"; rc=$?
check 'devcontainer:claude still runs claude-host' 0 "$rc"
contains 'devcontainer:claude still runs claude-host (called)' "$(cat "$T/claude-host" 2>/dev/null)" 'claude-host'
contains 'devcontainer:claude prints the deprecation line' "$out" 'devcontainer:claude is deprecated: use task devcontainer:agent -- <name>'
out="$(inside devcontainer:claude:fleet -- --plan)"; rc=$?
check 'devcontainer:claude:fleet still runs claude-fleet' 'claude-fleet --plan' "$(head -n 1 "$T/claude-fleet" 2>/dev/null)"
contains 'devcontainer:claude:fleet prints the deprecation line' "$out" 'devcontainer:claude:fleet is deprecated'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
