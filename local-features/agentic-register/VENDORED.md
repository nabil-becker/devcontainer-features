# Vendored: agentic-register

This folder is the AOF seed's `agentic-register` Feature (0.14.1), copied unchanged from the
offline package, with two exceptions listed below. Do not edit the files here; take a newer
copy instead.

| | |
|---|---|
| Source | `aof/tooling/src/agentic-register/` of the AOF seed 0.5.0 |
| Seed tag | `seed-v0.5.0` (commit `f06a77f`, made from `4eccebf`) |
| Bundle | `aof-seed-0.5.0.bundle`, sha256 `f6ad6d57223df63c2949548e03c7f8415f8f92a1182514dd89b933edb66d3990` |
| Reason | The AOF registry packages are private; the Operator ruled 2026-11-01: install from the offline package by path now, GHCR later. |

Differences from the source:

- `dcf-persist.sh` is this collection's canonical `src/common/dcf-persist.sh` (`task common:check`
  requires every copy to equal it); the seed's copy differs by one comment line.
- This file is added.

Replace this folder with `ghcr.io/kgo-solutions/agentic-operating-framework/agentic-register:0`
(a reference in `.devcontainer/devcontainer.json`, then delete the folder) once read access to the
registry exists.
