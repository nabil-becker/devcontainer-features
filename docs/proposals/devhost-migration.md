# Proposal: migrate the devhost Feature out, and retire it

Status: draft 2026-11-23, for the architecture review and the Operator. Nothing is built. Backlog
item `devhost-out-of-feature`.

Who this serves: the Operator, who rules on it; this repository's engineers, whose sessions run on
these tools every turn; and a consumer's maintainer (the office, DSNP), who today carries a copy
of the devhost Feature planted from the seed and must be able to move off it without breaking
their hooks, guards or tasks.

The Operator's direction (2026-11-23): devhost is a local-only Feature because it should no longer
be a Feature. Whatever it does that is not a separate Feature, or part of the repository's own
`.devcontainer/` declaration, moves out.

## 1. What stays, what goes

The word stays. The **devhost** is the dev container where sessions run and the backs act
(LEXICON.md). That concept, `docs/model/c4-container.md` ("inside the devhost") and the
`.devhost/` folder of repository settings keep their names. What goes is the Feature
`local-features/devhost` (1.18.0): one installer that bundles a back runner, four jobs, eleven
tools, eleven skill templates, a registry layer, a scaffold and seventeen tasks.

Today, and the end state this proposal recommends:

```
TODAY                                         END STATE
-----                                         ---------
local-features/devhost  (one Feature)         src/backs     (published)  runner, tester, state
  runner, jobs, condenser                     src/records   (published)  ledger, backlog, ADRs,
  ledger, backlog, ADR, costs, site                                      costs, briefing, verify,
  verify, branches, shutdown check                                       branches, site, init,
  init + templates + 11 skills                                           scribe/secretary/librarian,
  registry layer (architecture-review)                                   registry layer (skills)
  task devhost:*                              this repo's .devcontainer/ + Taskfile
        |                                       settings, mounts, seed:package, shutdown:check
        | copied whole by devhost-package     the seed (docs/iterations/)
        v                                       starter names published backs + records
seed: starter/features/devhost  ---> office,  local-features/agentic-register (unchanged)
                                     DSNP     local-features/devhost  DELETED
```

## 2. Inventory and destinations

Destinations: **B** the new `backs` Feature; **R** the new `records` Feature; **CR** a
component-registry layer (shipped by `records`); **Repo** this repository's `.devcontainer/`,
`Taskfile.yml` or scripts; **Seed** the seed's own tooling; **Other** an existing published
Feature (named); **Drop**. The split into `backs` and `records` is decision M1; publishing them is
M2.

Users: **H** the host session (and cons), **Bk** the backs, **CI** the pull-request checks,
**C** consumers through the seed. **C!** marks an item that today makes a consumer depend on
devhost: a name committed in their repository or a behaviour they rely on.

Paths are under `local-features/devhost/` unless absolute.

### 2.1 Commands on PATH

| Command | Source | What it does | Users | Destination | Why |
|---|---|---|---|---|---|
| `devhost-run-job` | `share/bin/run-job.sh`, `lib.sh` | Runs one back after a turn: lock, offset, condense, headless `claude -p`, metrics line, quiet notice, OpenBao key fetch | Bk, **C!** (hooks) | B | The generic runtime; knows nothing of records |
| `devhost-condense` | `share/bin/condense.py` | Prints a transcript stretch the way a back reads it | Bk, H | B | Used only by the runner |
| `devhost-redact` | `share/bin/redact.py` | Name guard: redact names and forbidden words | Bk (jobs), H | R | Only the record-writing jobs and the site call it |
| `devhost-briefing` | `share/python/briefing.py` | The session-start briefing: records, pending, spend, branches, OpenBao and gh state, version drift | H, **C!** (SessionStart hook) | R | Reads the records; the OpenBao, gh and drift lines see 2.6 |
| `devhost-costs` | `session_cost.py` | Cost of the newest session from Claude Code's transcripts | H, scribe | R | Alternative: an adapter verb in `claude-code` (transcripts are a CLI fact, NFR-13); later |
| `devhost-report` | `report.py` | Monthly cost report and its store | H | R | Records |
| `devhost-ledger` | `ledger.py` | Ledger reader and writer, register mode, mirror, reviews, cost archive | scribe, H, setup | R | Records; uses agentic-register when set (M4) |
| `devhost-adr` | `adr.py` | New or list ADRs | H, `new-adr` | R | Records |
| `devhost-verify` | `verify.py` | The commit check: ledger, ADR shape, model, secrets, names, emails, identity, conflict markers, hook modes, task descs, skill frontmatter | H, **C!** (pre-commit) | R | One check stays (ADR 0042); the split is M3 |
| `devhost-register-guard` | `register_guard.py` | Guard an agentic-register register runs on each entry | agentic-register, **C!** where a register names it | R | Same rules as verify |
| `devhost-branches` | `branches.py` | Branch rule `<type>/<id>/<n>`, list, prune, pre-push check | H, **C!** (pre-push) | R | The rule needs the backlog. Alternative: `git` Feature with a pluggable id check |
| `devhost-init` | `init.py` + `templates/` | Scaffold: hooks, ledger, backlog, lexicon, process, ADR folder, githooks, CLAUDE section, skills | consumer maintainer | R (`records init`) | Writes the records' shape and the hooks for both Features; stops copying skills (2.4) |
| `devhost-site` | `site.py`, `templates/site/` | One-page homepage of the records and docs | H, `publish-site` | R | A view of the records |
| `devhost-package` | `package.py` | Assembles the seed, copies `local-features/devhost` into it | H, `drop-a-seed` | Seed (Repo script, `task seed:package`) | Exists for this repository's iterations; the copy of devhost goes |
| `devhost-shutdown-check` | `shutdown.py` | Safe to stop: tree clean and pushed, no back lock or pending stretch, no night shift mid-plan | H, `devcontainer:stop`, **C!** (bootstrap fallback) | split: B `backs:shutdown-check` (locks, pending); R `records:shutdown-check` (night shift); Repo `task shutdown:check` aggregates them with the git rule | ADR 0022 already prefers `task shutdown:check`; `cloud-folder:shutdown-check` is the pattern |
| `devhost-setup` | `devhost-setup.sh` | post-create: state folder, report wiring, mirror restore | H | split: `backs-setup`, `records-setup` | Each Feature its own hook (NFR-1) |
| `dcf-persist` | `dcf-persist.sh` | Shared state-folder helper | setup | B and R vendor it | The `common` pattern |

### 2.2 Jobs (the backs)

| Job | Source | What | Destination | Why |
|---|---|---|---|---|
| scribe | `share/jobs/scribe/` (brief, entry template, job) | Ledger entries, cost measures, register signing | R, installed into the backs' jobs path | It writes a record |
| secretary | `share/jobs/secretary/` | Backlog adds and ticks; backlog guard | R, same | Same |
| librarian | `share/jobs/librarian/` | Lexicon, ADRs, model; docs guard | R, same | Same |
| tester | `share/jobs/tester/job.sh` | Runs `task test` when code changed | B | Model-free, generic |
| undo guards | `share/python/guards.py`, `pending.py` | Backlog and docs undo; scribe's pending list | R | Belong to the jobs above |

The job contract changes in one way: `DEVHOST_JOBS_DIR` (one folder) becomes `BACKS_JOBS_PATH`
(a list), so `records` adds its folder and a repository can still add its own. Later, a back's
brief could become a component-registry agent definition (release 2 is built); not in this
migration.

### 2.3 Hooks, git hooks and repository files

| Item | Where | Users | Destination | Note |
|---|---|---|---|---|
| SessionStart `devhost-briefing` | each repo's `.claude/settings.json` | H, **C!** | Repo (committed, renamed `records-briefing`) | Written by `records init` |
| Stop, SubagentStop `devhost-run-job <job>` | same | Bk, **C!** | Repo (committed, renamed `backs-run-job`) | Alternative: the Feature writes the hooks into Claude Code's managed settings, no repo wiring; not now: hooks stay visible and per repository |
| permissions allow-list naming `devhost-*` | same | H, **C!** | Repo (renamed) | |
| `.githooks/pre-commit` (`devhost-verify --quiet`) | template | all commits, **C!** | Repo (renamed `records-verify`) | |
| `.githooks/pre-push` (`devhost-branches --check-push`) | template | **C!** | Repo (renamed) | |
| `.devhost/redact-names.txt`, `name-exceptions.txt`, `allowed-secrets.txt`, `site-url`, `site/` | each repo | R tools, **C!** | Repo, folder name kept (M6) | Settings of the devhost, not of the Feature |
| `.devhost/CLAUDE.devhost.md` (included by CLAUDE.md) | template | H, **C!** | R (`records init` template); later a registry prompt | The text names `task devhost:*`; renamed with the tasks |
| `LEXICON.md`, `PROCESS.md`, `TODO.md`, `docs/adr/0000-template.md` + `README.md`, `docs/ledger/README.md`, `docs/night-shift/README.md`, `.devhost/.gitignore` | templates | consumer maintainer | R (`records init`) | The records' shape |

### 2.4 Skills and the registry layer

| Skill | Today | Users | Destination | Why |
|---|---|---|---|---|
| `architecture-review` (generic method) | `share/registry/` layer + template copy `init` plants | H, **C!** (planted copies) | CR: the `records` layer | The copy and its drift test go; D1 becomes moot (section 6) |
| `close-session`, `ledger-review`, `new-adr`, `night-shift`, `publish-site` | templates, copied by `init` and committed | H, **C!** (committed copies) | CR: the `records` layer | Each drives `records` tools; released with them |
| `shutdown-devhost`, `restart-devhost` | same | H, **C!** | CR: the `records` layer | Alternative: a `devcontainer-cli` layer, which owns the stop |
| `walkie-talkie` | same | the Operator | CR: the Operator's personal layer | A personal habit, not a repository rule |
| `plant-a-seed`, `drop-a-seed` (+ `journalist.md`, `INTERVIEW.md`) | same, and the seed's `skills/` | H, the next project | Seed | Already carried by the seed; `package.py` goes beside `drop-a-seed` |
| `registry/devhost.layer` | `share/registry/` | component-registry | CR: `records.layer` at `/usr/local/share/records/registry` | Renamed layer id |

This repository's committed copies (`.claude/skills/close-session` and the others above) are
deleted once the layer resolves them, because a committed project skill shadows the registry's.
`design-review` and `review-boards` are this repository's own and are not touched.

### 2.5 Tasks

| `task devhost:` | Destination |
|---|---|
| `version`, `setup` | `backs:` and `records:` each |
| `log`, `jobs:state`, `approles:setup` | `backs:` |
| `ledger`, `briefing`, `branch`, `branches`, `report`, `costs`, `adr`, `verify`, `init`, `site` | `records:` |
| `shutdown-check` | `backs:shutdown-check`, `records:shutdown-check`; Repo `shutdown:check` |
| `package` | Repo `seed:package` |
| this repo: `test:devhost`, `test:devhost:docker` | Drop: the Features' tests run under `task test FEATURE=<id>`, in CI again (ADR 0025 had lost that) |

Every `task devhost:*` name is **C!**: consumers' CLAUDE sections, PROCESS and skills name them.
A legacy `devhost:` namespace delegates to the new tasks while the shims last (M6).

### 2.6 Settings, state and variables

| Item | Today | Destination |
|---|---|---|
| volume `devhost-state-${devcontainerId}` at `/var/lib/devcontainer-features/devhost` | Feature mount | B: `backs-state-*` at `/var/lib/devcontainer-features/backs` (NFR-1). Slice 1 mounts the old volume at the new target in this repo's `devcontainer.json`, so offsets carry over |
| `PYTHONPYCACHEPREFIX` | Feature `containerEnv` | B and R both set it |
| `postCreateCommand devhost-setup`, option `installTaskfile` | Feature | each Feature |
| Backs variables: `DEVHOST_STATE`, `DEVHOST_JOBS_DIR`, `DEVHOST_JOB_CHILD`, `DEVHOST_CONTAINER_MARKERS`, `DEVHOST_JOB_SKIP_AGENTS`, `DEVHOST_JOB_QUIET_SECS`, `JOB_MIN_CHARS_SUB`, `SCRIBE_MODEL`/`SECRETARY_MODEL`/`LIBRARIAN_MODEL`/`TESTER_MODEL`, `TESTER_CMD`/`PATHS`/`TIMEOUT`, `DEVHOST_BACKS`, `DEVHOST_KEY_TMPFS`, `DEVHOST_BAO` | runner | B, as `BACKS_*` (the per-job `<JOB>_MODEL` names stay) |
| `DEVHOST_JOB_CHILD` read by `openbao` (`openbao-lib.sh`) and `facilitator` (`cli.py`) | two published Features | Other: both add `BACKS_JOB_CHILD` to their agent-job list; the old name stays in the list until the shims go |
| Records variables: `DEVHOST_ROOT`, `DEVHOST_RECORDS_DIR`, `DEVHOST_LEDGER_REGISTER`, `DEVHOST_LEDGER_DIR`, `DEVHOST_BACKLOG`, `DEVHOST_COSTS_DIR`, `DEVHOST_REVIEWS_DIR`, `DEVHOST_LEXICON`, `DEVHOST_ADR_DIR`, `DEVHOST_MODEL_DIR`, `DEVHOST_NIGHT_SHIFT_DIR`, `DEVHOST_REVIEW_EVERY`, `DEVHOST_MIRROR_TIMEOUT`, `DEVHOST_MONTHLY_TARGET`, `DEVHOST_ENGINEER`, `DEVHOST_REDACT_FILE`, `DEVHOST_REDACT_WITH`, `DEVHOST_FORBIDDEN_WORDS`, `DEVHOST_BASE_REF`, `DEVHOST_GH`, `DEVHOST_AGENTIC_REGISTER`, `AGENTIC_REGISTER_LIB`, `DEVHOST_OPENBAO_SETUP` | tools | R, as `RECORDS_*` (`DEVHOST_RECORDS_DIR` becomes `RECORDS_DIR`); `DEVHOST_ENGINEER` and `DEVHOST_ROOT` are read by both (B reads `RECORDS_*` when set, else its own) |
| this repo's `containerEnv`: `DEVHOST_ENGINEER`, `DEVHOST_MONTHLY_TARGET`, `DEVHOST_REVIEW_EVERY`, `DEVHOST_RECORDS_DIR`, `DEVHOST_LEDGER_REGISTER` | `.devcontainer/devcontainer.json` | Repo (renamed in slice 2) |
| `DEVHOST_SHARE` and the version-drift line ("`local-features/devhost` is newer than installed") | briefing | Repo: a check that any staged Feature (`src/`, `local-features/`) is newer than the installed one, in `post-create.sh` or `task features:drift`. It was never devhost-specific |
| OpenBao lines and gh-login line in the briefing | briefing | R for now. Later each Feature contributes its own line (a `briefing.d` folder); a gap to close, not a decision |
| agentic-register `registers` option `guard=/usr/local/bin/devhost-register-guard` | this repo's `devcontainer.json` | Repo (path renamed) |
| `.devcontainer/registry.yml` layer `path: /usr/local/share/devhost/registry` | this repo | Repo (path and id renamed) |
| `features:stage` | Taskfile | unchanged; `local-features/` keeps `agentic-register` only |

### 2.7 Placement (NFR-13)

| Element | Where | Why |
|---|---|---|
| back runner, lock, offsets, condenser, metrics, key fetch, tester | `backs` | Manages the agent's environment (what runs after a turn); uses Claude Code's hooks and `claude -p` as they are |
| ledger, backlog, ADRs, costs, briefing, verify, branches, site, init, the three record jobs | `records` | The records and their rules |
| way-of-working skills | `records`' registry layer | Registry layers are the home of skills (ADR 0063, 0064, 0074) |
| settings values, mounts, register guard path, layer list | each repository's `.devcontainer/` | Per-repository values |
| seed assembly | this repository's scripts and the seed | Only an iteration's end uses it |

NFR-12: backs runs Claude Code hooks and `claude -p`. Another CLI has no backs; `backs-setup`
says so in one line. A vendor-neutral `run-headless` adapter verb is later work.

## 3. Decisions for the Operator

**M1. How the devhost Feature is split.**

- (a) One Feature, renamed (for example `way-of-working`), contents unchanged.
- (b) Two: `backs` (runtime) and `records` (records, guards, skills). **Recommended.**
- (c) Three: (b) plus `repo-guards` for the generic commit checks.
- (d) The backs into `claude-code` through the participant component, `records` alone.

Recommendation (b). The runner is generic and has no records knowledge; the rest shares one
Python library (`devhost_common.py`), so splitting it further means a shared component to
vendor. (a) only renames the thing the Operator asked to take apart. (d) breaks ADR 0061's rule
that the participant component stays shell-only.

**M2. Published or local.**

- (a) Publish `backs` and `records` from `src/`. ADR 0025 and ADR 0044 are superseded.
  **Recommended.**
- (b) Keep them in `local-features/`, and the seed carries them as files (ADR 0044 extended).

Recommendation (a). Both consumers already run devhost, so it is not repository-internal, which
was ADR 0025's reason. Publishing ends the seed's file copy, puts the Docker tests back in CI and
lets consumers pin a version (NFR-3).

**M3. Where the commit guards live.**

- (a) All in `records verify`, one check as today (ADR 0042 stands). **Recommended.**
- (b) Generic hygiene (secrets, names, emails, identity, conflict markers, hook modes) in a new
  `repo-guards` Feature; the records guards in `records`; the repository's pre-commit runs `task
  verify`, which composes them.
- (c) In this repository's scripts. Consumers lose them; not viable.

Recommendation (a) now. (b) is right once a repository wants the hygiene without the records;
none does today. Either way the check gets the linter CLI contract (NFR-11, ADR 0035).

**M4. Records and agentic-register.**

- (a) Keep them apart: `records` uses a register when `RECORDS_LEDGER_REGISTER` is set, and ships
  the register guard. **Recommended.**
- (b) Merge the ledger tooling and the guard into the local `agentic-register` Feature.

Recommendation (a). `agentic-register` is vendored unchanged from AOF (VENDORED.md; ADR 0061 keeps
it there). Merging forks it. The Markdown ledger mode needs no register at all.

**M5. How consumers receive the way-of-working skills.**

- (a) The `records` Feature ships them as its registry layer (`path` source, pinned with the
  Feature, offline). **Recommended.**
- (b) A `git` layer from this repository (for example `registry/way-of-working/`, pinned to a tag).
- (c) The seed and `records init` copy them into each repository (today).

Recommendation (a). The skills call `records` tools, so they ship and version with them, as the
utility skills ship with component-registry (ADR 0064). (b) updates faster but adds a fetch at
every start and lets the skills drift from the tools. (c) keeps the shadowing copies. `records`
does not `dependsOn` component-registry: without it the tools and hooks work and the setup says in
one line that no skills are resolved; the starter declares component-registry.

**M6. Names during and after the move.**

- (a) New names (`backs-*`, `records-*`, `task backs:*`, `task records:*`, `BACKS_*`,
  `RECORDS_*`), with an option `legacyNames` (default true in 1.x) that installs the old
  `devhost-*` commands as shims, a `devhost:` task namespace that delegates, and reads `DEVHOST_*`
  as a fallback. Removed in 2.0.0. The `.devhost/` folder keeps its name. **Recommended.**
- (b) Keep every `devhost-*` and `DEVHOST_*` name for good.

Recommendation (a). A Feature's tasks and variables carry its id (NFR-2, NFR-6). The shims keep
every consumer's committed hooks and git hooks working with no edit until they choose to
re-run `records init`. `.devhost/` names the devhost (the container), which stays.

## 4. Migration order

Each slice leaves the backs, the pre-commit guard and `task devhost:*` working: through the old
Feature until slice 1, through the shims after it.

```
slice 1 lift         slice 2 rewire        slice 3 release+seed    slice 4 shims off
src/backs            this repo uses        Operator releases       backs, records 2.0.0
src/records          new names; skills     backs, records 1.0.0;   legacyNames removed
legacyNames on       from records layer;   seed names them;        after office and DSNP
local-features/      openbao, facilitator  office, DSNP swap       re-ran records init
devhost deleted      add BACKS_JOB_CHILD   their devhost copy
```

**Slice 1: lift.** `git mv` the code into `src/backs` and `src/records` per section 2, new share
folders and command names, `legacyNames` on. This repository's `devcontainer.json` swaps
`./features/devhost` for `./features/backs` and `./features/records`, and mounts the old
`devhost-state-${devcontainerId}` volume at the backs' state target. Tests move from
`test/devhost` to `test/backs` and `test/records` (unit tests stay in lint; Docker tests join
`task test`). The source-guard rule (verify runs the checkout's own guards) points at
`src/records`. `local-features/devhost` is deleted. A new ADR supersedes ADR 0025 for these parts.
Office, DSNP: nothing changes; they run their seed copy. Seed: no seed is dropped until slice 3
(`devhost-package` would refuse: the folder it copies is gone).

**Slice 2: rewire this repository.** `.claude/settings.json`, `.githooks/`, `containerEnv`,
`registry.yml`, the register guard path, CLAUDE.md, `.devhost/CLAUDE.devhost.md`, PROCESS.md,
LEXICON.md and the skills use the new names. The way-of-working skills resolve from the `records`
layer; the committed copies go. `task shutdown:check` and `task seed:package` are added; the
bootstrap's shutdown fallback names `task shutdown:check` only. `openbao` and `facilitator` add
`BACKS_JOB_CHILD` (patch releases). The six standing documents get section 5's deltas. Office,
DSNP: nothing yet. Seed: nothing yet.

**Slice 3: release and seed.** The Operator releases `backs` 1.0.0, `records` 1.0.0 and the
patches. The starter's `devcontainer.json` names the published `backs`, `records` and
`component-registry` and gains a `registry.yml`; `starter/features/devhost` and its SETUP.md
section go; `plant-a-seed` says so; `package.py` stops copying a Feature. ADR 0044 is superseded.
Office, DSNP: each replaces `./features/devhost` with the published Features in
`devcontainer.json`, deletes `.devcontainer/features/devhost`, adds the old-volume mount line,
and may adopt the `records` layer (which settles `consumers-registry-layer`). Their committed
hooks, git hooks and task names keep working through the shims. Their
`DEVCONTAINER_CONTRIBUTION.md` records it.

**Slice 4: shims off.** Once both consumers have re-run `records init --force` (new hook and
git-hook names) and renamed their variables, `backs` and `records` 2.0.0 drop `legacyNames` and
the `DEVHOST_*` fallback; `openbao` and `facilitator` drop `DEVHOST_JOB_CHILD`; the old-volume
mount line goes after a `backs:state:adopt` copy. Office, DSNP: a major bump, announced in the
changelog.

## 5. Deltas to the standing documents (not applied)

Applied in the slice that makes each change true.

- `docs/architecture/state-of-the-architecture.md`: the diagram's `local-features/` box drops
  devhost; the "Built" table gains `backs` and `records`; the `local-features/` table drops the
  devhost row; the agentic-devhost reference architecture row names `backs`, `records` instead
  of "local `devhost`"; the component registry row names the `records` layer; the proposals table
  gains this proposal.
- `docs/architecture/data-flows.md`: the records flow names `RECORDS_DIR`, `records-ledger mirror`, `records-setup`; the commit flow names `records verify`; the
  registry flow's layer is `/usr/local/share/records/registry`.
- `docs/architecture/data-inventory.md`: the backs' state row becomes volume `backs-state-*`
  owned by `backs`; the registry-layer row moves to `records`; producer names `devhost-report`,
  `devhost-verify` renamed.
- `docs/architecture/workflows.md`: `task devhost:branch`, `task devhost:verify`, `task
  devhost:branches PRUNE=1`, `devhost-shutdown-check` renamed; the stop flow runs `task
  shutdown:check`.
- `docs/architecture/lifecycles.md`: the setting `DEVHOST_REVIEW_EVERY` renamed; the skill
  lifecycle's "devhost 1.16.0" layer becomes the `records` layer and the planted-copy state goes.
- `docs/model/c4-container.md`: the backs and guards boxes gain their owning Feature (`backs`,
  `records`); the component registry view's devhost layer becomes the `records` layer.
- `docs/model/c4-context.md`: no change (the devhost there is the container).
- `docs/model/ontology.toml`: a Feature id for `backs` and `records` if the model lists Features;
  the terms stay.
- `docs/reference-architectures/agentic-devhost.md`: local `devhost` becomes `backs`, `records`.
- `docs/principles/non-functional-requirements.md`: the "Today" counts gain two Features.

## 6. The open question D1 (`devhost-registry-dependency`)

D1 asks whether the devhost Feature should require component-registry, so that every devhost
repository gets skills one way and the planted template copy and its drift test go. It is moot:
the devhost Feature is deleted in slice 1, and with M5 the planted copy goes too, so there is one
way left whatever D1 says. What remains of it is whether `records` `dependsOn`
component-registry; M5 answers no (it works without, and the starter declares the registry).
The secretary can close D1 when M5 is ruled.

## 7. Relation to other work

- `consumers-registry-layer` (should office and DSNP adopt the registry layer): becomes part of
  slice 3.
- ADR 0022 (the shutdown check contract) is kept; only the fallback command changes.
- ADR 0042 is kept under M3 (a); amended under (b).
- ADR 0025 is superseded in slice 1, ADR 0044 in slice 3 (M2 (a)).
- The least-privilege proposal's step "the backs' `claude -p` narrowed" lands in `backs`.

## Architecture review (2026-11-23)

**Verdict:** fit with changes

The direction fits: two published Features along the line of the runtime and the records, skills through a registry layer, shims for the consumers. The changes below are gaps in the mechanism (a mount, a hook rename, the shutdown fallback), not in the split.

### Findings

Requirements checked (section shown in brackets). NFR-1: met for `backs`, open for `records` and the volume carry-over (finding 1). NFR-2: met, every task keeps its `desc` and each Feature leads with `version` (2.5). NFR-3: not applicable, nothing is downloaded; the key fetch is OpenBao's. NFR-4: not applicable, no official Feature exists. NFR-5: met if each `*-setup` stays idempotent and never fatal (2.1), to be shown in the tests. NFR-6: met by `BACKS_*` and `RECORDS_*` with a documented fallback (M6). NFR-7: met, no task is interactive today. NFR-8: not shown, two new Features need the ten-item NOTES (finding 9). NFR-9: not shown, `records` needs the paragraph on what differs from the planted devhost copy and from AOF's tools. NFR-10: not shown, a scenario per option (`legacyNames`) and a place in the global scenario (finding 9). NFR-11: not met as written (finding 6). NFR-12: met by a named fallback, with a gap in the matrix (finding 8). NFR-13: met for the runner, one placement finding (finding 7).

1. **Two mounts at one target (NFR-1, section 2.6, slice 1).** The proposal has the Feature declare `backs-state-${devcontainerId}` at `/var/lib/devcontainer-features/backs` and this repository's `devcontainer.json` also mount the old `devhost-state-*` volume at the same target. Docker refuses a duplicate mount point, and consumers are told to add the same line in slice 3. `records` also keeps state (the scribe's pending lists, `runs.jsonl`, the cost archive under `DEVHOST_STATE`) and the proposal gives it no volume or says it reads the backs' one. Recommended change: pick one carry-over: a `backs` option `stateVolume` (default the new name) that a repository sets to the old name, or `backs:state:adopt` shipped in slice 1 rather than slice 4; and state which Feature owns `runs.jsonl`, `pending-*` and the locks, so `records` either reads a documented path of `backs` or owns its own volume.
2. **`DEVHOST_JOB_CHILD` has more readers than the proposal lists (2.6).** Besides `openbao` (`src/openbao/openbao-lib.sh`) and `facilitator` (`src/facilitator/facilitator/cli.py`), the name is read by the launcher: `bootstrap/host/DevcontainerCli.psm1` (the refusal for the key-file tasks), `bootstrap/devcontainer.yml` descriptions, `src/devcontainer-cli` NOTES; the tester job sets it for the suite, and the openbao tests in the Taskfile name it. The launcher is vendored into every consumer. A missed reader silently drops a refusal that keeps shares out of agent transcripts (ADR 0056). Recommended change: list every reader (grep result in the proposal), make `backs` export both names for the whole 1.x line, and add a `devcontainer-cli` patch to slice 2; drop the old name only in slice 4 after all three Features agree.
3. **Dropping the shutdown fallback can turn a refusal into "stopping" (ADR 0022, slices 2 and 3).** Slice 2 makes the bootstrap name `task shutdown:check` only. A consumer that re-vendors the launcher before it defines `shutdown:check` gets "no shutdown check defined; stopping" and loses the tree-clean and backs-idle check without a message. Recommended change: keep the `devhost-shutdown-check` fallback in the bootstrap until slice 4 (the shim provides it), have `records init` add the `shutdown:check` task to the consumer's Taskfile, and amend ADR 0022 in the new ADR (the contract stays, the fallback command changes).
4. **The hooks belong to the Feature that owns the command (placement, 2.3).** `records init` writes the Stop and SubagentStop hooks that call `backs-run-job`, so `records` must know `backs`' command names and hook shape, and a repository with `backs` only has no way to wire it. Recommended change: `backs init` (a task `backs:init`) writes the runner's hooks and permission lines; `records init` writes the briefing hook, git hooks and record files, and the jobs it adds are registered through `BACKS_JOBS_PATH`.
5. **The runner is not free of the records (section 2.1 "knows nothing of records", 2.2).** `share/bin/lib.sh` defines the paths of the ledger, backlog, lexicon, ADR folder, model folder, night-shift folder and the ledger register (`hk_ledger_dir`, `hk_backlog`, `hk_lexicon`, `hk_adr_dir`, `hk_model_dir`, `hk_night_shift_dir`, `hk_ledger_register`), and `hk_guard` and `hk_measures` serve the record jobs; `run-job.sh` also calls `redact.py`. Moving the jobs to `records` while the helpers stay in the runner leaves `backs` carrying the records' variables. Recommended change: split `lib.sh` in the lift: `backs` keeps root, state, jobs path, key fetch and measures; the `hk_*` record paths and `redact` move to a library `records` installs and the jobs source, and the section says the runner calls `redact` only through the job file.
6. **The commit check does not meet the linter contract as written (NFR-11, ADR 0035, M3).** `devhost-verify` reads staged changes, the commit identity and hook modes, which NFR-11 says a check tool must not know ("knows nothing of git, staged changes or hooks"); `devhost-redact` is a transform tool and `devhost-register-guard` a check. M3 says only that the check "gets the linter CLI contract". Recommended change: either write the exception in `records` NOTES (the staged-diff and identity guards stay git-aware, ADR 0042) with the contract applied to the rest (paths, `-`, `--format json`, exit 0/1/2), or split the git-aware guards into the pre-commit script; the proposal should say which.
7. **Placement of three elements (NFR-13, section 2.7).** (a) `devhost-costs` reads Claude Code's transcripts, a CLI fact; leaving it in `records` "later" means a second CLI has no cost line. Recommended change: ship it in `records` now with a named exit 3 for a CLI without a transcript reader, and open the backlog item for the adapter verb. (b) `devhost-branches` carries a branch rule that needs the backlog; it stays in `records`, but its pre-push hook is the `git` Feature's hooks path, so the hook line is written by `records init` only and the `git` Feature is not changed. (c) `shutdown-devhost` and `restart-devhost` drive the launcher's stop; their home is the `devcontainer-cli` layer, which owns the stop, not `records`. Recommended change: move them to a `devcontainer-cli` layer in that Feature, as the proposal's own alternative says, since `records` does not require the launcher.
8. **The capability matrix has no row for what `backs` depends on (NFR-12, agents-v2 section 14).** `backs` needs Claude Code's `Stop` and `SubagentStop` hooks, `claude -p` (a one-shot row exists, native on all five CLIs), and a transcript format the condenser reads; the matrix has no row for an after-turn hook or a transcript. Saying "another CLI has no backs" is a fallback, but it is unchecked. Recommended change: add two rows to section 14.1 (an after-turn hook, a transcript format) in the same pull request as `backs`, and have `backs-setup` exit with a distinct code (not an error) on a CLI without them.
9. **Each new published Feature carries the publishing work (NFR-8, NFR-9, NFR-10, CONTRIBUTING, `check_versions.py`).** The proposal does not list: the NOTES with ten items per Feature, `CHANGELOG.md`, generated `README.md`, the scenarios (defaults, `non_root`, `legacyNames` off), the global scenario entry, the `docs` task, and the `installsAfter` ids that cannot name an unreleased Feature until slice 3. The tests of the lifted code (`test/devhost/python`) split in two. Recommended change: add one paragraph to slice 1 listing these, and make the first pull request of slice 1 the one that keeps `task lint` and `task test:global` green with both Features present.
10. **Documentation deltas are prose, not the changed diagrams (skill step 3, ADR 0060).** All six standing documents are named (the C4 pair counts as one), which is right, but section 5 lists edits as sentences. The C4 container view needs a changed Mermaid block (`backs` and `records` as owners of the runner, jobs and guards), the data-flow view a changed flow for the state volume and the register guard, and the lifecycle of the skill a changed state diagram. The `docs/iterations/export/starter` copy of the devhost stays until slice 3 and its drift is unguarded for the interval. Recommended change: put the changed Mermaid blocks in the pull request of each slice (not the proposal), and say in slice 1 that no new seed export is dropped, as it already does, plus that the export's devhost copy is not edited.
11. **Names and the lexicon (LEXICON.md).** `backs` as a Feature id collides with the term "Back": the scribe, secretary and librarian are backs but ship in `records`, while the Feature named `backs` ships only the runner and the tester. `records` also carries the way-of-working skills and the briefing, wider than a records Feature. New terms the migration needs: the legacy-names shim (`legacyNames`), the way-of-working layer, and the jobs path (`BACKS_JOBS_PATH`). Recommended change: either name the runtime Feature for what it does (for example `back-runner`) or add a lexicon line saying "the Feature `backs` runs the backs; the record backs are installed by `records`", and add the three terms through the librarian in the slice that builds them.
12. **ADR work (ADR 0022, 0025, 0042, 0044, 0072).** The proposal supersedes 0025 and 0044 and keeps 0042 and 0022, but 0022 changes its fallback (finding 3), 0042 changes its file path and Feature, and 0072 names `task test:devhost:docker`, which the proposal drops. An accepted ADR is never edited. Recommended change: one new ADR for the split and publishing, which supersedes 0025 and 0044 and amends 0022, 0042 and 0072 by name, written in slice 1; M6 (the shim policy and the 2.0.0 date) gets its own ADR because it constrains the consumers.

### Open questions for the Operator

- **Name of the runtime Feature (M1).** `backs` with a lexicon line, or `back-runner`. The review recommends `back-runner`: the Feature then names what it installs and the term "Back" keeps one meaning.
- **State ownership (finding 1).** `records` reads the backs' volume through a documented path, or owns a volume of its own. The review recommends its own volume (NFR-1): the two Features then install and rebuild independently, and the briefing reads pending work through a `backs` command instead of a path.
- **Commit check split (finding 6, M3).** A written exception for the git-aware guards in one check, or a split of the staged-diff and identity guards into the hook. The review recommends the exception now (ADR 0042 stands), with the split when a repository wants the hygiene without the records.
- **Home of `shutdown-devhost` and `restart-devhost` (finding 7).** `records` layer, or a `devcontainer-cli` layer. The review recommends the `devcontainer-cli` layer, since that Feature owns the stop and `records` should not need the launcher.
- **Seed export in the gap (finding 10).** Keep the old copy until slice 3 as proposed. The review agrees; the Operator may prefer to export once after slice 1 so the starter does not lag.
