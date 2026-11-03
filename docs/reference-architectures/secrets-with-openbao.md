# Secrets with OpenBao

OpenBao keeps every secret the collection creates or stores; `ssh-agent` only uses keys. The decision is
[ADR 0048](../adr/0048-openbao-keeps-every-secret-and-ssh-agent-only-uses-keys-with-a-bounded-loss-exception-to-adr-0045.md),
the design is phase 1 of the approved proposal [secrets-master-split](../proposals/secrets-master-split.md).
This page draws that design and says, piece by piece, what is published today and what is not built.

## Who it is for, and when to use it

Use it when an engineer or a consumer's maintainer wants one place for private keys (ssh, git signing, a
register's operator key), tokens (`gh`, Azure, the cloud folder's login) and their lifecycle, opened by one gate:
the Operator unseals the server once per server start, and logs in once per sitting.

Two shapes, both phase 1:

- **Client mode, against a central server.** The container has the `bao` CLI and `BAO_ADDR` points at a server
  somebody runs. This meets ADR 0045 as it stands, because the server owner's storage holds the data. Choose it
  when a team already has, or will stand up, a server.
- **Server mode, local, with backups.** The container runs its own server (raft on the Feature's volume, loopback
  only, sealed until unsealed), and `openbao:backup` copies snapshots to a path you choose. Choose it for one
  machine and no server. It is a named, bounded-loss exception to ADR 0045: a machine loss loses at most what was
  written since the last backup, a window the Operator accepts and chooses at `openbao:init` (a destination, or an
  explicit "no backup").

Out of scope here: anything the proposal defers to a later phase.

## What exists today

Read this before you copy the fragment. The build has not started beyond the published CLI.

| Piece | Published today | Planned in phase 1 (proposal section 12) |
| --- | --- | --- |
| `openbao` client | `bao` at `/usr/local/bin/bao`, checksum-verified, `openbao:version`, `:status`, `:login`, `:kv:get`; no volume: a rebuild deletes `~/.vault-token`; `version` and `installTaskfile` are its only options | 1.1.0: the state volume, `dcf-secret`, the `mode` option (`client` only) |
| `openbao` server mode, backup, restore, onboarding | not built | 1.2.0 server mode and the gate; 1.3.0 backup and restore; 1.4.0 onboarding |
| `ssh-agent` | socket mode, and key mode with its own key volume and `key:unlock` / `key:lock` | 1.4.0: `key:load` and `key:lock` of a key fetched from OpenBao, with a lifetime; 2.0.0 removes the key volume |
| `gh`, `az` | each owns its login in its own volume | last slice: the long-lived credential in OpenBao, fetched with `dcf-secret` at the start of a sitting |
| ADR 0048 | accepted 2026-11-03; ADR 0046 (the passphrase unlock) is superseded, but its flow carries on until `ssh-agent` 1.4.0 ships | |

The fragment below uses only options that exist now. What server mode adds is in a second, planned fragment,
which `task lint` keeps honest: it must keep failing until the options exist, and says so the day it passes.

## Diagram

```text
                       the Operator                      (a person: unseals, logs in)
        unseal: once per server start (3 shares, threshold 2)      login: per sitting (4 h, at most 8)
                              |                                        |
 CONTAINER                    v                                        v
 +--------------------------------------------------------------------------------------------+
 |  openbao Feature                                                                           |
 |   client mode: bao CLI, BAO_ADDR ----------------------------------------> CENTRAL SERVER  |
 |                                                                  (owner-run, its storage)  |
 |   server mode: bao server 127.0.0.1:8200, sealed at start, raft -----+                     |
 |                  KV "dcf":  ssh/<key>  register/<principal>  token/<name>                  |
 |                  auth: userpass (the Operator)   approle (backup; the backs, devhost's)    |
 |   dcf-secret get | put | status      the one door every caller uses; no fallback           |
 |                                                                                            |
 |  ssh-agent Feature       key:load NAME= MINUTES=    dcf-secret get | ssh-add -t <life> -   |
 |   SSH_AUTH_SOCK, fixed path   (key on stdin, never a file, lifetime <= the login token)    |
 |        |                                                                                   |
 |        +--> git commit -S      register entries      ssh     (host socket: the workstation's|
 |                                                              agent, not imported)          |
 |  gh Feature, az Feature   logins today in their own volumes; later fetched with dcf-secret |
 |                                                                                            |
 |  volume openbao-${devcontainerId} (tier 4):                                                |
 |    raft/  audit.log  approle/<role>/secret_id  last-backup  backup-choice  .vault-token    |
 +-----------------------------+--------------------------------------------------------------+
                               | task openbao:backup DEST=<path>   (server mode only)
                               v   openbao-<machine>-<UTC time>.snap, written once, never overwritten
                      DEST: any path you name, e.g. /mnt/cloud-folder/... (tier 2)

 WORKSTATION: password manager, paper and a second person or hardware key (the 3 unseal shares);
              the Operator's own agent keys; the scheduler entry that runs `task dc:exec -- task openbao:backup`
```

## `devcontainer.json`

What you can build today: the CLI in client mode, the agent socket, and the two Features whose logins move last.

```jsonc
{
  "name": "secrets-client",
  "image": "mcr.microsoft.com/devcontainers/base:debian",
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
    // Pin to the server's version: the CLI and the server agree, and `latest` moves between builds.
    "ghcr.io/nabil-becker/devcontainer-features/openbao:1": {
      "version": "2.7.1"
    },
    // Socket mode needs no option. On windows-docker and windows-wslc there is no socket to mount:
    // "keyMode": true keeps a dedicated key in the container's key volume until ssh-agent 2.0.
    "ghcr.io/nabil-becker/devcontainer-features/ssh-agent:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/gh:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/az:1": {
      "bicepFromPath": true
    }
  },
  "containerEnv": {
    // Client mode: the central server, owner-run. TLS, auth method, token lifetimes and backups are its owner's.
    "BAO_ADDR": "https://bao.example.com",
    "DCF_HOST_TYPE": "${localEnv:DCF_HOST_TYPE}",
    "DCF_HOST_SSH_AGENT": "${localEnv:DCF_HOST_SSH_AGENT}"
  },
  "remoteUser": "vscode"
}
```

Log in with `task openbao:login` (`-- -method=oidc` where the server offers it). Today a rebuild logs you out; the
stopgap in the Feature's notes is `BAO_TOKEN` in the container's environment, set from a variable on the host or an
env file kept out of git, and a stale value there beats a fresh login. The state volume (1.1.0) ends that.

The planned server mode adds the options below, from the proposal's section 3. They do not exist yet, so the block is
fenced `jsonc planned`; `task architectures:check` fails the day it would pass and tells you to move it up.

```jsonc planned
{
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/openbao:1": {
      "mode": "server",
      "backupDest": "/mnt/cloud-folder/openbao-backups",
      "backupKeep": "30"
    }
  }
}
```

Then, once, in a plain terminal (never in an agent's job): `task openbao:init` (3 shares, threshold 2; it asks for the
backup destination or "no backup"), `task openbao:unseal`, `task openbao:login`.

## Data and its storage tier

Tiers as in [ADR 0045](../adr/0045-four-storage-tiers-govern-where-data-lives-and-a-machine-loss-must-lose-nothing.md):
1 git, 2 shared folder, 3 personal folder, 4 working set. A secrets store is the one thing tier 4 cannot honestly
hold, which is why ADR 0048 names a bounded-loss exception for server mode and why client mode is the safe default.

| Data | Where it lives | Tier | If the container is rebuilt | If the machine is lost |
| --- | --- | --- | --- | --- |
| Secret values (keys, tokens), client mode | the central server's own storage | the owner's | untouched | untouched: ADR 0045 met as it stands |
| Secret values, server mode (planned) | raft store in volume `openbao-${devcontainerId}` | 4, under the named exception | kept | lost back to the last backup |
| Backups: ciphertext snapshots (planned) | the path in `DEST`, one new file per backup, the last `backupKeep` kept | 2 when `DEST` is the shared folder | untouched | restore the newest, unseal with the shares; a snapshot without the shares is useless, with them it is everything |
| The unseal shares: 3, threshold 2 | the Operator's password manager, paper kept offline, a second person or a hardware key | off the machine, by design; ADR 0045 does not classify it | untouched | untouched; never in git, the container or the shared folder |
| The recovery register key | offline, outside OpenBao (a named exception to "OpenBao keeps everything") | off the machine | untouched | reopens the register's rosters if the shares are lost |
| The Operator's login token | `.vault-token` in the volume (planned; today the container's own filesystem) | 4 | kept once the volume exists, else lost | login again |
| The backs' role ids and secret ids (planned) | `approle/<role>/secret_id` in the volume, loopback-bound | 4 | kept | reissued by `openbao:approle:issue ALL=1` |
| `last-backup`, `backup-choice`, the audit log (planned) | the volume | 4 | kept | rebuilt by the next init and backup |
| Public keys allowed to sign: `.devcontainer/allowed_signers` | the repository | 1 | untouched | untouched; the host commits it |
| A key loaded for a sitting | the agent's memory only, lifetime at most the token's remaining time | none | gone | gone |
| `gh` and `az` logins (today) | their own volumes `gh-config-...`, `az-config-...` | 4 | kept | `gh auth login`, `az login` |
| The ssh-agent key volume (today, until 2.0) | `ssh-agent-key-${devcontainerId}` | 4 | kept | import the key again |
| Keys the workstation holds | the workstation's agent, never imported | the workstation's own | untouched | untouched |

## On the workstation, and in the container

| On the workstation (host) | In the container |
| --- | --- |
| the three unseal shares' custody: password manager, paper, a second person or hardware key | the `bao` CLI; in server mode `bao server` on loopback, `dcf-secret`, the `openbao:*` tasks |
| the scheduler entry, the consumer's own, that runs `task dc:exec -- task openbao:backup` (a one-shot command, ADR 0026; the launcher registers nothing, ADR 0024) | `ssh-agent`: the socket, `key:load`, `key:lock`, `git:signing`, `git:verify`, `key:rotate`'s SSH steps |
| `task dc:ssh-add` into the host's agent (socket host types); the deprecated `dc:ssh-key-import` becomes a one-shot stream into `openbao:ssh:import FROM=file` | `gh` and `az`, whose credentials move into OpenBao in the last slice |
| the Operator's own keys in the workstation's agent | the Operator's login and sitting: every task that handles a share or a token refuses inside an agent's job |
| a central server, when there is one, run by its owner | the volume and the backups' destination path |

## Best practices

- **Pin `openbao`'s `version` to the server's.** The CLI and the server should agree, and `latest` is resolved at
  image build, so two builds a month apart differ.
- **Prefer a central server when you have one.** Client mode meets ADR 0045 outright. Server mode is for one machine
  with no server, and then the backup choice is made at `openbao:init`, never defaulted.
- **Keep the backups where a lost machine cannot take them, and the shares somewhere else.** A snapshot is
  ciphertext; the shares open it. They never share a place: not git, not the container, not the shared folder.
- **Unseal once per server start, log in once per sitting, and let the key's lifetime follow the token.** `key:load`
  fetches the key with `dcf-secret`, pipes it to `ssh-add -t <seconds> -` and says when it drops out; the key is
  never written to a file. Ledger entry 2026-11-03 "ssh-agent 1.3.0 adds timed key unlock and key lock" records the
  mechanism, tested on OpenSSH 10.0.
- **Sign with only the public key present.** `git:signing` and `git:verify` need the public half; the private half
  arrives and leaves with the sitting.
- **Ask for a secret through `dcf-secret` and nothing else.** Its exit codes (10 unreachable, 11 sealed, 12 no or
  expired token, 13 denied, 14 no such secret) are the same for every caller, so a caller fails with a line that names
  the fix.
- **One dedicated signing key per purpose and container**, registered at GitHub as a signing key only. The offline
  recovery key is the one secret that stays outside.
- **After a rebuild list what is gone**: the login, the unlocked key. The server, if local, is sealed until the
  Operator unseals it, and a back that finds it sealed stops and says so.

## Anti-patterns

### S1. The live store on the shared folder

- **Don't:** put raft's database on an rclone or OneDrive mount, or let the Feature depend on the shared folder.
- **Why:** 2026-11-03 "OpenBao storage decided: local instance, no shared folder": raft's database is written in
  place, memory-mapped and locked, none of the `cloud-folder` modes promises that, and a second machine could open the
  same store; 2026-11-03 "Ledger and register storage location answered; shared-folder mirror blocked by hard links"
  is the same mount failing a design that assumed it would work. OpenBao 2.7.0 also removed the `file` backend.
- **Instead:** the live store on the Feature's volume, backed up to a path in the shared folder.
- **Caught by:** ADR 0048 (decision 3; option 3 lost); nothing in the code yet, because server mode is not built.

### S2. A start hook that waits for a person

- **Don't:** let the start hook wait for an unseal, a passphrase or a login.
- **Why:** 2026-10-30 "Start hook no longer waits on ssh-add; passphrase prompt gets a bounded wait and a warning": a
  hook waiting on `/dev/tty` held every Feature's start for about 775 s.
- **Instead:** the server's start hook prints one line (`sealed; task openbao:unseal`) and returns; the Operator acts
  later, in a terminal.
- **Caught by:** `test:ssh-agent-unit` for `ssh-agent`; nothing yet for the server's hook (the proposal's test list
  names it).

### S3. A timed unlock that the next start undoes

- **Don't:** rely on a lifetime for a key the start hook would load again.
- **Why:** 2026-11-03 "ssh-agent 1.3.0 adds timed key unlock and key lock": an unprotected key unlocked with a
  lifetime is reloaded, without a limit, at the next start.
- **Instead:** `key:load` takes the key from OpenBao for the sitting only and the start hook never fetches from
  OpenBao; until 1.4.0, timed unlock is for protected keys.
- **Caught by:** the NOTES only; the backlog item for the start-hook reload is open.

### S4. A fallback source for a secret

- **Don't:** read a key from a volume, a file or an environment variable when `dcf-secret` fails.
- **Why:** no incident yet; ADR 0048 and proposal section 6 give the reason: a second source would be a second master,
  and a sealed server is meant to stop signing, since an agent that cannot reach the master must not find a key
  elsewhere.
- **Instead:** fail with the exit code and its one-line fix, and let the Operator unseal or log in.
- **Caught by:** nothing yet (the `dcf-secret` tests in slice 1 include "no fallback when sealed").

### S5. Shares or tokens in a transcript

- **Don't:** run `openbao:init`, `unseal`, `login`, `restore` or a wrap in an agent's job, or paste a share into a chat.
- **Why:** no incident yet; the scribe reads the session's transcript, and a share or a token printed in it is a
  secret in the ledger's input. ADR 0048 decision 4 makes the refusal a rule.
- **Instead:** a plain terminal; the tasks are interactive and refuse when a job environment (`DEVHOST_JOB_CHILD`) is
  set; `-pgp-keys` where new shares are printed.
- **Caught by:** nothing yet (built and tested per task in slice 2a).

### S6. A moving version against a pinned server

- **Don't:** leave `version` at `latest` when the server is pinned, or assume the storage backends of one release exist
  in the next.
- **Why:** no incident yet; proposal section 13 found that `latest` installs a release without the `file` backend
  (removed in 2.7.0) and the NOTES warn that a stale `BAO_TOKEN` makes `permission denied` appear right after a fresh
  login.
- **Instead:** pin `version` to the server's; unset or update `BAO_TOKEN` after a login.
- **Caught by:** nothing yet.

### S7. A certificate for GitHub signing

- **Don't:** rely on OpenBao's SSH certificates to make GitHub show a commit as verified.
- **Why:** 2026-11-03 "Secrets master split proposal written": GitHub's documentation describes verification against
  a public key added to the account and says nothing of SSH certificates, so it is not documented to verify them.
- **Instead:** a long-lived signing key in OpenBao, its public key registered at GitHub, `allowed_signers` in the
  repository.
- **Caught by:** nothing yet; the proposal's section 8 records the check.
