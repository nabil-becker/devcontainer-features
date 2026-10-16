# Proposal: a King Arthur theme for the way of working

Status: accepted 2026-10-16 as option A, a layer, trimmed to ten names (LEXICON.md, "The Arthurian layer"); no committed output speaks in the voice: the journal stays in plain words because it is part of the project's iterations (the Operator, 2026-10-16). No name in the repository has changed.

The office generation was themed as an office; this devhost generation has its own words (LEXICON.md). The next generation is themed on King Arthur. This page maps the words, costs two ways of adopting it, and recommends one.

## 1. The mapping

| Today | Arthurian | Why it fits | Caution |
|---|---|---|---|
| The Operator | The King (Arthur) | Owns the realm, decides, ratifies; sessions advise | Keep "the Operator" in all committed text (name guard, no personal names) |
| Engineer | Knight of the realm | Anyone who works the repository with their own sessions | Not the same as a con (see below) |
| Host (main session) | Merlin | The strong counsellor beside the king: advises, briefs, shapes what others inherit | Merlin does not rule; the host proposes and the Operator decides, which suits |
| Inter | Squire or herald | Works with a person, directly or through the host | Weak image; keep "inter" |
| Con (by job) | Knight on a quest | Briefed once, sent out with a scope, returns with one report | See kinds below |
| Con: search or read-only | Scout or ranger | Looks, changes nothing | |
| Con: draft or port | Knight-errant | Sent to do a thing and come back | |
| Con: worktree job | Knight on a distant quest | Works away on its own branch; its work returns as a merge | |
| Con: reviewer | Questing knight sworn to report | Reads code it did not write | Optional |
| Back (background agent) | Household of the castle | Never meets the king, keeps the castle running | "Back" is plain; a collective noun helps, one per role below |
| Scribe | Scribe (or Chronicler) | Already the right image; keeps the ledger | Keep the name |
| Secretary | Seneschal | Steward who keeps the realm's list of duties | Seneschal is obscure; "Steward" is clearer |
| Librarian | Keeper of the Archive (Grail-keeper is wrong) | Keeps the lexicon and ADRs, the settled law | Not "Grail keeper": the Grail is an unreachable goal, not a store |
| Tester | Armourer, or the Watch | Proves the gear holds before the knights ride; no model | "Armourer" fits a suite; "the Watch" overlaps with guards |
| Journalist (proposed) | Bard | Narrates the story of each iteration | Bards sing, so the output is a story, not a record; the scribe stays the record |
| Stake | Pennant or token left at the gate | A plain marker left where the back will see it | "Stake" is already short; a pennant is a flag on a lance, not a request. Alternative: **Petition** (the king's court hears petitions) |
| Quiet notice | A whispered word, or a page's message | One line at the next turn, never loud | "Whisper" is the best fit and also short |
| Ledger | The Chronicle | Append-only record of deeds | Keep "ledger" for the file; "chronicle" as the synonym |
| Entry | A deed (in the Chronicle) | One per unit of work | |
| Ledger review (`/ledger-review`) | The Round Table | Equals sit, read the record, resolve each group into one action | The Round Table has no head, but the Operator decides; keep the decision with the king |
| ADR | A decree or Charter | Settled reasoning, kept | "Charter" over "Decree" (the Operator ratifies, ADRs record) |
| Lexicon | The Codex | The book of the realm's words | |
| Backlog (`TODO.md`) | The Quest board | Open quests waiting for a knight | Ties to cons: a backlog item taken becomes a quest |
| Backlog item | A quest | One thing to be done | |
| Decision for the Operator | A matter for the throne | Only the king rules on it | |
| Amend item | A correction to the rolls (Rewrite of the rolls) | A person changes the record by hand | Plain "amend" is clearer; keep it |
| Night shift | The vigil | A watch kept while the king sleeps | A vigil also means a knight's night of prayer; fits well |
| Morning report | The audience at dawn | The king hears what happened and keeps or reverts each deed | |
| Briefing | The council at dawn | What the host is told at session start | Do not make this "the audience": two dawn images |
| `/close-session` | Dousing the torches / the closing of court | End-of-day checklist | |
| Guards (back guard) | The portcullis | Undoes a back run that changed what it may only add to | |
| Guards (`devhost-verify`, pre-commit) | The castle watch or the gate | Checks everything that tries to enter the record | "Guard" is already Arthurian; keep, and say the watch is `devhost-verify` |
| Name guard | The herald of anonymity (the herald who strikes names) | Replaces names with "the Operator" | Cute but unclear; keep "name guard" |
| Cost report | The Treasury roll | What each knight cost, by model | Fine as a synonym |
| Hand-off shape | The returning knight's report | Outcome, Outputs, Friction, For the repository, Decisions needed | |
| Model sizing | Mount and armour by the quest | Strongest where others inherit; smallest for chores | |
| Workstation | The wider realm | Outside the castle walls | Keep "workstation": the word is used in commands |
| Devhost | Camelot | The environment where the court sits and the backs act | |
| Worktree | A far castle | Separate checkout on its own branch | |

Where the image would mislead: the Grail for the librarian (a quest, not a store); the Round Table for any standing body (it implies the Operator is one voice among equals, but the Operator decides); Excalibur or the Lady of the Lake for the guards (magic, not checking); "Lancelot/Mordred" for anything (a betrayer or a failed knight cannot be a role).

## 2. Layer or rename

| | A: a layer | B: a rename |
|---|---|---|
| What changes | LEXICON.md gains an "Arthurian" synonym column; skill and back descriptions and quiet notices speak in voice; ids, paths, task and file names unchanged | Every word in the table replaces the old one in documents, skill names, job directories, entrypoints, tasks and consumer templates |
| Files touched | About 4 to 8: LEXICON.md, PROCESS.md, `CLAUDE.devhost.md` template, the four skills' descriptions, the scribe brief | About 130 files (see counts) |
| Code touched | None; only prose and voice | Job directories `src/devhost/share/jobs/{scribe,secretary,librarian,tester}`, `entrypoints/`, `run-job.sh`, `lib.sh`, Taskfile, hooks in `.claude/settings.json`, tests |
| Consumers | Adopt in a release: new template text only | Both consumers re-run `devhost-init` against renamed templates; their own prose and hooks break until updated; every consumer-facing id that moves is a migration |
| History | Ledger and ADRs stay valid | The ledger is append-only: its entries keep the old words, so every query for "scribe" misses the past (the review, the briefing and the guards read them) |
| Reversible | Yes, delete the voice | Hard: renames spread to consumers and tests |
| Muscle memory | Low: old words still work | High: `devhost-verify`, `devhost-briefing`, `/ledger-review` change |

### Cost, by real references

Counts are files that contain the word (case-insensitive, whole word) in the tree, excluding `docs/ledger/`; "templates" is the part shipped to consumers in `src/devhost/share/python/templates`.

| Word | Files | In templates | Ledger files |
|---|---|---|---|
| scribe | 32 | 8 | 4 |
| secretary | 24 | 5 | 3 |
| librarian | 23 | 5 | 2 |
| tester | 24 | 4 | 3 |
| con / cons | 35 | 7 | 4 |
| back / backs | 75 | 9 | 4 |
| inter / inters | 18 | 4 | 3 |
| stake / stakes | 23 | 4 | 3 |
| quiet notice | 8 | 2 | 0 |
| briefing | 32 | 8 | 4 |
| guard / guards | 43 | 8 | 3 |
| night shift | 21 | 5 | 1 |
| host | 94 (includes the unrelated "host" in devcontainer wording) | 5 | 2 |

Commands carry the words too: `devhost-briefing`, `devhost-report`, `devhost-verify`, `devhost-adr`, `devhost-init` appear in 47 files. Four job directories and nine entrypoints under `src/devhost/share/` would move. Four skills are named (`close-session`, `ledger-review`, `new-adr`, `night-shift`).

A full rename would also make "host" ambiguous again (Merlin versus the workstation outside the container), and "con" (knight) and "back" (household) lose their pair-with-inter logic, which the lexicon was built around.

## 3. Recommendation

**Option A, the layer, starting with synonyms in LEXICON.md and one back in voice.** The theme is for the Operator's reading and the ecosystem's feel; none of the current words is wrong, and a rename costs about 130 files, two consumers and a split between old and new in an append-only ledger, for no change in what the system does.

A trial:

| Step | What | Measure |
|---|---|---|
| 1 | The scribe's quiet notice and ledger-entry voice in the chronicler register (headings and entry fields unchanged) for one week | The Operator's reading: is it clearer, funnier, or noise? |
| 2 | LEXICON.md gets an "Arthurian" synonym line per term (additive, the librarian's chore) | Does a reader find it useful, or skip it? |
| 3 | If kept, the night shift report in voice (the vigil, the dawn audience) | Morning read time |
| 4 | Decide at the next ledger review: keep, extend to more backs, or drop | Operator's verdict; a Review section records it |

Guards: the voice must not enter the machine-read parts (entry field names, `Corrects:`, ids), so the verify checks and cost parsers keep working.

## 4. Open questions for the Operator

1. Layer only (A), or is a full rename (B) wanted for the next generation? If B, is it a new repository generation rather than a rename here?
2. Is "the Operator" kept in committed text, with the King only a synonym in chat voice?
3. Secretary: Seneschal or Steward? Tester: Armourer or Watch? Stake: keep, or Petition?
4. The journalist back (see the open backlog item on its proposal): is it the bard, and does it exist alongside the scribe or replace part of its job?
5. Do the consumers (the office and DSNP) take the theme, or only this repository?
6. Should the voice appear in notices the Operator reads (the quiet notice) or only in documents?
