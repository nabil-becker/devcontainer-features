# ADR-0038: One cloud-folder login task finds out where it runs and opens the sign-in port only while signing in

| | |
|---|---|
| **Status** | proposed |
| **Date** | 2026-10-29 |
| **Deciders** | the Operator; proposed by the host |

## Context

The `cloud-folder` Feature signs in to OneDrive with `rclone authorize`, an OAuth flow. Microsoft
returns the browser to `http://localhost:53682/?code=...`, where rclone listens. Inside the
container that is the container's localhost, but the browser runs on the workstation, and our
launcher (`devcontainer up`) forwards no ports, so the redirect reaches nothing. The Feature's notes
told people to run `authorize` on a machine with a browser. The port number cannot change: rclone's
own app registration accepts exactly that one return address, and another port needs the
consumer's own app registration.

The first attempt at the manual route also showed a trap: a checksum check written in PowerShell
compared against an empty expected sum (the sums file came back as bytes), and a `throw` typed at
the prompt did not stop the next line, so an unverified archive was extracted. A scripted, correct
check is part of the answer.

The Operator asked that the sign-in work from the container, that the port be opened and closed on
demand, that people who do not need the workstation route not have to use it, and that it be the
same task wherever it runs.

## Decision

There is one task, `task cloud-folder:login`, that works out where it is running:

- **In the container** it prints the sign-in URL and takes a pasted-back value: the failed
  `localhost:53682/...` address from the browser, or a token from a workstation rclone. This is the
  default and needs nothing on the workstation.
- **On the workstation** it listens on `localhost:53682` only for the length of the sign-in, opens
  the browser, passes the redirect into the container through `docker exec` (bash's built-in TCP,
  no socat, no port mapping), and closes the port when sign-in finishes, fails or times out. If the
  port is busy it falls back to paste-back.
- **`--workstation-rclone`** fetches the pinned rclone, checks it against the published sums read
  as text, and runs `authorize` on the workstation.

No port is added to `devcontainer.json`. If the same task name cannot be offered cleanly on both
sides (the container's root Taskfile includes both the launcher's and the Features' tasks), the
fallback is `task devcontainer:cloud-folder-login` on the workstation. It ships as cloud-folder
1.3.0 and devcontainer-cli 1.16.0.

## Options considered

### Option 1: one task with three routes, the port opened by the launcher only during sign-in

Nothing stays open, nothing changes in `devcontainer.json`, and each person uses only the route
they need.

### Option 2: forward port 53682 in `devcontainer.json`

Keeps the container self-contained, but Docker cannot add a mapping to a running container, the port
stays open for the container's life, and every consumer carries it whether or not they sign in.

### Option 3: a different port, or dynamic port

Refused by Microsoft for rclone's app registration; needs a per-consumer Azure app registration.

### Option 4: only the manual workstation `rclone authorize`

Works, but is the checksum-and-version trap the bootstrap should hide.

## Consequences

- Sign-in works from the container with no workstation setup; the workstation route is opt-in.
- The paste-back route is not yet tested against Microsoft's real flow; the first real sign-in is
  the check.
- The launcher gains a short-lived listener, which ADR-0026 allows as a one-shot command, not a
  background process.
- The workstation bootstrap with a verified download is backlog item `cloud-folder-authorize-task`.

## Change log

| Date | Change |
|---|---|
| 2026-10-29 | First draft. |
