# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

## [1.0.0] - 2026-11-20

### Added

- The component registry, release 1 (ADR-0063): `dcf-registry resolve` fetches each layer of the
  layer list (`.devcontainer/registry.yml`, option `registryFile`, `COMPONENT_REGISTRY_FILE`) from
  its `git` or `path` source into a layer copy (an unchanged layer is skipped; an unreachable one
  uses its last good copy and says so; a `required` layer never fetched stops it), merges the
  `.reg` files by value type for who you are (`COMPONENT_REGISTRY_WHOAMI` or `--as`), and swaps
  the resolved view in; `dcf-registry explain <path> [--uses]` says who said each line, at which
  version, what was skipped and why, and what refers to a path. Skills only. Tasks
  `component-registry:resolve`, `:explain`, `:version`, `:setup`. Layer copies and the view are
  owner-only in a volume the Feature owns. Nothing to do until you write a layer list and set who
  you are.
