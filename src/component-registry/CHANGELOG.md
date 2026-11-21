# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

## [1.6.0] - 2026-11-20

### Added

- **Agent definitions** (`agents/<name>`, the second component kind; proposal section 6.1). Two
  fields, each merged by its type: `model:value` (the model the agent's CLI runs on, one word; and
  `model.<cli>:value`, the model for agents of that CLI only, which beats a plain `model` of the same
  layer and path; a key may now hold `.`) and
  `skills:list` (a skill name or `ref:skills/<name>`, checked as a ref, so `explain skills/<name>
  --uses` lists the agents that name it). A line for any other key of an agent is skipped and
  reported: the agents list owns the identity, the address, the lease, the folder, `args` and
  `definition`, and an agent definition carries no permission key at all.
- **The resolved view's `agents/<name>/`**: `model` (one line), `skills` (one name per line) and
  `from.tsv` (field, layer, `source:file:line` of each line used), what the participant component
  (participant 1.3.0) reads at the agent's start; `meta/agents/<name>/` as for skills.
- **`COMPONENT_REGISTRY_AGENTS`** (comma-separated `name:cli` items, set by the participant
  component): `resolve` resolves `agents/<name>` for each, so a pattern such as `[agents/*]` reaches an
  agent no layer names, and writes the effective model for that agent's CLI (`from.tsv` names the
  key it came from); the names are kept in the view (`agent-names`), so `/registry-refresh` keeps them.
- `explain agents/<name>` closes with where the participant reads the definition and that its
  values replace the agents list's (the registry wins for `model` and `skills`, the Operator's
  ruling of 2026-11-21).

Nothing to do for a layer list or a layer that holds skills only: they resolve as before. A
section for `agents/...`, reported as "not in this release" until now, is resolved from this
release.
## [1.5.0] - 2026-11-20

### Added

- **The `db` source.** A layer can be the rows of a database: `kind: db` with `driver: sqlite`
  (`path`) or `driver: postgres` (`host`, `port`, `database`, `user`, `sslmode`, and the password
  as `auth.secret`, a `dcf-secret` name), and one of `table` or `query`, returning the columns
  `section`, `key`, `type`, `data`, `locked`. The source (`registry-source-db`) renders them into a
  `.reg` file in the layer copy (a multi-line `text` into a file read with `@file`); its version is
  a hash of the rendered files; a bad row or an empty result fails the fetch with the reason, and
  `resolve` keeps the last good copy. The database is opened read-only; the password reaches
  `psql` in its environment only. Any other driver exits 3. The contract is in the Feature's notes.

### Changed

- A layer list naming `kind: db` is no longer reported as "not in this release".

Needs `sqlite3` or `psql` in the image for the driver in use (this Feature does not install them;
the source says how). Nothing to do for a layer list without a `db` source. Rebuild to get it.

## [1.4.0] - 2026-11-20

### Added

- **`dcf-registry explain --color auto|always|never`.** `explain` paints each resolved line by the
  layer it came from, with a legend at the top (layer id and colour name), and shows skipped lines
  and dangling refs dim and struck through. Six colours of the Okabe-Ito set, chosen to stay
  distinguishable with the usual colour-vision deficiencies; the layer id is on every line, so
  colour is never the only signal. The default, `auto`, colours only when stdout is a terminal and
  `NO_COLOR` is unset; `always` colours regardless (also over `NO_COLOR`); `never` does not. Without
  colour the output is byte for byte that of 1.3.0, so scripts keep working. Nothing to act on.

## [1.3.0] - 2026-11-20

### Added

- **`heading: false` on a layer.** A layer in the layer list can say `heading: false`: its `text`
  lines (a skill's `body`) are stacked with no `## Layer <id>` heading, after one blank line, so
  layers written to read as one document resolve to exactly that document. `explain` still names
  each line's layer. The default, `true`, is the 1.2.0 rendering, unchanged. A value other than
  `true` or `false` is refused with its line.
- **Front matter values.** A skill's `name:value` and `description:value` are written into the
  front matter of its `SKILL.md` (the strongest line wins, as for any value): the key's line is
  replaced, or added, or a front matter is made for a body that has none. Only these two keys; a
  permission key such as `allowed-tools` still comes from the lowest layer. `explain` says the
  value was written into the front matter.

Nothing to do: a layer list and `.reg` files of 1.2.0 resolve as before, except that a skill whose
higher layer already set `name` or `description` values now has them in its front matter. Rebuild
to get it.

## [1.2.0] - 2026-11-20

### Added

- **The `http` layer source.** A layer can now be one `.reg` file served over HTTP(S):
  `{ kind: http, url: "https://registry.example.invalid/corp.reg", auth: { type: bearer, secret: registry/corp } }`.
  `auth.type` is `bearer` (an `Authorization: Bearer` header), `header` (`auth.header` names the
  header) or `basic` (`auth.user` and the secret); without `auth` the endpoint is read open, the
  layer owner's choice. The secret is read with `dcf-secret` (the openbao Feature) and handed to
  curl on its standard input: never on a command line, in a file or in a log. A secret is never
  sent over plain `http://` unless the source says `allow-insecure: true` (plain http sends it
  in the clear), and with a secret redirects are not followed. The version is the ETag, else the
  Last-Modified, else a hash of the body; when the endpoint cannot be reached the last good copy
  is used and said. One `.reg` file of at most 1 MiB: archives and `@file` siblings are not read.
  The layer list accepts the new `allow-insecure` key. Nothing to do unless you want an http layer;
  rebuild to get it.
- The `cloud-folder` source's command comes with the cloud-folder Feature 1.4.0; `kind: cloud-folder`
  no longer says "later release" here. `db` is still not in a release.

## [1.1.0] - 2026-11-20

### Added

- **The adapter step** (ADR-0064): `dcf-registry handover <cli> [<name> <folder>]` hands the resolved
  view's skills to that CLI's adapter (`agent-adapter-<cli> skills`, when its `supports` lists it;
  Claude Code: `claude-code` 1.12.0); a CLI that cannot take them is named and keeps its plain skills.
  The participant component (`claude-code` with `participants: true`) runs resolve and the hand-over
  at every agent's start, with an agent's own `registry-path` from the agents list.
- **The three utility skills, in a built-in base layer**: `/registry-refresh` (resolve now for the
  path the current view was resolved for, then hand over to every CLI adapter on PATH: live in Claude
  Code, a restart for a CLI that does not watch its skills folder), `/registry-explain <path>`, and
  `/registry-remember [skills/<name>] <line>` (appends the line to the layer marked `writable: true`,
  which must have a `path` source, then refreshes; refused, nothing written, otherwise). The base
  layer is rank 0, the id `component-registry` at `/`, below every listed layer; `explain` shows it as
  `0 component-registry at /, source 1 (builtin)`. A listed layer adapts the utility skills like any
  skill.
- `dcf-registry layer-list`, `refresh`, `remember`; tasks `component-registry:refresh` and
  `component-registry:remember`.

### Changed

- The layer id `component-registry` is reserved for the base layer: a layer list using it is refused
  with its line. Rename such a layer.

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
