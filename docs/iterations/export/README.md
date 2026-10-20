# The seed

You are an agent. The person who gave you this folder wants to plant it in their project.

A seed is the way of working (the Agentic Delivery OS) exported from one finished project so the
next can start from it. It holds what was learned, what is worth adopting and the files to start
with. Planting means: interview the person, shape the way of working to how they work, then set
up a new repository or adapt an existing one.

## What is in this folder

- `papers/`: what each iteration learned, oldest first. Read these first.
- `foundation/`: the pieces worth adopting: the agent principles, the decisions (ADRs) that explain
  the why, and this project's lexicon, process and ontology as worked examples. The person's
  project builds its own lexicon and process; it does not take these as they are.
- `starter/`: files to copy into the target (`devcontainer.json`, `SETUP.md`, `CONTEXT.md`).
- `skills/`: the skills that run the cycle: `plant-a-seed` and `drop-a-seed`, `ledger-review`
  (turning the records into changes), and `shutdown-devhost` with `restart-devhost` (stopping
  and resuming a dev container where agents run in the background).
- `PACKAGE.md`: how the folder is built and what it holds.

## What to do

Run the `plant-a-seed` skill. If your tool has no skills, read `skills/plant-a-seed/SKILL.md`
and follow it; it sends you on to `skills/plant-a-seed/INTERVIEW.md`.

In short: read the papers and foundation, read the directory you were started in, interview the
person in short rounds, save their answers word for word, propose a plan, apply it only after
they decide, and end by recording the first ledger entry. If they say "skip the interview, just
build", use the defaults; their purpose is the one thing you must still ask.
