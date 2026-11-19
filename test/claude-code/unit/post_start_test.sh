#!/usr/bin/env bash
# Docker-free test of claude-code-post-start (claude-code 1.10.0, the postStartCommand): with
# participants off it does nothing and prints nothing; with participants on it runs
# `agents up --post-start` once; with the deprecated agents Feature also installed it leaves the
# run to that Feature's own hook; a missing agents command or a failing one never fails the hook.
# A fake agents records its calls. Part of `task lint` (`task test:claude-unit`).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
hook="$root/src/claude-code/claude-code-post-start.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }

mkdir -p "$T/bin" "$T/cc" "$T/ag" "$T/nobin"
# shellcheck disable=SC2016  # the fake expands its own variables
printf '#!/bin/sh\necho "$*" >> "%s/calls"\nexit "${FAKE_RC:-0}"\n' "$T" > "$T/bin/agents"; chmod +x "$T/bin/agents"
run() { CLAUDE_CODE_SHARE_DIR="$T/cc" AGENTS_SHARE_DIR="$T/ag" PATH="$T/bin:/usr/bin:/bin" bash "$hook" 2>&1; }
calls() { cat "$T/calls" 2>/dev/null; rm -f "$T/calls"; }

out="$(run)"; rc=$?
check 'participants off: exit 0' 0 "$rc"
check 'participants off: silent' '' "$out"
check 'participants off: agents not run' '' "$(calls)"

: > "$T/cc/participants"
run >/dev/null; rc=$?
check 'participants on: exit 0' 0 "$rc"
check 'participants on: agents up --post-start once' 'up --post-start' "$(calls)"

FAKE_RC=1 run >/dev/null; rc=$?
check 'participants on, agents up fails: still exit 0' 0 "$rc"
calls >/dev/null

printf '2.2.0\n' > "$T/ag/version"
run >/dev/null
check 'with the agents Feature installed: its own hook runs it, not this one' '' "$(calls)"
rm -f "$T/ag/version"

out="$(CLAUDE_CODE_SHARE_DIR="$T/cc" AGENTS_SHARE_DIR="$T/ag" PATH="$T/nobin:/usr/bin:/bin" bash "$hook" 2>&1)"; rc=$?
check 'no agents command: exit 0' 0 "$rc"
case "$out" in *"agents command is missing"*) check 'no agents command: says so' x x ;; *) check 'no agents command: says so' 'a line' "$out" ;; esac

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
