---
iteration: 1
project: client engagement (the office)
title: "From seed to tree"
date: 2026-10-14
derived_from: 01-from-seed-to-tree.html
original_sha256: 73cf00fb61717072e34ae06fda35703b7874e34921a95828c18056b5760f8d83
---

> **Derived copy, for agents.** The original is `01-from-seed-to-tree.html` in this folder,
> kept byte for byte as DSNP received it; it wins wherever the two differ. This copy is its
> text only: the seven diagrams of "In pictures" keep their captions but not their drawings,
> and the layout is simplified. Never edit the original.

# From seed to tree: growing an agentic office one friction at a time

We had to learn agentic delivery faster than our clients, so we built a small office of AI agents for our own work and let real friction decide every step.

Nabil Becker, Principal Architect, KGO Solutions

## The quick version

- The problem: we had two needs. We had to learn agentic delivery faster than our clients, and get better at measuring and improving our client relationships. So we built a proof of concept that does the second while teaching us the first.

- The idea: start from one Claude Code session and a log, and add a part only when real work shows it's needed: seed to tree.

- The floor manager (Opus) runs the shared office and hands client work to client execs (Sonnet), with one room per client and one job per brief.

- Bubble up: client execs reply in a fixed shape and pass office problems up, so a fix is made once for every room.

- Three kinds of agent: helpers work with the Operator; housekeepers (scribe, librarian, secretary, mostly on Haiku) keep the ledger, docs and backlog in the background; contractors take one-off jobs.

- Tasks, tests, verify: every action is a named task, and a check at every save refuses anything that breaks the office's rules.

- Ledger and review: every job logs its friction, and reviews turn it into one concrete fix at a time.

- The Operator decides: agents advise. Skills, permissions and exceptions count only when the Operator grants them.

- A night shift works an agreed list overnight, and Markdown becomes one HTML file the Operator reads on a phone.

- Lessons that matter most: size models by blast radius (down to local models for the most sensitive work), enforce boundaries in tooling, test outputs where they'll be read, and give agents a way to see what they make.

- Cost: model usage is small and visible. The largest cost is the Operator's attention.

- Next: room reviews, a security guard, and in time a platform with dashboards, grown the same way.

This file has three parts: the article, in prose; "In pictures", the same story told in diagrams; and "Lessons", the takeaways as a list. Read whichever suits you. The article and the pictures cover the same ground.

## The problem: learn faster than the people who hire you

KGO is a small firm of very technical engineers working with several clients. Those clients now ask us to lead agentic delivery: AI agents on real engagements, not demos. So we have to learn it faster than they do, and that means running agents on real work and watching what breaks.

We had a second need too: getting better at measuring and improving our relationships with our clients. So we built a proof of concept that does the second while teaching us the first. The office's mission is to help measure and improve KGO's client relationships, on a diverse set of our clients. Because the work is real, the lessons are too. How much of the routine could agents carry, and what would it take to trust them with it?

This piece is for KGO colleagues who will lead agentic delivery, and for the people we choose to share it with. Some of us learn from pictures and some from text, so every process is told both ways: in prose here, and in diagrams under "In pictures".

The proof of concept is a few weeks old, and most of it went up in three intense days. It has worked better than I expected, and most of it is still on probation, by design.

## The seed

It started with one Claude Code session in a folder, a short instruction file, and one subfolder per client. The first useful pieces were a draft progress-review method and a local model for some of the work, so sensitive material never left the machine. Everything soon moved into a devcontainer we call "the office". It is the only place the agents work, so they know and control their own environment.

Day one was full of friction. Shared instructions didn't load from inside a client folder, and the first real review run hit eight situations the method didn't settle. That wasn't a reason to design more upfront. It was a reason to write it down, and a log of what each job lacked became the soil everything else grew in.

## How it grew

One rule held throughout: nothing gets added until real work shows it's needed. Each structural choice is an architecture decision record that lists the alternatives we rejected. There are 27 now.

By now the office has three kinds of agent. Here is the map; the rest of this section is how each one came to be.

- Helpers work with the Operator, directly or through another helper: the floor manager, and client execs with their clerks.

- Housekeepers never deal with a person. They do the office's chores in the background after each turn: the scribe, the librarian and the secretary.

- Contractors are one-off helpers, hired for a single targeted job that no skill covers.

Splitting who talks to the Operator from who does the upkeep keeps the Operator's attention, and the helpers' turns, for real work. Each kind also gets the model and the permissions its work needs (see "Size models by blast radius" below). This is where the office stands:

A floor manager. One session working for several clients got muddled. Client context leaked into general decisions, and general fixes landed in one client's folder. So the top-level session became the floor manager. It owns the shared instructions, tooling and process, and it hands client work off.

Rooms and client execs. Each client got a room that holds only what is particular to that client. The floor manager gives one job at a time to a client exec working under that room's notes. A brief goes in, and a fixed reply comes back:

```
Outcome:  two to five lines
Outputs:  paths written
Friction: what this room should fix itself
Office:   items for the floor manager, tagged [tooling], [docs], [skill: new]...
Decisions needed: what only the Operator can decide
```

The Office line is how a room bubbles up problems that belong to the office. They get fixed once, at the top, for every room, and client material stays where it is. This week the first room to use a new shared tool reported its gaps instead of working around them, and the floor manager fixed the tool for every room within the hour.

Housekeepers. Helpers were spending turns on upkeep, and an agent has no clock, so "update the log every few minutes" never fires. So upkeep moved to housekeepers. Each runs as its own headless claude -p process on its own model. The scribe keeps the ledger, the librarian the docs, and the secretary the backlog.

They overdid it at first. Their notices buried my real answers, until I asked: "Can we suppress the housekeeper notifications?" Now notices are quiet context, raised only when I need to act. The secretary once mistook a passing remark for a decision. Another time it tried to edit a line it may only add to, and a guard script undid the edit. When a helper isn't sure a chore will be caught, it leaves a stake:

Stake for the librarian: "floor manager" needs the hand-off to client execs.

Tasks, tests and verify. Scripts piled up, and the documents quoting their paths drifted. So Task (go-task) became the office's single API: about forty named tasks, which I can run as easily as any helper. Bugs kept surfacing in real work, so task test now runs unit tests against a fake office, never against client material. task verify checks the office's rules at session start and on every commit, and refuses a save that breaks one. Every bug fix comes with the test that would have caught it.

Ledgers and reviews. Every level keeps an append-only ledger: what was asked, what came out, the friction, and the decisions. The floor logged 73 entries in its first three days. Every five or so entries, a review turns each group of friction into a backlog item, a decision for me, a change made now, or no action with a reason. Each review starts by checking whether last time's friction came back. Once, an agreed fix had never been applied, so it was reopened.

Skills. At first, every kind of work was meant to start as a skill. I reversed that. Ad hoc work is allowed and logged, and when something recurs, a client exec tags it [skill: new]. A skill is written and ratified only on my word (see "The Operator decides" below), and most of the ten are still unratified. The progress-review skill, for example, grew from one room's practice into cycles, one per meeting, and stages that I set.

A night shift. When I leave, the floor manager proposes backlog items it can finish alone and works through the list I agree. The night rules are strict: floor work only, tests and verify after each item, nothing sent out, nothing decided for me, and a spending cap. In the morning I keep or reject each item. The first design launched a separate unattended agent. Claude Code's auto-mode safety check refused it, so the shift now runs in the session I leave open. The first night finished all seven items using a little over half its cap.

Worktrees. I wanted a merge process so that a helper changing shared tooling can't silently clash with the floor manager. Those helpers now work in their own git worktree and merge back, so a clash shows up as a conflict. The first trial found that the office's git setup, which keeps the history outside OneDrive, sent the worktree's commands to the main copy. A small fix sorted it. Trialling it once, before writing it into the process, is what caught the problem.

Contractors. The first contractor, the reporter, drafted this article from the office's own records, with access set for that job.

## What the Operator reads

Agents write Markdown, and Markdown stays the source. But I wanted to read on my phone, from OneDrive. A first site with one page per document failed on the real device, because the OneDrive viewer downloads a linked file instead of opening it. One self-contained file with an in-page menu worked. So task docs:html renders a set of documents into one HTML file with in-page links and embedded images, and shows raw HTML as text, never running it. Like dbt's single-file docs, you can hand it to anyone. Charts work without scripts, and scripts only add extras. Everything presented to me is rendered this way, and each room renders its own file inside the room.

The lesson: test the delivery surface on the real device before you build the pipeline.

This article tested the pipeline too. The reporter's own friction report noticed absolute folder paths in the file's internal links. That's harmless inside the office, but not in a file you hand out. The pipeline now uses relative paths, with a test. The reporter also drew the diagrams without being able to see them, because the office has no renderer. The floor manager rendered them to images and looked, and caught a clipped label and an unclear subtitle in minutes. An agent producing visuals needs a way to see them, or a reviewer who can. I decided not to build a diagram generator yet.

Material I bring follows the same discipline. Notes and slide decks are inputs, not outputs. The librarian summarises them and names each source, and the client exec checks the coverage and reports any gaps. Once I agree, the raw copy moves to the room's archive. It is never deleted and never rendered.

## What turned out to matter

The Operator decides. This is the principle the rest hangs on. Agents advise, and I decide:

- Open decisions wait in the backlog with a recommendation, and no session settles them.

- A skill becomes standard only when I ratify it.

- A permission or an exception counts only when it comes from me directly, never relayed through another agent.

The agents hold to this. A client exec handed a one-off edit to an append-only record through a delegated brief stopped and asked me, because a brief is not my consent. When wider read access for this article was passed down to the reporter in a message, Claude Code's auto-mode safety check refused the first read that could touch personal data, and the agent didn't look for a way around. That is right. A permission that matters belongs in my own settings.

Exceptions are still possible, but they're mine to approve. The office never writes my name, so these drafts carried a <BYLINE> placeholder that I didn't recognise until I asked. I then had it filled in, only in session drafts that never go into git. Every guardrail needs an exception path its owner signs off. Every placeholder needs a one-line explanation. My own part is small and well defined:

Size models by blast radius. I assumed client execs needed the strongest model, since client work looks hardest. It's the other way round. The floor manager runs on Opus because its mistakes spread: a skill or rule it writes reaches every room and every later job. A client exec does one bounded job under a written skill, and I review it, so Sonnet is enough. Any single job can be raised to Opus. Clerks and most housekeepers run on Haiku.

Below Haiku there is one more tier: local models. Work that doesn't need a frontier model, or whose material should never leave the machine, runs on open models inside the office container. That takes load off the paid models, and the material never leaves the office. Not every step needs a hosted model, and the most sensitive steps are the ones to keep local.

Enforce boundaries with tooling, not trust. Client rooms are never in git and never published. The floor ledger holds paths, never client content, and sensitive material is processed by local models that never send it out. Still, my name crept into the ledgers about a dozen times despite the rule. So a script now strips it from everything the housekeepers write, and the history was rewritten. Even the floor manager slipped. While testing the renderer, it wrote a file into a room, against its own rule that only the client exec writes there, and removed it at once. Rules about who writes where need tooling guards too.

Git is the helpers' safety net for rollbacks, such as undoing a broken skill across many files. I never use it. Its history is kept outside OneDrive, and it has no remote, by design. When I suggested that local history could hold passwords, the floor manager advised against it: history is hard to undo, agents read it, and a platform would add a remote. A security guard is planned. Verify will fail if a remote appears, and pushes will be refused, as will saves containing anything that looks like a secret.

Agents keep their own records, and the records keep them honest. Ledgers, decision records and the backlog are mostly written by agents and read by me. They also expose agent mistakes: helpers have corrected the scribe four times, and the reviews count that.

One office, no copies. We considered templating the office and its rooms. I said no: "We don't want multiple offices. If we already have a process, there's no need to change it." One scaffolding script keeps the rooms in shape.

## What it costs

Every housekeeper run records a metrics line, and a script, not a model, builds the monthly report.

| What | Relative figure |
|---|---|
| Housekeeper runs, first two days | 139 |
| Their total cost | about one night shift |
| Haiku housekeepers vs the Sonnet librarian, per useful change | 20 to 30 times cheaper |
| Librarian's share of the housekeeping bill | close to 90% |
| Librarian runs that changed nothing | over a third |
| Guard undos and helper corrections | 1 and 4, in 139 runs |
| First night shift | whole list, a little over half its cap |

Watch which agent does the expensive work. The librarian's wake threshold went up first, and a move to Haiku will be decided after more runs.

The largest cost is not model usage. It is the Operator's attention: ratifying, correcting, re-deciding. It is falling, but it isn't zero, and it shouldn't be.

## What's next

Near term: room-level reviews, the librarian's model, more review cycles before ratifying the method, the security guard, and rough edges such as an office clock in the wrong timezone. Everything is internal for now. For sharing outside KGO later, the plan is OneDrive links to named people with an expiry date, password-protected HTML for email, and PGP only where the recipient already uses it, parked with a future security officer. Further out, the office will likely grow into a platform with dashboards, when the work asks for it.

## Starting your own

- One Claude Code session, ideally in a devcontainer, with an instruction file and a log. Do real work in it.

- Log what each job lacked, and review every few entries.

- When contexts mix, split them: a floor manager, rooms, and a brief-and-reply contract.

- Move upkeep into housekeepers on small models, with script guards.

- Put every action behind one task runner, then add tests and rule checks.

- Test the output on the real device, and let someone see what agents draw.

## Taking it to clients

What we will take to clients is not a product. It is a way of working they can grow for themselves, built on five principles:

- Start small. One session, a log and real work, not a platform designed upfront.

- Let friction drive the architecture. Each part arrives because a real problem asked for it, and is recorded as a decision with its alternatives.

- Keep the Operator responsible for decisions. Agents advise. The Operator ratifies, grants permissions and approves exceptions.

- Enforce boundaries through tooling. Checks that refuse a bad save guard confidential material, names and secrets. Instructions alone are not enough.

- Measure outcomes. Read cost per useful change, wasted runs, undos and corrections at every review.

The examples will come from our own office and its real work on client relationships, never from another client's material, and we'll be honest that ours is a few weeks old.

The office is still a sapling. Every branch that exists today was earned by a real operational problem, and every new branch will have to earn its place the same way. That is the most useful thing I've learned about agentic delivery so far.

## Tools mentioned

- Claude Code: Anthropic's agentic coding tool. Every helper and housekeeper in the office runs on it.

- Claude models: Opus, Sonnet, Haiku: the three hosted model tiers, sized by blast radius.

- Dev Containers: the open spec behind "the office", the container where all agents work.

- Task (go-task): the task runner that is the office's single API.

- git worktree: separate working copies for helpers that change shared tooling.

- git init --separate-git-dir: keeps the office's git history outside OneDrive.

- OneDrive: where the office's files live and where the Operator reads the HTML.

- Markdown (CommonMark): the source format for everything the agents write.

- dbt docs: the model for the single-file HTML output.

- OpenPGP: planned for external sharing, only where a recipient already uses it.


---

# How it works, in pictures

Some of us learn from pictures and some from text, so every process is told both ways. This page tells the whole story in pictures, and the article tells it in prose. Either one can be read on its own.

Every diagram uses the same shapes. A dark blue pill is the Operator, the person who runs the office. A blue box is a helper, an agent that works with the Operator. A dashed amber box is a housekeeper, an agent doing chores in the background. A blue box with a dotted border is a contractor, a one-off helper; it appears only in the overview, so only the overview's legend lists it. A green square-cornered box is a file or record. Grey dashed panels are places: the office floor and the client rooms.

## 1. The office at a glance

One Operator, one floor manager, and one room per client, with three kinds of agent: helpers work with the Operator, housekeepers do the chores, and contractors take one-off jobs. The legend here is the full one. Briefs go down to the rooms and office items bubble up. Housekeepers keep the records after every turn, and everything the Operator reads arrives as one HTML file.

## 2. The life of a request

A request becomes at most one brief to one room. The reply always has the same five parts. Nobody spends a turn on upkeep: the housekeepers handle it after the turn.

## 3. The improvement loop

Every job leaves friction in the ledger. Reviews turn it into one concrete change at a time. A test or verify check stops the same problem from coming back.

## 4. From ad hoc to skill

Work is not forced into a skill up front. A skill is written only when the Operator decides a kind of work should be done the same way every time, and it is ratified only when the Operator says so.

## 5. The night shift

The floor manager works an agreed list alone in the session left open. It tests and saves each item separately. Nothing is decided for the Operator: each item is kept or rejected in the morning.

## 6. Markdown to HTML

Agents write Markdown. One task turns a set of documents into a single file that opens anywhere, including a phone. Charts are drawn without scripts, so nothing depends on the viewer running them.

## 7. Where the Operator is in the loop

The Operator's part is seven well-defined moments. Everything between them runs on its own, and every result comes back to the Operator for a decision.

---

# Learnings from the agentic office

The lessons from the article, one line each.

Nabil Becker, Principal Architect, KGO Solutions. Companion to the article "From seed to tree". Each lesson gives what happened, then what to do about it.

- **Grow it from friction.**
  What happened: every part of the office (floor manager, rooms, housekeepers, tasks, tests, night shift) arrived because real work went wrong or got tedious.
  What to do: start with one session and a log, and add a piece only when the log shows it's needed.

- **Log what each job lacked.**
  What happened: the first real review run turned up eight situations the method didn't settle, and those notes became the next fixes.
  What to do: give every unit of work a log entry with a Friction line, and review the log every five or so entries.

- **Separate the shared parts from the client parts.**
  What happened: one session doing everything mixed client context into general decisions.
  What to do: have one manager for the shared parts, one room per client, and nothing shared copied into a room.

- **Put a contract on every hand-off.**
  What happened: a fixed reply shape (Outcome, Outputs, Friction, Office, Decisions needed) let office problems bubble up instead of being fixed locally.
  What to do: define the brief and the reply before you delegate.

- **Pointers, not copies.**
  What happened: shared rules copied into each room drifted within a day.
  What to do: keep one source and let everything else point to it.

- **Keep chores out of the conversation.**
  What happened: helpers spent turns on log entries and backlog upkeep, and timed instructions never fired because agents have no clock.
  What to do: run upkeep as background agents after each turn, on small models.

- **Make background agents quiet.**
  What happened: housekeeper notices buried the Operator's real answer, and questions had to be asked again.
  What to do: deliver notices as context for the next turn, and surface them only when the Operator needs to act.

- **Guard what agents may change.**
  What happened: a background agent tried to rewrite a line it was only allowed to add to, and a script undid the edit.
  What to do: for append-only records, enforce "add only" in code and log every undo.

- **Size models by blast radius.**
  What happened: the Operator expected client execs to need the strongest model, but the floor manager's mistakes spread to every room and later job. So the floor manager runs on Opus, client execs on Sonnet, and clerks and most housekeepers on Haiku.
  What to do: give the strongest model to the agent whose output others inherit, use a mid-tier model for bounded jobs that get reviewed, and raise a single job to the top model when it needs it.

- **Measure the agents.**
  What happened: per useful change, the librarian on Sonnet cost twenty to thirty times as much as the housekeepers on Haiku. It made up close to 90% of the housekeeping bill, and over a third of its runs changed nothing.
  What to do: record cost, outcome and duration per run, build the report with a script, and have every review read it first.

- **The Operator ratifies.**
  What happened: most skills are still unratified, and a client exec stopped when a record exception reached it only through another agent's brief.
  What to do: agents propose and the Operator decides, and "the Operator said so, directly" is the only way something becomes standard or gets an exception.

- **Permissions come from the Operator's own settings.**
  What happened: wider read access passed down through agents was refused by Claude Code's auto-mode safety check when it touched possible personal data.
  What to do: treat that as the system working, and grant sensitive access in your own settings, never through a chain of messages.

- **Enforce boundaries with tooling, not trust.**
  What happened: the Operator's name crept into records despite a written rule, and the history had to be rewritten.
  What to do: use script guards for names, client content and secrets, plus a verify step that refuses a bad save.

- **Keep secrets out of history, even local history.**
  What happened: the Operator suggested that local-only history could hold passwords, and the manager advised against it because history is hard to undo, agents read it, and a remote may come later.
  What to do: refuse secret-like content on save, and fail the checks if a remote appears.

- **One API for the Operator and the agents.**
  What happened: script paths quoted in documents drifted.
  What to do: put every action behind a named task that anyone can run by the same name.

- **Every fix comes with a test.**
  What happened: bugs surfaced only after they hit real work, until unit tests ran against a fake office.
  What to do: write the test that would have caught the bug, and never point a test at real client material.

- **Fit autonomy to what the platform allows.**
  What happened: the safety check refused an unattended overnight agent, so the night shift moved into the session left open, under a cap it keeps for itself. The first night finished 7 of 7 items using a little over half its cap.
  What to do: give unattended work an agreed list, strict rules, a cap and a morning review.

- **Expect renames and simplifications.**
  What happened: roles were renamed twice in one day, and an office template was considered and dropped ("one office").
  What to do: keep a lexicon and a scripted rename, and resist adding machinery for problems you don't have.

- **Budget the Operator's attention.**
  What happened: the largest cost in the first days was the Operator's time spent ratifying and correcting.
  What to do: plan for that time, and expect it to fall but never reach zero.

- **Test the delivery surface on the real device first.**
  What happened: a one-page-per-document site failed in the OneDrive viewer, where links download files instead of opening them. A single self-contained file with an in-page menu worked.
  What to do: before you build a reporting pipeline, open a sample on the device and viewer the reader will actually use.

- **Keep Markdown as the source and render one file.**
  What happened: everything presented to the Operator is now rendered into one HTML file. Links between documents become in-page jumps, and raw HTML is shown, never run.
  What to do: render for reading, keep the source plain, and make the output work without scripts, so scripts only add extras.

- **Let bubble-up do its job.**
  What happened: the first room to use the renderer reported its gaps instead of working around them, and the floor fixed it for every room within the hour.
  What to do: reward reporting over local workarounds, and fix shared tools at the top.

- **Rules about who writes where need guards too.**
  What happened: while testing, the floor manager wrote a file into a room, against its own rule, and removed it at once.
  What to do: back write boundaries with a tooling check, the same way secrets and names are guarded.

- **Trial a mechanism once before writing it into the process.**
  What happened: the first worktree trial showed that the environment variables pointing git at the separate git directory outside OneDrive sent every command to the main copy, and a small wrapper fixed it.
  What to do: run one real trial of any new mechanism, then document it.

- **Isolate agents that change shared tooling.**
  What happened: helpers that change shared tooling now work in their own worktree and merge back, while rooms and housekeepers don't need to.
  What to do: give an agent isolation in proportion to how far its changes reach.

- **Inputs are not outputs.**
  What happened: notes and decks brought for the record are summarised with a named source, checked for coverage, then archived, never deleted and never rendered.
  What to do: keep a clear path from raw input to summary, with the Operator's agreement before anything is archived.

- **Plan external sharing before you need it.**
  What happened: everything is internal for now. The plan for later is OneDrive links to named people with an expiry date first, then password-protected HTML for email, and PGP only where the recipient already uses it.
  What to do: write the sharing ladder down early, and park it with whoever owns security.

- **Write for both kinds of learner.**
  What happened: the Operator asked for flow diagrams of the processes and touch points because some of us learn from pictures and some from text, so every process now has a picture as well as prose.
  What to do: let the prose and the pictures each tell the whole story, so either one can be read on its own.

- **Give agents a way to see what they draw.**
  What happened: the reporter checked its SVGs only as XML and geometry, because the office has no renderer. The floor manager rendered them to images and caught a clipped label and an unclear subtitle in minutes.
  What to do: give a visual-producing agent a renderer, or plan a reviewer who looks. Build a tool for it once diagrams recur.

- **Helpers' friction improves the shared tooling.**
  What happened: the reporter's own friction report spotted absolute folder paths in the single HTML file's links. The pipeline now uses relative paths, with a test, and embeds images.
  What to do: ask every helper to report what the tools got wrong, even in work that succeeded.

- **Guardrails need an exception path, and placeholders need a label.**
  What happened: the office never writes the Operator's name, so the drafts carried a <BYLINE> placeholder the Operator didn't recognise. Once asked, the Operator approved filling it in, only in session drafts that are never committed.
  What to do: give every guardrail an exception the owner signs off, and put a one-line explanation next to every placeholder.

- **Keep the most sensitive steps local.**
  What happened: some of the work runs on open models inside the office container, below Haiku. That takes load off the paid models, and the material never leaves the office.
  What to do: don't send every step to a hosted model, and keep local the steps whose material must never leave the machine.


---

*The original's footer: Generated 2026-10-14 17:01 UTC from markdown. The markdown is the source: edit that and run task docs:html, never this file.*
