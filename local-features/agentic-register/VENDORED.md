# Vendored: agentic-register

This folder is the AOF seed's `agentic-register` Feature (0.14.4), copied unchanged from the
offline package, with the exceptions listed below. Do not edit the files here; take a newer
copy instead.

| | |
|---|---|
| Source | `aof/tooling/src/agentic-register/` of the AOF seed 0.5.1 |
| Seed tag | `seed-v0.5.1` (commit `e8b15cf`, made from `0c8a00b`) |
| Bundle | `aof-seed-0.5.1.bundle`, sha256 `0a573df60b9f5a27dd892d046a8994baf552890787ac042f76e74190e2652af0` |
| Provenance | Confirmed by AOF out of band on 2026-11-03: its host downloaded the bundle from the release with its own GitHub login and computed the same sha256. Also confirmed: `main` is `e8b15cf643ed63a2c7174abeb8fcc072107d4f04`, the tag object `seed-v0.5.1` is `50078f00f6762040b62b078b585c683cbe78a00b`, and the tree of `aof/` is `24103b01078f12a444d4a5178af40fb605d4d345`. It is AOF's release commit `0c8a00b` with `aof/seed/drops/` left out by design. The tag is not signed, so this is a second route for the hash, not a signature. |
| Reason | The AOF registry packages are private; the Operator ruled 2026-11-01: install from the offline package by path now, GHCR later. |

Differences from the source:

- `dcf-persist.sh` is this collection's canonical `src/common/dcf-persist.sh` (`task common:check`
  requires every copy to equal it); the seed's copy differs by one comment line.
- `mirror` (0.14.5 here; upstream is 0.14.4) goes by name: `register/cli.py` reads from the mirror only
  the entries the store lacks, and `register/adapters.py` has `raws(only=)` and `sync(read_sink=False)`
  for it. Upstream reads every entry of both sides twice (four full passes), which on rclone's FUSE
  mount (about 0.6 s a read, 1,623 entries) took 23-28 minutes (`scribe-mirror-slow`). To go upstream;
  drop this difference when a release has it.
- This file is added.

The register's own tests (`aof/tooling/test/agentic-register/`, 4,390 lines) are not vendored: they
assume AOF's layout (`aof/tooling/src/`, `aof/tooling/check/conformance.py`) and test the upstream
code, which this folder does not change. To run them against this folder, rebuild that layout in a
scratch directory from the seed tag, put a copy of this folder at `aof/tooling/src/agentic-register`,
and run each `test_*.py` with `python3 -I`.

Replace this folder with `ghcr.io/kgo-solutions/agentic-operating-framework/agentic-register:0`
(a reference in `.devcontainer/devcontainer.json`, then delete the folder) once read access to the
registry exists.
