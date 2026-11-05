# ADR-0056: An OpenBao key file on the workstation unseals OpenBao and logs the Operator in

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-05 |
| **Deciders** | the Operator; proposed by the host session |

## Context

In server mode the Operator types two unseal shares after every server start and a password every
sitting (ADR-0048 decision 4). The proposal `docs/proposals/openbao-key-file.md` (2026-11-04) asks
for an unlock with no typing. It checked a real `bao` (section 2) and went through the architecture
review of 2026-11-04 (fit with changes; findings 1 to 14, all taken). The Operator ruled on
2026-11-05, in these words: "approve" (design B, the proposal's decisions 1 to 10 as amended by the
review, including keeping the 1-hour period, keeping previous custody shares until the backups made
under them are pruned, a secret id that is not one-use in this build, and a quorum held by one
Windows account accepted for this devhost); "a, build it now" (build every slice and turn
`unlock: keyfile` on in this devhost now, without waiting for `agent-linux-user`); and "We'll rotate
after the agent linux user feature".

The forces: the gate must stay a gate (ADR-0048); a lost workstation or key file must not lock the
Operator out for good (review finding 1); a quorum of shares in one place is only as safe as that
place, and today every process in the devhost container runs as one Linux user (review finding 2).

## Decision

1. **An OpenBao key file on the workstation unseals OpenBao and logs the Operator in.** It is a
   JSON file the launcher stores under `%LOCALAPPDATA%\devcontainer-features-keys\openbao\`,
   protected with Windows DPAPI for the current user. It holds two unseal shares (shares 4 and 5),
   the cluster id, and an AppRole `role_id` and `secret_id`. After every `up` the launcher checks
   `openbao-setup unlock --status` and, when the server is sealed or the token is gone, sends the
   file's contents to `openbao-setup unlock --stdin` by the container engine's own `exec -i`. The
   container unseals through `sys/unseal`, logs in as the AppRole `operator` (a 1-hour periodic
   token, bound to 127.0.0.1/32, renewed inside the container) and keeps no share.
2. **Design B: five shares, threshold two.** Shares 1 to 3 are the **custody shares**, held by the
   Operator as ADR-0048 and ADR-0049 say. Shares 4 and 5 are the key file's. Any two of the five
   unseal, so the key file alone is a quorum.
3. **Opt-in.** The Feature option is `unlock` (`operator`, the default and today's behaviour, or
   `keyfile`; override variable `OPENBAO_SETUP_UNLOCK`). Server mode with `unlock: operator` is
   unchanged and keeps ADR-0048 decision 4 as written.
4. **This amends ADR-0048 decision 4 (the gate) for `unlock: keyfile`.** The gate is then the
   Windows account that can open the key file, plus the custody shares for recovery and rotation.
   The userpass login is deleted, and the Operator policy denies `auth/approle/role/operator/*`
   (review finding 5). `openbao:password` refuses in this mode. ADR-0048's other decisions stand.
5. **This amends ADR-0049: the key file is tier 4.** It is rebuildable: two of the three custody
   shares, typed on the workstation, rebuild it through the root-token route of ADR-0055 (no token
   needed on the loopback listener), so a lost file or machine is not a lock-out. Losing the key
   file loses nothing that custody cannot restore. The custody shares stay outside every tier.
6. **This supersedes the ruling `openbao-login-lifetime` for key-file servers.** The login there
   is a 1-hour periodic token renewed while the server runs, not 4 hours and at most 8. The ruling
   stays for servers that keep the password. The briefing names the no-typing unlock.
7. **This gives the ruling `openbao-unseal-shares` a new reading.** "Never in the container" means
   never stored there: the key file's shares cross into the container's memory for two
   `sys/unseal` calls and are dropped, and are never in a volume, a log, an argument or an
   environment variable. "In three places, never in the shared folder" means the custody shares; a
   quorum in one Windows account (the key file) is accepted for this devhost, by the Operator's
   ruling of 2026-11-05.
8. **Until agents run as their own Linux user, any agent in the container could harvest the
   quorum.** The container's memory holds the two shares during an unseal and the launcher's stdin
   protocol is open to every process of that Linux user, and the guards (refusal under
   `DEVHOST_JOB_CHILD`, `CLAUDECODE` and `OPENBAO_AGENT_JOB_VARS`) stop only an agent that obeys
   them. The Operator knows this and chose to turn `unlock: keyfile` on now anyway (2026-11-05,
   "a, build it now").
9. **The Operator rotates the key file and the shares once `agent-linux-user` is done** ("We'll
   rotate after the agent linux user feature"), with `task dc:openbao:keyfile:rotate`. Until then
   the shares in the key file are to be treated as exposed to the container.
10. **Names.** The term is "OpenBao key file", in full every time; "key file" alone already means
    an SSH key file in the launcher. The term "custody share" is unseal shares 1 to 3.
11. **Windows only for now.** The bash launcher prints one refusal line and does nothing; a later
    slice may use libsecret or the Keychain.

## Options considered

### Option B: five shares, two in a DPAPI-protected file, three in custody (chosen)

It needs no new infrastructure, uses OpenBao's own Shamir, AppRole and periodic tokens, and
keeps a recovery path that is independent of the key file: the custody shares rebuild it. The
quorum is what OpenBao itself needs, so nothing is stored that the Operator did not already
hold. Review finding 1 is met by the loopback route of ADR-0055; the threats of section 10 of
the proposal are stated here rather than hidden.

### Option A: a static seal (the key held by the server's config)

OpenBao unseals itself with a key. It lost because the key then lives in the server's memory
and config for the server's whole life, which stretches "never in the container" further than B
does (proposal section 8); because its recovery shares cannot rebuild a lost key, so it needs a
fourth custody item (review verdict); and because it changes the server's seal for every start,
not only for the Operator's unlock.

### Option: keep typing two shares and a password

Nothing to build and nothing to harvest. It lost because the Operator's cost is every start and
every sitting, and the password reset (openbao 1.4.0) shows the typing is itself a failure mode.
It stays as the default (`unlock: operator`) for every consumer that does not opt in.

## Consequences

- The Operator types nothing after a start; the launcher unlocks silently after each `up`, and
  prints one line when there is no key file for that server.
- The key file's two shares make this devhost's gate the Windows account plus the container's
  isolation from its agents; the second is weak until `agent-linux-user` (decision 8).
- Restore and onboarding claim in a key-file server end by telling the Operator to run
  `task dc:openbao:keyfile:rotate`, which makes the new key file (review finding 11).
- Rotation leaves the previous custody shares valid for the backups made under them: keep them
  until those backups are pruned (review finding 4).
- Slices 1 to 3 of the proposal build this: openbao 1.5.0, devcontainer-cli 1.20.0, devhost
  1.13.0 with `unlock: keyfile` set. The Operator then runs `task dc:openbao:keyfile:create`
  once on the workstation.
- A backlog item: rotate the key file and the shares after `agent-linux-user`.
- Open: a domain DPAPI backup key also opens the file (stated in the NOTES); a second
  workstation uses `:export` and `:import` with a one-time passphrase.

## Change log

| Date | Change |
|---|---|
| 2026-11-05 | First draft, accepted by the Operator the same day. |
