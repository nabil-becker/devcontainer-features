## How it fits

```text
  party A (a dev container)                party B (another container or machine)
  packet-relay send / sync                 packet-relay sync
        |  writes only <root>/<domain>/A/        |  writes only <root>/<domain>/B/
        v                                         v
  the shared folder (a host folder bind-mounted into each, or a synced cloud folder)
        |  packets and signed acknowledgements, each file written once
  $PACKET_RELAY_HOME (keys, members, chains, inbox, quarantine; named volume per container)
  egress / ingress guards (for example phi-check) run on every packet
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Each party's signing key, members and anchors files, chains, inbox and quarantine | `/var/lib/devcontainer-features/packet-relay`, the Feature's named volume | 4 working set (losing it needs a new key; see "State") |
| Packets and acknowledgements in transit | the shared folder (`root`), removed once every party took them | 2 shared folder (or a host folder) |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: none yet

## What it is

A file transport on sign-packet (AOF ADR 0024, decision 3). Parties exchange signed packets through a
folder each of them mounts: a host folder bind-mounted into several dev containers, or a cloud
folder (OneDrive) synced to several machines. Delivery is reliable, ordered per sender and
exactly once, as TCP's is, over files: the folder's own sync carries them, and the protocol does
not depend on its timing. The protocol is [SPEC.md](SPEC.md).

- Each party writes only its own subfolder, and each file once.
- A receiver takes each sender's packets in order; a gap waits.
- It acknowledges with a signed packet of its own; a sender removes a packet only after every
  party has taken it, and writes a lost one again.
- A gap lost for good is skipped only on an operator's signed word.
- A reader takes only packets of the parties in its own members file.

It is a Python library (`packetrelay`) and one command, `packet-relay`. It runs nothing in the
background: a party syncs when it is asked to (`packet-relay sync`). In AOF, the mailbox's shared
threads and federated registers (AOF's agentic-register) were its first users.

It came from the private AOF repository (the Agentic Operating Framework), where it was published
to that repository's private registry up to 0.3.0; this
collection carries it on from 0.4.0 under the same id. "AOF ADR nnnn" in these files names a
decision record of that repository, not one of this collection's `docs/adr/`.

## What it installs

- `/usr/local/lib/packet-relay/packetrelay/`, the library, `SPEC.md` (the protocol) and
  `options.env` (the options, read by the command).
- `/usr/local/lib/packet-relay/signpacket/`, this Feature's own copy of sign-packet's library (a
  verbatim copy of `src/sign-packet/signpacket/`, kept by `task signpacket:sync` and checked by `task
  signpacket:check`): the command finds it first, so no sign-packet Feature is needed and the order
  of Features never matters.
- `/usr/local/bin/packet-relay`, the command (run isolated, `python3 -I`), and
  `/usr/local/bin/packet-relay-setup`, the post-create hook.
- `/usr/local/libexec/packet-relay/dcf-persist`, this collection's `dcf-persist` (a verbatim copy of
  `src/common/dcf-persist.sh`, kept by `task common:sync`), in a folder of the Feature's own so the
  installer runs unchanged under a test's `DESTDIR`.
- Nothing is downloaded. When `python3` (3.11 or later) or `ssh-keygen` is missing, `install.sh`
  installs `python3` and `openssh-client` from the distribution's apt sources. A `guard` that
  cannot be used fails the install.

## Using it in devcontainer.json

```jsonc
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/packet-relay:0": { "root": "/mnt/relay" }
},
"mounts": ["source=<a host or cloud folder>,target=/mnt/relay,type=bind"]
```

## Verify

```sh
packet-relay version   # packet-relay 0.4.0 (sign-packet 0.6.0), then python, the library and the home
packet-relay check     # one line per part; NOT READY while the shared folder is not mounted
```

## Parties

Once per party, on its own machine or container:

```
packet-relay key new alice                       # prints "alice ssh-ed25519 AAAA..."
# every party's line goes into each party's members file, $PACKET_RELAY_HOME/members/<domain>
packet-relay send --domain talk --as alice --kind note --data '{"text": "hello"}'
packet-relay sync --domain talk --as bob         # takes it, acknowledges it
packet-relay sync --domain talk --as alice       # sees the acknowledgement, removes it
```

Operators who may skip a lost gap go into `$PACKET_RELAY_HOME/anchors`, in the same form. The
members and anchors files are each party's own configuration; nothing in the shared folder says
who may write.

## Options

| Option | Default | What it does |
|---|---|---|
| `installTaskfile` | `true` | Installs `taskfile.yml` into `/usr/local/share/go-task/includes.d/packet-relay.yml`, so the tasks below appear under `packet-relay:` (the go-task Feature). |
| `root` | `""` | The shared folder, as mounted in the container. Empty: give `--root` or set `PACKET_RELAY_ROOT`. The mount itself is the `devcontainer.json`'s. |
| `guard` | `""` | Egress guards: commands, separated by `;`, run on every packet this party sends, before it is signed (see "Guards"). Empty: none. |
| `ingressGuard` | `""` | Ingress guards: the same, on every packet this party would take; a refused one is quarantined. Empty: none. |
| `guardTimeout` | `10` | Seconds each guard has to answer (0 to 300); no answer refuses. |

## Tasks

| Task | What it does |
|---|---|
| `packet-relay:version` | The packet-relay and sign-packet versions, Python, the library and the home. |
| `packet-relay:setup` | The home in the volume and its `keys/` and `members/` folders (idempotent, never fatal). |
| `packet-relay:check` | One line per part (Python, ssh-keygen, the home, the shared folder); non-zero when one is not ready. |
| `packet-relay:key` | `-- new <party>` or `show <party>`: the party's key, and its line for the members file. |
| `packet-relay:send` | `-- --domain <d> --as <party> --kind <kind> --data '<json>'`: one packet, written once. |
| `packet-relay:sync` | `-- --domain <d> --as <party>`: one round (take, acknowledge, remove what all took, write again what was lost). Non-zero on a fork or a refused file. |
| `packet-relay:status` | `-- --domain <d> --as <party>`: what was sent, taken and acknowledged. Writes nothing. |
| `packet-relay:skip` | `-- --domain <d> --as <operator> --party <p> --from <seq> --through <seq> --id <id>`: an operator vouches that a gap is lost for good. |

Every task runs the `packet-relay` command, with `--json` for machines. No MCP server.

## State

`/var/lib/devcontainer-features/packet-relay` (`PACKET_RELAY_HOME`), on the named volume
`packet-relay-state-${devcontainerId}`: `keys/` (each party's signing key, never replaced),
`members/<domain>`, `anchors`, and per domain and party `<domain>/<party>/`: `state.json` (its
chains, what it took, any fork), `checked` (signatures already checked), `outbox/`,
`inbox/<sender>/` (every packet taken, named by seq) and `quarantine/<sender>/` (every packet an
ingress guard refused, with its `.reason`). A rebuild keeps it. The home must not be
inside the shared folder, nor the folder inside the home: the command refuses either.

Losing the home loses the party's chains. A party whose packets are still in the folder then
refuses to send from seq 1 again, since that would fork its chain: it needs a new key, a new line
in every party's members file, and a fresh home for that domain (a home refuses a key other than
the one that made its chains).

## Guards

A guard is a command run on a packet's body (sign-packet's SPEC.md, "Guards"): it exits 0 to let
the packet through, and anything else refuses it, failing closed. packet-relay runs them in both
directions, from its options only: the command runs isolated (`python3 -I`), so no `PYTHONPATH` or
user site stands in for the code that runs them.

```jsonc
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/phi-check:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/packet-relay:0": {
    "root": "/mnt/relay",
    "guard": "/usr/local/bin/phi-check --no-exceptions --stdin-filename packet -",
    "ingressGuard": "/usr/local/bin/phi-check --no-exceptions --stdin-filename packet -"
  }
}
```

- `guard` (egress): a packet refused is not sent, and nothing reaches the folder.
- `ingressGuard`: a packet refused is still taken in its sender's order and acknowledged, so
  nothing after it waits, but it goes to `<home>/<domain>/<party>/quarantine/<sender>/` with a
  `.reason` file (folders 0700, files 0600), never to the inbox. `sync` names it (`QUARANTINED`)
  and exits 1. An operator who releases one copies it from there.
- A guard that cannot run, times out or is killed refuses nothing: that sender is held for the
  round, nothing is acknowledged, and `sync` says `GUARD FAILED`. The sender keeps its packet.
- What a guard is not: a boundary against code running as the same user, which can read the key and
  write the folder itself. The egress guard stops mistakes; a receiver's ingress guard is what holds
  against what others send.
- The phi-check Feature is the first guard: it refuses protected health information and never
  prints it. A guard runs with a fixed `PATH`, so a script's interpreter must be on it (phi-check
  uses the distribution's Python, `/usr/bin/python3`).

## What it does not check

Without guards, packet-relay signs and carries what it is given: it does not look inside. The shared folder's
provider (the host disk, OneDrive) stores every packet in clear. What must not go there (a
person's name, an email address, a credential) is the sending layer's to refuse, before it
signs, or packet-relay's own egress guard (see "Guards"). Party names go into
every packet: use role names (`host`, `scribe`), not people's names.

## Implements

The AOF book's exchange of **records** between stacks (AOF ADR 0024): each record crosses as the
sign-packet packet it is, signed by its writer and named by its hash, so a receiving stack checks
it as it would its own.

## Tests

`test/packet-relay/unit/` (`task test:packet-relay-unit`, part of `task lint`): `test_relay.py` (two parties, three, a party away, a lossy
folder, a slow partial sync between two machines' copies, forged and misplaced files, a fork, a
gap lost for good and its skip, a lost state, a folder without hard links, the command) and
`test_feature.py` (install.sh into a throwaway root).

## Pairs with

- **sign-packet**: the packets are its packets. packet-relay carries its own copy of the library,
  so the sign-packet Feature is not needed.
- **phi-check**: the first guard, on egress and ingress (see "Guards").
- **cloud-folder**: a shared folder synced between machines can be the `root` (one folder per
  writer, each file written once, so a sync never merges a file).
- **register-engine** (and AOF's agentic-register): a federated register moves its entries through
  packet-relay.
- **go-task**: the Feature Taskfile. Needs Python 3.11 and OpenSSH 8.1 (installed with apt when missing).

## Limits

- Nothing runs in the background: a party moves packets only when `packet-relay sync` runs.
- A party that goes quiet holds the senders' files until an operator takes it off the members list;
  there is no timeout.
- The shared folder's provider sees every packet in clear (see "What it does not check").
- The setup script's helper lives in `/usr/local/libexec/packet-relay/`, not
  `/usr/local/bin/dcf-persist` as other Features of this collection install it; the file is the same.
- The volume is `packet-relay-state-${devcontainerId}`, not this collection's usual `-config-` name,
  so a container that ran the AOF package keeps its keys and chains.
- Troubleshooting: `packet-relay check` names the part that is not ready; `packet-relay status`
  shows what was sent, taken and acknowledged; `sync` names a refused file, a fork, a quarantined
  packet (`QUARANTINED`) or a guard that failed (`GUARD FAILED`).

## Why it exists

No published Feature moves signed records between dev containers through a plain folder. File sync
tools (rclone, OneDrive) copy files but promise no order, no delivery and no authorship;
packet-relay adds those on top of any folder the parties share, with nothing listening on a port.

## Version and upgrade

Pin the major (`:0`) or an exact version (`:0.4.0`). A rebuild takes a new one and keeps the home
in the volume; the protocol (SPEC.md) reads what earlier versions wrote (0.3.0's acknowledgement
list, and 0.2's map). The vendored sign-packet library moves with this Feature's version.
