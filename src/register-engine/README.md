
# register-engine (signed, mergeable registers: the building block under the capability Features) (register-engine)

The register engine, a building block (AOF ADR 0028): a register is a set of sign-packet packets that merges without conflicts across branches, machines and writers that are not trusted. The engine reads and checks them (rosters, anchors, forks and rulings, prunes), stores them (put once), syncs and mirrors them, and builds views; it knows no register type but `log`. Capability Features give the types, through a root-owned types folder, and the commands that write. Installs the register-engine command (version, check, types, verify), its own copy of sign-packet's library (no sign-packet Feature needed), and its Taskfile. Moved from the AOF repository, where it replaced agentic-register's engine.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/register-engine:0": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under register-engine: in a root Taskfile that includes /usr/local/share/go-task/features.yml (the go-task Feature). | boolean | true |

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

## Changes

### [0.3.0] - 2026-11-19

#### Changed

- Moved from the AOF repository (the Agentic Operating Framework, private) into this collection, and
  published from here as `ghcr.io/nabil-becker/devcontainer-features/register-engine`. The engine,
  the entry format and the command are 0.2.0's: every register it read reads here unchanged.
- **It installs alone.** The Feature now carries its own copy of sign-packet's library
  (`signpacket/`, sign-packet 0.6.0, the same code as 0.5.1 with the new version number) and
  installs it into `/usr/local/lib/register-engine/signpacket/`, where the command finds it first.
  The sign-packet Feature is no longer needed beside it, the install never runs a sibling's
  installer, and the order of Features does not matter. In AOF the two had to be listed together;
  this collection cannot name an unreleased Feature in `installsAfter`, and a published Feature
  folder must be self-contained (CONTRIBUTING, "Adding a Feature", step 3).
- The version goes on from AOF's line rather than restarting at 1.0.0. AOF's `publish-features`
  workflow published every version to its private registry
  (0.1.0 to 0.2.0); 0.3.0 is
  the first from here, and the minor says the install changed. 1.0 waits for the capability
  Features and format v3 to settle.
- The documentation is this collection's: the README is generated from `NOTES.md` (with "How it
  fits"), `documentationURL` and `licenseURL` point here (MIT), and the tests are in
  `test/register-engine/` (`task test:register-engine-unit`, part of `task lint`). References to
  AOF's decision records read "AOF ADR nnnn".
- A stack on the AOF package: change the Feature reference and rebuild; the sign-packet Feature may
  stay or go.

### [0.2.0] - 2026-11-11

#### Changed

- reads and writes format v3, identity and permission (SPEC.md, "Format v3"; the operator's
  rulings of 2026-11-11): identity attested once by an anchor in an agents register, carried byte
  for byte into each register's `grant`, `bind` and `revoke`. A register is one format; `read`,
  `sync`, `add` and `verify` take it (`fmt`, `--format`), 2 by default. The rules for who may
  write are the engine's, never a plug-in's. Reviewed (class S): checkpoints per register for a
  retired anchor, a bind never raises a role, a re-grant brings back no earlier key, the register
  entry first, carried signatures checked once. Needs sign-packet 0.5.1.

### [0.1.1] - 2026-11-11

#### Changed

- a format-v3 entry is refused (`bad-version`) until the engine reads v3 (0.2.0): sign-packet
  0.5.0 knows version 3, and these rules are v2's.

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/register-engine/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/register-engine/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
