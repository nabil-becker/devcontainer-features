#!/usr/bin/env bash
# audio-check: says plainly whether a recorder in this container can reach a microphone through
# PulseAudio, and if not, what is missing, in order: the tools (rec with SoX's PulseAudio backend,
# pactl, arecord), PULSE_SERVER, the socket it names, PulseAudio answering, a capture source (a
# source that is not a sink's .monitor). Exit 0 when ready, 1 when not. Installed by the audio
# Feature as /usr/local/bin/audio-check; `task audio:check` runs it. Reads DCF_HOST_AUDIO (what
# the devcontainer-cli launcher did: wslg or none) only to explain. Never records anything.
# With wslg the workstation gates the microphone (ADR 0057): the socket exists only while the
# engineer has audio on, so a missing socket in a mounted /mnt/wslg is "off", not "not set up", and
# an `expires` file next to the socket (epoch seconds, written by the workstation's relay) gives the
# time left.
set -u

say() { printf 'audio: %s\n' "$*"; }
ready=1

# What to do about a missing socket, from what the launcher said it did.
launcher_hint() {
  case "${DCF_HOST_AUDIO:-}" in
    wslg) echo "the launcher mounted the workstation's relay directory when this container was created (DCF_HOST_AUDIO=wslg); a WSL restart drops that directory, and task devcontainer:up on the workstation redoes it (then task devcontainer:rebuild, a mount belongs to the container)" ;;
    none) echo "the launcher gave this container no audio (DCF_HOST_AUDIO=none): on a Windows WSL2 workstation set DCF_HOST_AUDIO=wslg in .devcontainer/.env and run task devcontainer:rebuild (a mount belongs to the container); the start's own warning says why when it was asked for" ;;
    *) echo "DCF_HOST_AUDIO is unset: the container was not started by the devcontainer-cli launcher (task devcontainer:up), or the repository's devcontainer.json does not pass it on (\"DCF_HOST_AUDIO\": \"\${localEnv:DCF_HOST_AUDIO}\" in containerEnv)" ;;
  esac
}

# 1. The tools. Each missing one is a line; the checks below still run where they can.
if ! command -v rec >/dev/null 2>&1; then
  say "missing: rec (package sox)"; ready=0
elif ! sox -h 2>/dev/null | grep -i 'AUDIO DEVICE DRIVERS' | grep -qw pulseaudio; then
  say "missing: SoX's PulseAudio backend (package libsox-fmt-pulse); rec cannot record from PulseAudio without it"; ready=0
fi
if ! command -v arecord >/dev/null 2>&1; then
  say "missing: arecord (package alsa-utils); recorders that try ALSA first fall back to rec"
fi
have_pactl=1
if ! command -v pactl >/dev/null 2>&1; then
  say "missing: pactl (package pulseaudio-utils); the server cannot be asked"; have_pactl=0; ready=0
fi

# 2. PULSE_SERVER.
if [ -z "${PULSE_SERVER:-}" ]; then
  say "no PULSE_SERVER: nothing tells a recorder where PulseAudio is (the audio Feature sets unix:/mnt/wslg/PulseServer; the repository's containerEnv may have emptied it)"
  exit 1
fi

# 3. The socket it names (a unix: address or a bare path; a tcp: server is asked directly).
sock=''
case "$PULSE_SERVER" in
  unix:*) sock="${PULSE_SERVER#unix:}" ;;
  /*) sock="$PULSE_SERVER" ;;
esac
if [ -n "$sock" ] && [ ! -S "$sock" ]; then
  if [ "${DCF_HOST_AUDIO:-}" = wslg ] && [ -d "$(dirname "$sock")" ]; then
    say "off (the workstation has not turned audio on): $sock is not there; on the workstation run task audio:on (task audio:on TTL=30m for longer), then try again; no rebuild is needed"
    exit 1
  fi
  say "socket not reachable: $sock (PULSE_SERVER=$PULSE_SERVER) is not there; $(launcher_hint)"
  exit 1
fi

# 4. PulseAudio answering, and a capture source.
if [ "$have_pactl" = 0 ]; then exit 1; fi
to=()
if command -v timeout >/dev/null 2>&1; then to=(timeout 10); fi
if ! "${to[@]}" pactl info >/dev/null 2>&1; then
  say "PulseAudio at $PULSE_SERVER does not answer (pactl info fails): the socket is there but nothing listens (with wslg the workstation's relay may just have ended: task audio:status there); $(launcher_hint)"
  exit 1
fi
sources="$("${to[@]}" pactl list sources short 2>/dev/null | awk '{ print $2 }' | grep -v '\.monitor$' || true)"
if [ -z "$sources" ]; then
  say "no capture source: PulseAudio at $PULSE_SERVER answers but offers only monitors of its outputs (no microphone); check that Windows has a microphone and lets desktop apps use it (Settings, Privacy and security, Microphone)"
  exit 1
fi

# The time left, when the workstation's relay says (a file beside the socket, only with wslg).
left=''
if [ "${DCF_HOST_AUDIO:-}" = wslg ] && [ -n "$sock" ] && [ -r "$(dirname "$sock")/expires" ]; then
  exp="$(head -n1 "$(dirname "$sock")/expires" 2>/dev/null | tr -cd '0-9')"
  now="$(date +%s)"
  if [ -n "$exp" ] && [ "$exp" -gt "$now" ]; then
    secs=$((exp - now))
    left=" (the workstation turned audio on; $((secs / 60))m$((secs % 60))s left)"
  fi
fi

if [ "$ready" = 1 ]; then
  say "ready: capture source $(printf '%s' "$sources" | head -n1) through $PULSE_SERVER$left"
  exit 0
fi
say "PulseAudio at $PULSE_SERVER has a capture source ($(printf '%s' "$sources" | head -n1)), but a tool above is missing"
exit 1
