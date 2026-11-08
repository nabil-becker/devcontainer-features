# ADR-0058: The microphone is gated by a workstation relay with a TTL and is off by default

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-06 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR-0057 passes WSLg's folder into the container, so with `DCF_HOST_AUDIO=wslg` every process in
the container can reach the Windows microphone for as long as the container runs. An engineer who
opts in wants the microphone reachable only while they are dictating, and turning it on or off must
not need a rebuild. Any gate inside the container (suspending the source with `pactl`, a `chmod`
on the socket, an environment variable) can be undone by a process in the container, so it is no
gate. The `ssh-agent` Feature's Windows relay (ADR-0048) is prior art for a host-side relay.

## Decision

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

## Options considered

### Option 1: a relay on the workstation, bounded by a TTL (chosen)

The gate sits outside the container, so nothing inside can open it; no rebuild is needed to switch.

### Option 2: a gate inside the container

Rejected: a container process can undo it.

### Option 3: mount WSLg as ADR-0057 did and rely on the engineer's discipline

Leaves the microphone reachable for the container's whole life; the problem this decision removes.

## Options considered for the container-side request

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

## Consequences

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
| 2026-11-06 | First draft; accepted, the Operator decided the workstation is authoritative. |
| 2026-11-06 | The decision as built (devcontainer-cli 1.22.0, audio 1.1.0), moved here from the amendment to ADR-0057; the container-side request is not built. |
