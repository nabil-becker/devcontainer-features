# ADR-0045: Four storage tiers govern where data lives, and losing a machine must lose nothing

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-03 |
| **Deciders** | the Operator; proposed by the host session |

## Context

The ledger is moving onto the register with a mirror outside git (ADR-0043), and the records
follow it out of the tree. That raised the general question of where each kind of data belongs.
Today the answer is scattered: git holds code and records, a cloud folder holds `TODO.md`, Feature
volumes hold state and keys, and a personal folder exists that no Feature should touch.

This repository is a public project that its contributors' organisations contribute to, not an
organisation's own project. A rule for where data lives must therefore be generic: any consumer
maps their own storage onto it, and nothing here names an organisation, its staff or its folders.

## Decision

Data lives in one of four tiers, and each tier has one purpose:

```
tier 1  git              the reviewed record: code, ADRs, frozen ledger months
tier 2  shared folder    the cloud-folder mount (/mnt/cloud-folder): the register mirror, TODO.md
tier 3  personal folder  the Operator's own path: never mounted in the devhost unless asked
tier 4  working set      Feature volumes (register store, keys), scratch: rebuildable only
```

The rule: **if losing a machine would lose something, it is in the wrong tier.** Tier 4 holds only
what can be rebuilt or re-fetched; anything that cannot be is promoted to tier 1 or 2.

The cloud-folder product is only the implementation of tier 2 (OneDrive today); a consumer may use
another. The register mirror lives in tier 2. Tier 3 is a separate personal path and is not
the mirror's target. The tiers are written generically; a consumer's own mapping stays in the
consumer's repository.

## Options considered

### Option 1: four generic tiers with one rule

Names the purpose of each place and gives one test to apply. It fits a public repository and tells
the ledger move (ADR-0043) where its mirror goes. This wins.

### Option 2: a rule tied to one organisation's folders

Would be concrete, but this is not that organisation's project; it would leak names into a public
repository and fit no other consumer. It lost.

### Option 3: no stated tiers, decide per record

Nothing to write, but every move such as the ledger's reopens the question and a loss shows up only
after it happens. It lost.

## Consequences

- The register mirror target (`/mnt/cloud-folder`) is already in the right tier; nothing about
  ADR-0043 changes.
- A new store (a register, key, cache) states its tier; anything in tier 4 that cannot be rebuilt
  is a defect to move up.
- The personal tier stays out of the devhost's mounts by default.
- The tier names enter the lexicon, and the consumers map their own storage onto them.

## Change log

| Date | Change |
|---|---|
| 2026-11-03 | First draft, accepted by the Operator's decision of the same day (`storage-tiers-adopt`). |
