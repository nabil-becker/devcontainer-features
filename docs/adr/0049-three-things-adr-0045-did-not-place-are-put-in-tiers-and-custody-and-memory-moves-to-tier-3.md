# ADR-0049: Three things ADR-0045 did not place are put in tiers and custody, and Claude Code's memory moves to tier 3

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-03 |
| **Deciders** | the Operator; proposed by the host session |

## Context

ADR-0045 names four storage tiers and one rule: if losing a machine would lose something, it is in
the wrong tier. While the reference architectures were written, three kinds of storage did not fit
the four lines as written:

- a host-disk folder bound into the container, such as the per-repository Claude home and the gh
  and cloud-provider logins;
- per-machine files kept out of git, such as `.devcontainer/.env` and `.devhost/redact-names.txt`;
- the OpenBao unseal shares and recovery key (ADR-0048), which are the gate to every tier rather
  than data in one.

Checking the first one exposed a real gap: Claude Code's memory lives in that bound folder
(`/var/lib/devcontainer-features/claude-code/projects/*/memory/`), and memory cannot be rebuilt.

## Decision

ADR-0045 stands; this record places the three kinds of storage under it.

```
tier 1  git                reviewed record
tier 2  shared folder      team data
tier 3  personal folder    one person's own data
tier 4  working set        rebuildable only
------  custody            held by people, outside every tier
```

1. **A host-disk folder bound into the container is tier 4.** It survives a rebuild but not the loss
   of the machine, so it is a sturdier working set, not a fifth tier. Only rebuildable things live
   there: logins (log in again) and caches.
2. **Per-machine files kept out of git are placed by whether a task can recreate them.** When a
   task can recreate the file (machine values such as the host type and paths), it is tier 4 and
   the task is the record. When nothing can recreate it (the redact list, personal and sensitive),
   it is tier 3: it is kept in the personal folder and the repository holds only a pointer to it.
3. **The unseal shares and the recovery key are in custody, outside the tiers.** They are held by
   people, because they open the tiers and cannot sit inside one.
4. **Claude Code's memory belongs in tier 3.** It is not rebuildable, so it is not tier 4 even
   though it sits in the bound folder; a copy is mirrored to the personal folder. Until that
   mirror exists it is a known defect against the rule, tracked as a backlog item owned by the host.

## Options considered

### Option 1: place the three kinds under the existing tiers, and name custody

Keeps ADR-0045's four tiers and one rule, applies the rule to each case, and names the one thing
that cannot be in a tier. It also surfaces the memory defect. This wins.

### Option 2: add a fifth tier for the bound host-disk folder

Would name the place, but it holds the same kind of thing as tier 4 (rebuildable) with a better
survival record; a fifth tier would blur the rule. It lost.

### Option 3: leave the three unplaced

Costs nothing now, but each consumer decides alone and the memory gap stays invisible until a
machine is lost. It lost.

## Consequences

- Anything bound from the host disk must be rebuildable; a store that is not is a defect to move up.
- The redact list's home is the personal folder; the repository keeps only a pointer.
- Custody is a word the lexicon and the model carry; the shares and key are never stored in a tier.
- Backlog item (owner host): mirror Claude Code's memory to the personal folder (tier 3). It waits
  for a devhost rebuild that installs the fixed register version.
- ADR-0045 is not edited; this record amends how its tiers are applied.

## Change log

| Date | Change |
|---|---|
| 2026-11-03 | First draft, accepted by the Operator's go on the placements of the same day. |
