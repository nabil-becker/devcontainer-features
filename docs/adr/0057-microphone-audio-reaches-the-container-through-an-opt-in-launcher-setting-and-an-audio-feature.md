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
   directory the workstation gates, not WSLg's own directory; see "Amendment: the workstation gates
   the microphone" below.)
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

*2026-11-06, backlog item `audio-gate-ttl`; the Operator decided: "Let's do workstation for now."*

### Context

As built (devcontainer-cli 1.21.0, audio 1.0.0) the microphone was reachable by every process in
the container for as long as the container ran. A container is where agents and their tools run, so
"opted in" is too coarse: the engineer wants the microphone reachable only while dictating. A gate
inside the container (`pactl suspend`, `chmod` on the socket, an environment variable) is ruled
out: a container process could undo it. The gate has to be on the host side.

### Decision

1. The workstation is authoritative and the microphone is OFF by default. With
   `DCF_HOST_AUDIO=wslg` the launcher mounts, at `/mnt/wslg`, a relay directory
   `/mnt/wsl/devhost-audio/` of the default WSL distro (shared by every WSL2 distro), created empty
   at `up`. WSLg's own socket is never mounted.
2. `task audio:on [TTL=<duration>]` starts a `socat` relay in the default distro, as root through
   `wsl.exe`, from `/mnt/wsl/devhost-audio/PulseServer` to `/mnt/wslg/PulseServer`, under
   `timeout`: the relay is a process of the WSL distro (not of Windows), it ends by itself when the
   duration does, and the socket file is gone when it ends. The default is `DCF_HOST_AUDIO_TTL`
   (15m); the longest is `DCF_HOST_AUDIO_TTL_MAX` (2h), and a longer request is cut to it with a
   line saying so. `task audio:off` ends the relay at once, `task audio:status` says on (with the
   time left) or off. The relay writes `expires` (epoch seconds) beside the socket.
3. In the container, `audio-check` says `off (the workstation has not turned audio on)` when
   `/mnt/wslg` is mounted without the socket (distinct from "not set up", the socket missing from a
   container started without the launcher's mount), and "ready" with the time left when it is on.
4. Turning audio on or off never needs a rebuild; the mount changes once, when a repository moves
   from launcher 1.21.0 to 1.22.0 (one rebuild).
5. **The container-side request is not built.** The Operator also asked for "maybe a flag to
   'allow start from inside the container'": an opt-in setting (for example
   `DCF_HOST_AUDIO_ALLOW_CONTAINER=1`), off by default, that lets the container ask for audio on
   with a TTL capped by the same maximum, the workstation still winning. The condition set was to
   build it only if it needs no always-running host process. It does: a request written in the
   container is a file or a message, and something on the workstation has to be waiting for it. The
   options are in the pull request under "Decisions needed". Slice 1 (items 1 to 4) ships alone.

### Options considered for the container-side request

- **A watcher in the default WSL distro** (a loop or `inotifywait` on a request file in the relay
  directory, started at `up`): no Windows process, but a process that runs for as long as WSL does,
  which ADR-0026 does not allow in the launcher's own terms and which breaks "nothing is running
  unless the engineer started it". The request file is written by the container, so the watcher
  would also have to be as trusted as the gate it opens.
- **An always-listening socat on a request socket**: the same, and a second socket in the container.
- **A TTL-bounded standing permission**: `task audio:on` could instead start a relay that is
  *always* a socket, with the container asking for "unmute" by a request that the relay itself
  honours. Then the relay is the daemon, running for the TTL, not for ever: the gate moves into
  the relay, so the relay must be trusted not to be talked into more than its TTL. Possible, and
  the nearest to the flag, but it is a protocol and a longer review than this slice.
- **Not building it** (chosen): the engineer types `task audio:on`, one command, on the machine
  the microphone is on. Recommendation: wait for a real need, since the cost is a command on the
  workstation, and if it comes, take the third option with the maximum as a hard cap.

### Consequences

- The privacy line becomes "any process in the container can record while the workstation has
  audio on", and none can while it is off.
- The launcher gains a workstation task family (`audio:on`, `:off`, `:status`) and a `socat`
  dependency in the default WSL distro; `audio on` says when socat or WSLg is missing.
- The first real run is on the Operator's workstation: whether WSL keeps the relay alive for the
  whole duration once `wsl.exe` has returned, `socat` in the default distro, a container seeing a
  socket made after it started, Docker Desktop's engine seeing `/mnt/wsl/devhost-audio`.

## Change log

| Date | Change |
|---|---|
| 2026-11-06 | First draft; accepted, the Operator approved the design. |
| 2026-11-06 | `PULSE_SERVER` comes from the Feature, not the launcher, as built. |
| 2026-11-06 | Amended (audio-gate-ttl): the workstation gates the microphone with a relay directory and a TTL; the container-side request is not built. |
