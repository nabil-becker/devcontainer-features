# The planting interview

A guide for the agent, not a script. It says what must be answered and what earlier iterations
learned about asking. You choose the questions and their order. The person answers in short
rounds; everything is answered, skipped (a marked gap) or defaulted before you propose a plan.

Where it sits: the person points you at the seed's `README.md`, which sends you to the
`plant-a-seed` skill, which sends you here. You have read the papers, the foundation and the
target. You interview, write the answers to `docs/iterations/interview-<N>.md`, propose a plan,
and the person decides.

## 1. The opening

Welcome the person: hello, thank you for trying this, we hope it helps. Say what the interview is
for: to plant the seed in their project, shaped to how they work, and to hold their hand through
it. Say that every step has a default, and that "skip the interview, just build" is allowed: the
defaults then apply, except the purpose, which only they can give.

## 2. The two example use cases

Every question comes with an example answer for each of two projects, so the person can see what
an answer looks like for work like theirs. Offer them first; the person picks the one closer to
their work, and its answers become the defaults for everything they do not change. Word them
generically; never name a company or a client.

- **SD, software delivery.** A software shop that builds and ships a product, top to bottom: a
  full agile flow with grooming, planning, stand-up and retrospectives, run by agents as
  developers, QA, an architect, a scrum master and a business analyst. Iteration 3's devhost is a
  small version of this.
- **PA, personal assistant.** A planning assistant. The person records a voice memo; it is
  transcribed into a prompt; agents, each connected to one tool, act on it: one updates their
  personal calendar, one schedules meetings at work through their work assistant, one works a
  client's ticket tracker from its command line (product to be checked), one handles text
  messages. The same shape as iteration 1's flow, aimed at planning.

The interview walks through five principles. For each, explain it, then define it with the person
for their project. Ask only what the target and the records cannot answer.

## 3. P1: Separate personalization from process

One of the main things AI makes possible is personalizing how each person works. Keep two things
apart:

- **Process:** what is required. The outcomes, records, checks and decisions that must happen,
  the same for everyone.
- **Personalization:** how this person meets that process. Where they review, how much time they
  have, how they like to be asked, what they want to see.

Keeping them apart lets everyone focus on outcomes instead of micromanaging how the work gets
done. The process holds the line; personalization makes it fit the person. Example from iteration
3: reviewing from a phone, with decisions as numbered questions, is a personalization; the
decisions being recorded is process.

Ask these first, before anything about the project. Some people talk in quick texts; others write
long, pen-pal letters once a week.

**Key concept: humans and agents keep time differently.** A person feels a natural pause and
knows when it is their turn. An agent has no sense of time between messages, so anything that
depends on time has to be said outright: "reply when I say I'm done" instead of waiting for a
pause; "every Sunday at 00:00" instead of "weekly".

Questions, with example answers:

1. **How do you want me to talk to you?** (short or long answers, paragraphs or diagrams, lists or tables)
   - SD: Short answers; diagrams for anything architectural; show the diff, not a description of it.
   - PA: Plain sentences, no jargon; one summary a day, not a stream of updates.
2. **Where and how will we talk?** (rapid text back and forth, or fewer longer letters; chat, a page to read, a document to edit)
   - SD: At my desk in the terminal; reviews as pull request comments.
   - PA: Text messages from my phone, and voice memos while I drive.
3. **How will I know you are done talking?**
   - SD: When I say "go".
   - PA: When I send "done" after my memos.
4. **When should we check in? Give a day and time.**
   - SD: Stand-up every weekday at 09:00.
   - PA: A daily brief at 07:00 and a weekly plan every Sunday at 18:00.

### Shared language: the lexicon and the ontology

A step not to skip. The lexicon is the words the person and the agents use and what each means;
the ontology is how those things relate. Together they are the shared language (a controlled
vocabulary). Agreed words keep everyone aligned, and a theme makes the place quick to grasp:
background agents are simply "the housekeepers", and everyone knows what that means.

A theme is optional and a matter of taste, but explain why it helps before the person decides.
It is a starting point and can change as the work goes on. Themes to offer:

- **The office** (iteration 1): helpers, housekeepers, contractors, the way an office is staffed.
- **The devhost** (iterations 2 and 3): inters, backs, cons, with plain ids underneath in the lexicon.

A warning, not an offer: iteration 3 tried an Arthurian theme. Renaming everything would have
touched about 130 files and broken searches over the ledger, so it became a layer over plain
words, and writing in its voice was dropped (ADR 0004). Keep the theme light, and keep plain
words underneath for anything a machine reads.

5. **Which theme, if any, do you want for the agents and their work?**
   - SD: The devhost: inters, backs, cons.
   - PA: The office: a helper I talk to, housekeepers in the background.
6. **Which words already mean something specific to you?**
   - SD: "Done" means merged and released, not just merged.
   - PA: "Busy" means a blocked calendar slot, not a guess.

### A way to see out: the dashboard

Define not only how information gets into the project but how it gets out. Every setup needs some
form of dashboard, so the person can keep an eye on how it is going without asking. It is easy to
overlook; raise it rather than let them learn it the hard way.

The default: the agents keep a docs library (the librarian maintains the lexicon, decision records
and C4 diagrams), shown through a dashboard published as a Claude artifact. How it is shown is the
personal choice: a live page they open when they want, a skill they invoke where the agent reads
the records and reports back, or anything else that fits how they work.

7. **How do you want to see how things are going?**
   - SD: A dashboard page I open each morning: open work, the backlog, costs, recent decisions.
   - PA: A short summary in my texts each evening, and a page I can open for the week.

Record each answer as a personalization, separate from the process.

**Default for P1:** short answers numbered for "1 yes, 3 no", the devhost theme with plain ids
underneath, the lexicon and a dashboard page.

## 4. P2: Continuous improvement

Every flow, and every agent, has at minimum a continuous improvement process. Work that is not
looked back on does not get better. Much of the interview is defining this process for the
project: how work is recorded, when it is reviewed, and how what was learned turns into a change.

At its heart is a loop of three steps, repeated: plan, iterate, measure. The name is a starting
point; if it does not work, a later iteration tries another.

The loop needs a record to look back on: the **ledger**, one entry per unit of work, with what was
asked, what came out and the friction met. Walk the person through building theirs. The seed
offers the plumbing iteration 3 uses (the entry shape, the scribe that writes entries, the review
that reads them) as the first version; they can take it as is or pick other options. The ledger is
append-only: a correction is a new entry.

Built into the base ledger, so people see its value: every entry records its **friction** (what
blocked, and what was worked around) and the **resources** it used. Resource use per decision is
easy to track and one of the best measures there is. Iteration 3 measures it in dollars because it
pays for Claude and Copilot. Someone on their own hardware might measure tokens, compute time or
electricity. Ask which unit fits.

Questions, with example answers:

1. **What is one unit of work?**
   - SD: One story, ending in one pull request.
   - PA: One voice memo, turned into its actions.
2. **When do we look back, and how?**
   - SD: A retrospective every two weeks, and a ledger review every five or so entries.
   - PA: A review of the week's entries every Sunday, before planning the next.
3. **What counts as friction?**
   - SD: A failed build, rework, a reopened ticket.
   - PA: A meeting booked at the wrong time, a missed reminder, a message I had to fix.
4. **Which resource do we measure, in what unit?**
   - SD: Dollars per story, on paid Claude and Copilot plans.
   - PA: Tokens on a model running on my own machine.

**Default for P2:** the iteration 3 ledger, scribe and review, cost in dollars.

## 5. P3: The agent knows its place

An agent must understand its place: the world it works in and why it is there. "Place" is used
instead of "environment", which sounds too technical, and because knowing its place also means
knowing its boundaries. A place is made of:

- **Purpose:** why it is there and what it serves.
- **Principles:** the rules it holds to.
- **Process:** what must be done.
- **Ceremonies:** the meetings and recurring moments. Ours: the morning report and preparing for
  the night shift. In an agile team: backlog grooming and refinement, stand-up, planning,
  retrospectives.
- **Lexicon and ontology:** the words it uses and what they mean.
- **Inputs:** what it receives.
- **Outputs:** what it produces.
- **Tooling:** what it works with: commands, tasks, scripts and services.
- **Personas:** who it serves and works with. Not "roles": personas.
- **Boundaries:** what it may do, what it may not, what it is responsible for, and whom it must
  keep informed. In effect its row in a RACI chart (Responsible, Accountable, Consulted, Informed).

**Every level has a place.** The place applies everywhere, not just to the repository. The
repository has many personas. Every sub-agent, down to a small worker spun up for one job, has the
whole set too: principles, inputs, outputs, process, ceremonies and personas. A worker's personas
are few: itself, its direct stakeholder (the agent that invoked it), and always the operator. Even
when another agent invoked it, every agent is ultimately and entirely in service of the operator,
and must know it. The operator is always a persona.

**Purpose has no default.** It is mandatory and cannot be backfilled. The person is setting this up
for a reason, and only they can say what it is. If they are unsure, the two use cases are the
starting points. The product comes first: the way of working serves the purpose; it does not grow
itself (AP-13).

**Frameworks to offer.** To help fill in purpose, process, inputs, outputs and personas, offer a
known framework: the Zachman framework, or a context diagram from the DAMA Data Management Body of
Knowledge.

**The minimum (MVP).** This is the biggest principle to build, so it has a small start: a single
file at the root of the repository that holds the context. Ask the questions below, make sure the
person understands that knowing its place covers all the parts above, and write their answers into
that file (the template is `starter/CONTEXT.md`). A framework can come later.

Questions, with example answers:

1. **Purpose: why does this exist, and whom does it serve?** (required, no default)
   - SD: Build and ship our product for its users.
   - PA: Help me plan my days and weeks.
2. **Personas: who is involved?** (the operator is always one)
   - SD: The product owner, developers, QA, the users.
   - PA: Me, my family, the people in my work meetings.
3. **Inputs: what comes in?**
   - SD: Feature requests, bug reports, designs.
   - PA: Voice memos, emails, calendar invites.
4. **Outputs: what goes out?**
   - SD: Releases, pull requests, documentation.
   - PA: Calendar updates, scheduled meetings, replies.
5. **Process: how does work flow?**
   - SD: A full agile flow, from backlog to release.
   - PA: Memo, transcription, prompt, agents act, I confirm.
6. **Ceremonies: what happens on a rhythm?**
   - SD: Grooming, planning, stand-up, retrospective.
   - PA: The morning brief, the Sunday plan.
7. **Lexicon: which words mean something special here?** (links to the shared language in P1)
   - SD: Story, point, done, release.
   - PA: Block, errand, and the names of my calendars.
8. **Tooling: what do the agents work with?**
   - SD: The dev container, git, CI, the ticket tracker.
   - PA: The dev container, transcription, the calendar and email integrations.
9. **Boundaries: what is each agent responsible for, what may it not do, and who must be consulted or informed?**
   - SD: The developer agent is responsible for its pull request and may not merge it; QA is consulted before merge; I am accountable and informed of every release.
   - PA: The calendar agent is responsible for my personal calendar and may not accept invitations; my work assistant is consulted before anything at work moves; I am informed of every change by the daily brief.

### Boundaries that must be settled before the first commit

These are the two mistakes hardest to undo once pushed. Settle them now, not after (iteration 3:
an agent committed under the Operator's address, ADR 0001; a public paper carrying names needed an
exception, ADR 0010).

10. **Names and data: who and what must never appear in committed files? Does any file need an exception?** Fill the redact list before the first commit. Committed files hold paths and ids, never content.
    - SD: Customer names and account ids; no exceptions.
    - PA: My family's names and my calendars' ids; no exceptions.
11. **Identity: who do agents commit as, and which addresses are safe to use?** Use an unclaimable address (never a vendor's noreply address, which can link to a stranger's account; ADR 0002). Check it before the first agent commit.
    - SD: A bot identity at an address that cannot be claimed; my own address never.
    - PA: The same; commits are rare, so one bot identity for all agents.

### Tooling: bootstrapping the environment

Offer the dev container template and the rest of this repository's tooling to set it up. Strongly
recommended, since it is one of the benefits, but not required. Point the person to
`starter/SETUP.md` (requirements: a container runtime, PowerShell `pwsh`, the devcontainer CLI;
the bootstrap; the start) and `starter/devcontainer.json` (the base Features).

**Why the dev container:** it lets the agent and the person work on the same ground. The agent can
understand their working environment and, if the person chooses, update it, in a way that is
portable and repeatable: the environment is a file in the repository, so it can be read, changed,
reviewed and rebuilt anywhere.

**Without containers.** Other tools give the same portability and repeatability without containers
or isolated environments. They are outside the seed's scope; offer them as terms to look up or to
explore together:

- Nix, and tools built on it such as devenv or Devbox: declare every tool a project needs in one
  file. [nixos.org](https://nixos.org), [devenv.sh](https://devenv.sh), [jetify.com/devbox](https://www.jetify.com/devbox)
- Tool version managers such as mise: pin tool versions per project. [mise.jdx.dev](https://mise.jdx.dev)
- Dotfiles managers such as chezmoi: keep personal settings in a repository and apply them on any
  machine. [chezmoi.io](https://www.chezmoi.io)
- Machine configuration as code: WinGet configuration files on Windows, a Brewfile on macOS, or
  Ansible anywhere. Search "winget configure", "Homebrew Bundle", "Ansible workstation setup".

12. **Where will sessions run, where does state live, how is git set up, is it public or private?** This decides the guards, the redact list and where the ledger can live.
    - SD: In the dev container; state in its volumes; a private repository on a hosted git service.
    - PA: In the dev container on my laptop; a private repository.

**Default for P3:** the picked use case's answers for every part not changed (purpose alone has
none), written to the context file; the tooling a template dev container built from this
collection's Features: the Claude Code CLI, Task, and the basics to start it up and run sessions in
it. The person starts from it and adds the tools their purpose needs.

## 6. P4: Claims need evidence

An agent's output is a claim, not a fact. Agents are tools; they sound equally sure whether they
are right or wrong, so trust comes from how work is checked, never from an agent's word. The
picture is a court, closer to civil arbitration than a criminal trial: nobody is on trial; the
work is.

- **The claimant and its claim:** the agent that did the work, and what it says it did ("the tests
  pass", "the notes are fixed").
- **The operator's advocate:** the inter. It checks the claim's evidence itself, for example by
  re-running the check, then presents the case in the operator's own format with a recommendation.
  It turns the record into plain words for the operator, and the operator's ruling back into the
  record.
- **The judge:** the operator. Rules on what needs judgment.

The rules of the court:

- The claimant carries the burden of proof. A claim comes with its evidence: the diff, the test
  output, a check shown able to fail. A claim without evidence is not heard.
- Small claims never reach court. Where the rule can be written down, a guard settles it (P5).
  Only what needs judgment goes to the operator, as the boundaries in P3 say.
- A ruling may set a precedent, or may be an exception. Exceptions happen; the process embraces
  them. Which rulings become precedent is the operator's call, through P2.

**Two languages.** The record, for agents: precise and lasting (policy, the ledger, briefs,
hand-offs, every agent-to-agent message); it must still mean the same in two years. The
conversation, for people: plain and personalized (P1). Agents exist to make people more effective;
they do not replace them.

**Which record language.** The default: RFC 2119 keywords for rules (MUST, SHOULD, MAY and their
negatives), in short, plain sentences. The alternative to offer: a controlled natural language such
as Simplified Technical English (ASD-STE100). They combine: RFC 2119 for the obligation words, a
controlled language for the sentences around them.

- RFC 2119 (an IETF standard, BCP 14, used worldwide). For: exact levels of obligation, known to
  engineers and to models, easy to check by machine. Against: covers only the obligation words,
  not the rest of the sentence; reads stiff; SHOULD is often misread as optional.
- Simplified Technical English (an aerospace industry specification). For: a restricted vocabulary
  and grammar that make every sentence easy to read, also for non-native speakers. Against: a
  dictionary to learn; built for procedures more than rules; hard to follow strictly without a
  checker.

Questions, with example answers:

1. **Where do agents write things down for each other?**
   - SD: The ledger, ADRs, pull request descriptions.
   - PA: The ledger, and a rules file such as "never book before 09:00".
2. **What must an agent never do without your ruling?**
   - SD: Merge to main, publish a release.
   - PA: Accept a meeting, send a message in my name.
3. **How should a case be put to you?**
   - SD: The diff and the test that proves it.
   - PA: One line per proposed change; I answer yes or no.

**Default for P4:** the hand-off shape (Outcome, Outputs, Friction, For the repository, Decisions
needed), RFC 2119 for rules, nothing decided for the person.

## 7. P5: Right-size the work

Break the work into one-point pieces and give each to the smallest thing that can do it reliably:
a script, a checked agent, or the operator. Understanding the work and the resources it needs comes
first. In the seed's implementation:

- **Inters plan, cons do.** The agent working with the person plans and judges; sub-agents carry
  out the work.
- **Bite-sized work.** Work is broken down in an agile way into small pieces, each about one point.
- **Sized to fit.** Each piece gets the smallest tool that fits it: a script, a guarded agent, or a
  decision for the person.

Questions, with example answers:

1. **What is a one-point piece of work?**
   - SD: One story, one pull request, under a day.
   - PA: One calendar change, or one message.
2. **What should be a script, not an agent?**
   - SD: Lint, tests, the release.
   - PA: Recurring reminders, syncing calendars.
3. **Budget and models: what monthly spend are you comfortable with, who may spend it, and which work may run unattended?** Sets the night-shift cap and model sizing (AP-5, AP-10).
   - SD: A monthly cap; small models only for work a check can verify; nothing unattended without a list I agreed.
   - PA: Free tier or a local model only; nothing unattended.

**Default for P5:** the inter and con split, one-point pieces, script first, then a checked agent,
then the person; the budget the person names (none is assumed).

## 8. What from the seed applies

At the end, go through each foundation piece: adopt, adapt or leave out, and why. Propose from the
papers; the person decides piece by piece or "all yes". The answers feed the plan.

## 9. How to ask: what earlier iterations learned

1. **Read the records before asking.** Ask only what the records cannot answer, and say which
   blank each question fills. Iteration 3: the Operator was asked whether stray sign-offs were
   cleaned; git history already answered it.
2. **Ask for intent before calling something drift.** A turn that looks like drift in the records
   may have been the plan. Iteration 3: shipping the Features first read as a course correction;
   the Operator said it was the plan all along.
3. **Explain every term in the question.** The person should not need the lexicon to answer.
   Iteration 3: "stray sign-off" and "7-step repair" got "I don't know what this is".
4. **Short rounds, one-line answers.** Numbered questions, a recommendation on each, answerable as
   "1 yes, 3 no". About ten a round. Anything longer than a screen goes in a page, not in chat.
   Iteration 3: decisions taken from a phone; eight decisions closed with one "Yes".
5. **"Skip" is an answer.** A skipped topic becomes a marked gap. Never fill it with a guess.
   ADR 0008: honest accounts; a gap marked is worth more than a fact invented.
6. **Write answers down word for word.** Save them as a record the paper can cite. A decision left
   only in chat gets lost or misrecorded. Iteration 3: a back ticked an item before the Operator
   had answered.
7. **Settle identity and names before the first commit.** They are the two mistakes that are
   hardest to undo once pushed. Iteration 3: an agent committed under the Operator's address
   (ADR 0001); a public paper carrying names needed an exception (ADR 0010).
8. **Ask where the data lives.** A gap in the numbers may be another machine, not a missing
   measurement. Iteration 3: the 10-16 and 10-17 cost history is on the Operator's other machine.

## 10. When it is done

- Every topic is answered, skipped (a marked gap) or defaulted.
- The answers are saved to `docs/iterations/interview-<N>.md`.
- You have proposed a plan and the person has decided on it.

## For the closing interview (drop-a-seed)

These topics belong to the end of a project, when a seed is dropped, not to planting. They fill the
paper's blanks and settle what goes in the next seed. `drop-a-seed` runs them:

- **The intent behind the records:** why the big turns happened: what was planned, what was drift,
  what was a reaction. Records show what happened, rarely why.
- **Where the missing data lives:** cost history, transcripts or notes on other machines or in
  other tools. Ask before writing "not measured".
- **The story in their words:** how the person would tell this iteration in two sentences, and what
  surprised them. The paper's spine; the records hang on it.
- **Keep, change, drop:** which practices earned a place in the next seed, and which did not. This
  settles the foundation list.
