# sign-packet: the packet, format version 2

A packet is one signed body, named by its hash, with its place in its key's chain. Packets make a
graph that merges without conflicts wherever it is kept: a set of packets, joined by union.
sign-packet makes, checks and orders packets. It knows nothing of what a packet's `kind` and
`data` mean, who may write, or how packets are kept: a layer on top says that. agentic-register
is the first such layer: each of its registers is the packets of one domain, its entries are
packets (agentic-register's SPEC.md). Rules use RFC 2119 keywords. Any implementation that passes
the cases in `test/sign-packet/unit/` is one.

The format is the one agentic-register has written since its version 2 (AOF ADR 0024): every entry
ever written is a packet, byte for byte, with the same id.

## What it guarantees

| Property | How |
|---|---|
| Lives anywhere | A packet is a self-contained run of bytes. A folder, a git repository, a database or a bucket can carry it. No store is trusted. |
| Tamper-evident | A packet's id is the hash of its exact body. A packet names its parents by id, so changing one packet breaks every link after it. |
| Signed | Every packet is signed by the key it names. Nobody without the private key can make a packet of that key. |
| Concurrent writers | No central log and no locks. Each key writes its own chain. A packet also names the other packets its writer saw, so together they form a graph, as git's commits do. |
| Merges never conflict | A set of packets merges by union: the same result in any order, and duplicates are harmless. |
| Exactly once | The id is the hash of the body, so a second copy of a packet is the same packet. |
| Lying writers are visible | Two valid packets with one key and one `seq` are a **fork**, and a reader reports it. |

What it does not guarantee: that a key is allowed to write (the layer on top says who may: a
roster, a list of keys a party trusts); that a store holds every packet; that `at` is true (it is
the writer's claim; order comes from the graph); erasure (content that must never be kept MUST be
refused before it is signed).

## Terms

- **Packet**: one signed body.
- **Body**: one line of canonical JSON. It is what is hashed and signed.
- **Id**: the lowercase hex SHA-256 of the body's bytes (64 characters).
- **Key**: an OpenSSH Ed25519 public key, written `ssh-ed25519 <base64>`, without a comment.
- **Domain** (`reg`): the name of the set a packet belongs to, `[a-z][a-z0-9-]{0,63}`. A packet
  is read only in its own domain, so a packet signed for one is never replayed into another. In
  agentic-register a domain is a register.
- **Parents** of a packet: its `prev` (if any) and every id in its `saw`.
- **Ancestors**: the parents, their parents, and so on.
- **Vouched absent**: an id the layer on top says may be missing, so no packet waits for it (see
  "Vouched absent").

## The packet

A packet is UTF-8 text:

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
- Every object key matches `[a-z][a-z0-9_]{0,63}`.

This is a subset of RFC 8785 (the JSON Canonicalization Scheme) on which the two agree. Python's
`json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)` writes it.

### The body

| Field | Type | Rule |
|---|---|---|
| `v` | integer | `2` (or `1`, below). Anything else is refused (`bad-version`). |
| `reg` | string | The domain, `[a-z][a-z0-9-]{0,63}`. Versions 2 and 3. |
| `key` | string | The writer's key, `ssh-ed25519 <base64>`. |
| `as` | string | The name the writer writes as: a plain id, `[a-z0-9][a-z0-9_.-]{0,63}`, and for an agent the running instance it writes from after one `@`: that instance's GUID, lowercase, 8-4-4-4-12 (`scribe@3f2b9c1e-7a4d-4e8b-9c2a-5d6e7f8a9b0c`; see "The instance"). Nothing else follows `@`, so a principal is never an email address. Whether the key may use it is the layer's to say. |
| `seq` | integer | This key's number for the packet, from 1. |
| `prev` | id or null | null when `seq` is 1. Otherwise the id of this key's packet with `seq` minus 1. |
| `saw` | list of ids | Other packets the writer saw, for example the heads when it wrote. Sorted, no duplicates, at most 64, and never `prev`. MAY be empty. A writer SHOULD name only packets of the same domain: a reader that never gets the other packet holds this one for it. |
| `at` | string | The writer's clock, UTC, `YYYY-MM-DDTHH:MM:SSZ`. A claim. |
| `kind` | string | `[a-z][a-z0-9_]{0,63}`. What it means is the layer's. |
| `data` | object | What it holds is the layer's, by `kind`. |

A body with a field missing or an extra field is refused (`bad-field`). A new field needs a new
`v`. **Version 1** is version 2 without `reg`: a version-1 packet belongs to the domain `ledger`,
and only to it. A reader MUST still accept one there, and a key's chain MAY continue from
version-1 packets into version-2 packets. A writer MUST write version 2, or version 3 where its layer says so. **Version 3** has version 2's
fields; it is signed in its own namespace, and a layer gives it new rules (agentic's register
format v3, AOF ADR 0028: identity and permission). A reader that does not know version 3 refuses it
(`bad-version`), so it never reads a v3 packet by v2's rules. Version 3 is **opt-in**: the library
reads and signs versions 1 and 2 unless its caller asks for 3 (`versions=`), so a layer written
before version 3 refuses it without a change of its own. A packet refused for its version is
named by its id, so a packet that follows it is refused too (`refused-parent`), not held. A key's chain MUST NOT continue from
version 2 into version 3: a layer that moves starts a new domain.

## Checking a packet

A reader checks each packet in this order. The first failure decides. A layer adds its own checks
where it says (agentic-register adds the kind's data after 2 and 3, and who may write at 7).

1. **Format**: UTF-8, a body line, an armoured signature (`bad-format`). Body size (`too-large`).
   The body is JSON (`bad-format`), an object, with integers only (`bad-field`), and canonical
   (`not-canonical`).
2. **Fields**: `v` (`bad-version`), then every field (`bad-field`). Also `seq` 1 has `prev` null
   and `seq` above 1 does not (`bad-chain`).
3. **Domain**: the packet belongs to the domain being read (`reg`, or `ledger` for version 1). A
   packet of another domain is refused (`wrong-domain`; agentic-register says `wrong-register`).
4. **Signature**: by `key`, over the body, in the version's namespace (`bad-signature`).
5. **Parents**: every parent is known, or vouched absent. If one is not, the packet is **held**,
   not refused: it is checked again when the parent arrives. If a parent was refused, so is the
   packet (`refused-parent`).
6. **Chain**: `prev` has the same `key` and `seq` one less (`bad-chain`).
7. The layer's own checks, now that the ancestors are known.

The outcome of a packet is one of: **valid**; **held**, with the ids it waits for; **absent**
(vouched absent, below); **refused**, with a code. Checks 1 to 4 need only the packet and the
domain's name. Checks 5 to 7 need its ancestors.

## Reading packets

One domain is read at a time.

- **The packets** are the valid packets of every source joined together.
- **Order**: a topological order of the graph (parents first). Ties go to the earlier `at`, then
  to the smaller id. Every reader with the same packets gets the same order.
- **Heads**: valid packets that no valid packet names as a parent. A writer SHOULD put the heads
  it knows (other than its own `prev`) into `saw`, up to 64.

### Forks

A fork is a key writing two different packets as the same `seq`: a writer that ran twice at
once, or one key used on two copies of a store. Both packets stay valid, because both are signed,
and a reader reports the fork. A writer MUST NOT add to a forked chain until the fork is settled:
how it is settled is the layer's (agentic-register: an operator's ruling).

### Vouched absent

A packet MAY be missing on purpose: a layer let a store leave it out (agentic-register's prune),
or a party lost it for good. The layer gives the reader a set of ids it vouches for; only the
layer knows whose word counts (agentic-register: an anchor's).

- An id vouched for and not in the store is **absent**: a packet that names it as a parent is not
  held for it.
- A packet whose `prev` is absent is absent too if it is vouched for, even if the store still has
  it. If it is not vouched for, it is refused (`refused-parent`): its chain cannot be checked, so
  anyone's key could otherwise hang packets on a line that is gone.
- A packet vouched for and still in the store is read as if it were not vouched for. Whether it is
  to delete is the layer's to say.

## Guards

A guard is an adopter's own check on a packet's content: a command run on the packet's body, on
the way out (egress: before it is signed) and on the way in (ingress: after a received packet's
signature is checked, before the layer takes it). sign-packet runs them; the layer on top decides
where, and what a refusal means there.

- The command's first word MUST be an absolute path, never found on a caller's PATH or in its
  checkout. It reads the body's exact bytes on standard input and exits 0 to let the packet
  through.
- Anything else refuses it (`guarded`): a non-zero exit, a crash, a command that cannot run, or no
  answer within its timeout (10 seconds unless set, at most 300). A guard fails closed. A layer can
  tell a refusal for the content (the guard exited with a non-zero code) from a guard that gave no
  answer about it (it could not run, timed out, or was killed): the second is a failure of the
  guard, not a verdict on the packet.
- It is given a fixed `PATH` (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`), the
  locale, `SIGN_PACKET_GUARD_DOMAIN` and `SIGN_PACKET_GUARD_DIRECTION` (`egress` or `ingress`),
  `PYTHONNOUSERSITE=1` and `PYTHONSAFEPATH=1` (so a guard written in Python loads nothing from the
  user's site or its working folder), and nothing else of the caller's environment. It runs in `/`, in a session of its own, which is
  killed when it answers.
- Its standard output is not read. The refusal names the exit and the first line of its standard
  error (at most 200 characters, control characters replaced); it never repeats the packet.
- A guard's author MUST write only a reason to standard error, never the packet's content: the
  runner cannot check it, and the reason reaches logs, quarantines and the agents that read them.
  A guard MUST exit 0 only after reading all of standard input and completing its check.
- A guard is a check against mistakes and against what others send, not a boundary against code
  running as the same user: that code can read the signing key and write the folder itself.
- A chain runs guards in order; the first refusal decides. An empty chain lets everything through.
- On egress a refused packet is never signed: the writer's chain does not move. What a refusal on
  ingress means is the layer's (packet-relay: the packet is quarantined, and the sender's order
  goes on).

The first guard is the phi-check Feature's command, which refuses protected health information
without printing it: `/usr/local/bin/phi-check --no-exceptions --stdin-filename packet -`.

## Versions

| Version | Namespace | What changed |
|---|---|---|
| 1 | `aof-ledger` | The first format, of the ledger alone. |
| 2 | `aof-register` | Every packet names its domain (`reg`). |
| 3 | `aof-register-v3` | The same fields as 2, under a layer's new rules; its own namespace, so a version-2 signature never passes as one. |

A principal with an instance (`name@<GUID>`) is valid from sign-packet 0.4.0 (0.3.0 took a short
name after `@` instead; nothing was written with one). An older reader refuses such a packet
(`bad-field`): a clear failure, never a misreading. Every reader of a domain whose writers carry an
instance MUST be 0.4.0 or later.

## The instance

An instance is one running stack: one dev container, on one machine. Its id is a GUID, lowercase,
8-4-4-4-12, and it is the part after `@` in its agents' principals, so two running copies of one
project never write as one. A readable name for it is metadata, kept outside the records.

An instance's id is resolved in this order, the first found winning:

1. `AOF_INSTANCE_ID` in the environment (for example from a machine-local `.devcontainer/.env`,
   passed through `containerEnv`);
2. OpenBao, through the openbao Feature's `dcf-secret get instance --field id`, when it answers;
3. neither: a new GUID.

The id found is recorded once, in sign-packet's volume (`$SIGN_PACKET_HOME/instance-id`), and every
Feature in the container reads that record. Sources that disagree are refused before anything is
recorded; a source that later names another id is refused, never followed: an id is never changed.
A lost volume is a new instance, with a new id.

This stops an instance switching ids. It does not stop a new instance being given another's id at
its creation (a copied `.env`, one OpenBao secret shared by two instances): no instance can tell on
its own. That is caught between instances: packet-relay refuses a peer that claims its own id, and
an authority refuses to certify a second key for one instance (the certificate work).

sign-packet 0.1.0 and later read both and write 2; 0.2.0 adds guards ("Guards"), with no change to the format. The format belongs to sign-packet from 0.1.0;
agentic-register 0.15.0 and later read and write it through sign-packet.
