# ADR-0052: Onboarding hands over a claim token, the OpenBao Feature builds with `jq`, and PGP-encrypted shares are deferred

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-04 |
| **Deciders** | the Operator; proposed by the host session |

## Context

`openbao:onboard:export` makes a snapshot from a temporary second server for a new engineer, and
`openbao:onboard:claim` makes the restored store the receiver's own. Building the claim against a
real OpenBao 2.7.2 showed that `bao operator rotate-keys` needs a token on OpenBao 2.6 and later,
and a restored store holds only the sender's tokens, which the claim must not rely on. Three
decisions were open for the slice: how the claim gets a token, whether the Feature may depend on
`jq`, and whether the unseal shares are PGP-encrypted. The Operator agreed the host's
recommendations on 2026-11-04. Source: the hand-off of the onboarding slice and that agreement.

## Decision

1. The onboarding instance's root token is the claim token: `openbao:onboard:export` prints it
   once beside the fresh shares, the receiver gives it to `openbao:onboard:claim`, and the claim
   revokes it at the end.
2. `jq` is a build dependency of the `openbao` Feature.
3. PGP-encrypted shares are not part of this slice; the shares are printed once, as in the other
   share flows.

## Options considered

### Option 1: the onboarding instance's root token as the claim token

It exists only for the temporary server, is printed once, and dies with the claim. It wins
because the receiver needs no prior access and the sender's tokens are never reused.

### Option 2: a sender token carried in the snapshot

The receiver would hold something of the sender's through the claim. It lost: it defeats the
purpose of the claim, which revokes what the sender held.

### Option 3: no token, rotate-keys unauthenticated

Not possible on OpenBao 2.6 and later.

### `jq` and PGP

Parsing OpenBao's JSON in shell without `jq` is fragile; a build-time `jq` is small and pinned
like the other tools. PGP shares add key handling the Operator did not want in phase 1; they can
come in a later slice.

## Consequences

- The claim works on OpenBao 2.7.2 with the three things the receiver holds: the snapshot, the
  sender's two shares and the claim token.
- A claim token printed once and lost means a new export.
- The `openbao` Feature's build needs `jq`; the PGP deferral is a backlog candidate.

## Change log

| Date | Change |
|---|---|
| 2026-11-04 | First draft, accepted by the Operator's agreement of the same day. |
