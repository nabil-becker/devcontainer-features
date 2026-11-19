## How it fits

```text
  a capability Feature (its register types, its commands that write)
        |  types.d/<feature>.py (root-owned)          |  import registerengine
        v                                              v
  register-engine: read, check, store, sync, mirror, index a register
        |  its own copy of sign-packet's library (signpacket/)
        v
  ssh-keygen -Y sign / verify
  stores: folders the capability Feature names (its volume, a folder in git, a shared folder)
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Register types | `/usr/local/lib/register-engine/types.d/`, in the image, put there by capability Features | none (rebuilt with the image) |
| Registers, keys, anchors | the capability Feature's own volume or folders; the engine keeps none | none |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: none yet

## What it is

The register engine, a **building block** (AOF ADR 0028). A register is a set of signed entries
(sign-packet packets) that many writers add to at once, none of them trusted. It merges without
conflicts wherever it is kept: a folder in the volume, a folder in git, a shared folder. The
engine does everything a register needs that does not depend on what the register is for:

- **Writing**: an entry signed as the next in its key's chain, naming the heads it saw; refused
  when its key's chain has forked; a register's guard run before signing.
- **Reading many writers as one register**: rosters and anchors (who may write), forks and an
  operator's ruling on one, prunes, held entries, and the reader's own record of signatures
  already checked.
- **Storing and moving**: stores that put each entry once (a hard link, or O_EXCL on folders
  without links), sync between stores, the change feed.
- **Views**: the SQLite index.

It knows one register type, `log`. Every other type comes from a **capability** Feature:

| Capability | Feature | Its types |
|---|---|---|
| memory | agentic-memory | `ledger`, `backlog` |
| communication | agentic-communication | `messages` |
| trust | agentic-trust | the identity and permission split (format v3, coming) |
| agents | agentic-agents | `agents` |

The capability Features in that table are AOF's plan; none is in this collection yet. The format
is the one AOF's agentic-register wrote (SPEC.md, version 2), so every register it kept reads here
unchanged.

It came from the private AOF repository (the Agentic Operating Framework), where it was published
to that repository's private registry up to 0.2.0; this
collection carries it on from 0.3.0 under the same id. "AOF ADR nnnn" in these files names a
decision record of that repository, not one of this collection's `docs/adr/`.

**No conversation or messages type.** The engine has only `log`. AOF's `messages` type (threads,
messages, A2A tasks) lives in AOF's agentic-register (`register/messages.py`), which this collection
did not take; a capability Feature has to give it through `types.d`.

## What it installs

- `/usr/local/lib/register-engine/registerengine/`, the engine, and `SPEC.md` beside it.
- `/usr/local/lib/register-engine/signpacket/`, this Feature's own copy of sign-packet's library
  (a verbatim copy of `src/sign-packet/signpacket/`, kept by `task signpacket:sync` and checked by
  `task signpacket:check`): the command finds it first, so the engine needs no sign-packet Feature
  and the order of Features never matters. A sign-packet Feature installed beside it does not
  change what the engine runs.
- `/usr/local/lib/register-engine/types.d/`, root-owned, empty until a capability Feature fills it.
- `/usr/local/bin/register-engine`, the command, run isolated (`python3 -I`).
- Nothing is downloaded. When `python3` (3.11 or later) or `ssh-keygen` is missing, `install.sh`
  installs `python3` and `openssh-client` from the distribution's apt sources.

## Using it in devcontainer.json

```jsonc
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/register-engine:0": {}
}
```

## Verify

```sh
register-engine version   # register-engine 0.3.0 (format v2, sign-packet 0.6.0), then python and paths
register-engine check     # one line per part; exit 0 when ready
register-engine types     # log, from the engine itself
```

## Options

| Option | Default | What |
|---|---|---|
| `installTaskfile` | `true` | Install the Taskfile so `task register-engine:<task>` works (the go-task Feature). |

The registers themselves are configured in each capability Feature's options, not here.

## Types

A capability Feature installs one Python module into the engine's types folder,
`/usr/local/lib/register-engine/types.d/<feature>.py`, that lists its types:

```python
from registerengine.registertypes import RegisterType

def _check_note(d: dict) -> None: ...          # raises registerengine.core.Refused("bad-field", ...) when wrong

TYPES = [RegisterType("notes", {"note": _check_note}, description="short notes", feature="agentic-example")]
```

- **Only that folder.** A type is never taken from the environment, the working folder or a
  store.
- **Root's, all the way up.** The folder, each module, and every folder above it and above the
  engine's library, up to `/`, must be owned by root and writable by no one else (a sticky folder
  does not pass); a symlink is refused. Otherwise the engine refuses the types, saying which part
  fails. (A folder handed to the library explicitly, in a source tree or a test, may be the user's
  own.)
- **Isolated.** The installed types are read only by an isolated process (`python3 -I`, as the
  `register-engine` command and every capability Feature's command run), so nothing in the
  working folder or `PYTHONPATH` can stand in for a module a type imports.
- **Trusted like the engine.** A module runs in the engine's process, so every module in the
  folder is trusted as fully as the engine itself. What the rules keep out is anyone who is not
  root. Between capability Features, a type's kinds are frozen when it is accepted, and two
  modules giving one type name are refused, not merged; the refusal names both files.
- **A module that cannot load is refused by name.**
- **`kinds` is required** wherever an entry is parsed, signed, read, synced or added: `{}` says
  "unchecked" on purpose, so a caller that forgets it fails instead of reading everything unchecked.

`register-engine types` lists what is installed and who gave it.

## Tasks

| Task | What |
|---|---|
| `register-engine:version` | What is installed: the version, the format, sign-packet, Python, the library and the types folder. |
| `register-engine:setup` | Nothing to prepare: the engine keeps no state; each capability Feature keeps its own. |
| `register-engine:check` | One line per part (Python, `ssh-keygen`, its sign-packet library at 0.5.1 or later, the types folder). Exits non-zero when not ready. |
| `register-engine:types` | The register types installed, and which Feature gave each. |
| `register-engine:verify` | `-- <store> --register <name> [--type <type>] [--anchors <file>]`: every entry of one store checked as one register. Exits 1 on a refusal, a held entry or an unruled fork. |

The commands that write (add, roster, sync, mirror, rule, prune, query, show) are the capability
Features', each for its own registers, on this engine.

## State

None. The engine keeps nothing; a capability Feature keeps its keys, anchors and stores in its own
volume.

## Implements

- The book's **records** and **registers** (the AOF book's ontology), as the building block
  under the memory and communication capabilities (AOF ADR 0028).
- **P2, the record improves the work**: the register is the record the ledger and the backlog are
  kept in.

## Inside

| Path | What |
|---|---|
| `registerengine/core.py` | The format's rules: kinds every register has (`roster`, `ruling`, `prune`), the roster, anchors, reading one register (rulings, prunes, flags). |
| `registerengine/adapters.py` | Stores, sync, writing an entry, the guard, anchors files, the checked-signature record, the index, the change feed. |
| `registerengine/v3.py` | Format v3: the identity and permission kinds, carried attestations, and who may write a v3 entry. |
| `registerengine/registertypes.py` | Register types, and the types folder they are loaded from. |
| `registerengine/cli.py` | The command. |
| `signpacket/` | sign-packet's library, a verbatim copy of `src/sign-packet/signpacket/` (`task signpacket:check`, `task signpacket:sync`). |

Tests: `test/register-engine/unit/` (`task test:register-engine-unit`, part of `task lint`):
- `test_engine.py`: the engine with a ledger-like type given through the types folder (reading,
  refusals, forks, prunes, sync, the index), and the types folder's checks.
- `test_feature.py`: install.sh into a throwaway root, alone (its own sign-packet library).
- `test_v3.py`: format v3 (identity and permission) and the 0.2.0 security review's findings.
- `same_format` in `test_engine.py` reads entries AOF's agentic-register wrote; it runs only in a
  tree that has `src/agentic-register`, and says `skip` otherwise (this collection has none).

## Pairs with

- **sign-packet**: its packets are the entries. The engine carries its own copy of the library,
  so the sign-packet Feature is not needed; add it for its command or the instance id.
- **packet-relay**: moves packets between stacks; a federated register would use it (AOF's
  agentic-register did).
- **A capability Feature** (none in this collection yet): gives the types and the commands that
  write. Without one, the engine reads and verifies `log` registers only.
- **go-task**: the Feature Taskfile. Needs Python 3.11 and OpenSSH 8.1 (installed with apt when missing).

## Limits

- No command writes: `add`, `roster`, `sync`, `mirror`, `rule`, `prune`, `query` and `show` are a
  capability Feature's. Through this Feature alone a register can be verified, not kept.
- One type, `log`; no messages or conversation type (see "What it is").
- Python 3.11 or later; a base image without apt and without them fails the build with a plain message.
- Troubleshooting: `register-engine check` names the part that is not ready; `register-engine verify
  <store> --register <name>` lists each refused or held entry with its reason, and a types folder
  that fails its ownership rules is refused naming the part.

## Why it exists

No published Feature keeps a signed, append-only register that many untrusted writers merge without
conflicts. A git history is one such register only inside one repository and for those who may push
to it; the engine works on any folder, checks every entry's signature and the writer's place on a
roster, and settles forks by an operator's signed ruling.

## Version and upgrade

Pin the major (`:0`) or an exact version (`:0.3.0`). A rebuild takes a new one; the stores are the
capability Features', so an upgrade changes only the code. The entry format is versioned on its own
(`format v2`, and v3 read and written for identity and permission); an upgrade never makes stored
entries unreadable. The vendored sign-packet library moves with this Feature's version: a change to
sign-packet's library reaches the engine in a new register-engine version (`task signpacket:sync`).
