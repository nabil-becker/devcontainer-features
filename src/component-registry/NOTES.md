## How it fits

```text
  layer sources (git, a folder or file share)
        | registry-source-<kind> fetch (version first; offline: the last good copy)
        v
  volume: COMPONENT_REGISTRY_STATE_DIR
    copies/<layer>/<n>/   layer copies
        | dcf-registry resolve, for COMPONENT_REGISTRY_WHOAMI or --as an agent's path
        v
    view -> views/<stamp>/   the latest resolved view: skills/<name>/, meta/
    paths/<path> -> ...      (1.7.0) the latest view of each who-you-are path
    handovers.tsv            (1.7.0) who was handed which path's skills
        | dcf-registry handover <cli> <agent> <folder> --as <path>: agent-adapter-<cli> skills
        |   (at an agent's start, by the participant component; or /registry-refresh)
        v
  the CLI's own skills folders (Claude Code: $CLAUDE_CONFIG_DIR/skills for what every agent
  shares, and each agent's own folder read through --add-dir; marked owned)

  dcf-registry explain <path> [--uses] [--color auto|always|never]   read-only
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Layer list (which layers, at which paths, from which sources) | `.devcontainer/registry.yml` in the repository (option `registryFile`) | 1 git |
| Who-you-are path (`COMPONENT_REGISTRY_WHOAMI`) | `.env` (git-ignored) or the launcher, per person | none (a setting, set again) |
| A layer's `.reg` files and skill files | its source: a git repository, a folder, a file share | the owner's choice |
| Layer copies, the resolved view, the lock file | named volume at `/var/lib/devcontainer-features/component-registry`, owner-only | 4 working set |
| Resolved skills handed to a CLI | the CLI's skills folders (Claude Code: `$CLAUDE_CONFIG_DIR/skills` and, per agent, `$CLAUDE_CONFIG_DIR/registry-agents/`, the claude-code volume), owner-only | 4 working set |
| Hand-over records (`handovers.tsv`: CLI, agent, folder, path) | the state volume, owner-only | 4 working set |
| Remembered lines (`/registry-remember`) | `remembered.reg` in the writable layer's folder | the person's choice (their own layer's source) |
| The utility skills (built-in base layer) | `/usr/local/share/component-registry-feature/base`, in the image | none (the Feature) |
| Source secrets | OpenBao, read with `dcf-secret` | OpenBao's |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: none yet

## What it is

A registry for agentic components, shaped like the Windows Registry without being it
([ADR-0063](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/adr/0063-agentic-components-live-in-a-registry-of-layers-shaped-like-the-windows-registry-and-merge-by-value-type.md),
[the proposal](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/proposals/component-registry.md)).
A skill is written once; an organization, a department, a team and one person each adapt it in
their own **registry layer**, kept wherever they keep things. Layers are like hives, paths like
keys, typed `:key` values like registry values, locks like Group Policy; `resolve` builds the merged
view (like `HKCR`) for who you are, `explain` reads it (like `regedit`).

Release 1.0.0 is the core: the layer list, `COMPONENT_REGISTRY_WHOAMI`, the `.reg` grammar, the
four value types, patterns, the match rule, locks, `resolve` and `explain` (`--uses`), and the
`git` and `path` registry sources. Release 1.1.0 adds the adapter step (ADR-0064): `handover` gives
the resolved skills to a CLI through its adapter's `skills` verb, the participant component
resolves and hands over at every agent's start (with a per-agent who-you-are path), and a built-in
base layer ships the utility skills `/registry-refresh`, `/registry-explain`, `/registry-remember`.
Release 1.2.0 adds the `http` source (and, with cloud-folder 1.4.0, the `cloud-folder` source).
Release 1.3.0 adds the layer key `heading: false` (stack a layer's text without a heading) and
writes a skill's `name` and `description` values into its `SKILL.md` front matter.
Release 1.7.0 keeps a view per who-you-are path, so agents with different `registry-path`s each
get their own skills (ADR-0068, below).
It resolves **skills** only. Not yet: the `db` source; a layer list naming it is read, and
`resolve` says that kind is not in this release.

## What it installs

Nothing is downloaded at build; there is nothing to verify (an `http` layer is read at run time). Bash, awk and sed only (mawk and gawk both
work; no python3, no jq):

- `dcf-registry` (`/usr/local/bin`): `resolve`, `explain`, `version`, and (1.1.0) `handover`,
  `refresh`, `remember`, `layer-list`, and (1.7.0) `forget`, `handovers`.
- `/usr/local/share/component-registry-feature/base/`: the built-in base layer, the utility skills.
- `registry-source-git` and `registry-source-path`: the two **registry sources** of this release.
- `component-registry-setup`: the `postStartCommand`.
- `dcf-persist`, the collection's helper behind every setup script.
- `/usr/local/share/component-registry-feature/` with the version and the `registryFile` option.
- The Feature Taskfile (`installTaskfile`).

`resolve` needs `flock` (util-linux, in every Debian and Ubuntu image); a `git` source needs git,
which this Feature does not install (the base image, or the `git` Feature).

## Options

| Option | Default | What it does, when to change it |
| --- | --- | --- |
| `registryFile` | `.devcontainer/registry.yml` | The layer list, relative to the repository root (or absolute). Change it when the repository keeps its configuration elsewhere. `COMPONENT_REGISTRY_FILE` in `.env` or the environment overrides it without a rebuild. |
| `installTaskfile` | `true` | Register the Feature Taskfile under `component-registry:`. |

Settings are plain variables (NFR-6), each from the task variable, then the root `.env`, then
`.devcontainer/.env`, then the environment:

| Variable | Default | What it is |
| --- | --- | --- |
| `COMPONENT_REGISTRY_WHOAMI` | none: `resolve` refuses and says how to set it | Who you are, a path such as `/Corp/MyDepartment/team/me`. Per person, never in a committed file; `--as <path>` overrides it for one run. |
| `COMPONENT_REGISTRY_FILE` | the option | The layer list. |
| `COMPONENT_REGISTRY_STATE_DIR` | `/var/lib/devcontainer-features/component-registry` (`containerEnv`) | The state folder. |
| `COMPONENT_REGISTRY_LOCK_WAIT` | `120` | Seconds a `resolve` waits for another one to finish. |

## The layer list

Layers only, lowest first (tier 1, shared, committed). Several sources in one layer merge in their
listed order.

```yaml
layers:
  - id: corp-base               # letters, digits, - and _
    at: /Corp                   # a layer's relative section paths are joined to this
    required: true              # never fetched: resolve fails (also on one source)
    sources:
      - kind: git
        url: "https://git.example.invalid/corp/registry.git"
        tag: v3                 # exactly one of branch, tag, commit
        auth: { type: basic, user: bot, secret: registry/corp-base }   # optional
  - id: dept
    at: /Corp/MyDepartment
    sources:
      - { kind: path, path: /mnt/share/dept-registry }   # a share the launcher mounts
  - id: mine
    at: /Corp/MyDepartment/team/me
    sources:
      - { kind: path, path: .registry-mine }   # git-ignored in this repository
    writable: true              # /registry-remember appends here (one layer, a path source)
    heading: false              # 1.3.0: its text stacks with no "## Layer mine" line
```

`heading` (1.3.0, `true` by default) says whether a layer's `text` lines are stacked under a
`## Layer <id>` heading. With `heading: false` the layer's text follows the text before it after
one blank line, as if the two were one file; `explain` still names each line's layer. Use it when
the layers are written to read as one document (the first real use, below); keep the heading when
a reader should see who said what.

Only this YAML subset is read: comments, plain and quoted values, block entries and one-line
`{ }` maps. An unknown key, a missing `url` or ref, two refs, or a relative `at` is refused with
`file:line` and nothing is resolved (exit 2).

| Source kind | Keys | Log-in |
| --- | --- | --- |
| `git` | `url`, one of `branch`, `tag`, `commit`; `required` | `auth`: `type` `basic` (default; `user`, default `git`) or `bearer`, and `secret`, a `dcf-secret` name; handed to git through the environment, never an argument; git never prompts |
| `path` | `path` (repository-relative or absolute); `required` | the folder's own permissions |
| `http` | `url` (one `.reg` file); `allow-insecure`; `required` | `auth`: `type` `bearer`, `header` (`header` names it) or `basic` (`user`), and `secret`, a `dcf-secret` name; none (the default without a secret) reads an open endpoint |
| `cloud-folder` | `remote` (a folder under the cloud folder); `required` | the cloud folder's own set-up (cloud-folder Feature 1.4.0 or later installs the source) |
| `db` | a later release | |

### The `http` source

`registry-source-http` reads one `.reg` file of at most 1 MiB, saved in the layer copy under the
URL's file name (or `<layer>.reg`). The smallest safe form: archives (`.tar.gz`, `.zip`) and
`@file` siblings are **not** read in this release, because unpacking an archive from the network
is a risk the registry does not take; the source says so when the URL is an archive. No manifest
and no signature are required; review is the endpoint owner's, and the layer list pins only the
URL and how to log in.

- **Secrets.** `auth.secret` names a secret that `dcf-secret` (openbao) reads at each run; it
  reaches curl as a config on standard input, never on a command line, in a file, in an
  environment or in a log (a test reads every process's arguments while a request is in flight).
  A secret that holds a newline, quote or backslash is refused (a curl config cannot carry it).
- **Plain http sends credentials in the clear.** HTTPS is not required (an open endpoint over
  `http://` is the owner's choice), but a source with a secret and an `http://` URL is refused
  (exit 2) unless the source sets `allow-insecure: true`. With a secret, redirects are not
  followed, so the secret never reaches another host; without one, at most 3.
- **Version.** The ETag (`etag:<value>`), else the Last-Modified, else a hash of the body
  (`sha256:<hash>`); a HEAD request first, the GET when the server gives no validator.
- **Time and failure.** 10 s to connect and 60 s in all, the retry helper `dcf_curl` with one
  retry; a 4xx, 5xx, timeout or oversized body fails (exit 1) and `resolve` uses the last good
  copy and says so.

```yaml
- { kind: http, url: "https://registry.example.invalid/corp.reg", auth: { type: bearer, secret: registry/corp } }
- { kind: http, url: "https://registry.example.invalid/open.reg" }          # an open endpoint
- { kind: http, url: "https://registry.example.invalid/x.reg", auth: { type: header, header: X-Api-Key, secret: registry/x } }
```

### The `cloud-folder` source

`registry-source-cloud-folder` (installed by the cloud-folder Feature, which owns the transport)
reads `remote`, a folder under the cloud folder's mount point (`registry/mine` is
`<mountPoint>/registry/mine`), in whatever mode the Feature runs (host, sync or mount); it needs
no rclone credentials of its own and writes nothing into the folder. The version is a fingerprint
of names, sizes and times, as for `path`. When the cloud folder is not set up (the Feature's
status says why) or the folder is absent, the source exits 1 with one line and `resolve` uses the
last good copy.

## A layer's content: `.reg` files

One or more `*.reg` files at the root of the layer's copy, read in name order, line by line:

```
[path]                    a section; [path] @replace replaces the component below it
key:type = data           an entry; type is value, list, text or ref
lock key                  a higher layer cannot change this key
; comment
[!path]                   an exclusion: the sections above it in this file no longer apply
                          to what it matches (no entries of its own)
```

- A **path** is segments split by `/`; one starting with `/` is absolute, any other is joined to the
  layer's `at`. It is split at its first kind segment (`skills`; later `agents`, `prompts`,
  `settings`, `lexicon`): before it the **scope**, from it the **component**.
  `/Corp/MyDepartment/skills/diagrams` has scope `/Corp/MyDepartment`, component
  `skills/diagrams`. A skill is `skills/<name>`, one segment.
- **Patterns**: `*` is one segment, `**` any number (none included), each a whole segment.
  `/**/skills/diagrams` applies to everyone; `[/Corp/skills/*]` to every skill a section names.
- **Data**: `value` the rest of the line; `list` items split by `,` (`!item` removes it,
  `ref:/path` is a reference item); `text` the rest of the line or `@file <file>` (relative to
  the layer copy, never outside it); `ref` a path, `[scope/]skills/<name>[:key]`.
- **Skill files**: `body:text` stacks into the skill's `SKILL.md`; `files:value = @dir <folder>`
  copies a folder's files into the skill, every such line overlaid from the weakest to the
  strongest, so a higher layer's file of the same name replaces a lower one. `SKILL.md` comes
  from `body` when there is one.
- **Front matter values** (1.3.0): a skill's `name:value` and `description:value` are written into
  the front matter of the `SKILL.md` that `body` makes, the strongest line winning as for any
  `value`: the key's line (and its indented continuation lines) is replaced, or added before the
  closing `---`, or a front matter is made when the body has none. Only these two keys; the value
  is written as it is, one line (quote it in the `.reg` line if YAML needs that). Any other front
  matter line stays the first block's, so a permission key (`allowed-tools`) keeps the lowest
  layer's, as rule 3 of the match rule says. A `SKILL.md` that comes from `files` is not changed.

A line that cannot be read (no section, an unknown type, a bad header, a kind not in this
release) is reported with `source:file:line` and skipped; content never fails a `resolve`.

## The built-in base layer and the utility skills (1.1.0)

The Feature carries one layer of its own, read from `/usr/local/share/component-registry-feature/base`
(never fetched): rank 0, the id `component-registry`, at `/`, below every layer of the list and
present in every resolve. `explain` lists it first, as
`0 component-registry at /, source 1 (builtin): builtin, <Feature version>`, and names it on each of
its lines (`component-registry@1.1.0 1:component-registry.reg:<line>`). The id is reserved: a layer
list using it is refused with its line. A listed layer adapts a utility skill like any other
(`body:text` stacks on it, `@replace` replaces it).

| Skill | Runs | Does |
| --- | --- | --- |
| `/registry-refresh` | `dcf-registry refresh --session "${CLAUDE_SESSION_ID}"` | (1.7.0) resolve now for the calling agent's own path and hand over to it alone (its session id, found in each adapter's `list`); an unknown or unsubstituted id refreshes every recorded hand-over, each path once; with no record, for the path the latest view was resolved for, to every CLI adapter on PATH. Claude Code picks the change up in the running session; a CLI that does not watch its skills folder needs its session restarted; a skill already used in a conversation keeps its old text until a new conversation |
| `/registry-explain <path>` | `dcf-registry explain <path> [--uses] [--color auto|always|never]` | read-only, shown to the person |
| `/registry-remember [skills/<name>] <line>` | `dcf-registry remember [--skill <name>] -- <line>` | appends `body:text = <line>` under `[skills/<name>]` (or `[skills/*]`, every skill) to `remembered.reg` in the folder of the layer marked `writable: true`, then refreshes. Refused, nothing written: no writable layer, two, a writable layer without a `path` source (a git or http layer changes through its owner's release), a folder that is not there or not writable, an empty line, a line starting with `@`. Only when the person asks (`disable-model-invocation`) |

## Handing skills to a CLI (1.1.0)

`dcf-registry handover <cli> [<name> <folder>]` asks `agent-adapter-<cli> supports` for `skills` and,
when it is listed, runs `agent-adapter-<cli> skills <name> <folder>` with the current view's
`skills/` folder in `COMPONENT_REGISTRY_SKILLS`, holding `resolve.lock` shared so no resolve swaps the
view out mid-copy. The adapter copies the skills into the CLI's own skills folder, marks its copies,
removes those no longer resolved and never touches anything else (ADR-0064 amends the CLI contract
of ADR-0037; Claude Code: `claude-code` 1.12.0). No adapter, or one without the verb: exit 3 and one
line, the CLI keeps its plain skills (NFR-12).

At an agent's start the participant component (`claude-code` with `participants: true`) runs
`dcf-registry resolve` (`--as` the agent's `registry-path` from the agents list, else
`COMPONENT_REGISTRY_WHOAMI`) and `dcf-registry handover <cli> <agent> <folder>`. It never blocks the
start: no layer list, a failed resolve or a CLI that cannot take skills is one line. Resolve and
the hand-over together get at most `COMPONENT_REGISTRY_START_WAIT` seconds there (default 15, a
hanging fetch and a held lock included); past it the CLI starts with the last good skills already
in its folder, said in one line. `/registry-refresh` keeps `COMPONENT_REGISTRY_LOCK_WAIT`.

## A view per agent path (1.7.0)

Agents with different `registry-path`s in one container each get the skills their path resolves
([ADR-0068](https://github.com/nabil-becker/devcontainer-features/blob/main/docs/adr/0068-each-agent-reads-the-skills-its-registry-path-resolves-through-an-added-directory-and-the-personal-folder-keeps-what-every-agent-shares.md),
proposed; it amends ADR-0064's "one per container").

```text
  agents start rev   resolve --as /Corp/review  ->  paths/+Corp+review -> views/<a>/
                     handover claude rev <folder> --as /Corp/review
  agents start host  resolve (who-you-are /Corp/me) -> paths/+Corp+me -> views/<b>/
                     handover claude host <folder>       (the setting's view, never <a>)
  Claude Code:  $CLAUDE_CONFIG_DIR/skills              what <a> and <b> have alike
                registry-agents/rev.<sum>/registry     the rest of <a>, --add-dir for rev
                registry-agents/host.<sum>/registry    the rest of <b>, --add-dir for host
```

- **Views.** `resolve` points `paths/<path, / as +>` at the view it made, besides `view` (the
  latest). A resolve removes only the views no pointer names; `forget` also drops the pointers of
  paths no hand-over record names (but the latest view's).
- **The lock.** One `resolve.lock` for every path, as before: the layer copies under `copies/` are
  shared between paths, so two resolves never interleave; a hand-over holds it shared while it
  reads a view. A second agent's resolve waits for the first (the start limit,
  `COMPONENT_REGISTRY_START_WAIT`, bounds it); a lock per path would let two fetches write one copy.
- **Records.** `handovers.tsv`: CLI, agent, folder, path, and `as` (the agent's own path) or
  `whoami` (the setting, followed when it changes). `dcf-registry handovers` prints it; `refresh`
  repeats it; `forget <cli> <name> <folder>` removes a line after the adapter dropped the agent's
  copies (the adapter's `skills` verb with `COMPONENT_REGISTRY_FORGET=1`). `agents up` forgets an
  agent no longer in the list. The sessions no agent started are recorded as the agent
  `component-registry` in the repository root (a `refresh --as <path>` or a `handover` with no
  agent); nothing forgets it on its own: `dcf-registry forget claude component-registry <root>`.
- **Mid-session refresh.** `/registry-refresh` passes the session id Claude Code substitutes; the
  agent is found by that id in each adapter's `list` (name, id, state, folder) and its record, so
  its own path is refreshed and nothing else. A changed layer that other agents also read reaches
  them at their next start or refresh; meanwhile Claude Code moves that skill out of the shared
  folder into each agent's own (the views no longer agree), so no agent reads another's text.
- **Where the CLI keeps them** is the adapter's (NFR-13). Claude Code (claude-code 1.14.0): what
  every agent's view has alike stays personal, the rest goes to an added directory per agent; see
  the claude-code notes.
- **Disk.** A view per path in use (a few kilobytes each), and in Claude Code each agent's view
  kept twice at most.

## The match rule

For who you are, `W`:

1. **Which lines apply**: a line's scope, as a pattern, matches `W` or an ancestor of `W`
   (`/Corp` applies to `/Corp/MyDepartment/team/me`, `/Corp/Finance` does not). An exclusion
   section takes out the sections above it in its file for what it matches.
2. **Order** per key: the higher layer wins; inside a layer, the deeper the ancestor of `W` the
   scope matched, the stronger; then fewer wildcard segments; then the later line (sources in
   their listed order, files in name order).
3. **Permissions are never widened**: `allowed-tools`, `disallowed-tools` and any key starting
   `permission` come from the component's lowest layer only.
4. **Locks**: the lowest layer that locks a key keeps it; a higher layer's line is skipped and
   reported. A lock beats `@replace` too.
5. **@replace** drops every weaker line of that component (locked keys excepted).
6. **Types**: the lowest layer that defines a key fixes its type; a line of another type is
   skipped and reported.
7. **Merge by type**: `value` and `ref`, the strongest line; `list`, items combined from the
   weakest line to the strongest, each `!item` removing what came before; `text`, every line
   stacked from the lowest layer to the highest, one `## Layer <id>` heading per layer unless the
   layer says `heading: false` (1.3.0; then one blank line only); the first block's `---` front
   matter stays at the top of `SKILL.md`, with the resolved `name` and `description` values
   written into it (1.3.0).

`resolve` fails only for a missing who-you-are path or a `required` layer never fetched.

## The resolved view

`$COMPONENT_REGISTRY_STATE_DIR/view` is a symlink to `views/<stamp>/`, replaced in one rename, so
a reader sees the old view or the new one, never half of each:

| Path | What it holds |
| --- | --- |
| `skills/<name>/` | `SKILL.md` and the skill's files: what a consumer copies |
| `meta/skills/<name>/values/<key>` | each resolved value (a list one item per line; text as stacked) |
| `meta/skills/<name>/keys.tsv` | key, type, one-line summary |
| `meta/skills/<name>/provenance.tsv` | every line considered: state (`used`, `overridden`, `skipped`, `dropped`, `excluded`, `not-applying`), key, type, layer, rank, version, `source:file:line`, data, why; `-` for an empty field |
| `meta/refs.tsv` | every ref: from, key, target, its component and key, `ok` or `dangling`, why |
| `meta/problems.tsv` | lines that could not be read |
| `layers.tsv`, `whoami`, `resolved` | each source's version and state (`fetched`, `unchanged`, `offline`, `missing`), who it was resolved for, when |

## State

Layer copies (`copies/<layer>/<n>/`, with `<n>.meta`: the pin, the version, the fetch time), the
resolved views and `resolve.lock` live in a named volume (`component-registry-state-${devcontainerId}`)
on `/var/lib/devcontainer-features/component-registry` (NFR-1). They are as sensitive as their most
sensitive layer (a person's own layer may hold health facts), so everything is owner-only: the
setup script sets the folder to `0700` at every start and `dcf-registry` writes with `umask 077`.
None of it is committed. `resolve` removes the copies no layer still names; a changed pin is a
new copy, never the old one as a fallback. A bind mount on the same target keeps it on the host
disk instead.

## First real use: architecture-review in two layers (slice 4)

This repository's own devhost is the first user. `.devcontainer/registry.yml` lists two layers,
both `required` (a missing one leaves the last view, never a half skill that would shadow the
committed one) and both `at: /` (they apply to every who-you-are path):

| Rank | Layer | Source | Holds |
| --- | --- | --- | --- |
| 1 | `devhost` | `path` `/usr/local/share/devhost/registry` (the devhost Feature 1.16.0, from `local-features/devhost/share/registry`) | the review method: front matter, steps, the section format, "never edit the design sections"; usable alone |
| 2 | `devcontainer-features` | `path` `.devcontainer/registry/repo` (committed) | "In this repository": the NFR file, the CLI capability matrix and NFR-12, NFR-13, the placement layers |

Both say `heading: false` (component-registry 1.3.0), so the two read as one skill. The
participant start hook resolves it for `COMPONENT_REGISTRY_WHOAMI` (containerEnv, a role
default `/devcontainer-features/operator`; a person sets theirs in `.devcontainer/.env`) and hands
the skills to Claude Code.

**The equality check** (`task test:registry-first-use`, part of lint) resolves the real layer
list and compares the resolved `skills/architecture-review/SKILL.md` with the committed
`.claude/skills/architecture-review/SKILL.md`: **byte for byte equal**. What this use found, and
what 1.3.0 changed for it:

- **A heading for every layer** (the first included) made byte equality impossible in 1.2.0;
  the layer key `heading: false` (1.3.0) stacks without one.
- **Front matter came from the lowest block only**: a `description:value` in a higher layer was
  never written into `SKILL.md`. From 1.3.0 `name` and `description` values are.
- **Text only appends, layer by layer.** The repository-specific lines sat inside the method
  (two of the seven checks, the NFR path in the first, the placement layers in the sixth); no
  `.reg` line can put a higher layer's text between a lower layer's lines. The committed skill
  was restated once, in the same words, as the method then an "In this repository" section the
  method points to; the Operator accepted the restated skill as the reference (2026-11-20), with
  no anchors or slots.
- **A relative link breaks.** The resolved copy lives in the CLI's skills folder, so a link such
  as `../../../PROCESS.md` points nowhere; the base layer names files as plain paths.

### Switch-over (proposed, not done)

Today both the committed skill (`.claude/skills/architecture-review/`, project scope) and the
resolved one (Claude Code's personal skills folder, handed over at the agent's start) exist; the
personal one wins the name, so after the next rebuild the session runs the resolved skill, equal
to the committed one byte for byte. Switching over (the Operator: it waits) would take:

- **This repository**: delete `.claude/skills/architecture-review/` (the resolved copy is then
  the only one; a session started without the registry, on the workstation for example, has no
  architecture review), and drop the template copy's equality check from the test.
- **The devhost Feature's consumers**: `devhost-init` copies the template (`init.py`) into each
  consumer's `.claude/skills/`; that copy holds this repository's section too. Either the template
  becomes the base layer only (consumers keep a committed skill, generic), or consumers add the
  component-registry Feature and a `registry.yml` naming the devhost layer (plus their own layer
  for their rules) and `devhost-init` stops copying it. Each consumer's
  `DEVCONTAINER_CONTRIBUTION.md` would say which.
- **Nothing a reader sees**: the resolved skill already equals the committed one byte for byte.

## Use it

```json
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/component-registry:1": {}
}
```

```sh
echo 'COMPONENT_REGISTRY_WHOAMI=/Corp/MyDepartment/team/me' >> .env   # git-ignored
task component-registry:resolve
task component-registry:explain -- skills/architecture-artifacts
task component-registry:explain -- skills/diagrams --uses
task component-registry:explain -- skills/architecture-artifacts --color always   # a colour per layer
```

## Check that it works

`task component-registry:version` prints the version, the layer list and where it came from, who
you are and the resolved view. `task component-registry:resolve` prints one line per source
(`fetched <version>`, `unchanged at <version>`, an unreachable one `using the last good copy`),
every skipped line with its reason, and `resolved N component(s) for <W>`.

## Tasks

- `component-registry:version`: the version, the layer list, who you are, the resolved view.
- `component-registry:resolve`: fetch, merge and swap in the resolved view (`-- --as <path>`).
- `component-registry:explain`: `-- <path>[:key] [--uses] [--color auto|always|never]`, read-only. With colour, each line is
  painted by its layer, a legend (layer id, colour name) comes first, and skipped lines and dangling
  refs are dim and struck through. Six colours from the Okabe-Ito set (orange, sky-blue, teal,
  yellow, blue, purple), chosen for colour-vision deficiencies; every line also carries its layer id,
  so colour is never the only signal. `auto` (the default) colours only on a terminal and never
  when `NO_COLOR` is set; `always` wins over `NO_COLOR`. Without colour the text is byte for byte
  that of 1.3.0.
- `component-registry:setup`: re-run the start hook.
- `component-registry:refresh`: resolve and hand over now (`-- --as <path>`, `-- --session <id>`);
  `/registry-refresh`.
- `component-registry:remember`: `-- [--skill <name>] -- <line>`; `/registry-remember`.

## Pairs with

- `go-task` for the tasks; git in the image for `git` sources; `openbao` for `dcf-secret` (a
  source secret without it: the source says so and reads without one).
- `claude-code` 1.12.0: its adapter's `skills` verb, and with `participants: true` the participant
  component, which resolves and hands over at every agent's start. Neither is required: without
  them `handover` and `refresh` say no adapter takes skills.
- `cloud-folder` 1.4.0: its `cloud-folder` source. `curl` in the image for `http` sources.
- Later releases: the launcher (a file share mount, `COMPONENT_REGISTRY_WHOAMI` from the
  workstation).

## Limits

- Skills only; other kinds are reported and not resolved.
- Agents with different who-you-are paths each keep their own skills only where the CLI's adapter
  keeps them apart (Claude Code from claude-code 1.14.0, ADR-0068); another CLI reads the latest
  hand-over. In Claude Code a session not started through `agents` reads only the skills every
  agent's view has alike, and a project skill of the same name beats an agent's own copy (the
  registry's then runs as `/registry:<name>`).
- `remember` writes to a `path` source only, appends, and never edits or removes a line; to take
  one back, edit `remembered.reg` in your layer.
- Sources `git` and `path` only. A `path` source's version is a fingerprint of names, sizes and
  modification times, so a change that keeps all three is not seen.
- `*` and `**` are whole segments; there are no value filters.
- The text heading is `## Layer <id>` or none (`heading: false`), per layer, never per line; a
  higher layer's text only appends. Of the front matter only `name` and `description` are values.
- A `ref` is checked against this view only: its scope part is ignored, its component and key
  must resolve for the same who-you-are path.

## Why it exists

Claude Code distributes skills through plugins and marketplaces, with a fixed scope order for one
vendor (NFR-9). The registry adds what they do not: any number of owners and sources stacked in
one order, merge by value type inside one skill, locks, a who-you-are path, and `explain`. It hands
its result to the CLI's own skills folder (1.1.0), so the two do not compete.

## Version and upgrade

Pin the major in the Feature reference (`component-registry:1`); a rebuild picks up the newest
1.x. The layer copies and the view are rebuilt by the next `resolve`, so an upgrade needs nothing
else; the `.reg` grammar and the layer list keys only grow within 1.x.
