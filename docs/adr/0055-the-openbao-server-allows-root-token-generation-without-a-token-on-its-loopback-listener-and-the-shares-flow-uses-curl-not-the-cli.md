# ADR-0055: The OpenBao server allows root-token generation without a token on its loopback listener, and the shares flow uses curl, not the CLI

| | |
|---|---|
| **Status** | proposed |
| **Date** | 2026-11-05 |
| **Deciders** | the Operator; proposed by the host session |

## Context

ADR-0050 and ADR-0051 make a root token from the unseal shares (`generate-root`), and ADR-0051
lets the Operator's token start and cancel the attempt, because OpenBao 2.6 and later refuse an
unauthenticated start with a 403. The consequence showed up with `task openbao:password`: it works
only while the Operator's saved login lives (at most 8 hours). A forgotten password with no live
login is a lock-out, since the shares unseal the server but nothing can log in. The key-file
proposal (`docs/proposals/openbao-key-file.md`) has the same gap in its recovery path.

The Operator ruled on 2026-11-05 to test allowing root-token generation without a token, on the
container's loopback listener only. The test ran on real OpenBao 2.7.2 with throwaway servers:

- The option is `disable_unauthed_generate_root_endpoints`, a listener option (in `listener "tcp"`
  and `listener "unix"`), true by default since 2.5.3; with it true the legacy
  `sys/generate-root/*` endpoints answer 405. A restart applies a change, a SIGHUP does not.
- With it false, two of three shares make a root token with no token anywhere, and that token
  resets a userpass password.
- The `bao` CLI cannot do it: since 2.6.0 `bao operator generate-root` calls only the authenticated
  `sys/generate-root-token`, so every call gets a 403 without a token, whatever the setting.
- An unauthenticated caller can read the attempt status (never the encoded token), start an attempt
  and cancel any attempt. It cannot feed a share with a wrong nonce, start a second attempt,
  complete one without shares, or use a token from an attempt it did not start (the one-time
  password is missing).
- The option is per listener; a dedicated `listener "unix"` (mode 0600, TCP left at the default)
  works, with limits: `socket_mode` needs `socket_user` and `socket_group`, and the socket path
  must stay under about 108 characters.

## Decision

1. The openbao Feature writes `disable_unauthed_generate_root_endpoints = false` in the server's
   loopback `listener "tcp"` block. Rekey stays off.
2. The shares flow (`as_root` in `openbao-server.sh`) calls the legacy `sys/generate-root/*`
   endpoints with `curl` and no token, and decodes the token in bash. This is a deliberate step
   past NFR-13 ("manage the environment, not the CLI"), because the CLI has no way to reach these
   endpoints.
3. Shares are read with the hidden prompt and sent on stdin only; the one-time password comes from
   the server and is in no argument. An attempt already in progress is refused, not taken over.
4. On a 405 (a config without the marker line) the flow falls back to the CLI path, which needs the
   login and exits 12 naming the option. The two policy paths of ADR-0051 stay for that fallback.
5. `password`, `backup:role` and `restore` onto a store in use need no login. `approle:issue` and
   `approle:revoke` still do.
6. Whether the setting moves to a dedicated unix-socket listener, and whether the CLI fallback and
   with it ADR-0051's policy paths are dropped, are open and need the Operator's ruling.

## Options considered

### Option 1: allow unauthenticated generate-root on the loopback listener

Two shares alone can make a root token, so a forgotten password is recoverable with no login.
Completing an attempt still needs the shares, so an unauthenticated process can only start or
cancel one: a nuisance, not a breach. It wins for that reason.

### Option 2: keep requiring a token

Keeps the listener closed, but a forgotten password with no live login stays a lock-out, and the
key-file recovery path stays broken. It lost.

### Option 3: a dedicated unix-socket listener for the setting

Keeps a forwarded port 8200 from reaching these endpoints; tested and working. It does not keep out
agents, which run as the same user, and a long state-dir path would stop the server starting. Left
open for the Operator.

## Consequences

- A forgotten password is recoverable from two shares with no login.
- Any process able to reach the loopback port can start or cancel an attempt; a forwarded port
  widens that. Nothing more, since the shares are needed to finish.
- OpenBao has called these endpoints deprecated since 2.6.0; no removal is announced. A removal
  would break the flow, so a check on a pinned-version bump (for example in `server_mode.sh`) should
  fail loudly (backlog).
- A config that still carries the marker line is rewritten on every container start and gets the
  option with a rebuild; a config without it needs the line and a restart by hand, until then the
  tasks use the login as before. The openbao CHANGELOG says so.
- ADR-0051 is not superseded: its policy paths still serve the fallback.

## Change log

| Date | Change |
|---|---|
| 2026-11-05 | First draft, proposed: the Operator ruled to test option 1; the test passed, two points are open. |
