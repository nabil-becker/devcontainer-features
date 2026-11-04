# ADR-0051: The Operator's OpenBao policy may start and cancel a root-token attempt, because OpenBao 2.7 needs it to make one from the shares

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-04 |
| **Deciders** | the Operator; proposed by the host session |

## Context

ADR-0050 rules that creating or deleting an OpenBao role needs a root token made from the unseal
shares (`generate-root`). Building it against a real OpenBao 2.7.2 showed that the unauthenticated
`sys/generate-root-token` endpoints are disabled there: starting an attempt needs a token with
access to those paths, or the server answers 403. Without a path for the Operator's token the
shares flow cannot start, and ADR-0050 cannot be carried out. Source: the hand-off of the
`openbao-local-storage` stream's policy change (real-server run) and the Operator's agreement of
2026-11-04.

## Decision

1. The Operator's policy holds read, update and delete on `sys/generate-root-token/attempt` and
   update on `sys/generate-root-token/update`, and nothing more on `sys/generate-root-token`.
2. Starting or cancelling an attempt is allowed with the Operator's token. Completing one still
   needs the unseal shares, so a root token cannot be made without them.
3. The task that makes a root token never cancels an attempt it did not start: it refuses, exits
   with a message and leaves the Operator to cancel it by hand.
4. ADR-0050 stands; this record adds the two paths it did not list.

## Options considered

### Option 1: add the two paths to the Operator's policy

The residual risk is that a stolen Operator token could start or cancel an attempt: a nuisance,
not an escalation, since the shares are still needed to finish. It wins because the alternative
makes role creation impossible on 2.7.2.

### Option 2: leave the paths out

Role creation and deletion cannot work on OpenBao 2.7.2. It lost.

### Option 3: make the root token some other way

Anything that avoids the shares would weaken the ruling in ADR-0048 that guards restore. It lost.

## Consequences

- Creating and deleting a role works on OpenBao 2.7.2 with the shares typed at the terminal.
- A server initialised with the earlier 1.2.0 build keeps the old, wider policy, because only
  `init` writes it and changing a policy now needs a root token. Unreleased, so likely moot; a
  note or task could help anyone who ran that build.

## Change log

| Date | Change |
|---|---|
| 2026-11-04 | First draft, accepted by the Operator's agreement of the same day. |
