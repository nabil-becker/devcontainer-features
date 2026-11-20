#!/usr/bin/env bash
# Docker-free tests of the copilot Feature's agent-adapter-copilot (the participant component's
# adapter contract for GitHub Copilot CLI), with a fake `copilot` that records every call with its
# folder and keeps an MCP table like `copilot mcp add|remove|get` (it refuses a name that exists,
# as the real CLI does). No Copilot login, no network.
#   new, resume: copilot --name / --resume <session name> in the folder (AGENT_SESSION_NAME or the handle)
#   run-once: the prompt from stdin as -p, --silent --no-ask-user --no-auto-update, no tool grant unless
#     asked, --session-id a stable UUID only with AGENT_ADAPTER_COPILOT_CONTINUE=1, an empty prompt refused
#   mcp-attach: copilot mcp add facilitator, no token or handle in the entry, idempotent, nothing with
#     no facilitator on PATH, other targets exit 2
#   every other verb exits 3, and `supports` lists exactly the verbs that do not
# Part of `task lint` (`task test:copilot-unit`). ADAPTER_SH points the test at another copy.
# shellcheck disable=SC2016  # fake programs are written with single-quoted scripts on purpose
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
adapter_sh="${ADAPTER_SH:-$root/src/copilot/agent-adapter-copilot.sh}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

bin="$T/bin"; nofac="$T/nofac"; mkdir -p "$bin" "$nofac" "$T/repo"
cp "$adapter_sh" "$bin/agent-adapter-copilot"; chmod +x "$bin/agent-adapter-copilot"
cp "$adapter_sh" "$nofac/agent-adapter-copilot"; chmod +x "$nofac/agent-adapter-copilot"
export FAKE_CALLS="$T/calls" FAKE_MCP="$T/mcp"
: > "$FAKE_CALLS"; : > "$FAKE_MCP"
cat > "$bin/copilot" <<'FAKE'
#!/usr/bin/env bash
echo "$(pwd -P)|$*" >> "$FAKE_CALLS"
if [ "$1" = mcp ]; then
  case "$2" in
    add) name="$3"; shift 3
      grep -q "^$name	" "$FAKE_MCP" && { echo "Error: Server \"$name\" already exists." >&2; exit 1; }
      printf '%s\t%s\n' "$name" "$*" >> "$FAKE_MCP"; echo "Added server \"$name\""; exit 0 ;;
    remove) grep -q "^$3	" "$FAKE_MCP" || { echo "Error: Server \"$3\" not found." >&2; exit 1; }
      grep -v "^$3	" "$FAKE_MCP" > "$FAKE_MCP.new"; mv "$FAKE_MCP.new" "$FAKE_MCP"; exit 0 ;;
  esac
fi
exit 0
FAKE
printf '#!/bin/sh\nexit 0\n' > "$bin/facilitator"
chmod +x "$bin"/copilot "$bin"/facilitator
# a PATH with copilot but no facilitator
cp "$bin/copilot" "$nofac/copilot"
sysp="/usr/bin:/bin"
A="$bin/agent-adapter-copilot"
calls() { cat "$FAKE_CALLS"; }
reset() { : > "$FAKE_CALLS"; : > "$FAKE_MCP"; }
run() { PATH="$bin:$sysp" "$@"; }

# --- supports agrees with the verbs
VERBS="start-bg wake attach resume new list stop logs hint record trust run-once session-busy session-stop session-remove"
sup="$(run "$A" supports)"
check "supports lists the working verbs" "new resume hint run-once supports" "$(printf '%s' "$sup" | tr '\n' ' ' | sed 's/ $//')"
bad=''
for v in $VERBS; do
  if [ "$v" = list ] || [ "$v" = session-busy ] || [ "$v" = session-stop ] || [ "$v" = session-remove ]; then
    PATH="$bin:$sysp" timeout 20 "$A" "$v" x </dev/null >/dev/null 2>&1; rc=$?
  else
    PATH="$bin:$sysp" timeout 20 "$A" "$v" x "$T/repo" -- </dev/null >/dev/null 2>&1; rc=$?
  fi
  if printf '%s\n' "$sup" | grep -qx "$v"; then [ "$rc" -ne 3 ] || bad="$bad $v(listed, answers 3)"
  else [ "$rc" -eq 3 ] || bad="$bad $v(not listed, answers $rc)"; fi
done
check "supports agrees with the verbs" "" "$bad"
reset
check "an unsupported verb never reaches copilot" "" "$(calls)"
run "$A" start-bg x "$T/repo" 2>"$T/err"; check "start-bg exits 3" 3 "$?"
contains "the refusal says why" "$(cat "$T/err")" "no local background session"
run "$A" bogus x "$T/repo" 2>/dev/null; check "an unknown verb exits 3" 3 "$?"
run "$A" 2>/dev/null; check "no verb exits 2" 2 "$?"
run "$A" new onlyname 2>/dev/null; check "new without a folder exits 2" 2 "$?"
run "$A" new x "$T/nonexistent" 2>/dev/null; check "a missing folder exits 1" 1 "$?"

# --- new and resume
reset
run "$A" new jester "$T/repo" -- --model gpt-x; check "new exits 0" 0 "$?"
check "new: copilot --name <handle> in the folder, args after --" "$T/repo|--name jester --model gpt-x" "$(calls)"
reset
AGENT_SESSION_NAME="jester (review)" run "$A" new jester "$T/repo" --; check "new with a session name" "$T/repo|--name jester (review)" "$(calls)"
reset
AGENT_SESSION_NAME=$'bad\tname' run "$A" new jester "$T/repo" -- 2>"$T/err"
check "a tab in the session name falls back to the handle" "$T/repo|--name jester" "$(calls)"
contains "and says so" "$(cat "$T/err")" "using the handle"
reset
run "$A" resume jester "$T/repo" --; check "resume: copilot --resume <name>" "$T/repo|--resume jester" "$(calls)"
reset
AGENT_SESSION_NAME=jester-two run "$A" resume jester "$T/repo" -- --model m; check "resume with a session name and args" "$T/repo|--resume jester-two --model m" "$(calls)"
reset
check "hint prints how to resume by hand" "yes" "$(run "$A" hint jester "$T/repo" | grep -q "copilot --resume 'jester'" && echo yes)"
check "hint calls nothing" "" "$(calls)"

# --- run-once
reset
printf 'tell a joke\n' | run "$A" run-once jester "$T/repo" -- >/dev/null; rc=$?
check "run-once exits 0" 0 "$rc"
check "run-once: -p <prompt>, silent, no ask, no auto-update, no tool grant" "$T/repo|-p tell a joke --silent --no-ask-user --no-auto-update" "$(calls)"
reset
printf 'hi' | run "$A" run-once jester "$T/repo" -- --model m --allow-tool 'shell(git status)' >/dev/null
check "run-once passes the caller's args through" "$T/repo|-p hi --silent --no-ask-user --no-auto-update --model m --allow-tool shell(git status)" "$(calls)"
reset
printf 'hi' | AGENT_ADAPTER_COPILOT_ALLOW_ALL_TOOLS=1 run "$A" run-once jester "$T/repo" -- >/dev/null
contains "run-once: --allow-all-tools only when asked" "$(calls)" "--allow-all-tools"
reset
printf '   \n' | run "$A" run-once jester "$T/repo" -- 2>/dev/null; check "an empty prompt exits 2" 2 "$?"
check "and calls nothing" "" "$(calls)"
big="$(head -c 100001 /dev/zero | tr '\0' a)"
printf '%s' "$big" | run "$A" run-once jester "$T/repo" -- 2>"$T/err"; check "a prompt over 100000 bytes exits 2" 2 "$?"
contains "and says the limit" "$(cat "$T/err")" "limit is 100000"
reset
printf 'a' | run "$A" run-once jester "$T/repo" -- >/dev/null; lacks "no --session-id by default (a fresh session each turn)" "$(calls)" "--session-id"
reset
printf 'a' | AGENT_ADAPTER_COPILOT_CONTINUE=1 run "$A" run-once jester "$T/repo" -- >/dev/null; c1="$(calls)"
printf 'b' | AGENT_ADAPTER_COPILOT_CONTINUE=1 run "$A" run-once jester "$T/repo" -- >/dev/null
sid1="$(printf '%s\n' "$c1" | sed -n 's/.*--session-id \([^ ]*\).*/\1/p' | head -n 1)"
sid2="$(calls | sed -n 's/.*--session-id \([^ ]*\).*/\1/p' | sed -n 2p)"
check "CONTINUE: a UUID of the right shape" "yes" "$(printf '%s' "$sid1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' && echo yes)"
check "CONTINUE: the same UUID for the same name and folder" "$sid1" "$sid2"
reset
mkdir -p "$T/repo2"
printf 'a' | AGENT_ADAPTER_COPILOT_CONTINUE=1 run "$A" run-once jester "$T/repo2" -- >/dev/null
printf 'a' | AGENT_ADAPTER_COPILOT_CONTINUE=1 run "$A" run-once other "$T/repo" -- >/dev/null
s3="$(calls | sed -n 's/.*--session-id \([^ ]*\).*/\1/p' | sed -n 1p)"; s4="$(calls | sed -n 's/.*--session-id \([^ ]*\).*/\1/p' | sed -n 2p)"
check "CONTINUE: another folder gets another UUID" "different" "$([ "$s3" != "$sid1" ] && echo different)"
check "CONTINUE: another name gets another UUID" "different" "$([ "$s4" != "$sid1" ] && echo different)"
# the prompt is read from stdin, not the terminal: nothing on stdin is an error, not a hang
reset
PATH="$bin:$sysp" timeout 10 "$A" run-once jester "$T/repo" -- </dev/null >/dev/null 2>&1; check "no stdin: exit 2, no hang" 2 "$?"

# --- the reply reaches stdout untouched (the fake prints a line when -p is used)
mkdir -p "$T/echo"; cp "$adapter_sh" "$T/echo/agent-adapter-copilot"; chmod +x "$T/echo/agent-adapter-copilot"
printf '#!/bin/sh\necho "reply: $2"\n' > "$T/echo/copilot"; chmod +x "$T/echo/copilot"
check "run-once: copilot's stdout is the reply" "reply: hello there" "$(printf 'hello there' | PATH="$T/echo:$sysp" "$T/echo/agent-adapter-copilot" run-once jester "$T/repo" --)"
printf '#!/bin/sh\necho oops >&2\nexit 7\n' > "$T/echo/copilot"
printf 'x' | PATH="$T/echo:$sysp" "$T/echo/agent-adapter-copilot" run-once jester "$T/repo" -- 2>/dev/null; check "run-once: copilot's exit code is the adapter's" 7 "$?"

# --- mcp-attach
reset
run "$A" mcp-attach facilitator >/dev/null 2>&1; rc=$?
check "mcp-attach exits 0" 0 "$rc"
check "mcp-attach: remove, then add, through copilot mcp" "mcp remove facilitator;mcp add facilitator" "$(calls | sed 's/^[^|]*|//' | cut -d' ' -f1-3 | tr '\n' ';' | sed 's/;$//')"
contains "the entry is the stdio command that reads handle and token from the environment" "$(cat "$FAKE_MCP")" 'sh -c exec facilitator mcp --as "${FACILITATOR_HANDLE:?'
lacks "no token in the entry" "$(cat "$FAKE_MCP")" "FACILITATOR_TOKEN="
lacks "no --env in the call" "$(calls)" "--env"
check "one entry" 1 "$(grep -c '^facilitator	' "$FAKE_MCP")"
run "$A" mcp-attach facilitator >/dev/null 2>&1; check "mcp-attach twice exits 0 (idempotent)" 0 "$?"
check "still one entry" 1 "$(grep -c '^facilitator	' "$FAKE_MCP")"
run "$A" mcp-attach other 2>/dev/null; check "another target exits 2" 2 "$?"
run "$A" mcp-attach 2>/dev/null; check "no target exits 2" 2 "$?"
reset
out="$(PATH="$nofac:$sysp" "$nofac/agent-adapter-copilot" mcp-attach facilitator 2>&1)"; rc=$?
check "no facilitator on PATH: exit 0" 0 "$rc"
contains "and it says nothing was registered" "$out" "no entry to register"
check "and copilot is not called" "" "$(calls)"
out="$(PATH="$sysp" "$A" mcp-attach facilitator 2>&1)"; rc=$?
check "no copilot on PATH: exit 1" 1 "$rc"
contains "and it names the official Feature" "$out" "copilot-cli"
# a home that does not exist yet is made private
reset
h="$T/newhome/sub"; COPILOT_HOME="$h" run "$A" mcp-attach facilitator >/dev/null 2>&1
check "a missing COPILOT_HOME is created owner-only" "700" "$(stat -c %a "$h" 2>/dev/null)"
# a failing copilot mcp add is an error that names the likely cause
printf '#!/bin/sh\n[ "$2" = add ] && { echo "Error: The storage directory is writable by group or other users." >&2; exit 1; }\nexit 0\n' > "$T/echo/copilot"
cp "$bin/facilitator" "$T/echo/facilitator"
out="$(PATH="$T/echo:$sysp" "$T/echo/agent-adapter-copilot" mcp-attach facilitator 2>&1)"; rc=$?
check "a refused add exits 1" 1 "$rc"
contains "and names the private-home rule" "$out" "writable by group or other"

echo "copilot adapter: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
