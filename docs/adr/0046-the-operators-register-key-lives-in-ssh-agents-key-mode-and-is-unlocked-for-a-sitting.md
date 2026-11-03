# ADR-0046: The Operator's register key lives in ssh-agent's key mode and is unlocked for a sitting

| | |
|---|---|
| **Status** | superseded by ADR-0048 |
| **Date** | 2026-11-03 |
| **Deciders** | the Operator; proposed by the host |

## Context

The register (ADR 0043) is signed, and the Operator's key signs the acts only the Operator may
do, such as adding agents to the roster. This devhost has no forwarded SSH agent (Docker Desktop
on Windows has no socket to forward). The first route, backlog item `aof-signing-route`, kept the
key on the workstation and copied it into the container only for each signing. A consuming
repository asked for the same register and keeps its operator key in the `ssh-agent` Feature's
key mode: a passphrase-protected key in the Feature's volume, which the start hook never loads
(ssh-agent 1.2.0, `ssh-passphrase-wait`). The host had advised against key mode here because the
key then stays in the container; the Operator decided for it.

## Decision

The Operator's register key is kept in the `ssh-agent` Feature's key mode (`SSH_AGENT_MODE=key`
in the workstation's `.devcontainer/.env`). The key is imported once into the key volume with
`task devcontainer:ssh-key-import` and stays passphrase-protected there. The devhost installs
the `ssh-agent` Feature (`.devcontainer/devcontainer.json`). The Operator loads the key only for
an operator act and removes it from the agent afterwards. The copy-in route of `aof-signing-route`
is not used.

To make that one step, the `ssh-agent` Feature gains two generic tasks: `key:unlock NAME=<key>
[MINUTES=15]` loads a key with a lifetime (`ssh-add -t`), asks for the passphrase and says when it
drops out; `key:lock NAME=<key>` removes it at once. Both are key mode only. The devhost change
must work with either anchor setup (a committed anchors file or one in the volume).

## Options considered

### Option 1: key mode, unlocked for a sitting (chosen)

One import, no per-act copying, survives rebuilds, and the consumer already works this way, so
both repositories share one route. The passphrase is what keeps an agent from using the key: the
start hook never loads a protected key, and the timed unlock drops it by itself.

### Option 2: copy the key in for each signing

The key never rests in the container. It lost because every operator act repeats the copy and its
cleanup by hand, and the two repositories would differ.

## Consequences

- The key stays in the container's key volume across rebuilds, the trade-off the Feature's
  documentation names; the passphrase is the only guard against an agent using it.
- Operator acts need `key:unlock` first and `key:lock` after (or the timer).
- The consumer's own anchor tasks can be replaced by the Feature's generic ones.
- Open: the upper limit for `MINUTES` may come back as a decision; the `ssh-agent` change ships
  as a minor version bump after review.

## Change log

| Date | Change |
|---|---|
| 2026-11-03 | First draft. |
