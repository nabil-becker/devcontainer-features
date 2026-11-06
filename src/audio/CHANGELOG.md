# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

## [1.0.0] - 2026-11-06

### Added

- First release: the audio tools a recorder in the container needs to reach the host's microphone through PulseAudio, such as Claude Code's `/voice`: SoX with its PulseAudio backend (`rec`), `pactl`, `arecord` with an ALSA default that routes to PulseAudio (option `alsaDefault`), and `PULSE_SERVER=unix:/mnt/wslg/PulseServer`, where the devcontainer-cli launcher 1.21.0 mounts WSLg's socket on a Windows WSL2 workstation that sets `DCF_HOST_AUDIO=wslg`. `task audio:check` says plainly what is missing. It never fails a build. Turning it on gives the container the microphone; whether dictated audio may go to a model provider is your repository's ruling.
