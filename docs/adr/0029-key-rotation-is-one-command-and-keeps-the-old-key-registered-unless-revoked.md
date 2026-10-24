# ADR-0029: Key rotation is one command, and it keeps the old key registered unless revoked

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-10-24 |
| **Deciders** | the Operator; proposed by the host |

## Context

The `ssh-agent` Feature's key mode keeps a signing key in a container volume, so the key sits where
the container's code can read it. The advice taken in was to use a dedicated key per purpose and per
container, to be able to retire it, and to be warned when a key is a default one or is also one of
the user's own. The Operator then asked for tooling that makes rotating easy.

Commits signed with a key verify on GitHub only while that key stays registered there. Deleting the
old key at rotation would silently turn every old commit from "verified" into unverified. A key
believed compromised is the opposite case: losing that mark is the point.

## Decision

Rotation is one task, `task ssh-agent:key:rotate`. It makes the new key and loads it with the old one
still loaded; registers it as a signing key through `gh` when `gh` is logged in (otherwise it stops
and prints the public key and the command to resume); points git signing at it and must pass a sign
and verify round trip; and only then retires the old key. A failed step stops the rotation and
removes nothing. `--plan` shows the steps without doing them.

Retiring keeps the old public key in a local `allowed_signers` history file, so old signatures keep
verifying locally, and does not delete the old key from GitHub. Removing it there is opt-in with
`REVOKE=1`. `key:retire` retires one key on its own, `key:age` lists each key's age, and
`ssh-agent:check` warns when a key is older than a limit (365 days by default, overridable).
`key:new` defaults to a dedicated name, `<repo>-<container>-sign`, and says to register it as a
signing key only. Warnings about a default key name, or an imported key that is also in the host's
`authorized_keys` or among its other `~/.ssh` keys, never block, so a deliberate choice still works;
the `authorized_keys` check runs only on the host side at import time, where `~/.ssh` is readable.

## Options considered

### Option 1: one command, old key kept on GitHub unless `REVOKE=1` (chosen)

History stays verifiable by default, and a compromised key can still be revoked with one flag.

### Option 2: a checklist in the NOTES

Cheap, but a step skipped halfway leaves two keys or none; the Operator asked for one command.

### Option 3: delete the old key from GitHub on every rotation

Tidy, but it strips the verified mark from all old commits, which a routine rotation should not do.

### Option 4: warnings that block a default or shared key

Rejected: a deliberate choice must still work, so these only warn.

## Consequences

- Rotation is safe to run routinely; a failure leaves the old key in place.
- A retired key stays registered on GitHub until someone revokes it; the backlog item
  `ssh-key-revoke-later` covers revoking one later.
- Not yet tried for real: whether git itself still verifies old commits after the old key is
  retired (only the signing tool's own check was tested), and how `gh ssh-key list` formats its
  output, which `REVOKE=1` relies on to find the key's id.
- The tests run without Docker, with `gh`, `ssh-keygen` and `git` replaced by stubs; the CI key-mode
  scenario also runs a rotation.
- Shipped as ssh-agent 1.1.0 with devcontainer-cli 1.10.0.

## Change log

| Date | Change |
|---|---|
| 2026-10-24 | First draft. |
