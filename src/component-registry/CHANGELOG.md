# Changelog

All notable changes to this Feature, newest first, in the form of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each entry says what changed for a user
of the Feature and whether they must act (an option renamed, a task removed, a rebuild needed).
The version in `devcontainer-feature.json` is bumped in the same change that adds its entry
here; `task lint` fails when the entry is missing.


## [2.2.0] - 2026-11-24

### Added

- `git` source `path: <folder>`: a folder of the repository is the layer (a monorepo). Only that
  folder is fetched (a blob-less shallow fetch where the server allows it) and its contents are the
  layer root, so `*.layer` and `@file` siblings work as in a root layer. An absolute path, `..` or a
  folder missing at the ref is refused with a line naming layer, ref and path. The version stays the
  commit, so a change elsewhere in the repository is also a new version.
- `http` source `archive: tar.gz | tgz | zip`, with optional `sha256: <hex>` (the pin and the
  version; a mismatch is refused and nothing is replaced) and `path: <folder>` (a folder inside the
  archive). The archive is checked before extraction: absolute or `..` names, links pointing
  outside (a zip may hold no symlink), device files and a total over 100 MiB are refused. Without
  `archive` the source reads one `.layer` file exactly as before. Auth is unchanged.
- `max-size: <n>[K|M|G]` on an `http` source sets the one cap on the download and the extracted total (default 100 MiB for an archive, 1 MiB for a plain file); `COMPONENT_REGISTRY_MAX_ARCHIVE_SIZE` sets the default for archives, the source's key winning. A refusal names the cap and how to raise it.
- The Feature installs `unzip` (apt) when it is missing; a zip layer without it is refused saying so.

Action: none; existing layer lists work unchanged. Use `path` or `archive` to read a monorepo
folder or a release asset.

## [2.1.0] - 2026-11-24

### Added

- The built-in base layer ships `templates/copilot/SKILL.md.j2` (ADR-0077 slice 2.1, backlog
  `templating-slice-2`): Copilot CLI reads the same `SKILL.md` as Claude Code, so the template is
  the same, and it reproduces each resolved skill byte for byte. With copilot 0.3.0 (whose adapter
  gains the `skills` verb), `dcf-registry handover copilot` renders it and hands the result over; a
  layer overrides it the three ways as for Claude Code. `explain templates/copilot` and
  `render copilot` show it.

Nothing to do for Claude Code. A Copilot agent gets registry skills from copilot 0.3.0; see that
Feature's changelog for the default and how to turn it off.
## [2.0.0] - 2026-11-23

Breaking: removes what 1.9.0 and 1.10.0 deprecated, all at once (the Operator's rulings of
2026-11-20 and 2026-11-23). Pin `component-registry:2` after you have migrated.

### Removed

- `.reg` layer files are no longer read. `resolve` prints a warning per layer source naming them
  ("not read since 2.0.0: ...; rename to .layer") and goes on without them; a `required` layer
  holding only `.reg` files resolves with nothing, so rename them. The `http` source always saves
  `<layer>.layer`, even for a URL ending in `.reg`. Action: `git mv x.reg x.layer` in each layer.
- `writable: true` on a layer is ignored: `resolve` prints one warning per such layer, and an old
  `registry.yml` still resolves. Action: delete the line.
- `dcf-registry remember`, `task component-registry:remember` and the built-in `/registry-remember`
  skill (the base layer now ships two utility skills). `dcf-registry remember` prints "removed in
  2.0.0: edit your layer" and exits 1; the task is gone. A `remembered.layer` already in a layer
  folder is an ordinary layer file. Action: edit your layer instead; stop using the skill.

## [1.11.0] - 2026-11-23

### Added

- **Vendor templates** (ADR-0077, backlog `templating-build`): each vendor's files are rendered
  from Jinja templates by `minijinja-cli` at every hand-over; the merge (precedence, locks,
  `explain`) is unchanged. A template is a file `templates/<vendor>/<file>.j2` in a layer, a
  component of the new kind `template`, with a head saying `for:` (`skill` or `once`), `output:`
  (the path written, itself templated) and optionally `lock: true`. The highest layer's template
  wins whole; a lower layer's lock holds; a namespaced layer's templates are its own, render only
  its skills and never replace the Operator's files. Any layer may replace a template, change one
  block with `{% extends "<layer>/<file>.j2" %}`, or add its own.
- The built-in base layer ships `templates/claude/SKILL.md.j2`, which reproduces every resolved
  `SKILL.md` byte for byte: Claude Code gets exactly the files 1.10.0 gave until a layer
  overrides it. A CLI with no template is handed the view's skills as before.
- `dcf-registry render <vendor> <folder>` (task `component-registry:render`) previews what a
  hand-over gets; `dcf-registry explain templates[/<vendor>[/<file>.j2]]` shows each candidate,
  the winner and the base it extends. The view keeps the templates and `meta/templates.tsv`.
- `minijinja-cli` 3.1.0 is installed (the static build for x86_64 or aarch64, through `dcf_curl`,
  checked against a pinned sha256): the Feature's first download at build.

### Changed

- A template that does not render, or no `minijinja-cli`, fails the hand-over with the template's
  layer and file named; the adapter is not called and the CLI keeps the skills it has. A template
  head that cannot be read is skipped and reported by `resolve`, as an unreadable line is.

Action: rebuild to get `minijinja-cli`. Nothing else; a view resolved before 1.11.0 is handed
over as it is until the next `resolve`.

## [1.10.0] - 2026-11-23

### Deprecated

- The registry does not write layers (the Operator's ruling of 2026-11-23): if a change is needed,
  edit the layer. Still accepted in 1.x, removed in 2.0.0 together with `.reg`:
  - `writable: true` on a layer: `resolve` prints one deprecation line per such layer.
  - `dcf-registry remember` and the built-in `/registry-remember` skill: a deprecation line before
    writing; behaviour otherwise unchanged. Action: edit your own layer instead.

## [1.9.0] - 2026-11-23

### Changed

- A layer's files are now `*.layer`, not `*.reg`: Windows opens a `.reg` file in the Registry
  Editor on double-click. The grammar is unchanged. The built-in base layer, the `http` source
  (a URL without a `.layer` or `.reg` name is saved as `<layer>.layer`) and the `db` source
  (renders `<layer>.layer`) use the new name. `remember` writes `remembered.layer`.

### Deprecated

- `.reg` files are still read in 1.x, in name order with any `.layer` files, and `resolve`
  prints one line per layer source naming them. `remember` keeps appending to an existing
  `remembered.reg` (no split) with the same line. Action: rename your layer files to `.layer`
  (`git mv x.reg x.layer`); `.reg` is removed in 2.0.0.

## [1.8.0] - 2026-11-21

### Added

- **A view per who-you-are path** (ADR-0074, backlog `agent-skills-folders`). `resolve` keeps the
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

## [1.7.0] - 2026-11-21

### Added

- **Layer namespaces** (ADR-0073, decision 4): `namespace: <name>` on a layer in the layer list
  prefixes every component the layer brings (`skills/acme:arch-review`, `agents/acme:reviewer`).
  Layers that share a namespace merge with each other as layers do (order, specificity, locks,
  `@replace`, types, permission keys from the namespace's lowest layer); different namespaces
  never mix, and the un-namespaced layers (the Operator's own) never reach a namespaced component,
  nor it theirs. A name is lower-case letters and digits in words joined by one `-`, at most 40;
  anything else, and the reserved `component-registry` and `anthropic-skills`, is refused with
  `file:line`.
- A namespaced skill lands in the view, and in a CLI's skills folder, as `skills/<ns>--<name>/`,
  its `SKILL.md` named the same whatever its text says (a `:` is no skill folder name for the
  adapters, and Claude Code keeps the `:` for the prefixes it makes); one whose folder name an
  un-namespaced skill already has is not resolved and is reported. `meta/namespaced.tsv` maps the
  registry name to it; `handover` says which skills went by their folder name.
- **Explicit references** (the Operator's ruling of 2026-11-21): a ref, a list `ref:` item or an
  agent's `skills` item without a prefix names the referrer's own namespace; `<ns>:<name>` names
  namespace `<ns>` from any layer, including one namespace to another. Nothing names the
  un-namespaced set from inside a namespace.
- **Missing dependencies**: a reference whose target is not in the view is reported by `resolve`
  (the referrer, its layer, the target), shown by `explain` and `explain --uses`, and does not
  stop `resolve`. `meta/refs.tsv` gains the state `missing` (a malformed ref stays `dangling`) and
  two columns, the referrer's layer and the alias used.
- **Aliases**: `aliases: { <name>: <namespace> }` on a layer; inside it, a reference to `<name>:`
  resolves to `<namespace>:` first. One hop; an alias naming itself, the layer's own namespace,
  another alias of the layer or a reserved name is refused with `file:line`. `layers.tsv` gains
  an eleventh column, `aliases`.
- A namespaced agent definition (`agents/<ns>:<name>/` in the view) matches no agent of the
  agents list; a plain-listed layer's agent definitions override as before (the Operator's ruling
  of 2026-11-23). The Operator's own agent names a namespaced skill as `<ns>:<name>` in its
  `skills`, written to the view as `<ns>--<name>`.
- `explain` shows each layer's namespace, a namespace line with the hand-over name, and
  `[namespace <ns>]` on every line of a namespaced component; it takes `kind/<ns>:<name>[:key]`
  or the folder name; a "References" part lists each reference as written and as resolved, then
  the missing dependencies; `--uses` shows a namespaced or aliased ref's resolved target.

### Changed

- `layers.tsv` gains a tenth column, `namespace` (`-` for none). In an agent definition's
  `skills`, a plain item `<a>:<b>` (a lower-case `<a>`) now names the namespaced skill `a:b`; it
  was read as the skill `a` before. A ref to a target that is not there is reported as a
  `missing dependency:` line instead of `dangling ref:`. Otherwise a layer list without a
  namespace resolves exactly as in 1.6.0. `writable` and `remember` are unchanged.

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
