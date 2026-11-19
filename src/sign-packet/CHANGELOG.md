# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

The entries before the move to this collection are the AOF repository's own "Changes" list, as
written there, dated by the commit that first carried each version; "AOF ADR nnnn" names a record
of that repository.

## [0.6.0] - 2026-11-19

### Changed

- Moved from the AOF repository (the Agentic Operating Framework, private) into this collection, and
  published from here as `ghcr.io/nabil-becker/devcontainer-features/sign-packet`. The code, the
  packet format and the command are 0.5.1's: a packet signed by 0.5.1 reads here unchanged, and
  the instance id in the volume `sign-packet-state-${devcontainerId}` is kept.
- The version goes on from AOF's line rather than restarting at 1.0.0. AOF's
  `publish-features` workflow published every version to its private registry
  (0.1.0 to 0.5.1), so a stack
  that used it moves by changing the reference to `ghcr.io/nabil-becker/devcontainer-features/sign-packet:0`;
  0.6.0 is the first version from here. 1.0 stays reserved for a break of the format or the
  command (AOF ADR 0024).
- The documentation is this collection's: the README is generated from `NOTES.md` (with "How it
  fits"), `documentationURL` and `licenseURL` point here (MIT), the setup helper is this
  collection's `dcf-persist`, and the tests are in `test/sign-packet/` (`task
  test:sign-packet-unit`, part of `task lint`). References to AOF's decision records read
  "AOF ADR nnnn".
- Nothing to do for a new user. A stack on the AOF package: change the Feature reference and rebuild.

## [0.5.1] - 2026-11-11

### Changed

- a body nested too deeply (within the size limit) is refused (`bad-format`) instead of
  crashing the reader: one such file in a store stopped every read of its domain (register-engine
  0.2.0's security review, F3).

## [0.5.0] - 2026-11-11

### Changed

- format version 3 is known (AOF ADR 0028; the operator's rulings of 2026-11-11 on the register
  v3 design): version 2's fields, signed in its own namespace (`aof-register-v3`). It is opt-in:
  `parse`, `check_fields`, `sign`, `collect` and `read` take versions 1 and 2 unless the caller passes
  `versions=(1, 2, 3)`, so every layer written before it (agentic-register, register-engine 0.1,
  packet-relay) refuses v3 (`bad-version`) unchanged. A key's chain never crosses into or out of
  version 3. A packet refused for its version is named by its id, so what follows it is refused,
  not held. Reviewed (class S).

## [0.4.0] - 2026-11-06

### Changed

- a principal names its running instance: `role@<instance GUID>` (the operator's D93), and
  nothing else after `@`. sign-packet keeps the instance id (SPEC.md, "The instance"): from
  `AOF_INSTANCE_ID`, OpenBao or made here, recorded once in its own volume, a different value
  later refused; `sign-packet instance`, and a post-create hook.

## [0.3.0] - 2026-11-06

### Changed

- a principal may name its manor after one `@` (`scribe@manor`; AOF's design/federation.md, the
  operator's D35 and D38). Readers before 0.3.0 refuse such a packet.

## [0.2.0] - 2026-11-05

### Changed

- guards (SPEC.md, "Guards"): `signpacket.guard`, the runner agentic-register used for its
  register guard, now shared, with egress and ingress and a chain; `sign(..., guard=)`. The
  format does not change.

## [0.1.0] - 2026-11-05

### Changed

- extracted from agentic-register 0.14.4 (AOF ADR 0024), no change to the format: every entry
  agentic-register has written is a packet with the same id.
