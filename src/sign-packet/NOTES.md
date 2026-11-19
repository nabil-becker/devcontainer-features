## How it fits

```text
  a layer (register-engine, packet-relay, your code)
        |  import signpacket: sign, parse, collect, order
        v
  sign-packet library  --->  ssh-keygen -Y sign / verify (an SSH Ed25519 key)
        |
  sign-packet command (check packet files alone) / sign-packet-setup (the instance id)
        |
  $SIGN_PACKET_HOME/instance-id  (named volume sign-packet-state-${devcontainerId})
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| This running instance's id (`instance-id`) | `/var/lib/devcontainer-features/sign-packet`, the Feature's named volume | 4 working set (a new volume is a new instance) |
| Packets | wherever the layer on top keeps them; sign-packet stores none | none |
| Signing keys | the layer on top's (sign-packet only reads a key file it is given) | none |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: none yet

## What it is

Signed packets, named by their hash, chained per key: the core that registers are built
on (AOF ADR 0024: AOF's agentic-register, and this collection's register-engine). A packet is one line of canonical JSON, signed with an SSH Ed25519 key;
its id is the SHA-256 of that line; each key numbers its own packets and names the one before
(`seq`, `prev`), and the others its writer saw (`saw`). The format is in [SPEC.md](SPEC.md).

sign-packet makes, checks and orders packets. It knows no registers, kinds or rosters: who may
write and what a packet's data means is the layer on top's. In the AOF repository, agentic-register is
that layer for the ledger, the backlog and the mailbox; in this collection, register-engine
(registers) and packet-relay (a file transport between parties) are built on it.

It is a Python library (`signpacket`) and one command, `sign-packet`, that checks packet files on
their own. It needs Python 3.11 and OpenSSH's `ssh-keygen` (8.1 or later), and installs them with
apt when they are missing.

It came from the private AOF repository (the Agentic Operating Framework), where it was published
to that repository's private registry up to 0.5.1; this
collection carries it on from 0.6.0 under the same id. "AOF ADR nnnn" in these files names a
decision record of that repository, not one of this collection's `docs/adr/`.

## What it installs

- `/usr/local/lib/sign-packet/signpacket/`, the library, and `/usr/local/lib/sign-packet/SPEC.md`.
- `/usr/local/bin/sign-packet`, the command, and `/usr/local/bin/sign-packet-setup`, the
  post-create hook.
- `/usr/local/libexec/sign-packet/dcf-persist`, this collection's `dcf-persist` (a verbatim copy of
  `src/common/dcf-persist.sh`, kept by `task common:sync`), in a folder of the Feature's own so the
  installer runs unchanged under a test's `DESTDIR`.
- Nothing is downloaded: the code is in the Feature. When `python3` (3.11 or later) or `ssh-keygen`
  is missing, `install.sh` installs `python3` and `openssh-client` from the distribution's apt
  sources (verified by apt), and fails with a plain message where there is no apt.

## Using it in devcontainer.json

```jsonc
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/sign-packet:0": {}
}
```

The layers in this collection (register-engine, packet-relay) carry their own copy of the library
and do not need this Feature; add it for the `sign-packet` command, the instance id, or your own
code that imports `signpacket`.

## Verify

```sh
sign-packet version     # sign-packet 0.6.0 (format v2), then python, ssh-keygen and the library's path
sign-packet check       # one line per part; exit 0 when ready
```

## Options

| Option | Default | What it does |
|---|---|---|
| `installTaskfile` | `true` | Installs `taskfile.yml` into `/usr/local/share/go-task/includes.d/sign-packet.yml`, so the tasks below appear under `sign-packet:` (the go-task Feature). |

## Tasks

| Task | What it does |
|---|---|
| `sign-packet:version` | The sign-packet version, the format version, Python, ssh-keygen, and where the library is. |
| `sign-packet:setup` | Re-runs the post-create setup: the state folder, and this instance's id resolved once. |
| `sign-packet:instance` | This running instance's id: from `AOF_INSTANCE_ID`, OpenBao (`dcf-secret get instance --field id`), or made here; recorded once (SPEC.md, "The instance"). `-- --quiet` prints the id alone. |
| `sign-packet:check` | One line per part (Python 3.11, ssh-keygen, the instance id); exits non-zero when one is not ready. |
| `sign-packet:verify` | `-- --domain <name> <file or folder>...`: each packet alone (format, fields, domain, signature). Not who may write: the layer on top says that (`register-engine verify`). Exits non-zero when one is refused. |

Every task runs the `sign-packet` command, with `--json` for machines. No MCP server.

## The library

```python
import signpacket as sp
raw = sp.sign(value, key_file)              # the packet's bytes; value is a body (SPEC.md, "The body")
p = sp.parse(raw)                           # checks 1 and 2; raises sp.Refused
found, refused = sp.collect(raws, "notes")  # checks 1 to 4, each packet alone
g = sp.order(found, sp.Graph(refused=refused), vouched=set())   # checks 5 and 6, the order
g.valid, g.order, g.held, g.refused, g.absent, g.heads, sp.forks(g.valid)
```

A layer passes its own checks in: `parse_check` and `check` (the kind's data), and `decide` to
`order` (who may write, run once a packet's parents and chain are good). `vouched` is the
vouched-absent hook (SPEC.md, "Vouched absent").

## Guards

A guard is a command run on each packet's body: on egress, before it is signed, and on ingress,
after its signature is checked (SPEC.md, "Guards"). It exits 0 to let the packet through; anything
else refuses it, and it fails closed. A layer exposes them as options: packet-relay's `guard` and
`ingressGuard`, and a register's guard in the layers on register-engine.

```python
chain = sp.Chain.parse("/usr/local/bin/phi-check --no-exceptions --stdin-filename packet -")
raw = sp.sign(value, key_file, guard=chain)          # refused: sp.Refused("guarded"), nothing signed
chain.check(packet.body, "talk", "ingress")          # a layer's ingress check
```

The first guard is the phi-check Feature (it refuses protected health information and never prints
it). A guard runs with a fixed `PATH` (`/usr/local/sbin` to `/bin`): a script's interpreter must
be on it, as the distribution's Python is (`/usr/bin/python3`, which phi-check uses).

## Implements

The AOF book's **Record** (its ontology): one signed body, named by its hash, written
once, saying who wrote it; and the signature part of the **Guard**: no record without its key's
signature. Who may write, and conflicts between writers, are the register layer's (register-engine).

## State

`/var/lib/devcontainer-features/sign-packet` (`SIGN_PACKET_HOME`), on the named volume
`sign-packet-state-${devcontainerId}`: `instance-id`, this running instance's id, written once
(SPEC.md, "The instance"). A rebuild keeps it; a new volume is a new instance. Nothing else: a
layer keeps its own state (packet-relay's home, each capability Feature's volume).

## Tests

`test/sign-packet/unit/` (`task test:sign-packet-unit`, part of `task lint`): `test_packet.py` (the format, the checks, the order, forks, the
vouched-absent rule, the command) and `test_feature.py` (install.sh into a throwaway root).
`test_instance.py` (the instance id: from the environment, OpenBao, made here, recorded once).
register-engine's and packet-relay's tests run on it too, through their own copies.

## Pairs with

- **register-engine** and **packet-relay** (this collection): built on sign-packet's packets; each
  carries a verbatim copy of `signpacket/` (`task signpacket:check`), so neither needs this Feature
  installed and the order of the Features never matters.
- **openbao** (`dcf-secret`): the instance id can come from OpenBao (`dcf-secret get instance
  --field id`) when the openbao Feature is there; otherwise from `AOF_INSTANCE_ID` or made here.
- **phi-check**: the first guard (see "Guards").
- **go-task**: the Feature Taskfile.
- Needs Python 3.11 and OpenSSH 8.1 (installed with apt when missing).

## Limits

- Python 3.11 or later; a base image without apt and without them fails the build with a plain message.
- It checks packets, not who may write them: rosters, anchors and rulings belong to the layer on top.
- The instance id variable keeps its AOF name, `AOF_INSTANCE_ID`, so stacks planted from AOF keep working.
- The setup script's helper lives in `/usr/local/libexec/sign-packet/`, not `/usr/local/bin/dcf-persist`
  as other Features of this collection install it; the file is the same.
- The volume is `sign-packet-state-${devcontainerId}`, not this collection's usual `-config-`
  name, so a container that ran the AOF package keeps its instance id.
- Troubleshooting: `sign-packet check` names the part that is not ready; `sign-packet verify
  --domain <d> <file>` says why a packet is refused (its refusal code, SPEC.md "Refusals").

## Why it exists

No published Feature signs and chains records with SSH keys. `ssh-keygen -Y sign` signs a file;
sign-packet adds the canonical body, the id by hash, the chain per key and the order of many
writers' packets, which a register or a transport needs.

## Version and upgrade

The Feature's version is the library's (`signpacket.__version__`) and the command's. Pin the major
(`:0`) or an exact version (`:0.6.0`) in the Feature reference; a rebuild takes a new one. The
packet format is versioned on its own (`format v2`; version 3 is opt-in per caller); a reader
still reads versions 1 and 2, so an upgrade never makes stored packets unreadable. A layer that
needs a newer library says so (register-engine needs 0.5.1 or later).
