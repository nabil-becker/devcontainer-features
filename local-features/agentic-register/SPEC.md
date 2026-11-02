# The agentic register: format, version 2

A register is a shared record that many writers add to at once, none of them trusted, and that
merges without conflicts wherever it is kept. The ledger, one entry per unit of work and per model
run (the record behind the improvement loop, principle P2), is the first register. Others follow
the same format: a backlog, an agent registry, a mailbox. Version 2 adds one thing to version 1:
every entry names its register. This document is the format. Any implementation that passes the
conformance cases in `aof/tooling/test/agentic-register/` is one. Rules use RFC 2119 keywords.

## What it guarantees

| Property | How |
|---|---|
| Lives anywhere | An entry is a self-contained run of bytes. A folder, a git repository, a database or a bucket can carry it. No store is trusted. |
| Tamper-evident | An entry's id is the hash of its exact body. An entry names its parents by id, so changing one entry breaks every link after it. |
| Untrusted writers | Every entry is signed. A reader accepts an entry only from a key the roster allows. |
| Concurrent writers | No central log and no locks. Each key writes its own chain. An entry also names the other entries its writer saw, so together they form a graph, as git's commits do. |
| Merges never conflict | A register is a set of entries. Merging joins two sets: the same result in any order, and duplicates are harmless (a grow-only set). |
| Lying writers are visible | Each key numbers its own entries. Two valid entries with one key and one number are a **fork**. Both are kept and both are reported. Neither is chosen silently. |
| Disagreements are visible | Two entries that correct the same entry are both kept and reported. A person rules on them. |

What it does not guarantee:

- That a store holds every entry. A store can withhold entries. Comparing the heads of two stores
  shows what one lacks.
- That `at` (a timestamp) is true. It is the writer's claim. Order comes from the graph.
- Erasure. An entry cannot be removed without breaking every entry after it. Content that must
  never be kept, such as a name, an email address or a credential, MUST be refused before it is
  signed. Hosts SHOULD put their content guard in front of `add`.

## Terms

- **Entry**: one signed body.
- **Body**: one line of canonical JSON. It is what is hashed and signed.
- **Id**: the lowercase hex SHA-256 of the body's bytes (64 characters).
- **Key**: an OpenSSH Ed25519 public key, written `ssh-ed25519 <base64>`, without a comment.
- **Principal** (`as`): the plain id a key writes as, for example `tooling`, `scribe` or
  `operator-1`.
- **Anchor**: an operator key the reader trusts from its own configuration, never from a store
  (see "Anchors").
- **Roster**: the entries of kind `roster`. They say which keys may write, as whom, and with which
  role.
- **Parents** of an entry: its `prev` (if any) and every id in its `saw`.
- **Ancestors**: the parents, their parents, and so on.
- **Source**: anything that yields entry bytes. It is untrusted.
- **Sink**: anything that takes verified entries. A **store** is both a source and a sink. A
  **view** is a sink only (an index or a rendering) and can be rebuilt from a store.
- **Register**: a name (`[a-z][a-z0-9-]{0,63}`), a **type** and a store. The type says which
  kinds an entry may have and what each kind's `data` must hold (see "Registers").

## The entry

An entry is UTF-8 text:

```
<body>\n
-----BEGIN SSH SIGNATURE-----\n
<base64 lines>\n
-----END SSH SIGNATURE-----\n
```

- The body is the first line, without its line feed. It MUST NOT be longer than 65536 bytes.
- The rest is an SSH signature (OpenSSH `PROTOCOL.sshsig`), in its armour, over the body's bytes.
  The namespace is `aof-register` for version 2 and `aof-ledger` for version 1, so a signature
  made for one version is never valid for the other. The signing key MUST be the body's `key`.
  With OpenSSH, `ssh-keygen -Y sign -n aof-register -f <private key>` signs standard input.
- One body can have more than one valid signature over it. The id names the body. A store MAY
  keep any one valid copy.

### Canonical JSON

The body MUST be exactly the canonical form of its own value, or it is refused (`not-canonical`):

- Object keys sorted (by code point), no duplicates. There is no whitespace outside strings. The
  separators are `,` and `:`.
- Strings are as JSON writes them, with characters outside ASCII written as themselves, not as
  `\u` escapes. Only control characters, `"` and `\` are escaped.
- Numbers are integers only, between -(2^53-1) and 2^53-1, with no fraction, exponent or `-0`.
  An amount of money is an integer of millionths of a dollar (`usd_micro`).
- Every object key matches `[a-z][a-z0-9_]{0,63}`.

This is a subset of RFC 8785 (the JSON Canonicalization Scheme) on which the two agree. Python's
`json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)` writes it.

### The body

| Field | Type | Rule |
|---|---|---|
| `v` | integer | `2` (or `1`, below). Anything else is refused (`bad-version`). |
| `reg` | string | The register this entry belongs to, `[a-z][a-z0-9-]{0,63}`. Version 2 only. |
| `key` | string | The writer's key, `ssh-ed25519 <base64>`. |
| `as` | string | The principal, `[a-z0-9][a-z0-9_.-]{0,63}`. |
| `seq` | integer | This key's number for the entry, from 1. |
| `prev` | id or null | null when `seq` is 1. Otherwise the id of this key's entry with `seq` minus 1. |
| `saw` | list of ids | Other entries the writer saw, for example the heads of the register when it wrote. Sorted, no duplicates, at most 64, and never `prev`. MAY be empty. |
| `at` | string | The writer's clock, UTC, `YYYY-MM-DDTHH:MM:SSZ`. A claim. |
| `kind` | string | `roster`, `work`, `run`, or another kind (below). |
| `data` | object | Depends on `kind`. |

A body with a field missing or an extra field is refused (`bad-field`). A new field needs a new
`v`.

**Version 1** is version 2 without `reg`. A version-1 entry belongs to the register `ledger`, and
only to it. A reader MUST still accept one there, so that a ledger kept before registers stays
valid, and a key's chain MAY continue from version-1 entries into version-2 entries. A writer
MUST write version 2.

### Kinds

**`roster`** changes who may write. Only an operator may write one (`not-operator`).

```
data: { "add":    [ { "key": <key>, "as": <principal>, "role": "operator" | "agent" } ],
        "remove": [ { "key": <key> } ] }
```

Either list MAY be left out, but not both. A key is bound to one principal and one role. A
roster entry that adds a key already added among its ancestors with another principal or role is
refused (`wrong-principal`).

**`work`** is one unit of work:

| Field | Type | Required |
|---|---|---|
| `title` | string, not empty | yes |
| `operator`, `session`, `asked` | string | no |
| `came_out`, `learned`, `decisions`, `decisions_needed`, `for_repository` | list of strings | no |
| `friction` | list of `{ "tag": string, "text": string }` | no |
| `cost` | cost | no |
| `corrects` | id | no: the entry this one corrects |
| `agent` | principal | no: the agent that did the work (the writer may be another, such as a scribe) |
| `item` | string | no: the backlog item's id |
| `pr` | integer, 1 or more | no: the pull request that closed it |
| `started_at`, `merged_at` | timestamp, as `at` | no: the item's first commit, and its merge. `merged_at` is not before `started_at`. |
| `conflicts` | integer, 0 or more | no: merge conflicts and failed tidies met during the item |
| `checks_red` | integer, 0 or more | no: runs of the checks that failed before the merge |

The last seven are the measures of a unit of work. A measure that was not taken is left out,
never written as 0, so a reader can tell "none" from "not measured".

**`run`** is one model run (by the staff, a sub-agent, anything that costs):

| Field | Type | Required |
|---|---|---|
| `member` | string | yes: who ran |
| `model` | string | yes |
| `outcome` | string | yes |
| `cost` | cost | yes |
| `ms` | integer | no: how long it took |

**`merge`** is one pull request landing on the main branch, written once its commit is there (on
the shared remote, never from a local branch), so a check can join the ledger with the branch's
history: a merge rolled back, rewritten, reverted or abandoned.

| Field | Type | Required |
|---|---|---|
| `pr` | integer, 1 or more | yes |
| `merge_sha` | 40 lowercase hex | yes: the commit that landed |
| `patch_id` | 40 lowercase hex | yes: `git patch-id --stable` of its diff, which survives a rebase |
| `merged_at` | timestamp, as `at` | yes |
| `base_sha` | 40 lowercase hex | no: the main branch before it, to tell a revert from a rewrite |
| `corrects` | id | no: the merge entry this one replaces, after a rewrite or a re-link |
| `reason` | string, not empty | with `corrects`, yes |

The work entries a merge closes are found by their `pr` field when needed, never stored here. A
merge entry with `corrects` **supersedes** the entry it names and every merge entry of the same
`pr` among its ancestors (what its writer had seen); a reader flags those `superseded`. The others
are the pull request's **current** merge entries. A reader flags
`merged-twice` on each current merge entry of one `pr` when they name different commits; two that
name the same commit (two writers who both saw it land) are not flagged. A `work` or `merge` entry
whose `corrects` names an entry of another kind is flagged `corrects-another-kind`, and an entry
corrected more than once is flagged `corrected-more-than-once`.

**Cost** is an object with at least one of these:

- `usd_micro`: an integer of millionths of a dollar, at list price.
- `tokens`: a list of `{ "model": string, "input", "output", "cache_write", "cache_read": integer }`.
  The four counts are optional.
- `note`: a string, for example why dollars were not measured.

In the kinds above, a field of the wrong type is refused (`bad-field`). Fields not listed are
allowed and kept, so a later writer can add them without a new `v`.

**Other kinds** are kept and checked like any entry (format, signature, roster, chain), but their
`data` is not checked. A reader that does not know a kind MUST NOT refuse it for that. New kinds
can then spread before every reader knows them.

## Who may write: the roster

The roster is read from an entry's ancestors, so every reader comes to the same answer whatever
order it received the entries in.

For an entry E with key K and principal P:

1. If K is an anchor, it is allowed as the principal the anchor names, with role `operator`. An
   anchor cannot be removed by an entry, only by the reader's configuration.
2. Otherwise K is allowed if valid `roster` entries among E's ancestors add K, every one of them
   as P with one role, and none among E's ancestors removes K. Its role is the role of those
   additions.
3. A key removed among E's ancestors is refused (`removed-key`). A key added among E's ancestors,
   but as another principal than P, or as two different principals or roles (two operators
   adding it at once), is refused (`wrong-principal`). Any other key is refused (`unknown-key`).

A writer's first entry therefore MUST list, in `saw`, the roster entry that added its key, or an
entry that descends from it. A removed key is not re-added: give the writer a new key.

An entry whose key was removed by a roster entry that is not among its ancestors, and which is not
among that removal's own ancestors, was written **concurrently with the removal**. It stays valid
and is flagged `concurrent-with-removal`, for a person to look at.

## Checking an entry

A reader checks each entry in this order. The first failure decides.

1. **Format**: UTF-8, a body line, an armoured signature (`bad-format`). Body size (`too-large`).
   The body is JSON (`bad-format`), an object, with integers only (`bad-field`), and canonical
   (`not-canonical`).
2. **Fields**: `v` (`bad-version`), then every field (`bad-field`). Also `seq` 1 has `prev`
   null and `seq` above 1 does not (`bad-chain`).
3. **Register**: the entry belongs to the register being read (`reg`, or `ledger` for version
   1). An entry of another register is refused (`wrong-register`), so an entry signed for one
   register can never be replayed into another. Then the kind's `data`, as the register's type
   says (`bad-field`).
4. **Signature**: by `key`, over the body, in the version's namespace (`bad-signature`).
5. **Parents**: every parent is known. If one is not, the entry is **held**, not refused: it is
   checked again when the parent arrives. If a parent was refused, so is the entry
   (`refused-parent`).
6. **Chain**: `prev` has the same `key` and `seq` one less (`bad-chain`).
7. **Roster**: as above (`unknown-key`, `wrong-principal`, `removed-key`), and a `roster` entry
   needs the role `operator` (`not-operator`).

The outcome of an entry is one of these:

- **valid**;
- **held**, with the ids it is waiting for;
- **refused**, with one of these codes: `bad-format`, `too-large`, `not-canonical`,
  `bad-version`, `bad-field`, `bad-signature`, `refused-parent`, `bad-chain`, `unknown-key`,
  `wrong-principal`, `removed-key`, `not-operator`, `wrong-register`, `retired-anchor`.

Checks 1 to 4 need only the entry and the register's name and type. Checks 5 to 7 need its
ancestors.

## Reading a register

One register is read at a time.

- **The register** is the valid entries of every source joined together.
- **Order**: a topological order of the graph (parents first). Ties go to the earlier `at`, then
  to the smaller id. Every reader with the same entries gets the same order.
- **Heads**: valid entries that no valid entry names as a parent. A writer SHOULD put the heads
  it knows (other than its own `prev`) into `saw`, up to 64.
- **Reported, not resolved**:
  - `fork`: two or more valid entries with one key and one `seq`, until an operator rules on it
    (below).
  - `concurrent-with-removal`, as above.
  - `corrected-more-than-once`: two or more valid `work` entries whose `corrects` names one entry.

### Forks and rulings

A fork is a key writing two different entries as the same `seq`: a writer that ran twice at once,
or one key used on two copies of a store. Both entries stay valid, because they are both signed.
Until the fork is settled, a writer MUST NOT add to that key's chain (it would not know which side
to go on from), and a reader reports it.

An operator settles a fork with an entry of kind `ruling`, valid in every register whatever its
type: `data: { "keep": <entry id> }`.

- Only an operator may write one (`not-operator`).
- `keep` MUST be an entry that is part of a fork, and the ruling MUST have seen it and another
  entry of the same fork, among its ancestors (`bad-field`). A ruling settles only what its
  writer has seen.
- Once ruled, the fork stays in the register and is reported as ruled. The other entries of the
  fork, and every later entry of that key whose `prev` leads back to one of them, are **ruled
  out**: they stay valid and are flagged `ruled-out`, and they form no further fork with the side
  kept. The key goes on from the side kept.
- A ruling supersedes every earlier ruling on the same fork that it has seen among its ancestors.
  When the rulings no ruling supersedes keep different entries, they are all flagged
  `ruled-twice` and the fork is not settled. An operator who has seen them all rules again.

Forks are taken per key in `seq` order, so a fork found after a ruling counts only the side kept.

### Pruning

A ruled-out line is valid and stays in the history. Sometimes it must not: it holds something
that may never be copied on (a word from a redact list, say). Other writers' entries may already
name it among the heads they saw, so a store that simply leaves it out holds every entry that
depends on it. An operator lets a store leave it out with an entry of kind `prune`, valid in every
register whatever its type: `data: { "ruling": <entry id>, "pruned": [<entry id>, ...] }`.

- Only an anchor may write one: a key in the reader's anchors, not an operator added by a roster
  (`not-operator`). It vouches for entries nobody can check any more, so it rests on the reader's
  own trust.
- `ruling` MUST be a valid `ruling` the prune has seen among its ancestors, and `pruned` MUST NOT
  name the entry it keeps (`bad-field`). `pruned` is sorted, without duplicates, with 1 to 1024
  ids.
- A reader takes the prunes signed by its anchors and reads with them; then, while any of them
  is not valid (refused or held), it reads again without those. A prune counts only as far as it
  is valid itself.
- An entry named by a counted prune MAY be absent from a store. Where it is absent, it is
  **pruned**: an entry that names it as a parent is not held for it, and the ruling the prune
  names counts it, and only what that prune names, as the side of the fork it ruled out (no other
  ruling does: each still has to have seen both sides).
- An entry whose `prev` is pruned is pruned too if a counted prune names it, even if the store
  still has it. If no prune names it, it is refused (`refused-parent`): its chain cannot be
  checked, so a key of anyone's could otherwise hang entries on a pruned line.
- An entry named by a prune and still in the store is read as if the prune were not there. If it
  is ruled out, the reader reports it as still there: it is to delete, and `verify` fails until it
  is. If it is not ruled out, the prune is flagged `prunes-not-ruled-out`, the entry is never
  listed to delete, and `verify` fails until an operator corrects it.
- A writer MUST refuse a prune that names an entry not in the store, not ruled out by the ruling
  it names, or of kind `roster`, `ruling` or `prune` (`bad-field`): a reader cannot check what is
  gone, so the check is made while it is still there. Pruning a roster removal would bring the
  removed key back.
- What a reader cannot check, it takes on the anchor's word. A prune written by other means (by
  hand, by another tool) that names a roster removal, once that entry is gone, brings the removed
  key back, and no reader can tell. That is why only an anchor may prune.
- A sync MUST NOT put into a sink an entry that a counted prune names and that is ruled out,
  when the sink does not hold it: a pruned line is never copied on, so a store that has left it
  out, or a new one, stays without it, whichever copy still holds it.
- The command (`agentic-register prune --ruling <id>`) names everything its ruling ruled out.

`prune` is a kind of every register from this version. An entry of kind `prune` written before
(of some register type's own) is now checked as one.

So the order is: rule; prune, while the line is still in the store; then delete the line. A
reader older than pruning holds what depends on a pruned line; it verifies once it is upgraded.

## Sources, sinks and stores

The format knows nothing about storage. An implementation connects them in one operation:

```
sync(from: source, to: sink): every entry from the source is checked against what the sink
already holds plus what the source gives; the valid ones are put to the sink, parents first.
```

Adding an entry is signing it and syncing it to a store. Merging is syncing one store into
another. Indexing is syncing a store to a view.

A **store** MUST offer:

- `put(id, bytes)`: keep the bytes if the id is new, and do nothing if not. Putting the same id
  twice is safe.
- `get(id)`: the bytes, or nothing.
- `ids()`: every id it holds.

A store SHOULD offer `since(cursor)`, so a reader can fetch only what is new. Any product with
put-if-absent can be a store: a folder of files, a git branch, an object store, a relational or
immutable database. A store is never trusted. Every reader checks every entry it reads.

A **view** is rebuilt from a store at any time. It MUST NOT be read as the source of truth.

A register MAY have a **mirror**: a second store kept level with its **live store** by syncing each
way (the mirror into the live store, then the live store into the mirror). Every reader and writer
uses the live store. The mirror is a copy for somewhere the live store cannot be, such as a git
working tree, where a branch switch or a pull briefly removes files while someone writes.

- A mirror is synced as any source and sink: only valid entries move, nothing is ever removed, and
  a pruned line is never copied on ("Pruning").
- A mirror MUST NOT be the live store itself. A register that is never stored in git (the
  `messages` type) has none.
- One writer syncs a mirror, at the moment its copy is taken (for git: before the records are
  committed), so the copy holds everything written until then. Entries that reach the mirror by
  another way (a merge on the main branch) come into the live store at the next sync.

### A writer's guard

An implementation MAY let an adopter set a **guard** per register: its own check, run by the writer
on the exact body bytes before it signs them, and on each entry another store gives before `sync`
puts it in a sink that lacks it. An entry the guard does not let through is not signed or put, and
nothing that descends from it in the same sync is put. A guard that cannot run, fails or does not
answer refuses. An implementation MAY let an entry that only removes keys from a roster pass
without its guard, so that a guard that fails never stops a key being removed. A guard is a writer's policy, not part of the format: a reader never runs one, an
entry is never refused on reading because of one, and its refusal (`guarded`) is not one of the
outcomes above.

### The change feed

A reader that wants only what is new since it last looked keeps a **cursor**: the heads of the
register as it last read them. The entries new since a cursor are the valid entries that are
neither one of its heads nor among their ancestors, in the register's order. A cursor MUST NOT be
a position in the order. An entry merged in later from another copy can sort before entries the
reader has already seen, and a position would skip it. Heads in a cursor that the reader does not
have are ignored.

`watch` prints the new entries as JSON lines (`id`, `register`, `kind`, `from`, `at`, `seq`,
`data`, and `flags` when it has them), then `{"cursor": "<heads, comma-separated>"}` to pass to the
next `watch --since`. With `--follow` it keeps checking the store and prints as entries arrive.
Every entry it prints has passed every check. A bridge to another protocol (A2A, SLIM) reads this
feed.

## Anchors

A reader's anchors are lines of its own configuration, never read from a store:

```
<principal> ssh-ed25519 <base64> [until=<entry id>]
```

Trust starts at the anchors. Every other key is trusted because an anchor's roster entry, or one
it led to, added it. So:

- An anchor whose **private key is lost** MUST stay. Its public line still checks every signature
  it made. Deleting the line refuses its roster entries (`unknown-key`) and every entry after
  them (`refused-parent`). A second anchor line, for a new key, restores the power to change the
  rosters.
- An anchor whose key is **stolen**, or must no longer be used, is **retired** with
  `until=<entry id>`: the last entry it signed that is trusted (a checkpoint). It is then trusted
  for that entry and its ancestors only. Anything else it signs is refused (`retired-anchor`). The
  history it signed stays valid. A reader that does not have the checkpoint trusts the anchor for
  nothing, and says so.
- A reader SHOULD have at least two anchors, so that losing one key never leaves the rosters
  closed.

An agent's key needs no anchor. When it is lost, an operator adds a new key under the same
principal: what the old key signed stays valid. When it is stolen, an operator removes it in the
same roster entry, and what it signs after that removal is refused (`removed-key`).

## Registers

A register's type gives its kinds. `roster` is the same in every register. Each register has its
own roster, read from its own entries, so being allowed to write one register says nothing about
another. Anchors are the reader's, and the same for every register it reads.

| Type | Kinds | For |
|---|---|---|
| `ledger` | `work`, `run` (above) | one entry per unit of work and per model run |
| `backlog` | `add`, `edit`, `tick`, `reopen`, `move`, `note` (below) | a backlog: changes to items, and the backlog they add up to |
| `agents` | `agent`, `retire` (below) | the agent registry: one record per agent, written by itself |
| `messages` | `thread`, `message`, `invite`, `leave`, `read`, `task`, `status` (below) | conversations and requests between agents and operators; never stored in git |
| `log` | any, with `data` unchecked | records that have no type yet |

### The backlog type

Each entry is one change to one item, named by `item` (`[a-z0-9][a-z0-9_.-]{0,63}`):

| Kind | `data` | Effect |
|---|---|---|
| `add` | `item`, `title` (not empty); optional `owner` (a principal), `outcome`, `source`, `section`, `label` | The item, at the end of the order. `section` defaults to `Items`. |
| `edit` | `item`, `fields`: some of `title`, `owner`, `outcome`, `source`, `section`, `label` | Those fields change. |
| `tick`, `reopen` | `item` | Done, or open again. |
| `move` | `item`, `after`: an item, or null for the top | The item moves to just after `after`. |
| `note` | `item`, `text` (not empty) | A note under the item. |

**The backlog** is what applying the changes in the register's order gives. Two changes are
**concurrent** when neither is among the other's ancestors: neither writer had seen the other's.
Concurrent changes never block each other. A reader MUST flag them, on both entries, only when
they disagree:

| Flag | When | What the backlog shows |
|---|---|---|
| `concurrent-edit` | two concurrent edits set one field of one item to different values | the later in order |
| `concurrent-state` | a concurrent `tick` and `reopen` of one item | the later in order |
| `concurrent-move` | two concurrent moves of one item | the later in order |
| `added-twice` | a second `add` of an item | the first; the second is ignored |
| `unknown-item` | a change to an item never added (or a move after one) | nothing; the change is ignored |

Two ticks, edits of different fields, or edits to the same value are not conflicts. A person
settles a flag by writing the change that settles it.

A register of a type a reader does not know MUST NOT be read as another type. A new type is added
to this table with its kinds' rules, and needs no new `v`.

### The agents type

Each agent describes itself. An `agent` entry is a whole record that replaces that agent's last one:

```
data: { "record": <an OASF 1.1.0 agent record>,
        "aof":    { "principal": <principal>, "theme"?, "owns"?: [paths], "start"?, "model"?, "role"? } }
```

- `record` is an agent record in AGNTCY's Open Agentic Schema Framework, version 1.1.0, so it can
  be published to an agent directory as it is. The register checks its required fields (`name`,
  `version` as semver, `schema_version` = `1.1.0`, `description`, `authors`, `created_at` in the
  form of `at`, and `skills` as objects with a `name`), and the shape of `domains`, `locators` and
  `modules` where present. Fields OASF adds later are kept.
- `authors` MUST hold handles only (`[a-z0-9][a-z0-9_.-]{0,63}`), never a person's name or an email
  address (`bad-field`).
- `aof` holds what OASF has no field for. `aof.principal` is the principal the record describes.

`retire`, `data: { "principal", "reason"? }`, is an agent's statement that it has stopped.

**The registry** is, per principal, its latest record in the register's order. An agent writes only
its own: a record or a retire whose `aof.principal` (or `principal`) is not the writer's principal
is flagged `not-own-record` and ignored. Trust comes from the register's roster: an operator stops
an agent by removing its key. Two different records of one principal written concurrently (one
agent in two manors, each with its own key) are flagged `concurrent-update` on both, and the later
in order shows.

### The messages type

Conversations and requests, in the shape of A2A 1.0 (the Agent2Agent protocol): a message is an
A2A Message, a thread is an A2A context (`contextId`), a request is an A2A Task moving through
A2A's task states. Inside a manor the register is the binding: no agent runs a server. A bridge
carries the same objects over A2A's own bindings outside. Field names are snake_case, as
canonical JSON requires; a bridge maps them one for one (`message_id` to `messageId`,
`context_id` to `contextId`, `task_id` to `taskId`, `reference_task_ids` to `referenceTaskIds`), and
writes each part in A2A 1.0's shape: exactly one of `text`, `data`, `url` or `raw`, with `filename` and
`mediaType` for a file, and no `kind`.
A2A defines no group conversation. Members, sub-threads and references to threads are this
register's A2A extension, named by the URI of this section.

| Kind | `data` | Written by |
|---|---|---|
| `thread` | `thread` (an id), `kind` (`group` or `direct`), `members`; optional `title`, `parent`, `from` (a message's entry id in the parent) | anyone; the writer is a member. A direct thread has exactly two members, the writer one of them, and no parent |
| `message` | `thread`, `message_id`, `parts` (`{kind: text, text}`, `{kind: data, data}`, `{kind: file, name, uri or bytes}`); optional `task_id`, `reference_task_ids`, `reply_to` (a `message_id`), `mentions`, `refs` (`{thread}` or `{thread, message_id}`) | a member |
| `invite` | `thread`, `principal` | a member |
| `leave` | `thread` | the principal leaving |
| `read` | `thread`, `upto` (a `message_id`) | the reader: their read marker |
| `task` | `task` (an id), `thread`, `assignee`, `title`; optional `message_id` (the request) | a member; the task starts `submitted` |
| `status` | `task`, `state` (`working`, `input_required`, `auth_required`, `completed`, `failed`, `canceled`, `rejected`); optional `text` | the assignee, or the task's creator to cancel it |

**What the entries add up to**, in the register's order: each thread with its members (its
writer, its listed members, then invites and leaves), its messages and its sub-threads; each
member's unread count (messages after their read marker, not written by them); each task's state
and history.

- A **sub-thread** names its `parent`, which MUST be among its ancestors (its writer saw it), and
  its writer MUST be a member of the parent. Without `members` it starts with the parent's.
  Unread counts roll up: a member's inbox shows a parent's unread and, separately, what is unread
  in the sub-threads of it they are in.
- A **reference** (`refs`) grants no access: to a reader not in the referenced thread it shows
  only that the thread exists.
- Flagged, and the entry ignored: `not-a-member` (a post, invite, read, task or sub-thread by
  someone not in the thread), `unknown-thread`, `unknown-task`, `not-assignee`, `after-terminal`
  (a status after `completed`, `failed`, `canceled` or `rejected`). Flagged, both kept:
  `concurrent-membership` (an invite and a leave of one principal at once), `concurrent-status`
  (two different states set at once; the later in order shows, except that a terminal state
  always stands over one set at the same time, whatever the order). `after-terminal` applies
  only to a status whose writer saw the task end.

A register of this type MUST NOT be stored inside a git repository. A reader refuses such a store
and says so. Conversations are kept out of the record that is committed; what must last goes
into the ledger or the backlog, and a message can point to it.

## Versions

`v` names this format. A reader MUST refuse a `v` it does not know (`bad-version`). It MUST NOT
guess at the format. Kinds, kind fields and register types grow without a new `v` (above).
Anything else needs one.

| `v` | What changed |
|---|---|
| 1 | The ledger's format. |
| 2 | Every entry names its register (`reg`), and is signed in the namespace `aof-register`. |
