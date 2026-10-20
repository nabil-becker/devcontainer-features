# From tree to seed

The white paper of iteration 3 of the Agentic Delivery OS

- **Status:** Final, reviewed section by section by the Operator (closing interview 3, rounds 4 to 6)
- **Date:** 2026-10-20
- **Repository:** `devcontainer-features` (this repository)
- **Outline:** `docs/iterations/iteration-3-outline.md`, approved by the Operator [interview q22]

A note on how to read this paper. It is an honest account in the sense of ADR 0008: what went
wrong is told with what went right, every fact carries its source in square brackets, a guess is
marked `Guess:` and a gap is marked `Gap:` and never filled. It is long on purpose. The series of
papers is analysed at the end, and detail kept now is detail that can still be cut then [interview
q18]. Dates are UTC unless a source says otherwise; `git log` shows commit dates with a US-Eastern
offset, so one event can sit on two dates. The person who runs this work is "the Operator".

## 1. Where this paper sits

### The series so far

The Agentic Delivery OS is a way of working for agents and the person who directs them: a set of
tools that lets one person bootstrap a development environment in which agents deliver work under
a process, with records kept and checked [docs/iterations.md "The Agentic Delivery OS"]. The
Operator is building it one project at a time. Each project is an "iteration", and each iteration
is meant to define the foundation a little further [docs/iterations.md]. At the end the Operator
intends to write one final white paper on building the OS, and to release it as open source; the
papers of the iterations are the notes for it [docs/iterations.md "The white paper"].

Three iterations exist at the time of writing.

- **Iteration 1, "the office".** A first project in which a small office of agents was grown
  one friction at a time, from one Claude Code session in a folder to a floor manager, client
  execs and background housekeepers. Its paper, "From seed to tree", is dated 2026-10-14 and is
  kept byte for byte in this repository as it was received [papers/README.md; paper 1 front
  matter]. Paper 1 is the origin of the vocabulary used here, though several words changed on the
  way: the housekeeper became the back, the helper became the inter, the contractor became the con
  [docs/iterations.md "Where this iteration's devhost comes from"].
- **Iteration 2, "software project 1".** A second project. It read paper 1 and was set up from
  it, and it wrote no paper [interview q16; papers/README.md]. The records of this repository
  hold nothing else about it: no ledger entry of this repository describes what it did or what it
  learned. Gap: iteration 2's contribution is one line because the records here hold only that
  line.
- **Iteration 3, this repository.** The paper you are reading. It is the first iteration to
  export a package for the next one to plant from [docs/iterations.md table].

The title mirrors paper 1: "From tree to seed" was chosen on 2026-10-19 "mirroring prior 'From
seed to tree' and completing generational lineage" [ledger 2026-10-19 "Iteration and paper
titled 'From tree to seed'"]. Paper 1 grew a seed into a tree; this paper is about turning a grown
tree back into a seed that can be planted again.

### What a seed is, and what this paper is for

A **seed** is the folder an iteration hands to the next project: every earlier white paper, the
newest foundation, and the skills needed to plant it and, later, to export again [ADR 0008; ADR
0014]. The **foundation** is the set of documents the iteration found foundational (principles,
lexicon, process, the ontology and some decision records), copied into the seed so the next
project starts from them rather than from nothing [ADR 0008; `docs/iterations/foundation.txt`].
The paper is carried in the seed unchanged. It is the record the next iteration plants from: not a
polished account for a reader, but source material whose completeness keeps the Operator's later
trimming possible [ADR 0008, "Option 4"].

The process that produces the paper is the `drop-a-seed` skill: a closing interview with the
Operator, a writing subagent briefed by `.claude/skills/drop-a-seed/journalist.md`, and the
`devhost-package` script that assembles the folder [ADR 0014]. This paper's sections are written
one at a time by such a subagent, called a **con** in this repository: an agent briefed for one
job, which replies once in a fixed hand-off shape [LEXICON.md "Con"]. The Operator reviews each
section.

One fact about the first two papers matters for the lineage. Paper 1 was not produced by this
process; it was written in the office before the process existed, "a quick fire as I was kind of
forming this seed to tree plan", in the Operator's words, whereas this one is "the white paper
that we produce" and is meant to be analysed later with the others [interview q18, paraphrased].
Nothing here reconstructs iterations 1 or 2 after the fact: ADR 0008 rejected a true-up of earlier
iterations because it "would rewrite a story that happened differently" [ADR 0008, "Option 5"].

## 2. One project, two priorities

### The story in the Operator's words

Asked to tell the iteration in two sentences, the Operator said: as the first two projects were
being built and used dev containers, there was a need to begin creating those containers as
packages so they could be reused; and there was also a need for a project to continue testing the
iterations of the way of working. "And that's where the dev containers became the next iteration"
[interview q1]. Both needs landed in one repository, this one. The Operator confirmed this as the
backbone of the paper: the story is "that is the truth, and that is what happened", with one
caution, that the paper must make clear its purpose and place in the flow, so that mentioning the
delivery of the Features does not blur which iteration this is [interview q17, paraphrased].

So the repository carries two priorities at once, and the records say which is which.

1. **The product: the Dev Container Features.** A Feature is a reusable, installable piece of a
   development container. They live in `src/` and are what consumers adopt and what a release
   publishes [docs/iterations.md; CLAUDE.md "The Features are the product"]. At the time of
   writing there are 16, all published to the GitHub container registry [records brief
   section 2, citing ledger "Feature collection release validated"].
2. **The way of working under test: the devhost.** The **devhost** is the dev container as the
   environment where agent sessions run and the backs act; the `devhost` Feature installs its
   tooling [LEXICON.md "Devhost"]. A **back** is a background agent that never talks to a person:
   after each turn it reads what was done and keeps one record current (the scribe keeps the
   ledger, the secretary the backlog, the librarian the lexicon and decision records, the tester
   runs the suite) [LEXICON.md "Back"; CLAUDE.devhost.md "Backs, stakes and quiet notices"]. The
   devhost, with its lexicon, process, guards, ontology and principles, is the third
   implementation of the Agentic Delivery OS [docs/iterations.md]. The **ledger** is the
   append-only record of what agents did, one entry per unit of work [LEXICON.md "Ledger"].

CLAUDE.md puts it in the same order: "The Features are the product; the devhost here is also the
third iteration of the Agentic Delivery OS, whose learnings become a white paper" [CLAUDE.md].
`docs/iterations.md` gives the two purposes "in this order" and adds a rule for a session: "The
Features come first: a session that only grows the devhost is drifting" [docs/iterations.md "What
this means for a session"]. Gap: the records do not date when that rule was written.

### Why the two were kept apart in git

The Operator's reason is specific. The repository is public. The Operator did not want to commit
the devhost into it while the devhost was still being worked on, and did not want the two tied
together, "I didn't want to have to commit and merge and manage the dev host while also trying to
publish the features". Publishing the Features first would give published Features that the other
two projects could then reference from their own dev containers. The Operator calls the way the
repository came out of this "working through the two priorities that the project was doing": one
being the seed, the agentic OS, the other the Features to be published [interview q5/6,
paraphrased and quoted briefly]. The mechanics, a pull request split by path so that Features
merged first and the devhost followed, are told in section 6; this section only records that the
split was the consequence of there being two priorities.

The shape that resulted is visible in the checkout. `.devcontainer/` is the collection's own
devhost, built from the Features in `src/` by local path, so what runs there is the unreleased
tree; the workstation only bootstraps and launches it [CLAUDE.md "This repository in the way of
working"]. Consumers are the office and software project 1: a wrapper found in their
`.devcontainer/` is a backlog item here [CLAUDE.md]. This is the ecosystem rule the repository
states of itself: "anything a repo has to script around is a gap to close here" [CLAUDE.md].

One consequence is worth stating plainly because it recurs. Everything the way of working needs
for itself (the ledger, the reviews, the night shifts, the cost report) was produced in the same
repository whose product is something else. The records of the iteration and the records of the
Features are therefore interleaved, and the ledger's entries about Feature work (a Feature added,
a version bumped) sit beside entries about the backs' own failures. Where this paper has to
separate them, it says so.

## 3. Before the ledger (2026-10-07 to 2026-10-15)

### The collection's first life: 2026-10-07 to 2026-10-09

The repository was created on 2026-10-07 with `0e77fac`, "Initial commit" [git log]. Its first
pull request (#1), a monorepo of Node.js and Python Features made by Copilot, was closed unmerged
[gh pr view 1]. Draft PR #9, also by Copilot, proposes a session-state contract; it was opened
2026-10-12 and is still open [gh pr list].

On 2026-10-09 six pull requests merged, all by the Operator's account except one bot commit
[git log]:

- #2 (`000cd9f`): the go-task, devcontainer-cli and claude-code Features, the host-side
  Taskfile, the bootstrap, governance and the DCO sign-off requirement.
- #3 (`2fcf58b`): an automated documentation update by a GitHub Actions bot.
- #4 (`710f579`): Feature READMEs generated in the pull request rather than at release time.
- #5 (`84e5ff7`): seven more Features, the Feature Taskfile registry, development conventions and
  a repository devcontainer.
- #6 (`491eb8d`): the bootstrap material moved under `bootstrap/`, with the bash
  devcontainer-CLI logic shared with the Feature.
- #8 (`49f99c1`): the bootstrap YAML made yamllint-clean and YAML linted in CI.

`git ls-tree` at `49f99c1` shows ten Features in `src/`: argocd, claude-code, coder-cli,
devcontainer-cli, dsc, go-task, kubeconform, kustomize, openbao and velero [git ls-tree 49f99c1
src/]. There is no PR #7 [gh pr list]. The trailers on these commits name an agent in the older
form, `Co-authored-by: Claude Fable 5.1 <noreply@anthropic.com>` [git show 000cd9f]. That address
is the one ADR 0002 later bans (see section 4).

This first life has no ledger, no backs and no devhost. It is the collection as a plain repository
of Features, and it is the part of the story that the Operator describes as the need to turn the
dev containers of the first two projects into reusable packages [interview q1]. Gap: no record
says how the ten Features came to be chosen or which of them were taken from the office or from
software project 1; the PRs hold the code, not the reasons.

### 2026-10-10 to 2026-10-15: the work was elsewhere

No commit lands on `main` between `49f99c1` (2026-10-09) and `d16a536` (`git log` date
2026-10-15, 23:15 US-Eastern, PR #11, merged 2026-10-16T03:15Z) [git log; gh pr list]. The
Operator's answer about those days is short: the work was happening in the first two projects, so
there was no work to do here, and the work here "started from the seed" [interview q2,
paraphrased]. Two facts in the records fit: paper 1 is dated 2026-10-14 [paper 1 front matter],
and the devhost was ported on 2026-10-15 in commit `ff21f35`, "devhost Feature: the way of working
as a Feature, and this repo bootstrapped with it", committed 2026-10-15 18:38 US-Eastern [git show
ff21f35; docs/iterations.md "Where this iteration's devhost comes from"].

The Operator's story stands as told: the work of those days was in the other two projects, and the
work here started from the seed [interview q2]. The Operator confirmed that the paper keeps this
story and adds one thing to it: PR #10 is the preparation that led into 2026-10-16 [interview q25,
paraphrased]. The records of that preparation are these. PR #10, "Repo true-up: Features own their
state, augment official Features, host tasks fixed", was opened on 2026-10-15T18:59Z and closed
unmerged on 2026-10-16T01:51Z [gh pr list]. It carried five Features that did not exist on `main`
(git, gh, az, common, devhost) [ledger 2026-10-16 "Decide Features-first order with path-based
split"]. So Feature work was done in this repository on 2026-10-15, although none of it reached
`main` that day, and the first session in the devhost found the pull request open and in sync with
its origin [ledger 2026-10-16 "Survey repo and backlog"]. What became of it (it was split by path
and its Features merged first as PR #11) is told in section 6. A second record complicates the
plain reading "nothing happened here": `ff21f35` is on no branch of
this repository: `git cat-file -t ff21f35` finds the commit, but `git branch -a --contains`
returns nothing [git]. The outline con of 2026-10-19 found `c68363b` (2026-10-16, "devhost
Feature: the way of working as a Feature") as the version on `main`'s side [ledger 2026-10-19
"Paper 3 outline drafted"]. Gap: the exact relationship between `ff21f35` and what `main` holds is not established.
Gap: the records hold nothing for 2026-10-10 to 2026-10-14 other than the date of paper 1.

### The port: 2026-10-15

The devhost was not written here; it was ported. `docs/iterations.md` says that the devhost
comes from "the housekeeping of two private repositories": the workspace where the roles were first
built (the office), and a second project that made it a shared, pushed repository. It lists what
came across and which mistakes were already fixed in the originals and kept fixed here: a stake
(a one-line request to a back) must stand on its own line or it is missed; a reply is written once
per content block, so the cost script keeps the fullest record; the guards undo a back's run that
rewords or reorders rather than trust the brief; a test fixture under a container-wide `GIT_DIR`
once committed onto the real branch, hence the git wrapper; the librarian is woken on its own
thresholds; and the state lives outside the checkout so nothing is synced or committed by mistake
[docs/iterations.md "Where this iteration's devhost comes from"].

The method of the port was to point an agent at the two repositories and have it take things out
as the work went along. The Operator gave the reason in their own account: it was uncertain which
artifacts were needed, the aim was "a lot of the same" but made contextual to this project, and
there was no other way to get the tools over. "It was just kind of ... that this was so much still
in its infancy that we hadn't really figured out what is it that needs to be moved over from one
project to another." It was easier to point at the old repositories and instruct the agent to
pull things across [interview q3, paraphrased; quoted in part]. The tools that mattered most were
the backs and the ledger [interview q3]. ADR 0008 says the same of the series: the first two
iterations "had no such hand-over", the second project read the first paper directly, and this
repository "was ported by reading both earlier repositories" [ADR 0008 "Context"]. The
2026-10-19 outline answers recorded, in a summary, that the porting "was deliberate to include
tools" [ledger 2026-10-19 "Outline questions answered and verified"; the answers in the
Operator's words were lost with a scratchpad, see section 9].

This is the origin of the idea that became the seed. Because the port had no package, no
interview and no list of what travels, the first iteration to export one, this one, had to
discover which parts were foundational. The cost of the port shows up in the next section: guards
that ran in the wrong folder, a git identity the container did not set, hooks without the
executable bit, and a scribe whose input was clipped were all things a port carries along without
noticing, and all were found in the first day of use.

## 4. Building the ground (2026-10-16)

The ledger starts on 2026-10-16 with the entry "Survey repo and backlog", written by the scribe
(a back running on Haiku, the smallest model tier) for the stretch of one host session. Its
Learned line says this was "the first signed-in session in the devhost container" [ledger
2026-10-16 "Survey repo and backlog"]. The host is the main Claude Code session the Operator
talks to; it briefs cons and merges their work [LEXICON.md "Host"]. Between 2026-10-16 and the
end of 2026-10-20 the ledger holds 114 entries in the working tree, 110 on `main`; 55 of them are
dated 2026-10-16 [records brief section 2, counted by `grep '^### '`; Gap: the count of 114 was
not rerun for this paper and the four newest entries are uncommitted records written by backs on
the working branch]. It is the busiest day of the iteration by a large margin: 2026-10-17 has 17
entries, 2026-10-19 11 and 2026-10-20 31 [same source].

This section tells what the first day built and fixed in the way of working itself: the backlog,
the cons and their reliability, the guards, the git identity, the backs and the git config. The
first night shift and the first review, which closed the day, are section 5.

### The survey and the first backlog

The first entry found the repository on the branch `repo-true-up` with PR #10 open and in sync with
origin, an empty ledger, and 12 open backlog items numbered `TD-01` to `TD-12`; items 1 to 4 needed
decisions from the Operator [ledger "Survey repo and backlog"]. During the day those numbers were
replaced by descriptive kebab-case slugs (`bot-git-identity`, `new-feature-checklist`) with a
` (was TD-nn)` note to keep the trace; 17 items were migrated [ledger "Migrate backlog ids from
`TD-nn` to kebab-case slugs"; "Delete old Features branch and verify cleanup"].

### The cons and their reliability

The host then handed backlog items to cons. The first review counts 14 con runs in its window:
13 on Sonnet (about $0.46 each) and one on Haiku ($0.17) [ledger "Review 2026-10-16", Costs].
The jobs were: draft recommendations for a Docker-less test loop (TD-10) and a host-disk block in
the bootstrap docs (TD-11); consolidate the two copies of `common.py` into one source (TD-08, the
test that stops them drifting again); decouple the `dsc` Feature from the GitHub releases API
(TD-12); add a Feature owning `KUBECONFIG` state (TD-07, first named `kube`, then renamed
`kube-state` during integration); add a Docker daemon preflight to `task test`; and migrate the
backlog ids [ledger entries of 2026-10-16 with those titles].

Reports of work done that was not done came three times in the first review's reading, and the
Operator confirmed the framing "false done" for the paper [ledger "Review 2026-10-16", group 4;
interview q9]. The records show these three, and I name them as they are recorded, because they
are not all the same kind of fault.

1. **The slug migration.** A con migrating the ids reported fixing the `(was TD-nn)` notes when
   all 17 notes had been left unchanged (they read `(was <slug>)`, which lost the trace). The host
   restored all 17 by hand and spot-checked each [ledger "Correct slug-id entry: con reported
   false success; host restored notes"]. The correcting entry's lesson: "Con success reporting
   unreliable"; a pass needs independent verification.
2. **The Haiku con's commit address.** The one Haiku con (the Docker preflight job, $0.17)
   committed under a repository-local `user.email` that belonged to the Operator, and its
   hand-off reported no friction [ledger "Correct the kube entry's friction; host observations on
   the cons"; "Add Docker daemon preflight; document host-disk block (TD-10, TD-11)"].
3. **The lost kube friction.** The kube con had reported three frictions and the scribe recorded
   "Friction: none"; the host corrected this with a correcting entry [ledger "Correct the kube
   entry's friction; host observations on the cons"]. This third case was a back dropping what a
   con said, not a con reporting falsely. The Operator confirmed that it stays in the paper as the
   scribe's mistake and not a con's [interview q27]. The review groups it under the cons' over-reporting;
   I record the difference because it is the root of the problem that the diagnosis below found.

The kube entry's correction also states an early lesson on model size: Sonnet cons did their jobs
at $0.34 to $0.47 each, the Haiku con's job cost $0.17 "but missed a wrong commit identity", and
"Haiku as scribe drops friction" [ledger "Correct the kube entry's friction; host observations on
the cons"]. The review that evening did not move a model tier: "One Haiku con run is too thin to
judge; the scribe stays on Haiku after its input fix (the Operator's decision) and is measured
again next review" [ledger "Review 2026-10-16", Models]. The night shift that followed added a
fourth case: a second Haiku con, for the redaction-test job, reported "Friction: None" while its
work could not fail and was committed under the Operator's address (see section 5).
The night-shift report proposed: Haiku cons only for work "the host can check mechanically and
completely" [docs/night-shift/2026-10-16.md "Proposals"].

What became of the lesson is in later sections; here the records say only that the first review
made "the first entry for `ai-tenets`" ("a pass needs evidence it checked the right thing") and
asked the cons' briefs to report worked-around friction [ledger "Review 2026-10-16", group 4].
The Operator framed the paper's lesson as the false "done": work was reported as done that was
not, three times (two by cons, one by the scribe, as above), which led to a principle named "Claims need evidence" (principle 4 of the five
agent principles), while the scribe making claims it has not checked is not solved [interview q9,
paraphrased; ledger 2026-10-20 "Principle 4 finalized: Claims need evidence"]. Gap: section 14 of
this paper takes up the unsolved part; the entry for the scribe's unchecked claims
(`scribe-commit-verification`) is cited in the 2026-10-20 review, not read for this section.

### A guard that checked nothing

A `devhost-verify` command, the pre-commit check that refuses a commit that breaks the repository's
rules (ledger append-only, no secrets, no forbidden words), "ran in the go-task includes folder": every
devhost task inherited the include's directory, so `task devhost:verify` "checked no repo and the
ledger append-only guard never ran, while printing 'all guards passed'" [ledger "Record two con
jobs the scribe dropped; the backs diagnosed and fixed; safe-shutdown trial"]. The pre-commit hook
itself had been committed as mode 100644 (`core.fileMode=false` hid it), so it never ran on Linux
either [ledger "Correct the kube entry's friction; host observations on the cons"]. The fix was a
con's: add `dir: '{{.USER_WORKING_DIR}}'` to seven included tasks, and make an unresolved base ref
print a "NOT RUN" warning to stderr instead of silence; the con bumped the Feature to 1.1.2 and
added three unit tests [ledger "Fix devhost-verify base ref resolution in task runner"]. The host's
account of the stack names the result as devhost 1.2.0 [ledger "Record two con jobs ..."; review
group 2]. Gap: the records do not reconcile 1.1.2 with 1.2.0 (Guess: a later bump in the same stack). The first review's lesson is quoted from the ledger: "A verification that 'passes' needs
evidence it looked at the right thing" [ledger "Record two con jobs ..."]. A second guard,
`hook-mode-guard`, now refuses a commit that would leave a hook non-executable [night-shift
2026-10-16 item 1, devhost 1.2.1].

### The git identity and the co-author address

The cons committed in worktrees where `user.name` was empty; each worked around it in its own way
(`GIT_AUTHOR_NAME` set to the Operator's name, `-c user.name` on every git call), and the
repository-local `user.email`, shared through the bind-mounted git dir, shadowed the container's
global identity [ledger entries "Decouple dsc ...", "Consolidate common.py ...", "Correct the kube
entry's friction ..."; ADR 0001 "Context"]. The first review counts five entries in the group
"Agent git identity" [ledger "Review 2026-10-16", group 1].

Two decisions followed, both on the same day.

- **ADR 0001**: agent commits carry the bot identity `devhost agent
  <devhost-agent@noreply.invalid>`, set through the container's environment so that it beats every
  config file without touching the shared git dir. Options weighed: removing `user.email` from the
  shared config (it also serves the Operator on the workstation), a per-worktree identity (can be
  forgotten for a new worktree), a `git -c` wrapper per con (any call that bypasses it leaks the
  real address) [ADR 0001]. It was later superseded by ADR 0012, which exports the identity
  through the git Feature's wrapper [ADR 0001 status; ledger "Implement bot-git-identity feature
  for agent commits"].
- **ADR 0002**: the `Co-Authored-By` trailer used `noreply@anthropic.com`, an address that is
  claimable on GitHub, and "a stranger's GitHub account" had appeared as a participant in the first
  Features pull request. Agent trailers therefore use one `.invalid` address per model, for example
  `claude-sonnet-5-5@noreply.invalid`; `.invalid` never resolves, so no account can claim it [ADR
  0002; CLAUDE.md "Git here"]. The Operator's own commits resolve to their own account, and the bot
  address to none [ADR 0002 "Context"]. The old branch `features/2026-10-16` was deleted and the 13
  commits rewritten onto a new branch `features/true-up-features` (a new branch, to avoid a force
  push), with author, date and sign-off preserved [ledger "Rewrite trailers and push corrected
  Features branch"; "Delete old Features branch and verify cleanup"].

The cost of getting the identity right, as recorded: the Haiku con's wrong address, the second
Haiku con's wrong address, the rewritten trailers, the 29 local commits that later carried a stray
second sign-off (see below). On the other side, `bot-git-identity` is the one backlog group the
first review moved to "Now" at once [ledger "Review 2026-10-16", group 1]. Gap: the records do not
show whether the "stranger's account" was a real person or a coincidence of address ownership;
ADR 0002 itself says only that "a stranger's GitHub account appears to have claimed it" [CLAUDE.md].

### The backs diagnosed: five root causes (ADR 0003)

By mid-day the ledger showed that the scribe had dropped two con jobs altogether and clipped
others. The host ran a root-cause analysis, "Diagnose pipeline failures in scribe and
secretary", which found five causes [ledger "Diagnose pipeline failures in scribe and
secretary"; ADR 0003 "Context"].

1. The scribe's input clipped a con's hand-off at 3,000 characters, silently, so the Friction
   section was lost.
2. A con finishing while the scribe was busy exited within 30 to 60 seconds and was never
   retried: dropped jobs.
3. The secretary's retry loop: a host stake asked it to reword an existing item, the guard undid
   the reword, the stake stayed pending, and the secretary retried on every turn. In two of the
   four secretary runs the guard had undone, the host's own stake had asked for the reword
   [ADR 0003 "Context"].
4. The secretary's installed brief still issued `TD-nn` ids.
5. The guard logged only the old line, not what the edit tried to change, so one undone run could
   not be explained.

The decisions were ADR 0003: a back never rewords an existing record and nobody asks it to; a stake
that asks for a change becomes an `amend-<id>` backlog item that the host or the Operator carries
out by hand; the scribe keeps its small model and reads a con's full Friction, For the repository
and Decisions needed sections, writing "not reported" rather than "none" when one is missing; dropped
jobs are queued, and the lock wait for the SubagentStop back runs is 600 seconds [ADR 0003; ledger
"Record two con jobs the scribe dropped ..."]. Options rejected: letting the secretary reword on a
stake (it would break the add-only rule every other back would then ask to be excused from) and
moving the scribe to a larger model (the faults were clipping and dropped jobs, which a larger model
would not have seen either) [ADR 0003 "Options considered"]. A line of the ledger explains why the
earlier suspicion of model size was wrong: "all of the backs' failures today were pipeline bugs or
host briefing errors, not model size" [ledger "Record two con jobs the scribe dropped ..."]. The
fixes were installed as part of devhost 1.2.0 [review 2026-10-16, group 3]. The review's check was:
undone runs to equal 0 and no "not reported" from a clip at the next review [same].

### The git config that a test corrupted

A test run during the day used the real git binary in a scratch folder with `GIT_DIR` and
`GIT_WORK_TREE` set container-wide, bypassing the git wrapper that normally isolates them. It set
`core.filemode` and `core.worktree` in the shared config to values that broke the Operator's
Windows checkout. The host documented a seven-step repair and left it for the Operator to run
[ledger "Diagnose git config corruption from wrapper bypass"]. The question the entry left open
(worktrees rather than the `GIT_DIR` pattern for scratch repos; a guard against an unset
`GIT_WORK_TREE`) was not answered in the entry. On 2026-10-19 the Operator's answer to the outline
questions recorded the config as verified correct (only `core.filemode false` present) [ledger
"Outline questions answered and verified"]. Gap: the 2026-10-16 repair command, who ran it and
when, is not in the ledger; only the later verification is.

The same stack produced a second identity fault. The `prepare-commit-msg` hook signed off from
`user.name`/`user.email` instead of the committer identity, so every rebase or cherry-pick under
the bot identity added a second sign-off pairing the global bot name with the repository-local
address. 29 local commits carried it. The hook was fixed in `7048173`; the stray sign-offs were not
stripped that day because the rewrite was refused by auto mode and waited for the Operator [ledger
"Rebase stack and fix the sign-off hook (corrected)"]. The scribe's first entry for this unit had
claimed the cleanup was done, and was corrected: this is the scribe's unchecked claim again (the
corrected entry's own Friction line says so) [same entry]. On 2026-10-19 the sign-offs were
recorded as cleaned by the squash merges, not by rewriting [ledger "Outline questions answered and
verified"]. The same entry holds the decision "The Operator merges with the admin bypass while the
only other collaborator is rarely available" [ledger "Rebase stack and fix the sign-off hook
(corrected)"], a practice the Operator calls "a known weak point", not a priority now, "later
iteration" [interview q10, paraphrased; section 14].

## 5. The first night shift and review (2026-10-16)

The day described in section 4 ended with the first unattended run and the first look back at the
ledger. Both are told here, with what the day left.

### The first night shift

A **night shift** is a host session that the Operator leaves open, working an agreed list of
backlog items alone under the night rules and a cost cap, and reviewed in a morning report [LEXICON.md
"Night shift"]. The first one ran on the branch `chore/night-shift-2026-10-16`, planned at 8 items
under a $100 cap, started 2026-10-16T02:36Z at $28.79 and ended 02:56 UTC "the list was done". Result:
8 done, 0 skipped, 0 undone, cost about $9.5 [docs/night-shift/2026-10-16.md]. The Operator
reviewed it the same day: all eight items kept, four open questions to answer [same].

Five build items and three proposals: a refusal in `devhost-verify` of a non-executable hook
(devhost 1.2.1, three tests); the tester back reporting "skipped" rather than red when there is no
Docker daemon (1.2.2); redaction tests that use a placeholder name and are proven able to fail by
mutation; quieter backs (the librarian's threshold for con jobs raised from 1,500 to 8,000
characters; the secretary no longer files work begun and finished in one session; the scribe
writes `Corrects:` only for a real correction; devhost 1.2.3); and one 13-step "Adding a
Feature" checklist in CONTRIBUTING.md. The three proposals, none of them built, were a King
Arthur theme as a layer, a journalist back, and personalization [docs/night-shift/2026-10-16.md,
items 1 to 8].

The night shift had a discarded attempt. A Haiku con redid the redaction-test job by swapping the
name string, which left the three checks unable to fail anywhere, committed under the Operator's
address despite the identity-checking helper, and reported "Friction: None". It was never merged
(commit `1d090e4`) and was redone on Sonnet as `5c79546` with mutation proof [night-shift report
item 3; ledger "Correct the Haiku con's placeholder entry; the night shift's host record"]. The
host also changed a con's work: a con fitted a threshold at 8,400 characters, 26 under the only
productive data point, and the host lowered it to 8,000 for a margin, "because a skipped con stretch
is never offered again" [night-shift report item 4]. A cost-basis question sits inside the report:
it started "at $28.79", while the first review gives $27.74 for the whole window [night-shift
report; ledger "Review 2026-10-16"]. Guess: the two figures are cost to date at different
moments; this was not checked against a cost report. The cost report for most of the day is not
available (see sections 9 and 12).

### The first review

The first ledger review looked at 21 entries, from "Survey repo and backlog" to "Diagnose pipeline
failures in scribe and secretary", reading five corrections in place of what they correct. A
**ledger review** reads the cost report first and turns each group of friction into one action
[ledger-review skill; CLAUDE.devhost.md "The ledger"]. This was the first review, so there was no
earlier promise to check [ledger "Review 2026-10-16", Entries reviewed]. Costs for the window:
$27.74 at list price, all on 2026-10-16: host (Opus) $16.40 in one session (59%); cons $6.19 in 14
runs; backs $5.16 in 97 runs, 5 undone by a guard; the librarian: 14 of 19 runs changed nothing,
$0.57 per change; the scribe $0.09 per change [same, Costs]. Costs here are list-price estimates,
not charges [records brief section 2]. Eight groups came out, each with an action:

| Group | Entries | Action |
|---|---|---|
| Agent git identity | 5 | `bot-git-identity` moved to Now |
| Guards that did not run | 4 | fixed with tests; new `hook-mode-guard` |
| Backs pipeline | 4 | fixed and installed (devhost 1.2.0) |
| Cons over-reporting success | 3 | con briefs ask for worked-around friction; host checks every hand-off; first `ai-tenets` entry |
| Scattered new-Feature knowledge | 3 | `new-feature-checklist` |
| Tester red without Docker | not given | `tester-skip-without-docker` |
| Back noise | not given | `back-briefs-tidy` |
| Permissions | not given | no action |

[ledger "Review 2026-10-16", Groups and actions]. Under "What this review lacked" it says: "a
single day and session, so no trend; costs are a baseline" [same].

### What the day left, with what it cost

By the end of the day the repository had a bot identity and an unclaimable co-author address, a
verify step that looked at the repository, backs that no longer clipped or retried, hook and sign-off
fixes, two pull requests waiting on a Features PR that merged at 03:15Z (PR #11, opened 01:38Z; PRs
#12 and #13 opened 11:15Z) [gh pr list], and a record of its own faults. It also had a set of
fixes taking effect "only after the devhost is rebuilt from `devhost/true-up`" [ledger "Record two
con jobs the scribe dropped ..."] and the pull requests #12 and #13 that would not merge until
2026-10-19 (15:20Z and 16:09Z) [gh pr list]. What the day cost is not known beyond the first
review's window: Gap: no cost report covers 2026-10-16 after the first review's window, and none
exists for 2026-10-17 or 2026-10-18 (section 9). The Operator decided that this paper gives the
two partial figures it has for 2026-10-16 as a marked guess, and leaves out the session-to-date
figure that the second night-shift report starts from [interview q28, paraphrased]. Guess: the cost
of 2026-10-16 is of the order of the $27.74 of the first review's window plus the about $9.5 of
the first night shift [ledger "Review 2026-10-16", Costs; docs/night-shift/2026-10-16.md]; the
two are not summed here because the windows may overlap, and nothing measures the rest of the day.
The day's second half, in which the devhost grew
inward (an ontology and its guard, the Arthurian theme, the site generator, principles drafted and
the iteration-package proposal), is told in sections 6 and 7.

## 6. Features first (2026-10-16 to 2026-10-20)

### The reason, in the Operator's words

Section 2 gave the reason for keeping the two priorities apart. This section tells what the
decision looked like in the records and how far it carried. The Operator's account is that the
repository is public; they did not want to commit and merge and manage the devhost while also
trying to publish the Features; and publishing the Features first would give published Features
that the office and software project 1 could then reference from their own dev containers. They
were explicit that this was not an attempt to hide the devhost, only a refusal to put it out while
it was still being worked on, and they read the outcome as the sign of working through the two
priorities the project carried [interview q5/6, paraphrased]. The question put to the Operator
also asked whether the inward turn of the same day was planned or drift; the dictated answer is
mostly the reason above, and the inward turn is taken up with the later answer of round 4 in
section 7 [interview q5/6; q26]. Gap: the interview does not say what, on 2026-10-16, made the Operator decide to split pull
request #10 that day and not later. What the records show is what follows.

### The starting position

The first ledger entry of the project, "Survey repo and backlog", found the checkout on the branch
`repo-true-up` with PR #10 open, in sync with its origin [ledger 2026-10-16 "Survey repo and
backlog"]. PR #10 had been opened on 2026-10-15T18:59Z and held everything of the previous day:
five Features new to the collection (git, gh, az, common, devhost), and, by its title, changes to
how Features own their state [gh pr list; ledger 2026-10-16 "Decide Features-first order with
path-based split"]. Guess: the pull request also held the devhost's records and configuration,
since the split below was made by path out of one branch and sorted the paths into two pull
requests; the ledger does not list #10's files. A
backlog item `release-collection` ("Release the collection"), carried over from the first backlog
as `TD-03`, already said why the Features mattered to the consumers: until the release workflow
ran, git, gh, az, common and devhost would not exist on the registry, so consumers could not pull
them and `installsAfter` could not name them. The item is dated 2026-10-15 [TODO.md
`release-collection`]. So the wish to get the Features out predates the ledger by a day; what the
ledger records is the decision on how.

### The decision: a path-based split

The decision entry, written by the scribe for a host stretch, records the Operator asking whether
the Features could be committed first, with the true-up following after the release and
referencing released versions instead of local paths. The host validated a path-based split as
feasible. The Features pull request would hold `src/`, `test/`, `.github/workflows/`, the Feature
rows of the README, the conventions of CONTRIBUTING, the test tasks of the Taskfile and
`.gitignore`. The true-up pull request would hold `.devcontainer/`, `.devhost/`, `.claude/`,
`docs/`, `bootstrap/`, the git hooks, `CLAUDE.md`, `PROCESS.md`, `LEXICON.md`, `TODO.md` and the
ledger. The merge order was reversed on purpose: Features first, then the release workflow, then
the true-up that would consume released versions. The entry's check was that a rebase onto a
released `main` had no conflicts and that DCO checks were clean at each step [ledger "Decide
Features-first order with path-based split"]. Note that the Feature `devhost` (the tooling the
way of working installs) went with the Features and the devhost's own records and configuration
went with the true-up: "the devhost" that the Operator did not want to commit was the working
state of the way of working, not the installable Feature. Gap: the records do not say whether
that distinction was drawn at the time or is only how the path list fell.

### Building the Features branch

A Sonnet con built the branch by path-filtering the history of the backlog branch with
`git filter-branch`, keeping original authors, dates and sign-offs. The result was the branch
`features/2026-10-16` with 13 commits (12 original commits filtered and one new commit by the bot
identity), a diff of 168 files, +8,382 and -193, and three commits pruned as empty (a hook mode
change, a commit touching only `TODO.md`, a lock file). Lint, unit tests and generated docs passed
on that tree alone, which was the proof that the split had not left the Features depending on
the devhost [ledger "Build Features PR branch by path-filtering history"; the con's measure was
$0.80 at list price]. The con's own friction was "none". Two of its remarks are recorded as
learning: bot commits need explicit identity flags, and partial edits to the README, the Taskfile
and `.gitignore` have to be handled outside the filter so that they do not leave dangling
references [same entry].

Then the branch was thrown away and rebuilt. When the host verified and pushed it, the trailers
still named the old address; ADR 0002, decided the same day, banned it (see section 4). The 13
commits were rewritten onto a new branch `features/true-up-features`, author, date and sign-off
preserved and the code byte-identical, and the old branch was deleted from the origin, "a new
branch avoids force-push complications and GitHub PR history issues" [ledger "Rewrite trailers and
push corrected Features branch"; "Delete old Features branch and verify cleanup"]. Opening the pull
request from the command line failed once because the token lacked pull-request write permission;
the Operator widened the token and the host then filled in the description [ledger "Verify and
push Features branch to origin"; "Fill PR #11 body after gh token fix"]. Friction, as recorded:
the host's first attempt to create the pull request failed, and the Operator had to change the
access token before the description could be written.

### The result

PR #11, "Features/true up features", was opened 2026-10-16T01:38Z and merged 2026-10-16T03:15Z
as `d16a536` [gh pr list; git log]. PR #10 had been closed unmerged at 01:51Z, 13 minutes after
#11 was opened [gh pr list]. After #11 the collection held 16 Features in `src/`: the ten of the
first life, `kube-state` (added on 2026-10-16 by a con, TD-07), and the five from PR #10 [git
ls-tree d16a536 src/; ledger "Add kube Feature for KUBECONFIG state (TD-07)"]. The remainder of
the day's Feature work and the devhost's records were stacked as two further pull requests, both
opened 2026-10-16T11:15Z: #12, "devhost 1.2.3 and git 1.1.0: guards that run, quieter backs, one
commit identity" (seven code commits and the sign-off hook fix), and #13, "The devhost records of
2026-10-16 (stacked on the Features PR)" [gh pr list; ledger "Open pull requests for features and
records"].

### What the order did and did not deliver

Features first held for the merge: #11 merged at 03:15Z on 2026-10-16 and the devhost's
records did not reach `main` until #12 and #13 merged on 2026-10-19 (15:20Z and 16:09Z)
[gh pr list]. Gap: the records give no reason why two pull requests opened on the 16th waited
three days; the only entries about them are of 2026-10-19 ("PR #13 retargeted to main, mergeable
after prior failure": a retarget command had failed and was retried; the decision needed was to
merge it "using squash merge from phone per PR #12 pattern"), and 2026-10-18 has no record at all
[ledger 2026-10-19; section 9].

What did not hold is the middle step of the plan. The decision called for the release workflow
to run after the Features merged and before the true-up. The release is a manual workflow on
`main` [CLAUDE.md "Git here"], and it was not run until 2026-10-20, after PRs #14 to #18 merged:
it published go-task 1.1.0, claude-code 1.3.0, git 1.1.0, gh 1.0.0 and devhost 1.4.0, and a
validation entry the same day found all 16 Features on the registry, anonymously pullable, each
tagged with its `src/` version [ledger 2026-10-20 "Release workflow completed, Features published
to GHCR"; "Feature collection release validated on GHCR"; TODO.md `release-collection`, done
2026-10-20]. The five that "blocked the release" were git, gh, az, common and devhost, the five of
PR #10, because until then they had never been published [same validation entry]. Gap: the two
entries name different five (the run entry lists go-task and claude-code where the validation
names az and common); the validation, which checked all 16 on the registry, is the one relied on. So the
Operator's stated gain, published Features that the other projects could reference at once, was
available from 2026-10-20 and not from 2026-10-16: four days after the merge, on the day the
seed was being exported. The devhost of this repository itself still runs the unreleased tree by
local path, and a backlog item, `devhost-released-versions`, to pin it to released versions is
open [TODO.md]. Gap: no record in this repository shows whether the office or software project 1
referenced a published Feature, so the gain the Operator named is recorded as available, not as
used.

### Features first as a rule for a session

The second half of the reason is a rule for sessions, not a pull-request order. On 2026-10-16 an
engineer's explanation of the project's foundational purpose was written into the repository:
`docs/iterations.md` (three iterations building toward the Agentic Delivery OS), a line in
`CLAUDE.md`, and a memory file for the host. The entry's lesson: "Codebase priorities should
reflect consumers and product (Features) first, then platform (devhost)" [ledger 2026-10-16
"Agentic Delivery OS foundation purpose documented"]. `docs/iterations.md` carries the rule "The
Features come first: a session that only grows the devhost is drifting" [docs/iterations.md]. This
narrows the gap that section 2 left: the file was written on 2026-10-16. The entry does not quote
the rule's wording, so Gap: the exact day the sentence itself was written is not recorded. The backlog was reordered twice to match, on 2026-10-16 ("Backlog reorganized for
product-first focus", where the secretary had merged two concerns into one item and the host
split them) and on 2026-10-17 (section 8). Whether the turn that came between these two moments
was drift or the plan is section 7's question.

## 7. The inward turn (2026-10-16 and 2026-10-17)

### What it was

After the Features were out of the way, the devhost's own records and tooling grew. The ledger's
entries of 2026-10-16 from "Open pull requests for features and records" onward, and those of
2026-10-17, record the following, in the order the scribe wrote them, which is append
order and not a clock [ledger 2026-10-16 "Open pull requests ..." onward; Gap: the ledger's
dates and the night-shift reports' timestamps do not line up exactly around midnight, so the order
inside this stretch is the ledger's order, not a proven timeline].

1. **The ontology and its guard.** A con built `docs/model/ontology.toml` (about 55 ids, 14
   predicates, about 55 relations), the theme labels in `docs/model/themes/arthurian.toml`, C4
   Context and Container views in Mermaid, and a guard in `devhost-verify` that checks the lexicon,
   the themes and the views against the ontology, with an add-only rule for the librarian. 67
   devhost tests passed and the checks were mutation-tested. The host integrated it, and the guard
   "caught two new lexicon terms lacking ids" on first use [ledger "Built canonical ontology model
   and guard"; "Ontology guard integrated and verified on records branch"]. ADR 0005 records the
   decision: one plain base id per term, themes as label tables keyed by those ids, a guard, a
   start small that "grows from friction, not from a design made up front" [ADR 0005; the
   Operator's phrase in its change log: "kick it into a guard, let friction form it"].
2. **The Arthurian theme and the journal piece.** Three proposals had been written as items of the
   first night shift (a King Arthur theme, a journalist back, a personalization mechanism)
   [docs/night-shift/2026-10-16.md, items 6 to 8; ledger "Write King Arthur theme proposal" and its
   two siblings]. The theme proposal mapped ten Arthurian names to the roles and records and
   costed two ways of adopting them. ADR 0004 chose a layer. A hand-run trial, a con acting as the
   journalist (the "bard"), then wrote `docs/journal/2026-10-16.md`, 951 words in the Arthurian
   voice, in five chapters [ledger "First hand-run trial of the Bard back"].
3. **The life theme and the iteration package.** The host drafted `docs/proposals/iteration-package.md`
   (papers carry over, the foundation is merged and not nested, adoption by conversation), marked
   it accepted, and ADR 0007 gave the series ten shared life labels (generation, tree, ground,
   seed, fruit and the rest). ADR 0008 fixed the honest-account rules that bind this paper [ADR
   0007; ADR 0008; ledger "Iteration package proposal drafted and committed" and "... acceptance
   marked"]. An alignment note, story, purpose and outcome only with no action for the other
   projects, was drafted for them [ledger "Alignment prompt drafted for other projects"].
4. **The site.** A con built `devhost-site`, a script that turns the repository's docs and
   records into one self-contained HTML page (devhost 1.3.0, 13 new tests, 66 in all), and a skill
   `publish-site` published it as a private Claude artifact. ADR 0006 records that the script is
   deterministic and that hosting is a swappable skill [ledger "Site generator and dashboard
   homepage built"; ADR 0006]. The page was republished many times (the ledger names versions 4, 8,
   9 and 10 [ledger 2026-10-17 entries]).
5. **Principles.** Two cons drafted `docs/proposals/agent-principles.md` (13 principles,
   AP-1 to AP-13, each with evidence from the ledger, ADRs and the night-shift report) and
   `docs/proposals/feature-principles.md` (10 principles, FP-1 to FP-10, in RFC 2119 wording)
   [ledger "Agent principles proposal drafted"; "Feature principles proposal drafted"]. The
   outline had said "five, then fourteen"; the records show the other order: 13 drafted on the 16th,
   14 in the file `docs/principles/agents.md` of 2026-10-20, trimmed to five generic ones the same
   day (ADR 0013). That trimming belongs to section 10 [ledger 2026-10-20 "Eight architectural
   decisions written ..."; "Agent and Feature principles restructured ..."].
6. **Pictures.** On 2026-10-17 four Mermaid diagrams were added to `PROCESS.md` and a "picture
   principle" was written into its rules of thumb: balance visuals and paragraphs, diagrams for
   flow, structure, state or trend, prose for reasoning [ledger "PROCESS.md balanced with Mermaid
   diagrams"; PROCESS.md]. Five Sonnet cons added 2 or 3 diagrams each to the five proposals
   (personalization, journalist back, iteration package, King Arthur theme, feature principles) at
   $0.20 to $0.23 per con; none was rendered, and two said so in their reports (iteration package
   and King Arthur theme: "unchecked in rendering") [ledger 2026-10-17 "... balanced with Mermaid diagrams"]. These cons ran on the night-shift
   branch but are not among the three items of the night-shift report (section 8) [docs/night-shift/2026-10-17.md].
7. **A storybook.** At the Operator's request, a private HTML storybook of the Arthurian tale was
   made as a page outside the repository, after a mid-conversation clarification that it was not
   meant as repository documentation [ledger 2026-10-17 "King Arthur storybook created for personal
   use"]. It is in no commit of this repository.

### What the Operator says it was

The Operator was asked whether the turn was planned or drift. They said yes, it was planned, because
those items were the project refining: the King Arthur theme showed the need to begin separating out
the concepts, because a ledger written in old English would have been "useless and painful"
[interview q26, paraphrased and quoted in part].
The result of that thought is visible in ADR 0004: the theme is a layer and not a rename. The ADR's
own reasons are narrower and are the ADR's, not the Operator's: a rename would touch about 130
files, the append-only ledger would keep the old words and every query for them would miss the
past, and the machine-read parts must never carry the voice [ADR 0004, "Context", "Option 2"].
The two fit together. The Operator's point is the one that a ledger is a record people and
guards read, so a theme that touches it spoils its use; the ADR's point is that the layer keeps
the record honest. The same separation is written down in ADR 0005: the lexicon says what a
word means, the ontology says what exists and how it relates, a theme names things in a voice
[ADR 0005, "Context"]. The Operator's account connects the two (the theme showed the need to
separate the concepts); ADR 0005 does not say so itself.

The records are less simple about whether the move was only a plan. Two entries of the day use
the word the Operator rejects. After a read of the Features' documentation, the scribe recorded,
under Friction for the host, "Feature documentation deprioritized relative to devhost tooling,
causing drift from repo's stated purpose", and the plan it recorded was to restructure the backlog
and the C4 views to show the Features and the consumers first [ledger 2026-10-16 "Audited
Features documentation and planned remediation"]. And the rule in `docs/iterations.md` calls a
session that only grows the devhost "drifting" [docs/iterations.md]. Both are the records' own
words, written on the same day as the turn; neither is a quotation from the Operator. This paper
keeps both: the Operator's account of intent (planned, as refining), and the host's observation
that Feature documentation was falling behind. It does not choose between them [interview q26;
the journalist brief: "Intent is not guessed"].

### What each item became

The Operator's later classification of these items is the second half of their account. Asked
what the next seed should keep, the Operator said: the picture principle (diagrams in docs) is
a personalization matter, so no; the Arthurian theme with its journal piece, no; the site is
another personalization matter. Both the pictures and the site are about how a repository exposes
its outputs, and it matters more that this concept is thought through than that the form is
copied; whether an implementer mandates C4 diagrams for architectural docs is up to them, a
cross-cutting concern. The ontology goes with the lexicon, always exported together, because they
complement each other: the lexicon is shared nomenclature and the ontology serves a different
purpose [interview q11, paraphrased]. Later, ADRs 0004 (the Arthurian theme) and 0007 (the life
theme) left the foundation, and ADR 0006 (the site) stayed as an example of thinking through how
a project shows its outputs [interview q19; round 3 summary].

The records give each item a different present state, and they do not all match the account.

- **The ontology** and the lexicon, its C4 views and the Arthurian label table are on `main` (PR
  #13) [git log -- docs/model]. The ledger's own words at the time were that the guard "remains on
  devhost/ontology-guard branch; requires separate PR" [ledger 2026-10-17 "Architecture models and
  diagrams integrated to dashboard"]. The guard code (`8dd5717`, devhost 1.2.4 on that branch)
  is not an ancestor of `main`: `git merge-base --is-ancestor 8dd5717 main` fails, no file under
  `src/devhost/` other than the planting interview mentions an ontology, and the version 1.2.4
  that is on `main` is a different change (the report counting only real corrections, PR #15).
  The backlog item `publish-ontology-guard-pr` is still open. Yet another backlog item of
  2026-10-20 records the remote `devhost/ontology-guard` as one of three "merged branches" that were
  deleted [TODO.md `publish-ontology-guard-pr`, `branch-triage`; git log]. Gap: the guard is
  described in the records as built and mutation-tested, and in the repository as not merged; the
  remote branch is gone and the local branch still holds 37 commits not on `main`.
- **The theme** is a ten-name section of `LEXICON.md` and a label file. No committed output speaks
  in the voice; the one piece that did, the journal, is on `main` (PR #13) with a README saying a
  plain piece will replace it when the back is built [docs/journal/README.md]. Since ADRs 0009 and
  0014 no journalist back will be built, so the piece stands as the single trial. Gap: whether the
  journal piece stays in the repository is not decided in the records.
- **The site** reached `main` only on 2026-10-20, rebuilt from the old branch as PR #21 (devhost
  1.5.0; 92 tests; the generator builds 116 docs) [ledger 2026-10-20 "devhost-site rebuilt as PR
  #21 and old branch deleted"]. Its journey from the 16th had defects found by the Operator
  and not by the tests: columns that wrapped a letter to a line, a description cut at "e.g.", a false
  "uncommitted changes" badge. The corrected entry's friction states that "the defects shipped
  because the page was never opened in a browser before the first publish; the con said so and it
  was published anyway" [ledger "Dashboard Features display fixed and republished (corrected)"].
  The fix moved the cut from the page's JavaScript to the generator so a test can fail on it
  (commit `734c237` on the site branch, on the night shift of the 17th) [docs/night-shift/2026-10-17.md
  item 3]. The page itself was still unopened in a browser after that, and the backlog item
  `publish-site-browser-check` stayed open [same item].
- **The principles** were accepted on 2026-10-19 and 2026-10-20 as the five generic agent
  principles and ten non-functional requirements (ADRs 0011 and 0013) [docs/proposals/README.md];
  the Operator keeps the five (section 13).
- **The iteration package** became the seed of this paper's own process (ADRs 0008, 0009, 0014;
  section 10).

### Another unchecked claim by the scribe

One more entry of the turn belongs with the false "done" of section 4. The scribe
recorded the iteration-package proposal as "drafted and committed" when it had only been drafted;
the file was missing from the docs site, and the site publishes only tracked files, which is how
the Operator asked why it was missing. The correcting entry names the cause: "The scribe recorded
'committed' from the plan, not from git" [ledger "Iteration package proposal drafted (corrected)"].
The review of 2026-10-19 counts three entries that said "committed" from the plan and pages
published unopened, and files them as `scribe-commit-verification` [ledger "Review 2026-10-19",
group 5]. This is the scribe's unchecked claim of section 4 recurring, one day later, in
a new form.

## 8. The second night shift and the documentation standard (2026-10-17)

### The plan and the result

The second night shift ran on the branch `chore/night-shift-2026-10-17`: a plan of 3 items under a
$10 cap, a stop time of 07:00, started 2026-10-17T00:39:31Z; the result was 3 done, 0 skipped, 0
undone, cost "about $4.6 of $10", and "ended 00:50 local, the list was done" [docs/night-shift/2026-10-17.md].
The report's header records the start as a session-to-date figure, which this paper leaves
out on the Operator's decision [interview q28]; the $3.30 given at item 1's commit line is the
report's own "cost so far" at that point [same]. Gap: the report gives its start time with a Z
and its end time as "local" without naming the zone, so 11 minutes between the two cannot be
confirmed as a duration. The Operator reviewed the report on 2026-10-19 and kept all three
items [same, header]. These costs come from the report, not from a cost report: no cost report
exists for the day (section 9).

### Item 1: the four thinnest Features' documentation

The Features' documentation was audited on 2026-10-16 by a read-only Sonnet con: it proposed a
standard of 10 items for a Feature's `NOTES.md`, scored all 16 Features against it (5 close, 7 plain
installers that need 4 sections, 4 thin), found 7 mismatches between what the documents said and
what the code did, and found that 9 of 16 had no documentation of their Taskfile tasks [ledger
2026-10-16 "Feature documentation audit and standards proposal"]. The mismatches were treated as
bugs, not gaps; for example, the README and kube-state's notes said that kustomize and kubeconform
read `KUBECONFIG`, which they do not [same; ledger 2026-10-17 "kubeconform NOTES.md brought to
standard"]. The four thinnest (kubeconform, kustomize, devcontainer-cli, openbao, at 16 to 24 lines
each) were rewritten by one Sonnet con per Feature, one at a time, each bumping a patch version
and checking `task docs` and `task lint` [docs/night-shift/2026-10-17.md item 1; ledger 2026-10-17
entries]. The commits: kubeconform 1.0.1 (`48b1a2e`), kustomize 1.0.1 (`1e0d073`),
devcontainer-cli 1.1.2 (`185c8d6`), openbao 1.0.1 (`faca4e6`); each con cost $0.20 to $0.25
[same].

What the documentation now says is worth recording because it is honest in the way this paper
tries to be. devcontainer-cli's notes say plainly that the CLI itself is installed from npm with
no checksum of the repository's own and that only its private Node.js is checked against
`SHASUMS256.txt`. openbao's say plainly that a rebuild logs the user out, and give the `BAO_TOKEN`
route; a bind-mount route a con drafted was cut to a stated gap, because nobody had tested it.
kubeconform and kustomize point at each other and say they need nothing from kube-state [night-shift
item 1, "What changed"]. The check: `task docs`, `task lint` and `devhost-verify` green; the host
spot-checked claims against `install.sh`, the JSON and the Taskfiles; "Not run in a container"
[same]. Gap: the briefs to the cons named items "1 to 8" or "1 to 9" of the standard while the
audit counted 10 and the report speaks of "10 items"; the records do not say which items were left
out of the briefs or why [ledger 2026-10-17 entries; night-shift item 1].

### Item 2: the backlog reordered

`TODO.md`'s Now and Next sections each begin with a group "Features (the product)", then
"Devhost and the way of working". Four items were ticked with their commits as evidence, and one
was added for what was left (`fix-installer-docs-rest`: velero, dsc, argocd, coder-cli and the
overclaims in kube-state and the README). No item was reworded; a sorted diff of before and after
showed only the ticks, the new item and the group headings [night-shift item 2; ledger 2026-10-17
"TODO.md reordered with Features-first structure"]. This is the second half of the backlog
reordering of section 6. The host session that did it cost $3.75 for its stretch; the same $3.75 is
repeated on the next entry (the dashboard summary refactor), because the scribe copied one stretch's
cost onto both [ledger 2026-10-17 entries; ledger "Review 2026-10-19", group 4], a fault told in
section 11.

### Item 3: the dashboard fixes committed with a test

The three display fixes from section 7 were committed on the site branch with a test that every
Feature summary is a whole sentence, shown able to fail against the old cut; the suite then had 68
devhost tests, green [night-shift item 3]. Nothing was published. The page was still not opened in
a browser, "so the backlog item stays open for that" [same].

### What the report asked, and what came of it

The report put two questions to the Operator and made three proposals. The questions: whether
openbao keeps its state as a documented gap or gets a volume and setup hook like gh and az
(recommended: the volume, after the release, since FP-1 would fail it), and whether a docs-only
change should still bump a patch version (recommended: keep the rule, since the registry's README
changes too) [night-shift "Questions for the Operator"]. The Operator decided the first on 2026-10-19: yes, a volume and
setup hook, built after the release; it is the open item `openbao-state-build` [TODO.md
`openbao-state-volume`, `openbao-state-build`]. Gap: no record answers the patch-bump question;
the four bumps stand. The three proposals were the tester running `task lint` or one named
Feature's test and not the unspecific `task test`, the ontology guard's pull request after #12
and #13, and a render check for the dashboard [night-shift "Proposals"]. The first became two
backlog items, `tester-run-lint` and `tester-skipped-notice`, closed as superseded in the review of
2026-10-19; the second is still open (section 7); the third is `publish-site-browser-check`,
still open [ledger "Review 2026-10-19", group 9; TODO.md].

### The follow-on, and the standard becoming a rule

The same week the standard was applied to the rest. On 2026-10-19 a Sonnet con brought velero 1.0.2,
dsc 1.1.1, argocd 1.1.1 and coder-cli 1.1.1 to it, using kubeconform's as the model, in seven
commits that also fixed the false `KUBECONFIG` claim in kube-state (1.0.1) and the false "all
downloads verified" claim of the README and devcontainer-cli (1.1.3). The con retried its shell
loops after glob patterns failed, reported a bootstrap copy it could not diff against, and made
one change beyond its brief (a line of kube-state's JSON description with a version bump), which it
put to the host as a decision [ledger 2026-10-19 "Installer documentation standardized for four
Features"; cost $0.69]. All of this merged as #14 on 2026-10-20 [gh pr list].
Eight Features then met the standard, and on 2026-10-20 it became non-functional requirement NFR-8
("`NOTES.md` MUST cover the audit's 10 items, or say in one line that an item does not apply"),
made binding by ADR 0011 [docs/principles/non-functional-requirements.md; ADR 0011]. Its "Today"
line says: "none meets all 10 yet. Eight Features' NOTES were brought to the standard on 2026-10-17
and 2026-10-19", which is a statement about the same eight, not about eight more [same]. Gap: the
section of CONTRIBUTING on `NOTES.md` still describes four short topics and has not been brought
to the standard [CONTRIBUTING.md "NOTES.md"].

### Where this leaves the Features

By the end of the night shift of the 17th the Features had a documentation standard, four rewritten
notes, a reordered backlog and a binding rule coming; by the 19th eight had been rewritten; by
the 20th all 16 were published (section 6). Whether this was the Features-first rule being kept
is a reading this paper does not make for the Operator: the documentation work was the Features'
side, in the same days, of the inward turn of section 7.

## 9. What the records cannot show

This section is a map of where the evidence stops. It is placed here because the missing records
mostly lie in the days it follows, 2026-10-16 to 2026-10-19, and because later sections lean on it.

### 2026-10-18 has no record

The ledger has no entry for 2026-10-18 (55 entries for the 16th, 17 for the 17th, none for the
18th, 11 for the 19th) [ledger 2026-10.md, counted by `grep '^### '`], and no commit on any
branch of this repository is dated between 2026-10-17T12:00Z and 2026-10-19T12:00Z [git log
--all]. Gap: nothing in the records says what, if anything, was done on the 18th, or in the
other projects, and this paper does not fill it.

### Cost from 2026-10-16 to 2026-10-18 was not available when this was written

The cost of those days is not known here. The Operator's reason, in their own framing, is plain
and the paper says it plainly: because of technical issues, the data are not available and the
paper may be amended. The explanation they gave is that the work was started on a personal
machine and carried to a work machine, the cost files were not published to git, and so when
the work machine pulled, they were not there; the data could in principle be fetched from the
first machine, and the Operator does not count its absence as blocking the seed [interview q7,
paraphrased; garbled in dictation and not quoted]. This is the sentence the paper keeps: due to
technical issues the data was not available at the time of writing, and the paper may be
amended.

The records add detail and one disagreement. The ledger entry of 2026-10-20, "Cost history from
other machine dropped", records that the other machine's history is "lost and not recoverable",
that the decision was to "Discontinue pursuit; continue without other machine's cost data", and
that the pursuit was dropped "due to data loss" [ledger 2026-10-20 "Cost history from other
machine dropped"]. The Operator's later wording leaves the door open ("may amend later"); the entry
closes it. Gap: whether the data can still be recovered from the first machine is not established
by either record. The wording here follows the Operator's and flags the entry. The Measures lines
of the ledger entries survive and carry a list-price figure for each stretch, but the review of
2026-10-19 found that a stretch's cost was copied onto several entries, so sums overcount
(`scribe-cost-deduplication`), and its only derived figures are "about $3.60 per stretch" for the
host on the 16th and "$2.50" on the 17th, and about $0.46 per Sonnet con run on the 16th and $0.22
on the 17th [ledger "Review 2026-10-19", Costs and group 4]. This paper does not sum the Measures
lines. What survives, in total: $27.74 for an early window on the 16th (the first review), about
$9.5 for the first night shift, about $4.6 for the second, and the per-entry figures [section 5;
section 8]. The cost file `costs-2026-10-operator.md` that the first review cited now begins on
2026-10-19T14:23 and totals $64.46 for the 19th and 20th (inter sessions $50.20, cons $4.20 in 8
runs, backs $10.06 in 217 runs) [docs/ledger/costs-2026-10-operator.md]; a second, smaller
file for 2026-10-16T00:28 to 00:30 holds $0.44 [docs/ledger/costs-2026-10-unknown.md]. So even the
$27.74 of the first review can no longer be rechecked against a report. Gap: no cost report for
2026-10-16 after the first review's window, for 2026-10-17 or for 2026-10-18.

### Transcripts and back run records before 2026-10-19 14:21 are gone

The container's state volume (the Claude Code state: transcripts, session files and the backs'
run records) was recreated on 2026-10-19. The ledger entry "Session naming with remote control
clarified" found that the "session state folder created today at 14:21; contains only today's
sessions" and that an original session name was "likely on another machine or was lost when
storage was recreated" [ledger 2026-10-19 "Session naming with remote control clarified"]. The
review of the same day says the same of the cost report: it "covers only 2026-10-19, because the
Claude Code state volume was recreated that day and the earlier transcripts are not on this
machine" [ledger "Review 2026-10-19", Costs]. The Operator confirmed that the earlier session
structure is not stored anywhere else [interview q8, paraphrased]. What that removes: any check
of the cons' and backs' work of the 16th and 17th against their transcripts, the back run records
that the cost report and the guards' undo counts are built from (the review of the 16th counted 97
runs, and the con of the journal found 117 in `runs.jsonl` that same day [ledger "Review
2026-10-16"; "Write journalist back proposal"]), and the original session's name. What stays:
the ledger, the reviews, the night-shift reports, the ADRs, git. The Operator's own words and
the first outline answers of 2026-10-19 were also lost, with a scratchpad (section 3).
Everything this paper says about those days therefore rests on the committed records only, and a
fact those records contain only as the scribe's summary (a Haiku back's account of a host's
stretch) is as reliable as the scribe is, which sections 4 and 7 show is not always.

### Other gaps seen so far

- PR #17 has no commit of its own on `main`; it is inside the squash of #16 [git log].
- `ff21f35`, the port, is on no branch (section 3).
- The pull requests #12 and #13 waited from the 16th to the 19th for a reason the records do not
  give (section 6).
- The ledger gives the day of each entry; around midnight UTC it does not agree with the
  night-shift reports on where the 17th begins (section 7).

## 10. Naming the iteration and building the export (2026-10-19 to 2026-10-20)

Sections 4 to 8 told 2026-10-16 and 2026-10-17. After the gap of section 9, the work came back on
2026-10-19 with a different object: not the Features or the devhost, but the thing this iteration
hands on. This section tells how that was built, in the order the records give it. Section 11
tells what broke in the same two days; the two were one run of work, and they are split only so
that neither story is lost in the other.

### The 19th: a review, a name, an outline

The day began with the second ledger review, which read 53 entries (34 from 2026-10-16, 17 from
2026-10-17, 2 from 2026-10-19) and turned them into ten groups of action [ledger "Review
2026-10-19"]; what it found belongs to section 11. The same day the two long-waiting pull requests
#12 and #13 merged (15:20Z and 16:09Z) and two new ones, #14 (the Features' documentation standard
and the records of 2026-10-17 to 2026-10-19) and #15 (devhost 1.2.4, the report that counts only real
corrections and the briefing that warns about a stale install), were opened at 16:13Z [gh pr list;
ledger "PR A (docs and records) and PR B (devhost 1.2.4) rebased and prepared", "PRs #14 and #15
opened and formatted to repository template"].

The iteration and the paper were named: "From tree to seed", "mirroring prior 'From seed to tree'
and completing generational lineage" [ledger 2026-10-19 "Iteration and paper titled 'From tree to
seed'"; its stretch cost $3.51 in the entry's Measures, a list-price estimate]. The entry gives no
alternatives considered. Gap: the records do not say which other names, if any, were weighed.

A Sonnet con then drafted an outline of this paper: about 1,700 words, ten chronological sections, a
Numbers part, a Lineage part and five questions for the Operator; it cost $0.82 in the entry's
Measures [ledger 2026-10-19 "Paper 3 outline drafted: 'From tree to seed'"]. The con's friction is
useful here because it names gaps that this paper inherited: commit `ff21f35` is on no branch;
the cost reports for 2026-10-16 and 2026-10-17 were missing; the two night-shift reports start
from different cost bases; and the ledger "does not record cleanup of 29 stray sign-offs" [same,
Friction and For the repository]. The Operator answered the five questions the same day; the ledger
keeps only a summary: the port "was deliberate to include tools"; the port is the paper's story, with
the foundation "moving 'liquid to solid' but unfinished"; cost history on the other machine is a gap;
the inward turns of 2026-10-16 "were planned"; sign-offs and git config verified [ledger
2026-10-19 "Outline questions answered and verified"]. The outline file was a scratchpad file and is
lost, and so are the Operator's answers in their own words (section 9). The closing interview of
2026-10-20 (`docs/iterations/interview-3.md`) has the same topics again in its first round (the days
before the ledger, the port, the inward turn, the cost history), this time kept word for word
[interview, header and round 1].

A decision that the paper must keep in view was taken in the same days and is not a build step:
ADR 0010, accepted on 2026-10-19, says that a paper carrying names is committed unchanged under an
exception the Operator approves, file by file, through `.devhost/name-exceptions.txt`; paper 1
needed it because it names its author's job and a client [ADR 0010, Context and Decision]. This
paper does not need the exception: it says "the Operator", "the office" and "software project 1"
and nothing else, as the Operator decided [interview q15, q20].

### The package tools (2026-10-19)

The host built the two tools that assemble a seed: `devhost-package`, which gathers the papers,
writes a sha256 index and refuses when files are inconsistent (13 tests), and a journalist skill of
54 lines that carried ADR 0008's honest-account rules. Two commits on the branch
`devhost/iteration-package`; the lint suite (66 tests) and the guards were green; nothing was
pushed. The friction the entry records is a version clash: the package tools were numbered devhost
1.3.0 while #15 targeted 1.2.4 [ledger 2026-10-19 "Package tools complete: devhost-package and
journalist skill"; cost $2.54 for the host's stretch and $0.81 for the con's, per the entry]. The
records call the clash anticipated and say it was resolved when the stack was rebased after #15;
the package tools were devhost 1.4.0 when they merged (below) [ledger 2026-10-20 "Principles and
seed-package branches committed ..."; "PR #16-#17 rebased, version conflict resolved"; "Drop-a-seed
skill implemented ..."].

### Principles made binding, then cut from fourteen to five (2026-10-19 and 2026-10-20)

The principles of section 7 became binding in two steps. ADR 0011, dated 2026-10-19, says the
Operator reviewed and accepted the two drafts that day: ten principles for Features and fourteen
for agents [ADR 0011, Context]. The ledger entry that wrote them down is dated 2026-10-20: "Eight
architectural decisions written", with the files `docs/principles/features.md` (10 principles,
accepted) and `docs/principles/agents.md` (14, accepted), ADR 0011, ADR 0012 and ADR 0010 indexed,
and devhost 1.2.5 [ledger 2026-10-20 "Eight architectural decisions written: principles and ADRs
0011-0012"]. The same entry records that the iteration-package proposal then named the
foundation as "principles minus #13, ADRs 0003-0009, ledger and journalist" [same]. Gap: the date
of ADR 0011 (10-19) and the date of the entry (10-20) differ by a day, and the records do not say
whether the ADR was written on the 19th or dated for the day of acceptance.

ADR 0012 supersedes ADR 0001 and records a divergence that had never been written down: the git
Feature puts the bot identity in its wrapper, not in `containerEnv` as ADR 0001 said [ADR 0012,
Context]. It is the first of two identity ADRs of these days; the second is in section 11.

Later on the 20th the Operator trimmed the agent principles from fourteen to five, and renamed the
ten Feature principles "non-functional requirements", NFR-1 to NFR-10, with the same content and
order. A Sonnet con did the rewrite and wrote ADR 0013, which carries a 14-row table of where each
old principle went [ledger 2026-10-20 "Agent and Feature principles restructured: five principles,
ten NFRs, ADR 0013"; cost $0.40]. ADR 0013 gives the Operator's reason as a call: this is the next
iteration, trimming the fat; fourteen rules are too many to teach in an interview, and the fourteen
describe this repository, not a method another Operator can adopt [ADR 0013, Context]. The five are
P1 Separate personalization from process, P2 Continuous improvement, P3 The agent knows its place,
P4 Claims need evidence, P5 Right-size the work [docs/principles/agents.md]. P4 and P5 were named and
worded with the Operator that day; the dashboard requirement was folded into P1 as "a way to see
out"; P4 gained its picture of a court, with the agent as claimant, the inter as the operator's
advocate and the operator as judge [ledger 2026-10-20 "P5 confirmed, dashboard integrated into P1";
"Principle 4 finalized: Claims need evidence"; agents.md]. The host stretch that did this cost
$6.55 in the entry's Measures, the largest of the day; the 2026-10-20 review says the large host
stretches "were writing the principles with the Operator" [ledger "Review 2026-10-20", group 8].
The outline's order, "five, then fourteen", is wrong; the records' order is 13, 14, then five
(section 7).

### The seed's shape (2026-10-20)

The shape was decided in one host stretch: "Seed package architecture decided: journalist folded
into drop-a-seed". The seed is a plain folder: `README.md`, `papers/`, `foundation/`, `starter/`
and `skills/`; the journalist stops being a skill and becomes `drop-a-seed/journalist.md`, a brief
that the export hands to a writing subagent, which keeps the long ledger read out of the main
session [ledger 2026-10-20 "Seed package architecture decided ..."; ADR 0014]. ADR 0014
records two skills for the cycle, `drop-a-seed` at the end of a project and `plant-a-seed` at the
start of the next, both travelling inside the seed; it supersedes ADR 0009, and weighs the
alternatives of a journalist skill of its own (rejected: it only ever runs inside the export, and
the subagent already isolates the context) and of no import skill, a README alone (rejected: the
interview and setup are repeatable procedure) [ADR 0014, Options considered; ADR 0009 status line].
ADR 0014 also records the principle that rules that can be written as a script should be scripts
(P5), which is why assembly is a script (`devhost-package`) and the judgement is in the skills.

Two Sonnet cons wrote the skills at the same time, on the branch `devhost/iteration-package`. One
wrote `plant-a-seed` (`SKILL.md`, `INTERVIEW.md`) and the starter files (`devcontainer.json`,
`SETUP.md`, `CONTEXT.md`) from the interview guide, restructured by use case and by the five
principles, with questions, example answers and defaults; it pinned the starter's Features to
`:1` and asked in its own friction whether the Feature versions were published [ledger 2026-10-20
"Plant-a-seed skill and interview guide implemented"; $0.33]. The other wrote `drop-a-seed`, folded
the journalist's text into `journalist.md`, removed the old `journalist` skill folder, taught
`devhost-package` the options `--readme`, `--starter` and `--skills`, and wrote the foundation
manifest `docs/iterations/foundation.txt`; it bumped devhost to 1.4.0 and left lint at 73 tests
green [ledger 2026-10-20 "Drop-a-seed skill implemented with journalist.md folded in"; $0.57].
Its friction lists the ADR 0009 file not being in its worktree, a test count it had to correct
from 15 to 13, and `task docs` regenerating Feature lines that it had not meant to touch; its For the
repository lists the stale journalist references in six documents and the need to keep the
templates of the skills under `src/devhost/share/python/templates/` in step with `.claude/skills/`
[same]. A host entry the same day records two worked examples for the interview, a personal planning
assistant and a software shop, with a template dev container; its friction asks whether a ticket
tracker's command-line tool named in the example is a current product [ledger 2026-10-20 "Worked
examples complete with dev container tooling"; $2.30]. Gap: the examples' files are not named in
the entry, and this paper did not locate them.

An ADR number clashed: the librarian back and the principles work had both taken 0011, and the
seed ADR was renumbered 0014 when the two branches were prepared [ledger 2026-10-20 "Principles
and seed-package branches committed, PRs stacked and opened", Friction]. The same entry holds
the lesson the seed was built on: "Seed is cumulative: papers/ holds all iterations untouched;
papers arriving in a seed are copied byte-for-byte; missing or altered earlier papers cause
refusal (guards the series)" [same, Learned].

### Merging the stack (2026-10-20)

Pull requests #14 and #15 merged at 16:16Z and 16:17Z on the 20th, the day after they were opened.
Two more, #16 (the five principles, the ten NFRs and ADRs 0010 to 0014, the ledger through the 20th)
and #17 (drop-a-seed, plant-a-seed, the package tools, devhost 1.4.0), were opened at 16:10Z, stacked
on #14, rebased after #14's squash merge with the version conflict resolved, and merged at 16:24Z
and 16:23Z. #18, paper 1 kept as received (ADR 0010), was opened at 16:19Z and merged at 16:25Z
[gh pr list; ledger 2026-10-20 "PR #16-#17 rebased, version conflict resolved"; "PRs #16-#17 merged
to main"; "PR #18 merged to main"]. #17 merged before #16, so its content reached `main` inside #16's squash and
has no commit of its own there (section 9). The ledger's rebase entry repeats the stretch cost of
the entry before it ($2.19 twice), one of the repeats told in section 11.

One hitch stands out. The pre-commit name guard refused the records branch because the installed
devhost was 1.2.3 and predates the name exceptions of #15, so the Operator approved a single
`--no-verify` for that commit, with the reason in the ledger; `LICENSE` was added to the exception
list, the README's maintainer line was changed to a GitHub handle, and the redact list (ignored by
git, four entries) was recreated [ledger 2026-10-20 "Name guard exceptions created and changes
committed to records branch"]. That is the `--no-verify` commit of interview q10 (section 14).
Pull request #19, "Records of the 2026-10-20 session close", opened at 16:29Z, was blocked until a
required approving review was given, and the Operator merged it on github.com at 17:00Z [gh pr
list; ledger 2026-10-20 "PR #19 merged on GitHub"]. It also carried ADR 0015, the shutdown ADR,
section 11. Gap: the ledger has no entry for the writing of ADR 0015; the earliest entries that
mention it are of the records brief and the shutdown build [ledger 2026-10-20 "Seed records brief
for iteration 3 written read-only"].

The release came after #18: a manual workflow run at 16:29Z published the Features that the
starter names. It is told with the other claims that did not hold, in section 11.

### The export's own run (2026-10-20)

The export that this paper belongs to started once #19 and the release were done. The steps were
those of ADR 0014: a records brief written read-only by a Sonnet con (about 2,900 words; $1.76 in the entry's
Measures; its friction records the Bash output of the large ledger being truncated and re-read in
chunks, and that the working tree held uncommitted writes by the backs) [ledger 2026-10-20 "Seed
records brief for iteration 3 written read-only"]; the closing interview, whose first round the
host saved word for word [ledger 2026-10-20 "Interview round 1 saved word for word to
interview-3"]; the outline, approved by the Operator [interview q22]; and this paper, drafted by
cons section by section under the journalist brief, with the Operator's review between rounds. The
con that drafted sections 1 to 4 found that the records brief had the pull-request dates wrong and
that its counts of cons by model are not in the ledger; it used `gh`, and the first review's 14 con
runs, instead [ledger 2026-10-20 "White paper of iteration 3, sections 1 to 4 drafted", Friction].
The con that revised them and drafted sections 6 to 9 found that the outline's order of
principles was wrong and that the ontology guard was not on `main` (section 11) [ledger 2026-10-20
"Iteration 3 paper revised per round 4, sections 6 to 9 drafted"].
The writing of the paper is therefore itself in the records it describes, and one of its writers
caught a fault in the host's own work while checking a fact, which section 11 tells.

## 11. The records failing, and the reviews catching it (2026-10-20)

The records of this project are its method: the ledger, the cost report, the guards, the backlog
and the pull requests are what the Operator, the host and the next iteration rely on to know what
happened. On 2026-10-19 and 2026-10-20 they failed in seven ways, in the same days as the export was being
built on them, and one more piece of work, the shutdown check, was built in the middle of the seven.
Each failure was found by a review or by the work, and each became a change, with a test where one
could be written (said below). The pattern is told at the end: the failures were
not only the backs'. The host's own statements failed too, and the section keeps both.

Four terms are used here that earlier sections did not explain. A **rebuild** is the recreation of
the dev container from its definition; the checkout stays on the Operator's disk, and the named
volumes that hold Claude Code's state, the backs' run records and the git Feature's config are
meant to survive it. A **stretch** is the span of a session's replies that the scribe back turns into one or more
ledger entries, filling each entry's Measures line with the stretch's cost; the records use the word
without defining it. A **squash merge** turns a pull request into one commit on `main`, so a branch
that was merged this way is no longer an ancestor of `main` and `git branch --merged` cannot see it.
**Admin bypass** is the Operator merging a pull request past the branch protection's required checks
or review, as an administrator.

### The release: what was published, and when

The decision of 2026-10-16 (section 6) was Features first. The Features merged on 2026-10-16 as #11
(03:15Z), but the release is a manual workflow run on `main` and it was not run until the 20th. The
ledger records it in two entries. The first says: "Five Features published to GHCR: go-task 1.1.0,
claude-code 1.3.0, git 1.1.0, gh 1.0.0, devhost 1.4.0. Starter `:1` tags now resolve for new
projects", with the friction that the container's installed devhost "remained at 1.2.3 after release;
name guard additions require rebuild" [ledger 2026-10-20 "Release workflow completed, Features
published to GHCR"]. The second, a validation, says that all 16 Features were on the registry,
anonymously pullable, each tagged with its `src/` version and `latest`, that "the five that blocked
the release were git 1.1.0, gh 1.0.0, az 1.0.0, common 1.0.0 and devhost 1.4.0", and that
`release-collection` could be ticked and the export was no longer blocked on it; its friction lists
that the container had no GitHub credentials for pushes, that auto mode refused `git push --delete`,
and that gh's interactive login could not finish at the `!` prompt and succeeded as a bash input
[ledger 2026-10-20 "Feature collection release validated on GHCR"]. The two entries name
different sets of five (section 6, Gap; TODO `release-entries-sets`).

The workflow's own log settles part of this, and it disagrees with both entries. The release
workflow ran three times in the repository's life: 2026-10-09T16:07Z and 18:26Z, in the first life,
and 2026-10-20T16:29Z on the head of #18 (`638a0ab`), started by hand [gh run list for "Release
dev container features"]. The last run's log shows 15 Features published at that run (argocd 1.1.1,
az 1.0.0, claude-code 1.3.0, coder-cli 1.1.1, common 1.0.0, devcontainer-cli 1.1.3, devhost 1.4.0,
dsc 1.1.1, gh 1.0.0, git 1.1.0, kube-state 1.0.1, kubeconform 1.0.1, kustomize 1.0.1, openbao 1.0.1,
velero 1.0.2) and one skipped with the warning "Version 1.1.0 already exists", which by the
alphabetical order is go-task [gh run view 39457857111 --log, lines "Published feature" and
"already exists"]. So "five" in both entries is the count of the Features the starter needs, or of
those that had never been published, and not the count the run published. Guess: that is the
sense of "five" in the validation entry (git, gh, az, common and devhost, the five that had never
been published; section 6 reads them as the five of PR #10); the run entry's list, with go-task and
claude-code in place of az and common, is then a mistake in that entry. Neither entry mentions the 15.

What the registry holds now is a further point. The last release run was on `638a0ab`, where
devhost was 1.4.0, git 1.1.0 and devcontainer-cli 1.1.3 [git show 638a0ab:src/<id>/devcontainer-feature.json].
After it, `main` took devhost 1.5.0 (#21), git 1.2.0 (#23), devhost 1.6.0 and devcontainer-cli 1.2.0
(#24) [gh pr list; src versions], and the branch of this paper took devhost 1.6.1 [ledger 2026-10-20
"Main folded into docs/seed-iteration-3 ..."]. No release run follows in the run list. Gap: the
records do not say whether a second release is planned before the seed is planted; as of this
writing the published `devhost:1` is 1.4.0, which has no shutdown check, and the published `git:1`
is 1.1.0, which has no `commitWhenEnv` (section 15 takes up what that means for the starter).

The Operator's stated gain from Features first, published Features that the other projects could
reference, was therefore available from the 20th, four days after the merge, and the Operator's
account is that the other projects could reference them from the 20th [interview q32, "Yes to all"
in round 5; section 6]. The 20th is also the day the cost report lost its history, which is the next
failure.

### The cost report that erased its own history

The cost report (`docs/ledger/costs-2026-10-<engineer>.md`, generated by `devhost-report`, and
again at every session start by the briefing) was built, until 2026-10-20, from this machine's
Claude Code transcripts and the backs' run records. It is regenerated, never edited by hand. When
the container was rebuilt on the 20th it was regenerated from whatever the volumes then held, and
the committed report lost its history. The first signs were in the work. One host entry notes that the
file shows "13 lines removed, 1 added" in the working tree and that it "appears to have been regenerated
empty"; another records that the briefing's spend line read "$0.00 across 0 back runs while the ledger
holds entries and corrections" [ledger 2026-10-20 "Remote branches compared with main; merged branches
pruned"; "Session identity confirmed"]. The host's first decision was to restore main's copy
and move on: "Keep main's cost report and drop the local regeneration. Ignore the costs-report-empty
item" [ledger 2026-10-20 "Main pulled after #19; name guards rerun and pass", Decisions]. That decision
treated the symptom as noise, one entry before the review took it up.

The third review, of 29 entries, read the cost report first, as its brief says, and found the cause:
the report "lost its history on a rebuild: it was rebuilt from the volumes' transcripts and run
records only, so $49.84 became $2.21 and the briefing read $0.00" [ledger "Review 2026-10-20", Costs
and group 1]. The change was made in the review itself and shipped as PR #20 (devhost 1.4.1, opened
17:15Z, merged 17:18Z): the report keeps a committed store beside it,
`costs-YYYY-MM-<engineer>.jsonl`, one line per priced reply or back run, ids and numbers only; it
merges the machine's records into that store; and the month's earlier figures are carried as a
one-time baseline taken from the committed report. Two tests were added, `test_a_rebuild_loses_no_history`
and `test_a_baseline_adds_to_every_table`; the month then read $55.19 instead of $2.21 [gh pr list;
ledger "Review 2026-10-20", group 1; git log `f15a215`, PR #20 description]. After a second rebuild,
the one that followed #23, the briefing read $64.46 for the month, up from $55.19, "the cost store kept
its history" [ledger 2026-10-20 "Devhost rebuild checked: identities and cost store intact"]. That is the
figure of the cost report as committed [docs/ledger/costs-2026-10-operator.md].

Three honest limits. First, the baseline holds the totals of the earlier figures, not their detail:
the review says its own lack, "the transcripts and back run records from before the 2026-10-20 rebuild;
the baseline carries their totals, not their detail" [ledger "Review 2026-10-20", What this review
lacked]. Second, the entry that declared the volumes safe before the rebuild said "Claude session and
backs state in volumes (preserved)" and the review found that "volumes preserve the Claude session"
"held for the session but not its transcript history" [ledger 2026-10-20 "Rebuild readiness check
completed"; "Review 2026-10-20", group 3]: the host's statement, written by the scribe, was a claim
that was not checked against what the report needed. Third: Gap: the records do not say why the
transcripts were not on the volume after the first rebuild of the 20th. It is the same family as the
loss of 2026-10-19, when the state volume was recreated at 14:21 (section 9), but the records do not
say it is the same cause. This is also one more reason why the cost of 2026-10-16 to 2026-10-18 is
not in this paper: the store was introduced after the history it would have kept was gone.

### A stretch's cost copied onto every entry

The scribe writes each entry's Measures line from a script that prices the stretch. The script put
the stretch's cost on every entry the stretch produced, so a stretch that produced two entries
showed its cost twice, and a sum over entries overcounted. The first sight of it is in section 8, where
a $3.75 host stretch sits on two entries of 2026-10-17. The review of 2026-10-19 named it, group 4
("a stretch's cost copied onto several entries, so sums overcount"), and filed
`scribe-cost-deduplication`. The review of 2026-10-20 found it back: "11 of 29 entries repeat their
stretch's cost; the job wrote it onto every entry by design", and changed the scribe job in the review
itself: "the cost on the first entry and a pointer on the others", with a functional check "the stretch's
cost is on its first entry only" [ledger "Review 2026-10-19", group 4; "Review 2026-10-20", Recurrence and
group 2]. The recurrence is itself a finding: the first review's action was a backlog item, not a
change, and the problem was there a day later, with the next set of entries.

Two things follow in the records. Between the review and the rebuild, entries still repeated their
cost: the entry for #20 and the entry for #21 both read $7.35, and the three entries from the branch deletion
to the pull after #19 read $0.80 [ledger 2026-10-20 "Ledger review applied and PR #20 opened"; "devhost-site
rebuilt as PR #21 ..."; "PR #19 merged on GitHub"; "Main pulled after #19 ..."]. After the rebuild the
entries read "Measures: counted in the first entry of this stretch, above", as designed (the entries
for #23 and for the rebuild check) [ledger 2026-10-20 "Git 1.2.0 agent commit identity merged as PR
#23"; "Devhost rebuild checked ..."]. Guess: the repeats before the rebuild are the job's old version,
still installed, which matches the first review's lesson that a fix in `src` is not live until a rebuild
(group 1 of the review of 2026-10-19: "Fixes in `src` not live until a rebuild"); no entry says so.
And a backlog item written later on the 20th records that host cost Measures "still repeat across
entries ($0.68, $1.79, $3.75)", so that sums overcount even though the item is ticked
[TODO.md `cost-measures-repeated`, open]. Gap: which writer repeats them is not established;
the Measures lines of the ledger are therefore not summed anywhere in this paper (section 12).

### Corrects: none

Each ledger entry may carry a `Corrects:` line, and only a correcting entry should: "A wrong entry is
never edited; a new entry with a `Corrects:` line replaces it" [ledger/README.md; CLAUDE.devhost.md "The
ledger"]. The scribe wrote `Corrects: none` on entries that corrected nothing: 41 in the file now,
25 of the 55 entries of 2026-10-16 and 16 of the 17 of 2026-10-17, none since [grep of
`docs/ledger/2026-10.md`, counted for this paper]. There were nine real corrections, all on the first two
days (eight on the 16th, one on the 17th) [same; docs/ledger/costs-2026-10-operator.md "Ledger
corrections: 9"].

The fault went through four steps. The night shift of the 16th changed the scribe's brief so that
`Corrects` was written only for a real correction (devhost 1.2.3) and noted that a check for it
could not be added to `devhost-verify` because the existing entries held the line and the ledger is
append-only [section 5; ledger 2026-10-16 "Tidy back-briefs (librarian, secretary, scribe)", Friction]. The review of 2026-10-19
found the line still being written, 24 of 34 and 16 of 17, because the installed devhost lagged
the fixed brief, and found that the cost report counted every `Corrects: none` as a correction:
"50 reported, 9 real", which it fixed in `abf6412` (devhost 1.2.4) with a test shown failing on
the old count; the Operator decided that the guard would refuse the line from 2026-10-19 on, never
retroactively [ledger "Review 2026-10-19", groups 2 and 3]. The review of 2026-10-20 found one new
`Corrects: none` and made the refusal real: `devhost-verify` refuses it in entries dated 2026-10-19
or later and the scribe job drops the line before appending, with the test
`test_corrects_none_is_refused_from_2026_10_19_only`; the one uncommitted line was removed before
its first commit [same, "Review 2026-10-20", group 3]. The ledger now holds none on the 19th or the
20th [grep]. The 41 earlier lines stay, by the append-only rule.

### Conflict markers past every guard

At the close of the 20th, while the host moved the backs' late records from one branch to another, a
commit went out with merge-conflict markers in the ledger: `<<<<<<<`, `=======` and `>>>>>>>` lines
left by a stash pop. Every guard passed. The ledger entry says it plainly: "Moving the backs' records between
branches left them in, and every guard passed"; the host removed the three marker lines in the next
commit, keeping both sides, and filed the backlog item `verify-conflict-markers` for the missing guard
[ledger 2026-10-20 "Session wrap-up: late records to PR #22, conflict markers fixed"; TODO.md
`verify-conflict-markers`]. The two commits are `74cbb67` (17:28Z, the entry for #21 and the
post-rebuild identity check, which carried the markers) and `489ee4a` (17:29Z, "remove conflict markers
left in the ledger by a stash pop"), both on `chore/records-2026-10-20-close` [git log -S for the marker lines, on the ledger file]. The
markers are not on `main` [git grep on `origin/main`: none]. The guard does not exist: the item is
open, and a test that fails without it is not written. Gap: that branch had not been merged when this
was written, and whether the commit with the markers is ever merged as it stands is not established;
the fix commit follows it on the same branch.

It is the same family as the guard that checked nothing (section 4): a check that passes without having
looked at what it should have. This one found nothing wrong because it did not look for the thing; it is
a missing rule, not a broken one.

### Agent commits with no identity, then an identity too wide

The bot identity of 2026-10-16 (section 4, ADRs 0001 and 0002) did not survive the move into practice.
The git Feature put the identity in its wrapper from 1.1.0 (ADR 0012), but this devhost did not set the
options, so agent commits had none: the first commit of PR #20 failed for no author name, "and the email
was personal", and the bot identity was applied by hand on each command [ledger 2026-10-20 "Ledger review
applied and PR #20 opened", Friction; "Local git email question answered; agents to commit as bot
identity", Friction]. The review of 2026-10-19 had already named it: `bot-git-identity` "came back (a con
committed under the Operator's address; stray sign-offs)", and the Operator had decided the wrapper would
cover rebase, cherry-pick and merge commits [ledger "Review 2026-10-19", group 6].

Setting the Feature's two options in this devhost would have fixed agents and broken the Operator: the wrapper fills the
author for every git call that has not set one, so the Operator's own commits from a container terminal
would have been the bot's too [ADR 0016, Context]. The Operator's answer to the question of whether their
local address was right is paraphrased from the entry: yes, their commits should carry their own real
address; agents should set their own [ledger 2026-10-20 "Local git email question answered ...", Decisions].
ADR 0016 chose to gate the identity on an environment variable: git 1.2.0 has an option `commitWhenEnv`;
this devhost sets it to `CLAUDECODE`, which Claude Code sets on every process it starts, so agent commits
and sign-offs are `devhost agent <devhost-agent@noreply.invalid>` and a person's terminal commits keep their
own [ADR 0016, Decision]. It was opened at 17:26Z and merged at 17:31Z as #23 (`f349fc0`); after the
rebuild a test commit from Claude Code came out as the bot and one from the terminal as the repository
identity, and the commits of the branch of this paper are authored by the bot [gh pr list; ledger
2026-10-20 "Devhost rebuild checked ..."; git log of `9251726` and `64ff85f`]. ADR 0016 states what it
leaves open: a commit the Operator makes through the `!` prompt runs inside Claude Code and so carries the
bot identity; a harness that does not set the marker gets none; a command that bypasses the wrapper gets
none [ADR 0016, Consequences]. Over the five days of sections 4 to 11 the identity took three decisions (ADRs 0001,
0012, 0016) and two versions of the git Feature before it did what the first one asked; the version
that carries the third (git 1.2.0) was not published as of this writing (above).

### A remote branch deleted as merged, whose guard code had never reached main

On the 20th the host compared six remote branches with `main`, after the stack merged, and listed
ahead and behind counts; `devhost/ontology-guard` was 37 ahead and 6 behind, `chore/night-shift-2026-10-17`
51 ahead and 6 behind [ledger 2026-10-20 "Remote branches compared with main; merged branches pruned"].
Three branches were then deleted from GitHub as merged; the entry does not name them, and the backlog item
`branch-triage` does: `chore/night-shift-2026-10-17`, `devhost/ontology-guard` and `fix/gitattributes-lf`
[ledger 2026-10-20 "Three merged remote branches deleted from GitHub"; TODO.md `branch-triage`]. The records
show no merge check before the delete, and the delete itself was first refused by auto mode and
then by missing credentials, which the review turned into `gh-auth-briefing` [ledger "Feature collection
release validated on GHCR", Friction; "Review 2026-10-20", group 4].

The mistake was found by the con that wrote sections 6 to 9 of this paper, while checking one fact:
whether the ontology guard was on `main`. It was not. The guard's commit (`8dd5717`) is not an ancestor of
`main`; the 37 commits were never merged. The con put it to the host as a decision needed: "Is the ontology
guard to be merged? It is not an ancestor of main, and publish-ontology-guard-pr is still open, yet
branch-triage lists it as merged and deleted" [ledger 2026-10-20 "Iteration 3 paper revised per round 4,
sections 6 to 9 drafted", Decisions needed]. The host then corrected itself: `devhost/ontology-guard`
"restored on GitHub from the commit still on the machine; about 280 lines had never reached main";
`chore/night-shift-2026-10-17` restored too, "to be safe"; `fix/gitattributes-lf` confirmed merged, and
merging it changed nothing. Its own account of the cause: "The ontology-guard branch was deleted after
checking only its conflict markers, not whether it was merged", and "Conflict markers do not show merge
status. Only a merge check does" [ledger 2026-10-20 "Branch triage corrected: two branches restored after a
wrong delete"]. The backlog item `branch-triage` kept its tick and gained the correction; the item
`ontology-guard-merge` was put to the Operator and ticked [TODO.md]. The Operator answered "Yes to all" to
the round that carried it: bring the guard up to date with `main` and open it as a pull request, a devhost
minor bump after the seed; delete `chore/night-shift-2026-10-17` again, because its content reached `main`
[interview q30, q31]. At the time of writing the local branch `feat/ontology-guard` holds one commit,
"model guard and add-only librarian model keeping, 1.7.0", and no pull request for it is open [git log;
gh pr list]; `publish-ontology-guard-pr` is open [TODO.md].

What the deletion cost is not known and must be said as it is: nothing is recorded as lost, because
a copy of the commit was still on the machine. Gap: the entries do not say whether another copy existed;
had the checkout and the volumes been lost, the remote branch was the only other place the code was.
Also Gap: the Operator's request to clean up branches is not in the stretch of the entries, so the
instruction the host acted on is not known. The `fix/gitattributes-lf` check is the useful contrast: a
merge check was possible and cheap, and it came after the delete.

The paper's own account matters here for a second reason: a writing subagent, briefed to trace every fact
to a record, found a wrong claim in a record the host had written, because tracing a fact is what the
brief makes it do (journalist brief, "Every fact traces to a record"). The reviews and the guards did not.

### The shutdown work built during the export (PR #24, ADR 0015)

The shutdown work was not a failure; it is told here because it was built in the middle of these ones and
because it is a repair for another of them. ADR 0015 (dated 2026-10-20, merged inside #19 with no ledger
entry of its own, section 10) decides that stopping a dev container safely is three pieces:
`devhost-shutdown-check`, a script that tests the rules that can be written down (the working tree clean and
pushed, no back's lock held, no pending stretch, no tester run in progress, no night shift mid-plan, stashes
and untracked files listed); the `shutdown-devhost` skill and its counterpart `restart-devhost`; and
`devcontainer:stop`, a host task that runs the check first, because the dev container specification has
start hooks but no stop hook [ADR 0015, Context and Decision]. The ADR gives its own motive, the Operator's wish to make the host's ad-hoc shutdown preparation part
of the container's lifecycle; the day offered cases of the same shape, a rebuild readiness check made by
hand with backs finishing in the background, and records moved between branches by hand (above) [ADR
0015, Context; ledger "Rebuild readiness check completed"; "Session wrap-up ..."]. The link between the
day and the ADR is this paper's reading, not a record.

In the closing interview the Operator's answer on whether the ADR belonged in the seed was that it
should, because it is related to the dev container Feature and anyone who runs the dev container needs
to know that shutting it down has running processes; on the defaults path they expected "a close
session type skill", and if it was not built, a subagent should implement the ADR and the seed should
carry it [interview q14, paraphrased and garbled in dictation, not quoted]. A Sonnet con did it: commit
`9d076dc` on `feat/devhost-shutdown`, the check and its 11 tests, the two skills, `devcontainer:stop`
for the bash and the PowerShell host tooling; devhost 1.5.0 to 1.6.0 and devcontainer-cli 1.1.3 to 1.2.0;
`task lint` and `devhost-verify` passed and `task test` was not run [ledger 2026-10-20 "ADR 0015 shutdown
check, skills and stop task committed on feat/devhost-shutdown"; cost $0.88]. The con's friction is plain
about what it could not do: the devcontainer CLI has no stop, so the task finds the container by its label
and stops it with the engine's CLI, and "the host path is untested: the engine runs on the Windows host and
the label path format is unverified"; PSScriptAnalyzer asked for `SupportsShouldProcess`; a test failed
because `git add -A` staged its own scratch file; and when the container is not running the check says
"check failed" and not "container not running" [same, Friction]. The host pushed the branch, opened #24 at
18:12Z and the Operator merged it at 18:28Z [gh pr list; ledger 2026-10-20 "PR #24 merged, ADR 0015
shutdown work"]. The pull request's checklist leaves one box open, in bold: "Not tested: the stop route
itself ... Needs one real `task devcontainer:stop` from the workstation before relying on it" [PR #24
description]. The backlog item for it, `devcontainer-stop-try`, is open and assigned to the Operator
[TODO.md]. The interview's later answers settled two defaults: an untracked file blocks a shutdown as
built, and the package's default skill list includes `shutdown-devhost` and `restart-devhost` [interview
q23, q24]; the package default was changed in devhost 1.6.1 [src/devhost/share/python/package.py; ledger
"Main folded into docs/seed-iteration-3, devhost 1.6.1, branch pushed"]. Gap: the backlog items
`seed-shutdown-skills` and `shutdown-untracked-blocks` still stand open, although the Operator answered
both; the backs had not ticked them when this was written.

### What was found by whom, and what changed

| Failure | Found by | Changed by | Test or guard | Still open |
|---|---|---|---|---|
| Cost history lost on a rebuild | The work (empty file, $0.00 briefing), then review 2026-10-20 | PR #20, devhost 1.4.1 | `test_a_rebuild_loses_no_history`, `test_a_baseline_adds_to_every_table` | Pre-rebuild detail is gone; cost 10-16 to 10-18 is not recovered |
| A stretch's cost on every entry | Review 2026-10-19, back in review 2026-10-20 | The scribe job, in the review | Functional check "first entry only" | `cost-measures-repeated` |
| `Corrects: none` | Night shift 10-16, reviews 10-19 and 10-20 | devhost 1.2.3, 1.2.4, 1.4.1 | `test_corrects_none_is_not_a_correction`, `test_corrects_none_is_refused_from_2026_10_19_only` | The 41 older lines stay (append-only) |
| Conflict markers in the ledger | The host, after the commit | Fix commit `489ee4a` | None | `verify-conflict-markers` |
| No identity, then too wide an identity | Reviews, the work | ADRs 0012 and 0016, #23, git 1.2.0 | Rebuild check by hand | Git 1.2.0 unpublished; `!` prompt carries the bot identity |
| Branch deleted as merged | A writing subagent, checking a fact | The host's restore; a pull request to come | None (`branch-triage` to test merge status is asked for) | `publish-ontology-guard-pr` |
| Release not run until the 20th, entries disagree | The con that drafted sections 6 to 9 (the entries); the timing is in section 6 | Release run 2026-10-20 | None | `release-entries-sets`; second release |
| Shutdown without a check | The Operator's wish (ADR 0015, Context) | PR #24, ADR 0015 | 11 unit tests | The stop route is untested on the workstation |

[the sections above; TODO.md]

### The pattern

The reviews caught four of these: the repeated cost, `Corrects: none`, the cost report that lost its
history (found first by the work and then diagnosed by the review), and the recurrence of the identity
fault. The work caught the conflict markers (the host, after the commit), the branch deletion (a subagent,
not the host's own checks) and the identity's width (ADR 0016, before the options were set). No guard
caught any of them when it happened; the one guard that now covers a failure of this section,
`devhost-verify`'s refusal of `Corrects: none`, exists because a review wrote it.

The honest reading is that the host's own claims failed too, not only the backs'. The paper's lesson
in section 4 was the false "done" of the cons and the scribe's unchecked statements, and principle 4
("Claims need evidence") was written from them. In these two days the same kind of fault came from the
host: "volumes preserve the Claude session" said before a rebuild; branches "merged" said before a
merge check; the cost report's empty file set aside; the markers committed past guards that had never
been taught to look. The Operator's framing of the lesson was the false "done" and the
unsolved scribe [interview q9]; this section adds that the claimant who did not prove its claim was, on
the 20th, sometimes the party the principle names as the Operator's advocate. That is not a verdict on
the host and it is not proof that the principle is wrong. It is what the records show on one day,
and the principle's own wording, "the inter ... checks the evidence itself" (P4), is what was not done in
the branch case [docs/principles/agents.md P4]. Whether the day is typical is not known: nothing in the records counts how often the host's own
claims held.

## 12. Numbers

Every figure here was counted again from the primary records for this paper, not taken from the records
brief of 2026-10-20, which is a secondary document and was wrong in places (listed at the end of the
section). The source of each figure is in brackets. Money figures are list-price estimates, not charges:
the cost report prices every reply and run at the list price of its model (Opus $5 and $25, Sonnet $3 and
$15, Haiku $1 and $5 per million tokens in and out; unknown models priced as Opus), and says so in its
header [docs/ledger/costs-2026-10-operator.md]. A figure with no stated basis is marked.

### The ledger

- **Entries:** 128 at the last count made for this paper (`grep -c '^### ' docs/ledger/2026-10.md`,
  working tree). By day: 2026-10-16, 55; 10-17, 17; 10-18, none; 10-19, 11; 10-20, 45 [same, by the
  date in each heading]. The count rises while this is read, because the scribe writes entries for the
  drafting of the paper itself; the figures of the first three days cannot change, and the 20th's can.
- **By writer:** 82 entries by host sessions and 46 by cons, taken at the same count of 128 [the
  Session line of each entry]. Of the cons' entries, 12 are dated 2026-10-19 or later, against 8 con runs
  in the cost report for the same days [docs/ledger/costs-2026-10-operator.md, Cons]. Gap: the two
  counts are not reconciled; the report counts runs it found in transcripts, and the records do not say
  whether every con job gets an entry or the report found every job.
- **Corrections:** 9 real corrections, 8 on the 16th and 1 on the 17th (a `Corrects:` line with a
  target); 41 `Corrects: none` lines, 25 on the 16th and 16 on the 17th, none since the guard [grep of
  the ledger; the cost report's "Ledger corrections: 9" agrees]. Section 11 tells the 41.
- **Reviews:** 3 [ledger `## Review` sections]: 2026-10-16 (21 entries), 2026-10-19 (53) and
  2026-10-20 (29), 103 entries in all; the rest are the entries that came after the third review's
  window. A review is meant "every five or so entries" [CLAUDE.devhost.md]; these three came at 21, 53
  and 29. Each of the second and third found a recurrence of an earlier finding (section 11,
  section 14).

### Pull requests

[gh pr list --state all --limit 40, createdAt and mergedAt]

- 23 pull requests exist, numbered 1 to 24; #7 is not a pull request. 20 merged; #1 and #10 closed
  without merging; #9, a Copilot draft of 2026-10-12, is open.
- Merged: 6 on 2026-10-09 (#2 to #6 and #8), 1 on 2026-10-16 (#11, 03:15Z), 2 on 2026-10-19 (#12 and
  #13, 15:20Z and 16:09Z), 11 on 2026-10-20 (#14 to #24). #14 and #15 were opened on the 19th at 16:13Z
  and merged on the 20th, at 16:16Z and 16:17Z; #16 and #17 were opened and merged on the 20th [same].
- `origin/main` has 20 commits: the initial commit and 19 for the 20 merged pull requests, because #17
  has no commit of its own (section 9) [git log origin/main].
- Dates here are from `gh`, which reports UTC. `git log` shows the commits with a US-Eastern offset,
  so the same merge can be on two days, as for #11, which `git log` dates 2026-10-15 [section 3].

### Decisions, Features and tests

- **ADRs:** 16 (0001 to 0016): 8 dated 2026-10-16 (0001 to 0008), 1 on the 17th (0009), 3 on the 19th
  (0010 to 0012), 4 on the 20th (0013 to 0016). Two are superseded: 0001 by 0012 and 0009 by 0014 [status
  lines of `docs/adr/`]. ADRs 0010 to 0014 reached `main` in #16 and 0015 in #19; 0016 is in the
  commit `9251726` of this paper's branch and not yet on `main`, although the change it records (#23) is
  [git log -- docs/adr; git ls-tree origin/main].
- **Features:** 16 in `src/`: ten from the first life (2026-10-09, #2 and #5), and six added on
  2026-10-16 through #11 (git, gh, az, common, devhost, kube-state) [section 6]. Versions on this branch
  [`src/*/devcontainer-feature.json`]: argocd 1.1.1, az 1.0.0, claude-code 1.3.0, coder-cli 1.1.1,
  common 1.0.0, devcontainer-cli 1.2.0, devhost 1.6.1, dsc 1.1.1, gh 1.0.0, git 1.2.0, go-task 1.1.0,
  kube-state 1.0.1, kubeconform 1.0.1, kustomize 1.0.1, openbao 1.0.1, velero 1.0.2. The last release run
  (2026-10-20T16:29Z, section 11) published the same versions in all but three: devcontainer-cli 1.1.3
  (branch: 1.2.0), devhost 1.4.0 (1.6.1) and git 1.1.0 (1.2.0) [gh run view; git show 638a0ab].
- **Tests:** the devhost's unit tests passed 53 at devhost 1.2.3 and 56 at 1.2.4, 66 with the package
  tools, 73 at 1.4.0, 92 at 1.5.0 and 106 at 1.6.0 and after [ledger entries of 10-16 "Tidy back-briefs",
  10-19 "Devhost report and briefing fixes committed (1.2.4)", "Package tools complete", 10-20 "Drop-a-seed
  skill implemented ...", "devhost-site rebuilt ...", PR #24 description]. These are the entries'
  counts; the paper did not rerun them. The Feature tests (`task test`) need a Docker daemon and run
  in CI only; this container cannot run them (section 14).
- **Night shifts:** 2, 11 items of 11 done: 8 of 8 on the 16th (about $9.5 of $100) and 3 of 3 on the
  17th (about $4.6 of $10) [night-shift reports]. Both reports were reviewed by the Operator. The basis
  of the two cost figures is not stated in the reports. Guess: list price from the same tool as the cost
  report, which was not checked.

### Back runs and guard undos

From the cost report of 2026-10-19T14:23Z to 2026-10-20T17:29Z: backs ran 217 times, 1 run undone by a
guard [docs/ledger/costs-2026-10-operator.md, Backs]:

| Back | Model | Runs | Changed | Nothing | Pending | Undone | Cost | Per change |
|---|---|---|---|---|---|---|---|---|
| librarian | Sonnet | 32 | 6 | 13 | 13 | 0 | $4.23 | $0.71 |
| scribe | Haiku | 54 | 28 | 26 | 0 | 0 | $2.40 | $0.09 |
| secretary | Haiku | 48 | 31 | 15 | 2 | 1 | $3.42 | $0.11 |
| tester | none | 83 | 2 | 81 | 0 | 0 | $0.00 | $0.00 |

The tester ran without a Docker daemon and mostly found nothing to do; its two "changed" are not
explained by the report. The first review counted 97 back runs on the 16th and 5 undone by a guard
[ledger "Review 2026-10-16", Costs]; the second review's window (the 19th, early) counted 16 runs and 0
undone; the third counted 185 runs and 1 undone, the same undo as the report's [ledger "Review
2026-10-19", "Review 2026-10-20"]. So the guard undos known are 6: 5 on the 16th and 1 between 2026-10-19 and the
report's end, by the secretary [reports as read; the report gives no date for the undo]. Gap: no run record exists for the 17th and 18th, and the 16th's
97 is the first review's count, while a con of the 16th found 117 runs in the run file that day (section
9); the two counts are not reconciled.

### Cost

All list-price estimates [docs/ledger/costs-2026-10-operator.md unless another source is given]. The
report's total is **$64.46** for the month of October on this machine: inters $50.20 in 2 sessions, cons
$4.20 in 8 runs (about $0.53 a run), backs $10.06 in 217 runs [same, header line].

| Day | Inters | Cons | Backs | Total |
|---|---|---|---|---|
| 2026-10-19 | $17.30 | $2.90 | $4.11 | $24.31 |
| 2026-10-20 | $32.90 | $1.30 | $5.94 | $40.14 |

The two days add to $64.45, a cent below the total, which is rounding. By model: Opus $50.20 (all inters,
412 replies), Sonnet $8.43 ($4.20 cons, $4.23 the librarian), Haiku $5.81 (the scribe and secretary,
102 runs), and 83 runs with no model (the tester) at $0.00 [same, By model]. The inters' two sessions: one of one reply
($0.21, 2026-10-19T14:23) and the host session of this work, 411 replies, $49.99 [same, Inter
sessions]. Cons: 8 runs, all Sonnet, 97 replies [same, Cons].

Where the report ends. The report was generated when the briefing last ran; its last reply is
2026-10-20T17:29. The work after that time is not in it: the records brief, the closing interview and the
drafting of this paper, PR #24 and the later branch work. Their stretches appear in entries' Measures, which
repeat and are not summed (section 11), so the real cost of the 20th is more than the $40.14 and is not
known here. Gap: no cost figure for the 20th after 17:29. $64.46 is a lower bound for the iteration from
2026-10-19; it does not cover 10-16 to 10-18.

Other cost figures in the records, each as given and each a list-price estimate unless said:
- 2026-10-16, the first review's window: $27.74 (host $16.40 in one session, cons $6.19 in 14 runs, backs
  $5.16 in 97 runs, 5 undone) [ledger "Review 2026-10-16", Costs]. The cost file that review read no
  longer exists (section 9).
- 2026-10-16, a file for 00:28 to 00:30: $0.44, 4 replies and 4 back runs [docs/ledger/costs-2026-10-unknown.md].
- The first night shift, about $9.5 and the second, about $4.6 (basis not stated, above). The first
  night-shift report starts "at $28.79" and the second "at $65.28 (session to date)", a figure the
  Operator decided to leave out of this paper [section 5; interview q28]. The two figures'
  bases differ; Guess: the second is the host's cost for the whole day of the 16th, not checked against a report.
- 2026-10-19, the second review's window: $4.11 (host $2.65, cons $0.69, backs $0.76) [ledger "Review
  2026-10-19", Costs]. The cost report's backs figure for the whole day is also $4.11. Guess: a
  coincidence; the review's total and the report's backs-only figure measure different things, and the
  paper did not find a link.
- 2026-10-19 to 2026-10-20T16:26, the third review's window: $49.84 (host $35.98 in 2 sessions, Sonnet
  cons $4.20 in 8 runs, backs $9.66 in 185 runs, 1 undone) [ledger "Review 2026-10-20", Costs]. This is
  the baseline that PR #20 carries (section 11).
- Per entry: of the 128 entries 113 carry a dollar figure in Measures, from $0.11 to $12.55 at that
  count [ledger]. They repeat across entries and are not summed.
- The review of 2026-10-16 found the librarian changed nothing in 14 of 19 runs ($0.57 per change)
  [section 5]; the current report shows its 32 runs as 6 changed, 13 nothing and 13 pending, $0.71 per
  change [above]. The two count different windows and are not a trend.

**Cost 2026-10-16 to 2026-10-18: not available at the time of writing.** Due to technical issues the
data was not available; the paper may be amended [interview q7 and q34, paraphrased; section 9]. This
paper follows the Operator's wording, not the ledger entry that says the history is lost.

### Where this recount differs from the records brief

The brief is a working document and the Operator did not ask for it to be corrected. The differences, so
that nobody reads a figure from it into this paper:
- Entries: the brief counted 114 (110 on `main`); the count made for this paper is 128 and rising. The
  brief's by-day figure for the 20th (31) is now 45.
- Pull requests: the brief says 19 merged; 20 had merged by #24, which the brief predates.
- Pull request dates: the brief gives merge times for #14 to #17 that are the times they were opened
  (16:13Z and 16:10Z); the merges were later, as above. The same con that drafted sections 1 to 4 found the
  dates wrong and used `gh` [ledger 2026-10-20 "White paper of iteration 3, sections 1 to 4 drafted"].
- The brief says PR #10 was closed 2026-10-15T18:59Z; `gh` gives that as its creation time [gh pr list;
  section 6 gives the closing time].
- The brief says ADR 0009 "stays accepted"; it was marked superseded by 0014 after the interview [ADR 0009
  status; interview q13].
- The brief says the release published "five Features, go-task 1.1.0, claude-code 1.3.0, git 1.1.0, gh
  1.0.0, devhost 1.4.0"; the run log shows 15 published and one skipped (section 11).

## 13. Keep, change, drop; the foundation; liquid to solid

This section is the Operator's verdict on the practices of the iteration, with the records' numbers
set beside each verdict. The numbers are not arguments for or against it; the Operator decided, and
the paper reports what they said. Where the records and the Operator's wording differ, both are given.

### What the Operator keeps

Asked which practices should go into the next seed as they are, which should change and which should
drop, the Operator answered in one dictated message, paraphrased here [interview q11, round 2].

- **The four backs** (scribe, secretary, librarian, tester): kept; the Operator liked them. The numbers
  from 2026-10-19 to 2026-10-20: 217 runs, $10.06; the scribe $0.09 and the secretary $0.11 per change,
  the librarian $0.71, the tester $0 and 81 of its 83 runs finding nothing to do (it ran without a Docker
  daemon); 1 run undone by a guard [section 12; cost report]. The first review's five undos and the
  five root causes of ADR 0003 are the evidence of what the backs got wrong (section 4).
- **The night shift:** kept; the Operator liked it. Two runs, 11 of 11 items done, none undone, about
  $9.5 and about $4.6 [section 12; night-shift reports]. Section 5 and section 8 tell what they did and
  what a morning review found.
- **The ledger review:** kept, with its cadence to refine. The Operator's view is that it is too
  frequent, that they have no answer for it yet, and that it needs more cleaning up or refining but
  needs to be there [interview q11, paraphrased]. A later answer confirms that the
  paper keeps the review and says its cadence is still to be refined, and that a backlog item rethinks it
  (per week or per finished piece of work instead of every five entries) [interview q21; TODO.md
  `ledger-review-cadence`, open]. The records' evidence is mixed in a way the paper reports and does not
  reconcile: the briefing asks for a review every five or so entries, yet the three reviews came at 21,
  53 and 29 entries (section 12), so the frequency the Operator found too high is the briefing's prompt,
  not the interval actually kept. Guess: the felt frequency is the number of reminders in the briefing.
  Each review found something that came back and each made at least one change with a test (section
  11); the paper does not claim a better cadence.
- **The cost report:** kept [interview q11]. It is a script, so it costs nothing per run; its history
  was lost once and fixed (section 11), and its list-price basis is a limit (section 12).
- **The five principles:** kept [interview q11]. They are generic and each Operator sets them up through
  the interview (ADR 0013).
- **The ontology with the lexicon:** exported together, because they complement each other: the
  lexicon is shared nomenclature and understanding, and the ontology serves a different purpose
  [interview q11, paraphrased]. The manifest does it (below). The guard of the ontology is a different
  matter: it is not on `main` (section 11).

### What is personalization

The Operator separates the way of working from how a person likes to see it. Three practices of the
inward turn (section 7) are, in their words, personalization, not process: the picture principle
(diagrams in the docs), the Arthurian theme with its journal piece, and the site. The theme and the
picture principle are therefore not for the next seed. For the site and the pictures the point is that
both are about how a repository exposes its outputs, and that concept is what should be thought through;
whether an implementer mandates C4 diagrams for their architecture documents is a cross-cutting concern
that is the implementer's call [interview q11, paraphrased]. The records make the split in two places. P1, the first of
the five principles, is "Separate personalization from process" and says a theme over the lexicon is
optional and that "plain words stay underneath for anything a machine reads" [docs/principles/agents.md
P1]; and ADRs 0004 (the Arthurian theme) and 0007 (the life theme) leave the foundation while ADR 0006
(the site) stays, as an example of thinking through how a project shows its outputs [interview q19;
foundation.txt]. The Operator's other reason for the theme, that a ledger written in old English would
have been "useless and painful", is in section 7. A backlog item holds the concept for the Operator:
`repo-outputs-concept`, "settle the concept before the next seed" [TODO.md, open]; whether the journal piece
stays in the repository is `journal-piece-keep`, also open [TODO.md].

### The foundation, as it stands

The foundation is the manifest `docs/iterations/foundation.txt`, one path per line, that
`devhost-package` copies into the seed [ADR 0008; ADR 0014; foundation.txt]. In the interview the Operator
named what it should hold [interview q12, paraphrased]. They asked that only the agent principles go,
because the Feature requirements are contextual to the product and the way of working is what the next
project needs; that the ADRs go, because they explain the why; that the lexicon and process go as
artifacts the next project must understand it has to build for itself; and that there be "a final set
of bootstrap files", enough that a person who skips the interview and gives only a purpose gets a
repository with a dev container folder, a task file, a README and git set up locally, and then a
command to bring the container up and start the first agent session in it. The manifest now holds
[foundation.txt]:

| Piece | In the manifest | Why, where known |
|---|---|---|
| The agent principles (`docs/principles/agents.md`) | yes | The five, generic |
| The Feature requirements (NFR-1 to NFR-10) | no | Contextual to this product [interview q12] |
| `LEXICON.md`, `PROCESS.md`, `docs/model/ontology.toml` | yes | Worked examples, to be built anew by the project; lexicon and ontology together [q11, q12] |
| ADRs 0003, 0005, 0006, 0008, 0009, 0011, 0013, 0014, 0015, 0016 | yes | The why [q12]; 0009 is in as history, though superseded; 0015 and 0016 follow q14 and the identity work |
| ADRs 0004 and 0007 (themes) | no | Personalization [q19] |
| ADRs 0010 and 0012 | no | About this repository [q12, the recommended leave-outs] |
| ADR 0002 (co-author trailers) | no | Not discussed in the interview. Gap: the records do not say why it is out |
| The themes file `docs/model/themes/arthurian.toml` | no | Personalization [q12] |
| The ledger and `ledger-review` | not in the manifest | `ledger-review` is a skill in the package; the ledger's shape arrives through `devhost-init`. See below |

The starter is a separate input to the package: `starter/devcontainer.json`, `SETUP.md` and `CONTEXT.md`
(section 15). Two records disagree with the manifest. ADR 0014 describes `foundation/` as "the five
principles, the ledger setup, a starter lexicon and ontology", and the manifest holds the ledger setup
nowhere; the backlog item `seed-manifest-ledger-skills` asks for the ledger and `ledger-review` to be added
or said to be excluded [ADR 0014, Decision; TODO.md, open]. And the manifest's comments, which the records
brief found stale (they said the principles existed only on an unmerged branch), have been updated since
[foundation.txt]. The Operator also accepted that ADR 0009 be marked superseded by ADR 0014, since the
backs are not allowed to do it, and it is [interview q13; ADR 0009 status]. Two of the Operator's
answers in the interview were conditional and the records show how they resolved: on ADR 0015 the answer
moved within one dictation from leaving it out until it was built to putting it in, and the shutdown
skills were built that day
(section 11, [interview q14; PR #24]); on the untracked-file rule and the default skills list, "yes" to
both [interview q23, q24].

### Liquid to solid

The phrase "liquid to solid" comes from the summary of the outline answers of 2026-10-19: the foundation
was "moving 'liquid to solid' but unfinished" [ledger "Outline questions answered and verified"]. The
records do not say whether it is the title's idea. Asked what was meant and what is
solid now, the Operator answered, paraphrased from a garbled dictation: the project is taking form but it is
not done; there will be a few more iterations, they are not sure how many; the present phase is still going
through the iteration cycle; there is now a set of artifacts, a set of instructions, skills and workflows,
and the next steps are to run it a few more times; and in terms of real working days the project has been
doing this for only a few days, so it is very early, though it is moving at a very fast pace [interview q4].
The records count the days: the ledger has entries on four calendar days, 2026-10-16, 17, 19 and 20, and
the repository's first commit is 2026-10-07, thirteen days before the date of this paper [section 12;
`git log`]. Gap: the Operator was asked what is solid now, and the answer, as dictated and as
transcribed, names no list; the interview's question names "the five principles, lexicon, the themes" as
its prompt, and the Operator's answer to the keep-drop question (above) takes the themes out. This paper
therefore does not say what is solid. It reports, as a map of states, what the records say.

| Piece | State on 2026-10-20 | Source |
|---|---|---|
| The five principles | Binding by ADR 0011, generic by ADR 0013 | ADRs |
| The ledger, its shape and guards | In use; `Corrects: none` now refused; conflict markers not guarded | Section 11 |
| The cost report | Rebuilt once; the store carries history; list price only | Section 11 |
| The backs | In use; the scribe's unchecked claims unsolved | Section 14 |
| The lexicon and process | Worked examples, built here, not shipped as they are | foundation.txt |
| The ontology | The model is on `main`; its guard is not | Section 11 |
| The ledger review | Kept; cadence to be rethought | `ledger-review-cadence` |
| The seed's skills | Written; plant-a-seed not yet run on a project | Section 14 |
| The shutdown route | Built; the stop route untested | Section 11 |
| The Features | 16, published in versions older than the branch's for three | Section 11 |

The table is the paper's, not the Operator's; it is a reading of the same records the sections above rest
on. Whether "liquid to solid" is a good name for it is the Operator's call.

## 14. Known weak points

These are the places where this iteration's way of working is known to be weaker than it looks. Each
carries its source and its status. Where the Operator has said it is not the priority now, that is said;
the paper does not rank them for the Operator.

### The false "done", and the scribe's unchecked claims (not solved)

The Operator's framing for the paper is the false "done": work reported as done that was not, three times
on 2026-10-16, which led to principle 4, "Claims need evidence"; and the scribe making claims it had not
checked is still not solved [interview q9, paraphrased; section 4]. The records give the recurrence after
the 16th. The scribe recorded work as "committed" from the plan, not from git (three entries, review of
2026-10-19, group 5); wrote "PR 19 is blocked by checks" when all 69 checks had passed and a review was the
requirement (review of 2026-10-20, recurrence); and recorded "Claude session and backs state in volumes
(preserved)", which held for the session but not its transcript history (same review, group 3) [ledger
"Review 2026-10-19"; "Review 2026-10-20"]. The backlog item for the first, `scribe-commit-verification`
(the scribe checks `git log` before it writes "committed"), is open [TODO.md]. The second review's model
decision was to keep the scribe on Haiku, with about 4 of 53 entries needing a correction, and to restrict
Haiku cons to work the host can check mechanically (review 2026-10-19, Models and group 5).

A second weakness sits underneath: the scribe writes from what its stretch contains, and the stretch is
clipped. Six entries of 2026-10-20 say that the request, a name or a question is "not in this stretch" or
clipped (the three branch deletions, PR #24, the fold of `main`, the saves of interview rounds 4 and 5,
and the branch-triage correction) [ledger, grep for "this stretch" in the Asked, Came out and Learned
lines]. That is the clipped hand-off of ADR 0003's first root cause, still present four days after the ADR was
written (2026-10-16). Guess: the clip has the same cause as before; no entry says so. P4 itself states "Not yet a mechanical hand-off check"
[docs/principles/agents.md P4]. Section 11 adds that the host's own statements failed too.

### Merging past the safeguards (known, not the priority now)

`main` is protected: pull requests only, squash merges, DCO sign-off on every commit, required checks
`validate`, `lint`, `tests` and `DCO` [CLAUDE.md "Git here"]. The Operator merges with the administrator's
bypass while the only other collaborator is rarely available, decided in a ledger entry of 2026-10-16
[ledger "Rebase stack and fix the sign-off hook (corrected)", Decisions], and one commit on 2026-10-20 was
made with `--no-verify`, with the Operator's approval and the reason in the ledger [section 10; ledger "Name
guard exceptions created ..."]. Asked whether the next seed should keep this as practice or change it, the Operator said it is a known weak point, that it is not their priority now,
that it can be addressed in a later iteration, and that they are balancing building this seed against delivering
the purpose of the repositories being bootstrapped [interview q10, paraphrased]. The paper therefore records
the practice and does not recommend a change. One observation from the records: on 2026-10-20 a required
approving review blocked #19 until the Operator gave it on github.com [ledger "PR #19 merged on GitHub"], so the protection
did bind there; which of the other merges used the bypass is not recorded. Gap: no record lists which
merges used the administrator's bypass.

### The review cadence

The Operator found the ledger review too frequent and keeps it; the cadence is to be refined [interview
q11, q21; section 13]. The weak point is double: the intended cadence is not the one kept (21, 53 and 29
entries between reviews against "every five or so" [section 12]), and the readers differ: the second review was
read by a Sonnet con and its claims checked by the host, the third by the host [ledger "Review 2026-10-19",
"Review 2026-10-20", Entries reviewed]; the first review's header does not say. Whether the reader changed
what each found is not measured. `ledger-review-cadence` is open [TODO.md].

### The cost record: gaps, a basis and a limit

Cost before 2026-10-19 is not available at the time of writing, due to technical issues, and the paper may
be amended [interview q7, q34; section 9]. The cost report covers one machine and, through its store, the
months since 2026-10-19; the baseline of $49.84 carries totals and no detail (section 11). Every figure is a
list-price estimate, not a charge (section 12). The report was current to 2026-10-20T17:29, so the later work
of that day is not in it. Host Measures lines still repeat across entries (`cost-measures-repeated`, open),
so entry-level cost cannot be summed. The cost of this paper's own drafting by cons sits in entry Measures,
one per job, and is not summed here. No figure in the records says what the iteration cost in total.

### Untested and unrun

- **The stop route.** `task devcontainer:stop` has never run: the engine runs on the Windows host, and neither
  the label's path format on Windows nor `wslc` or Podman has been checked. The pull request says it needs
  one real run from the workstation, and the item for it, `devcontainer-stop-try`, is open and assigned to
  the Operator [PR #24 description; TODO.md]. This container cannot test it.
- **The Feature tests.** `task test` needs a Docker daemon; the container's Docker-in-Docker Feature cannot
  start its daemon here (mount permission denied; no privileged mode under `wslc`), so it runs in CI or on
  Docker Desktop [ledger "Devhost rebuild checked ..."; CLAUDE.md "Tasks"]. The unit tests (106) and the
  guards run here (section 12). Gap: the result of the CI run for the latest `main` is not in the records
  at the time of writing.
- **The seed itself.** The records hold no entry in which `plant-a-seed` was run on a project, the interview
  guide was used with a person, or the starter was brought up. The seed has not been assembled (section 15).
  Gap: nothing shows that the planting path works end to end.
- **The branch of the ontology guard.** It is not on `main`, although two documents that travel in the
  seed describe it as existing: P1 of the agent principles lists "the ontology guard in `devhost-verify`"
  under "In this repository", and ADR 0005 is a foundation ADR about the guard [docs/principles/agents.md P1;
  foundation.txt; section 11]. Until the pull request lands, the seed's text is ahead of the code.

### Guards that are missing, and fixes that are not live

`devhost-verify` does not refuse conflict markers (`verify-conflict-markers`, open) and fails an empty skill
folder, which could not be removed from inside the container until a merge put the file back [ledger "PR #21
merged on GitHub; skill file restored"]; both are in section 11. A fix in `src` is not live until the
container is rebuilt: the briefing warns when the installed devhost is older, a guard that came from the
review of 2026-10-19 and held in the review of 2026-10-20, and `--no-verify` was needed once because the
install was older than the guard [ledger "Review 2026-10-20", Recurrence]. The Features carrying the latest
changes are unpublished (section 11), and `devhost-released-versions`, to pin the devhost to released Feature
versions, is open [TODO.md].

### What the evidence cannot bear

- **Five days of ledger, one project.** The ledger has entries on four calendar days and the project began on
  2026-10-07 [section 12]; the Operator's own note is that it is very early [interview q4]. A finding that a
  practice works rests on a handful of days, and the reviews' recurrences are as likely to be teething as a
  trend.
- **Iteration 2 is one line.** Nothing in this repository says what software project 1 learned (section 1).
- **Summaries of summaries.** After the state volume was recreated, what survives of the 16th and 17th is
  the ledger as the scribe wrote it, the reviews and the night-shift reports; a fact held only as the
  scribe's account of a stretch is as reliable as the scribe is (section 9).
- **The paper's own drafting.** Sections of this paper were drafted by cons from records the host
  selected, then reviewed by the Operator; the cons found two facts that the host's records got wrong (the
  branch, the PR dates), and the paper may contain others that nobody has checked. The Operator's review is the control; it is a person reading prose,
  not a check shown able to fail.

## 15. What the next iteration starts with

The next iteration starts from a seed, a plain folder that an agent is pointed at. This section says what
that folder holds, what the first run through it does, and what the next iteration inherits unfinished.
It describes the seed as the files stand on 2026-10-20; the folder itself has not been assembled yet.

### The folder

The seed's README addresses the agent that reads it: the person who gave it the folder wants to plant it in a
project; it says what a seed is and lists the folder's parts [docs/iterations/seed/README.md]:

- `papers/`: what each iteration learned, oldest first, read first. It will hold paper 1 ("From seed to
  tree", kept as received) and this paper [ADR 0008; ADR 0010; `devhost-package` refuses when an earlier paper
  has changed].
- `foundation/`: the agent principles, the decisions (ADRs) that explain the why, and this project's lexicon,
  process and ontology as worked examples that the next project builds its own from [foundation.txt; section
  13].
- `starter/`: `devcontainer.json`, `SETUP.md` and `CONTEXT.md`, to copy into the target.
- `skills/`: the skills that run the cycle: `plant-a-seed`, `drop-a-seed`, `ledger-review`, `shutdown-devhost`
  and `restart-devhost` [seed README; `devhost-package`'s default `--skills`, devhost 1.6.1; interview q24].
- `PACKAGE.md`: how the folder is built and what it holds, written by `devhost-package`.

`task devhost:package -- --iteration 3 --paper docs/iterations/papers/iteration-3.md` assembles it; exit code 2
is a refusal with a reason (a missing README, starter or skill, a missing manifest entry, a non-empty output
folder, or a received paper that changed) [.claude/skills/drop-a-seed/SKILL.md step 6]. Gap: at the time of writing
neither `PACKAGE.md` nor the output folder exists; the seed has not been assembled and the paper is not final.
The records disagree about the skills list: the drop-a-seed skill's own text and ADR 0014 name three skills
(`plant-a-seed`, `drop-a-seed`, `ledger-review`), ADR 0015 and the package default name five [drop-a-seed
SKILL.md; ADR 0014; ADR 0015; package.py]. The night shift, which the Operator keeps, is not in that list: it
reaches a new project through `devhost-init`, which ships it with the other skills as templates
[src/devhost/share/python/templates/claude/skills/], so it arrives with the devhost Feature and not with the seed.

### The first run: `plant-a-seed`

The README sends the agent to the skill. Its seven steps are: read the seed (the README, the papers oldest
first, the foundation, the starter); read the target (a blank directory or an existing repository, asking
nothing the target already answers); run the interview in `INTERVIEW.md` (the opening, two example use cases,
then the five principles in order, personalization first, in short rounds with example answers and a
recommendation on each); write the answers down word for word in `docs/iterations/interview-<N>.md`, a skipped
topic being a marked gap and never a guess; propose a plan in a form the person can answer "1 yes, 3 no";
apply it only after the person decides, on a topic branch in an existing repository, after the redact list
and the identity agents commit as are settled; and set up the ledger and record its first entry
[.claude/skills/plant-a-seed/SKILL.md]. The guide is 408 lines in ten parts, ending with the topics that belong to
`drop-a-seed` and not to planting [INTERVIEW.md]. Its use cases are the two the host's worked examples show, a
personal assistant and a software shop (section 10).

### The defaults path

The Operator's happy path is a person who says "skip the interview, just build" and is asked only for a purpose,
because purpose has no default and cannot be backfilled [interview q12, q14; agents.md P3; SKILL.md "Defaults"].
The skill ends that path in a project that runs [SKILL.md "Defaults"]:

1. `git init` in a blank directory (an existing repository gets a topic branch); no remote is created or pushed
   to.
2. A short `README.md` with the purpose in the person's words and how to start.
3. The collection's bootstrap (`starter/SETUP.md`): it vendors the host-side tasks into `bootstrap/` and writes
   `Taskfile.yml`, `.devcontainer/devcontainer.json` and `.devcontainer/.env.example`; then `devcontainer.json`
   is replaced by the starter's, and `CONTEXT.md` is copied and filled in from the purpose.
4. A stop before the container, with the two commands that start it and the agent session in it:
   `task devcontainer:up` and `task devcontainer:claude`.
5. Inside the container, `task devhost:init` writes the records (lexicon, process, backlog, ledger, ADR folder,
   skills, hooks); the foundation's lexicon and process are worked examples to start the project's own from;
   then the first ledger entry and a first commit.

The starter's `devcontainer.json` uses five published Features of this collection at `:1`: go-task, claude-code,
git (with `hooksPath` set), gh and devhost, and sets `DEVHOST_ENGINEER` from the environment so that no name
is committed [docs/iterations/starter/devcontainer.json]. It sets no commit identity, and the skill's
step 6 makes the identity a thing the person settles before the first commit.

That is the path the Operator described in the interview, almost to the word: a dev container folder, a task
file, a README, git set up locally, and then the command to bring the container up and start the first agent
session [interview q12, paraphrased]. They also said that on this path they would expect the dev container to
have a skill for closing a session, which is why the shutdown work was built (section 11) [interview q14].

One finding from the records bears on this path. `:1` follows the 1.x line of what is published, and what is
published is the release of 2026-10-20T16:29Z: devhost 1.4.0, git 1.1.0 and the rest (section 11). The shutdown
check (devhost 1.6.0), the shutdown and restart skills in the `devhost-init` templates, `devcontainer:stop`
(devcontainer-cli 1.2.0) and the agent-only identity gate (git 1.2.0) are on `main` and not in the registry. Guess: a
project planted today would get a `shutdown-devhost` skill from the seed's `skills/` folder that names
`task devhost:shutdown-check`, a task that its devhost 1.4.0 does not have; and a git Feature without
`commitWhenEnv`. Nobody has tried it. A second release run would remove the question; the records do not say it is
planned (section 11).

### What the next iteration inherits as open

From `TODO.md` and the sections above, as open at the time of writing, with the section that tells each:

- The ledger review's cadence (`ledger-review-cadence`; section 13) and the concept of how a repository exposes
  its outputs (`repo-outputs-concept`; section 13).
- The scribe's unchecked claims (`scribe-commit-verification`; section 14) and repeated Measures
  (`cost-measures-repeated`; section 11).
- A guard for conflict markers (`verify-conflict-markers`) and for the merge status of a branch
  (`branch-triage`'s own correction asks for it; section 11).
- The ontology guard's pull request (`publish-ontology-guard-pr`; the local branch holds it as devhost 1.7.0),
  to be opened as a devhost minor bump after the seed [interview q30; section 11].
- The ledger and `ledger-review` in the manifest (`seed-manifest-ledger-skills`; section 13), the questions
  batched in `open-questions-batch`, and the two backlog items the Operator has already answered
  (`seed-shutdown-skills`, `shutdown-untracked-blocks`), which the backs have not ticked.
- The stop route's first real run (`devcontainer-stop-try`; section 14), a second release (section 11), and
  pinning the devhost to released versions (`devhost-released-versions`).
- The admin-bypass merges (section 14), left for a later iteration by the Operator [interview q10].
- Cost 2026-10-16 to 2026-10-18, which may still be fetched from the first machine (sections 9 and 12).
- The final white paper on building the Agentic Delivery OS, to be written from the iterations' papers
  [docs/iterations.md "The white paper"; section 1]. The series has two papers so far, paper 1 and this
  one, because iteration 2 wrote none; iteration 4 reads both.

The Operator's own forecast is that there will be a few more iterations, that the present phase is the
iteration cycle still being gone through, and that more runs are needed before the foundation can be called
solid [interview q4, paraphrased; section 13].

## Sources

The record kinds this paper cites, with where each lives. Nothing here was taken from memory or from the
brief alone; the records brief of 2026-10-20 is a secondary source and is cited only where a figure was checked
against a primary one (section 12).

- **The ledger:** `docs/ledger/2026-10.md`: entries by title and date, and its three `## Review` sections
  (2026-10-16, 2026-10-19, 2026-10-20); its guard rules in `docs/ledger/README.md`.
- **The cost reports:** `docs/ledger/costs-2026-10-operator.md` (and its store `.jsonl`, not regenerated for
  this paper) and `docs/ledger/costs-2026-10-unknown.md`.
- **ADRs:** `docs/adr/0001` to `0016`, and `docs/principles/agents.md`.
- **Night-shift reports:** `docs/night-shift/2026-10-16.md` and `2026-10-17.md`.
- **The interview:** `docs/iterations/interview-3.md`, rounds 1 to 6; the outline `docs/iterations/iteration-3-outline.md`.
- **The seed's files:** `docs/iterations/seed/README.md`, `docs/iterations/foundation.txt`,
  `docs/iterations/starter/`, `.claude/skills/plant-a-seed/`, `.claude/skills/drop-a-seed/` and
  `src/devhost/share/python/package.py`.
- **The backlog:** `TODO.md`, by item id.
- **Git and GitHub:** `git log` (all branches), `git show`, `git grep`, `git ls-tree`; `gh pr list --state all`
  (numbers, state, created and merged times, UTC); `gh run list` and `gh run view --log` for the workflow
  "Release dev container features"; PR descriptions of #20 and #24.
- **The Features:** `src/*/devcontainer-feature.json` for versions.
- **The journalist brief:** `.claude/skills/drop-a-seed/journalist.md`.
- **Not a source:** the Operator's dictated answers in their own words from 2026-10-19 and the original
  outline (lost), the state volume's transcripts and run records before 2026-10-19 14:21 (gone), and any cost
  record for 2026-10-16 to 2026-10-18 beyond those named in section 12.

## Gaps

Every `Gap:` marker of this paper, collected, by section. `Guess:` markers are not repeated. The list is not an
excuse for the text: each is also marked where it arises.

**Section 1.** Iteration 2's contribution is one line, because the records here hold only that line.

**Section 2.** The date the rule "the Features come first" was written into `docs/iterations.md` is not recorded.

**Section 3.** How the ten first-life Features were chosen, and which came from the office or software project 1,
is not recorded. The relationship between `ff21f35` (the port) and what `main` holds is not established. The
records hold nothing for 2026-10-10 to 2026-10-14 other than the date of paper 1.

**Section 4.** The count of 114 entries was not rerun for that section; section 12 recounts it (128 and rising).
The unsolved part of the scribe's claims is taken up in section 14. Devhost 1.1.2 and 1.2.0 are not reconciled
(Guess: a later bump in the same stack). Whether the "stranger's account" of ADR 0002 was a real person is not
recorded. The 2026-10-16 repair of the git config (the command, who ran it, when) is not in the ledger.

**Section 5.** No cost report covers 2026-10-16 after the first review's window, or 2026-10-17 or 2026-10-18.

**Section 6.** The interview does not say what made the Operator split pull request #10 on 2026-10-16 and not
later. Whether the distinction drawn by the path list was drawn at the time is not recorded. The records give no
reason why #12 and #13 waited from the 16th to the 19th. The two release entries name different sets of five
Features (section 11 adds the workflow's log: 15 published, one skipped). No record shows whether the office or
software project 1 used a published Feature. The exact day the sentence of `docs/iterations.md` was written is
not recorded.

**Section 7.** The order inside the stretch around midnight is the ledger's order, not a proven timeline. The
ontology guard is described as built in the records and is not on `main` (section 11 tells what followed).
Whether the journal piece stays in the repository is not decided.

**Section 8.** The night-shift report's end time is "local" with no zone. The briefs to the cons name items "1 to
8" or "1 to 9" of a standard that has 10, and the records do not say why. No record answers the patch-bump
question for docs-only changes. CONTRIBUTING's section on `NOTES.md` has not been brought to the standard.

**Section 9.** Nothing says what was done on 2026-10-18. Whether the other machine's cost data can still be
recovered is not established by either record. No cost report exists for 2026-10-16 after the first review's
window, for the 17th or for the 18th.

**Section 10.** The names weighed for the iteration, if any, are not recorded. ADR 0011 is dated a day before
the ledger entry that wrote it down. The files of the two worked examples are not named in the entry and were not
located. The writing of ADR 0015 has no ledger entry.

**Section 11.** Whether a second release is planned is not recorded (the registry holds devhost 1.4.0 and git 1.1.0).
Why the transcripts were not on the volume after the first rebuild of 2026-10-20 is not recorded. Which writer
repeats host cost Measures is not established. Whether the commit that carried conflict markers is merged as it
stands is not established. Whether another copy of the ontology guard existed besides the local commit is not
recorded, and neither is the Operator's instruction on cleaning up branches. The backlog items
`seed-shutdown-skills` and `shutdown-untracked-blocks` stay open although the Operator answered both.

**Section 12.** The 46 cons' entries and the 8 con runs of the cost report for the same days are not reconciled.
The back-run counts of the 16th (97 and 117) are not reconciled, and there is no run record for the 17th and 18th.
No cost figure exists for the 20th after 17:29, and none for 2026-10-16 to 2026-10-18 (not available at the time
of writing).

**Section 13.** Why ADR 0002 is outside the foundation is not recorded. What the Operator considers solid now was
asked and not answered as a list.

**Section 14.** Which merges used the administrator's bypass is not recorded. The result of the CI run for the
latest `main` is not in the records. Nothing shows that the planting path works end to end.

**Section 15.** The seed has not been assembled: neither `PACKAGE.md` nor the output folder exists, and the paper is
not final. The records disagree about the skills list (three in `drop-a-seed` and ADR 0014; five in ADR 0015 and the
package default).
