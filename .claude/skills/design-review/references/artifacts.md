# The six standard boards: skeletons

Each board: a title (`<Subject>: <artifact>`, size title), a takeaway of at most ten words (size
large), a "current as of <date>" line, then sections top to bottom, and a link card back to the
State board under the title (the State board instead links to the other five). Keep a board within
about 1,500 wide and, when it is first made, about 750 high; sections are added below, never beside
the right edge.

## State of the architecture (the entry point)

```
 title · takeaway · current as of
 ┌ Accepted / built (green) ┐ ┌ In progress (peach) ┐ ┌ Next (white, numbered, arrows) ┐
 │ one card per decided or   │ │ one card per open   │ │ the order of work, one card     │
 │ built element             │ │ item, its PR         │ │ per step                        │
 └───────────────────────────┘ │ Waiting on you:      │ └─────────────────────────────────┘
                               │ calls + recommendation│
                               └──────────────────────┘
 Decision <call>: options side by side, the chosen one green (when a call needs explaining)
 The other standing boards: five link cards
```

- One card per element: bold name, then one short line. Accepted cards say what was decided, not
  how it was argued.
- "Waiting on you" is the only place open calls are listed. Empty is good: say "Nothing waiting".
- A decision section (explaining one call) sits under the columns: the inputs on the left, the
  options as cards on the right, a closing line in plain words. After the ruling: chosen green
  with "decided <date>", the others white with "not chosen", the closing line rewritten.

## C4 models

Two sections side by side: **Context** (people top, the system blue/green in the middle, stores and
neighbours below) and **Container** (the parts inside, a line of steps, the main flow). Show the
example values a person recognises (a source named "HTTP / REST", not `registry-source-http`).
Notes as a short bullet list under the container. Built parts green, later parts peach with
"later". Leave out what does not help (OpenBao, the launcher) unless the review is about them.

## Workflows

One lane (section) per flow, steps as boxes left to right with arrows, at most five steps per lane
(a longer flow continues on the next row from the left). Lanes stack downwards with a title each:
"1 · Session start", "2 · You add a preference", "3 · A layer owner changes their layer". A lane
can be "expanded" into its options or rules in a section directly under it. Rules that apply to
all lanes go as a short list at the bottom.

## Lifecycles

One section per thing that has states. States as pills in a line, the main path left to right;
loops and failures as dashed arrows back, labelled with what causes them ("a layer changed").
One or two lines of notes to the right. Mark proposed states peach.

## Data flows

Trust zones as sections (outside the container, the container, the shared folder, GitHub).
Sources on the left (one database-shaped box each), the processing in the middle, consumers on the
right. Label arrows only where the meaning is not plain ("read-only mount"). A trust line at the
top of the container zone. Notes (offline behaviour, what is never committed) at the bottom.

## Data inventory and models

A table first: Data | Where | Source | Tier | Sensitivity | Lost with machine? Then the model as
boxes with fields one per line and labelled arrows ("holds 1..n", "merged into"). Further sections
only for what the review decided about data (a mapping to a familiar system, a namespace); each
decided alternative collapses to one "Decided: ..." line once ruled.

## Colours (every board the same)

| Colour | Means |
|---|---|
| green | built, accepted, decided |
| peach | in progress, later, a catch or risk |
| white | neutral, not chosen |
| blue | one highlight per board, named in the board's text (e.g. "blue = picked by the pattern") |

Never more than four. A colour means the same thing on every board of the review.
