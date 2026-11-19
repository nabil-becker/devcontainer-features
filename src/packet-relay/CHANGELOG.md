# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

The entries before the move to this collection are the AOF repository's own "Changes" list, as
written there, dated by the commit that first carried each version; "AOF ADR nnnn" names a record
of that repository.

## [0.4.0] - 2026-11-19

### Changed

- Moved from the AOF repository (the Agentic Operating Framework, private) into this collection, and
  published from here as `ghcr.io/nabil-becker/devcontainer-features/packet-relay`. The protocol
  (SPEC.md), the command and the options are 0.3.0's; a home in the volume
  `packet-relay-state-${devcontainerId}` and the packets in a shared folder carry over unchanged.
- **It installs alone.** The Feature now carries its own copy of sign-packet's library
  (`signpacket/`, sign-packet 0.6.0, the same code as 0.5.1 with the new version number) and
  installs it into `/usr/local/lib/packet-relay/signpacket/`, where the command finds it first.
  The sign-packet Feature is no longer needed beside it, the install never runs a sibling's
  installer, and a guard option is now always checked at install (before, it was skipped when
  sign-packet was not yet installed). This collection cannot name an unreleased Feature in
  `installsAfter`, and a published Feature folder must be self-contained (CONTRIBUTING, "Adding a
  Feature", step 3).
- The version goes on from AOF's line rather than restarting at 1.0.0. AOF's `publish-features`
  workflow published every version to its private registry
  (0.1.0 to 0.3.0); 0.4.0 is the
  first from here, and the minor says the install changed. 1.0 stays reserved for a break of the
  protocol.
- The documentation is this collection's: the README is generated from `NOTES.md` (with "How it
  fits"), `documentationURL` and `licenseURL` point here (MIT), the setup helper is this
  collection's `dcf-persist`, and the tests are in `test/packet-relay/` (`task
  test:packet-relay-unit`, part of `task lint`). References to AOF's decision records read "AOF ADR nnnn".
- A stack on the AOF package: change the Feature reference and rebuild; the sign-packet Feature may
  stay or go.

## [0.3.0] - 2026-11-09

### Changed

- an acknowledgement lists what it took (`taken`, each with `from`), as a field name cannot
  hold a principal with an instance (`relay@<GUID>`); 0.2's map (`upto`) is still read. A 0.2 party
  reads a 0.3 acknowledgement as nothing taken, so upgrade every party: until then nothing is removed.
  The 0.2.1 entry below was wrong: parties with an `@` could send but never be acknowledged.

## [0.2.1] - 2026-11-06

### Changed

- a party may be a principal with its manor (`aof@manor`), as sign-packet 0.3.0 reads them.

## [0.2.0] - 2026-11-05

### Changed

- guards on egress and ingress (`guard`, `ingressGuard`, `guardTimeout`), run by sign-packet
  0.2.0; an ingress refusal is quarantined and the sender's order goes on. The phi-check Feature
  is the first guard.

## [0.1.0] - 2026-11-05

### Changed

- the first version (AOF ADR 0024, decision 3).
