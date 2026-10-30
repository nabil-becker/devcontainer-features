#!/usr/bin/env bash
# Docker-free tests of the passphrase prompt of ssh-agent-setup (src/ssh-agent/ssh-agent-setup.sh):
# a key with a passphrase in the key volume makes the start hook's ssh-add ask on the terminal. The
# hook must wait for the answer, then WARN and let the start continue (exit 0) when the wait runs
# out, when there is no terminal, or when the wait is switched off; a typed passphrase still loads
# the key, a wrong one is asked again, and the setting is honoured. The terminal is a real
# pseudo-terminal (pty_run.py); the keys are throwaway. Part of `task lint` (`task test:ssh-agent-unit`).
# SETUP_SH points the tests at another copy of the script (to show they fail on the old code).
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
setup_sh="${SETUP_SH:-$here/../../../src/ssh-agent/ssh-agent-setup.sh}"
for t in ssh-agent ssh-add ssh-keygen python3 timeout setsid; do
  command -v "$t" >/dev/null 2>&1 || { echo "passphrase_test: $t is required"; exit 1; }
done

T="$(mktemp -d /tmp/sshpw.XXXXXX)"
cleanup() { pkill -f "ssh-agent -a $T/" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/home" "$T/keys"
SOCK="$T/agent.sock"
KEYS="$T/keys"
PASS='correct horse'

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
has() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (no '$2' in: $3)"; fi
}
lacks() { # <name> <text> <output>
  if grep -qF -- "$2" <<<"$3"; then fail=$((fail + 1)); echo "FAIL - $1 ('$2' found in: $3)"
  else pass=$((pass + 1)); echo "ok   - $1"; fi
}

fresh() { # a new agent with nothing loaded
  pkill -f "ssh-agent -a $T/" 2>/dev/null; rm -f "$SOCK"
  ssh-agent -a "$SOCK" >/dev/null
}
held() { SSH_AUTH_SOCK="$SOCK" ssh-add -l 2>/dev/null | grep -c SHA256; }

# ARGS: what follows ssh-agent-setup. The start hook has none; `task ssh-agent:setup` passes setup --ask.
ARGS=(setup --ask)
# noterm: the hook with no terminal at all (a new session, stdin closed).
noterm() {
  local t0=$SECONDS
  out="$(env -i PATH="$PATH" HOME="$T/home" DCF_SSH_AGENT_SOCK="$SOCK" DCF_SSH_AGENT_KEY_DIR="$KEYS" DCF_HOST_SSH_AGENT=key \
    setsid -w timeout 60 bash "$setup_sh" "${ARGS[@]}" 2>&1 </dev/null)"
  rc=$?; took=$((SECONDS - t0))
}
# onterm <answers|-> [VAR=value ...]: the hook on a pseudo-terminal that types the answers.
onterm() {
  local answers="$1" t0=$SECONDS
  shift
  out="$(env -i PATH="$PATH" HOME="$T/home" DCF_SSH_AGENT_SOCK="$SOCK" DCF_SSH_AGENT_KEY_DIR="$KEYS" DCF_HOST_SSH_AGENT=key "$@" \
    python3 -I "$here/pty_run.py" "$answers" 25 bash "$setup_sh" "${ARGS[@]}" 2>&1)"
  took=$((SECONDS - t0))
  rc="$(grep '^EXIT ' <<<"$out" | tail -n 1 | cut -d' ' -f2)"
}

ssh-keygen -q -t ed25519 -N "$PASS" -C protected -f "$KEYS/protected"
cmd_hint='task ssh-agent:setup'

# --- the START HOOK (no arguments) never asks, terminal or not: skip, warn, exit 0, the rest loads
ssh-keygen -q -t ed25519 -N '' -C plain -f "$KEYS/plain"
ARGS=()
fresh
onterm - SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT=20
check 'hook on a terminal: exits 0' 0 "$rc"
lacks 'hook on a terminal: never prompts' 'Enter passphrase for' "$out"
has 'hook on a terminal: one warning naming task ssh-agent:setup' 'protected has a passphrase and the start hook never asks for one, so it is not loaded; the start continues' "$out"
has 'hook on a terminal: names the command' 'task ssh-agent:setup' "$out"
check 'hook on a terminal: it did not wait' yes "$([ "$took" -lt 8 ] && echo yes || echo no)"
check 'hook on a terminal: the unprotected key is loaded, the other skipped' 1 "$(held)"
has 'hook on a terminal: the summary counts the skipped one' '1 of 2 key(s)' "$out"
check 'hook on a terminal: the agent is running' 0 "$(SSH_AUTH_SOCK="$SOCK" ssh-add -l >/dev/null 2>&1; [ $? -le 1 ] && echo 0 || echo 1)"
fresh
noterm
check 'hook without a terminal: exits 0' 0 "$rc"
has 'hook without a terminal: the same warning' 'the start hook never asks for one' "$out"
check 'hook without a terminal: the other key is loaded' 1 "$(held)"
rm -f "$KEYS/plain" "$KEYS/plain.pub"
ARGS=(setup --ask)

# --- no terminal to ask on (the explicit task): warn at once and continue
fresh
noterm
check 'no terminal: the start step exits 0' 0 "$rc"
has 'no terminal: one clear warning' 'has a passphrase and there is no terminal to ask for it, so it is not loaded; the start continues' "$out"
has 'no terminal: says how to load it later' "$cmd_hint" "$out"
check 'no terminal: it did not wait' yes "$([ "$took" -lt 10 ] && echo yes || echo no)"
check 'no terminal: nothing was loaded' 0 "$(held)"

# --- a terminal, nobody types: the wait ends in a warning, exit 0
fresh
onterm - SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT=2
check 'timeout: the start step exits 0' 0 "$rc"
has 'timeout: ssh-add asked for the passphrase' 'Enter passphrase for' "$out"
has 'timeout: one warning naming the wait' 'no passphrase for protected within 2s, so it is not loaded; the start continues' "$out"
has 'timeout: says how to load it later' "$cmd_hint" "$out"
check 'timeout: the wait was the setting (>= 2s)' yes "$([ "$took" -ge 2 ] && echo yes || echo no)"
check 'timeout: and it ended soon after' yes "$([ "$took" -le 12 ] && echo yes || echo no)"
check 'timeout: nothing was loaded' 0 "$(held)"
has 'timeout: the rest of the start still ran (summary and verdict)' 'reachable at' "$out"

# --- the setting is honoured: a longer wait outlasts the shorter one
fresh
onterm - SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT=5
has 'setting: 5 seconds is waited for' 'within 5s' "$out"
check 'setting: it waited at least 5s' yes "$([ "$took" -ge 5 ] && echo yes || echo no)"

# --- 0 switches the prompt off
fresh
onterm - SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT=0
check 'wait 0: exits 0' 0 "$rc"
has 'wait 0: warns, the key is not loaded' 'the wait for it is off' "$out"
lacks 'wait 0: never prompts' 'Enter passphrase for' "$out"

# --- the passphrase typed in time loads the key
fresh
onterm "$PASS" SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT=20
check 'unlock: exits 0' 0 "$rc"
has 'unlock: the key is reported loaded' '1 of 1 key(s)' "$out"
check 'unlock: the agent holds it' 1 "$(held)"
lacks 'unlock: the passphrase is never printed' "$PASS" "$out"
lacks 'unlock: no warning about the key' 'is not loaded' "$out"

# --- a wrong passphrase is asked again (ssh-add's own retry), then the right one loads it
fresh
onterm "wrong one|$PASS" SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT=20
check 'wrong then right: exits 0' 0 "$rc"
has 'wrong then right: ssh-add asked again' 'Bad passphrase, try again' "$out"
check 'wrong then right: the agent holds the key' 1 "$(held)"
lacks 'wrong then right: the wrong one is never printed' 'wrong one' "$out"

# --- wrong every time: ssh-add gives up after its tries, one warning, exit 0
fresh
onterm "a|b|c" SSH_AGENT_SETUP_PASSPHRASE_TIMEOUT=20
check 'always wrong: exits 0' 0 "$rc"
has 'always wrong: one warning with the command' "$cmd_hint" "$out"
check 'always wrong: nothing loaded' 0 "$(held)"

# --- a key without a passphrase loads with no terminal and no wait
ssh-keygen -q -t ed25519 -N '' -C plain -f "$KEYS/plain"
rm -f "$KEYS/protected" "$KEYS/protected.pub"
fresh
noterm
check 'unprotected: exits 0' 0 "$rc"
check 'unprotected: loaded without a terminal' 1 "$(held)"
lacks 'unprotected: no warning' 'is not loaded' "$out"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
