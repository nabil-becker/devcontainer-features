# The planting interview, run on this repository (interview 4)

This is `plant-a-seed`'s planting interview (`.claude/skills/plant-a-seed/INTERVIEW.md`) taken on
this repository itself, on 2026-10-21, so the repository and the seed it exports agree. It is not
the closing interview: that is `docs/iterations/interview-3.md` (iteration 3's closing interview).
The Operator asked for it on 2026-10-21 (backlog item `seed-self-interview`): most of it can be
answered from the records, so each question below is answered by the host from the records, with
its source in brackets, and only what the records cannot answer is put to the Operator.

How to read it:

- An answer with a source in brackets is taken from the records. Where the Operator's own words
  exist (interview 3), they are quoted briefly.
- **To confirm** marks an answer where the records give several answers, conflict, or only imply it.
- **Gap: question for the Operator** marks a question nothing answers, with a recommended answer.
- Nothing here was decided by the host. The last section collects every gap and confirmation as a
  numbered round for the Operator.

Source shorthand: README, CLAUDE (`CLAUDE.md`), DEVHOST (`.devhost/CLAUDE.devhost.md`), PROCESS,
LEXICON, AGENTS (`docs/principles/agents.md`), NFR (`docs/principles/non-functional-requirements.md`),
ADR n (`docs/adr/`), ITER (`docs/iterations.md`), I3 q n (`docs/iterations/interview-3.md`
question n), ledger (`docs/ledger/2026-10.md`, entry date and title), TODO (`TODO.md`).

## 1. The opening

The opening says what the interview is for (to plant the seed, shaped to how the person works) and
that every step has a default, "skip the interview, just build" being allowed, except the purpose.

- **Answer:** not applicable as a welcome; this repository is its own target. The one part that
  matters is kept: the purpose cannot be defaulted, and it is answered below (P3 q1) from the
  Operator's own words. [`plant-a-seed/INTERVIEW.md` section 1; I3 q6, q17]

## 2. The two use cases

- **Answer:** the closer one is **SD, software delivery**, in its small form. This repository
  builds and ships a product (the Features) with agents, but it has no developers, QA, architect,
  scrum master or business analyst as separate agent personas; its agents are the host, cons, backs
  and the night shift. The guide itself says "Iteration 3's devhost is a small version of this".
  [`INTERVIEW.md` section 2; PROCESS "Who does what"]
- **To confirm:** SD is the use case whose defaults the next section compares against. Every
  SD default this repository does not meet is listed in "Where this repository differs from the
  seed". [question 1 of the final round]

## 3. P1: Separate personalization from process

The principle (AGENTS P1) holds the line on process and lets the person personalize. Where each
answer below is a personalization, it is marked so; the records that are process are named as such.

### Time (the key concept)

- **Answer:** the repository already says time outright where it matters: a night shift has an
  absolute stop time ("Stop 07:00 Eastern (11:00Z)") and a cap, and the Operator's replies close a
  decision ("Yes", "#30 merged"). [`docs/night-shift/2026-10-21.md` header; ledger 2026-10-20 "PR #30
  merged"; AGENTS P1]

### Questions

1. **How do you want me to talk to you?**
   - **Answer (personalization):** short answers; decisions as numbered questions answerable in one
     line ("1 yes, 3 no"); pictures where a flow or structure is the point (Mermaid in documents,
     ASCII in the terminal); plain words in conversation, precise words in the record. The Operator
     dictates long messages and is happy to read long drafts section by section. [AGENTS P1 "The
     Operator reviews and decides from a phone, with decisions as numbered questions"; PROCESS
     "Rules of thumb" (pictures); `docs/proposals/personalization.md` section 1 ("I like diagrams");
     I3 q18 ("the more verbose, the better" for the paper)]
   - **To confirm:** "short answers" and "more verbose is better" both appear; the first is for
     conversation, the second for the white paper. [final round 1]
2. **Where and how will we talk?**
   - **Answer (personalization):** a host Claude Code session inside the devhost, started with
     `task devcontainer:claude` from the workstation, reachable from a phone (decisions "taken from
     a phone"); reviews as pull requests the Operator merges; dictated messages. Records and drafts
     are pages and documents in the repository, and the site is a page to read. [CLAUDE "This
     repository in the way of working"; README "One session per role, found by UUID"; I3 q1 to q18
     (dictated); ledger 2026-10-20 "PR #30 merged"; seed guide section 9.4 (decisions from a phone)]
3. **How will I know you are done talking?**
   - **Gap: question for the Operator.** The Operator sends several messages in a row; the records
     hold a backlog item for it (`hang-on-skill`: acknowledge each in one word, do nothing until the
     Operator says they are done) but it is not built and no word was chosen. [TODO `hang-on-skill`]
   - **Recommendation:** one word, "go", ends a run of messages; the host acknowledges each
     message in one word until then. Why: an agent has no sense of a pause, so it must be said
     outright (AGENTS P1).
4. **When should we check in? Give a day and time.**
   - **Gap: question for the Operator.** The records show no fixed stand-up or day and time. The
     morning report happens when the Operator returns from a night shift; the briefing arrives at
     each session start; the ledger review is "every five or so entries". [PROCESS "The improvement
     loop"; `.claude/skills/night-shift/SKILL.md`; DEVHOST "How work flows"]
   - **Recommendation:** no stand-up; one weekly check-in on a named day and time that takes the
     ledger review, the cost report and the open decisions together (see P2 q2).

### Shared language: the lexicon and the ontology

- **Answer:** both exist and are exported together: `LEXICON.md` (words and meanings) and
  `docs/model/ontology.toml` (how they relate), with a guard in `devhost-verify` that keeps the
  rest in line with the ontology (the model guard). The Operator: "the lexicon is like, shared
  nomenclature and understanding. The ontology is, like, it serves a different purpose", and they
  "should always be exported together". [LEXICON; ADR 0005; I3 q11, q12]
- **Themes. Answer (personalization):** the devhost theme: inters, backs, cons, with plain ids
  underneath. The Arthurian layer and the life layer exist in the lexicon as optional layers over
  plain words; both stay out of the seed. The Operator: "the King Author theme showed a need to
  begin to seperate out the concepts because having the ledger in old english would have been
  useless and painful." [LEXICON "The Arthurian layer", "The life layer"; ADR 0004; ADR 0007; I3
  q11, q19, q26]
5. **Which theme, if any, do you want for the agents and their work?**
   - **Answer:** the devhost theme, with plain ids underneath; keep any further theme light. [as
     above; the guide's warning about renaming 130 files is ADR 0004]
6. **Which words already mean something specific to you?**
   - **Answer:** "the Operator" (the person, never named in committed text); "inter", "back", "con",
     "host", "stake", "ledger", "friction", "hand-off", "workstation" (the machine outside the
     container, never "the host"); "the office" and "software project 1" for the two earlier
     projects. [LEXICON "People and agents", "Places"; I3 q15, q20, q41; DEVHOST "Backs, stakes and
     quiet notices"]
   - **To confirm:** what "done" means. A backlog item ends `Done YYYY-MM-DD`, but the scribe was
     corrected for recording "done", "merged" and "published" before git showed it, so the three are
     different claims. [TODO header; TODO `scribe-commit-verification`; ledger Review 2026-10-20
     (second) group 1, group 7] [final round 4]

### A way to see out: the dashboard

7. **How do you want to see how things are going?**
   - **Answer (personalization):** the briefing at every session start (open work, ledger since the
     last review, pending items, the month's spend); the monthly cost report; and the site,
     `task devhost:site`, one self-contained page of the backlog, ledger, Features, records and every
     document, published as a private Claude artifact by the `publish-site` skill only when the
     Operator asks. The librarian keeps the lexicon, the decision records and the C4 diagrams
     (`docs/model/`). How a repository exposes its outputs is "a seed-level concept, more important
     to settle than the personal forms it takes". [DEVHOST "How work flows"; ADR 0006; TODO
     `repo-outputs-concept`, `publish-docs-artifacts`, `publish-site-browser-check`; I3 q11]

**Default for P1** (short numbered answers, the devhost theme, the lexicon and a dashboard page):
met, except the numbered "1 yes, 3 no" rounds, which are practice, not a written rule.
[final round 1]

## 4. P2: Continuous improvement

- **The ledger. Answer:** `docs/ledger/YYYY-MM.md`, append-only, one entry per unit of work, written
  by the scribe back after each turn and each con's job, with its measured cost; a wrong entry is
  replaced by a new entry with a `Corrects:` line, never edited. Every entry has Friction (tagged,
  and including what was worked around) and Measures. [DEVHOST "The ledger"; ADR 0003; AGENTS P2;
  ledger entries]
- **The loop. Answer:** work, entries, the monthly cost report, the review, one action per cause
  (an item, a decision, a change now, or no action with a reason), the change with its test, and the
  next review starts by checking whether last time's friction came back. [PROCESS "The improvement
  loop"; ledger Review 2026-10-20 (second)]

1. **What is one unit of work?**
   - **Answer:** one ledger entry per turn and per con job. A backlog item is bigger: it becomes one
     topic branch (`<type>/<backlog-id>/<n>`) and one pull request, and in a night shift one commit
     per item. [DEVHOST "The ledger"; ADR 0017; `.claude/skills/night-shift/SKILL.md`]
   - **To confirm:** SD's default says one story ending in one pull request. Here the ledger's unit
     (a turn or a job) is smaller than the delivery unit (an item). [final round 5]
2. **When do we look back, and how?**
   - **Answer:** a ledger review (`/ledger-review`) "every five or so entries", reading the cost
     report first. The Operator: "the ledger review, I think, was just too frequent", "it needs to be
     there", "needs some more cleanup or some refining". The paper keeps the review and says its
     cadence is to be refined; the backlog item suggests per week or per finished piece of work.
     No retrospective ceremony exists. [DEVHOST "The ledger"; I3 q11, q21; TODO `ledger-review-cadence`]
   - **To confirm** (conflict: five entries now, "per week or per finished piece of work" proposed,
     nothing decided). [final round 3]
3. **What counts as friction?**
   - **Answer:** what was missing, wrong or had to be worked out, tagged `[tooling]`, `[process]`,
     `[docs]`; it includes what a con worked around (a command retried another way), not only what
     blocked it. Examples recorded: a failed branch switch, scripted edits that needed a retry, a
     guard that passed while checking nothing. [PROCESS "The improvement loop" step 1; DEVHOST "How
     work flows" step 2; ledger entries "2026-10-20 Finished branches deleted after the merge check"]
4. **Which resource do we measure, in what unit?**
   - **Answer:** dollars at list price per run (host sessions and cons from transcripts, backs from
     their metrics lines), in the monthly report per engineer; October 2026 stood at $105.72 at the
     second review. [PROCESS step 2; ledger Review 2026-10-20 (second) "Costs"]

**Default for P2** (the iteration 3 ledger, scribe and review, cost in dollars): met; the cadence is
the open point.

## 5. P3: The agent knows its place

The place's parts: purpose, principles, process, ceremonies, lexicon and ontology, inputs, outputs,
tooling, personas, boundaries. This repository has no single place file (the seed's MVP is
`starter/CONTEXT.md`); the parts are spread over README, CLAUDE, DEVHOST, PROCESS, LEXICON and
AGENTS. This section gathers them, as `CONTEXT.md` would. [`plant-a-seed/INTERVIEW.md` section 5;
`docs/iterations/starter/CONTEXT.md`; difference D1]

1. **Purpose: why does this exist, and whom does it serve?**
   - **Answer:** two purposes, in this order. First the product: the Dev Container Features in
     `src/` and the workstation tooling around them, which consumers adopt and a release publishes.
     Second an iteration of the Agentic Delivery OS: the devhost and its records, the third
     implementation of a way of working the Operator is distilling into a product. The Operator: one
     project "carries two priorities, the seed and the feature published", the Features released
     first "so the devhost could keep changing". [README; CLAUDE; ITER "two purposes, in this order";
     I3 q6, q17]
2. **Personas: who is involved?**
   - **Answer:** the Operator (always one); other engineers with their own sessions; the maintainers
     of the two consuming repositories (the office, software project 1), who ask for changes through
     issues; public contributors (the repository is run as a public project); and the agents (host,
     cons, backs, night shift), each serving the Operator. [LEXICON "People and agents"; README
     "Contributing from a consuming repo", "Public registry"; CLAUDE "Consumers"; PROCESS "Who does
     what"]
   - **To confirm:** whether public contributors are a persona the Operator wants agents to serve, or
     only consumers. [final round 7]
3. **Inputs: what comes in?**
   - **Answer:** the Operator's notes, asks and decisions (often dictated); requests from consuming
     repositories, which arrive as backlog items marked "requested by a consuming repository"; a
     consumer's local wrapper found in its `DEVCONTAINER_CONTRIBUTION.md` (a backlog item here);
     upstream tool releases (Dependabot, version pins); pull requests from others and draft agent
     pull requests (#31). [CLAUDE "Consumers"; TODO `claude-host-print-flag`, `git-dir-placeholder`,
     `stop-check-configurable`, `session-state-contract`; README "Governance"]
4. **Outputs: what goes out?**
   - **Answer:** released Features on GHCR (the Operator starts the release); the host-side Taskfile
     and bootstrap; generated Feature READMEs; pull requests; the ledger, ADRs, lexicon and
     backlog; the site; the seed, the white papers and these interviews. [README; CLAUDE "Git here";
     DEVHOST; ITER]
5. **Process: how does work flow?**
   - **Answer:** the happy path of PROCESS: start with the briefing, three modes with the host (ideate,
     discuss, work), cons briefed for one job each, a hand-off, the host's check, the turn ends, the
     backs record, the host reads their writes and commits on a topic branch; close with
     `/close-session`. [PROCESS "The happy path"; DEVHOST "How work flows"]
6. **Ceremonies: what happens on a rhythm?**
   - **Answer:** the morning report after a night shift and the preparation for the night shift
     (`/night-shift`); the briefing at each session start; the ledger review "every five or so
     entries". The guide's own list names the morning report and the night-shift preparation as "ours".
     No stand-up, grooming, planning or retrospective, and no ceremony has a day and time. [guide
     section 5; `.claude/skills/night-shift/SKILL.md`; PROCESS rules of thumb ("No new ceremony")]
   - **Gap: question for the Operator** on the day and time of each ceremony (see P1 q4).
7. **Lexicon: which words mean something special here?**
   - **Answer:** `LEXICON.md` and `docs/model/ontology.toml`; see P1 q6. [LEXICON; ADR 0005]
8. **Tooling: what do the agents work with?**
   - **Answer:** the devhost (`.devcontainer/devcontainer.json`: Debian base, PowerShell,
     docker-in-docker, shellcheck, yamllint, and the collection's own Features by local path:
     common, go-task, devcontainer-cli, git, gh, claude-code, devhost), the Taskfile ("task is the
     API": `task --list`: lint, test, docs, `devhost:*`, `devcontainer:*`), git hooks, the pre-commit
     `devhost-verify`, CI checks `validate`, `lint`, `tests`, `DCO`. [`.devcontainer/devcontainer.json`;
     `Taskfile.yml`; CLAUDE "Tasks", "Git here"]
9. **Boundaries: what is each agent responsible for, what may it not do, who is consulted or informed?**
   - **Answer, row by row (the RACI):**
     - *The Operator:* accountable; decides; owns the release (an agent says a release is due and what
       it would publish, and never runs it); merges pull requests; grants permissions in their own
       settings. [CLAUDE "Git here"; MEMORY "Operator runs releases"; DEVHOST "Work"]
     - *The host:* responsible for the work of the session; proposes where a decision is the
       Operator's; commits and pushes only when asked; never commits to the base branch; reads the
       backs' writes before each commit. [PROCESS "Who does what"; DEVHOST "Git rules"]
     - *A con:* responsible for one job within its brief; replies once in the hand-off shape; brief
       names bounds, model and isolation. [PROCESS "Who does what"]
     - *A back:* only adds (the secretary also ticks); never talks; a guard undoes anything else;
       runs inside the devhost only. [ADR 0003; DEVHOST "Backs, stakes and quiet notices"]
     - *The night shift:* works only an agreed list within a cap; one commit per item, nothing
       pushed, deployed, sent or decided; reviewed by the Operator in the morning. [PROCESS; night-shift
       skill]
     - *Informed:* the Operator by the briefing, quiet notices (only when they must act) and the
       hand-off. [DEVHOST]
   - **To confirm:** the rows exist in prose but not as one RACI table, and cons are briefed for a
     job without the parts of a place (the guide: every sub-agent has the whole set, and the operator is
     always a persona). [final round 7; difference D2]

### Boundaries settled before the first commit

10. **Names and data: who and what must never appear in committed files? Any exceptions?**
    - **Answer:** the names in the ignored `.devhost/redact-names.txt` (restored after the
      2026-10-19 rebuild); committed files hold paths and ids, never content; the forbidden-words
      guard skips only files in `.devhost/name-exceptions.txt`, a list the Operator approves (ADR
      0010). The approved exceptions: the two copies of paper 1 in the seed's export, byte for byte.
      The person is "the Operator"; the two projects are "the office" and "software project 1".
      [DEVHOST "Git rules"; ADR 0010; TODO `restore-redact-names`, `name-guard-approved-files`; I3 q15,
      q20, q40, q41]
11. **Identity: who do agents commit as, which addresses are safe?**
    - **Answer:** the bot identity `devhost agent <devhost-agent@noreply.invalid>` (author, committer
      and sign-off), set by the git Feature only for git run by an agent (it carries `CLAUDECODE`); the
      Operator's terminal keeps their identity; a co-author trailer names the model at an unclaimable
      `@noreply.invalid` address; never `noreply@anthropic.com`, which a stranger's GitHub account
      appears to have claimed. [CLAUDE "Git here"; ADR 0001; ADR 0002; ADR 0012; ADR 0016; `.devcontainer/devcontainer.json`]

### Tooling: bootstrapping the environment

12. **Where will sessions run, where does state live, how is git set up, public or private?**
    - **Answer:** sessions run in the devhost; the checkout is the only thing on disk; each Feature
      keeps its state (Claude Code, git's global config, gh) in a volume it owns; the checkout's git
      dir sits outside OneDrive and is bind-mounted, with the git Feature's wrapper keeping `GIT_DIR`
      scoped to it; the workstation only bootstraps and launches. The repository is **public** on
      GitHub, `main` protected (pull requests only, squash merges, DCO sign-off, required checks
      `validate`, `lint`, `tests`, `DCO`). The dev container is used; the guide's "without containers"
      options are not relevant. [CLAUDE; README "How the pieces fit", "Governance"; `.devcontainer/devcontainer.json`]

**Default for P3:** the seed's default is a context file and a template dev container; here the
tooling goes further and the context file is missing (difference D1).

## 6. P4: Claims need evidence

- **Answer:** the court is held in the records: a claim comes with evidence (the diff, test output, a
  check shown able to fail); the host checks each hand-off ("a report is not evidence"); small claims
  never reach court because a guard settles them (`devhost-verify`); only judgment goes to the
  Operator; exceptions are recorded as such (ADR 0010). The mutation proof ("a check is trusted only
  after it has been shown able to fail") is in the test briefs. "Not yet a mechanical hand-off check."
  [AGENTS P4; PROCESS "Happy path"; ADR 0010]
- **Which record language. Answer:** RFC 2119 keywords (MUST, SHOULD, MAY) in short, plain sentences
  for rules; the Feature requirements use them (10 MUSTs in the NFR file). Simplified Technical
  English is offered in the principle as the alternative and not used. [AGENTS P4; NFR]
  - **To confirm:** that RFC 2119 is the Operator's choice (the records state it as the repository's
    practice but no interview question records the Operator choosing). [final round 10]

1. **Where do agents write things down for each other?**
   - **Answer:** the ledger, ADRs, `TODO.md`, pull request descriptions, briefs and hand-offs in the
     shape Outcome, Outputs, Friction, For the repository, Decisions needed; stakes (one plain line)
     to a back. [AGENTS P4 "In this repository"; DEVHOST]
2. **What must an agent never do without your ruling?**
   - **Answer:** merge to `main` or run a release; push, deploy, send or decide during a night shift;
     reword or remove a backlog item (backs); resolve an item marked for the Operator; widen its own
     permissions; commit under the Operator's address. "A permission counts only when the Operator
     grants it in their own settings." Commit and push only when asked. [CLAUDE "Git here"; DEVHOST;
     PROCESS "Rules of thumb"; ADR 0001]
3. **How should a case be put to you?**
   - **Answer:** numbered questions with a recommendation, answerable in one line, often from a phone;
     for a change, the diff and the check that proves it; for a merge, the pull request. [AGENTS P1;
     ledger 2026-10-20 "Branch naming rule settled" ("42 yes ... 46 yes"); I3 q19 to q41]

**Default for P4** (the hand-off shape, RFC 2119, nothing decided for the person): met.

## 7. P5: Right-size the work

- **Answer:** the host plans and judges, cons do, backs record; two questions in order before a job is
  handed out: can the rule be written down? Then a script with a test that can fail. Can the result be
  checked mechanically? Then an agent does it and a script guard checks it. Otherwise an agent proposes
  and the Operator decides. Models are sized by blast radius, with the cost report and the ledger
  review as the check; a small model only where a check can verify the result completely. [AGENTS P5;
  PROCESS "Working the backlog"]

1. **What is a one-point piece of work?**
   - **Gap: question for the Operator.** Nothing defines a point. The nearest records: a con is
     briefed for "one job"; a night shift does "one commit per item"; the branch rule is one item (or
     several, listed in the pull request) per branch. [PROCESS; night-shift skill; ADR 0017]
   - **Recommendation:** one backlog item, one branch, one pull request, small enough that a
     reviewer reads it in one sitting; a con's job smaller still.
2. **What should be a script, not an agent?**
   - **Answer:** the guards (`devhost-verify`), lint, the tests, the cost report, the briefing, the
     shutdown check, `devhost:branches`, the docs generator; the tester back has no model. Releases are
     a manual workflow the Operator starts. "The cost report and the guards, being scripts, cost
     nothing." [AGENTS P5; LEXICON "Tester"; CLAUDE "Git here"]
3. **Budget and models: what monthly spend, who may spend, what may run unattended?**
   - **Answer, in part:** the night shift's default cap is $10 at list price, stops at an agreed time,
     and runs only an agreed list; unattended work happens only under `/night-shift`; the month's spend
     is shown at every session start; models are sized by blast radius (host largest, cons by blast
     radius, backs small). [night-shift skill; DEVHOST "How work flows" step 2; PROCESS]
   - **Gap: question for the Operator:** the monthly cap, and who may spend. No record states one;
     October 2026 reached $105.72 at list price by 2026-10-20. **Recommendation:** name a monthly
     figure the briefing warns against at 80%; keep $10 a night; only the Operator and sessions they
     start spend.

**Default for P5** (inter and con split, one-point pieces, script first, then a checked agent, then
the person; the budget the person names): met except the budget and the definition of a point.

## 8. What from the seed applies

The guide asks for adopt, adapt or leave out for each foundation piece. This repository is the source
of the foundation, so each piece is already in use; the useful answer is whether it is used as the
seed ships it. [`docs/iterations/foundation.txt`; I3 q12, q14, q19, q24]

| Foundation piece | Here | Marked |
| --- | --- | --- |
| `docs/principles/agents.md` | in force (ADR 0011, 0013) | adopt |
| `LEXICON.md`, `PROCESS.md`, `docs/model/ontology.toml` | in force; the seed's copies are worked examples | adopt |
| ADRs 0003, 0005, 0006, 0008, 0009, 0011, 0013, 0014, 0015, 0016 | in force (0009 is to be marked superseded by 0014, I3 q13) | adopt |
| ADRs 0004, 0007 (themes) | in force here, out of the seed | adapt (personalization) |
| ADRs 0001, 0002, 0012, 0017 | in force here; 0017 (branch names) postdates the foundation list | see D6 |
| Non-functional requirements (Features) | this project's product, out of the seed | leave out of the seed |
| Starter: `devcontainer.json`, `SETUP.md`, `CONTEXT.md` | the devcontainer differs (local Features), `CONTEXT.md` is missing | see D1, D4, D5 |
| Skills: close-session, ledger-review, night-shift, shutdown-devhost, restart-devhost, new-adr, publish-site, drop-a-seed, plant-a-seed | present | adopt (see D9 for the manifest) |

## 9. Closing topics

The guide leaves the closing topics (intent behind the records, where missing data lives, the story,
keep-change-drop) to `drop-a-seed`; they were run in interview 3. Not repeated here.

## Where this repository differs from the seed

What the seed (its guide and its SD defaults) would set up, against what this repository has, with a
recommendation: **change the repository**, **change the seed** (the foundation, the starter or a
skill), or **record as this repository's personalization**. Nothing is changed by this document.

| # | The seed says | This repository does | Recommendation |
| --- | --- | --- | --- |
| D1 | P3 MVP: one `CONTEXT.md` at the root holding purpose, personas, boundaries, inputs, outputs, process, ceremonies, lexicon, tooling. | No `CONTEXT.md`; the parts are spread over README, CLAUDE, DEVHOST, PROCESS, LEXICON, AGENTS. | **Change the repository:** add a `CONTEXT.md` filled from this interview (section 5), linked from CLAUDE.md. The repository should hold what it tells others to hold. |
| D2 | Every sub-agent has the whole place; its personas are itself, its invoker and always the operator; boundaries are a RACI row. | Cons get a brief (job, bounds, model, isolation, hand-off shape); no persona or RACI statement; boundaries are prose. | **Change the repository:** one RACI table in `CONTEXT.md`, and the con brief gains a short place block (the operator as persona, the invoker, the outputs). |
| D3 | SD defaults: grooming, planning, stand-up, retrospective; agents as developers, QA, architect, scrum master, analyst. | Host, cons, backs, night shift; no agile ceremonies; "No new ceremony". | **Record as personalization:** the repository is the small SD version; keep, and say so in `CONTEXT.md`. |
| D4 | Starter `devcontainer.json` pulls published Features (`:1`) and omits the git identity options. | Local Features staged by `task features:stage`; git Feature sets `commitName`, `commitEmail`, `commitWhenEnv`; adds docker-in-docker, PowerShell, shellcheck, yamllint, a git-dir bind mount. | Local Features and the git-dir mount: **personalization** (a product repo tests its own tree, git dir outside OneDrive). The missing identity options: **change the seed's starter** (P3 q11 says settle identity before the first commit, so the starter should set the bot identity). |
| D5 | P3 q12 default: private repository on a hosted git service. | Public; DCO sign-off, protected `main`, governance script, CODEOWNERS-style approval. | **Record as personalization** (a public collection). Keep out of the seed. |
| D6 | The foundation lists ADRs up to 0016; the guide mentions identity (ADR 0001, 0002). | ADR 0017 (branch names carry a backlog id) and `devhost-branches` are newer; ADRs 0001, 0002, 0012 are not in the foundation list. | **Change the seed:** add 0017; consider 0001 and 0002 (identity before the first commit is a guide topic, so its reasons belong in the seed). |
| D7 | P2 unit: one story ending in one pull request; retrospective every two weeks. | Ledger unit is a turn or a job; delivery unit is a backlog item; review every five or so entries, which the Operator found too frequent. | **Change the repository** once the Operator settles the cadence (`ledger-review-cadence`); then **change the seed's** guide example and `ledger-review` skill to match. |
| D8 | P1 q3 and q4: a stated "done" signal and a check-in day and time. | Neither is written; `hang-on-skill` is unbuilt. | **Change the repository:** record both in `CONTEXT.md` as personalization after the Operator answers; build `hang-on-skill`. |
| D9 | The seed's manifest should carry every skill the way of working needs. | The manifest lists neither the ledger nor the `ledger-review` skill (TODO `seed-manifest-ledger-skills`). | **Change the seed:** add both, or state the exclusion. |
| D10 | P4: where the person has not chosen, RFC 2119 is the default. | RFC 2119 is used; no recorded choice by the Operator. | **Record as personalization** once confirmed (round question 10). |
| D11 | Themes: offer the devhost or the office; warns about the Arthurian rename. | Devhost theme plus the Arthurian and life layers as optional layers in the lexicon. | **Record as personalization:** keep the layers here, out of the seed (I3 q11, q19). |
| D12 | The dashboard is a docs library shown by a page published as an artifact. | The same (site, `publish-site`), but publishing is manual, the browser check and the docs artifacts are open items, and the Operator has not settled how a repository exposes outputs. | **Change the repository** by finishing `publish-site-browser-check`; the concept itself stays an open Operator item (`repo-outputs-concept`). |
| D13 | P5 q3: a monthly budget the person names, and who may spend. | A night-shift cap ($10) and a monthly total in the briefing; no monthly cap. | **Change the repository:** record the Operator's monthly cap in `CONTEXT.md` once named. |
| D14 | Release belongs to the person (the guide's own SD example: "publish a release" needs the person's ruling). | The Operator runs releases; in CLAUDE.md, and the host's memory. | **No difference.** Note: the rule is both a repository rule and a personal memory file; keep it in CLAUDE.md. |

## Questions for the Operator

The round the host puts to the Operator. Each can be answered in one line ("1 yes, 3 no"). Terms
are explained where they appear; you do not need the lexicon.

1. **Use case.** The seed offers two example setups. "Software delivery" is a software shop that
   builds a product with agents in the agile roles (developers, QA, a scrum master). This repository
   is the small version of it, with no agile roles or meetings. Do we treat the repository as that
   small version and say so in its own context file? **Recommend yes.** (Also: conversation is short
   answers, decisions as numbered questions, pictures where a flow matters, and the white paper stays
   long; is that how you want to be talked to? **Recommend yes.**)
2. **"I'm done" word.** You often send several messages in a row. Which one word do you send to say
   "now act on all of that"? **Recommend "go"**; until you send it, the host replies with one word per
   message and does nothing else (a small skill to build, `hang-on-skill`).
3. **Check-in time and review cadence.** Today a "ledger review" (the host reads the last entries'
   problems and costs and turns each cause into one action) runs every five or so entries, which you
   found too often, and no day and time exists for anything. Pick: (a) once a week on a day and time
   you name, covering the review, the cost report and the open decisions; (b) after each finished
   backlog item; (c) every ten entries. **Recommend (a), Monday 09:00 your time**; say another time if
   that is wrong.
4. **What "done" means.** A backlog item is ticked "Done" today when it is committed, but a merge and
   a release are separate. **Recommend:** "done" means merged to `main` by you; "released" is a
   separate step that only you start. Yes or no?
5. **Unit of work.** Recommend one definition: one backlog item = one branch = one pull request, small
   enough to review in one sitting; the ledger keeps one entry per turn or job, as now. (The seed's
   example says "one story, one pull request".) Yes or no?
6. **Money.** What is the monthly spend, at list price, you are comfortable with? Nothing records one;
   October 2026 reached $105.72 by 2026-10-20. **Recommend:** you name the figure; the briefing warns
   at 80%; the night-shift cap stays $10 a night; only you and sessions you start may spend.
7. **Who is served and who is informed.** Personas (the people the agents work for) recorded: you,
   other engineers, the maintainers of the office and software project 1, and public contributors to
   this public repository. Keep public contributors in the list? **Recommend yes**, as persons the
   agents are polite to but do not serve. And do you agree the host writes the per-agent boundaries
   (who is responsible, who may not do what, who is consulted or informed) as one table in a new
   `CONTEXT.md`, and gives each helper agent a short "who you serve" block in its brief? **Recommend
   yes to both.**
8. **Add `CONTEXT.md` here.** The seed asks every project for a single file holding its purpose,
   personas, boundaries, inputs, outputs, process, ceremonies, words and tooling; this repository has
   none. Build it from this interview, linked from `CLAUDE.md`? **Recommend yes.**
9. **Changes to the seed itself.** Three: (a) put ADR 0017 (branch names carry a backlog id) and the
   identity ADRs 0001 and 0002 in the foundation; (b) make the seed's starter dev container set the
   agents' commit identity (a made-up address nobody can claim), since the guide says to settle it
   before the first commit; (c) add the ledger and the ledger-review skill to the seed's manifest.
   **Recommend yes to all three.**
10. **Record as this repository's own choices, not seed defaults.** Keep: the public repository with
    protected `main` and sign-off rules; local-path Features in this repository's dev container; the
    Arthurian and life word layers (kept out of the seed); rules written with the words MUST, SHOULD
    and MAY (RFC 2119, an internet standard for stating how binding a rule is) rather than a controlled
    English like Simplified Technical English. **Recommend yes to all four.**

When you answer, the host writes the answers word for word into this file, then makes the changes you
approved on topic branches (items D1, D2, D4, D6 to D9, D12 and D13 in the table above).
