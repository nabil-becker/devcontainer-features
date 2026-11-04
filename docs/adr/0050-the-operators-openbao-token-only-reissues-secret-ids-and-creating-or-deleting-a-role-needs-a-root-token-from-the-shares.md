# ADR-0050: The Operator's OpenBao token only reissues secret ids, and creating or deleting a role needs a root token made from the shares

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-04 |
| **Deciders** | the Operator; proposed by the host session |

## Context

ADR-0048 puts every secret in OpenBao and rules that a restore needs a root token made from the
unseal shares, because `snapshot-force` is not in the Operator's policy. The first server-mode
build gave the Operator's userpass token more than that: create, update and delete on
`auth/approle/role/*` and on `sys/policies/acl/approle-*`, so that `approle-issue` and
`approle-revoke` could run without the shares.

A token that can write any policy can write one that holds `snapshot-force`, then log in through a
role that carries it. That sidesteps the ruling that guards restore. Source: the Rulings (ruling 3)
in `docs/proposals/secrets-master-split.md` and the Operator's decision on the draft pull request
of the `openbao-local-storage` stream.

## Decision

1. **The Operator's own token (userpass login) may only reissue secret ids for roles that already
   exist**: list roles, read a role's role-id, list secret-id accessors, destroy secret ids by
   accessor, and create a new secret id. It has no access to `sys/policies/acl/*` and cannot
   create, update or delete a role.
2. **Creating a role** (`approle-issue` with a policy file, which writes the `approle-<role>`
   policy and the role) **and deleting one** (`approle-revoke`) **need a root token made from the
   unseal shares** (`generate-root`), used for that step only and revoked straight after, also on
   failure.
3. Shares and the root token are never echoed, logged or written to disk. Both steps refuse inside
   an agent's job, like every task that handles a share or a token.
4. Reissuing for one role or all roles keeps working with the Operator's token alone.
5. Alongside, as built: `seal` refuses inside an agent's job, and server mode requires OpenBao
   2.4.0 or later.

## Options considered

### Option 1: narrow the policy to reissue; role create and delete use a root token from the shares

Nothing the Operator's token holds can widen what any token may do, so ruling 3 stays whole. The
cost is a shares prompt on the two rare steps. This wins.

### Option 2: keep policy and role write in the Operator's policy

Convenient (no shares for a new role), but a policy writer can grant itself or a role
`snapshot-force`. It lost.

### Option 3: let an agent identity create roles

Puts a share-free path to policy writing in reach of an agent's job. It lost.

## Consequences

- Day-to-day reissue stays a single login; adding or removing a role is a deliberate step the
  Operator does with the shares at the terminal.
- The Feature's docs and task descriptions say which steps ask for the shares.
- ADR-0048 is not edited; this record carries ruling 3 over from restore to role create and delete.

## Change log

| Date | Change |
|---|---|
| 2026-11-04 | First draft, accepted by the Operator's ruling of the same day. |
