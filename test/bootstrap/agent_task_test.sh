#!/usr/bin/env bash
# Docker-free test of how `task devcontainer:agent` and `devcontainer:agent:list`
# (bootstrap/devcontainer.yml) hand the agent name, its flags and AGENTS_FILE to the agents
# Feature's `agents` command: inside the container directly, from the host through the exec
# task (--dry shows the command, nothing runs); and that the deprecated devcontainer:claude and
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

out="$(fromhost devcontainer:agent --dry -- host --new)"
contains 'host: goes through the exec task' "$out" 'devcontainer:exec CMD='
contains 'host: the command is agents start with the arguments' "$out" 'agents start host --new'
out="$(fromhost devcontainer:agent:list --dry)"
contains 'host: agent:list through the exec task' "$out" 'agents list'

out="$(inside devcontainer:claude)"; rc=$?
check 'devcontainer:claude still runs claude-host' 0 "$rc"
contains 'devcontainer:claude still runs claude-host (called)' "$(cat "$T/claude-host" 2>/dev/null)" 'claude-host'
contains 'devcontainer:claude prints the deprecation line' "$out" 'devcontainer:claude is deprecated: use task devcontainer:agent -- <name>'
out="$(inside devcontainer:claude:fleet -- --plan)"; rc=$?
check 'devcontainer:claude:fleet still runs claude-fleet' 'claude-fleet --plan' "$(head -n 1 "$T/claude-fleet" 2>/dev/null)"
contains 'devcontainer:claude:fleet prints the deprecation line' "$out" 'devcontainer:claude:fleet is deprecated'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
