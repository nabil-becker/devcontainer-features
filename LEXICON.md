# Lexicon

The words of the way of working in devcontainer-features, and what they mean here. Every other document
uses them in this sense. When a term changes, it changes here first. This file only grows: the
librarian back adds terms, an inter changes or retires one (a retired term is struck through
with the reason, never deleted).

The domain words of the project itself are not here; they live with the project's own documents.

## The product

- **Feature**: a Dev Container Feature in `src/<id>`: the deliverable of this repository, installed
  by a devcontainer.
- **Consuming repo**: a repository whose devcontainer pulls these Features; the office and software project 1 are
  two.
- **Devcontainer**: a consuming repo's `.devcontainer/`: the container definition that lists the
  Features it uses.
- **Feature registry**: where released Features are published and pulled from: GHCR, listed on
  containers.dev.
- **Release**: the manual workflow on `main` that publishes the Features to the registry.
- **Local Feature**: a Feature in `local-features/<id>` that this repository uses but does not
  publish; `task features:stage` stages it with the `src/` Features and releases skip it. The
  devhost is one (ADR-0025).
- **Feature Taskfile**: the Taskfile a Feature ships for its tool, registered at build time.
- **Linter CLI contract**: the shape a Feature's check or transform tool takes: paths and `-` for
  standard input, one `path:line: rule` per finding with a `--format` for machines, exit 0 clean,
  1 findings, 2 usage or internal error, exceptions in a file, and no knowledge of git or hooks
  (ADR-0035).
- **Feature state**: what a Feature keeps outside the checkout: a named volume under
  `/var/lib/devcontainer-features/<id>` or host disk.
- **Git dirs mount**: the one line every consuming repo adds to bind the workstation's `.git-dirs`
  folder at `/git-dirs` (the `GIT_DIRS_ROOT` default); the git Feature's wrapper maps a checkout's
  `.git` pointer onto it, so no repo sets `GIT_DIR` or `GIT_WORK_TREE` (ADR-0020).
- **Host type**: the kind of workstation the launcher runs on: `windows-docker`,
  `windows-wsl-docker`, `windows-wslc`, `linux` or `macos`. `HOST_TYPE` picks it (default `auto`,
  detected in the order of `HOST_TYPE_PRIORITY`); the launcher then sets `DCF_HOST_TYPE`,
  `DCF_HOST_HOME` and `DCF_HOST_SSH_AGENT`, which a repo maps into the container with
  `containerEnv` (ADR-0024). It is not an adapter: "adapter" is reserved for the CLI adapter.
- **Augmentation**: a Feature with the same id as a tool that an official Feature or the base image
  already installs, ordered after it with `installsAfter`, that adds the ecosystem pieces around the
  tool: persistent state, a wrapper, a Taskfile, a setup script (`claude-code`, `git`, `gh`, `az`;
  CONTRIBUTING.md).
- **Wrapper**: an executable a Feature installs ahead of a tool on PATH under the tool's own name to
  adjust its behaviour (the `git` and `claude` wrappers).
- **Local workaround**: a consuming repository's own script around a gap in this collection; each
  one found is a backlog item here.
- **Launcher**: the host-side bootstrap and task set (`task devcontainer:*`, `bootstrap/host`) that
  runs `devcontainer up` and sets `DCF_HOST_*`; host side only. A command that starts something
  inside the container is a start command, not a launcher.
- **Shared script**: a script in `src/common` vendored verbatim into the Features that use it
  (`dcf-persist`, `dcf-curl`).
- **Devcontainer hook**: a `postCreateCommand`, `postStartCommand` or `postAttachCommand` of the
  Dev Container spec. Bare "hook" is avoided: say whose hook it is (devcontainer, Claude, git). An
  agent integration's lifecycle points are verbs, not hooks.
- **Setup script**: a Feature's `<id>-setup`, an executable on PATH that the Feature's post-create
  devcontainer hook calls; also `task <id>:setup`.
- **Git hook**: a script git runs at a step of its own: `pre-commit`, `pre-push`,
  `prepare-commit-msg` (`.githooks`).
- **Host mount**: a bind mount the launcher adds to `devcontainer up` (and so `rebuild`) with
  `--mount type=bind,source=...,target=...`, from a per-host-type list; it is skipped when the
  repository's `devcontainer.json` already mounts the same target, and `HOST_MOUNTS=false` turns
  the list off. The `.git-dirs` mount is the first entry (ADR-0024).

## People and agents

- **The Operator**: the person who owns the repository. Brings notes, asks for work, reviews,
  decides and ratifies. Items marked for the Operator are not for a session to resolve.
- **Engineer**: anyone who works the repository with their own sessions on their own machine; the
  Operator is one. The cost report is per engineer.
- **Agent**: any model doing work for the repository: a Claude Code session, a subagent, or a
  background run. Every agent is an inter or a back.
- **Place** (of an agent): what an agent knows about where it stands: who it ultimately serves
  (always the Operator, even when another agent started it) and its boundaries. Agent principle 3
  (P3); the Operator sets it up per agent, with defaults from a personal-assistant or a
  software-delivery use case.
  - **Boundaries**: the part of a place that says what an agent may and may not do, what it is
    responsible for, and who it consults or keeps informed; in practice its row in a RACI chart.
    For example, a developer agent owns its pull request but cannot merge it.
- **Host** (the main session): the Claude Code session an engineer is talking to, the one that
  briefs and merges the work of the others; the main inter. The machine outside the container is
  the **workstation**, never "the host".
- **Inter** (interface agent): an agent that works with an engineer, directly or through another
  inter; the host is the main one.
- **Resident agent**: an agent kind in the agent list: it runs continuously in the background, and
  starting it attaches to it (starting it first if it is not running). The host becomes one once
  Remote Control reaches a background session; until then it is on-demand. Not to be confused with
  a back, which no person attaches to.
- **On-demand agent**: an agent kind in the agent list: starting it opens a new session, and it
  can resume an earlier one when asked. A designer or a general Claude instance is one.
- **Handle**: an agent's `name` in the agent list: an address, not an identity. Letters, digits,
  `-` and `_`, unique in the list; it is also the name of the agent's lease folder, so it stays
  path-safe (`docs/proposals/agents-v2.md`).
- **Stateful agent**: an agent whose `lifecycle` is `stateful`, the default: it has an identity,
  takes a lease so only one copy runs, and keeps its state in records, not in the session. A 1.x
  agent was one in practice. Independent of its kind: a resident or an on-demand agent can be
  stateful. Decided 2026-10-29 (ADR-0036).
- **Ephemeral agent**: an agent whose `lifecycle` is `ephemeral`: it takes no lease, any number of
  copies may run at once, and nothing is kept or resumed. It may share a stateful agent's identity,
  which is how a stateful agent's background runs are listed. It is never resident
  (ADR-0036).
- **Lease**: the exclusive right to run one copy of a stateful handle: a folder
  `leases/<handle>/` with a holder file in the agents Feature's state folder, taken with `mkdir`
  at every start through `agents`, held until the carrier ends, and taken over when the holder is
  dead. Its `scope` is `container` (the default for a stateful agent) or `none` (ephemeral); a
  wider scope is refused. A second start of a resident joins the running copy; a second start of
  an on-demand stateful agent is refused (ADR-0036).
- **Carrier**: what an agent currently runs on, a runtime fact and not a list key: `session:<id>`
  for a background session, `process:<pid>` for a foreground one, `none` before a start. The lease
  is held by the agent; the carrier is never assumed to be the agent (ADR-0036).
- **Session name**: the label a CLI shows for an agent's session, for example in a remote session
  list, apart from the handle. The agents Feature renders it once per start from the `sessionName`
  template (variables `{handle}`, `{repo}`, `{machine}`) and hands it to the CLI adapter in
  `AGENT_SESSION_NAME`; a stateful agent's stays the same at every start. Decided 2026-10-30
  (ADR-0041).
- **Agent integration**: an executable `agent-integration-<id>` on PATH, supplied by a framework and
  never by the agents Feature, that acts on an agent's lifecycle through the verbs `env`,
  `before-start`, `after-start`, `lease-taken`, `lease-released`, `stop` and `check`, taking
  `key=value` arguments and never reading the agent list. A handle names the ones it uses in
  `integrations`, and the ones whose absence blocks a start in `integrations-required`
  (ADR-0036).
- **CLI adapter**: an executable `agent-adapter-<cli>` on PATH, installed by a CLI Feature (for
  example `claude-code`), that the agents Feature calls to start, wake, open or list that CLI's
  sessions; a repository chooses it with `cli:` in the agent list. "Adapter" is used only for
  this. An agent integration is a different thing: supplied by a framework and named in
  `integrations`, never chosen by `cli:`.
- **Agent list**: the file a repository keeps naming its agents, each with its kind and CLI;
  `.devcontainer/agents.yml` by default, with a configurable path relative to the repository root.
- **Back** (background agent): an agent that never works with a person. After each turn, and after
  each con's job, it reads what was done and keeps one record current, so no inter spends a turn
  on upkeep. It reports only through a quiet notice. Each runs on its own model, inside the
  devhost only.
  - **Scribe**: the back for the ledger.
  - **Secretary**: the back for the backlog (`TODO.md`): adds items and decisions for the
    Operator, ticks finished ones; never rewords, removes or reorders.
  - **Librarian**: the back for this lexicon and the ADRs.
  - **Tester**: the back with no model: runs the suite after a turn that changed code and
    speaks only when it is red, or green again.
  - **Journalist**: planned as the back for the journal; never built: it became a skill
    (ADR-0009), then the writing brief inside `drop-a-seed` (ADR-0014).
- **Con** (consult agent): an agent briefed by the host for one job, a Claude Code subagent, with
  its scope, model and isolation set for that job; it replies once, in the hand-off shape, and
  its job gets its own ledger entry. Not a standing role.
- **Night shift**: a host session the Operator leaves open, working an agreed list of backlog
  items alone under the night rules and a cap, reviewed in the morning report. Defined in the
  `night-shift` skill.

## Places

- **Devhost**: the dev container as the environment where sessions run and the backs act. The
  `devhost` Feature installs the tooling; its state lives outside the repository.
- **Publish target**: where the repository's site is published (Claude artifacts today); the
  `publish-site` skill serves one, and another target takes the same page file.
- **Workstation**: an engineer's own machine outside the devhost. The backs' hooks do nothing
  there.
- **Worktree**: a separate checkout of the repository on its own branch, where a con that changes
  shared tooling works; its work comes back as a merge, so a clash is a conflict, not an
  overwrite. Backs do not use worktrees.
- **Storage tier**: one of four places data may live: tier 1 git (the reviewed record), tier 2 the
  shared folder (the cloud-folder mount, which holds the register mirror), tier 3 the Operator's
  personal folder (not mounted unless asked), tier 4 the working set (Feature volumes and scratch,
  rebuildable only). If losing a machine would lose something, it is in the wrong tier (ADR-0045).
- **Custody**: what people hold outside every storage tier, such as the OpenBao unseal shares and
  recovery key, because they are the gate to the tiers and cannot sit inside one (ADR-0049).

## Work

- **Note**: something the Operator says in chat that the repository must remember; recorded in
  the ledger entry's Decisions and, when it is work, in the backlog.
- **Unit of work**: one thing an engineer asked for that got done or settled: a slice, a document
  change, a question answered, a decision taken; and every con's job. One ledger entry each.
- **Backlog item**: an engineering item that needs no external answer, named by its backlog id in `TODO.md`.
- **Backlog id**: the short descriptive kebab-case slug (two to four words, for example
  `release-collection`) that names a backlog item; unique in `TODO.md`, never reused, never
  renamed once written, and cited the same way in commits and ledger entries. It replaces the
  earlier `TD-nn` numbers, which survive only as `(was TD-nn)` on converted items.
- **Branch rule**: every branch is named `<type>/<backlog-id>/<n>` (type `feature`, `fix`, `docs`
  or `chore`; `<n>` the workstream number, always present) and names a backlog item that exists in
  `TODO.md`; the backs' records use the standing item `records`. Made by `task devhost:branch`,
  listed and pruned by `task devhost:branches`, enforced by the pre-push hook (ADR-0017).
- **Workstream number**: the `<n>` in a branch name, always present and counted from 1; a parallel
  stream on the same backlog item (for example a con in a worktree) takes the next free number.
- **Done**: a backlog item is done when its pull request is merged to `main` (decided 2026-10-21);
  releasing is a separate step only the Operator starts.
- **Spend target**: the monthly agent spend the Operator measures against, $200 at list price
  (decided 2026-10-21). A target to track, not a cap: no warning and no block until a month or
  two of data shows what the work costs; real caps come later.
- **Amend item**: a backlog item with the id `amend-<id>`, added by the secretary when a stake asks
  to change an existing item; it names the item and the change, and a person makes the change by
  hand, since backs never reword (ADR-0003).
- **Decision for the Operator**: an engineering choice only the Operator can make, listed under
  "Decisions for the Operator" in `TODO.md` with a recommendation.
- **Brief**: what an inter gives a con: the job, the scope and what is out of bounds, the model,
  the isolation, the reply shape.
- **Hand-off** (reply): what every handing-back ends with, in one shape: Outcome, Outputs,
  Friction, For the repository, Decisions needed.
- **Model sizing**: matching the model to the blast radius of the work: the strongest where others
  inherit the output, a mid tier for a bounded job an inter reviews, the smallest for chores.
  Checked against the measured costs at each review.
- **Trial**: running a new mechanism once on real (or, for tooling, synthetic) work before the
  process describes it.
- **Agentic Delivery OS**: the product the Operator is building: a set of tools that lets one
  person, technical or not, bootstrap a devhost. It is the foundation of a pyramid, and each
  iteration helps define that foundation (`docs/iterations.md`).
- **Way of working** (WoW): how work gets done here: the roles, the records, the loop that improves
  them and the rules of thumb, as `PROCESS.md` describes them. Approved by the Operator 2026-10-17.
- **Iteration**: one project in which the way of working is tried and learned from: the
  office first, then software project 1, then this repository. The Operator decides when an iteration is
  done.

## Records

- **Backlog** (`TODO.md`): the engineering items and the decisions for the Operator; kept by the
  secretary. Out of git since 2026-11-04: in the shared records folder (`DEVHOST_RECORDS_DIR`).
- **Lexicon** (`LEXICON.md`): this file, the words of the way of working; kept by the librarian.
- **Journal**: the record of the project's iterations in `docs/journal/`, in plain words, add-only.
- **Night-shift report**: the morning report of a night shift, in `docs/night-shift/`.
- **Ledger**: the append-only record of what agents did. Here, since 2026-11-04, the agentic-register
  register `ledger` (signed entries, mirrored to the shared folder; `devhost-ledger show` renders it);
  before that, monthly files under `docs/ledger/` (in git history).
- **Entry**: one ledger record, one per unit of work: asked, came out, friction, learned,
  decisions, for the repository, decisions needed, measures. A wrong entry is corrected by a new
  one with a `Corrects:` line.
- **Friction**: what a unit of work lacked, got wrong or had to work out, tagged `[tooling]`,
  `[docs]`, `[skill: <name>]`, `[skill: new]` or `[process]`. "none" is a valid entry.
- **Measures**: the numbers of an entry: the stretch's cost at list price, its tokens and models,
  filled in by the scribe's script from the transcripts, never by a model. A stretch's cost goes on
  its first entry only; the stretch's other entries point to it, so summing the ledger counts it once.
- **Review**: reading the cost report and the entries since the last review, checking whether the
  last review's friction came back, and turning each group into one action; kept as a `## Review`
  section (a file in the shared folder's `reviews/`, shown between the ledger's entries), every 75 entries here (`DEVHOST_REVIEW_EVERY`, ADR 0021; 25 if unset). Run with `/ledger-review`.
- **Architecture review**: a subagent's check of a proposal's design against the non-functional
  requirements, the ADRs, the CLI capability matrix, the lexicon and where each element is placed,
  written into the proposal before the Operator rules; run with `/architecture-review`.
- **Cost report**: `costs-YYYY-MM-<engineer>.md` (in the shared folder's `costs/`), the monthly agent costs on one
  engineer's machine (inters, cons, backs, by model), rebuilt by `devhost-report` with no model
  from the cost store and this machine's new records, with the month's entry rate and, when `DEVHOST_MONTHLY_TARGET` is set, the spend against that tracking point. Read first by the review.
- **Cost store**: `costs-YYYY-MM-<engineer>.jsonl`, the ids-and-numbers record beside the cost
  report (committed until 2026-11-04, now in the shared folder). `devhost-report` adds this machine's new records to it and never
  drops committed rows, so a rebuilt machine cannot empty the month; figures from before the store
  existed enter once as a baseline taken from the committed report.
- **List-price estimate**: every cost figure here: tokens priced at the published list price,
  which on a subscription measures use, not a charge.
- **ADR**: an architecture decision record in `docs/adr/`, for a decision whose reasoning does
  not fit in a line.
- **Ontology**: the canonical data model of the way of working: what kinds of thing exist (by
  plain base id), and how they relate (briefs, writes, keeps, checks, decides). The lexicon words,
  the themes and the C4 views must agree with it; it is not the instances, which the ledger holds.
- **Shared language**: the lexicon and the ontology taken together: the agreed words and the model
  behind them, which keep the Operator and the agents aligned. The technical term is controlled
  vocabulary. A theme (optional, a matter of taste, changeable later) is a voice over it that makes
  the place quicker to grasp.
- **White paper**: the account of one iteration, written once when the Operator calls it done, in
  plain words, function over form, every fact traceable to the ledger, ADRs, reviews and cost
  reports. Written with the Operator during `drop-a-seed`, by a subagent following its journalist
  brief (ADR 0009, ADR-0014).
- **Journalist**: the brief (`drop-a-seed/journalist.md`) a writing subagent follows to draft the
  white paper with the Operator when the iteration is called; not a back (ADR-0009), and no longer
  a skill of its own (ADR-0014).
- **Iteration package**: what an iteration hands to the next, cumulative: every earlier white
  paper kept unchanged, plus the newest set of artifacts (a bootstrap prompt, context, whatever the
  iteration finds foundational), which each iteration merges into and replaces, so packages never
  nest. It carries the foundations of the Agentic Delivery OS, not the tooling, and says what to
  ingest and why, not how to transform it. In the life theme (ADR-0007) it is the **seed**, a label only:
  plain names stay in every id, path and sentence, as in ADR-0004
  (`docs/proposals/iteration-package.md`).
- **Drop a seed**: the export skill (`drop-a-seed`), run when a project ends: the closing
  interview, the iteration named, the white paper written by a subagent, the seed's contents
  settled with the Operator, the seed folder assembled by `devhost-package` (ADR-0014).
- **Shutdown check**: what `devcontainer:stop` and `:rebuild` run inside the container before
  stopping it, and `devcontainer:prepshutdown` runs on its own: exit 0 is safe, non-zero refuses,
  `FORCE=1` skips it. Resolved in order: the repository's `task shutdown:check`, else
  `devhost-shutdown-check`, else none (the stop goes ahead); `STOP_CHECK` overrides
  (`bootstrap/SHUTDOWN.md`, ADR-0022). Here it is `devhost-shutdown-check`, which says whether
  the devhost can be stopped without losing work: tree clean and pushed, backs idle with locks
  free, no stretch waiting (one untouched for over 24 hours is only a note), no tester run, no night shift mid-plan; it lists stash and untracked
  files. Also run by the `shutdown-devhost` skill (ADR-0015).
- **Shutdown and restart** (`shutdown-devhost`, `restart-devhost`): the skill pair that closes the
  devhost cleanly and brings it back where it was; both ship in the seed (ADR-0015).
- **Plant a seed**: the import skill (`plant-a-seed`), run in the new place after the agent is
  pointed at the seed's README: it reads the papers and foundation, runs the interview, sets up or
  adapts a repository, and ends with the first ledger entry (ADR-0014).
- **Docs site**: the one self-contained HTML page `devhost-site` builds from the docs and records,
  a homepage that leads with what needs the Operator. Publishing it is a separate skill, so the
  host (Claude artifacts today) can change without touching the page (ADR-0006).
- **C4 view**: a diagram of the system at one zoom level (Context, Container), written in Mermaid
  and named by ontology ids.

## Mechanisms

- **Claude hook**: a command Claude Code runs on an event, set in `.claude/settings.json`:
  SessionStart runs the briefing; Stop and SubagentStop start the backs; `claude-host-pin` is
  another. Not a devcontainer hook or a git hook.
- **Briefing**: what an inter is told at session start (`devhost-briefing`): the entries since
  the last review and whether a review is due, what the backs left pending, the open backlog
  items, the month-to-date agent spend.
- **Stretch**: the part of a transcript a back has not read yet, condensed to the engineer's
  words, the inter's replies and which tools ran.
- **Stake**: one plain line anyone leaves in a session when a chore might not be caught on its
  own: `Stake for the <back>: <what> needs <what>.` Lifted to the top of what every back reads;
  the one addressed treats it as an explicit request.
- **Over**: the word the Operator ends a run of messages with, on its own and with no punctuation
  needed (decided 2026-10-21, for dictation): "act on everything in the run". It applies only while
  the `walkie-talkie` skill is on, which it is not by default; outside a run every message is acted
  on as usual.
- **Walkie-talkie**: the skill (`walkie-talkie`) that holds a run of the Operator's messages
  until "over" (decided 2026-10-21). Off by default, so every message is acted on as usual; it
  turns on when the Operator invokes it or says "hold on" or "wait". While on, the inter gives one
  short acknowledgement per message; "over" ends the run and the inter acts on everything in it
  together, "over and out" ends it without acting.
- **Quiet notice**: how a back reports: one line of context on the inter's next turn, never a
  message to the engineer; the inter reads the change before the next commit and mentions it
  only when asked, when something was wrong, or when the Operator must act.
- **Guard** (back guard): the script that undoes a back's run that changed what it may only add
  to (`devhost` `guards.py`: the backlog guard, the docs guard).
- **Name guard**: the replacement of every name in the ignored `.devhost/redact-names.txt` by
  "the Operator" in everything a back writes.
- **Name exception**: a file the Operator approves, listed in
  `.devhost/name-exceptions.txt`, that the commit-time forbidden-words guard skips so it can be
  committed unchanged (the first white paper, ADR-0010). By file, never by word.
- **Metrics line**: the one JSON line every back run appends to its `runs.jsonl`: when, which
  back, model, size, outcome, guard undos, duration, cost, tokens.
- **The guards** (`devhost-verify`): the commit-time checks the pre-commit hook runs: the ledger
  append-only and well-formed, no secrets, no forbidden words, the ADR shape, every task
  described, every skill named, and the model: every lexicon term has an id in the ontology
  (ADR 0005, devhost 1.7.0).
- **Agent principles**: the five generic principles (P1 to P5) of the way of working: separate
  personalization from process, continuous improvement, the agent knows its place, claims need
  evidence, right-size the work. Generic by design: each Operator sets them up
  (`docs/principles/agents.md`, ADR-0013).
- **Non-functional requirement** (NFR): one of thirteen requirements (NFR-1 to NFR-13) that every work
  item touching a Feature must meet, or else record a backlog item or a written exception in the
  Feature's NOTES (`docs/principles/non-functional-requirements.md`).

## Secrets

The words of the secrets split: OpenBao keeps every secret, `ssh-agent` only uses keys (ADR-0048).

- **Master of secrets**: OpenBao, in the role ADR-0048 gives it: it keeps every private key and
  token the collection creates or stores, and their lifecycle; `ssh-agent` only uses keys. Keys a
  workstation holds stay the workstation's, and the recovery key is outside it.
- **Client mode**: the `openbao` Feature's default mode: the `bao` CLI only, `BAO_ADDR` pointing at
  a server outside the container, plus the volume and `dcf-secret`. It meets ADR-0045 as it stands.
- **Server mode**: the `openbao` Feature's other mode: a server run inside the container at
  post-start, raft storage on the Feature's own volume, sealed until the Operator unseals it. Its
  storage is the bounded-loss exception to ADR-0045.
- **Seal and unseal**: a sealed server cannot read its store; unsealing, once per server start,
  needs a quorum of the unseal shares (`openbao:unseal`).
- **Unseal share**: one of the 5 Shamir shares (threshold 2) of a server with an OpenBao key
  file, or one of the 3 (threshold 2) of a server without. Shares 1 to 3 are custody shares, kept
  in a password manager, on paper offline, and with a second person or on a hardware key; never
  in git, the container or the shared folder. Shares 4 and 5 are in the OpenBao key file. "Never
  in the container" means never stored there (ADR-0056).
- **OpenBao key file**: the DPAPI-protected file on the Operator's Windows workstation that holds
  two unseal shares, the cluster id and the `operator` AppRole's ids, and that the launcher sends
  to the container after every `up` to unseal OpenBao and log the Operator in (`unlock: keyfile`,
  ADR-0056). Rebuildable from the custody shares, so tier 4. Not the SSH key files of the
  launcher: never say "key file" alone for it.
- **Custody share**: one of unseal shares 1 to 3, held by the Operator outside every tier. Two
  of them rebuild the OpenBao key file and are typed only to recover or rotate it (ADR-0056).
- **The gate**: the two steps that open the master of secrets: the unseal once per server start,
  then the login once per sitting. The Operator types them, or, in a server with an OpenBao key
  file, the launcher does it from that file after every `up`; recovery and rotation still need
  two custody shares typed by the Operator.
- **Sitting**: the span between the Operator's login to OpenBao and the end of that token (4 hours,
  at most 8, in a server this Feature runs; in a server with an OpenBao key file, the 1-hour
  periodic token the container renews, so the sitting lasts while the server is up and unsealed);
  a key loaded for a sitting lives no longer than it.
- **Secret name**: the path a secret is kept under in OpenBao, as `dcf-secret get <name>` and
  `put` take it (`ssh/<key>`, `register/<principal>`).
- **Back identity**: the AppRole a back (scribe, secretary, librarian, tester) logs in with, bound
  to loopback and to its own secret name path, working only while the server is unsealed.
- **Register operator key**: the Operator's key that signs the register's operator acts; kept in
  OpenBao and loaded for a sitting by `key:load` (ADR-0048, replacing ADR-0046).
- **Recovery key**: the register's second operator key, kept offline outside OpenBao, the one
  stated exception to "OpenBao keeps everything".
- **Key mode**: the `ssh-agent` Feature's opt-in mode with a key volume and key tasks, chosen with
  the SSH agent mode `key` (formerly `keyMode: true`); deprecated
  by ADR-0048, and renamed `localAgent` (an in-container agent whose keys live only in memory) in
  `ssh-agent` 2.0.
- **Host agent mode**: what the workstation offers the `ssh-agent` Feature, worked out by the
  launcher and passed as `DCF_HOST_SSH_AGENT`: `socket` (the host's own agent is forwarded), `none`
  (the host engine cannot pass a socket in) or `key` (the Operator set `SSH_AGENT_MODE=key`, so the
  socket mount is skipped). Not the same as the SSH agent mode, which says what the container may
  do about it.
- **Host audio**: the opt-in `DCF_HOST_AUDIO=wslg` setting in the workstation's `.devcontainer/.env`:
  on a WSL-backed Windows host type the launcher shares WSLg's folder into `/mnt/wsl/wslg` from the
  default distro (skipped when already shared), and mounts it into the container, where
  the `audio` Feature (which sets `PULSE_SERVER`) sees the Windows microphone as `RDPSource`. Off by default, and a missing
  WSLg warns and starts the container without audio (ADR-0057).
- **SSH agent mode**: the one setting a user touches for the `ssh-agent` Feature, `SSH_AGENT_MODE`
  in the workstation's `.devcontainer/.env`, mapped by `"mode": "${localEnv:SSH_AGENT_MODE:auto}"`;
  values `auto` (follow the host socket), `socket`, `key` and `none`; an empty or unknown value
  counts as `auto` with a warning. It replaces the `keyMode` option and the
  `SSH_AGENT_SETUP_KEY_MODE` override, both deprecated and removed in `ssh-agent` 2.0.
- **Central server**: an owner-run OpenBao server that devcontainers reach in client mode; the
  only server a wrapping token can be unwrapped against.
- **Snapshot**: the raft file `bao operator raft snapshot save` writes: the whole store, as
  ciphertext.
- **Backup**: the `openbao` Feature's named copy of a snapshot in a destination
  (`openbao-<machine>-<UTC time>.snap`, never overwritten); `openbao:backup` writes it and
  `openbao:restore` reads it. Scheduled backups are optional and off by default.
- **Workstation scheduler**: the consumer's own scheduler on the workstation (Windows Task
  Scheduler) running a one-shot task such as `task dc:exec -- task openbao:backup`; the launcher
  never registers it (ADR-0024, ADR-0026). Not the Host.
- **Throwaway init**: the first step of a restore into a fresh server: it initialises the server
  with shares and a root token that are discarded once the snapshot is restored.
- **Onboarding instance**: a second, short-lived server holding only the shared keys, from which
  `openbao:onboard:export` takes the snapshot handed to a new devhost, never a snapshot of the
  sender's own store.
- **Claim**: `openbao:onboard:claim`, run after restoring someone else's snapshot: it makes the
  store the receiver's own with `bao operator rotate-keys` (new unseal shares, the OpenBao name for
  what was `rekey`), with the claim token, revokes what the sender held, reissues the back
  identities and rotates the data key (`bao operator rotate`), so only what is written afterwards
  is out of the sender's reach.
- **Claim token**: the onboarding instance's root token, which `openbao:onboard:export` prints once
  beside the fresh unseal shares; the receiver gives it to the claim, because `rotate-keys` needs a
  token on OpenBao 2.6 and later and a restored store holds only the sender's; the claim revokes it
  at the end.
- **Response wrapping**: a one-use, short-lived wrapping token that holds one secret in the
  issuing server's cubbyhole (`openbao:wrap`, `openbao:unwrap`); one token per secret, and it works
  only against a central server.
- **Keyfile unlock**: the `openbao` Feature's `unlock` option set to `keyfile` (`operator` is the
  default): a server-mode store that the Operator's OpenBao key file on the workstation unlocks,
  through `openbao-keyfile` (`unlock`, `create`, `confirm`, `cancel`, `rotate`, `renew`, `status`),
  instead of the Operator typing shares and a password. The Feature's own renewer, not `bao agent`,
  keeps the AppRole token alive.
- **Renewer**: the Feature's own background process under keyfile unlock that renews the operator
  AppRole's 1-hour periodic token and stops when a renewal is refused, the token is dead or the
  Operator logs out; `server:status` shows it.

## The bar layer

A voice over the plain words, not a rename (ADR 0004; the theme has been a bar since 2026-10-23,
ADR 0023, replacing the Arthurian one). The landlord is the Operator, the bartender the host, a
runner a con, the barbacks the backs, the tab book the ledger, the chalkboard the backlog, the
cash-up the ledger review, the lock-in the night shift, the bouncers the guards; the labels are in
`docs/model/themes/bar.toml`.
Themes are label files under `docs/model/themes/`, keyed by the ontology ids of
`docs/model/ontology.toml`; they change no process, and no committed output speaks in them
(ADR 0004). The plain word stays in every id, path, command, field name and guard.
The journal is a record of the project's iterations and stays in plain words (decided 2026-10-16).

## The life layer

A second voice over the plain words, for the whole series of projects, shared by every project
and sitting above each repository's own theme (the bar layer here), not replacing it
(decided 2026-10-16, ADR-0007, `docs/proposals/iteration-package.md`). Labels and story only:
the plain word stays in every id, path, command, field name and guard, and nothing committed is
renamed. Each project is a tree growing in its own ground.

| Plain word | In the layer |
|---|---|
| iteration | generation |
| project | tree |
| project context | ground |
| iteration package | seed |
| white paper | fruit |
| a learning that changed the foundation | adaptation |
| a change that proved a one-off | shed trait |
| the series of iterations | lineage |
| iterations 1 and 2 (before any package existed) | first life, before seeds |
| this repository | the first seed-bearing tree |
