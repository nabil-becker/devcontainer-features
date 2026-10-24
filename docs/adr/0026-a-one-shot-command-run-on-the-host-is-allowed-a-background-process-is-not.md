# ADR-0026: A one-shot command run on the host is allowed, a background process is not

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-24 |
| **Deciders** | the Operator; proposed by the host |

## Context

ADR-0024 decision 3 says no process of ours runs in the background on the host, which is why
`windows-docker` and `windows-wslc` have no forwarded SSH agent. The `ssh-agent` Feature (slice 4 of
`host-profile-contract`) still has to get keys to a container on those hosts, and the Operator wants
loading keys to be simple. Two tasks need the workstation's own tools for a moment: the host's
`ssh-add`, and reading a key file under the Windows profile to hand it to the container.

The Operator's ruling in the session, on the rule that work runs in the container rather than on the
host: a one-shot command run on the host is an acceptable exception, as long as it does not stay
running.

## Decision

A bootstrap task may run a one-shot command on the host: it starts, does its job and exits, and
leaves nothing running. Two come with the `ssh-agent` Feature:

1. `task dc:ssh-add -- <key>` runs the host's own `ssh-add` to load a key into the host's agent. On
   the hosts that forward the agent the container sees it at once; on `windows-wslc` it says the
   container cannot reach that agent and points to the next task.
2. `task dc:ssh-key-import FILE=<path>` reads the key on the host and streams it into the running
   container's key volume through standard input, never on a command line or in a log, then the
   in-container agent loads it.

ADR-0024 decision 3 stands: no relay, daemon or other background process on the host.

## Options considered

### Option 1: one-shot host tasks (chosen)

Gets keys into the container on every host type with nothing left running, so decision 3 of
ADR-0024 holds. The key travels over input, which a test checks.

### Option 2: keys loaded only from inside the container

The Operator would copy the key into the volume by hand. Simple for the code, but it leaves the
Windows path and the permissions to each person and loses the one-step route.

### Option 3: a host relay for the Windows agent

Rejected by ADR-0024 decision 3: a process that stays running.

## Consequences

- Loading a key is one command on every host type; the rest (signing setup, verify) is inside the
  container.
- The bootstrap now holds host-side commands that handle key material; their tests must show the
  key never reaches a command line.
- Any future host command is held to the same line: it must exit when done.

## Change log

| Date | Change |
|---|---|
| 2026-10-24 | Accepted: the Operator allowed the one-shot exception during slice 4. |
