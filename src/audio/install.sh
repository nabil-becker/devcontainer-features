#!/usr/bin/env bash
# Installs the audio tools a recorder in the container needs to reach the host's microphone
# through PulseAudio (see NOTES.md): sox and its PulseAudio backend, pactl, arecord with the ALSA
# PulseAudio plugin, an ALSA default that routes to PulseAudio, and audio-check. Everything comes
# from the distribution's apt sources (signed by the distribution), so nothing is downloaded by
# hand and there is nothing to pin. It never fails a build: a missing apt-get or a failed install
# is a warning, and audio-check later says what is missing. Feature options arrive as upper-cased
# environment variables (see devcontainer-feature.json): ALSADEFAULT, INSTALLTASKFILE.
set -euo pipefail

ALSADEFAULT="${ALSADEFAULT:-true}"
packages=(sox libsox-fmt-pulse pulseaudio-utils alsa-utils libasound2-plugins)
# The first line of an /etc/asound.conf this Feature wrote; only such a file is replaced.
marker='# Written by the audio Feature (devcontainer-features): ALSA default -> PulseAudio.'

if [ "$(id -u)" -ne 0 ]; then
  echo "audio: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"

if command -v apt-get >/dev/null 2>&1; then
  if DEBIAN_FRONTEND=noninteractive apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${packages[@]}"; then
    echo "audio: installed ${packages[*]}"
  else
    echo "audio: WARNING - apt-get could not install ${packages[*]}; the build goes on, and audio-check names what is missing." >&2
  fi
  rm -rf /var/lib/apt/lists/*
else
  echo "audio: WARNING - no apt-get on this image; install ${packages[*]} (or your distribution's names for them) yourself. The build goes on." >&2
fi

if [ "$ALSADEFAULT" = true ]; then
  if [ ! -e /etc/asound.conf ] || head -n1 /etc/asound.conf | grep -qxF -- "$marker"; then
    printf '%s\n%s\n%s\n' "$marker" 'pcm.!default { type pulse }' 'ctl.!default { type pulse }' > /etc/asound.conf
    chmod 0644 /etc/asound.conf
    echo "audio: /etc/asound.conf routes ALSA's default to PulseAudio"
  else
    echo "audio: /etc/asound.conf exists and was not written by this Feature; left as it is (arecord uses its default)."
  fi
fi

install -m 0755 "$feature_dir/audio-check.sh" /usr/local/bin/audio-check
echo "audio: audio-check installed; sox $(sox --version 2>/dev/null | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p' | head -n1 || true)"

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/audio.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
