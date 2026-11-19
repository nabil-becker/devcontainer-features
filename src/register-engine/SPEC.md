# The register engine: format, version 2

A register is a shared record that many writers add to at once, none of them trusted, and that
merges without conflicts wherever it is kept. This is the format the register engine reads and
writes (AOF ADR 0028), the same version 2 that agentic-register wrote: every register it kept reads
here unchanged. What each register type adds (its kinds, what they add up to, how they show) is
its capability Feature's: agentic-memory (the ledger, the backlog), agentic-communication (the
messages), agentic-trust and agentic-agents. Rules use RFC 2119 keywords.

An entry is a **packet** of the sign-packet Feature (AOF ADR 0024): its bytes, canonical JSON, the
body's fields, the checks of format, fields, signature, parents and chain, the order, forks and
the vouched-absent rule are in [sign-packet's SPEC.md](../sign-packet/SPEC.md), and are not
restated here. A register is the packets of one domain, the register's name. This document says
what the registers add: kinds, the roster, anchors, rulings, prunes, stores and register types.

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
- **Principal** (`as`): the id a key writes as, for example `tooling`, `scribe` or `operator-1`.
  An agent or a staff member also names the running instance it writes from, after one `@`: that
  instance's GUID (`scribe@3f2b9c1e-7a4d-4e8b-9c2a-5d6e7f8a9b0c`; sign-packet's SPEC.md, "The
  instance"). An operator, a person who signs for every stack they run, stays plain (the
  operator's D38 and D93; sign-packet 0.4.0 and later read it).
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

An entry is a sign-packet packet (sign-packet's SPEC.md, "The packet"): one line of canonical
JSON, its body, then an SSH signature over it in the namespace `aof-register` (`aof-ledger` for
version 1). Its id is the SHA-256 of the body. One body can have more than one valid signature;
the id names the body, and a store MAY keep any one valid copy.

### Canonical JSON

As sign-packet's SPEC.md, "Canonical JSON". An amount of money is an integer of millionths of a
dollar (`usd_micro`).

### The body

The fields are sign-packet's (SPEC.md, "The body"). What the registers make of them:

| Field | In a register |
|---|---|
| `reg` | The register's name: the packet's domain. An entry of another register is refused (`wrong-register`). |
| `as` | The principal. The roster says which keys may write as which principal (see "Who may write: the roster"). |
| `kind` | One of the register type's kinds, or `roster`, `ruling` or `prune` (see "Kinds"). |
| `data` | What the kind says it holds (see "Kinds"). |
| `saw` | The register's heads the writer knew, which are entries of the same register. |

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

A reader checks each entry in this order. The first failure decides. Checks 1, 2, 4, 5 and 6
are sign-packet's (its SPEC.md, "Checking a packet"); 3 and 7 are the register's.

1. **Format** (sign-packet).
2. **Fields** (sign-packet), then the data of `roster`, `ruling` and `prune` (`bad-field`).
3. **Register**: the entry belongs to the register being read (`reg`, or `ledger` for version
   1). An entry of another register is refused (`wrong-register`), so an entry signed for one
   register can never be replayed into another. Then the kind's `data`, as the register's type
   says (`bad-field`).
4. **Signature** (sign-packet).
5. **Parents** (sign-packet): a missing parent holds the entry; a refused one refuses it
   (`refused-parent`). A parent a counted prune vouches for is not waited for (see "Pruning").
6. **Chain** (sign-packet, `bad-chain`).
7. **Roster**: as above (`unknown-key`, `wrong-principal`, `removed-key`), and a `roster` entry
   needs the role `operator` (`not-operator`). An anchor retired at a checkpoint signs nothing
   after it (`retired-anchor`; see "Anchors").

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
- **Order** and **heads**: sign-packet's (its SPEC.md, "Reading packets"). Every reader with the
  same entries gets the same order.
- **Reported, not resolved**:
  - `fork`: two or more valid entries with one key and one `seq`, until an operator rules on it
    (below).
  - `concurrent-with-removal`, as above.

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
- The prune command of a capability Feature (`prune --ruling <id>`) names everything its ruling ruled out.

`prune` is a kind of every register from this version. An entry of kind `prune` written before
(of some register type's own) is now checked as one.

A counted prune's `pruned` is what sign-packet calls vouched absent (its SPEC.md, "Vouched
absent"): the rules above for a pruned parent and a pruned `prev` are that rule.

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
<principal> ssh-ed25519 <base64> [until=<entry id>] [until=<register>:<entry id>]...
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
  nothing, and says so. `until=<entry id>` holds in every register; `until=<register>:<entry id>`
  (repeatable, once per register) in that register alone, so a key retired at one register's entry
  is not cut off from every register at once. In a register with no checkpoint of its own, an anchor
  retired elsewhere is trusted, in format 2, for nothing; in format 3, up to its revocation as
  carried into that register by another anchor ("Format v3").
- A reader SHOULD have at least two anchors, so that losing one key never leaves the rosters
  closed.

An agent's key needs no anchor. When it is lost, an operator adds a new key under the same
principal: what the old key signed stays valid. When it is stolen, an operator removes it in the
same roster entry, and what it signs after that removal is refused (`removed-key`).

## Register types

A register's type gives its kinds. `roster`, `ruling` and `prune` are the same in every register.
Each register has its own roster, read from its own entries, so being allowed to write one
register says nothing about another. Anchors are the reader's, and the same for every register it
reads.

The engine knows one type, `log`: any kind, with `data` unchecked. Every other type is given by a
capability Feature, as a module in the engine's types folder (README.md, "Types"); the module's
type says its kinds and their checks, and MAY say what the entries add up to and which flags that
adds. A reader MUST take types only from that folder, never from its environment or a store, and
MUST refuse a types folder or module that someone other than root could change, or that sits below
a folder someone other than root could change (in a source tree, the user running MAY stand in for
root). A type module runs with the reader's own authority: it is trusted as fully as the reader.

## Format v3: identity and permission

A register is format 2 (the roster, above) or format 3, never both: a format-3 register holds
version-3 entries only (sign-packet's version 3, namespace `aof-register-v3`), and refuses any
other (`bad-version`); a format-2 reader refuses every version-3 entry. The design and its review:
`AOF's aof/tooling/design/register-v3-identity-permission.md` and `register-v3-review.md` (ruled by the
operator, 2026-11-11). The rules below are the engine's: a reader applies them whatever capability
Features are installed.

**Identity** is said once, by an anchor, in an agents register: an entry of kind `identity`,
`{principal, key, type}` (`type`: `agent` or `operator`; optional `subject`, `until`, `was`). An
anchor ends one with `identity_revoke`, `{key, ends: [<attestation ids>], reason?}`. Only an anchor
writes either (`not-operator`), and never about an anchor's own key (`anchor-key`).

**Permission** is said in each register, by an operator, carrying identity byte for byte:

| Kind | Data | What it says |
|---|---|---|
| `register` | `{identity_from: [<agents register>...], continues?: {register, heads}}` | The register's first entry, an anchor's; the agents registers it takes identity from. One per register. |
| `grant` | `{principal, role, identity: <identity packet>}` | P may write here as `role` (`agent` or `operator`), with the key the identity names. |
| `bind` | `{identity: <identity packet>, revocation?: <identity_revoke packet>}` | P, already granted, holds a further key; with the old key's revocation, a rekey in one entry. |
| `revoke` | `{revocation: <identity_revoke packet>}` | The key the revocation names is P's no longer. |
| `ungrant` | `{principal}` | P may no longer write here. |
| `ruling`, `prune` | as in format 2 | |

`roster` is format 2's: a format-3 register refuses it (`bad-field`).

**A carried packet** (an `identity` or `identity_revoke`, at most 8192 bytes) counts only when it
checks alone (format, fields, version 3, its kind, signature), comes from a register the `register`
entry accepts, is signed by one of the reader's anchors that the reader trusts for the **entry that
carries it** (an anchor retired at a checkpoint counts only in carriers that are the checkpoint or
before it; one retired elsewhere, only in carriers before its carried revocation), and names no
anchor's key (`anchor-key`). The one exception: the `identity_revoke` of an anchor this reader has
retired elsewhere, carried in a `revoke` by another anchor, which retires it in this register from
there on (`retired-anchor` for its own entries). Otherwise the carrying entry is refused
(`bad-carried`). A `grant` carries the identity of the principal it names (`wrong-principal`), and
grants `operator` only to an identity of type `operator` (`not-operator`).

**Who may write an entry E**, with key K and principal P, is decided by E's ancestors alone:

1. K is an anchor: as in format 2 (its principal, role `operator`, its checkpoint).
2. Otherwise K is P's by a carried identity in a `grant` or `bind` that **stands** among E's
   ancestors (every `ungrant` of P among them comes before it, so a re-grant brings back no key
   from before an ungrant), no revocation of K is among them, and a grant of P stands. Its role is
   the grant's.
3. Refused: a revoked K (`revoked-key`); K bound to another principal, or P granted two roles at
   once (`wrong-principal`); P with no standing grant (`not-granted`); anything else
   (`unknown-key`).

`register`, `grant`, `bind`, `revoke`, `ungrant` and `ruling` are an operator's (`not-operator`);
`register`, `prune`, `identity` and `identity_revoke` an anchor's. `register` is the register's
first entry, with no parents; a second is refused (`bad-field`). `grant`, `bind`, `revoke` and
`ungrant` need it among their ancestors (`no-register`). A key once revoked is never bound again.
A `bind` of an identity of type `agent` to a principal granted as `operator` is refused
(`not-operator`).

Known and accepted: an operator can re-grant another principal with a lower role, which locks its
entries out as an `ungrant` would (`wrong-principal`); a prune that leaves out a ruled-out entry
also drops what that entry granted or revoked, as in format 2.

**Flagged, not refused:** an entry written concurrently with the carried revocation of its key
(`concurrent-with-revocation`); a `grant` and an `ungrant` of one principal written concurrently
(`concurrent-grant`), where the ungrant wins.

**Moving from format 2** makes a new format-3 register: its `register` entry names the format-2
register and its heads in `continues` (a reference, not a parent), and the format-2 register is
closed by a last anchor entry of kind `closed`, `{continued_by}`, which a format-2 reader keeps as
a kind it does not check.

## Versions

`v` names this format. A reader MUST refuse a `v` it does not know (`bad-version`). It MUST NOT
guess at the format. Kinds, kind fields and register types grow without a new `v` (above).
Anything else needs one.

| `v` | What changed |
|---|---|
| 1 | The ledger's format. |
| 2 | Every entry names its register (`reg`), and is signed in the namespace `aof-register`. |
| 3 | Identity and permission (above): the same fields, signed in `aof-register-v3`, under the rules of "Format v3". |

From agentic-register 0.15.0 the format is sign-packet's (AOF ADR 0024). Nothing in it changed: every
entry written before is a packet with the same id.
