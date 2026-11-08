#!/usr/bin/env bash
# Docker-free test of the relay script the devcontainer-cli launcher runs in the default WSL distro
# for task audio:on, audio:off and audio:status (audio_relay_script in
# src/devcontainer-cli/devcontainer-cli.sh), run for real in a private directory with a fake
# "WSLg" socket (python3 echoing what it is sent): off before anything, on answering the seconds
# with the socket there (mode 666) and carrying data to the fake WSLg, the time left, the socket
# gone after the duration, off ending it at once (socket, expires and pid file gone), on twice
# leaving one relay, a missing socat and a missing WSLg socket answered plainly with no socket made,
# status cleaning up after a killed relay. Part of lint (task test:audio-unit). Needs python3 and
# socat; skipped, loudly, without socat. CLI_SH points at another copy of the launcher.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
cli_sh="${CLI_SH:-$here/../../../src/devcontainer-cli/devcontainer-cli.sh}"

if ! command -v socat >/dev/null 2>&1; then echo "skip - socat is not on PATH (the relay itself); install it to run this test"; exit 0; fi

T="$(mktemp -d)"
trap 'kill "${fake:-0}" 2>/dev/null; sh -c "$script" sh off 0 "$T/d" "$T/w" >/dev/null 2>&1; rm -rf "$T"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}

# The script, as the launcher holds it.
script="$(bash -c 'source <(sed -n "/^audio_relay_script=/p" "$1"); printf %s "$audio_relay_script"' _ "$cli_sh")"
check 'the script was found in the launcher' yes "$([ -n "$script" ] && echo yes)"

d="$T/d"; w="$T/w"
python3 -I -c '
import socket, sys, os
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(5)
while True:
    c, _ = s.accept()
    data = c.recv(100)
    c.sendall(data)
    c.close()
' "$w" &
fake=$!
for _ in $(seq 1 50); do [ -S "$w" ] && break; sleep 0.1; done

r() { sh -c "$script" sh "$1" "${2:-0}" "$d" "$w"; }
echo_through() { python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1]); s.sendall(b"ping"); print(s.recv(10).decode())
' "$d/PulseServer" 2>&1; }

check 'status before anything: off' off "$(r status)"
check 'off before anything: off, no directory needed' off "$(r off)"

check 'on 3: answers on 3' 'on 3' "$(r on 3)"
check 'on: the socket is there' yes "$([ -S "$d/PulseServer" ] && echo yes)"
check 'on: mode 666' 666 "$(stat -c %a "$d/PulseServer")"
check 'on: data goes through to the WSLg socket and back' ping "$(echo_through)"
st="$(r status)"
check 'status: on with at most 3 seconds left' yes "$([[ "$st" =~ ^on\ [0-3]$ ]] && echo yes)"
check 'on: expires is in the future' yes "$([ "$(cat "$d/expires")" -gt "$(date +%s)" ] && echo yes)"
check 'on: the pid file is outside the directory' yes "$([ -s "$d.pid" ] && [ ! -e "$d/pid" ] && echo yes)"
sleep 4
check 'after the duration: the socket file is gone' no "$([ -e "$d/PulseServer" ] && echo yes || echo no)"
check 'after the duration: status says off' off "$(r status)"
check 'after the duration: status cleaned up expires and the pid file' 'no no' "$([ -e "$d/expires" ] && echo yes || echo no) $([ -e "$d.pid" ] && echo yes || echo no)"

check 'on 60: answers on 60' 'on 60' "$(r on 60)"
pid1="$(cat "$d.pid")"
check 'on again: one relay, the old one ended' 'on 120' "$(r on 120)"
pid2="$(cat "$d.pid")"
check 'on again: a new pid' yes "$([ "$pid1" != "$pid2" ] && echo yes)"
check 'on again: the old relay is gone' no "$(kill -0 "$pid1" 2>/dev/null && echo yes || echo no)"
check 'on again: the new one works' ping "$(echo_through)"
check 'off: says off' off "$(r off)"
check 'off: the socket, expires and pid file are gone' 'no no no' "$([ -e "$d/PulseServer" ] && echo yes || echo no) $([ -e "$d/expires" ] && echo yes || echo no) $([ -e "$d.pid" ] && echo yes || echo no)"
check 'off: the relay process is gone' no "$(kill -0 "$pid2" 2>/dev/null && echo yes || echo no)"
check 'off: the container side can no longer connect' 1 "$(echo_through >/dev/null 2>&1; echo $(($? > 0)))"

# A killed relay (no unlink): status cleans up and says off.
r on 60 >/dev/null
kill -9 -- "-$(cat "$d.pid")" 2>/dev/null
sleep 0.3
check 'a killed relay: status says off' off "$(r status)"
check 'a killed relay: status removed the stale socket' no "$([ -e "$d/PulseServer" ] && echo yes || echo no)"

# Missing pieces: answered plainly, no socket made.
empty="$T/empty"; mkdir -p "$empty"; for t in sh cat date mkdir rm echo; do ln -sf "$(command -v "$t")" "$empty/$t" 2>/dev/null; done
check 'no socat: nosocat, no socket' 'nosocat no' "$(PATH="$empty" sh -c "$script" sh on 5 "$d" "$w" 2>&1) $([ -e "$d/PulseServer" ] && echo yes || echo no)"
check 'no WSLg socket: nopulse, no socket' 'nopulse no' "$(sh -c "$script" sh on 5 "$d" "$T/absent") $([ -e "$d/PulseServer" ] && echo yes || echo no)"
check 'an unknown action: usage' usage "$(r dance)"

echo "relay: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
