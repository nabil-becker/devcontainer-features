#!/usr/bin/env bash
# Docker-free test of how `task devcontainer:claude:fleet` (bootstrap/devcontainer.yml)
# hands SESSIONS and its arguments to claude-fleet: inside the container directly, from
# the host through the exec task (--dry shows the command, nothing runs), and the
# refusal when SESSIONS is not set. A fake claude-fleet on PATH records what it gets.
# Needs the real `task` (the lint environment has it). YAML_FILE points the test at
# another copy of devcontainer.yml (used to show the test fails when the task is broken).
# Part of `task lint` (`task test:claude-fleet-task`).
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
cat > "$T/bin/claude-fleet" <<'FAKE'
#!/bin/sh
printf '%s' "$SESSIONS_B64" | base64 -d > "$FLEET_OUT/sessions"
echo "$*" > "$FLEET_OUT/args"
FAKE
chmod +x "$T/bin/claude-fleet"
sessions='solis|HOST_SESSION_SOLIS|rooms/solis|--model sonnet
atlas|HOST_SESSION_ATLAS|rooms/atlas|'
cat > "$T/repo/Taskfile.yml" <<YAML
version: '3'
includes:
  devcontainer:
    taskfile: '$yml'
    vars:
      SESSIONS: |
        solis|HOST_SESSION_SOLIS|rooms/solis|--model sonnet
        atlas|HOST_SESSION_ATLAS|rooms/atlas|
YAML
printf "version: '3'\nincludes:\n  devcontainer: '%s'\n" "$yml" > "$T/repo/NoSessions.yml"

export FLEET_OUT="$T"
out="$(cd "$T/repo" && DEVCONTAINER_IN_CONTAINER=1 PATH="$T/bin:$PATH" task devcontainer:claude:fleet -- --plan --no-view 2>&1)"; rc=$?
check 'inside: exits 0' 0 "$rc"
check 'inside: claude-fleet gets SESSIONS (lines, pipes, spaces intact)' "$sessions" "$(cat "$T/sessions" 2>/dev/null)"
check 'inside: claude-fleet gets the arguments after --' '--plan --no-view' "$(cat "$T/args" 2>/dev/null)"

out="$(cd "$T/repo" && DEVCONTAINER_IN_CONTAINER=0 PATH="$T/bin:$PATH" task devcontainer:claude:fleet --dry -- --plan 2>&1)"; rc=$?
contains 'host: goes through the exec task' "$out" 'devcontainer:exec CMD='
contains 'host: the command is claude-fleet with the arguments' "$out" "claude-fleet --plan"
contains 'host: SESSIONS travels encoded' "$out" "SESSIONS_B64='"

out="$(cd "$T/repo" && DEVCONTAINER_IN_CONTAINER=1 task -t NoSessions.yml devcontainer:claude:fleet 2>&1)"; rc=$?
check 'no SESSIONS: refuses' 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
contains 'no SESSIONS: names the variable' "$out" 'SESSIONS'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
