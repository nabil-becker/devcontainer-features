# Proposal: a key file on the workstation opens OpenBao, with no password

Status: Proposed 2026-11-04. Awaits the architecture review and the Operator. Build not started.
The password-reset task (`task openbao:password`, openbao 1.4.0) stays the stopgap until this ships.

Who this serves: the Operator, as the engineer who runs the `openbao` Feature in server mode in this
devhost and today types two unseal shares after every start and a password every sitting; and the
maintainers of the office and DSNP repositories, who adopt the `openbao` Feature and the launcher
(`task devcontainer:*`) and would get the key file as an option they choose, never as a change of
default.

How to read it: section 1 is the ask and the rulings it rests on; section 2 is what was checked on a
real `bao` (the static seal included); section 3 compares the two ways to build it and recommends
one; sections 4 to 9 are the design; section 10 states the threats plainly; section 11 is the slice
plan; section 12 the decisions for the Operator. The architecture review goes at the end.

## 1. The ask, and the rulings it rests on

The Operator's rulings (2026-11-04), as given:

1. **"I want a key file instead of an operator password."** A value or set of values made at init,
   kept in a protected file only the user can read. The three unseal shares (two needed) are used
   only when that file is lost or has to be rotated.
2. **The key file lives on the workstation, not in the container.** Inside the container Claude
   Code and the backs run as the same Linux user, so a mode-600 file there is readable by every
   agent; today agents are kept off OpenBao because unsealing and logging in need something a human
   types.
3. **"As long as I don't have to keep doing something once I create the key file."** After the
   one-time creation, nothing recurring: no typing at container start, rebuild, Windows reboot, a
   new session, or a login that runs past today's 8-hour `max_ttl`.
4. The password-reset task now being built stays as the stopgap until this ships.

Rulings it touches: `openbao-unseal-shares` (three shares, two to unseal, in three places, never in
git, the container or the shared folder), `openbao-login-lifetime` (4 hours, at most 8, no renewal
past that), ADR 0048 decision 4 (the gate), ADR 0050 and 0051 (what the Operator's token may do),
ADR 0024 and 0026 (the launcher runs one-shot commands on the host, never a background process),
ADR 0045 (a machine loss must lose nothing).

## 2. What was checked on a real `bao` (2026-11-04)

The backlog item `openbao-static-seal-check` asked for this before any design. The Feature's
`version` option defaults to `latest`; the devhost runs **OpenBao v2.7.2** (`bao version`), and
server mode needs 2.4.0 or later. Each line below was run against throwaway servers (raft, loopback,
other ports, in a scratch folder deleted afterwards), never against the devhost's own server.

| Question | Result on 2.7.2 | Source |
|---|---|---|
| Is there a `static` seal, and since when? | Yes, since **2.4.0** ("static key unseal mechanism", GH-1425); so every version server mode supports has it | changelog, docs `configuration/seal/static`, run |
| Key format | 32 bytes (AES-256-GCM); raw bytes in a file, or base64/hex inline or in an env var | docs, run |
| `current_key = "file://<fifo>"` | Works: the server reads the key once at start from a named pipe; nothing at rest | run |
| `current_key = "file:///dev/stdin"` | Works: the key piped into `bao server` | run |
| `current_key = "env://VAR"` | Works, but the value sits in `/proc/<pid>/environ` for the server's whole life, readable by every process of the user | run |
| A server whose key has not arrived | **Blocks before it opens its listener** (connection refused) until the key is written | run |
| Init on a static seal | `-recovery-shares=3 -recovery-threshold=2`: no unseal shares, three **recovery shares** | run |
| Restart with the key present | Unseals itself ("unsealed with stored key") | run |
| `generate-root` from recovery shares | Works (on 2.7 the attempt needs a token, as ADR 0051 says for the shares) | run |
| Key rotation | `previous_key` + `current_key`, one start, then the old key can go; data still readable | run |
| Shamir to static migration | Add the stanza, restart, `bao operator unseal -migrate` with two shares: the old shares **become the recovery shares**, data intact, unseals itself after a restart | run, docs |
| **Can recovery shares open the store if the key is lost?** | **No.** "Recovery keys cannot decrypt the root key, and thus are not sufficient to unseal"; a lost seal key loses the cluster "even from backups" | docs `concepts/seal` |
| A snapshot restored into a server with a different static key | Restore accepted, then the server seals itself: "failed to decrypt keys from storage" | run |
| A snapshot restored into a server with the same static key | Works, data readable | run |
| Shamir alternative: `rotate-keys` from 3 shares to 5, threshold 2 | Works (`sys/rotate/root/init` and `update`, two old shares); the server then reports `n` 5, `t` 2 | run |

Not confirmed: unsealing from two of the five shares after that rotation (the `bao operator unseal
-` stdin form answered "'key' must be a valid hex or base64 string" in the run; the
`sys/unseal` API, which the design uses, was not retried before the scratch server was removed).
That is the first test of slice 1.

The finding that shapes everything: **with the static seal, the shares cannot rebuild a lost key
file.** The host's sketch assumed they could. They only authorise (`generate-root`, rotating the
recovery shares, migrating back to Shamir *while the key is still there*). Lose the key and every
backup is lost with it.

## 3. Two ways to build it, and the one recommended

```
 A. static seal (the host's sketch)          B. Shamir, five shares, two in the key file (recommended)
 ---------------------------------------     --------------------------------------------------------
 key file = a 32-byte seal key + login        key file = unseal shares 4 and 5 + login
 3 custody shares = recovery shares           3 custody shares = unseal shares 1 to 3 (any two open it)
 lose the key file -> data lost, backups too  lose the key file -> two custody shares open it, as today
   unless a 4th custody copy of the key       rotate: rotate-keys, all five shares new
 rotate: previous_key/current_key, shares     migrate: rotate-keys 3/2 -> 5/2 (custody shares re-stored once)
   unchanged                                  start hook unchanged: server starts sealed, the launcher
 migrate: unseal -migrate, shares kept          unseals it through the API
 start hook changes: the server cannot start   no new OpenBao feature; works on every 2.x
   until the key arrives                      a snapshot opens with any two of the five
```

| | A. static seal | B. five shares, two in the file |
|---|---|---|
| Matches ruling 1 ("the shares are used only when the file is lost or rotated") | **No**: the shares cannot replace a lost key; a fourth custody item (an offline copy of the key) is needed or a workstation loss is a total loss | **Yes**: two custody shares unseal and make a new file |
| ADR 0045 (machine loss loses nothing) | only with that fourth custody copy | yes, as today |
| Rotation after a theft | the key only; custody shares stay | all five shares; the three custody shares are re-stored |
| Moving today's server | `unseal -migrate`; shares kept as recovery shares | `rotate-keys` 3/2 to 5/2; three new custody shares stored once |
| Start hook | must start the server with the key on a pipe, or wait for it; a server started by the hook without the key hangs before its listener | unchanged: starts sealed, never waits |
| What passes through the container at each start | the seal key, then held in the server's memory for its life | two shares, used for one API call and dropped |
| Second workstation, read-only restores | the master's key must be carried there | the master's two file shares must be carried there |
| Words | brings in "recovery key", which the lexicon already uses for the register's offline key | keeps "unseal share" |
| A key file + a backup | opens everything | opens everything |

**Recommendation: B.** It is the Operator's model as stated: the file is the everyday key, the
custody shares are the spare, and a lost file costs a rotation, not the store. A was tested and
works, and stays the fallback if the Operator prefers keeping the custody shares unchanged at a
rotation over needing no fourth custody item (decision 1).

The rest of this proposal designs B; where A would differ it says so.

## 4. What the key file holds, and where it lives

The key file is one blob per server, made once:

```json
{ "v": 1, "server": "<cluster id>", "repo": "<workspace folder name>", "created": "<UTC time>",
  "shares": ["<unseal share 4>", "<unseal share 5>"],
  "role_id": "<operator AppRole role id>", "secret_id": "<operator AppRole secret id>" }
```

- **Protected with DPAPI** for the Windows account (`[System.Security.Cryptography.ProtectedData]::Protect`,
  scope `CurrentUser`, with a fixed per-launcher entropy value), written as
  `%LOCALAPPDATA%\devcontainer-features\openbao\<repo>-<cluster id>.keyfile`. `%LOCALAPPDATA%` is not in
  OneDrive's known-folder move, does not roam, and is the folder the launcher already caches Node.js
  in. Never in OneDrive, the shared folder, the checkout or git. The plain JSON exists only in the
  launcher's memory.
- **Why not Windows Credential Manager**: pwsh has no built-in cmdlet for it (a P/Invoke or a
  module), a blob is capped at 2,560 bytes, and enterprise-persisted entries can roam to other
  machines. Why not `Export-Clixml` of a `PSCredential`: it is DPAPI underneath too, but it wraps a
  string in a format meant for passwords; `ProtectedData` takes the bytes as they are. Both are
  workable; the file is the simpler (decision 5).
- **What DPAPI does and does not protect**: the blob opens for any process running as the
  Operator's Windows account on that machine, and for nobody else (another account, a copy of the
  disk without the account's password, a stolen file). A workstation session of Claude Code runs as
  the Operator and could open it; CLAUDE.md already treats a workstation session as the exception.
- Under design A the blob holds the 32-byte seal key and its id instead of the two shares.

## 5. Start-up: what happens at every `task dc:*`

The launcher's `up` (and so `start`, `shell`, `claude`, `exec`, `rebuild`) gains one one-shot step
after `devcontainer up`: when the container's `openbao` Feature is in server mode with
`unlock: keyfile`, and the server is sealed or the Operator's token is missing or dead, the launcher
opens the key file and streams it into the container on standard input. A running, unsealed
container with a live token gets nothing (one status call, no secret sent).

```
 workstation (Windows, the Operator's account)               container (remote user, loopback only)
 ---------------------------------------------               ---------------------------------------
 task dc:up / dc:claude / dc:shell / rebuild
   | devcontainer up  -------------------------------------> postStart: openbao-setup start
   |                                                          bao server starts SEALED (as today;
   |                                                          the hook never waits, never prompts)
   | devcontainer exec openbao-setup unlock --status  -----> "sealed" | "no token" | "ready"
   |   "ready": stop here, nothing is sent
   | open %LOCALAPPDATA%\...\<repo>-<id>.keyfile
   |   (DPAPI, in memory only)
   | devcontainer exec -i openbao-setup unlock --stdin
   |   stdin <- {shares, role_id, secret_id}  ---------------> 1. PUT sys/unseal twice (shares 4, 5),
   |   (never an argument, an env var, a temp file,             from the read buffer, never on argv
   |    or a log line; nothing on the host keeps running)    2. AppRole login as `operator`
   |                                                          3. token -> the token helper
   |                                                             ($OPENBAO_STATE_DIR/token, as today);
   |                                                             the previous token revoked by accessor
   |                                                          4. renewer started (if not running):
   |                                                             renews the periodic token every 20 min
   | <---------------------------------------------- one line: "unsealed, logged in" or why not
   v
 the session starts; backs, dcf-secret, key:load all work; nothing was typed
```

- **Why `devcontainer exec` with stdin**: it is how `openbao-ssh-import` and `ssh-key-import`
  already hand a secret over (`Invoke-DevcontainerCliProcess`, ADR 0026). The key file differs in
  one way: it is written to the process's standard input from memory
  (`StandardInput.BaseStream.Write`, as the cloud-folder relay does), never through `-InputFile`,
  which would need a decrypted file on disk.
- **The postStart hook cannot receive it**: a devcontainer hook runs inside the container with no
  channel from the workstation, so the step belongs to the launcher, after `up`.
- **Windows reboot**: if the engine restarts the container on its own, it comes back sealed. It stays sealed until the
  next `task dc:*` command, which unseals it with no typing. A back that runs in between finds the
  server sealed and waits for its next run, as today.
- **A container started without the launcher** (VS Code "Reopen in Container") is not reached:
  it stays sealed until `task dc:openbao:unlock` on the workstation (no typing) or two custody shares
  at `task openbao:unseal` in the container (decision 8).
- **Design A** would differ here: `openbao-setup start` could not start the server (it blocks
  before its listener until the key arrives), so the start hook would wait for the launcher, and the
  launcher's step would start the server with the key on its standard input
  (`current_key = "file:///dev/stdin"`).

## 6. The login that outlives eight hours

Today the Operator logs in with `userpass` (a password, 4 hours, at most 8). Ruling 3 asks for a login
that needs nothing past that. The options weighed:

| Option | What stays in the container | What recurs | Verdict |
|---|---|---|---|
| a. AppRole from the key file, a **periodic token** renewed in the container | the token (as today) | nothing | **recommended** |
| b. AppRole with the secret id kept in the container, re-login on expiry | the secret id, which never expires: a permanent Operator credential at rest, readable by every agent | nothing | rejected: worse than (a) at rest and after a theft |
| c. Re-login fed from the workstation on a timer | the token | a workstation scheduler job every few hours | rejected: ADR 0024/0026 (the launcher never leaves anything running or registers a scheduler) and it stops while the laptop sleeps |
| d. Cert auth with a client certificate in the key file | the token | the same renewal problem as (a) | no gain over AppRole, and a certificate to issue and renew |
| e. Keep userpass, longer `max_ttl` | the token | typing the password once per start | fails ruling 3 |

The design for (a):

- **Role `operator`** (AppRole), made in the create step with a root token from the shares (ADR
  0050: making a role needs one). Policy: the Operator's policy as it stands (ADR 0050, 0051),
  unchanged. `secret_id_bound_cidrs` and `token_bound_cidrs` `127.0.0.1/32` (the login happens in
  the container), `secret_id_num_uses` 0, secret id kept **only in the key file**.
- **Token**: `token_period` **1 hour**, no `explicit_max_ttl`. Renewed every 20 minutes by a small
  renewer in the container (`openbao-setup renew`, started by `unlock`, its pid in the volume, like
  the backup timer). When the container stops the renewer stops and the token dies within the hour;
  the next `unlock` makes a new one and revokes the last by its accessor. `task openbao:logout` ends
  it at once, and the renewer exits on the first failed renewal.
- **userpass**: the `operator` user is deleted by the create step. A key-file server has no
  password; `task openbao:password` refuses there and says so.
- **What changes for "sitting"**: in a key-file server a sitting is the life of the container's
  login, from `unlock` to the container's stop or `openbao:logout`. The ruling
  `openbao-login-lifetime` stays for servers that keep the password (decision 3).

## 7. Lifecycle: create, rotate, lose, migrate, a second workstation

```
             task dc:openbao:keyfile:create  (one time; the Operator types 2 custody shares)
 today's server (3 shares, password) ---------------------------------------------------------+
      |  rotate-keys 3/2 -> 5/2 from 2 shares; root token from the shares (used once, revoked):   |
      |  make role `operator`, delete userpass `operator`; shares 1-3 printed once to the         |
      |  workstation console (the Operator stores them again, in the same three places);         |
      |  shares 4-5 + role id + secret id -> DPAPI key file                                      |
      v                                                                                         |
 [ key-file server ] <----------------------------------------------------------------------------+
      |   every start: task dc:* unseals and logs in (section 5); nothing typed
      |
      |-- key file deleted / workstation lost / profile reset
      |      server sealed at next start, the launcher says "no key file for this server"
      |      task openbao:unseal (2 custody shares, typed once) -> then keyfile:create again
      |      = rotate-keys (all 5 new: custody shares re-stored), new secret id, old one destroyed
      |
      |-- key file suspected copied (laptop stolen, a session that should not have read it)
      |      task dc:openbao:keyfile:rotate = the same rotate-keys and new secret id, from the
      |      key file's own two shares (no typing) or two custody shares; then a backup, and the
      |      old backups treated as opened (they still open with the old shares)
      |
      |-- second workstation (a read-only restore of the master's backups, ruling openbao-two-machines)
      |      the restored store carries the master's shares, so that machine needs the master's
      |      key file: task dc:openbao:keyfile:export on the master writes it encrypted with a
      |      one-time transfer passphrase; task dc:openbao:keyfile:import on the other machine
      |      reads it once, re-protects it with that machine's DPAPI and deletes the transfer file
      |
      '-- back to typing (the Operator changes their mind)
             unlock: operator (the option) + task openbao:password; the key file is forgotten with
             task dc:openbao:keyfile:forget, and a keyfile:rotate makes shares 4-5 worthless
```

- **Create on a new server** is `openbao:init` with `unlock: keyfile`, driven from the workstation:
  `bao operator init -key-shares=5 -key-threshold=2`, shares 1 to 3 printed once to the workstation
  console, 4 and 5 into the key file; no password asked.
- **Create on today's server is the migration**: the same command, from two custody shares. There
  is no separate migration step in design B. (Design A: add the seal stanza, restart,
  `unseal -migrate` with two shares, and the shares stay as recovery shares.)
- **The protocol of create**: the container side runs without a terminal, so the hidden prompts are
  the launcher's (`Read-Host -AsSecureString` on the workstation). The launcher sends the two shares
  on standard input; the container answers on standard output with one JSON object (the five
  shares, role id, secret id); the launcher keeps 4, 5 and the login in the key file and prints 1 to
  3 once. The container side refuses inside an agent's job (`DEVHOST_JOB_CHILD`, `CLAUDECODE`,
  `OPENBAO_AGENT_JOB_VARS`, exit 3), as every share-handling task does.
- **Onboarding** (`openbao:onboard:claim`) already runs `rotate-keys`: in a key-file server it makes
  five shares and ends by writing the key file the same way.
- **Backups**: unchanged. A snapshot opens with any two of the five shares, so the key file alone
  plus a backup opens everything (section 10).

## 8. The shares ruling, reconciled

`openbao-unseal-shares` says the shares are never in git, the container or the shared folder.

- **The three custody shares** (1 to 3) still never go in the container at rest. They are typed
  only to recover (a lost file) or rotate, at a hidden prompt, as `task openbao:unseal` takes them
  today; in design B's create step the prompt is on the workstation and the shares cross into the
  container's memory for the one API call.
- **The key file's two shares** are a different secret in the Operator's sense (ruling 1): they
  cross into the container's memory at each start, for two `sys/unseal` calls, and are dropped. They
  are never written to the volume, a log, an argument or an env var.

The ruling holds if "never in the container" is read as **never stored there**, which is also what
today's typed unseal does. The Operator confirms that reading (decision 2). Under design A the seal
key would live in the server's memory for the server's whole life, which stretches the reading
further.

## 9. Where it sits in the collection

| Part | Change |
|---|---|
| `openbao` (Feature) | option `unlock`: `operator` (default, today's typed unseal and password) or `keyfile`; `openbao-setup unlock --status` and `--stdin`; `openbao-setup renew`; the create, rotate and claim steps' JSON protocol on standard input and output; `server:status` shows the unlock mode and the renewer; `openbao:password` refuses in `keyfile` |
| `devcontainer-cli` (the launcher, `bootstrap/host`) | the DPAPI key-file store; the unlock step after `up`; `dc:openbao:keyfile:create`, `:rotate`, `:export`, `:import`, `:forget`, `dc:openbao:unlock`; Windows (pwsh) only at first |
| `devhost` (local) and `.devcontainer` | this devhost sets `unlock: keyfile`; the briefing's sealed line names `task dc:openbao:unlock` |
| consumers | nothing until they set `unlock: keyfile` |

The launcher already knows the `openbao` Feature by name (`openbao-ssh-import`); this adds one more
such call, behind a status command that answers "not keyfile" when the option is off, so a repo
without the Feature pays one failed `command -v`.

Linux, macOS and a WSL distro run the bash launcher, which has no DPAPI. There the unlock step says
the key file is Windows-only for now and the server stays as today (decision 9).

## 10. Threats, stated plainly

What the key file **changes**:

- No secret that unseals the store is at rest in the container, its volume, a rebuild or a backup
  destination. A copied volume or a stolen backup is still ciphertext without two shares, as today.
- No human types a share or a password in the normal course; nothing reaches a transcript.
- The backs work whenever the container runs, not only after the Operator has unsealed it.

What it **does not change**, and what gets worse:

- **A running container now always holds an unsealed server and a live Operator token.** The
  token file (`$OPENBAO_STATE_DIR/token`, mode 600) is readable by every process of the remote user,
  so every agent can act as the Operator through it. The NOTES and section 9 of
  `secrets-master-split` already say this of a sitting; today a sitting lasts at most 8 hours and
  starts only when the Operator types a password. With the key file it lasts as long as the
  container runs. **This is the main cost** (decision 4).
- **Passwordless `sudo`.** The remote user has it (checked), so any agent can become root, read the
  server's memory (the barrier keys, the token), or intercept the key file's bytes on their way
  through standard input. `kernel.yama.ptrace_scope` is 1, which stops a plain same-user agent from
  reading the server's memory, but not root. Today the same holds while the server is unsealed.
  Keeping agents out of OpenBao for real needs a separate user for agents and no passwordless
  `sudo`; not proposed here, a backlog item (section 13).
- **The key file is a quorum.** Its two shares open the store; with any backup they open
  everything ever backed up under those shares. Today two custody shares do the same; now one
  Windows account does too. DPAPI makes it as strong as the Windows login.
- **Agents' own logins** are unchanged: the backs keep their AppRole identities (loopback, one path
  each), and agents get their own narrow logins under `openbao-agent-login`, never the Operator's.
  The key file is not a way to give agents the Operator's rights; it is a way to stop asking the
  Operator to type.
- **Detection**: the audit log names the `operator` AppRole for every read, as it named the
  userpass login.

## 11. Slice plan: small stacked pull requests

Each with its version bump, CHANGELOG entry and `task docs`; the host commits, pushes and opens them;
the Operator merges and releases. openbao 1.4.0 (`task openbao:password`) is in flight in another
worktree and lands first.

0. **Records** (with the acceptance): an ADR "a key file on the workstation unseals OpenBao and logs
   the Operator in", amending ADR 0048 decision 4 (the gate) for `unlock: keyfile`, and the rulings
   it supersedes for key-file servers (`openbao-login-lifetime`) or reads anew (`openbao-unseal-shares`);
   the lexicon's "the gate", "sitting" and "unseal share" gain the key-file reading; a new term
   "key file".
1. **openbao 1.5.0** (minor: opt-in, default unchanged). The `unlock` option; `openbao-setup unlock`
   (status, stdin), `renew`; the create, rotate and claim JSON protocol; `operator` AppRole with the
   periodic token; `server:status` lines; `openbao:password` refusing in `keyfile`. Tests: unit
   (stub `bao`) for the stdin protocol, the refusals under the agent variables, the state folder
   holding no share after `unlock` and after a failed one, the renewer's exit on a failed renewal;
   a Docker scenario `server_keyfile` against real `bao` (create from three shares to five, restart,
   unseal from the two file shares through `sys/unseal`, AppRole login, the old share set refused,
   a rotation). Usable by hand by piping a JSON file, so it can be reviewed before the launcher.
2. **devcontainer-cli 1.20.0** (minor). The DPAPI store and the tasks of section 9; the unlock step
   after `up`; Pester tests: DPAPI round trip, the blob unreadable as another user (skipped where it
   cannot be made), no secret in the started process's arguments or environment, nothing written to
   `%TEMP%`, the step silent when the status says `ready`; the bash launcher's refusal line.
3. **devhost 1.13.0** (local) and `.devcontainer/devcontainer.json`: `unlock: keyfile`, the briefing
   line. Then the Operator runs `task dc:openbao:keyfile:create` once on the workstation (two
   custody shares, three new ones stored): a backlog item for the Operator.
4. Later, if wanted: the bash launcher (libsecret on Linux, the Keychain on macOS), devcontainer-cli
   minor.

Model sizing: slices 1 and 2 reach every consumer that pins `openbao:1` or runs the launcher, so
they are sized for the strongest model; slices 0 and 3 are Sonnet work. Releases: one per Feature,
started by the Operator; the devhost picks slice 1 up from the checkout before any release.

## 12. Decisions for the Operator

1. **Design B (five shares, two in the key file) rather than A (the static seal).** B keeps "the
   shares are the spare" true and needs no new custody item; A keeps the custody shares unchanged at
   a rotation but loses the store with the key unless a fourth custody copy of it is kept.
   *Recommendation: B.*
2. **The shares ruling reads "never stored in the container".** The custody shares stay out except
   when typed to recover or rotate; the key file's two shares pass through the container's memory
   at each start. *Recommendation: yes.*
3. **The Operator's login becomes an AppRole from the key file with a 1-hour periodic token renewed
   in the container**, no maximum, ended by the container's stop or `openbao:logout`; the userpass
   user is deleted on a key-file server; `openbao-login-lifetime` stays for servers that keep the
   password. *Recommendation: yes.*
4. **Accept that a running key-file container always has an unsealed server and a live Operator
   token** that any agent there can use (and, with passwordless `sudo`, the server's memory), and
   open a backlog item to give agents their own Linux user without passwordless `sudo`.
   *Recommendation: accept, and open the item.*
5. **The key file is a DPAPI-protected file under `%LOCALAPPDATA%`**, not Credential Manager.
   *Recommendation: yes.*
6. **No fourth custody item.** A lost key file is replaced from two custody shares by a rotation
   (the three custody shares are stored again). *Recommendation: yes (follows from 1).*
7. **A second workstation gets the master's key file by export and import** with a one-time
   transfer passphrase, carried by the Operator's own means, never through the shared folder or
   git. *Recommendation: yes.*
8. **A container started without the launcher stays sealed** until `task dc:openbao:unlock` (no
   typing) or two custody shares in the container; the launcher does not try to reach VS Code's
   start. *Recommendation: yes.*
9. **Windows first**: the bash launcher (Linux, macOS, a WSL distro) refuses the key file with one
   line until slice 4. *Recommendation: yes.*
10. **An opt-in option** `unlock: operator | keyfile` on the `openbao` Feature, default `operator`;
    this devhost sets `keyfile`. *Recommendation: yes.*

## 13. For the repository (found while writing)

- `openbao-static-seal-check` is answered by section 2 (works on 2.7.2, since 2.4.0; recovery
  shares cannot replace a lost key); the backlog item can be ticked with that note.
- The lexicon's **Recovery key** is the register's offline key; OpenBao calls an auto-unseal
  server's shares "recovery keys". If design A is ever chosen, call them **recovery shares** to keep
  the two apart.
- Agents and the Operator share a Linux user with passwordless `sudo` in the devhost; every
  "readable by the remote user" line in the openbao NOTES is also "readable by every agent, and
  root by `sudo`". Worth its own backlog item (decision 4).
- `bao operator unseal -` (a share on standard input) refused a share in the run; the tasks today
  use `bao`'s own prompt. Check it before any task pipes a share to the CLI rather than the API.

## Architecture review (2026-11-04)

Reviewed cold against the proposal, `docs/principles/non-functional-requirements.md`, `docs/adr/`
(0024, 0026, 0045, 0048 to 0052), `LEXICON.md`, `src/openbao/NOTES.md`, the launcher
(`bootstrap/host/DevcontainerCli.psm1`, `bootstrap/devcontainer.yml`) and
`docs/proposals/secrets-master-split.md` section 9. Who it serves: the Operator running server mode,
and consumers' maintainers who would opt in.

**Verdict:** fit with changes

The choice of B over A is sound and the section 2 evidence supports it: the static seal's recovery
shares cannot rebuild a lost key, so A needs a fourth custody item. The placement (DPAPI in the
launcher, the stdin protocol and the option in the Feature, the setting in the devhost) follows ADR
0024. Two findings must be settled before slice 1 is built: as designed, losing the key file or the
machine leaves no way to get a token back (finding 1), and the threats section understates what a
same-user agent can take (finding 2).

### Requirements (NFRs), one line each

- **NFR-1 owns-its-state**: met. The token, the renewer's pid and the unlock mode live in the
  Feature's volume (sections 5, 6). The key file is the launcher's host-side state, as the Node.js
  cache already is (but see finding 10).
- **NFR-2 registered-taskfile**: met if every new `dc:openbao:*` task and Feature task gets a `desc`
  (section 9). `openbao-setup unlock` is a script subcommand the launcher calls, as
  `openbao-ssh import` already is.
- **NFR-3, NFR-4, NFR-9, NFR-11**: do not apply (no download, no official Feature, no check tool).
- **NFR-5 idempotent-and-user-neutral**: met. The start hook is unchanged and never waits
  (section 5), and `unlock` run twice answers `ready` and sends nothing.
- **NFR-6 one-way-to-configure**: partly met. The option `unlock` is named, but its override
  variable is not (finding 13).
- **NFR-7 agent-ready**: not yet met. `dc:openbao:keyfile:create`, `:rotate`, `:export` and `:import`
  prompt, so they must be marked `interactive: true`, and they need a host-side agent guard
  (finding 9).
- **NFR-8 documented-to-the-standard**: met if slice 1 adds the option, the new tasks, the
  Windows-only limit and the recovery route to the NOTES. Slice 1 does not list the NOTES.
- **NFR-10 tested-on-base-images**: met. The `server_keyfile` scenario covers the new option value
  (slice 1). It must also cover the recovery routes in findings 1 and 11.
- **NFR-12 vendor-neutral-contracts**: does not apply. No agent CLI contract is touched; the guard
  reuses `OPENBAO_AGENT_JOB_VARS`.
- **NFR-13 manages-the-environment-not-the-cli**: partly met. The design uses OpenBao's own
  Shamir, AppRole and periodic tokens, but the hand-written renewer may duplicate OpenBao Agent
  (finding 7).

### Decisions (ADRs)

- **Amends ADR 0048 decision 4** (the gate) for `unlock: keyfile`. Slice 0 says so.
- **Supersedes the ruling `openbao-login-lifetime`** for key-file servers, and gives
  `openbao-unseal-shares` a new reading. Slice 0 says so, but the reading changes more than
  "in the container" (finding 12, open question 3).
- **ADR 0024 and 0026**: met. The launcher's step is one-shot and the renewer runs inside the
  container, which ADR 0024 decision 3 allows. The launcher already knows the Feature by name
  (`openbao-ssh-import`).
- **ADR 0045 and 0049**: not met as designed. The key file is a quorum held by a machine, so it is
  tier 4 only if the custody shares can rebuild it, and today they cannot (findings 1, 12).
- **ADR 0050**: the `operator` role is made with a root token from the shares, as required. But
  decision 1 also lets the Operator's token reissue secret ids for any existing role, including
  `operator` (finding 5).
- **ADR 0051 and 0052**: conflict. A root-token attempt and `rotate-keys` both need a token on 2.6
  and later. The design's recovery routes assume none is needed (finding 1).
- **Agent CLIs** (the capability matrix in `docs/proposals/agents-v2.md` section 14): nothing here
  touches an agent CLI, so this check is skipped.

### Findings

1. **A lost key file, or a lost machine, leaves no token, so the custody shares cannot rebuild the
   file.** Sections 3, 7 and 12 (decision 6) say two custody shares open the server "as today" and
   then `keyfile:create` runs again, which is `rotate-keys`. In a key-file server, though, there is
   no password (the userpass user is deleted, section 6) and the AppRole secret id lives only in the
   key file. The periodic token dies within the hour of the container stopping. On 2.6 and later,
   `rotate-keys` needs a token (ADR 0052), and so does starting a root-token attempt (ADR 0051, NOTES
   "A root token generation needs a token from 2.6.0 on"). So once the file is gone and the
   container has restarted, two custody shares unseal the server but nothing can log in, make a root
   token, rotate or read. After a machine loss, a restored backup is in the same state. That breaks
   ADR 0045 and the proposal's own ruling 1. The same gap probably affects the password-reset
   stopgap: its `as_root` starts the attempt with the saved login, so "no login needed" holds only
   while a token is still live. Recommended change: before slice 1 is accepted, design a route from
   two custody shares to a new key file that needs no token. The likely route is the loopback
   listener's `disable_unauthed_generate_root_endpoints = false` in key-file mode, if 2.7.2 honours
   it, since the shares are the authority either way, as ADR 0051 argues. Add two cases to the
   `server_keyfile` scenario: "key file lost, token dead" and "machine lost, restore, new key file".

2. **A same-user agent can take a permanent quorum without `sudo`.** Section 10 names root reading
   memory or stdin as the way to intercept. Cheaper ways need no root. An agent can edit the remote
   user's shell profile, which `devcontainer exec` reads when it probes the user's environment, to
   put its own `openbao-setup` or `BAO_ADDR` first. Or it can stop the server and listen on
   `127.0.0.1:8200` itself. Either way it receives shares 4 and 5 and the secret id at the next
   start. Two shares are a quorum over every backup ever written under them, including those in the
   shared folder, off the machine, until a rotation. That is a larger loss than a live token, which
   section 10 calls "the main cost". Today's typed unseal has the same exposure, but only when the
   Operator types in that terminal. With the key file the quorum crosses unattended at every start.
   The backlog item `agent-linux-user` already calls itself "a precondition of the key-file design",
   while decision 4 calls it a follow-up. Recommended change: restate section 10 and decision 4 to
   name a harvested quorum as the main cost, and make `agent-linux-user` a precondition of slice 3
   (the devhost turning `unlock: keyfile` on), not a follow-up.

3. **The stdin route goes through the user's environment probe.** Section 5 streams the key file
   with `devcontainer exec`, which runs the remote user's profile to build the environment and then
   resolves `openbao-setup` on that `PATH`. The launcher already has a route that skips this: the
   cloud-folder relay runs the engine's own `exec -i` with fixed arguments and writes stdin from
   memory. Recommended change: stream the key file through the engine's `exec -i` to the absolute
   path `/usr/local/bin/openbao-setup`. `unlock` should ignore `BAO_ADDR`, `VAULT_ADDR` and
   `BAO_TOKEN` from the environment and talk only to the loopback address the start hook wrote.
   Add a unit test for both.

4. **Rotations strand the backups made before them.** A snapshot opens only with the shares in
   force when it was taken (NOTES, "What was confirmed against OpenBao 2.7.2"). So "a snapshot opens
   with any two of the five" (sections 3, 7) holds only for backups made after the 3-to-5 rotation.
   Every create, rotate and claim prints new custody shares, which the Operator "stores again, in the
   same three places". If the Operator overwrites the old ones, and the machine is lost before the
   next backup, every remaining backup needs shares nobody has. Recommended change: every step that
   runs `rotate-keys` (create, rotate, claim) should end with a backup to the recorded destination
   before it reports success. Its printed instructions should say to keep the previous custody
   shares until `backupKeep` has pruned the backups made under them.

5. **A live Operator token can mint a lasting Operator credential.** ADR 0050 decision 1 lets the
   Operator's token create secret ids for any existing role. With an `operator` AppRole, that
   includes the Operator's own role. Any agent holding the token (section 10) can therefore make
   itself an `operator` secret id that outlives the token, the container and a `keyfile:rotate`
   that destroys only "the old one" (section 7). Recommended change: the Operator's policy denies
   `auth/approle/role/operator/*`, so secret ids for `operator` are made only with a root token from
   the shares, at create and rotate. Rotate should destroy every secret-id accessor of the role,
   not just one.

6. **Revoking the previous token by accessor needs a path the Operator's policy does not hold.**
   Section 5 step 3 revokes the last token "by accessor". That is `auth/token/revoke-accessor`,
   which is not in the policy ADR 0050 lists, yet section 6 says the policy is "unchanged".
   Recommended change: before writing the new token, revoke the previous one with itself
   (`revoke-self`, which the default policy allows), read from the token file.

7. **NFR-13: the renewer may re-implement OpenBao Agent.** `bao agent` has AppRole auto-auth (with
   `remove_secret_id_file_after_reading`, so the secret id can arrive on a tmpfs file or a pipe and
   not stay at rest), a lifetime watcher that renews the token, and a file sink. That is
   `openbao-setup renew` plus the login. ADR 0048 decision 6 set the precedent of checking
   OpenBao's own tool first, for scheduled snapshots. Whichever is used, a background child started
   from an `exec` must detach its stdio, or the launcher's `exec` waits on it. Recommended change:
   in slice 1, check `bao agent` auto-auth and its sink against section 6 first. Write the Feature's
   own renewer only if it does not fit, and record which in the NOTES.

8. **Ruling 3 ("nothing recurring") is not met after a long sleep.** The token has a 1-hour period
   and is renewed every 20 minutes. When the laptop sleeps longer than an hour with the container
   up, the server will probably find the token expired on wake, before the renewer's next tick. The
   renewer then exits by design, and the Operator's token is gone until the next `task dc:*` or
   `task dc:openbao:unlock`. Nothing is typed, but it recurs every morning for a session resumed
   without the launcher (Remote Control, an open terminal). The backs are unaffected, since the
   server stays unsealed. A container started from VS Code (decision 8) recurs in the same way for
   consumers' maintainers. Recommended change: slice 1 tests the token across a clock jump longer
   than the period. Section 6 should then say what happens after a long sleep and what the briefing
   tells the Operator (open question 4).

9. **The workstation-side tasks have no agent guard.** ADR 0048 decision 4 says every task that
   handles a share or a token refuses inside an agent's job. The container-side guard cannot see
   the workstation's environment. Yet `keyfile:create` and `:rotate` print custody shares to the
   workstation console, and `:export` and `:import` handle the whole file. A workstation Claude Code
   session (CLAUDE.md's exception) would get them in its transcript. Recommended change: those four
   launcher tasks refuse when `CLAUDECODE`, `DEVHOST_JOB_CHILD` or a name in
   `OPENBAO_AGENT_JOB_VARS` is set on the workstation, and are marked `interactive: true`.

10. **The key file would sit inside the launcher's download cache.** Section 4 puts it under
    `%LOCALAPPDATA%\devcontainer-features\`, which `Get-LauncherCacheRoot` and the `install` task
    describe as a cache. A person or a tool may clear a cache, and here that is a lost key file
    (and, until finding 1 is fixed, a lost store). Also, on a domain-joined machine the domain's
    DPAPI backup key opens the file too, so section 4's "for nobody else" should say so.
    Recommended change: keep the key file in its own folder that is not called a cache (for example
    `%LOCALAPPDATA%\devcontainer-features-keys\openbao\`), readable only by the user.

11. **Restore and onboarding claim are not designed for key-file mode.** `openbao:restore` ends by
    asking for the Operator's password and reissuing the AppRoles. `openbao:onboard:claim` asks for
    "your own Operator password" and sets up userpass (NOTES). A key-file server has neither, and
    both tasks run in a container terminal, which cannot reach the workstation's key file. Section 7
    covers the claim in one line and the restore not at all, though the second-workstation flow
    depends on it. Recommended change: section 7 adds restore and claim in key-file mode, driven
    from the launcher (the final login, the AppRole reissue and the new key file). The Docker
    scenario should include a restore into a key-file server.

12. **The records in slice 0 miss ADR 0049, and the shares ruling changes more than one word.**
    ADR 0049 puts the shares in custody, "held by people". The key file puts a quorum on a machine,
    which is a new placement: tier 4 if, and only if, custody can rebuild it (finding 1). The ruling
    `openbao-unseal-shares` also meant that no single place holds two shares (three places,
    threshold two). Now one Windows account does, which section 10 admits but decision 2 does not
    ask about. Recommended change: the slice 0 ADR names ADR 0049 among those it amends and places
    the key file in tier 4, rebuildable from custody. Decision 2 then asks about the quorum in one
    place as well as the "never stored in the container" reading.

13. **NFR-6: the option has no override variable.** Every other server-mode option has an
    `OPENBAO_SETUP_*` override in `containerEnv`. Recommended change: name `OPENBAO_SETUP_UNLOCK` in
    section 9, and make `unlock --status` report the resolved value, so the launcher reads one
    source.

14. **Lexicon.** "Key file" already means an SSH private key file in the launcher
    (`dc:openbao-ssh-import FILE=`, ADR 0026's "a key file under the Windows profile"), so the new
    term collides. "Custody share" is used throughout but is not defined. "Unseal share" is defined
    as one of 3, "sitting" as 4 hours and at most 8, and "the gate" as typed steps; all three change.
    "The master's key file" (section 7) reads as the lexicon's "master of secrets" when it means
    the master machine of `openbao-two-machines`. Recommended change: slice 0 names the new thing
    "unlock file" (or "OpenBao key file", used every time), adds "custody share", rewrites "unseal
    share", "sitting" and "the gate" with the key-file reading, and section 7 says "the master
    machine".

### Placement

| Element | Layer | View |
|---|---|---|
| DPAPI store, unlock step after `up`, `dc:openbao:*` tasks | launcher (`devcontainer-cli`) | right: only the launcher knows the host (ADR 0024 decision 1) |
| `unlock` option, `unlock --status/--stdin`, the JSON protocol, the AppRole | `openbao` Feature | right, opt-in and host-blind |
| the renewer | `openbao` Feature, in the container | right layer; check OpenBao Agent first (finding 7) |
| restore and claim in key-file mode | launcher plus Feature | missing (finding 11) |
| `unlock: keyfile`, the briefing line | devhost and `.devcontainer` | right; gated on `agent-linux-user` (finding 2) |
| consumers | their own `devcontainer.json` | right: nothing until they opt in |

### On the decisions in section 12

Agreed as written, given the findings: 1 (B), 3, 5 (with finding 10's folder), 6 (only once
finding 1 is fixed), 7, 8, 9 and 10. Decisions 2 and 4 need restating (findings 2 and 12).

### Open questions for the Operator

- **Is design B the right base?** Recommendation: yes. A's static key cannot be rebuilt from the
  custody shares, and that is checked, not assumed.
- **Is the key file turned on in this devhost only after agents run as their own Linux user without
  passwordless `sudo` (`agent-linux-user`)?** Recommendation: yes. Build slices 1 and 2 now, but
  hold slice 3 until that item is done, since until then any agent can take a permanent quorum
  (finding 2).
- **Is a quorum held by one Windows account acceptable for this devhost?** Today two separate
  custody places are needed. Recommendation: accept it for this devhost, written into the slice 0
  ADR. Consumers decide for themselves by opting in.
- **Is the 1-hour token period kept, so that the Operator's token may need a no-typing
  `task dc:openbao:unlock` after a long sleep?** Recommendation: keep 1 hour, with the briefing
  naming the command when the token is gone. A longer period buys little, since every `task dc:*`
  unlocks anyway.
- **Are the previous custody shares kept after a rotation until the backups made under them are
  pruned?** Recommendation: yes, including after a theft rotation. The thief's file shares already
  open those backups, so keeping your own old shares adds no exposure.
- **Should the secret id become one-use and rolled at every unlock** (a copied key file then fails
  at the next start, which shows the theft)? Recommendation: not in slice 1. Revisit once finding 1
  gives a recovery route that needs no token, because a failed roll today is a lockout.
