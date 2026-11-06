## How it fits

```text
  Windows microphone
     |  WSLg (default WSL distro): /mnt/wslg/PulseServer   (never mounted in the container)
     |  workstation: task audio:on [TTL=15m]  -> socat relay, only for the TTL; task audio:off ends it
     |  launcher, DCF_HOST_AUDIO=wslg: /mnt/wsl/devhost-audio (a directory shared by every WSL2 distro)
     v
  container: /mnt/wslg/PulseServer  <-- PULSE_SERVER (this Feature); there only while audio is ON
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
- `DCF_AUDIO_FEATURE=1` in `containerEnv`: tells the root Taskfile that it is inside the container, where the
  workstation's `audio:on` and `audio:off` are left out.
- `PULSE_SERVER=unix:/mnt/wslg/PulseServer` in `containerEnv`, the fixed path where the
  devcontainer-cli launcher mounts the workstation's relay directory, in which the socket appears only
  while the workstation has audio on. Feature metadata is static, so it is set whether
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
the devcontainer-cli launcher (1.22.0 or later) and is off until you switch it on:

1. In the workstation's `.devcontainer/.env`: `DCF_HOST_AUDIO=wslg`. Install `socat` in the default WSL
   distro: `task audio:setup` on the workstation installs it (or `sudo apt-get install socat` there).
2. In the repository's `devcontainer.json`, `containerEnv`: `"DCF_HOST_AUDIO":
   "${localEnv:DCF_HOST_AUDIO}"` (the bootstrap's template has it), so the container knows what the
   launcher did. The root Taskfile includes the bootstrap's `audio.yml` (the template has it).
3. `task devcontainer:rebuild`: a mount belongs to the container, so an existing one does not get it. Once.

The launcher then makes the relay directory `/mnt/wsl/devhost-audio` in the default WSL distro (shared by
every WSL2 distro, so the container engine's distro sees it) as root, and mounts it, empty, at
`/mnt/wslg`. WSLg's own socket is never in the container. To dictate, on the workstation:

```sh
task audio:on            # 15 minutes; TTL=30m, 2h, 90s ...; at most DCF_HOST_AUDIO_TTL_MAX (2h)
task audio:status        # ON with the time left, or OFF
task audio:off           # ends it now; the socket file is gone from the container
```

Nothing in the container can turn it on or off, and neither needs a rebuild. The devcontainer-cli notes
("Audio") say what happens on each host type and when it says no.

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
task audio:check     # audio: ready: capture source RDPSource through unix:/mnt/wslg/PulseServer (the workstation turned audio on; 12m3s left)
```

`audio-check` prints one plain line per problem, in order, and exits 1 until all is well:

1. a missing tool: `rec`, SoX's PulseAudio backend, `pactl` (a missing `arecord` is a note only:
   recorders fall back to `rec`);
2. `no PULSE_SERVER`;
3. `off (the workstation has not turned audio on)`: `DCF_HOST_AUDIO=wslg`, `/mnt/wslg` is mounted and has
   no socket. Run `task audio:on` on the workstation; no rebuild. Not a fault, and distinct from
   `socket not reachable: <path>` ("not set up"), with what to do from `DCF_HOST_AUDIO`: `wslg` with no
   `/mnt/wslg` (a WSL restart dropped the relay directory: `task devcontainer:up` redoes it, then a rebuild),
   `none` (turn it on, then rebuild), unset (the container was not started by the launcher, or
   `devcontainer.json` does not pass it on);
4. PulseAudio does not answer;
5. `no capture source`: only monitors of outputs, no microphone (check Windows' microphone privacy
   setting for desktop apps).

It records nothing. Then, in Claude Code, `/voice`.

With the microphone off, `/voice` says it "could not find a working audio recorder" and suggests
installing SoX: the tools are installed, the gate is closed. Run `audio-check`; when it says `off`,
run `task audio:on` on the workstation and `/voice` again.

## Tasks

- `audio:version`: the versions of `sox`, `pactl` and `arecord`, and `PULSE_SERVER` and
  `DCF_HOST_AUDIO`.
- `audio:check`: `audio-check`, the verdict above.

## Pairs with

- `devcontainer-cli` 1.22.0 or later on the workstation (the launcher's `DCF_HOST_AUDIO` and
  `task audio:on`): it mounts the relay directory. Without it, the Feature installs the tools and
  `audio:check` says no socket is there. With 1.21.0 the socket is always there (no gate).
- `go-task` for the tasks. `claude-code` for `/voice`, which needs a claude.ai sign-in.

## Privacy

With the launcher's `DCF_HOST_AUDIO=wslg`, every process in the container can open the workstation's
microphone while the workstation has audio on (`task audio:on`, for 15 minutes unless told otherwise, at
most 2 hours by default; `task audio:off` ends it), as any Windows desktop app can, and none can while it
is off: the switch is on the workstation, outside the container, so nothing in the container can undo it. A
process in the container can read the `expires` file beside the socket (the time left) and nothing more.
Claude Code's `/voice` streams the recorded audio to Anthropic for transcription. Whether dictated audio may
go to a model provider is the consuming repository's ruling (its data rules), not this Feature's: the opt-in
is per machine on purpose, and a repository that must not send audio leaves the Feature out.

## Limits

- Proven on Rancher Desktop with WSL2 and WSLg (no `.wslconfig`); other engines and hosts are in the
  devcontainer-cli notes.
- Linux and macOS hosts: the launcher mounts nothing for audio yet. A repository can mount its own
  PulseAudio socket and set `PULSE_SERVER` itself.
- `RDPSource` is listed even when Windows denies desktop apps the microphone; the recording is then
  silent ("No audio detected" in Claude Code). `audio-check` cannot tell.
- The container cannot ask for audio itself (a flag for that was considered and not built: it needs a
  host process that is always running; see ADR 0057).
- apt-based images only; elsewhere the build warns and installs nothing.

## Why it exists

No published Feature brings the PulseAudio client side into a devcontainer, and the official images
carry no audio tools. Claude Code's `/voice` in a container on a WSL2 workstation needs exactly these
packages, the socket, and a way to say which of them is missing.

## Version and upgrade

Pin it with the Feature reference (`audio:1` or `:1.1.0`); an upgrade is a rebuild. The tool versions
are the distribution's, so they move with the base image.
