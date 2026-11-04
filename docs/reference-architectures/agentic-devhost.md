# Agentic devhost

A devcontainer in which agents do the work and keep the records: one list of agents, a host session the
Operator talks to, background agents that keep the ledger, the backlog and the lexicon, guards that check what
they write, and git that commits as a bot. It is the shape of this repository's own devhost.

## Who it is for, and when to use it

Use it when an engineer or a maintainer runs software delivery with agents in a repository and wants the
agents' work recorded, checked and bounded: who may commit, what may be written, what a session costs. The
guidance is the devhost's way of working ([CONTEXT.md](../../CONTEXT.md), [PROCESS.md](../../PROCESS.md)); this page
is only how the Features are assembled. The real example is
[`.devcontainer/devcontainer.json`](../../.devcontainer/devcontainer.json).

Two Features here are **local and unpublished**: `devhost` (the way of working: backs, ledger, briefing, verify
guards) and `agentic-register` (signed, mergeable registers; the ledger is the first). They live in
[`local-features/`](../../local-features), are not released (ADR 0025), and are referenced by path, as
`./features/<id>`. A consumer receives them as files through the seed (ADR 0044), and the repository stages them
into `.devcontainer/features/` before every start. A Feature that cannot be pulled cannot be named by a
published id, and `task lint` refuses it in the fragment below if you try.

Not for: a repository that only wants a coding agent in a container (add `claude-code` and `agents` to the
[Windows workstation devhost](windows-workstation-devhost.md) and stop there), or one that needs the secrets of
[secrets with OpenBao](secrets-with-openbao.md): the operator key of the register is the first of those.

`gh` is part of it too: the branch and pull-request tools read pull-request state through it, and its login is one of
the things a rebuild loses (see the [Windows workstation devhost](windows-workstation-devhost.md)).

In this page "host" is the workstation, as in the other architectures; the devhost's own word for the main Claude
session is "Host" (see the lexicon), so it is called the host session here.

## Diagram

```text
 WORKSTATION (host)                      OPERATOR
 +-------------------------------+        |  terminal, or phone through Remote Control
 | task devcontainer:agent -- host|<-------+
 | (launcher: up, exec)           |
 | initializeCommand: stage the   |
 |  local Features from the checkout
 +---------------+---------------+
                 | devcontainer exec
                 v
 +-------------------------------------------------------------------------------------------+
 | DEVCONTAINER                                                                              |
 |                                                                                           |
 |   agents list  .devcontainer/agents.yml --->  task agents -- <name>                       |
 |      host: on-demand, --remote-control          |  lease: one live copy per stateful agent |
 |      residents: run from container start        v  (agents up, postStartCommand)           |
 |                                          agent-adapter-claude  (claude-code Feature)      |
 |                                                 |                                         |
 |   CLAUDE CODE  host session  <--- hooks: SessionStart  devhost-briefing                   |
 |        |  cons (sub-agents, briefed per job)    Stop, SubagentStop  devhost-run-job       |
 |        |                                                 |                                |
 |        |                         BACKS (background, inside the devhost only)              |
 |        |          scribe ledger | secretary TODO.md | librarian LEXICON, ADRs | tester   |
 |        |                                                 |                                |
 |        v                                                 v                                |
 |   git (wrapper: bot identity when CLAUDECODE is set)   GUARDS                             |
 |        |    pre-commit: devhost-verify (ledger append-only, secrets, names, ADR shape)    |
 |        |    register guard: names, forbidden words, secrets, on every entry               |
 |        |    phi-check: the repository wires it into the hook and CI                       |
 |        v                                                                                  |
 |   topic branch --> the host session pushes, opens the pull request (ADR 0040)             |
 |                                                                                           |
 |   volumes (tier 4): claude-code-config  devhost-state  agentic-register-state  git-config |
 |   container filesystem only: agent leases (a lease must not survive a rebuild)            |
 +--------+-------------------------+----------------------------+---------------------------+
          v                         v                            v
     GitHub: pull requests    Anthropic (the CLI and        shared folder (tier 2):
     reviewed and merged by   the backs' runs)              the register's mirror, once
     the Operator only                                      configured (ADR 0043)
```

## `devcontainer.json`

The Features of this architecture, after this repository's own. The `./features/...` lines are the two local
Features; `task features:stage` here, or your own step that copies them, runs as `initializeCommand` so the CLI can
find them under `.devcontainer/`.

```jsonc
{
  "name": "agentic-devhost",
  "image": "mcr.microsoft.com/devcontainers/base:2-trixie",
  "features": {
    "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/git:1": {
      "hooksPath": ".githooks",
      // Agents commit as the bot; the Operator's own terminal keeps their identity (ADR 0002, 0012, 0016).
      "commitName": "devhost agent",
      "commitEmail": "devhost-agent@noreply.invalid",
      "commitWhenEnv": "CLAUDECODE"
    },
    // gh: pull-request state and the branch tools; the login is restored after a rebuild (see the Windows page).
    "ghcr.io/nabil-becker/devcontainer-features/gh:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/claude-code:1": {},
    // Major 2: the agent list, leases and session names. The list is .devcontainer/agents.yml.
    "ghcr.io/nabil-becker/devcontainer-features/agents:2": {
      "sessionName": "{machine} {handle}"
    },
    // The repository wires the check into its pre-commit hook and CI; the Feature installs no hook.
    "ghcr.io/nabil-becker/devcontainer-features/phi-check:1": {
      "exceptions": ".phi-exceptions.txt"
    },
    // Local and unpublished: the way of working, and the register that holds the ledger.
    "./features/devhost": {},
    "./features/agentic-register": {
      // name:type:guard=<absolute command>; the guard runs with no environment, so it is told the root.
      "registers": "ledger:ledger:guard=/usr/local/bin/devhost-register-guard --root=/workspaces/myrepo",
      "registerMcp": false
    }
  },
  "containerEnv": {
    // A handle on ledger entries and the cost report; committed, so never a name.
    "DEVHOST_ENGINEER": "${localEnv:DEVHOST_ENGINEER:operator}",
    // The workstation's machine name, set by the launcher; session names use {machine}.
    "DCF_HOST_MACHINE": "${localEnv:DCF_HOST_MACHINE}",
    // A tracking point for the month's agent spend at list price, in dollars. Not a cap.
    "DEVHOST_MONTHLY_TARGET": "200"
  },
  // Host side, before every start: copy the local Features under .devcontainer/features/ (gitignored).
  "initializeCommand": ["task", "features:stage"],
  "postCreateCommand": "bash .devcontainer/post-create.sh",
  "remoteUser": "vscode"
}
```

Also in the repository: `.devcontainer/agents.yml` (for example one `host` agent, `cli: claude`, `kind: on-demand`,
`args: [--remote-control]`, `default: true`), the hooks in `.claude/settings.json` that `task devhost:init`
writes, and `.githooks/pre-commit` calling `devhost-verify`. A line such as
`git diff --cached --name-only --diff-filter=ACM -z | xargs -0 -r phi-check` goes in the same hook where the
repository's rule is that PHI never enters it.

## Data and its storage tier

Tiers as in [ADR 0045](../adr/0045-four-storage-tiers-govern-where-data-lives-and-a-machine-loss-must-lose-nothing.md).
The records are the point of this architecture, so where each lives matters most here.

| Data | Where it lives | Tier | A rebuild | Losing the machine |
| --- | --- | --- | --- | --- |
| Code, ADRs, lexicon, `TODO.md`, the ledger's frozen months `docs/ledger/YYYY-MM.md` | the repository | 1 | untouched | kept once pushed |
| The month's cost store `docs/ledger/costs-YYYY-MM-<engineer>.jsonl` | the repository, committed beside the ledger | 1 | untouched | kept once pushed |
| The register's live store (the ledger as signed entries) | volume `agentic-register-state-${devcontainerId}` | 4 | kept | lost, unless mirrored: the mirror to the shared folder is the ADR 0043 plan and is not configured in this repository yet, so the git copy is the one that survives |
| The register's mirror (once configured) | the shared folder, `mirror=<folder>` | 2 | untouched | kept |
| The register's keys, anchors and the reader's own records | the same volume | 4 | kept | the operator key is on its way to OpenBao (ADR 0048); until then a loss needs the offline recovery key |
| Claude Code login, settings, session transcripts, the adapter's agent records | volume `claude-code-config-${devcontainerId}` | 4 | kept | login again; transcripts are gone, which the committed cost store survives |
| The backs' offsets, locks, logs and metrics | volume `devhost-state-${devcontainerId}` at `DEVHOST_STATE` | 4 | kept | rebuilt: a back that finds no offset reads the stretch again |
| Agent leases | the container filesystem, on purpose | none | gone, as intended | gone |
| git identity of the container | volume `git-config-${devcontainerId}`; the bot identity is the Feature's options | 4 / 1 | kept | rewritten at post-create |
| The exceptions of `phi-check` | `.phi-exceptions.txt`: a dated, reasoned line per file | 1 | untouched | kept once pushed |
| The name list the guards refuse (`.devhost/redact-names.txt`) | the checkout, git-ignored, never committed | per machine; ADR 0045 does not name it | untouched | written again by hand |
| The site the Operator reads | `.devhost/site/`, git-ignored, regenerated; its URL in `.devhost/site-url` | none | regenerated | regenerated |

## On the workstation, and in the container

| On the workstation (host) | In the container |
| --- | --- |
| the launcher: `task devcontainer:agent -- <name>` starts or attaches an agent; `task devcontainer:up`, `exec`, `stop` | the agents, the host session, the cons, the backs: they act only inside the devhost (the hooks do nothing on a workstation) |
| `initializeCommand`: staging the local Features | `task agents`, `agents:list`, `agents:leases`, `agents:check`; `agents up` at every container start, never fatal |
| the Operator's terminal or phone (Remote Control) | the git wrapper: bot identity for any process Claude Code starts; the person's own terminal keeps their identity |
| a workstation session, used only for work outside the checkout: no backs, so the records are done by hand at close | the guards: `devhost-verify` at commit, the register guard on every entry, `phi-check` in the hook and CI |
| nothing scheduled: no background process of ours on the host (ADR 0024) | commits and pull requests on topic branches by the host session; the Operator reviews, merges and releases (ADR 0040) |

## Best practices

- **One list, one verb.** Declare the agents in `.devcontainer/agents.yml` and start them with
  `task devcontainer:agent -- <name>` (inside: `task agents -- <name>`). Mark one agent `default: true`. Keep the
  host session `on-demand` with `--remote-control` until a background session is shown to be reachable through
  Remote Control.
- **Agents commit as a bot, with an address nobody can claim.** `commitWhenEnv: CLAUDECODE` applies the identity
  only to processes an agent started, and a co-author trailer names the model, at a `@noreply.invalid` address. A
  stranger's GitHub account appears to have claimed `noreply@anthropic.com`, and it shows up as a participant (ADR 0002).
- **Brief a con by the files it owns.** One pull request touches only its own files; the brief says who the work is
  for, names the pull request template when the con opens one, passes the Operator's decisions in full, and asks for
  the hand-off shape. Size the model by blast radius.
- **Prove a fix with a test that fails without it**, stashing only the fix file. Ledger 2026-10-29 "claude-code 1.8.7
  wake fixes: stop before resume, saved flag order, PR #105": the first mutation check stashed the test with the fix.
- **Run the architecture review before the ruling**, and check a finding against the ADR list before accepting it
  (ADR 0039; ledger 2026-10-29 "PR #115 opened: architecture review before every ruling").
- **Create worktrees by hand.** Claude Code cannot create one for a subagent here (the git dir sits outside the
  checkout, behind the `/git-dirs` mapping): `git worktree add -b <branch> <path> origin/main`, and
  `git worktree remove` when merged. Put a volume over `.claude/worktrees` so a synced checkout never carries them.
- **Guard what an agent writes, at the door.** The register guard refuses an entry that holds a name, a forbidden
  word or a secret; `devhost-verify` does the same at commit; `phi-check` joins them where health data could appear.
- **Record a release from the registry, not from a report.** Read the workflow run and the registry tag, then write.
- **Test a merge driver with a real merge in a scratch repository**, and check the guard against the doubled lines
  it can produce. Ledger 2026-10-29 "Review changes applied: union merge, duplicate-id guard, PSScriptAnalyzer file
  list, brief guidance": a union merge can duplicate a line both sides edit; the `backlog_ids` tests in `test:devhost`
  cover it.
- **Split a contract into "can it" and "do it".** A side-effect-free `supports` answer says whether an adapter can
  do a verb; the verb's exit code is the authority at run time; test that the two agree (`test:agents-contract`,
  ledger 2026-10-29 "Decision: keep the supports verb").
- **Write "cause not proven" when it is not, and check a blame against the evidence before filing it.** Ledger
  2026-10-30 "Start failure traced to cloud-folder post-start and ssh passphrase wait" was wrong (the hook took 0.08
  s) and was corrected the same day with a `Corrects:` line; nothing stops a first wrong entry.
- **After a rebuild, rebuild to the CLI version the consumer runs** before you fix a Claude Code behaviour, and
  record the CLI version in the entry and the NOTES.

## Anti-patterns

### A1. Trusting a background-session record after a rebuild

- **Don't:** trust a stored session record or a pid after a rebuild or an engine move, or start `attach` twice in
  quick succession.
- **Why:** issue #155 "agents Feature: a fresh container starts a second copy of a resident agent"; ledger
  2026-11-03 "Stale background record cleared before agent wake; copy becomes an error (#155)": each `agents up`
  after a rebuild started two hidden copies.
- **Instead:** prove a record dead (a pid in another namespace, absent from `/proc`, a different start time) before
  any wake; report a copy that still results as an error of the Feature.
- **Caught by:** the 1.9.7 unit tests only; nothing yet against a real service (`second-copies-real-service`).

### A2. Waking a resident with flags, or counting a wake as done because a process exists

- **Don't:** pass flags when waking a session, compare its saved options exactly with the agent's args, or record a
  wake before the session survives its first seconds.
- **Why:** 2026-10-30 "Restart-wake bug fixed in claude-code 1.9.1, PR #131 open" and 2026-10-30 "Resident wake stays
  bare; extra saved options no longer start a copy": Claude Code adds options the operator never passed. 2026-10-30
  "Consumer's claude-code 1.9.2 findings triaged": a session with no transcript crashed after the adapter had
  recorded it.
- **Instead:** a wake is always bare; compare only the wanted options; confirm for `AGENT_ADAPTER_SETTLE` seconds;
  start fresh when the transcript is missing.
- **Caught by:** `test:claude-unit`, the adapter checks from 1.9.3 and 1.9.4; the real-CLI case is nothing yet
  (`agents-real-cli-canary`).

### A3. Fixing a Claude Code behaviour on a different CLI version

- **Don't:** fix a behaviour from a consumer's report while the container runs another Claude Code version.
- **Why:** 2026-10-30 "Four fixes released: cloud-folder 1.3.1, ssh-agent 1.2.0, claude-code 1.9.4, agents 2.1.1": the
  container ran 2.1.308 and the consumer 2.1.314, so fork detection shipped modelled, not run; seven claude-code patch
  releases in six days followed.
- **Instead:** rebuild to the consumer's version first and record the version in the entry.
- **Caught by:** nothing yet (`rebuild-claude-code-2-1-314` was a one-off; `agents-real-cli-canary` is proposed).

### A4. `pkill -f` with a pattern the shell contains

- **Don't:** let a con run `pkill -f` with a pattern its own shell command line contains, or share a log with other
  cons.
- **Why:** 2026-10-30 "Start hook no longer waits on ssh-add; passphrase prompt gets a bounded wait and a warning": a
  con killed its own shell twice, after the guidance was written; the ledger review of 2026-10-29, group 5.
- **Instead:** stop by pid, wait on your own background jobs, write a long run to your own log, hand back once.
- **Caught by:** the brief guidance in `CLAUDE.devhost.md` only; a permission classifier also refused a `pkill` on
  2026-11-03; no test.

### A5. A docs or ruling con editing files another slice owns

- **Don't:** brief parallel work without saying which files each con owns.
- **Why:** 2026-10-30 "Session names ruling recorded in #126, ADR 0041 and tests item corrected": a con edited the
  `agents` NOTES and README that another slice was rewriting; the host took the edits out.
- **Instead:** the brief lists the files the con owns; one pull request touches only its own.
- **Caught by:** host review; nothing yet (a proposed clause in the briefs).

### A6. Merging `TODO.md` or the ledger with a plain union

- **Don't:** merge `TODO.md` or a ledger file with a plain union, or rely on GitHub's server-side merge for them.
- **Why:** 2026-10-30 "PRs #118 and #119 merged to main": three ticked items doubled; 2026-10-30 "PR #135 merged to main
  with main merged in": GitHub could not merge `TODO.md`.
- **Instead:** keep the backlog and the ledger out of git (ADR 0054): the backlog in the shared folder, the
  ledger in the register. Until 2026-11-04 this repository used the `devhost-todo` merge driver instead.
- **Caught by:** the `backlog_ids` guard in `devhost-verify`, and the driver (#121, #123).

### A7. Branches and records that do not line up

- **Don't:** name a branch `feat/...`, or push code whose backlog item exists only in uncommitted records.
- **Why:** 2026-10-29 "Agents 1.0.3: CLI capabilities in agents check pushed" and 2026-11-02 "Devhost seed change
  committed and opened as PR #148": branches named `feat/...` broke the rule and were refused by the push check after
  the work was done; 2026-11-02 "Launcher engine-wait and agent-name fixes committed and opened as PR #147": the
  backlog item was still only in uncommitted records.
- **Instead:** `task devhost:branch -- <backlog-id>` makes `<type>/<id>/<n>` with `<type>` one of feature, fix, docs,
  chore, and the item is committed with the change.
- **Caught by:** the `pre-push` hook, after the fact (`branch-task-push-check`).

### A8. Recording a release, a merge or a tick from a report

- **Don't:** write that something was released, merged or done because the host said so.
- **Why:** 2026-11-03 "claude-code 1.9.7 released with the fix for #155" and 2026-11-03 "Records PR #159 opened": the
  1.18.1 run was not confirmed; corrected entries on 2026-10-19.
- **Instead:** read the workflow run and the registry tag (the token needs `read:packages`), then write.
- **Caught by:** nothing yet (`scribe-commit-verification`).

### A9. A decision settled in chat and left open in the records

- **Don't:** settle a point in chat and leave the ADR or ledger listing it open, or apply a decision to an open pull
  request without checking whether its release has shipped.
- **Why:** 2026-11-02 "Operator confirms the three open calls on the ledger register guard"; 2026-11-03 "Queue
  wording changed to 'N waiting' in PR #158 (1.18.1)": 1.18.0 had shipped.
- **Instead:** write the decision into the ADR or the ledger at once; check the release first.
- **Caught by:** nothing yet.

### A10. A registry image for something you also ship locally

- **Don't:** depend on a published image of a Feature the repository also carries as files.
- **Why:** 2026-11-02 "Why the devhost still looks published: moved out of the release, old image and seed starter
  remain".
- **Instead:** the seed carries `local-features/devhost` as files and the registry package is deleted (ADR 0044); name
  it `./features/devhost`.
- **Caught by:** ADR 0044, and `task architectures:check`, which refuses a local Feature named by a published id.

### A11. Importing a ledger without a dry run

- **Don't:** import a Markdown ledger into the register without a dry run and an entry count, or run `roster --key`
  without the `.pub` beside the key.
- **Why:** 2026-11-03 "Ledgers 2026-10 and 2026-11 imported into the register (550 entries)": stray code fences needed a
  workaround; 2026-11-03 "Operator's key signed host, scribe and secretary onto the agent roster": a traceback.
- **Instead:** dry run first, compare the counts, keep the `.pub` beside the key.
- **Caught by:** nothing yet (`import-stray-fence`, `register-roster-traceback`).

### A12. Editing a settings file by redirecting onto itself

- **Don't:** redirect a command's output onto the file it reads, in the Claude settings or any config.
- **Why:** 2026-10-31 "Auto-mode settings merged into Claude settings; 27 lines confirmed": a split paste emptied
  `settings.json` before `jq` failed.
- **Instead:** back up, write a temporary file, replace.
- **Caught by:** nothing; practice since 2026-10-29 "Factcheck folder trusted in the Claude config, backup kept".

### A13. A briefing that stays silent about stale tooling

- **Don't:** let the session start without saying that the installed devhost is older than the source in
  `local-features/devhost`, or that a project is in flight.
- **Why:** 2026-11-03 "Devhost restarted after the rebuild" and 2026-11-03 "Cloud folder and ledger-out-of-git project
  status reported": the backs run the installed devhost, so a fix in the source is not live until the container is
  rebuilt, and the state of a long project had to be asked for.
- **Instead:** the briefing warns, in one line, when the source's version is newer than the installed one, and names
  the project in flight.
- **Caught by:** the briefing's version-gap line, in the devhost's notes, for the first half; nothing yet for the project
  in flight or a report after a restart (`restart-restore-report`).
