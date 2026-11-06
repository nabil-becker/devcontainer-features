# ADR-0058: An OpenBao SSH certificate authority signs for the Operator only, with roles of principal patterns

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-06 |
| **Deciders** | the Operator; proposed by the host |

## Context

Two consumers asked for an SSH certificate authority (openbao 1.6.0, pull request 184, backlog id
`openbao-ssh-ca`). AOF's packet-relay signs each stack instance's relay key so that the receiving
stack can trust it (AOF rulings D94 and D95). The KGO Office wants its register writer keys trusted
by one CA once per register, instead of every machine's key one by one. Both verify with stock
OpenSSH: `ssh-keygen -Y verify` against `cert-authority` lines, with expiry. The CA's private key
must live in OpenBao and never leave it (`src/openbao/NOTES.md`, "SSH certificate authority").

Forces recorded in the NOTES and the changelog:

- OpenBao matches a role's `allowed_users` exactly and has no wildcard, so a pattern such as
  `relay@<guid>` cannot be enforced by the server.
- In server mode, enabling a mount, writing the CA and writing a role are things the Operator's
  token may not do: a token that could write a role could widen it. The same shape already holds
  for `openbao:approle:issue` with a policy path.
- A certificate's key id ends up in records that can never be erased; OpenBao's default key id
  comes from the requesting token's name, which for a password login includes the user name.
- Agents run in the same container as the Operator's tools (ADR-0056 notes that any agent could
  harvest the key file's shares until agents run as their own Linux user).

## Decision

The CA is an `ssh` secrets engine at the mount `ssh-ca` (`MOUNT=` or `DCF_SSH_CA_MOUNT` name
another), with an ed25519 CA generated inside OpenBao.

1. **Only the Operator signs; agents are read-only.** The Operator's policy alone holds
   `ssh-ca/sign/*`, the CA's public key and the roles (list, read). The backs' AppRoles and an
   agent's token have no path there and get exit 13. `dcf-ssh-sign sign` is refused inside an
   agent's job (exit 3); `ca`, `ca --fingerprint`, `roles` and `status` are public reads and work
   in an agent's job. Ruled by the Operator.
2. **The signing role is named `default`** (`DCF_SSH_CA_ROLE` renames it). It is a role like any
   other, with the principal forms AOF uses, `relay@<guid>` and `fed-<guid>`; `ALLOWED=` overrides.
   Ruled by the Operator.
3. **A certificate's maximum lifetime is 90 days.** `TTL=` defaults to `2160h`, and `MAX_TTL=`
   defaults to the same value, so a longer certificate takes a conscious change. Ruled by the
   Operator.
4. **Two unseal shares set up the authority or a role.** In server mode `ca:init`, `ca:role` and
   `ca:import` use a root token made from two unseal shares typed at the hidden prompt, for that
   step alone and revoked after; a plain terminal, refused inside an agent's job. A re-run with
   everything in place needs no terminal and no shares. Against a server elsewhere they run with the
   token held, and the task prints the policy paths the server's owner adds. Ruled by the Operator.
5. **`ca:import` takes only an unencrypted ed25519 key**, from stdin only, never an argument. It is
   refused when the mount already has a CA: a CA is never replaced here. Ruled by the Operator.
6. **Settings come as environment variables** (`DCF_SSH_CA_MOUNT`, `DCF_SSH_CA_ROLE` and the task
   variables). Ruled by the Operator.
7. **Exact GUID forms.** A `<guid>` pattern token is exactly a lowercase 8-4-4-4-12 GUID with
   hex digits `0-9a-f`, nothing before or after it: no upper case, no short or long form. `<guid>`
   and `*` are the pattern syntax of every role. As committed to AOF and the KGO Office (ca84a92).
8. **No certificate names `operator`.** `ca:init` and `ca:role` refuse an `ALLOWED` that would admit
   the principal `operator` (`*`, `op*`, `operator`, in any capitalisation), and `sign` refuses it
   under any role, also a role made outside the task. The Operator's login is never a user a
   certificate can log in as.
9. **Key ids carry no names.** Every role sets `key_id_format` to
   `{{role_name}}-{{public_key_hash}}`, so a call with no key id puts no token name in a
   certificate. `sign` requires `--key-id` and cannot tell a name from an id, so a key id the
   caller passes must not carry a person's name: the caller's responsibility.
10. **Every role is narrow**: ed25519 subject keys only, user certificates only, host certificates
    off, no extensions, no critical options. A principal outside the named role is exit 13, so a
    relay certificate and a register certificate never stand in for each other.
11. **Where patterns are enforced.** A role of exact names is enforced by the server. A role with a
    `*` or a `<guid>` has `allowed_users: "*"` on the server, its patterns are kept in the KV store
    as `ssh-ca/roles/<role>`, and `dcf-ssh-sign` checks them before it signs. The boundary a
    verifier relies on is its own `cert-authority` line, which restricts the principals and names
    the namespace.
12. **Trust is set by a fingerprint compared out of band**, never because the key was found in a
    shared folder, a repository or a message.

## Options considered

### Option 1: the CA key inside OpenBao, signing by the Operator only, roles of patterns checked by `dcf-ssh-sign` (chosen)

The key never leaves OpenBao and verification is stock OpenSSH. It meets both consumers' asks (one
trust anchor, expiry) with the Operator's authority as the single signer. The cost is that a role
with a pattern is enforced by `dcf-ssh-sign` and the verifier's `cert-authority` line, not by the
server alone.

### Option 2: let agents sign

Rejected by the Operator: agents are read-only, they read public material and never sign. No other
reason is written in the PR or the NOTES.

### Option 3: rely on OpenBao's own `allowed_users` for every role

Not possible for patterns: OpenBao matches `allowed_users` exactly, with no wildcard (the PR body and
NOTES). It holds for roles of exact names, which the server does enforce.

### Option 4: OpenBao's default key id

Rejected: it builds the key id from the requesting token's name, which for a password login
includes the user name, and key ids end up in records that can never be erased (NOTES).

### Option 5: let the Operator's token write the CA and roles

Rejected: a token that could write a role could widen it (NOTES), so the shares-made root token is
used for those steps alone, as `openbao:approle:issue` with a policy path already does.

## Consequences

- Easier: a register or a stack trusts the CA once, by fingerprint; certificates expire by
  themselves (at most 90 days); an agent can read the CA key and roles but cannot mint a login.
- Harder: setting up the CA or a role needs two unseal shares at a plain terminal; a longer lifetime
  needs a conscious `MAX_TTL=`; a verifier must always write the principal restriction and the
  namespace in its `cert-authority` line (SSH namespaces are shared by everyone who signs with them,
  so the principal pattern is what restricts).
- A caller that goes round `dcf-ssh-sign` is the Operator, since only the Operator's token can sign.
- Nothing further is left open by the rulings; the reasons for rulings 2 to 6 are the Operator's.

## Change log

| Date | Change |
|---|---|
| 2026-11-06 | Created, accepted on the Operator's rulings for pull request 184. |
