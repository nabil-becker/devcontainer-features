# ADR-0062: sign-packet, register-engine and packet-relay move here from AOF, and each carries its own copy of the signing library

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-19 |
| **Deciders** | the Operator (the move, the three Features, the version lines, the MIT licence, the merge order); proposed by the host (the standalone install) |

## Context

The register this devhost runs on (`local-features/agentic-register`) is vendored from the
private AOF repository, so a downloaded Feature cannot pull it. Facilitator decision 3 (ADR-0061),
"make the register installable", needs the register, and the signed messages it carries, to be
pullable from GHCR by an engineer's devcontainer.

The Operator decided on 2026-11-19 to take over the Features that AOF's tooling holds and publish
them from this repository. They named five (sign-packet, register-engine, agentic-register,
packet-relay, agentic-a2a), then narrowed the first move to three: sign-packet, register-engine
and packet-relay. agentic-register and agentic-a2a stay out for now, so the devhost and the seed
keep their vendored register unchanged.

AOF published every version on its main to a private registry, so these version numbers already
exist there. AOF has no licence file; this repository is MIT and carries DCO sign-offs. AOF's
ADR numbers clash with this repository's, so the moved text names them "AOF ADR nnnn".

The Features' own rule ("Adding a Feature", step 3) allows no dependence on a sibling Feature's
files at install time. In AOF, register-engine and packet-relay needed sign-packet beside them or
a sibling-installer trick.

## Decision

sign-packet, register-engine and packet-relay live in `src/` here, one topic branch and one pull
request each, taken from AOF commit `d45b11ec`.

register-engine and packet-relay each carry a verbatim copy of sign-packet's library and install
it into their own lib folder, so each installs alone. `task signpacket:check` (in lint) fails when
a copy differs from `src/sign-packet`, and `task signpacket:sync` refreshes the copies.

Each Feature keeps its AOF version line and bumps the minor (sign-packet 0.6.0, register-engine
0.3.0, packet-relay 0.4.0) rather than restarting at 1.0.0, because AOF ADR 0024 reserves 1.0 for
a break of the format or the command, and a stack on the AOF package then changes only the
registry path. Their `dcf-persist` goes to `/usr/local/libexec/<id>/` and their volumes keep the
`<id>-state-` names, so containers that ran the AOF package keep their state.

No agentic-register code is moved: register-engine has only the `log` type, and the `messages`
type stays with agentic-register.

## Options considered

### Option 1: three Features, each with its own verbatim copy of the signing library

Each installs alone, in line with step 3 of "Adding a Feature". The cost is three copies, held in
line by a lint check.

### Option 2: depend on sign-packet through `dependsOn` or a sibling installer

One copy only. It lost because the Feature install must not rely on another Feature's files, and
the sibling-installer trick is ruled out by the same step.

### Option 3: take all five Features at once

Closes decision 3 fully. It lost because the Operator narrowed the scope, and replacing the
register under the devhost and the seed reaches every consumer.

### Option 4: restart the version lines at 1.0.0

A clean start here. It lost because it breaks the AOF rule for 1.0 and the path-only switch for
existing stacks.

## Consequences

- The three Features are published from GHCR by the release the Operator started on 2026-11-19:
  sign-packet 0.6.0, register-engine 0.3.0 and packet-relay 0.4.0 (#194, #195, #196).
- The three pull requests touch the same lines (CI matrices, `_global` lists and count, the
  Features table, the lint list), so the second and third to merge conflict and are resolved by
  keeping every id. Sign-packet merges first, so the copy check compares against `src/sign-packet`.
- The code is MIT here, like the rest of the repository, on the Operator's decision: the code is
  theirs, AOF had no licence file.
- Still open: the later move of agentic-register and agentic-a2a, which is what lets the devhost
  and the seed switch to the published register.
- The `ssh-agent` unit, `cloud-folder` unit and `agents-lease` suites already fail on main inside
  this devhost; that is a backlog matter, not part of this change.

## Change log

| Date | Change |
|---|---|
| 2026-11-19 | First draft. |
| 2026-11-19 | Accepted as the Operator ruled (versions, MIT, merge order, release); numbered 0062 (0060 and 0061 were taken on main). |
