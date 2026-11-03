# agentic-register

Shared registers that many writers add to at once, none of them trusted, merged without conflicts
wherever they are kept: in git or outside it. Every entry is signed by its writer, named by its
hash, and names its register. Each register's roster of keys says who may write it. Forks and
disagreements are kept and shown, never resolved silently. The format is [`SPEC.md`](SPEC.md),
version 2. It still reads version-1 ledger entries.

One Feature keeps any number of registers, each a **name**, a **type** and a **store**. The ledger
is the first type. Others (a backlog, an agent registry, a mailbox) are added as types without a
change to the format. This Feature supersedes `agentic-ledger`: a ledger is now one register.

```jsonc
"features": {
  "ghcr.io/<namespace>/agentic-register:0": {
    "registers": "ledger:ledger:docs/ledger/entries; notes:log"
  }
}
```

Then, once per operator and once per agent:

```
agentic-register key new operator-1              # prints "operator-1 ssh-ed25519 AAAA..."
# paste that line into the anchors file ($AGENTIC_REGISTER_HOME/anchors)
agentic-register key new tooling
agentic-register roster --as operator-1 --add-key 'ssh-ed25519 AAAA...' --principal tooling --role agent
AGENTIC_REGISTER_AS=tooling agentic-register add --title "Package the ledger" --data '{"cost":{"usd_micro":120000}}'
agentic-register verify && agentic-register show
agentic-register add --register notes --kind note --data '{"text": "a log takes any kind"}'
```

Moving a repository onto it, from `agentic-ledger`, a ledger file or a `TODO.md`:
[`ADOPTING.md`](ADOPTING.md).

## Options

| Option | Default | What |
|---|---|---|
| `installTaskfile` | `true` | Install the Taskfile so `task agentic-register:<task>` works (the go-task Feature). |
| `registers` | empty | The registers, one entry per register separated by `;`, each `name:type[:store][:mirror=<folder>][:guard=<command>][:guard_timeout=<seconds>]`, written without quotes (see "The registers option"). A relative store or mirror is taken from the top of the git repository. With no store, a register is kept in `$AGENTIC_REGISTER_HOME/registers/<name>`, in the volume. A `mirror` is a folder that `mirror` keeps level with the store (see "A live store and its mirror"); a `messages` register has none. A `guard` is a command run on every entry before it is written (see "A guard"). Empty means one register, `ledger`, of type `ledger`. `AGENTIC_REGISTER_REGISTERS` overrides it, but never drops or replaces a guard set here. An option that is not valid fails the install, saying why. |
| `anchors` | empty | The file of operator keys this reader trusts, the same for every register. Empty means `$AGENTIC_REGISTER_HOME/anchors`. It is never read from a store. `AGENTIC_REGISTER_ANCHORS` overrides it. |
| `registerMcp` | `true` | Register the MCP server with Claude Code at setup, when Claude Code is installed. Setup run from a source copy (no `options.env` beside the code) never registers it. |
| `mcpTools` | empty | The MCP tools the server offers, comma-separated, in full (`agentic_register_add`) or short (`add`, `new-thread`). Empty means every tool. A tool not named is not listed and cannot be called. `AGENTIC_REGISTER_MCP_TOOLS` narrows it further (only what both name) and never widens it. A name that is no tool fails the install. |

### The registers option

Write the registers without quotes: `ledger:ledger:mirror=docs/ledger/entries; backlog:backlog:mirror=docs/backlog/entries; messages:messages`.
Each entry is a name, then its type, then, if it has them, its store (a bare folder, or
`store=<folder>`) and its mirror (`mirror=<folder>`), separated by `:`. A missing type is `ledger`
for a register named `ledger` and `log` for any other.

Why no quotes: the devcontainer CLI (0.80 to 0.90 at least) writes each option into a shell file as
`NAME="value"`, escaping nothing, and sources it before `install.sh` runs. A `"` inside the value
ends the shell's string and is lost, and `$`, `` ` `` and `\` are read by the shell. The quote-free
form has none of them, so it arrives as written.

A value that starts with `[` is still read as a JSON list of `{"name", "type", "store", "mirror"}`.
It arrives whole only when each `"` reaches the shell as `\"`, which in `devcontainer.json` is
`\\\"`. A repository that writes it that way keeps working. A JSON value whose quotes were stripped
fails the install, showing the value received and the form that works.

A command works on one register: `--register <name>`, or `AGENTIC_REGISTER_DEFAULT`, else the
first in the list. Who writes is `--as <principal>` or `AGENTIC_REGISTER_AS`. The signing key is
the volume's `keys/<principal>`, or `--key <file>`. For an operator that is a `.pub` file whose
private half an SSH agent holds on the operator's own machine, so the private key never enters the
manor. Where no agent reaches the manor (a Windows host), `--key` may name a private key copied in
for one signing and loaded into an agent started there, with or without its `.pub`: the public
half is read from the key file itself (ADOPTING-ledger-file.md, step 2).

## Register types

| Type | Kinds | Index views |
|---|---|---|
| `ledger` | `work` (a unit of work, with its measures), `run` (a model run, with its cost), `merge` (a pull request landing on main) | `costs`, `items`, `merges` |
| `backlog` | `add`, `edit`, `tick`, `reopen`, `move`, `note`: changes to items | the tables `backlog` and `backlog_notes`, the view `open_items` |
| `agents` | `agent` (an OASF 1.1.0 record plus our `aof` part), `retire` | the tables `agents` (with the pure OASF `record`, ready to publish) and `agent_skills`, the view `active_agents` |
| `messages` | `thread`, `message`, `invite`, `leave`, `read`, `task`, `status`: conversations and requests, A2A 1.0 shaped | the tables `threads`, `thread_members`, `messages`, `unread`, `tasks`, `task_history`, the view `open_tasks` |
| `log` | any, `data` unchecked | none |

A `messages` register is never stored in git: leave its `store` unset, and it lives in the
Feature's volume (`$AGENTIC_REGISTER_HOME/registers/<name>`), which survives rebuilds. Threads
are group or direct, may have sub-threads, and messages may reference other threads without
granting access to them. A request between agents is an A2A task with its states.

### A live store and its mirror

A store in a git working tree loses entry files whenever a branch switch, a pull or a rebase
briefly removes them while someone writes; that forked two chains here. So a register that is
kept in git has its **live store** in the volume (leave `store` unset) and a **mirror** in the
repository:

```json
[{"name": "ledger", "type": "ledger", "mirror": "docs/ledger/entries"}]
```

Every command reads and writes the live store. `agentic-register mirror` copies each way: what
the mirror has that the store lacks (entries merged on `main`, or everything, into a new volume),
then what the store has that the mirror lacks. It only adds, checks every entry it copies, and
never copies back a line an operator pruned. Run it in one place only: the step that commits the
records, in the checkout whose branch holds them. A file missing from the mirror, or one that does
not check, never touches the store, and the next `mirror` puts back what a switch removed.

The volume is lost if the container engine's storage is reset; the mirror in git is then the copy
the next `mirror` restores from. Entries written since the last `mirror` are lost with it, so run
it before each commit of the records.

**Where a store or a mirror can live.** A put never replaces an entry already there. On a local
filesystem (ext4, xfs, btrfs, tmpfs, overlayfs, APFS) or a bind mount of one, that is a hard link,
which never replaces, so any number of writers on one machine are safe. A folder without hard links
(rclone's FUSE mount, OneDrive, an SMB or other network share) falls back to creating the file
exclusively (O_EXCL) and removing it if the write fails, so it still never replaces an entry this
machine can see. O_EXCL there is only as strong as the mount: rclone's VFS checks it against this
machine's view, so two machines writing one id at the same moment may both succeed. They write the
same body (an id is the hash of the body), so either copy is a valid entry. A file under an entry's
name that is not a whole entry (a write cut short by a crash) is replaced by the next put of that
id. Keep the live store on a local filesystem or the volume; a cloud or network folder is fine for
a mirror.

A backlog is what its changes add up to, in the register's order. Changes made at the same time
never block each other. They are flagged for a person only when they disagree: two edits of one
field to different values, a tick beside a reopen, two moves of one item, an item added twice
(SPEC.md, "The backlog type"). `show` renders it as a `TODO.md`, and `import --todo` backfills
one.

Every register also takes `roster`. Each register has its own roster: being allowed to write one
says nothing about another.

### A guard

The register checks that an entry is well formed and signed by a key on its roster; it does not
know what an adopter must keep out of it (names, secrets, personal data). A register's `guard` is
the adopter's own check, run by the Feature itself, so no way of writing goes around it:

```jsonc
"registers": "ledger:ledger:/srv/ledger:guard=/usr/local/bin/ledger-guard --strict:guard_timeout=5"
```

In the quote-free form a guard's command cannot hold `:`, `;` or quotes. A command that needs them
goes in the JSON form, `"guard": ["/usr/local/bin/ledger-guard", "--strict"]`, with its quotes
escaped for the shell (see "The registers option").

- **What it is**: a command, a list of arguments or a string split as a shell would (no shell runs
  it). Its first word is an absolute path (`/usr/local/bin/ledger-guard`): a bare name or a relative
  path fails the install, since it would be found on a writer's `PATH` or in a writer's checkout.
- **What it gets**: the entry's body, the exact bytes that are then signed (canonical JSON, one
  line, no newline), on standard input; the register's name in `AGENTIC_REGISTER_GUARD_REGISTER`;
  a fixed `PATH` (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`) and the locale.
  Nothing else of the writer's environment reaches it: no tokens, no SSH agent, nothing such as
  `BASH_ENV` that could change what it does. It runs in `/`. Its standard output is ignored.
- **When it runs**: on every entry before it is signed, whatever writes it: `add` and the commands
  built on it (`roster`, `rule`, `prune`, `new-thread`, `send`, `mark-read`, `invite`, `leave`,
  `ask`, `task-status`, `thread --mark-read`), `import` (each record), `rekey`, and every MCP
  tool that writes (`agentic_register_add` and the conversation tools). And on every entry signed
  elsewhere before `sync` or `mirror` puts it in a store that lacks it (in both directions); one it
  refuses is not put, nor is anything after it that descends from it, and the command exits 1.
- **Its answer**: exit 0 lets the entry through, unchanged. Anything else refuses it (`guarded`),
  and nothing is written: a non-zero exit, a crash (a signal), a command that cannot be run, or no
  answer within `guard_timeout` seconds (default 10, at most 300: every writer of the register
  waits for it). The guard and anything it started are killed once it answers or runs out of
  time. The refusal says which, with the exit and the first line of the guard's standard error
  (printable characters only); it never repeats the entry. That line reaches the writer, an agent's
  MCP reply among them, so a guard MUST NOT quote what it matched on it: name the rule, not the text.
- **Removing a key**: a `roster` entry that only removes keys, at most 8, each a real ed25519
  public key, is never shown to the guard, in `roster` or in `sync` (the operator's ruling D79). It
  adds no free text, and a broken guard must never stop an operator removing a key. Anything more
  (a "key" that is not one, adding a key, `rekey`) stays guarded.
- **No guard**: as before. `check` shows a guard that cannot be found as `NOT READY`.
- **An override**: `AGENTIC_REGISTER_REGISTERS` cannot drop or replace a guard the installed
  `registers` option sets for a register of the same name. When the installed list cannot be read,
  the command stops rather than run without its guards. It is a writer's policy, not part of the
  format: a reader never runs it (SPEC.md, "A writer's guard").
- **What it is not**: a defence against a writer with a shell. The rule above is kept by register
  name, so an override that names another register writes without it, into whatever folder it
  names (readers of the guarded register refuse those entries as another register's, but the
  bytes are on disk); and anyone holding a signing key can sign outside the Feature. `--store` and
  `sync --to` keep the selected register's guard. The guard
  closes the ways the Feature itself offers, which is where honest mistakes, and agents, write.

## Keys: losing one

| Lost | What breaks | Recovery |
|---|---|---|
| an agent's key | that agent cannot write; what it wrote stays valid | `rekey <principal>`: a new key, added to every register's roster in one sitting |
| every agent's key (the volume was reset) | no agent can write | `rekey butler framework tooling seed scribe secretary tester` |
| an agent's key, maybe stolen | nothing yet | `rekey --replace <principal>`: a new key, and the old one removed; what it signs after is refused |
| an operator's key | no roster can change; everything else works | keep its anchor line; add a line for a new key (`ssh-keygen` on the host) |
| an operator's key, stolen | it could add keys | retire its anchor line: `until=<the last entry id it signed that you trust>` |

Never delete an anchor line. Every entry it vouched for, and everything after them, would be
refused (SPEC.md, "Anchors"). Keep two anchors (two operators, or a second key kept offline), so
that losing one never leaves the rosters closed. Agent keys need no backup: `rekey` replaces them.
An operator's key on the host is the one key worth backing up (a password manager, or a hardware
key).

## Tasks

Every task runs `agentic-register <task>`. Arguments go after `--`, including
`--register <name>`.

| Task | What |
|---|---|
| `agentic-register:version` | What is installed: the version, the format version, Python, `ssh-keygen`. |
| `agentic-register:registers` | The registers: name, type, store, how many entries. |
| `agentic-register:setup` | Re-runs the post-create setup. Idempotent, never fatal. |
| `agentic-register:check` | One line per part (Python, `ssh-keygen`, home, store, anchors, your key). Exits non-zero when not ready. |
| `agentic-register:key` | `new <principal>` or `show <principal>`: a signing key, and the line for the anchors file or a roster. |
| `agentic-register:rekey` | An operator gives agents new keys, because they were lost or with `--replace`, and adds them to every register's roster in one sitting. A key still there and on the roster is left alone. |
| `agentic-register:roster` | An operator adds a key to a register's roster (`--add-key`, `--principal`, `--role`) or removes one (`--remove-key`). |
| `agentic-register:add` | Signs an entry as the next in your chain and puts it in the register's store. |
| `agentic-register:verify` | Checks every entry of the register. Exits non-zero on a refused entry (including one of another register), a held entry or a fork no operator has ruled on. |
| `agentic-register:forks` | The register's forks (one key writing two entries as one `seq`), each with its entries and whether it is ruled. |
| `agentic-register:rule` | An operator settles a fork: `--keep <entry id>`. The key goes on from that side; the other side stays, flagged `ruled-out`. |
| `agentic-register:prune` | An anchor lets a store leave out what a ruling ruled out: `--ruling <entry id>`. Write it while the line is still there, then delete the line; what depended on it still verifies, and `verify` counts it as pruned (SPEC.md, "Pruning"). |
| `agentic-register:mirror` | Copies each way between the register's live store and its mirror (`--all`: every register that has one). Only adds, only valid entries; a pruned line is never copied back. |
| `agentic-register:sync` | Merges other store folders into the register's store (`--from`, `--to`). Another register's entries never come in. |
| `agentic-register:show` | The register as Markdown, with what needs a person first. A backlog shows as a `TODO.md`. |
| `agentic-register:import` | Backfill: a Markdown ledger (`--markdown`) or a run log (`--runs`) into a ledger, a `TODO.md` (`--todo`) into a backlog. Each record is marked `backfill`, and importing twice adds nothing. A Markdown import names a code fence that nothing closes (read as text) and each dated heading a fence hides. |
| `agentic-register:watch` | The change feed: entries new since a cursor, one JSON line each, then the next cursor. `--follow` keeps going. The cursor is the register's heads, so an entry merged in late is never skipped. |
| `agentic-register:query` | Read-only SQL on a freshly built index of the register (`entries`, `parents`, `heads`, `flags`, `forks`, `held`, `refused`, and its type's views). |

### Conversations

On a `messages` register (the first one of that type, unless `--register` names another):

| Task | What |
|---|---|
| `agentic-register:threads` | The threads you are in, with unread counts (sub-threads rolled up). |
| `agentic-register:thread` | One thread: its messages, members, sub-threads and tasks. `--mark-read` moves your read marker to its end. |
| `agentic-register:inbox` | What is unread for you, per thread, and your open tasks. `--notice` gives one line for a turn hook ("Mail for tooling: 1 unread in standup (+1 in sub-threads); 1 open task: ... from butler."), or nothing, and never fails a turn. |
| `agentic-register:new-thread` | Starts a thread: `group` (default) or `direct` (two members), or a sub-thread with `--parent`. |
| `agentic-register:send` | Posts a message: `--thread`, `--text`, and optionally `--reply-to`, `--mention`, `--ref`. Prints the `message_id`. Refuses a thread that does not exist or that you are not in. |
| `agentic-register:mark-read` | Moves your read marker in a thread. |
| `agentic-register:invite`, `leave` | Membership: a member invites; anyone leaves. |
| `agentic-register:ask` | A request: a message and an A2A task for `--to`. Prints the task id. |
| `agentic-register:tasks` | The tasks you asked for or were given; open ones unless `--all`. |
| `agentic-register:task-status` | The assignee moves a task on (`working`, `input_required`, `completed`, `failed`, `rejected`); its creator may cancel it. |

Every one takes `--json` for a stable machine output, and each has an MCP tool of the same name.

## MCP

`agentic-register mcp` serves these tools over stdio. Each runs the same command as the task of the
same name (listed in `mcp.json`) and takes a `register` argument where the task does:
`agentic_register_version`, `agentic_register_registers`, `agentic_register_forks`, `agentic_register_check`,
`agentic_register_add`, `agentic_register_verify`, `agentic_register_sync`,
`agentic_register_show`, `agentic_register_query`, `agentic_register_watch` (no follow: pass the cursor back), and the conversation tools (`agentic_register_threads`, `thread`, `inbox`, `new_thread`, `send`, `mark_read`, `invite`, `leave`, `tasks`, `ask`, `task_status`). `key`, `rekey`, `roster`, `rule`, `prune`, `import` and `setup` are
for people only and have no tool. Setup registers the server with Claude Code at user scope, in an
installed Feature only (`registerMcp`); run from a source copy, it never does. Registering again
changes nothing. The `mcpTools` option limits the tools it offers, for example
`version,registers,forks,check,add,verify,show,query` for a ledger and nothing else. A register's
guard runs on every tool that writes.

## State

`AGENTIC_REGISTER_HOME=/var/lib/devcontainer-features/agentic-register`, on the named volume
`agentic-register-state-${devcontainerId}`, which survives rebuilds:

| Path | What |
|---|---|
| `keys/<principal>` | Signing keys (private, mode 600). A credential: it never leaves the volume. |
| `anchors` | The operator keys this reader trusts. |
| `checked` | The reader's own record of signatures already checked. |
| `index/<register>.db` | The index `query` builds. It is rebuilt each time and is never the truth. |
| `registers/<name>/` | A register's store, when its `store` is not set: the live store, which a `mirror` copies into the repository. |

A volume is lost when the container engine's storage is reset. Keep keys you cannot lose
somewhere else as well, or bind-mount the folder from the host.

## Implements

- **P2, continuous improvement.** The ledger register: every unit of work leaves an entry with
  its friction, its measures and the resources it used. Records are append-only, and a
  correction is a new entry.
- **P4, claims need evidence.** An entry is signed by who wrote it, cannot be changed unnoticed,
  and cannot be replayed into another register. Forks and disagreements go to a person.
- **P3, the agent knows its place.** Each register's roster says who may write it.

Oracle records this in the book, and Gordon makes it a default of the seed.

## Inside

- `register/core.py` holds the format (versions 1 and 2), the checks, the roster, merging and
  order, with no storage. `register/types.py` holds the register types. `register/adapters.py`
  holds `sync`, `add`, the `dir` store, the `sqlite` index and the `markdown` view.
  `register/backlog.py` is the backlog type. `register/backfill.py` imports older ledgers. `register/cli.py` is the command and
  `register/mcp.py` the server. They need Python 3.11 and OpenSSH's `ssh-keygen -Y`, nothing
  else.
- Tests are in `aof/tooling/test/agentic-register/`: the format (`test_core.py`), registers
  (`test_registers.py`), the guard and the MCP tool list (`test_guard.py`), losing keys (`test_keys.py`), the backlog type (`test_backlog.py`), the adapters (`test_adapters.py`), the backfill (`test_backfill.py`),
  and the installed Feature (`test_feature.py`). Keys are made fresh on each run. The scenarios
  for `devcontainer features test` need a container engine, so CI runs them.
- The storage is an adapter. A store needs only put-if-absent, get and list, so a sturdier
  product can replace the folder without changing the format or any reader.

| Step | What | Status |
|---|---|---|
| A | Format 2, register types, the ledger as the first register | done (#30) |
| B | The `backlog` type: changes, and the backlog they add up to | done (#34) |
| C | The `agents` type: the agent registry, an OASF 1.1.0 record | done (#59) |
| D | The `messages` type (#71), its commands and MCP tools (#77), the change feed (#78), the notice | this |

## Changes

- 0.14.4: `--key` may name a private key without its `.pub` beside it: the public half is read from
  the OpenSSH key file itself, without its passphrase. A key file that holds none is refused in one
  line naming the `.pub` it needs, not a traceback; a passphrase-protected one without an SSH agent,
  in one line naming `ssh-add`. `rekey` and `roster --add-key` say
  `--role agent` when a role is missing. `rekey --replace` retires a key whose `.pub` is gone, and
  still takes it off the rosters. ADOPTING-ledger-file.md, step 2: the route where no SSH agent
  reaches the manor, and what it does not protect against.
- 0.14.3: `import --markdown` no longer drops every entry after a code fence that nothing closes.
  A fence still open at the end of the file is read as text, and the dry run and the import say
  where it is. A dated entry heading inside a fence that does close (a template) is still not an
  entry, but each one is now named, so a fence that hides real entries shows before the import.
- 0.14.2: a store or mirror on a folder without hard links (rclone's FUSE mount, OneDrive, SMB)
  works: a put falls back to an exclusive create, which still never replaces an entry, instead of
  failing with a traceback. A file cut short under an entry's name is replaced by the next put.
- 0.14.1: `send` and `ask` refuse a thread that does not exist or that the writer is not in,
  saying so, and write nothing. Before, the entry was signed and kept, but no member ever saw it.
- 0.14.0: a register's `guard`, the adopter's own check on every entry before it is written
  (see "A guard"); removing a key passes without it (D79). An `mcpTools` option limits the MCP
  tools the server offers. Setup run from a source copy (no `options.env`) never registers the MCP
  server. The Markdown importer reads older ledgers' shapes (review sections, entries without the
  bold, `Corrects: none`, tags in backticks or naming a skill, several tags on one friction line).
  Contributed by an office planted from the seed, reviewed and adapted here.
- 0.13.2: the `registers` option has a quote-free form, `name:type[:store][:mirror=<folder>]`
  entries separated by `;`, and the README, `ADOPTING.md` and `ADOPTING-ledger-file.md` show it. The
  JSON form these pages showed before never worked in a real build: the devcontainer CLI strips its
  quotes. JSON escaped for the shell (`\\\"` in `devcontainer.json`) still works. A value the
  install cannot read now fails showing the value received and a hint.
