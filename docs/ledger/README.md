# The ledger

The append-only record of what agents did in devcontainer-features: one entry per unit of work.
Since 2026-11 (records-out-of-git, the Operator's decision of 2026-11-04) it is no longer kept in
git. Where the records are now:

| Record | Where | Written by |
|---|---|---|
| The ledger entries | the agentic-register register `ledger`: its live store in the Feature's volume (`/var/lib/devcontainer-features/agentic-register/registers/ledger`), mirrored to the shared folder (`/mnt/cloud-folder/ledger`) | the scribe, each entry signed with its own key (`work` entries), and the cost of each stretch and each back run (`run` entries) |
| The ledger reviews | `/mnt/cloud-folder/reviews/YYYY-MM-DD.md`, one file per review, never replaced | the host, through `/ledger-review` (`devhost-ledger review`) |
| The cost reports | `/mnt/cloud-folder/costs/costs-YYYY-MM-<engineer>.md` and `.jsonl` | `devhost-report` and the briefing |
| The cost history to the cut-over | `/mnt/cloud-folder/costs/archive/costs-history-to-2026-11-04.jsonl`, one cold-storage file, recorded in the register by one entry (its path, size, sha256, period, record count and each source file's sha256) | the host, once (`devhost-ledger archive-costs`); `devhost-ledger restore-costs <archive> <dir>` gives the files back byte for byte |
| The backlog | `/mnt/cloud-folder/TODO.md` | the host and the secretary |

The settings are `DEVHOST_RECORDS_DIR=/mnt/cloud-folder` and `DEVHOST_LEDGER_REGISTER=ledger` in
`.devcontainer/devcontainer.json`; the devhost Feature's NOTES ("Records outside git") say what each
tool does with them.

## Reading it

`devhost-ledger show` prints the ledger as Markdown in the shape the monthly files had (one
`### YYYY-MM-DD <title>` entry with its `- **Field:**` lines, the reviews as `## Review YYYY-MM-DD`
sections between them); `devhost-ledger show --month 2026-11` one month. The briefing, the cost
report, the site and the ledger review read the same view. `agentic-register verify` checks every
signature; `task devhost:verify` runs it at each commit.

## The history in git

The monthly files `2026-10.md` and `2026-11.md` and the cost reports `costs-2026-1*-*.md` and
`.jsonl` were removed from the tree when the records moved; git history keeps them (the last
commit that has them is the parent of the commit that removed this directory's files). Every entry
of the monthly files was imported into the register first, each marked as a backfill with its
source file, line, original date and the SHA-256 of its text (`agentic-register import --markdown`),
the reviews in them were copied to the reviews folder (`devhost-ledger carry-reviews`), and the cost
stores and reports were merged into the cold-storage archive above.

## Correcting an entry

A wrong entry is never edited (the register cannot be edited): a new entry with a `Corrects:` line
naming the date and title of the wrong one replaces it; the scribe writes it like any other.
