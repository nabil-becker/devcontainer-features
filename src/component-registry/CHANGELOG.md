# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.

## [1.7.0] - 2026-11-20

### Added

- **A view per who-you-are path** (ADR-0068, backlog `agent-skills-folders`). `resolve` keeps the
  latest view of every path (`paths/<path>` in the state folder) besides `view`, the latest of all;
  `handover <cli> <name> <folder> --as <path>` hands that path's view, and without `--as` the view
  of the who-you-are setting. `explain --as <path>` reads a path's own view. The one resolve lock
  stays: the layer copies are shared.
- **Hand-over records** (`dcf-registry handovers`): cli, agent, folder, path and whether the path
  was the agent's own or the setting. `forget <cli> <name> <folder>` asks the adapter to drop the
  agent's own copies, removes the record, and the views no record names any more.
- **`refresh --session <id>`**: the agent whose session that is (each adapter's `list`) is
  refreshed for its own path, alone. Without it (or with an id no agent has), `refresh` repeats
  every recorded hand-over, each path resolved once; with no record, as before.
- `/registry-refresh` runs `dcf-registry refresh --session "${CLAUDE_SESSION_ID}"`, so it refreshes
  the calling agent in Claude Code.
- **The skills mode** (`handover --skills-mode split|shared|off`, else the setting
  `COMPONENT_REGISTRY_SKILLS_MODE`, else `split`), given to the adapter, recorded and repeated by
  `refresh`; `off` forgets the agent. `handovers --skills` lists each agent's path, mode, own folder
  and own skills (from the adapter's `skills-show`).

Nothing to do. The adapter's `skills` verb also gets `COMPONENT_REGISTRY_PATH`; with claude-code
1.14.0 agents of different paths keep their own skills.

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
