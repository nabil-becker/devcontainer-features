# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

## [1.1.0] - 2026-11-06

### Added

- **The microphone is gated on the workstation** (with devcontainer-cli 1.22.0): the launcher no longer mounts WSLg's own directory at `/mnt/wslg` but an empty relay directory, so the real socket is never in the container, and the microphone is OFF until the engineer runs `task audio:on` on the workstation (default 15 minutes, `TTL=<duration>`, at most 2 hours), which starts a relay for that long; `task audio:off` ends it at once. When it ends, the socket file is gone. No process in the container can switch it on or off, and neither needs a rebuild. `audio-check` says `off (the workstation has not turned audio on)` when `/mnt/wslg` is mounted and has no socket, distinct from the `socket not reachable` (not set up) line, and with the audio on it adds the time left.
- A note that with the microphone off, Claude Code's `/voice` blames a missing recorder and suggests installing SoX; `audio-check` says `off`, and `task audio:on` is the fix.
- `DCF_AUDIO_FEATURE=1` in `containerEnv`, which the bootstrap's root Taskfile reads to leave the workstation's `audio:on`, `audio:off` and `audio:status` out inside the container.

### Changed

- **Act:** upgrade the workstation's launcher to devcontainer-cli 1.22.0 (re-run the bootstrap), then `task devcontainer:up` and, once, `task devcontainer:rebuild` so the container gets the relay directory instead of WSLg's own. With the older launcher (1.21.0) the microphone stays always on, as in 1.0.0. The privacy line changes from "while the container runs" to "while the workstation has audio on".

## [1.0.0] - 2026-11-06

### Added

- First release: the audio tools a recorder in the container needs to reach the host's microphone through PulseAudio, such as Claude Code's `/voice`: SoX with its PulseAudio backend (`rec`), `pactl`, `arecord` with an ALSA default that routes to PulseAudio (option `alsaDefault`), and `PULSE_SERVER=unix:/mnt/wslg/PulseServer`, where the devcontainer-cli launcher 1.21.0 mounts WSLg's socket on a Windows WSL2 workstation that sets `DCF_HOST_AUDIO=wslg`. `task audio:check` says plainly what is missing. It never fails a build. Turning it on gives the container the microphone; whether dictated audio may go to a model provider is your repository's ruling.
