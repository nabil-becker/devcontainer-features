#!/usr/bin/env bash
# Docker-free tests of the audio Feature's audio-check (src/audio/audio-check.sh): each thing that
# can be missing gives its own line in order and exit 1 (rec, SoX's PulseAudio backend, arecord
# only a note, pactl; PULSE_SERVER; the socket, with the hint for each DCF_HOST_AUDIO value;
# PulseAudio not answering; only monitor sources), and "ready" with exit 0. Fake sox, pactl and
# arecord on a private PATH; the socket is a real unix socket made with python3. Part of lint
# (task test:audio-unit). AUDIO_CHECK points the tests at another copy of the script.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
script="${AUDIO_CHECK:-$here/../../../src/audio/audio-check.sh}"
bash_bin="$(command -v bash)"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0 fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
has() { # <name> <pattern> <text>
  if grep -qF -- "$2" <<<"$3"; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (no '$2' in: $3)"; fi
}

sock="$T/PulseServer"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock"

# make_bin <dir> [sox] [sox-nopulse] [rec] [pactl] [arecord]: a PATH with the base tools and the fakes named.
make_bin() {
  local d="$1" t; shift
  mkdir -p "$d"
  for t in grep awk head printf sed timeout cat date dirname tr; do ln -sf "$(command -v "$t")" "$d/$t"; done
  for t in "$@"; do
    case "$t" in
      sox) printf '#!/bin/sh\necho "AUDIO DEVICE DRIVERS: alsa pulseaudio"\n' > "$d/sox" ;;
      sox-nopulse) printf '#!/bin/sh\necho "AUDIO DEVICE DRIVERS: alsa"\n' > "$d/sox" ;;
      rec) printf '#!/bin/sh\nexit 0\n' > "$d/rec" ;;
      arecord) printf '#!/bin/sh\nexit 0\n' > "$d/arecord" ;;
      # FAKE_PACTL: answer (info and sources), noanswer, monitors.
      pactl) cat > "$d/pactl" <<'EOF'
#!/bin/sh
case "${FAKE_PACTL:-answer}" in noanswer) echo "Connection failure" >&2; exit 1 ;; esac
if [ "$1" = info ]; then echo "Server Name: pulseaudio"; exit 0; fi
echo "1	RDPSink.monitor	module-rdp-sink.c	s16le 2ch 44100Hz	SUSPENDED"
if [ "${FAKE_PACTL:-answer}" = answer ]; then echo "2	RDPSource	module-rdp-source.c	s16le 1ch 44100Hz	SUSPENDED"; fi
EOF
        ;;
    esac
    [ -f "$d/$t" ] && chmod +x "$d/$t"
    [ "$t" = sox-nopulse ] && chmod +x "$d/sox"
  done
  return 0
}
make_bin "$T/full" sox rec pactl arecord
make_bin "$T/norec" sox pactl arecord
make_bin "$T/nopulsefmt" sox-nopulse rec pactl arecord
make_bin "$T/noarecord" sox rec pactl
make_bin "$T/nopactl" sox rec arecord

run() { # <bin dir> [VAR=value ...]: out, rc
  local d="$1"; shift
  out="$(env -i PATH="$d" "$@" "$bash_bin" "$script" 2>&1)"; rc=$?
}

run "$T/full" PULSE_SERVER="unix:$sock" DCF_HOST_AUDIO=wslg
check 'ready: exit 0' 0 "$rc"
check 'ready: one line naming the source' "audio: ready: capture source RDPSource through unix:$sock" "$out"

run "$T/full" PULSE_SERVER="$sock"
check 'a bare socket path is accepted' 0 "$rc"

run "$T/full" DCF_HOST_AUDIO=none
check 'no PULSE_SERVER: exit 1' 1 "$rc"
has 'no PULSE_SERVER: says so' 'audio: no PULSE_SERVER' "$out"

run "$T/full" PULSE_SERVER=unix:/nonexistent/PulseServer DCF_HOST_AUDIO=none
check 'socket missing: exit 1' 1 "$rc"
has 'socket missing: names the path' 'socket not reachable: /nonexistent/PulseServer' "$out"
has 'socket missing, none: how to opt in' 'set DCF_HOST_AUDIO=wslg in .devcontainer/.env' "$out"
run "$T/full" PULSE_SERVER=unix:/nonexistent/PulseServer DCF_HOST_AUDIO=wslg
has 'socket missing, wslg, no directory: not set up, the WSL restart hint' 'a WSL restart drops that directory' "$out"
check 'socket missing, wslg, no directory: not "off"' 0 "$(grep -c '^audio: off' <<<"$out")"
# The workstation's gate (ADR 0057): a mounted /mnt/wslg without the socket is "off", distinct from "not set up".
mkdir -p "$T/gate"
run "$T/full" PULSE_SERVER="unix:$T/gate/PulseServer" DCF_HOST_AUDIO=wslg
check 'gate off (directory there, no socket): exit 1' 1 "$rc"
check 'gate off: says off, the workstation has not turned audio on' "audio: off (the workstation has not turned audio on): $T/gate/PulseServer is not there; on the workstation run task audio:on (task audio:on TTL=30m for longer), then try again; no rebuild is needed" "$out"
check 'gate off: is not the "not set up" line' 0 "$(grep -c 'socket not reachable' <<<"$out")"
run "$T/full" PULSE_SERVER="unix:$T/gate/PulseServer" DCF_HOST_AUDIO=none
has 'directory there, no socket, DCF_HOST_AUDIO=none: still not set up' 'socket not reachable' "$out"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/gate/PulseServer"
echo $(( $(date +%s) + 754 )) > "$T/gate/expires"
run "$T/full" PULSE_SERVER="unix:$T/gate/PulseServer" DCF_HOST_AUDIO=wslg
check 'gate on: exit 0' 0 "$rc"
has 'gate on: ready, the workstation turned it on, the time left' "audio: ready: capture source RDPSource through unix:$T/gate/PulseServer (the workstation turned audio on; 12m" "$out"
has 'gate on: seconds are shown too' 's left)' "$out"
run "$T/full" PULSE_SERVER="unix:$T/gate/PulseServer" DCF_HOST_AUDIO=none
check 'gate on, DCF_HOST_AUDIO=none: no time claimed' "audio: ready: capture source RDPSource through unix:$T/gate/PulseServer" "$out"
echo $(( $(date +%s) - 5 )) > "$T/gate/expires"
run "$T/full" PULSE_SERVER="unix:$T/gate/PulseServer" DCF_HOST_AUDIO=wslg
check 'gate on, an expired expires file: ready, no time claimed' "audio: ready: capture source RDPSource through unix:$T/gate/PulseServer" "$out"
rm -f "$T/gate/expires"
run "$T/full" PULSE_SERVER="unix:$T/gate/PulseServer" DCF_HOST_AUDIO=wslg
check 'gate on, no expires file (an older launcher): ready' "audio: ready: capture source RDPSource through unix:$T/gate/PulseServer" "$out"

run "$T/full" PULSE_SERVER=unix:/nonexistent/PulseServer
has 'socket missing, unset: not started by the launcher' 'DCF_HOST_AUDIO is unset' "$out"

run "$T/full" PULSE_SERVER="unix:$sock" FAKE_PACTL=noanswer
check 'PulseAudio not answering: exit 1' 1 "$rc"
has 'PulseAudio not answering: says so' 'does not answer (pactl info fails)' "$out"

run "$T/full" PULSE_SERVER="unix:$sock" FAKE_PACTL=monitors
check 'only monitors: exit 1' 1 "$rc"
has 'only monitors: no capture source' 'audio: no capture source' "$out"

run "$T/norec" PULSE_SERVER="unix:$sock"
check 'no rec: exit 1' 1 "$rc"
check 'no rec: the first line names it' 'audio: missing: rec (package sox)' "$(head -n1 <<<"$out")"
has 'no rec: the server is still checked' 'has a capture source (RDPSource), but a tool above is missing' "$out"

run "$T/nopulsefmt" PULSE_SERVER="unix:$sock"
check 'no PulseAudio backend: exit 1' 1 "$rc"
has 'no PulseAudio backend: names the package' 'libsox-fmt-pulse' "$out"

run "$T/noarecord" PULSE_SERVER="unix:$sock"
check 'no arecord: still ready (rec suffices)' 0 "$rc"
has 'no arecord: a note' 'missing: arecord (package alsa-utils)' "$out"

run "$T/nopactl" PULSE_SERVER="unix:$sock"
check 'no pactl: exit 1' 1 "$rc"
has 'no pactl: names the package' 'missing: pactl (package pulseaudio-utils)' "$out"

run "$T/nopactl"
check 'no pactl and no PULSE_SERVER: the tool first' 'audio: missing: pactl' "$(sed -n 1p <<<"$out" | cut -c1-21)"
check 'no pactl and no PULSE_SERVER: then the variable' 'audio: no PULSE_SERVER' "$(sed -n 2p <<<"$out" | cut -c1-22)"

# The Feature Taskfile runs it (needs task; skipped without).
if command -v task >/dev/null 2>&1; then
  install -m 0755 "$script" "$T/full/audio-check"; ln -sf "$(command -v env)" "$T/full/env"; ln -sf "$bash_bin" "$T/full/bash"
  out="$(cd "$T" && env -i PATH="$T/full:$(dirname "$(command -v task)")" HOME="$T" PULSE_SERVER="unix:$sock" task -t "$here/../../../src/audio/taskfile.yml" check 2>&1)"; rc=$?
  check 'task audio check: exit 0' 0 "$rc"
  has 'task audio check: the verdict' 'audio: ready' "$out"
else
  echo "skip - task not on PATH (the Taskfile part)"
fi

echo "audio-check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
