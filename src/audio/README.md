
# Audio (microphone through the host's PulseAudio) (audio)

The audio tools a recorder in the container needs to reach the host's microphone through PulseAudio, such as Claude Code's /voice dictation: sox with its PulseAudio backend (libsox-fmt-pulse, so `rec` works), pulseaudio-utils (pactl), alsa-utils with libasound2-plugins and an ALSA default (/etc/asound.conf, only when absent or written by this Feature) that routes `default` to PulseAudio, so `arecord` works too. PULSE_SERVER is fixed at unix:/mnt/wslg/PulseServer, where the devcontainer-cli launcher mounts WSLg's PulseAudio socket on a Windows WSL2 host when the machine opts in (DCF_HOST_AUDIO=wslg in .devcontainer/.env). Installs from the distribution's apt sources only and never fails a build: a missing package manager or a failed install is a warning. `audio-check` (task audio:check) says plainly what is missing. Plus the Feature Taskfile.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/audio:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Also install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under the <id>: namespace of a root Taskfile that includes /usr/local/share/go-task/features.yml (see the go-task Feature). | boolean | true |
| alsaDefault | Write /etc/asound.conf so ALSA's default device is PulseAudio (arecord, and any recorder that opens ALSA's default, then reach PULSE_SERVER). Never replaces an /etc/asound.conf this Feature did not write. false leaves ALSA alone. | boolean | true |

## How it fits

```text
  Windows microphone
     |  WSLg (default WSL distro): /mnt/wslg/PulseServer
     |  launcher, DCF_HOST_AUDIO=wslg: bind to /mnt/wsl/wslg (shared by every WSL2 distro)
     v
  container: /mnt/wslg/PulseServer  <-- PULSE_SERVER (this Feature)
     |
     +-- rec (SoX + libsox-fmt-pulse)
     +-- arecord --> ALSA default --> pulse plugin (/etc/asound.conf)
     +-- pactl (audio-check asks it)
     v
  a recorder, e.g. Claude Code's /voice (its audio goes to its provider)
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| `/etc/asound.conf` (ALSA default to PulseAudio) | the image | 4 working set (rebuildable only) |
| Audio | streamed from the host's microphone; this Feature stores none | none |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: none yet

## What it installs

The tools a recorder in the container needs to reach a microphone through the host's
PulseAudio server, with Claude Code's `/voice` dictation in mind (on Linux its native audio module
comes first, then `arecord`, then SoX's `rec`; with WSLg, `rec` needs SoX's PulseAudio backend,
Claude Code's voice dictation documentation says so):

- `sox` and `libsox-fmt-pulse`: `rec` records from PulseAudio.
- `pulseaudio-utils`: `pactl`, which `audio-check` asks.
- `alsa-utils` and `libasound2-plugins`: `arecord`, and the ALSA plugin that hands ALSA's
  `default` device to PulseAudio.
- `/etc/asound.conf` (option `alsaDefault`): `pcm.!default` and `ctl.!default` of type `pulse`,
  so `arecord` and anything else that opens ALSA's default reach `PULSE_SERVER`. Written only when
  there is no `/etc/asound.conf`, or the one there starts with this Feature's marker line; any
  other file is left as it is, with one line in the build log.
- `/usr/local/bin/audio-check`, the check (below).
- `PULSE_SERVER=unix:/mnt/wslg/PulseServer` in `containerEnv`, the fixed path where the
  devcontainer-cli launcher mounts WSLg's socket. Feature metadata is static, so it is set whether
  or not a socket is mounted there; a repository that mounts another server sets its own
  `PULSE_SERVER` in `containerEnv`, which wins.

The packages come from the distribution's apt sources, which the distribution signs; nothing is
downloaded by hand, so there is no checksum of ours to verify. The Feature never fails a build:
without `apt-get` (a non-Debian image), or when the install fails, it prints a warning and goes on,
and `audio-check` names what is missing.

## Options

- `alsaDefault` (default `true`): write `/etc/asound.conf` as above. `false` leaves ALSA alone,
  for an image whose ALSA is configured on purpose; `arecord` then uses that configuration.
- `installTaskfile` (default `true`): installs the Taskfile below.

## State

None: no login, no config, no volume. Audio is streamed, never stored by the Feature.

## Turning it on (Windows with WSL2)

The Feature only installs tools. The microphone comes from the workstation, per machine, through
the devcontainer-cli launcher (`task devcontainer:up`):

1. In the workstation's `.devcontainer/.env`: `DCF_HOST_AUDIO=wslg`.
2. In the repository's `devcontainer.json`, `containerEnv`: `"DCF_HOST_AUDIO":
   "${localEnv:DCF_HOST_AUDIO}"` (the bootstrap's template has it), so the container knows what the
   launcher did.
3. `task devcontainer:rebuild`: a mount belongs to the container, so an existing one does not get it.

The launcher then binds the default WSL distro's `/mnt/wslg` to `/mnt/wsl/wslg` (shared by every
WSL2 distro, so the container engine's distro sees it) as root, and mounts `/mnt/wsl/wslg` at
`/mnt/wslg`. The devcontainer-cli notes ("Audio") say what happens on each host type and when it
says no.

## In devcontainer.json

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/audio:1": {}
},
"containerEnv": {
  "DCF_HOST_AUDIO": "${localEnv:DCF_HOST_AUDIO}"
}
```

## Checking that it works

```sh
task audio:check     # audio: ready: capture source RDPSource through unix:/mnt/wslg/PulseServer
```

`audio-check` prints one plain line per problem, in order, and exits 1 until all is well:

1. a missing tool: `rec`, SoX's PulseAudio backend, `pactl` (a missing `arecord` is a note only:
   recorders fall back to `rec`);
2. `no PULSE_SERVER`;
3. `socket not reachable: <path>`, with what to do from `DCF_HOST_AUDIO`: `wslg` (a WSL restart
   dropped the bind: `task devcontainer:up` redoes it), `none` (turn it on, then rebuild), unset
   (the container was not started by the launcher, or `devcontainer.json` does not pass it on);
4. PulseAudio does not answer;
5. `no capture source`: only monitors of outputs, no microphone (check Windows' microphone privacy
   setting for desktop apps).

It records nothing. Then, in Claude Code, `/voice`.

## Tasks

- `audio:version`: the versions of `sox`, `pactl` and `arecord`, and `PULSE_SERVER` and
  `DCF_HOST_AUDIO`.
- `audio:check`: `audio-check`, the verdict above.

## Pairs with

- `devcontainer-cli` 1.21.0 or later on the workstation (the launcher's `DCF_HOST_AUDIO`): it mounts
  the socket. Without it, the Feature installs the tools and `audio:check` says no socket is there.
- `go-task` for the tasks. `claude-code` for `/voice`, which needs a claude.ai sign-in.

## Privacy

With the launcher's `DCF_HOST_AUDIO=wslg`, every process in the container can open the workstation's
microphone while the container runs, as any Windows desktop app can. Claude Code's `/voice` streams
the recorded audio to Anthropic for transcription. Whether dictated audio may go to a model provider
is the consuming repository's ruling (its data rules), not this Feature's: the opt-in is per machine
on purpose, and a repository that must not send audio leaves the Feature out.

## Limits

- Proven on Rancher Desktop with WSL2 and WSLg (no `.wslconfig`); other engines and hosts are in the
  devcontainer-cli notes.
- Linux and macOS hosts: the launcher mounts nothing for audio yet. A repository can mount its own
  PulseAudio socket and set `PULSE_SERVER` itself.
- `RDPSource` is listed even when Windows denies desktop apps the microphone; the recording is then
  silent ("No audio detected" in Claude Code). `audio-check` cannot tell.
- apt-based images only; elsewhere the build warns and installs nothing.

## Why it exists

No published Feature brings the PulseAudio client side into a devcontainer, and the official images
carry no audio tools. Claude Code's `/voice` in a container on a WSL2 workstation needs exactly these
packages, the socket, and a way to say which of them is missing.

## Version and upgrade

Pin it with the Feature reference (`audio:1` or `:1.0.0`); an upgrade is a rebuild. The tool versions
are the distribution's, so they move with the base image.

## Changes

### [1.0.0] - 2026-11-06

#### Added

- First release: the audio tools a recorder in the container needs to reach the host's microphone through PulseAudio, such as Claude Code's `/voice`: SoX with its PulseAudio backend (`rec`), `pactl`, `arecord` with an ALSA default that routes to PulseAudio (option `alsaDefault`), and `PULSE_SERVER=unix:/mnt/wslg/PulseServer`, where the devcontainer-cli launcher 1.21.0 mounts WSLg's socket on a Windows WSL2 workstation that sets `DCF_HOST_AUDIO=wslg`. `task audio:check` says plainly what is missing. It never fails a build. Turning it on gives the container the microphone; whether dictated audio may go to a model provider is your repository's ruling.

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/audio/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/audio/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
