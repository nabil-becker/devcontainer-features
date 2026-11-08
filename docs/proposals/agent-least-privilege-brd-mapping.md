# Least privilege: the two consumers' BRDs mapped, and the revision they imply

draft 2026-11-08

Status: a traceability and a proposed revision, for the Operator to rule on. It does not change
[agent-linux-user.md](agent-linux-user.md) (accepted 2026-11-08, "the accepted proposal" below);
the Operator rules on this first, and the accepted proposal is amended after that ruling. Backlog:
`least-privilege-mvp` (step 1 is on draft pull request 190), `agent-linux-user`. Basis:
[agent-least-privilege-inventory.md](agent-least-privilege-inventory.md) (the inventory, with its
test results of 2026-11-08) and the held broker draft (#187, `docs/proposals/brokers.md` on
`docs/broker-pattern/1`).

**Who this serves.** The Operator, through the host, who rules on the revision and rotates the
OpenBao key file after it; and the maintainers of the two consumers whose agents will run under it:
the office and AOF (agentic-operating-framework). Each sent a business requirements document on
2026-11-08: **the office's BRD (draft 2, 2026-11-08)**, cited here by its identifiers (R1.1 to R8.5, the
decisions BRD-1 to BRD-12, "office acceptance 1" to 12), and **AOF's BRD (2026-11-08)**, cited by
"AOF req 1" to 13, its non-functional requirements by name and "AOF acceptance 1" to 14 (in the
BRD's order). Both BRDs are consumer material: they are not copied here, and this document uses
generic words ("a room", "a client room", "a level") for what they name.

How to read it: section 1 is the table, then where the two BRDs agree, differ and conflict with an
accepted decision; section 2 the revision, step by step, and the helper gate compared with the
held brokers; section 3 who owns each new element, the versions and what each consumer changes;
section 4 the open questions; section 5 the decisions for the Operator. Words are the lexicon's;
the decisions of the accepted proposal's section 14 are written D1 to D16.

## 1. Traceability

Status: **covered** (the accepted proposal meets it as written), **partly** (it meets part of it,
or only for one agent user), **gap** (nothing in the accepted deliverable). "Later" is the accepted
proposal's section 12. "Rev" names the element of section 2 that closes it. A decision in the
last column is an accepted decision the requirement runs into (section 1.3).

### 1.1 The office's BRD (draft 2, 2026-11-08)

| Req | Asks, in short | Accepted proposal | Status | Rev | Runs into |
|---|---|---|---|---|---|
| R1.1 | each agent names (or derives) its user in the agent list; a room added later gets user and group without a rebuild | Later: one user per identity, made at start from the list | gap | 6b users from the list, made at start | D7, D8 (install time) |
| R1.2 | housekeepers run as their own users in their level's group | Later: one user per back; a shared group | gap | 6b back users, 6c level groups | D7 |
| R1.3 | subagents inherit their parent's user, said so | 3.3 "cons share their parent" | covered | (NOTES line) | |
| R1.4 | no agent can `sudo`, `su` or join the Operator's groups; the only way up is a named helper | step 6: no `sudo`, no `docker`; but 6.5 makes the agent's primary group the Operator's | partly | 6a `dcf-work` group; 6e helper gate | D10 |
| R1.5 | the Operator starts, resumes, attaches to and stops any agent as that agent; leases per user | 6.2: every adapter verb through `sudo -n -u agent`; leases the caller's | partly (one user) | 6b the switch per user | |
| R1.6 | the process that signs a register entry runs as the key's user | not covered (host and backs share `agent`) | gap | 7b per-user keys | D7 |
| R1.7 | Linux users and uids are per machine, independent of the writer id | users are per container | covered | 6b fixed numbers (section 4, Q5) | |
| R2.1 | the repository by ownership: shared floor parts read by all, floor tooling written by the floor only, a room's exec writes its own room only and reads no other room; the floor reads every room's docs and README only; recordings through helpers; helper-written files owned by the room group; one published read-only folder | step 3: write-deny by path, the same for every agent | gap | 6c level groups, POSIX ACLs; 6e helpers; T2 gates it | |
| R2.2 | the shared folder: a room reads only its own results folder; no agent reads the raw-material folders or the name list; writes only through a named task | step 7: `agentAccess` `none`, `read`, `write` for the whole mount; the office runs `host` mode (review finding 16) | partly | 7a per-group sub-mounts in `mount` mode; `host` mode reported unprotected | D15 (whole mount) |
| R2.3 | the personal folder: the Operator's and the floor's, nothing for rooms | not covered | gap | 7a the same sub-mounts (a second remote) | |
| R2.4 | the state home: each level's machinery in its level's group; work, quarantine and the staff list for helpers only; the app key for one helper | not covered | gap | 6c, 6e; the app key moves into OpenBao (step 5's consumer change) | |
| R2.5 | the office's own read-block hook and deny rules stay | the two-list rule adds, never removes; but `lockPermissions` (`allowManagedPermissionRulesOnly`) would make Claude Code ignore the office's own deny rules | partly | step 2 note: the consumer's rules move into the managed list, or `lockPermissions` stays off | step 2 text |
| R2.6 | mounts that cannot hold ownership are detected, protected another way or reported unprotected | T2 asks the question; nothing detects or reports | gap | 6f the check reports them (BRD-8 decided "report") | |
| R3.1 | a fixed list of task names per agent may run with more rights; data, never `task` itself | Later: custom brokers (held) | gap | 6e helper gate | the brokers hold |
| R3.2 | the helper learns its caller from the kernel uid, refuses outside the caller's scope | not covered | gap | 6e caller by `SO_PEERCRED`; the scope check is the office's task (its section 5) | |
| R3.3 | a path from the caller is resolved without following links out of the room, and read only if the caller could read it | not covered | gap | 6e a path argument is opened on the caller's side and handed over on standard input | |
| R3.4 | files a helper writes into a room end up in the room's group | not covered | gap | 6c setgid folders | |
| R3.5 | helpers print counts and identifiers, never content (except where content is the job) | not covered | partly | the office's tasks; the gate's audit line holds no values | |
| R3.6 | register writes run as the caller with its own key through ssh-agent, not as a helper | not covered | gap | 7b | D7 |
| R4.1 | the key file and the vault's state for the Operator's user only; rotate once after the switch | steps 5, 6; D16 | covered | | |
| R4.2 | secrets through the agent's own vault login (`DCF_SECRET_AS`), a policy per secret, short tokens, no fallback | step 5: an AppRole for the host (`openbao-agent-login`) | partly | 5+ one AppRole per agent and helper user | |
| R4.3 | operator commands refuse agent users, by uid | Later: share tasks refuse by user | gap | 5+ moved in | |
| R4.4 | two signing principals per room (exec, scribe), each key usable only by its user; both append to the room's store | not covered | gap | 7b; 6c group on the store | D7 |
| R5.1 | every agent user commits as the office's bot identity with its trailer; the git wrapper works for each user | git's wrapper is per call and user-neutral; `safe.directory` (6.5) | partly | 6a `core.sharedRepository` with `dcf-work`; a test as a second user | |
| R5.2 | `save` is a privileged helper (fetch, merge, verify, push); a plain `git push` by an agent is refused | not covered (the host pushes with the step 1 token) | gap | 6e; the push token belongs to the helper user, not to agents | |
| R5.3 | a worktree belongs to the agent that opened it; a refusal names the rule | not covered; kernel refusals are bare | partly | 6f the check explains; the office's guard names the rule | |
| R6.1 | each agent user has its own Claude home that survives a rebuild; the Operator's memory unreadable | Later: per-user Claude state | gap | 6d | D8 (volume handed whole) |
| R6.2 | the shared skills linked read-only into each user's skills folder; a dead junction ignored | not covered | gap | 6d | |
| R6.3 | each user logged in once without copying credentials; Remote Control reaches each resident | Later: per-user Claude logins | gap | 6d (section 4, Q3) | |
| R6.4 | hooks fire; a housekeeper runs as its user from a copy the hook hands over, never reading the exec's home | Later: back users and the hand-over (review finding 3) | gap | 6g hand-over through the gate | D7 |
| R6.5 | session-start checks fail soft ("not visible", counts) for restricted users | not covered | partly | the office's own checks; the Feature's check (6f) follows the same rule | |
| R7.1 | tools system-wide and readable by all | the image already | covered | | |
| R7.2 | the model caches shared read-only and kept across a rebuild | not a least-privilege step | gap (out of the Features' scope) | the office's volume; 6f reports presence | |
| R7.3 | a long pipeline run runs as the helper, outlives the session, is visible to agents, stopped only by the Operator | not covered | gap | 6e `detach` entries; the kernel stops other uids from killing it | |
| R8.1 | one switch per machine; off restores today's single user with nothing lost | step 6: `runAs` | partly | 6b `runAs: per-agent` beside `agent` | |
| R8.2 | a check per agent and per room, counts only: paths, helpers allowed or refused, layout mismatches, unprotected paths, caches; an audit extract | Later: `agents boundary` | gap | 6f `agents check` | |
| R8.3 | upgrade in place: ownership moved with a dry run, no content read, root-owned or 777 trees reported | not covered | gap | 6f `agents migrate` | |
| R8.4 | two machines independently; accounts and credentials never through the shared folder; uids do not carry rights across machines | users per container; the shared folder's access by mount options | covered | | |
| R8.5 | no noticeable cost per turn; a rebuild grows by at most a minute | not measured | partly | T19 | |
| Section 5 | out of scope: the office's tasks reading the caller; a container per agent; agent-to-agent exchange (BRD-11) | | | the gate hands the caller to the task; the task's use of it is the office's | |
| Section 7 | R1, R2's principle, R4, R8.1 to R8.3 apply to any stack | | | the revision is one model for both (AOF req 11) | |
| Office acceptance 1 | a room's exec cannot read another room or the raw-material folders by any command | | gap | 6c, 7a; T2 | |
| Office acceptance 2 | no agent reads the key file, the name list, the staff list, the app key | T9 for the key file | partly | T9 extended per user | |
| Office acceptance 3 | helpers work for the caller's room and refuse another; a link out of the room refused | | gap | 6e | |
| Office acceptance 4 | masking a transcript for the exec, who never reads the raw text | | gap | 6e | |
| Office acceptance 5 | exec and scribe each sign with their own key, refused with the other's | | gap | 7b | |
| Office acceptance 6 | `save` merges another room's change and pushes; a plain push refused | | gap | 6e | |
| Office acceptance 7 | a resident starts, is reached by Remote Control, resumed by the Operator | 6.2, T11 (one user) | partly | 6b, 6d, T15 | |
| Office acceptance 8 | a housekeeper writes its entry from the hook's copy, nothing outside its level | | gap | 6g | |
| Office acceptance 9 | the briefing passes for an exec with "not visible" counts | | gap | the office's checks | |
| Office acceptance 10 | after the switch the key file is rotated and the vault unseals | D16 | covered | | |
| Office acceptance 11 | on an ownership-less mount the check lists unprotected paths | | gap | 6f | |
| Office acceptance 12 | the switch off restores the single user, every agent working | `runAs: remote-user` | partly | 6b | |

### 1.2 AOF's BRD (2026-11-08)

| Req | Asks, in short | Accepted proposal | Status | Rev | Runs into |
|---|---|---|---|---|---|
| AOF req 1 | one least-privilege user per main agent, per staff member, and for the operator | Later: per identity, per back | gap | 6b | D7 |
| AOF req 2 | no passwordless `sudo` for agents; at most named commands on a list the operator sets, shown by the "Visible" command | step 6 for one user | partly | 6e, 6f | the brokers hold |
| AOF req 3 | each agent signs only as itself; the agent makes its own key; the operator takes only the public key | not covered | gap | 7b, and AOF's own register changes | D7 |
| AOF req 4 | the operator's OpenBao token, the unseal shares on their way in, the key file's secret id and the anchor key out of agents' reach | steps 5, 6, 7: other uid, modes 600/700, no `SSH_AUTH_SOCK` | covered (T9 to list each path) | | |
| AOF req 5 | an AppRole per agent, reading only its SSH key and the instance id | step 5 for the host | partly | 5+ | |
| AOF req 6 | an agent writes only its own worktree, as filesystem permissions | step 3: write-deny by path for all agents alike | gap | 6c per-agent owners on the worktree volume (Q8) | |
| AOF req 7 | shared on purpose, through groups: checkout and git dir, records lock, mailbox and live store, relay volume, the agents' messaging socket | one user shares everything | partly | 6a `dcf-work`, 6c groups; T17 for messaging | D10 |
| AOF req 8 | Claude Code per user; the staff read the turn they record | Later | gap | 6d, 6g | D8 |
| AOF req 9 | the start tasks, the residents at start and `--resume` keep working as each user, nothing typed | 6.2 for one user | partly | 6b | |
| AOF req 10 (SHOULD) | GitHub per agent, or one bot behind a group | step 1: one narrow token for the host | partly | Q2 | D3, D4 |
| AOF req 11 (SHOULD) | the same model in every stack | | covered by this document | the revision | |
| AOF req 12 | a relay user per stack holding the relay key; one shared gid for the relay; a fixed uid range per stack; setgid party folders | not covered | gap | 6b fixed-number registry; the relay user is AOF's | |
| AOF req 13 | least privilege of knowledge: guard configuration, key and unlock procedures, the signing workflow readable only by their maintainers and the operator | not covered | gap (partly reachable) | 6e guard helper; Q9 | |
| Fail closed | a missing user, group or permission stops the start with one line; never `host` | 6.1 falls back to today's user when the user cannot be made | partly | 6b refuse, never fall back | 6.1 text |
| No secret in an argument, the environment or a log | | 6.2's environment deny list (D13) | covered | | |
| Visible | one command per agent: user, groups, writable paths, reachable secrets | Later: `agents boundary` | gap | 6f | |
| Auditable | a register entry or a commit traced to its user | not covered | partly | 7b for entries; commits: Q10 | |
| Idempotent rebuilds | uids, gids and owners stable on volumes; old volumes re-owned once, saying what changed | 6.1: one fixed uid | partly | 6b fixed numbers, 6f migrate | |
| Cost | a start under a second slower; nothing typed | | partly | T19 | |
| Honest limits | the design says what it does not stop | 3.3 | covered | section 2.4 adds the new limits | |
| AOF acceptance 1 | `id` shows the agent's own user; `sudo -n true` fails | T9 (one user) | partly | 6b | |
| AOF acceptance 2 | one agent cannot read another's register key or sign as it | | gap | 7b | |
| AOF acceptance 3 | no agent reads the token helper's file; `bao token lookup` shows its own token | 6.3 openbao drop-in, T9 | covered | | |
| AOF acceptance 4 | an agent's OpenBao identity reads its SSH key and the instance id, nothing else | step 5 (host) | partly | 5+ | |
| AOF acceptance 5 | one agent cannot write another's worktree or folders | | gap | 6c | |
| AOF acceptance 6 | no agent reads another's transcripts; the staff read the turn | | gap | 6d, 6g | |
| AOF acceptance 7 | an agent that does not maintain a control cannot read its internals | | gap | Q9 | |
| AOF acceptance 8 | the start tasks start each agent as its user; residents at start | 6.2 | partly | 6b | |
| AOF acceptance 9 | the staff write ledger and backlog as themselves; verify and test pass | | gap | 6g, 7b | |
| AOF acceptance 10 | two agents writing one register at once both succeed | | gap | 6c, AOF's lock fix | |
| AOF acceptance 11 | push, open a pull request, merge through the queue | step 1 (host) | partly | Q2 | |
| AOF acceptance 12 | the relay delivers; another stack's relay user cannot touch your party folder | | gap | 6b fixed numbers; AOF's relay | |
| AOF acceptance 13 | a rebuild keeps every owner | | gap | 6b, 6f | |
| AOF acceptance 14 | the operator rotates the key file and new custody shares are stored | D16 | covered | | |
| Settled: subagents | sub-agents run as the parent's user, narrowed by tools | 3.3 | covered | | |
| Settled: staff | one user per staff member | | gap | 6b, 6g | D7 |
| Settled: fixed numbers | fixed uids and gids across stacks for the relay; numbers devfeat's | | gap | Q5 | |

AOF's constraints table (what each part needs from this work) is traced by Feature in section 3.1;
its own code changes are AOF's (section 3.3).

### 1.3 Agree, differ, conflict

**Where they agree** (one design serves both):

- One Linux user per identity, including the background agents (office R1.1, R1.2, BRD-1; AOF
  req 1 and its settled staff item), and subagents as their parent (R1.3; AOF's settled item; the
  accepted 3.3).
- No `sudo` for agents, with a list of named commands as the only way up, the caller known from
  the kernel (R1.4, R3.1, R3.2; AOF req 2).
- Each register key usable only by its own user; the signing process runs as that user (R1.6,
  R3.6, R4.4; AOF req 3).
- The vault for the Operator only, an AppRole per agent, rotation after the switch (R4.1 to R4.3;
  AOF req 4, 5, acceptance 14).
- Claude Code state per user; the background agent reads a copy of the turn, not the agent's home
  (R6.1, R6.4; AOF req 8).
- The Operator starts and resumes everything as each agent, nothing typed (R1.5; AOF req 9).
- Fail closed; a check that shows the model; re-own once with a report (office section 2, R8.2,
  R8.3; AOF's "Fail closed", "Visible", "Idempotent rebuilds").
- The same model in every stack (office section 7; AOF req 11).

**Where they differ** (the design must allow both):

| Topic | The office | AOF | Consequence |
|---|---|---|---|
| Grouping | a room group per level: the exec and its housekeepers share one group and write the same documents; the floor reads every room's docs (R2.1, BRD-1, BRD-4) | one user per agent with only its own worktree writable; shared things through groups (req 6, 7) | groups are declared in the agent list, not derived: a level group for the office, a group per shared resource for AOF (6c) |
| Privileged helpers | many, named by task id, each scoped by the caller's room (R3.1 to R3.5, R7.3) | named commands on a list, no shape asked (req 2) | one gate whose entries are task names (6e); AOF may start with none |
| Pushing | no agent pushes; `save` is a helper (R5.2, BRD-3) | agents push, open pull requests and merge through the queue; GitHub per agent or one bot (req 10, acceptance 11) | the push credential belongs to whoever pushes: a helper user for the office, a bot token per stack for AOF (Q2) |
| Commit identity | one bot identity for every agent, with the office's trailer (R5.1) | a commit traceable to the user (Auditable) | the identity stays one bot; the user goes in a trailer written by the consumer's own hook from `id -un` (Q10) |
| Fixed numbers | uids are per machine and carry no rights across machines (R1.7, R8.4) | a fixed uid range per stack and one shared relay gid (req 12) | compatible: fixed numbers keep owners stable on volumes shared between stacks on one workstation; nothing relies on a uid across machines (Q5) |
| A relay user | none | one `relay` user per stack (req 12) | a user the agent list can declare that is not an agent; AOF's relay Feature makes it with a number from the registry |
| Knowledge | not asked | security internals readable only by maintainers (req 13) | partly reachable (Q9) |
| Agent-to-agent messaging | out of scope (section 5, BRD-11) | kept working through a group (req 7) | T17; not a reason to change the model |
| Mounts | the checkout and the shared folder are Windows mounts that may hold no ownership (R2.6) | worktrees on a Docker volume, where ownership holds | the check reports the office's unprotected paths; T2 decides how much of R2.1 the kernel can enforce |

**Where a BRD runs into an accepted decision** (section 14 of the accepted proposal):

| Accepted | Runs into | What the revision proposes |
|---|---|---|
| D7: one `agent` user for the host, its cons and the backs | every user-per-identity requirement of both (R1.1, R1.2, R1.6, R4.4, R6.4; AOF req 1, 3, 8, settled staff) | keep `runAs: agent` and add `runAs: per-agent` (decision 1, overturns D7 as the end state) |
| D8: the user made at install time; the Claude state volume handed to it whole | R1.1 (a room added later without a rebuild); R6.1 and AOF req 8 (a home per user) | users made at start from the list in `per-agent` mode; a Claude home per user (decisions 2, 5, partly overturn D8) |
| D10: the agent's primary group is the remote user's own | R1.4 (no agent joins the Operator's groups); AOF req 7 (sharing through named groups) | a shared group `dcf-work` with a fixed gid in both modes (decision 3, overturns D10) |
| D12: an agent cannot start another agent | nothing in either BRD asks for it; the hand-over starts a fixed background job as another user | D12 kept; the hand-over and helpers are gate entries, not `agents start` (decision 14) |
| D15: the shared folder's `agentAccess` for the whole mount | R2.2, R2.3 (per room, per folder) | per-group sub-mounts beside it (decision 12, amends D15) |
| Step 2's text: no `allowUnixSockets` | the gate and per-user ssh-agent sockets must be reachable from a sandboxed Bash call | list exactly those two paths (decision 7, amends step 2) |
| Step 2's `lockPermissions` | R2.5 (the office's own deny rules stay) | the consumer's rules move into the managed list, or `lockPermissions` stays off for that consumer (section 2.1) |
| 6.1's fallback ("agents run as today" when the user cannot be made) | the office's section 2 and AOF's "Fail closed" | refuse, never fall back (decision 11) |
| The brokers hold (2026-11-06 ruling, #187 not part of the MVP) | R3.1 to R3.4, R5.2, R7.3; AOF req 2 | a narrow part of #187, the helper gate, enters the deliverable; the per-tool brokers stay held (decision 6) |

D1 to D6, D9, D11, D13, D14 and D16 are untouched by either BRD. D16 matters for order: both BRDs'
urgency is the key file, and step 6 as accepted (one agent user) already takes it out of every
agent's reach, so `key-file-rotate` does not wait for the revision (section 2.3).

## 2. The revision

The smallest change to the accepted deliverable that meets both BRDs: keep steps 1 to 5 and 8,
ship step 6 as accepted (with the shared group), then extend it with what the BRDs need from
"Later" and a narrow helper gate; change step 7 for per-user sockets and per-group sub-mounts.

### 2.0 The picture: users and groups

```
 the Operator's user (remote user)  sudo, docker, OpenBao token, rclone.conf, its own Claude home
 |   member of dcf-work and of every declared group
 |
 |  agents start / attach / resume / stop  ==> sudo -n -u <agent user>  (every adapter verb)
 v
 +======================= group dcf-work (fixed gid): the checkout, the git dir ==================+
 |                                                                                               |
 |  the office:                                                                                  |
 |   group "room A"                 group "room B"                group "floor"                  |
 |   +------------------------+     +-------------------+         +---------------------+        |
 |   | agent-roomA   (exec)   |     | agent-roomB       |         | agent-floor         |        |
 |   | back-roomA-scribe      |     | back-roomB-scribe |         | back-floor-tidy     |        |
 |   | back-roomA-librarian   |     | ...               |         | (ACL: reads each    |        |
 |   +------------------------+     +-------------------+         |  room's docs only)  |        |
 |                                                                +---------------------+        |
 |  AOF:                                                                                         |
 |   agent-<each main agent> (owns its worktree)   back-<each staff member>                     |
 |   group "records" (lock, live store), group "mailbox"; relay (its own user, shared relay gid) |
 |                                                                                               |
 |  each agent and back user: its own Claude home (700), ssh-agent socket and register key,      |
 |  AppRole; no sudo, no docker; cons and subagents run as their parent                          |
 |                                                                                               |
 |  helper users (no login, no sudo): helper-save, helper-pipe, helper-guard, ...                |
 |     reached only through the gate: one socket each, caller = SO_PEERCRED uid                  |
 +===============================================================================================+
```

### 2.1 Step by step

| Step | Changed by a BRD? | What changes |
|---|---|---|
| 1 GitHub ruleset, narrow token | no | as accepted. Where a consumer pushes through a helper (the office's `save`), the narrow token belongs to that helper user, not to an agent user (Q2) |
| 2 Sandbox, locked permissions | yes, two settings | as accepted, plus: `sandbox.network.allowUnixSockets` lists exactly the gate's socket folder and the per-user ssh-agent socket folder (decision 7; each socket's own mode keeps other users out); and a consumer with its own deny rules (R2.5) either moves them into the managed list (a new claude-code option for extra `permissions.deny` lines) or keeps `lockPermissions` off. The two-list rule stays |
| 3 Write-deny | no | as accepted; per-level write separation is the kernel's (6c), not more sandbox paths |
| 4 The backs narrowed, the tester under `bwrap` | no | as accepted; 6g adds the hand-over on top |
| 5 Per-agent AppRole | extended (5+) | one AppRole per agent user and per helper user, issued from the agent list (`task openbao:approle:issue` over the list); the share tasks refuse by user (the caller must own `$OPENBAO_STATE_DIR`) beside the variables, moved in from Later (R4.3); the unix listener as accepted |
| 6 One `agent` user | yes | shipped as accepted with one change (6a), then extended (6b to 6g) |
| 7 Shared folder and ssh-agent | yes | 7a per-group sub-mounts; 7b per-user ssh-agent sockets and register keys |
| 8 Codex | no | as accepted |

**6a. The shared group, in both modes.** A group `dcf-work` with a fixed gid (section 4, Q5) made
at install time; `_REMOTE_USER` joins it at build (review finding 6), every agent and helper user
joins it, and git's `core.sharedRepository=group` uses it. It replaces "the agent's primary group
is the remote user's" (D10), so no agent joins the Operator's groups (R1.4). Umask 002 for agent
users stays.

**6b. Users per identity.** `runAs` gains `per-agent` beside `remote-user` and `agent`. Each
identity in the agent list gets `agent-<identity>` (or the entry's `user:`), each background
agent the list declares gets `back-<name>`, each helper `helper-<name>`; no password, no `sudo`,
no `docker`, home in the image. In `per-agent` mode the start hook makes them as root **at start**,
from the agent list **as committed on the base branch** (or from the Operator's own working copy
when the Operator runs `agents sync` themself), never from a working tree an agent can write, so a
room added later needs no rebuild (R1.1) and an agent cannot widen its own entry. uids and gids:
an entry's `uid:`, else derived inside the stack's range (`uidRange` option) and refused on a
collision, so a rebuild keeps owners (AOF "Idempotent rebuilds"). The switch is 6.2's, per user:
every adapter verb runs as the entry's user; the Operator starts, resumes, attaches and stops as
that user (R1.5, AOF req 9). With `runAs` set and a user, group or socket missing, `agents start`
refuses with one line naming it and never runs as the Operator's user (decision 11). `agent` mode
keeps the install-time user of 6.1.

**6c. Level groups and modes.** The list declares groups (`groups:` with a gid, and `group:` per
entry). The office declares a group per room and one for the floor (exec and housekeepers in it);
AOF declares a group per shared resource (records lock, live store, mailbox) and none per agent.
Folders a level writes are setgid to its group, so files a helper writes there end up in the
group (R3.4). Reads across levels (the floor reading each room's docs and README, R2.1; the one
published folder, BRD-9) are POSIX ACLs on those folders, the kernel's own feature (NFR-13). All of
this holds only where the filesystem keeps owners, modes and ACLs: on a Docker volume it does; on
the Windows mounts it depends on T2, which runs before 6c is built (section 4, Q7).

**6d. A Claude home per user.** claude-code's drop-in sets `CLAUDE_CONFIG_DIR` to
`$CLAUDE_CONFIG_DIR/users/<user>` (700, the user's), in the existing volume, so it survives a
rebuild (R6.1, AOF req 8). The volume's root stays the Operator's, with the Operator's memory
(ADR-0049's path for the Operator does not move; the host identity's state is copied once into
`users/agent-host/` by the migration). The consumer's shared skills are linked read-only into each
user's `skills/` (R6.2). The sign-in is Q3. The cost report reads every user's folder as the
Operator's user (review finding 4).

**6e. The helper gate** (privileged helpers by task id). Its shape is in 2.2.

**6f. `agents check` and `agents migrate`**, moved in from Later ("`agents boundary`"). `check`
prints, per user, with counts only: its user and groups, which declared paths it can read and
write, each gate entry allowed or refused, every path on a filesystem that cannot hold ownership
(reported unprotected, never counted as protected: R2.6, BRD-8), and what secrets it can reach
(AOF "Visible"); one line per finding and `--format json` (the linter contract's named exception,
review finding 11). Each Feature ships its protected paths in `boundary.d/` (review finding 8); a
consumer adds its expected model (the office from its layout spec). `migrate` re-owns existing
files from a consumer's ownership map, dry run by default, never reading content, reporting
root-owned or 777 trees instead of failing (R8.3).

**6g. The hand-over to back and staff users.** The `Stop` hook, running as the agent, measures the
stretch's cost, then hands the stretch to the background agent's user through a gate entry
(`handover <back>`), on standard input; the back runs as `back-<name>` and never reads the agent's
home (R6.4, AOF req 8). It is review finding 3 closed the broker way (#187 section 11): one
program, no argument pattern, the caller checked. The devhost here does the same for its four
backs.

**7a. Per-group sub-mounts of the shared folder.** In `mount` mode, cloud-folder keeps the main
mount the Operator's (`agentAccess: none` where agents need nothing of it) and adds `agentMounts`:
a remote sub-path mounted read-only (or read-write) with a forced gid and modes (`rclone mount`'s
own `--gid`, `--dir-perms`, `--file-perms`, `--allow-other`, `--default-permissions`), for example
a room's results folder for the room's group (R2.2) or the floor's folders of the personal remote
(R2.3). In `host` mode the folder is a Windows bind mount with no owners: the check reports it
unprotected (Q7).

**7b. Per-user ssh-agent sockets and register keys.** ssh-agent gains a `per-user` mode: the
drop-in starts one agent per user on `/run/agents/ssh/<uid>.sock` (the user's, 600) and loads that
user's register key from OpenBao through the user's own AppRole (5+), with a lifetime, memory only,
as `key:load` does today. The signing process is then the key's user (R1.6, R3.6, R4.4; AOF req 3).
Both principals of a room append to its store through the store's group (6c). How a key is made
(AOF: the agent makes it, the Operator's rekey takes the public key) is the register's own code.

### 2.2 The helper gate, against the held brokers

Both BRDs ask for the same thing in different words: a short list of named commands that run with
more rights than the caller, the caller known from the kernel (office R3, AOF req 2). The smallest
form:

```
 agent-roomA (sandboxed Bash call)            the gate (helper-pipe's listener)
   task <id> VAR=value  <path argument>          /run/agents/gate/helper-pipe.sock (0660, dcf-work)
     | the consumer's task calls the client         |
     v                                              v
   agent-helper <id> VAR=value  ---- socket ----> 1 caller  = SO_PEERCRED uid (the kernel)
     (opens <path> as the caller, no link        2 entry   = allowlist[<caller>][<id>]   (root-owned,
      out of its tree; sends it as the                       from the agent list on the base branch)
      body, R3.3)                                3 vars    = the entry's named variables, by kind
                                                 4 code    = the task from a snapshot of the base
                                                             branch, never the working tree
                                                 5 env     = fixed: PATH, the helper's AppRole,
                                                             AGENT_CALLER_UID and _USER set by the gate
                                                 6 audit   = time, caller, id, allowed/refused, exit
                                                 7 run     = as helper-pipe, umask 002, in the
                                                             caller's level folder; detach if marked
                                                 refusal: "agent-helper: refused: <id>: <why>", exit 3
```

- **Why a socket, not `sudo`.** Step 2 is strict (D5): every Bash call is sandboxed, and the
  sandbox sets `no_new_privs`, under which `sudo` cannot start (#187 review finding 9; inventory
  section 5, row 6). A listener judged by `SO_PEERCRED` needs no setuid step and works from inside
  the sandbox once its socket is listed (decision 7). It is the "caller from the kernel uid" both
  BRDs name, literally.
- **One unprivileged listener per helper user**, started at container start; no root daemon. A
  helper that must write into a room is a member of that room's group (setgid folders do the
  rest); the scope check against the caller's room is the consumer's task, reading
  `AGENT_CALLER_UID` that the gate sets (office section 5). If the number of helper and back users
  makes per-user listeners costly, one root-started listener that drops to the entry's user is the
  fallback (T19).
- **Long jobs** (R7.3): an entry marked `detach` runs under `setsid`; agents read its state with
  another entry and cannot signal another uid's process; the Operator stops it.
- **Credentials**: a helper logs in with its own AppRole (5+, `DCF_SECRET_AS`), fail closed; the
  office's push token and app key belong to helpers, never to agents.
- **Guards**: a guard helper holds what agents must not read (the redact list, AOF req 13), and the
  pre-commit hook pipes the staged diff to it; it reports `forbidden word #N`, never the word, as
  `devhost-verify` already does (Q4).

| From #187 (brokers) | In the gate? | Why |
|---|---|---|
| one shared implementation in `src/common`, vendored (section 6) | reused | the gate's server and client are a shared script; brokers can build on it later |
| the caller from the kernel (section 8), refused when missing or root | reused, as `SO_PEERCRED` (its section 14's fallback) | `sudo` cannot run in the sandbox (its finding 9) |
| the policy fixed outside the checkout, allow-list only, unknown refused (section 1) | reused | the allowlist is root-owned, read from the base branch |
| code run only from the base branch as committed (section 10.3) | reused, for task code | the task file and its scripts are agent-writable in the working tree |
| a fixed environment, helpers by full path (finding 4) | reused | |
| one refusal line, exit 3; one audit line without values (section 6, decision 13) | reused | |
| the refusal-test harness with a planted fault (`dcf-broker-test.sh`) | reused | |
| the broker's own AppRole, fail closed (section 12) | reused, through 5+ | |
| the backs' hand-over as an instance (section 11, finding 18: callers are named users only) | reused (6g) | |
| one registry of fixed numbers (finding 12) | reused (Q5) | |
| a service account per resource (`dcf-git`, `dcf-gh`, kube, az, docker) with manifests | not needed | the unit is a consumer's reviewed task, not a tool's verbs |
| per-verb flag allow-lists, exact spelling, argument kinds of a tool | not needed | arguments are the entry's named variables; the task decides |
| shims on PATH under the tool's name | not needed | agents call the task; the client is `agent-helper` |
| the git dir owned by a broker (section 10) | not needed | the git dir's `config` residual stays as accepted (3.3, step 3); the office pushes through `save` |
| `sudo` per call and its rules (sections 6, 14) | not needed | replaced by the socket |
| `credentials: file` per broker, the docker broker, the MCP front door | not needed | |

### 2.3 Order

1. Steps 1 to 5 as accepted (5+ can follow 5 in the same openbao minor).
2. **Step 6 as accepted, with 6a** (`runAs: agent`, one user, `dcf-work`): T9 green, then the
   Operator runs `key-file-rotate` (D16). This closes the key file for both consumers early.
3. **6b, 6c, 6d, 6f** (users, groups, homes, check and migrate), after **T2** (modes on the
   Windows mounts) and **T15** (sign-in per user).
4. **6e and 6g** (the gate, the hand-over) with **T16** (the gate from a sandboxed call).
5. **7a, 7b** (sub-mounts, per-user ssh-agent) with **T20**.
6. Step 8 as accepted.

New tests: **T15** a per-user Claude home signed in by a stack token: a resident starts, Remote
Control reaches it, the token rotates; **T16** `SO_PEERCRED` through a socket listed in
`allowUnixSockets` from a sandboxed Bash call, refused for an unlisted caller, and a planted
fault; **T17** Claude's messaging between sessions of two users; **T18** POSIX ACLs and setgid on a
Docker volume and on the Windows mounts; **T19** start cost of making users at start, one gate
call, idle listeners; **T20** a per-user ssh-agent socket from a sandboxed call, refused for
another user.

### 2.4 What the revision does not stop (added to 3.3)

- **Anything committed is readable by every user who can read the git objects**: a file hidden by
  its mode in the working tree is one `git show` away. Least privilege of knowledge (AOF req 13)
  holds only for what lives outside the repository the agents read.
- **On a mount without owners**, per-level separation is reported, not enforced (R2.6), unless T2
  passes or the consumer moves that tree.
- **A gate entry runs what the base branch says**: it is as safe as review of `main`; a task
  changed on a topic branch runs privileged only after it is merged.
- **Helpers trust the consumer's own scope check**: the gate gives the caller; refusing another
  room's item is the consumer's task.
- **The Operator's user keeps root** (D9), and the docker socket stays root for whoever has it.

## 3. Owners, versions, what each consumer changes

### 3.1 Which Feature owns each element

| Element | Feature | Version (next, numbers taken at build) | Breaking? |
|---|---|---|---|
| `runAs: per-agent`, users and groups from the list at start (`user:`, `group:`, `uid:`, `groups:`, helper and back entries), `uidRange`, refusal instead of fallback, `agents sync`, `agents check`, `agents migrate` | agents (2.1.3) | 2.2.0 for step 6 as accepted; 2.3.0 for 6b to 6g | no: opt-in; the default flip stays Later (3.0.0) |
| `dcf-work` and the fixed-number registry; the gate's server and client (`agent-helper`), its test harness | common (1.0.4), vendored into agents | 1.1.0 | no |
| a Claude home per user, shared skills linked, the sign-in route, `allowUnixSockets` entries, the extra managed deny lines, the `SessionStart` warning | claude-code (1.9.9) | 1.10.0 for steps 2 and 3 as accepted; 1.11.0 for 6d | no: inert unless `runAs` is `per-agent` |
| `core.sharedRepository=group` with `dcf-work`; the wrapper as several users; a NOTES line for a user trailer hook | git (1.4.6) | 1.5.0 | no |
| `per-user` mode: one agent per user, register keys loaded through the user's AppRole | ssh-agent (1.5.0) | 1.6.0 | no |
| an AppRole per agent and helper user from the list; `DCF_SECRET_AS` (`openbao-agent-login`); share tasks refuse by user beside the variables; the token file per user; the unix listener | openbao (1.6.0, unreleased with the SSH CA) | 1.6.0 if it is still unreleased when built, else 1.7.0 | no; dropping the variable check is 2.0.0 (Later) |
| `agentAccess` (step 7 as accepted) and `agentMounts` | cloud-folder (1.3.3) | 1.4.0 | no |
| the per-user `GH_CONFIG_DIR`, held by a helper user where one pushes | gh (1.1.0) | 1.2.0 | no |
| the backs as back users through the gate; the cost report across users; the redact list behind a guard helper | devhost (local) | after 1.15.0 (step 4) | local, not published |

AOF's constraints, traced: **common-utils** (users and groups per agent, `sudo` for the operator
only): unchanged; the agents Feature makes the users and none of them gets `sudo`. **agents** (a
user per entry, started as that user): 6b. **claude-code** (a config folder per user): 6d.
**agentic-register** (each key readable only by its principal, the live store writable by a group):
7b and 6c here, the code AOF's. **openbao** (the operator token for the operator only, an AppRole
per agent): steps 5, 6, 5+. **ssh-agent** (a socket per user, or for the operator only): 7b.
**git and the hooks** (a shared git dir through a group, hooks working for every user): 6a.
**gh** (per agent or behind a group): Q2. **The staff** (their own users, reading the turns they
record): 6b, 6g. **The relay** (a relay user per stack, a shared gid): the number registry here, the
relay user AOF's.

### 3.2 What the office changes

- Its agent list gains users, groups (one per room and the floor), uids, back entries for the
  housekeepers and gate entries per agent (its task names of R3.1).
- Its Taskfile routes each privileged task id through `agent-helper`; its tasks read
  `AGENT_CALLER_UID` and refuse outside the caller's room (its own section 5).
- Its secrets move to AppRoles (step 5's consumer change, R4.2); the board tool's app key into
  OpenBao.
- Its own deny rules into the managed list, or `lockPermissions` off (R2.5).
- An ownership map from its layout spec for `migrate` and `check`; `migrate` dry run, then real.
- Its shared folder: `mount` mode with sub-mounts, or `host` mode reported unprotected (Q7); its
  checkout on the Windows mount follows T2.
- A register key per principal; then `key-file-rotate` on each machine.

### 3.3 What AOF changes

- Its own code, as its BRD lists (the register's key creation and public-key rekey, the writer
  lock in the group, per-user reader caches, a relay user per stack, a process per staff member,
  the bridge's contacts): AOF's tooling and host agents, not devfeat.
- Its `devcontainer.json`, start tasks, hooks and staff runner onto the users, with its own ADR.
- Its agent list with users, groups per shared resource and uids from its range; worktrees owned
  per agent on their volume (Q8).
- Its relay user from the shared relay gid and its range (Q5).
- Then `key-file-rotate`; the seed-tag key under its own ADR.

## 4. Open questions, each with a recommendation

1. **Where the Operator works.** *Recommendation:* the remote user, in VS Code's terminal and
   `task dc:shell`, keeping `sudo`, a member of `dcf-work` and of every declared group (added at
   build; a group added later reaches the Operator's long-lived processes only after a restart,
   review finding 6). Agent users are named `agent-<identity>`, so AOF's remote user, which has the
   same name as its main agent's identity, stays distinct from `agent-host`.
2. **GitHub: a token per agent or one bot.** *Recommendation:* one bot per stack, held by whoever
   pushes: a helper user where the consumer pushes through a helper (the office's `save`), the host
   agent's user otherwise (step 1's narrow token, AOF); no token per agent; a GitHub App identity
   later (D4's Later), which also removes the Admin bypass.
3. **Claude sign-in: shared or per user.** *Recommendation:* the state per user always (6d:
   transcripts and memory are tied to the user's home, not to the sign-in); the sign-in one
   long-lived token per stack (`claude setup-token`), kept in OpenBao and read by each user's own
   AppRole into its environment at start, nothing at rest (ADR-0048 decision 1); a per-user
   interactive login through an adapter verb `login` (review finding 9) only if T15 shows Remote
   Control needs it.
4. **Guards and the redact list without agents reading it** (AOF's open question). *Recommendation:*
   the list moves out of the checkout into a guard helper user's folder; the pre-commit hook pipes
   the staged diff to the gate entry `guard:names`, which answers `forbidden word #N` and the
   exit code. Back guards and `devhost-verify` call the same entry.
5. **Fixed uid and gid ranges per stack.** *Recommendation:* one registry in `src/common`'s NOTES
   for every fixed number of the collection: shared gids from 19900 (`dcf-work` 19900, the relay 19901),
   helper and service users 19950 to 19998, agent users in blocks of 1000 per stack from 20000
   (this repository 20000, then one block per consumer, chosen with `uidRange`); an entry's `uid:`
   wins; a collision refuses the start.
6. **The seed: from day one or an option** (AOF asks its seed agent). *Recommendation:* an interview
   option, default `runAs: agent` where the planting runs agents, `per-agent` when it has more than
   one identity.
7. **Mounts that hold no ownership** (the office's checkout and `host`-mode shared folder).
   *Recommendation:* run T2 first; where it fails, report the paths unprotected (BRD-8), offer the
   shared folder's `mount` mode with sub-mounts, and leave moving the checkout to a volume to the
   office; a forced-owner FUSE view per room (`bindfs`) only if the office asks after T2.
8. **Per-path owners inside one working tree** (AOF: an agent cannot write another's folders in its
   own worktree). git rewrites files by replacing them, so a merge that touches a path the agent
   cannot write fails. *Recommendation:* the unit of ownership is the worktree (AOF's
   `.worktrees/<agent>/` on a volume); paths inside one tree that belong to another agent are
   protected by review and the pre-commit check as today; a merge into a tree goes through a helper
   where it must touch them (the office's `save` pattern).
9. **Least privilege of knowledge** (AOF req 13). *Recommendation:* accept it as narrowing, as AOF's
   BRD itself does: what must be hidden lives outside the agents' repository (the image, the state
   home, OpenBao) and is read through a guard helper; devfeat's own NOTES are published and cannot
   be hidden.
10. **Commits traceable to the user** (AOF "Auditable") with one bot identity (office R5.1).
    *Recommendation:* keep the bot identity; the consumer's `prepare-commit-msg` hook adds a trailer
    from `id -un` (the kernel's answer, not a variable); the git NOTES give the line.
11. **Helper listeners: per helper user, or one root-started.** *Recommendation:* per helper user,
    unprivileged; one root-started listener only if T19 shows idle listeners cost too much.
12. **Agent-to-agent messaging across users** (AOF req 7; out of scope for the office).
    *Recommendation:* T17 first; if Claude's own messaging does not cross users, through a
    group-writable mailbox or a gate entry, as the office's section 5 says.

## 5. Decisions for the Operator

Only the revision's decisions; "overturns" marks an accepted decision of section 14 or an accepted
ruling.

1. **Users per identity enter the deliverable** (`runAs: per-agent`, `agent` kept). *Recommendation: yes.* Overturns D7 as the end state.
2. **In `per-agent` mode users and groups are made at start, from the agent list as committed on the base branch.** *Recommendation: yes.* Partly overturns D8 (install time).
3. **A shared group `dcf-work` with a fixed gid, in both modes, instead of the remote user's primary group.** *Recommendation: yes.* Overturns D10.
4. **Groups declared in the agent list (a level group for the office, groups per shared resource for AOF), setgid folders, ACLs for cross-level reads, after T2.** *Recommendation: yes.*
5. **A Claude home per user in the claude-code volume; the root stays the Operator's.** *Recommendation: yes.* Partly overturns D8 (the volume handed whole).
6. **A helper gate (task names, caller by `SO_PEERCRED`, code from the base branch) enters the deliverable; the per-tool brokers of #187 stay held.** *Recommendation: yes.* Overturns the 2026-11-06 hold for this narrow part.
7. **Step 2's sandbox lists exactly two socket folders in `allowUnixSockets` (the gate, per-user ssh-agent).** *Recommendation: yes.* Amends accepted step 2 text.
8. **The hand-over to back and staff users through the gate, the stretch on standard input, its cost measured before.** *Recommendation: yes.*
9. **One AppRole per agent and helper user; share tasks refuse by user in an openbao minor.** *Recommendation: yes.*
10. **`agents check` and `agents migrate` (dry run first) in the deliverable.** *Recommendation: yes.*
11. **Fail closed: with `runAs` set and a user missing, the start refuses; no fallback to the Operator's user.** *Recommendation: yes.* Amends 6.1's text.
12. **cloud-folder `agentMounts` (per-group sub-mounts in `mount` mode) beside `agentAccess`; `host` mode reported unprotected.** *Recommendation: yes.* Amends D15.
13. **ssh-agent `per-user` mode; register keys loaded through each user's AppRole.** *Recommendation: yes.*
14. **D12 kept: an agent still cannot `agents start` another; the hand-over and helpers are gate entries.** *Recommendation: keep.*
15. **One fixed-number registry in `src/common`, blocks per stack, `uid:` per entry** (Q5). *Recommendation: yes.*
16. **Order: step 6 as accepted (with `dcf-work`) and `key-file-rotate` first; the per-identity steps after T2, T15 and T16.** *Recommendation: yes.*
17. **Claude sign-in: one stack token from OpenBao per user environment; a per-user login only if T15 requires it** (Q3). *Recommendation: yes.*
18. **GitHub: one bot per stack, held by whoever pushes (a helper or the host agent's user); no token per agent** (Q2). *Recommendation: yes.*
