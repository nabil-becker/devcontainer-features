#!/bin/bash
# Auto-generated scenario: the audio Feature alone with default options on the base image. No
# host socket is mounted here, so audio-check must say so and fail; the tools must be in place.
# Run with:
#   devcontainer features test -f audio --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "rec is on PATH" command -v rec
check "sox has the PulseAudio backend" bash -c "sox -h | grep -i 'AUDIO DEVICE DRIVERS' | grep -qw pulseaudio"
check "pactl is on PATH" command -v pactl
check "arecord is on PATH" command -v arecord
check "the ALSA pulse plugin is installed" bash -c "ls /usr/lib/*/alsa-lib/libasound_module_pcm_pulse.so"
check "asound.conf routes the default to PulseAudio" grep -q 'pcm.!default { type pulse }' /etc/asound.conf
check "audio-check is installed and root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/audio-check)\" = root ]"
# shellcheck disable=SC2016  # expanded by the inner bash
check "PULSE_SERVER is the fixed path" bash -c '[ "$PULSE_SERVER" = unix:/mnt/wslg/PulseServer ]'
# shellcheck disable=SC2016  # expanded by the inner bash
check "DCF_AUDIO_FEATURE tells the root Taskfile it is inside" bash -c '[ "$DCF_AUDIO_FEATURE" = 1 ]'
check "audio-check fails with no socket mounted" bash -c "! audio-check"
check "audio-check names the missing socket" bash -c "audio-check | grep -q 'socket not reachable: /mnt/wslg/PulseServer'"
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/audio.yml

reportResults
