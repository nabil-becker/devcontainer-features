# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

The entries before the move to this collection are the AOF repository's own "Changes" list, as
written there, dated by the commit that first carried each version; "AOF ADR nnnn" names a record
of that repository.

## [0.3.0] - 2026-11-19

### Changed

- Moved from the AOF repository (the Agentic Operating Framework, private) into this collection, and
  published from here as `ghcr.io/nabil-becker/devcontainer-features/register-engine`. The engine,
  the entry format and the command are 0.2.0's: every register it read reads here unchanged.
- **It installs alone.** The Feature now carries its own copy of sign-packet's library
  (`signpacket/`, sign-packet 0.6.0, the same code as 0.5.1 with the new version number) and
  installs it into `/usr/local/lib/register-engine/signpacket/`, where the command finds it first.
  The sign-packet Feature is no longer needed beside it, the install never runs a sibling's
  installer, and the order of Features does not matter. In AOF the two had to be listed together;
  this collection cannot name an unreleased Feature in `installsAfter`, and a published Feature
  folder must be self-contained (CONTRIBUTING, "Adding a Feature", step 3).
- The version goes on from AOF's line rather than restarting at 1.0.0. AOF's `publish-features`
  workflow published every version to its private registry
  (0.1.0 to 0.2.0); 0.3.0 is
  the first from here, and the minor says the install changed. 1.0 waits for the capability
  Features and format v3 to settle.
- The documentation is this collection's: the README is generated from `NOTES.md` (with "How it
  fits"), `documentationURL` and `licenseURL` point here (MIT), and the tests are in
  `test/register-engine/` (`task test:register-engine-unit`, part of `task lint`). References to
  AOF's decision records read "AOF ADR nnnn".
- A stack on the AOF package: change the Feature reference and rebuild; the sign-packet Feature may
  stay or go.

## [0.2.0] - 2026-11-11

### Changed

- reads and writes format v3, identity and permission (SPEC.md, "Format v3"; the operator's
  rulings of 2026-11-11): identity attested once by an anchor in an agents register, carried byte
  for byte into each register's `grant`, `bind` and `revoke`. A register is one format; `read`,
  `sync`, `add` and `verify` take it (`fmt`, `--format`), 2 by default. The rules for who may
  write are the engine's, never a plug-in's. Reviewed (class S): checkpoints per register for a
  retired anchor, a bind never raises a role, a re-grant brings back no earlier key, the register
  entry first, carried signatures checked once. Needs sign-packet 0.5.1.

## [0.1.1] - 2026-11-11

### Changed

- a format-v3 entry is refused (`bad-version`) until the engine reads v3 (0.2.0): sign-packet
  0.5.0 knows version 3, and these rules are v2's.

## [0.1.0] - 2026-11-11

### Changed

- the first version (AOF ADR 0028). It holds agentic-register 0.18.0's engine without its
  register types, with the types folder in their place. The change feed no longer fails on an
  entry whose parent was pruned. Reviewed (class S) before release: the types folder's rules above.
