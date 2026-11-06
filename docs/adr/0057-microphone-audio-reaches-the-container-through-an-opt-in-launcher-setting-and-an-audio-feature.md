# ADR-0057: Microphone audio reaches the container through an opt-in launcher setting and an `audio` Feature

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-06 |
| **Deciders** | the Operator; proposed by the host |

## Context

Claude Code's `/voice` records with `arecord` and falls back to SoX, so a container needs a
PulseAudio source. On a Windows workstation WSLg offers the microphone as `RDPSource`, but the
container engine of the Rancher distro does not see `/mnt/wslg`. The route was proven on
2026-11-06: with the default distro bind-mounting `/mnt/wslg` onto `/mnt/wsl/wslg` (a folder the
Rancher distro shares), a container that mounts `/mnt/wsl/wslg` at `/mnt/wslg` and sets
`PULSE_SERVER=unix:/mnt/wslg/PulseServer` lists `RDPSource`. The bind is lost when WSL restarts.
Passing the microphone in gives the container the Operator's microphone and needs a root `mount`
in the default distro, so it must not happen silently. ADR-0024 makes the launcher the one place
that knows the host and exposes it as `DCF_HOST_*` variables; ADR-0031 set the precedent of the
launcher acting on request.

## Decision

1. A new `audio` Feature in `src/` installs SoX with its PulseAudio format library,
   `pulseaudio-utils` and an ALSA default that routes to PulseAudio, and sets
   `PULSE_SERVER=unix:/mnt/wslg/PulseServer` in its `containerEnv` (as `ssh-agent` sets
   `SSH_AUTH_SOCK`: `devcontainer up` cannot set a container variable, and a `${localEnv:...}` line
   in every consumer would set an empty value where nobody asked). It works on any host and never
   fails a build; `task audio:check` reports what is missing, in order: no `PULSE_SERVER`,
   socket not reachable, no microphone source.
2. The launcher (`devcontainer-cli`), only on WSL-backed Windows host types, shares WSLg into
   `/mnt/wsl/wslg` from the default distro before each start (skipped when already shared), adds
   the mount at `/mnt/wslg`, and reports the result as
   `DCF_HOST_AUDIO`, as it does for the SSH socket. (Amended on 2026-11-06: the mount is a relay
   directory the workstation gates, not WSLg's own directory; see ADR-0058.)
3. It is opt-in and off by default: `DCF_HOST_AUDIO=wslg` in `.devcontainer/.env`. Without it the
   launcher changes nothing. If WSLg is absent the launcher warns and starts without audio; it
   never fails the start.
4. Whether dictated audio may go to the model provider is a ruling for each consuming repository,
   not this collection.

## Options considered

### Option 1: an `audio` Feature plus an opt-in launcher setting (chosen)

Keeps the container side portable and the host side in the launcher, the one place that knows the
host (ADR-0024); the microphone and the root `mount` happen only when the Operator asks.

### Option 2: the launcher shares audio on every start

Simpler to use, but it hands the microphone to every container and runs a root `mount` in the
default distro for everyone, silently. Lost on privacy and blast radius.

### Option 3: a Feature alone, with the host steps left to a consumer's script

The host bind is lost on every WSL restart, so each consumer would script around it: a local
workaround, which this collection treats as a gap to close.

## Consequences

- A consumer gets voice input with one line in `.devcontainer/.env` and the `audio` Feature.
- The launcher change reaches every consumer's start, so it must change nothing for anyone who
  does not opt in; it is released as a minor `devcontainer-cli` version.
- The real Windows launcher cannot be run from the devhost, so the first real test is on the
  Operator's workstation.
- Each consuming repository decides whether dictated audio may go to the model provider.

## Amendment: the workstation gates the microphone

Refined by [ADR-0058](0058-the-microphone-is-gated-by-a-workstation-relay-with-a-ttl-and-is-off-by-default.md)
(2026-11-06, `audio-gate-ttl`): the launcher mounts a relay directory the workstation gates with
`task audio:on TTL=<duration>`, not WSLg's own directory, and the microphone is off by default.

## Change log

| Date | Change |
|---|---|
| 2026-11-06 | First draft; accepted, the Operator approved the design. |
| 2026-11-06 | `PULSE_SERVER` comes from the Feature, not the launcher, as built. |
| 2026-11-06 | Amended (audio-gate-ttl): the workstation gates the microphone with a relay directory and a TTL; recorded in ADR-0058. |
