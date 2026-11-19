# packet-relay: the protocol, version 1

Parties exchange sign-packet packets (sign-packet's SPEC.md) through a folder each of them mounts:
a host folder bind-mounted into several dev containers, or a cloud folder synced to several
machines. The folder's own sync carries the files; the protocol does not depend on its timing,
order or completeness. AOF ADR 0024, decision 3, sets the guarantees; this document is how they are
kept. Rules use RFC 2119 keywords.

| Guarantee | How |
|---|---|
| Reliable | A sender keeps every packet until every party has acknowledged it, and writes it again while one lacks it. A packet removed before that is a loss the sender sees: its acknowledgements stop below it. |
| Ordered | A receiver takes each sender's packets in their chain's order (`seq`, with `prev` naming the one before). A gap waits. |
| Exactly once | A packet's id is the hash of its body: a second copy, under any name, is the same packet. A receiver takes each seq once. |
| Signed | Every packet and every acknowledgement is signed. A receiver takes only packets of the parties in its own members file, from each party's own subfolder. |

## Terms

- **Domain**: one conversation between a set of parties, a sign-packet domain of at most 59
  characters (so `<domain>-ack` and `<domain>-skip` are domains too).
- **Party**: a principal and its key, listed in the **members file** of the domain. Each party
  has its own key: one key used on two machines forks its chain (see "Forks").
- **Members file** and **anchors file**: `<principal> ssh-ed25519 <base64>` per line. They are
  the reader's own configuration, never read from the shared folder. The anchors are the
  operators whose word may skip a lost gap.
- **Home**: a party's own state, outside the shared folder: its chains, its outbox (every packet
  it sent and that not every party has taken), its inbox (every packet it took, in order) and
  what it has taken from each sender.

## The folder

```
<root>/<domain>/<party>/packets/<id>.entry     the party's packets (domain <domain>)
<root>/<domain>/<party>/acks/<id>.entry        its acknowledgements (domain <domain>-ack)
<root>/<domain>/vouch/<operator>/<id>.entry    an operator's skips (domain <domain>-skip)
```

- Each subfolder has one writer: the party (or operator) it is named for. A party MUST NOT write,
  rename or remove a file in another's subfolder.
- A file is written once: a writer MUST NOT replace a whole file that is there. A file under an
  entry's name that is not a whole packet (a write cut short) MAY be replaced by the same packet.
- A file's name is not trusted. A reader MUST check every packet it reads (sign-packet, checks 1
  to 4, in the subfolder's domain) and MUST refuse one that is not the subfolder's party's: its
  `key` the members file's key for that party, its `as` that party (`not-this-party`).
- Files a reader cannot use (another name, a partial copy, a sync tool's conflict copy) are
  skipped or refused, never fatal.
- Nothing in the folder is followed. Each folder below the root is opened once per round, part by
  part, without following a symlink (`O_NOFOLLOW`), and every list, read, write and removal in it
  goes through that open folder, so a folder swapped for a symlink during a round changes nothing.
  A symlink, or a file where a folder should be, is refused (`not-a-folder`); in a party's own
  folders it stops the round, in one line. Only plain files named `<64 hex>.entry` are read
  (`not-a-file` for a symlink or a special file), none bigger than a packet can be (`too-large`,
  not read), and a file's party and kind are checked before its signature, so junk costs no
  signature check. A round reads at most 2000 files of a subfolder and reports at most 100
  refusals of it.
- A domain MUST NOT end in `-ack` or `-skip`, and no party or domain is named `vouch`, so the
  protocol's own domains and folders never meet a party's.

## Sending

A party signs each packet as the next in its own chain in the domain (`seq`, `prev`), with an
empty `saw`: order is per sender. It keeps the packet in its outbox before it writes it into its
`packets/` subfolder, so a crash between the two writes the same packet again, never a second
one at the same seq. A party's home is its own, per domain: several parties may share a home.

## Acknowledging

After taking packets, a receiver writes an acknowledgement: a packet in the domain `<domain>-ack`,
of kind `ack`, in its own chain of acknowledgements, with `data: {"taken": [{"from": <sender>,
"seq": <n>, "id": <id>, "key": <the sender's key>}, ...]}`: for each sender, the last packet it has
taken in order, named by seq, id and key. It is a list, not a map by sender, because a field name
cannot hold a principal with an instance (`relay@<GUID>`). A reader also takes the map 0.2 wrote,
`{"upto": {<sender>: {"seq", "id", "key"}}}`; a 0.2 reader finds no `upto` in a 0.3 acknowledgement,
counts it as nothing taken and removes nothing: mixed versions are slow, never wrong. It is cumulative: the newest acknowledgement (the highest `seq` of that
party's valid packets of kind `ack`) is the only one that counts, a reader never waits on a gap in
them, and a party MAY remove its own older acknowledgements.

## Removing and writing again

In each round a sender reads every other party's newest acknowledgement. An entry for it counts
only if it names the sender's own key and, at that seq, the id of the sender's own packet: one
that names another (an old chain of this party, a home restored from an old copy, a key it no
longer has) counts as nothing taken, and is reported as stale. Let `done` be the lowest counted
seq over the other parties (0 for a party with none).

- It MAY remove from its own `packets/` subfolder, and from its outbox, every packet with `seq`
  up to `done`: every party has taken it.
- It MUST write again, unchanged, every packet of its outbox above `done` that is not in its
  subfolder. The same bytes under the same name: a receiver that already had it takes nothing new.
- It MUST NOT remove a packet above `done` because of time. A party that is away holds the
  sender's packets until it comes back or an operator takes it off the members file.

## Taking

For each sender, a receiver takes the packet at the seq after the one it last took:

- If there is exactly one, and its `prev` is the id of the packet taken before it (null at seq
  1), it is taken: put in the inbox, then recorded as taken. A crash between the two puts the same
  file there again and reports it as taken again: a consumer takes each id once.
- If there are two or more different packets at that seq, the sender's chain has forked: none is
  taken, and the fork is reported (see "Forks").
- If its `prev` is not the packet taken before, or another packet is at a seq already taken,
  the sender's chain went another way: a fork.
- If there is none, the receiver waits: it reports the gap with the seq it needs and, when the
  packet after it is there, the missing packet's id (that packet's `prev`). Later packets of that
  sender are not taken until the gap fills.

## Skipping a gap

When a sender has lost a packet too (its outbox and the folder both lack it), the gap never
fills. Only an operator may let a receiver go on: a packet in the domain `<domain>-skip`, of kind
`skip`, in the operator's subfolder of `vouch/`, with `data: {"party": <sender>, "key": <its key>,
"first": <seq>, "through": <seq>, "id": <the id the next packet's prev names>}`. It says: that
sender's packets `first` to `through` are lost; the one at `through + 1` must have `prev` equal to
`id`.

A receiver takes it only if the operator is in its own anchors file, only when the seq it needs
is between `first` and `through` (a reader behind `first` waits for what is only late or hidden),
and only to go on from a packet that is there with that `prev`. It reports the skip.

## Forks

A key that writes two packets at one seq (one key used on two machines, or a home restored from
an old copy) forks its chain. A receiver takes neither side, records the fork in its home and
reports it in every round after, even if one side leaves the folder: a writer of the folder must
not choose the side. An operator settles it outside the protocol, with a new key for that party
in the members file: a receiver that sees a sender's key change starts that sender's chain from
seq 1 again, and says so (`key-changed`).

A party whose home is lost MUST NOT write again from seq 1: it would fork. It refuses when its
packets are in the folder, or when another party's acknowledgement names a packet of its key. It
needs a new key, and a new home: a home's chains belong to the key that made them, and a home
used with another key refuses.

## Guards

A party MAY run sign-packet guards (sign-packet's SPEC.md, "Guards") on its own packets and on the
packets it takes. Which ones is the party's own configuration, never the folder's.

- **Egress**: on every packet the party sends, before it is signed. A refusal sends nothing, and
  its chain does not move: the next packet takes the same seq.
- **Ingress**: on every packet the party would take, once it is next in the sender's order and its
  chain is good. A refusal does not stop the sender's order: the packet is taken (recorded and
  acknowledged, so the sender may remove it), but it is put in the party's quarantine, with the
  guard's reason, never in the inbox. One refused packet blocks nothing after it.
- A guard that gives no answer about the content (it cannot run, times out, or is killed) refuses
  nothing and quarantines nothing: the party takes no more from that sender this round, does not
  acknowledge it, and reports it (`guard-failed`). The sender keeps the packet, and the next round
  tries again. A broken guard holds the conversation; it never makes packets vanish.
- Acknowledgements and skips carry no free text (ids, seqs, keys) and are not guarded.

## What it does not guarantee

- Delivery to a party that never syncs. Its absence is seen: its acknowledgements stop.
- Order across senders. `saw` is empty; each sender's own order is kept.
- Secrecy. Packets are signed, not encrypted: anyone who can read the folder can read them.
- A content check, unless a party configures guards (above). Without an egress guard packet-relay
  writes what it is given: whatever must not reach the folder's provider (a person's name, an email
  address, a credential, health information) MUST then be refused by the layer that sends, before
  it signs.
- Protection against a writer of the folder that removes files: it cannot forge a packet, but it
  can delete one. A deletion before every acknowledgement is resent from the outbox; a deletion
  of the outbox too is a gap that only an operator can skip.
