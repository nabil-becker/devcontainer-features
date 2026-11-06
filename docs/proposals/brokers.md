# Proposal: brokers, a service account and an allow-list per shared resource

Status: proposed 2026-11-06. Awaits the architecture review and the Operator's ruling; build not
started. Backlog: `broker-pattern`, `broker-openbao-hook`, `service-account-broker`. To be decided
with `agent-linux-user` (draft pull request 186), whose `sudo` rule and users it builds on.

Who this serves: the Operator, through the host, who wants agents to reach git, GitHub, a cluster,
Azure and the container engine only for the operations they need, and who reviews and merges;
the maintainers of the office and of DSNP, who adopt the `git`, `gh`, `kube-state`, `az` and
`openbao` Features and would otherwise keep a token per agent; and the authors of Features in this
collection, who get one pattern and shared code instead of writing a gatekeeper of their own.

How to read it: section 1 is the ask and the rulings it rests on; section 2 the problem in the
agent-user design that this solves; section 3 the words; section 4 the picture; sections 5 to 9
the pattern (what a Feature supplies, what the shared code does, how a call runs, who the caller
is, who is not brokered); section 10 git, the first broker; section 11 the later brokers;
section 12 OpenBao; section 13 an optional MCP front door; section 14 performance; section 15
the requirements; section 16 what a consumer changes and what breaks; section 17 the slices;
section 18 the unknowns, each as a test; section 19 the decisions for the Operator; section 20
what was found for the repository. The architecture review goes at the end, written by the host
after this draft.

## 1. The ask

The backlog items, as written:

- `broker-pattern`: "a broker is a service account plus a gate that allows only listed operations,
  in one shared implementation in `src/common`. A Feature that owns a sensitive resource (git, gh,
  kube, docker, az) opts in with `broker: on` and supplies its account, owned path, policy file,
  shim and refusal tests; agents get the shims, not the resource."
- `broker-openbao-hook`: "an OpenBao integration so a team that uses OpenBao can hook a broker in
  easily."
- `service-account-broker`: "a dedicated account (`dcf-git` first) owns each shared resource and
  agents reach it only through a narrow gate with listed operations, refusing `config`, `-c`,
  `--no-verify`, pushes to `main` and hooks; it would fix the git-settings finding."

The Operator's direction of 2026-11-06, designed to here and not reopened:

- One standard pattern with shared code vendored from `src/common`; each Feature opts in through
  its own option (`broker: off|on`); `off` keeps today's behaviour; the default flips only in the
  same major as the agents Feature's `runAs`.
- Each Feature supplies a manifest: the account (`dcf-<name>`), what it owns, a policy file (an
  allow-list), the shim on PATH, and a refusal test for each known escape. The shared code makes
  the account, writes one narrow `sudoers` rule (no wildcard), checks the arguments against the
  policy, writes one audit line per call (the caller's user, the verb), prints plain refusals,
  and provides the test harness.
- The policy is fixed at build time (the image and the Feature options in `devcontainer.json`),
  never read from the checkout, which agents can write. Allow-list only; anything unknown is
  refused.
- The shim on PATH is the enforcement point that every CLI and script calls. An optional MCP
  server is a typed front door generated from the same policy files, never a second rule set; it
  needs an ADR against "MCP: none for now".
- git is the first broker. gh, kube, docker (the tester) and az are sketched as later ones.
- OpenBao integration: an option `credentials: file|openbao` in the shared code, fail closed, two
  independent checks.

Rulings it rests on:

- **ADR-0020.** Every container mounts the whole `.git-dirs` at `/git-dirs`; the git Feature's
  wrapper maps the checkout's `.git` pointer onto it for each call.
- **ADR-0040.** The host commits, pushes and opens pull requests; the Operator reviews, merges and
  releases.
- **ADR-0016, ADR-0002.** Agent commits carry the bot identity (`commitWhenEnv`), and co-author
  trailers use an unclaimable `@noreply.invalid` address, never `noreply@anthropic.com`.
- **ADR-0045.** If losing a machine would lose something, it is in the wrong tier; tier 4 holds only
  what can be rebuilt.
- **ADR-0048.** OpenBao is the master of every secret the collection creates or stores, gh and Azure
  tokens named; every task that handles a share or a token refuses inside an agent's job.
- **ADR-0050.** The Operator's OpenBao token may only reissue secret ids for existing roles;
  creating a role or a policy needs a root token made from the unseal shares.
- **ADR-0058 on `feature/openbao-ssh-ca/1`** (pull request 184). The SSH certificate authority
  signs for the Operator only; agents are read-only.
- **NFR-12, NFR-13, and "MCP: none for now"** (`docs/principles/non-functional-requirements.md`).

## 2. What it resolves in the agent-user design

`docs/proposals/agent-linux-user.md` (draft pull request 186) gives each agent and back its own
Linux user. Its architecture review left four findings that a user alone cannot close:

| Finding of that review | Why a user alone does not close it | How a broker closes it |
|---|---|---|
| 1. The git dir's `config` is not protected by its owner | agents must write objects, refs and the index, so the git dir is group-writable, and `rename(2)` over `config` needs only the folder's write bit | agents never write the git dir at all: `dcf-git` owns it and nobody else may write it, so there is no folder to rename in (section 10.2) |
| 3. The backs' hand-over `sudoers` rule has a wildcard | `*` in a `sudoers` argument matches across spaces, and the runner takes a job path | the hand-over becomes an instance of the pattern: one rule naming one program, no argument pattern, the caller checked by the policy (section 11) |
| 4. The `docker` group is root | an allow-list of `docker` arguments cannot stop a mount of `/` | a `dcf-docker` account is in the group; agents get one verb, never the socket (section 11) |
| 14. Tokens at rest per agent | 8.4 and 8.5 keep a token per agent in its own folder until `openbao-agent-login` | a credential belongs to the broker's account, one per resource, and never enters an agent's process; with `credentials: openbao` it is not at rest at all (section 12) |

It also replaces the git half of that proposal's section 9 (`core.sharedRepository=group`, the git
dir group-writable): with the git broker on, only `dcf-git` and the Operator's user write the git
dir. Decision 1 asks to decide the two proposals together for that reason.

## 3. The words (proposed for LEXICON.md, not added here)

The librarian adds these once the Operator rules; this draft does not edit the lexicon.

- **Broker**: a service account, its policy and its shim, which together own one sensitive
  resource (the git dirs, a GitHub login, a kubeconfig, an Azure login, the container engine's
  socket). Agents reach the resource only through the broker's shim; the resource's files and
  credentials belong to the account. Each Feature that has one opts in with `broker: on`.
- **Service account**: the Linux account a broker runs as, `dcf-<name>`: no login shell, a locked
  password, a fixed uid, reached only through its one `sudoers` rule. Not an agent user and not a
  back user; it never runs a model.
- **Broker policy**: the allow-list a broker checks every call against: the verbs, for each verb
  the flags and argument kinds it accepts, and which callers may use it. Fixed at build time.
  Anything not in it is refused.
- **Broker manifest**: the file a Feature ships to declare its broker to the shared code: the
  account, what it owns, the policy, the shim, the real tool, the credentials it needs, the refusal
  tests.
- **Shim**: the executable on PATH under the tool's own name (`git`, `gh`) that hands a call to the
  broker. It is the existing wrapper where a Feature has one (the git wrapper gains the hand-over
  as its first step), so "wrapper" stays the word for the file and "shim" names its broker role.
- **Caller**: the user a brokered call comes from, as `sudo` reports it (section 8).
- **Direct call**: a call by the Operator's user, which the shim runs as that user without the
  broker (section 9).
- **Refusal test**: one line of a broker's test file: a call, the user it runs as, the exit code
  and the start of the refusal it must print.

Two words avoided on purpose: **gate**, which is already OpenBao's unseal and login ("The gate" in
the lexicon), so this proposal says *policy* or *allow-list* for the broker's check; and
**hook** on its own, per the lexicon (git hook, devcontainer hook).

## 4. The picture

### 4.1 One call

```
 agent-host (uid 2xxxx, group dcf-work)          the Operator's user (vscode, sudo)
   git commit -m "..."                             git commit ...
        |                                               |
        v                                               v
 /usr/local/bin/git   the shim (the git wrapper) ------ caller uid = the Operator's? -- yes -->
        | no                                                         /usr/bin/git, as vscode
        v                                                            (a direct call, one audit line)
 sudo -n -u dcf-git -- /usr/local/libexec/dcf-brokers/git commit -m "..."
        |    /etc/sudoers.d/dcf-broker-git:
        |      %dcf-work ALL=(dcf-git) NOPASSWD: /usr/local/libexec/dcf-brokers/git
        v
 dcf-broker, now uid dcf-git, environment rebuilt by sudo
   1 caller    SUDO_UID -> agent-host               set by sudo, not by the caller (section 8)
   2 resource  the git dir recorded for this checkout at post-create, never the .git pointer as
               it stands now; refuse if the call is outside the checkout or its worktrees
   3 trust     git dir, config, hooks folder: group dcf-git, not writable by others
   4 policy    verb commit: allowed for every caller; -m <text> allowed; nothing unknown
   5 rules     identity, sign-off, trailer address, hooks path, no editor, no pager (section 10)
   6 secret    none for commit; for push: a file or OpenBao, in this process only (section 12)
   7 audit     2026-11-06T10:00:00Z git agent-host commit allowed exit=0
   8 exec      /usr/bin/git --git-dir=<recorded> --work-tree=<checkout> commit -s -m "..."
```

### 4.2 Who owns what, with the git broker on

```
                                              agent users   dcf-git    the Operator's user
 /git-dirs/<owner>/<this repo>/   (2770)       -             rwx        rwx  (group dcf-git)
   config, hooks/, info/          (660/2770)   -             rw         rw   (group dcf-git)
 the broker's hooks folder        (root 755)   -             r-x        r-x
 the checkout (group dcf-work)                 rw            rw         rw
 the broker's credential (file mode)           -             r          -    (or OpenBao: none at rest)
 the broker's audit log           (640)        -             append     r    (group dcf-git)
 /usr/local/share/dcf-brokers/git/ policy,     r             r          r    (root, from the image)
   manifest, refusal tests
```

### 4.3 Two independent checks (with `credentials: openbao`)

```
  caller ---> broker policy: may this caller run this verb with these arguments?   (the image)
                 | yes
                 v
              the broker's own AppRole: may this broker read this credential?      (OpenBao)
                 | yes
                 v
              the credential, in the broker's process for this call only ---> the resource
```

Either check alone fails closed. An agent that could change one still meets the other: a wider
policy gets no credential OpenBao does not grant the broker, and a wider OpenBao policy is reached
only through verbs the allow-list names.

## 5. What a Feature supplies: the manifest

A Feature that opts in ships, under `/usr/local/share/dcf-brokers/<name>/` (root, 644):

```
# manifest  (key=value, read by the shared code at install and at every call)
name=git
account=dcf-git
uid=19901                         # from the reserved range in src/common's NOTES (decision 7)
owns=gitdir                       # a kind the Feature resolves: the checkout's own git dir
operator_group=yes                # the Operator's user joins group dcf-git (section 9)
callers=dcf-work                  # the group whose members may call (decision 3)
real=/usr/bin/git                 # the real tool; recorded by install.sh
shim=/usr/local/bin/git           # the wrapper, which hands over
policy=policy                     # the allow-list, beside this file
refusals=refusals.tsv             # the refusal tests, beside this file
credential.push=github-token      # what the verb push needs; see section 12
```

```
# policy  (one verb per line; flags exact; arguments typed; callers by agent identity or *)
verb status    callers=*     flags=-s,--short,-b,--branch,--porcelain[=v1|v2],--untracked-files=no|normal|all
verb diff      callers=*     flags=--cached,--staged,--stat,--name-only,--name-status,--color=never  args=rev*,--,path*
verb log       callers=*     flags=--oneline,-n:int,--format=fmt,--graph,--decorate  args=rev*,--,path*
verb add       callers=*     flags=-A,--all,-u,--update  args=--,path+
verb commit    callers=*     flags=-m:text,-F:-,--amend  force=-s
verb push      callers=host  flags=-u,--set-upstream,--force-with-lease  args=remote:origin,ref:branch-rule
refuse -c,--config-env,--exec-path,--git-dir,--work-tree,--namespace,--no-verify   # named, for a clearer refusal
```

```
# refusals.tsv  (user  call  exit  refusal starts with)
agent-test  git -c core.fsmonitor=x status          3  git: refused: -c
agent-test  git commit --no-verify -m x             3  git: refused: --no-verify
agent-test  git commit --no-ver -m x                3  git: refused: --no-ver (not in the policy)
agent-test  git push origin HEAD:main               3  git: refused: push to main
agent-test  /usr/bin/git -C . status                128 (the real git: permission denied on the git dir)
```

The exact syntax is slice 1's to settle; what matters is the shape. Three properties are fixed:
flags are matched by **exact spelling** (git, gh and az accept abbreviations of long options, so
`--no-ver` means `--no-verify` to git; an allow-list refuses it because it is not spelled in the
list); each value has a **kind** (`text`, `int`, `path` inside the checkout, `rev`, `ref`, a fixed
set), and a `path` is resolved and refused when it leaves the checkout; and **callers** name an
agent identity (`host` is `agent-host`), or `*` for every member of the callers group.

## 6. What the shared code does

Three shared scripts in `src/common`, vendored verbatim into each Feature that opts in, so each
Feature folder stays self-contained when published; `task common:check` already compares every
`src/common/*.sh` with its copies, so `task lint` covers them without a new check.

| Script | When | What it does |
|---|---|---|
| `dcf-broker-install.sh` | `install.sh`, at build, only with `broker: on` | installs `sudo` if absent; makes group and account (system account, `nologin`, locked, the manifest's uid and gid, refused if the uid is taken by another name); adds the account to `dcf-work` (to read the checkout) and, with `operator_group=yes`, the remote user (`_REMOTE_USER`) to the account's group; writes `/etc/sudoers.d/dcf-broker-<name>` with one rule and its `Defaults`, checked with `visudo -cf` before it is moved into place; installs the broker entry point `/usr/local/libexec/dcf-brokers/<name>` (root, 755); writes the resolved settings to a root-owned file |
| `dcf-broker.sh` | every brokered call, as the account | the eight steps of section 4.1: caller, resource, trust, policy, Feature rules, credential, audit, exec; prints a refusal as one line, `<name>: refused: <what>: <why>`, and exits 3 |
| `dcf-broker-test.sh` | the Feature's container tests, and `task <id>:broker:check` | runs each line of `refusals.tsv` as its user (a throwaway `agent-test` user in the tests) and checks the exit code and the start of the message; once more after a planted fault (the policy file made world-writable, the config handed to another owner) to show the check can fail |

The one `sudoers` rule, per broker:

```
Defaults!/usr/local/libexec/dcf-brokers/git env_reset, !setenv, !use_pty, closefrom=3
%dcf-work ALL=(dcf-git) NOPASSWD: /usr/local/libexec/dcf-brokers/git
```

It names one program and no argument pattern. In `sudoers` a command listed without arguments
accepts any arguments, which is deliberate here: `sudo` passes the caller's argument vector as it
is (no shell, no splitting), and the broker's policy judges every argument. `sudoers` judges only
who may become `dcf-git` and which one program runs. No `*` appears anywhere, so finding 3's
"`*` matches across spaces" cannot arise. Decision 2 asks whether to go further.

Settings are read from the root-owned file `install.sh` wrote, never from the caller's environment
(section 15, NFR-6).

The audit line goes to `/var/lib/devcontainer-features/<id>/broker/audit.log` in the Feature's own
volume (NFR-1), owned by the account, group-readable by the Operator's user, one line per call:
time, broker, caller, verb, `allowed` or the refused rule, exit code. Never an argument's value: a
commit message or a path can be content, and committed and logged files hold paths and ids, never
content. It is tier 4 and capped in size (the oldest half is dropped at the cap).

## 7. How a call runs

1. **The shim** (as the caller) decides direct or brokered (section 9) and, when brokered, runs
   `sudo -n -u dcf-<name> -- /usr/local/libexec/dcf-brokers/<name> "$@"`. `-n` makes a missing rule
   a plain refusal instead of a password prompt. The shim passes nothing else: no variables, no
   paths it worked out.
2. **The broker** (as the account) learns the caller (section 8) and finds the resource from its
   own records, never from what the caller says. For git: the checkout's git dir recorded at
   post-create (today's `dirs.env` of the git Feature, moved to a file `dcf-git` owns).
3. **Trust check**: every file the broker will let the tool read as configuration or run as code
   belongs to the account's group (so only the account and the Operator's user can have written
   it), is owned by the account, root or the Operator's user, and is not writable by others, as
   `ssh` checks its own files.
   A failure is a refusal naming the file and the repair task, never a silent fix.
4. **Policy check**: the verb, each flag by exact spelling, each argument by kind, the caller. The
   first unknown token ends the check with a refusal.
5. **Feature rules**: what the Feature adds that a list cannot say (for git: the trailer address,
   the push refspec).
6. **Credential**, only for the verbs the manifest names (section 12).
7. **Audit line**, then **exec** of the real tool with a fixed environment the broker builds:
   `HOME` and `PATH` of the account, the Feature's own variables, and nothing of the caller's.
   Standard input, output and error are the caller's, so pipes and exit codes behave as before.

The broker is a short-lived process per call. It holds no state between calls except the audit
log and, in file mode, the credential.

## 8. How the broker learns the caller

`sudo` sets `SUDO_UID`, `SUDO_GID` and `SUDO_USER` from the **real uid of the process that ran
`sudo`**, which the kernel keeps and the caller cannot change. Under this rule the caller cannot
put its own values there either:

- `env_reset` (the default, written out in the rule's `Defaults`) drops the caller's environment,
  and `sudo` then writes its own `SUDO_*`. A caller that exports `SUDO_UID=0` before calling sees
  it discarded.
- `!setenv` and the absence of a `SETENV` tag stop `sudo VAR=value` and `sudo -E`; there is no
  `env_keep` for any `SUDO_*` variable.
- The account has no other way in: a locked password, a `nologin` shell, no other `sudoers` rule,
  and no rule that lets the account run anything as anyone. So any process running as `dcf-git`
  was started by `sudo` from the rule above, or by root.

The broker reads `SUDO_UID`, not the name, and maps it with `getent passwd`; it refuses when
`SUDO_UID` is missing (started some other way), when the uid is root's (root is not a caller), or
when the mapped user is not a member of the callers group. It then maps the user to an agent
identity (`agent-<identity>`, as `agent-linux-user` names them) for the policy's `callers=`.

What this does not cover, stated plainly: a process the caller started inherits nothing from the
broker, but a git hook the broker runs is a child of the broker and runs as `dcf-git`; that is why
hooks come only from a folder the account trusts (section 10.3).

## 9. The Operator's own user: direct, not brokered

The Operator's user (the remote user, which keeps `sudo` under `agent-linux-user` decision 5) is
not brokered. The shim compares the caller's uid with the remote user's uid recorded at build and,
when they match, runs the real tool directly as the Operator, with today's behaviour, logins and
identity, after one audit line marked `direct`. Reasons:

- The Operator's user can become root anyway; a policy in front of it protects nothing and would
  stop the Operator's own repairs, `git config` and rebases.
- The Operator's logins (`gh`, the ssh-agent socket, the cloud folder) are the Operator's own and
  must not cross into a service account.
- A `claude` the Operator starts in their own terminal is direct too; `agent-linux-user` section 8.6
  already makes it say so.

For a direct call to write the git dir that `dcf-git` owns, the Operator's user is a member of the
account's group (`operator_group=yes`), and the git dir is group-writable for that group only
(2770). Agent users are never members. On a container where agents still run as the Operator's
user (`runAs: remote-user`), every call is direct: `broker: on` then changes ownership and nothing
else, and the shared code says so in one line at start.

## 10. git, the first broker

### 10.1 What `dcf-git` owns

- **The checkout's own git dir** under `/git-dirs` (the one ADR-0020's mapping finds for the
  workspace), with its `config`, `hooks/`, `info/`, objects, refs, index and `worktrees/`. Owner
  `dcf-git`, group `dcf-git`, 2770 for folders, 660 or 640 for files.
- **The broker's hooks folder**, `/var/lib/devcontainer-features/git/broker/hooks/` (section 10.3).
- **The broker's git configuration**: `GIT_CONFIG_GLOBAL` for the broker is its own file in the
  image (root, 644), written at build from the git Feature's options (identity, `safe.directory`
  for the checkout and its git dir, the credential helper line). The Operator's global config in
  the git volume stays the Operator's and is used only by direct calls.
- **The credential for push** (section 12).

Not the other repositories under `/git-dirs`. Taking all of them would break every other
devcontainer that mounts the same folder with the broker off, since their remote user could no
longer write its own git dir. Other repositories' git dirs therefore stay as reachable as
ADR-0020 left them; closing that is ADR-0020's option 2 (mount only the repository's own git dir),
a separate item (decision 6).

### 10.2 The git-settings finding, closed

Agents have no write permission anywhere in the git dir, so neither `git config`, a rename over
`config`, nor a planted `config.worktree` is possible for them; the Operator's user can still write
it (trusted, section 9). The broker refuses to run when:

- `config`, `config.worktree`, `hooks/` or the git dir itself is not in group `dcf-git`, has an
  owner other than `dcf-git`, root or the Operator's user, or is writable by others (the trust
  check, step 3);
- the config holds an `include.path` or `includeIf` that points outside files the broker trusts.
  This repository's own `task repo:setup` writes `include.path ../.gitconfig`, a file in the
  checkout, which an agent can write; under the broker the values it carries (`core.hooksPath`,
  the `cs` alias) are set by the broker's own config instead and the include is refused (the
  `.gitconfig` header already says why git never reads a tracked config on its own);
- the config sets an executable setting the policy does not list: `core.fsmonitor`,
  `core.sshCommand`, `core.pager`, `core.editor`, `diff.external`, `*.textconv`, a filter driver,
  `credential.helper` other than the broker's own, an alias that starts with `!`.

The workstation side: files Windows git creates under `.git-dirs` show in the container as `root`
777 (agent-linux-user section 2). The first brokered call after such a write meets the trust check
and is refused with `task git:broker:repair`, which the Operator runs: it shows what changed in
`config` against the broker's last copy, then hands ownership back. So a Windows-side write can
make the broker stop, never make it run what an agent planted. Test U3.

### 10.3 Hooks

The ask is "hooks enforced": every brokered commit runs the repository's git hooks
(`pre-commit` runs `devhost-verify`, `prepare-commit-msg` adds the sign-off). But the hooks in the
checkout (`.githooks/`) are files any agent can write; run as `dcf-git`, an edited hook would be an
agent's code with the broker's rights, including its push credential.

So the broker never runs a hook from the work tree. Its `core.hooksPath` is a folder only it and
root can write, filled from **the base branch as committed** (`git show origin/main:.githooks/<hook>`,
read from objects, not from the work tree): content that reached `main` only through a pull request
the Operator merged. The Operator refreshes it with `task git:broker:hooks` (direct), and the
post-start hook refreshes it once per start. A hook may run only programs from the image; a hook
that runs code from the checkout (a `task` call, a script under the work tree) is refused by the
refusal test that plants one (decision 5). This repository's hooks pass: `pre-commit` runs
`devhost-verify` from the image, which reads but does not run checkout files.

`--no-verify` and `-n` on commit, `--no-verify` on push, and `core.hooksPath` from the caller are
refused everywhere.

### 10.4 The first allow-list

| Verb | Callers | Allowed | Refused (each a refusal test) |
|---|---|---|---|
| `status`, `diff`, `log`, `show`, `rev-parse`, `ls-files`, `merge-base`, `branch --list` | every agent | read flags by exact spelling; paths inside the checkout | `--output`, `--ext-diff`, `--textconv`, `--no-index` (reads any file as `dcf-git`), `--exec-path`, an abbreviated flag |
| `add`, `rm --cached`, `restore --staged` | every agent | paths inside the checkout | `--pathspec-from-file` outside the checkout, a path that leaves the checkout through `..` or a symlinked folder |
| `commit` | every agent | `-m`, `-F -` (standard input only), `--amend` of an unpushed commit, `--trailer` | `--no-verify`, `-n`, `-F <file>`, `-t`, `--template`, `--author`, `--date`, `--no-signoff`; a co-author trailer at `noreply@anthropic.com` (ADR-0002); a message read from an editor |
| `switch`, `switch -c`, `branch <new>` | every agent | names that follow the branch rule `<type>/<id>/<n>` | `-f`, `--force`, a name outside the rule, deleting the base branch |
| `fetch` | host | `origin` only | `--upload-pack`, `--recurse-submodules`, a URL as remote |
| `push` | host | `origin`, a branch that follows the branch rule, `-u`, `--force-with-lease` on that branch | the base branch in any refspec form (`main`, `HEAD:main`, `+x:refs/heads/main`), `--mirror`, `--all`, `--tags`, `--delete` of the base branch, `--force`, `--receive-pack`, `--exec`, `-o`, `--no-verify` |
| `worktree add`, `worktree remove` | host and cons | a path in the caller's area (U8) and `-b` with a rule-following name | `--force`, a path in another caller's area |
| everything else | nobody | | `config`, `-c`, `--config-env`, `--git-dir`, `--work-tree`, `--namespace`, aliases, `submodule`, `filter-branch`, `rebase --exec`, `gc --prune=now`, `update-ref`, `replace`, `notes`, `remote add` |

Enforced, whatever the caller passes: the bot identity (author, committer and sign-off from the
git Feature's `commitName` and `commitEmail`, as ADR-0016 does through `commitWhenEnv` today),
`commit -s`, `GIT_EDITOR=false` and `GIT_PAGER=cat` (no interactive program can start),
`--end-of-options` before refs the broker passes on. Merging to `main` stays the Operator's; there
is no verb for it.

### 10.5 Working-tree reads and writes by `dcf-git`

`add`, `status`, `diff` and `commit` read the work tree; `switch`, `restore` and `worktree add`
write it. `dcf-git` is a member of `dcf-work`, the checkout's group (agent-linux-user section 9),
so it reads what agents write (664, umask 002) and the files it writes are group `dcf-work` with
umask 002, so agents can edit them after. A file an agent made private (600) is refused by `add`
with a line naming it, never added half. The index, objects and refs are in the git dir, which only
`dcf-git` and the Operator's user write.

The work tree's `.git` pointer is ignored by the broker: it is a file in the checkout, so an agent
could point it at a folder of its own with a planted `config`. The broker passes `--git-dir` and
`--work-tree` from its own record, and a linked worktree is accepted only when its admin folder is
under the recorded git dir's `worktrees/`.

## 11. Later brokers

Each is a manifest, a policy and refusal tests on the same shared code; each its own slice, after
git. Sketches, not designs:

| Broker | Account owns | Allowed (first cut) | Refused, to start with | Credential, file mode / with OpenBao |
|---|---|---|---|---|
| gh | `GH_CONFIG_DIR`'s token (a GitHub App installation, or a narrow token) | `pr create --draft`, `pr view`, `pr list`, `pr checks`, `pr edit` of a draft, `pr ready` for the host (ADR-0053), `issue view`, `issue list`, `run view`, `run list`, `api` GETs on a listed set of endpoints | `auth token`, `auth status --show-token`, `pr merge`, `release`, `workflow run`, `secret`, `variable`, `repo delete`, `extension`, `alias`, `config set`, `api` with a write method, `--repo` outside the policy's repositories | a token file only `dcf-gh` reads / an installation token minted per call (section 12) |
| kube | the kubeconfig (`KUBECONFIG` of `kube-state`) | `get`, `describe`, `logs`, `events`, `diff`, `apply --dry-run=server` in listed namespaces and contexts; `velero` and `argocd` reads the same way | `exec`, `attach`, `cp`, `port-forward`, `proxy`, `auth can-i --as`, `--as`, `--token`, `--server`, `--kubeconfig`, `--context` outside the list, `get secret`, plugins | a kubeconfig only `dcf-kube` reads / a service-account token from OpenBao's Kubernetes secrets engine, per call |
| docker (the tester) | membership of the `docker` group, so the socket | one verb, `test <feature>`: the Feature tests of a **committed** ref (exported from objects, not the work tree) against the daemon | the socket itself, every other `docker` and `devcontainer` verb; scenarios from the work tree (they choose mounts and `--privileged`) | none |
| az | `AZURE_CONFIG_DIR`'s login | `account show`, `group list`, `resource list`, `deployment group what-if`, `bicep build` | `login`, `logout`, `account get-access-token`, `rest`, `--debug` (it prints tokens), `keyvault secret show`, `ad sp credential`, `role assignment create` | a service principal secret only `dcf-az` reads / a dynamic service principal from OpenBao's Azure secrets engine |
| the backs' hand-over (devhost, local) | the user `back-<name>` | one verb, `handover <back>`, the stretch on standard input | a job path, any caller but `agent-host` | the back's AppRole ids, as today |

Docker is the one where an argument allow-list does not help: `docker run` with a mount of `/` or
`--privileged` is root, and a test scenario in the work tree chooses both. The broker therefore
offers one verb that runs a committed tree, and even that is root for whatever the committed
scenarios ask; it is safe only as far as review of `main` is. Decision 11 recommends leaving docker
out of the first round (the tester keeps reporting "skipped", the tests run in CI and in the
Operator's terminal, as `agent-linux-user` decision 4 already says).

The backs' hand-over row is how finding 3 of that review closes: the devhost's `sudoers` rule
for the backs is written by the same shared code, names one program with no argument pattern,
and its policy accepts only `agent-host` as caller and only standard input as the stretch.

## 12. OpenBao

### 12.1 The option

The shared code takes `credentials: file|openbao` (an option on each Feature that opts in,
`brokerCredentials`, default `file`). A Feature declares in its manifest what each verb needs:

```
credential.push=github-token          # a logical name
credential.github-token.file=/var/lib/devcontainer-features/git/broker/credential/github-token
credential.github-token.openbao=dcf/brokers/git/github-token         # a KV path, or:
credential.github-token.openbao-mint=github-app:installation-token    # a minting step (12.3)
```

- **`file`**: the credential is a file in the Feature's volume, owned by the account, 600. The
  Operator puts it there once (`task <id>:broker:credential`, direct, value on standard input).
  It is at rest, but in one place per resource and readable by one account, not per agent.
- **`openbao`**: nothing at rest. On a verb that needs a credential, the broker logs in as its own
  AppRole inside its own process, reads or mints the credential, uses it for this call, and lets
  the token expire (5 minutes, as every role `openbao:approle:issue` makes). Verbs that need no
  credential (status, diff, log, add, commit) never call OpenBao, so most calls cost nothing extra.
- **Fail closed.** Sealed, unreachable, logged out or denied means refuse, with `dcf-secret`'s exit
  code and its one line naming the fix; the broker never falls back to the file. With `openbao`
  set, a credential file found in the volume is reported by `task <id>:broker:check` as a finding,
  and never read.

### 12.2 The broker's AppRole

- **The role and its policy.** The shared code writes, at build, a policy file per broker that
  reads only the paths the manifest declares (`dcf/data/brokers/git/*`, a signing or minting
  path), and a task `task <id>:broker:approle` that the Operator runs in a plain terminal. Creating
  a role and a policy needs a root token from the unseal shares (ADR-0050), so this task calls
  `openbao:approle:issue` with that policy file and asks for two shares, once per broker; a reissue
  later needs only the Operator's login (ADR-0050 decision 4).
- **The ids.** The role id and secret id go to the broker's own folder,
  `$OPENBAO_STATE_DIR/brokers/<name>/`, owned by the account, 700, as the backs' ids are today but
  owned by the broker, not the Operator. The secret id is at rest, bound to `127.0.0.1/32` and
  useful only while the server is unsealed; that is the same exposure the backs' identities have.
  A later step can shorten it: the Operator's renewer reissues each broker's secret id at every
  unlock with a lifetime of the sitting (ADR-0050 decision 1 allows that), so a stopped container
  leaves nothing usable.
- **The login inside the process**, through `DCF_SECRET_AS=<role>`: the interface `dcf-secret`
  reserves today ("not supported in this version", exit 2) and that `openbao-agent-login` delivers.
  A broker is its first consumer in this collection.

### 12.3 Where OpenBao adds dynamic credentials

| Resource | OpenBao part | What the broker gets per call | What has to change first |
|---|---|---|---|
| git over SSH | the SSH certificate authority of pull request 184 (`ssh-ca`) | a certificate for a key made in the broker's process, for one fixed principal, minutes long | ADR-0058 decision 1 says only the Operator signs and agents are read-only. A broker is not an agent, but it does sign: a new ADR amends decision 1 with a role `broker-git` that only the `broker-git` AppRole may use, exact principal (server-enforced, decision 11 of ADR-0058), a lifetime of at most 10 minutes, no extensions, and decision 8 (no `operator` principal) kept. Also: github.com trusts an SSH CA only for organisations on GitHub Enterprise Cloud (U11), so this fits a self-hosted forge or such an organisation, not a personal account |
| git and gh over HTTPS | KV holds a GitHub App's private key; or a GitHub secrets plugin keeps it inside OpenBao | an installation token, at most an hour, narrowed at mint time to the policy's repositories and permissions (contents, pull requests) | none for the KV route (the key crosses the broker's memory only); the plugin route needs a pinned, verified plugin (NFR-3) registered with a root token (U12) |
| kube | the Kubernetes secrets engine | a service-account token for a role bound to the listed namespaces, minutes long | the engine's role per cluster, made by the cluster's owner |
| az | the Azure secrets engine | a dynamic service principal, or a rotated secret of an existing one | the new principal's propagation delay (tens of seconds, U13) may need the lease cached for its lifetime in the broker's memory-backed folder |
| any | the audit device (`audit.log`, already on in server mode) | every login and read under the broker's role name | correlating an OpenBao entry with the broker's own line is by role and time; a request id carried across is U14 |

### 12.4 Two checks, and how this relates to `openbao-agent-login`

The broker's policy decides what a verb may do; OpenBao's policy decides which broker gets which
credential. They are written in different places (the image; OpenBao, by the Operator with shares)
and checked by different programs, so neither can widen the other (section 4.3).

`openbao-agent-login` gives a tool running inside an agent session its own narrow AppRole, fetched
in that tool's own process (the office's board tool reading its GitHub App key). It and the broker
use the same login (`DCF_SECRET_AS`), built once. They differ in who sees the credential: with
`openbao-agent-login` the agent's process holds it for the call; with a broker, only the account's
process does, and the agent sees the result of an allowed verb. So `openbao-agent-login` comes
first and stays for tools that have no broker; a broker is the step up when the resource deserves a
verb list. Under agent users, the agent's own role ids sit in its own folder (agent-linux-user
section 7); a broker's sit in the account's.

## 13. An optional MCP front door

A broker can also be offered as an MCP server: one tool per verb (`git_status`, `git_commit` with
`message` and `paths`), with typed inputs generated from the same policy file. The server calls the
shim, so the policy check runs exactly once, in the broker; the server adds types and descriptions,
never a rule. It helps a CLI that prefers tools over shell commands; it is no stronger, since the
shim stays reachable.

The collection decided "MCP: none for now; revisit per tool when an agent shows friction a task
cannot fix" (2026-10-19). A front door needs an ADR against that line, with that friction as its
evidence. NFR-12 is met (MCP servers work with Claude Code, the Copilot CLI and others); NFR-13 is
met as long as the server is generated and adds no concept. Decision 12 recommends not building it
in the first round.

## 14. Performance: `sudo` per call

Every brokered call pays one `sudo`: reading `sudoers`, a PAM session, a fork and exec. Typically
a few milliseconds to a few tens of milliseconds; git calls are many (Claude Code calls `git status`
and `git log` itself, and a commit sequence is five or six calls). Brokered calls that need a
credential with `openbao` add a loopback AppRole login and a read.

- **Budget**: at most 25 ms added per call at the median, measured (U1); the git wrapper's own
  cost today is 0.1 to 0.3 ms (ADR-0020).
- **Cheap levers** inside `sudo`: `Defaults!<broker> !use_pty`, no `sudo` I/O logging, `!pam_session`
  if the PAM stack is the cost.
- **If the budget is missed**: a broker daemon per account on a Unix socket, which learns the caller
  from the kernel (`SO_PEERCRED`), even firmer than `SUDO_UID`, and pays no `sudo` per call. It
  costs a process to supervise per broker and a protocol to pass arguments and file descriptors.
  It is the fallback, not the start (decision 14).

## 15. The requirements

- **NFR-1** owns-its-state: met; the audit log, the credential in file mode, the hooks folder and the
  role ids are in the Feature's volume.
- **NFR-2** registered-taskfile: met if the new tasks (`<id>:broker:check`, `:broker:repair`,
  `:broker:hooks`, `:broker:credential`, `:broker:approle`) have a `desc`.
- **NFR-3** verified-and-pinned: met; nothing is downloaded but `sudo` from the distribution where
  absent (as git's apt fallback, an existing exception), and the GitHub plugin only if chosen.
- **NFR-4** augments-not-replaces: met; the real tool stays the official one, the shim is the
  existing wrapper.
- **NFR-5** idempotent-and-user-neutral: met in intent; the account is a system account with a
  fixed uid, the remote user comes from `_REMOTE_USER`, a re-run finds everything in place.
- **NFR-6** one-way-to-configure: a **written exception**. The options and their `containerEnv`
  overrides work at build, but the exported environment of the caller is never read at run time,
  since the caller is who the broker guards against. Each Feature's NOTES says so.
- **NFR-7** agent-ready: met; refusals are one line and exit 3; the Operator's tasks that ask for
  shares are `interactive: true`.
- **NFR-8** documented-to-the-standard: each opting Feature's NOTES gains a "Broker" section (what it
  owns, the verbs, the refusals, how to turn it off).
- **NFR-10** tested-on-base-images: the refusal harness runs in each Feature's container tests on
  the three images; `debian:latest` has no `sudo`, so the install step installs it (U5).
- **NFR-11** linter-cli-contract: `<id>:broker:check` prints one `<file>: <rule>` line per finding,
  `--format json`, exits 0, 1 or 2.
- **NFR-12** vendor-neutral-contracts: met; a shim on PATH works for every CLI, and the shared
  code knows no agent CLI.
- **NFR-13** manages-the-environment-not-the-cli: met; the broker restricts which of the tool's own
  verbs run and with what credential, and re-implements none of them. Using git's own
  `--end-of-options`, OpenBao's own engines and `sudo`'s own environment reset is this rule
  applied.

## 16. What a consumer changes, and what breaks

**Opt-in first.** Every Feature change is inert until a consumer sets `broker: on` on that
Feature; every slice up to the flip is a minor.

To turn the git broker on:

1. Run agents as their own users (`agents` option `runAs: agent-user`, from `agent-linux-user`).
   Without it, `broker: on` changes ownership only (section 9).
2. Set `"broker": "on"` on the git Feature and rebuild. The post-create hook hands the checkout's
   git dir to `dcf-git` and adds the Operator's user to its group.
3. Give the broker its push credential: `task git:broker:credential` (file mode) or
   `task git:broker:approle` and the secret in OpenBao (`openbao` mode).
4. Drop the repository's own `include.path` to a tracked file (`task repo:setup` here) and move its
   values into the git Feature's options; fill the hooks folder with `task git:broker:hooks`.
5. Run `task git:broker:check` and read it.

**The office**: its board tool needs `openbao-agent-login` first; its git and gh brokers follow
the same steps. **DSNP**: check which agent tasks run `git config`, `push` to `main`, or use the
`docker` group (agent-linux-user U12); those move to the Operator's terminal or CI.

**What breaks, and so needs a major**, when the default becomes `on` (in the same majors as
`runAs: agent-user`, agents 3.0.0):

| Change | Why it breaks | Version |
|---|---|---|
| The git dir is owned by `dcf-git` | an agent's `git config`, `--no-verify`, a push to `main` and any verb not listed stop working | git 2.0.0 |
| Hooks come from the base branch | a hook changed on a topic branch does not run until it is merged | git 2.0.0 |
| `include.path` to a tracked file is refused | repositories that rely on it lose those settings until moved into options | git 2.0.0 |
| `gh`'s login belongs to `dcf-gh` | an agent's `gh auth token`, `gh api` writes and `pr merge` stop | gh 2.0.0 |
| Turning the broker off again | the git dir stays owned by uid 19901 until `git-setup` hands it back, which it does when `broker: off` meets a git dir owned by the broker's uid | minor, with the test |

## 17. Slices, in delivery order

Each with its version bump, CHANGELOG entry and `task docs`; the host commits, pushes and opens
them; the Operator merges and releases.

0. **Records** (with the ruling): an ADR "a broker owns each shared resource", the terms of
   section 3 in the lexicon, the reserved uid range in `src/common`'s NOTES.
1. **common minor: the shared code and the harness.** `dcf-broker-install.sh`, `dcf-broker.sh`,
   `dcf-broker-test.sh`, with a test-only broker (`dcf-echo`, one verb) in `test/common/`, red for
   a planted fault and green as built. No Feature uses it yet.
2. **git minor: the git broker, file mode.** `broker` and `brokerCredentials` options, the
   manifest, the policy of 10.4, the trust check, the hooks folder, the repair task; the refusal
   tests of 10.4 and every config setting of 10.2. Needs `agent-linux-user` slice 2 for real agent
   users; the tests make their own.
3. **devhost (local): the backs' hand-over** on the shared code (finding 3), with `agent-linux-user`
   slice 6.
4. **openbao minor and `openbao-agent-login`**: `DCF_SECRET_AS`; `approle:issue` with a policy file;
   then common's `credentials: openbao`, and git's push with a GitHub App installation token
   minted per call.
5. **gh minor: the gh broker.**
6. **kube-state and az minors**, each when a consumer asks; the SSH certificate route for git after
   its ADR amending ADR-0058.
7. **Optional: the MCP front door**, after its ADR.
8. **The flip**: git 2.0.0 and gh 2.0.0 with agents 3.0.0.

Model sizing: slices 1, 2, 4 and 8 reach every consumer and carry the boundary: the strongest model.
Slices 0, 3, 5 and 6: Sonnet, with the strongest model for the refusal list review of each.

## 18. Unknowns, each as a test

| # | Unknown | The test |
|---|---|---|
| U1 | What one `sudo` costs per call here, and with `!use_pty` and `!pam_session` | 1,000 runs of `git status` through the shim and directly, on wslc and docker, median and 95th percentile |
| U2 | Can a caller change what the broker sees as `SUDO_UID` or its environment | as an agent user: export `SUDO_UID=0`, `GIT_CONFIG_PARAMETERS`, `GIT_DIR`, `LD_PRELOAD`; `sudo -E`, `sudo VAR=x`; the broker prints what it received |
| U3 | Do ownership and modes set in the container on `/git-dirs` hold, and what do Windows git's writes look like after | `chown` and `chmod` the git dir, restart, then commit, fetch and `gc` from Windows git; `stat` and the trust check after each |
| U4 | Is the refusal list complete for git's options | for each allowed verb, `git <verb> --git-completion-helper-all` lists every option; each one not in the policy must be refused, also abbreviated |
| U5 | Does the install step work where `sudo` is absent (`debian:latest`), and as a non-root `remoteUser` | the container tests on the three images with `broker: on` |
| U6 | Does Claude Code call git by PATH (so through the shim), and does it cope with a refusal | run a session as an agent user with the broker on; list its git calls in the audit log; check nothing calls `/usr/bin/git` directly |
| U7 | Do hooks from the base branch behave like today's (the sign-off, `devhost-verify`) | commit through the broker in this repository; a refusal test with a planted hook calling `task` |
| U8 | Where a con's worktree can live, since `/tmp/claude-<uid>/` is 700 and `dcf-git` cannot write it | `worktree add` into a caller-owned folder with group `dcf-work` and setgid, and into a broker-owned area per caller |
| U9 | Does Windows git still work on a git dir whose Linux owner is `dcf-git` | `git status`, commit and push from Windows on the same repository |
| U10 | Do `git push` and `fetch` through the broker keep progress output and the caller's exit codes | push a branch from the host; a failing push returns git's own code |
| U11 | Does the forge trust an SSH CA for this account type | GitHub: an organisation without Enterprise Cloud refuses a CA; a self-hosted forge accepts the certificate |
| U12 | Is a GitHub secrets plugin available for OpenBao 2.x, pinned and verified | find, pin, register in a throwaway server; mint a token |
| U13 | How long a dynamic Azure service principal takes to work | mint one, time the first successful `az` call |
| U14 | Can a broker's call be matched to its OpenBao audit entry by more than time | pass a request id as metadata; look for it in `audit.log` |

## 19. Decisions for the Operator

1. **Decide this with `agent-linux-user`**, letting the git broker replace that proposal's group-
   writable git dir (its section 9, git half) and its backs' rule (8.3). *Recommendation: yes.*
2. **The `sudoers` rule names the broker program with no argument pattern**, and the policy judges
   the arguments; the stricter form (no arguments allowed, the argument vector on a file
   descriptor) costs `closefrom` exceptions and gains nothing the policy does not check.
   *Recommendation: no argument pattern.*
3. **Callers**: every agent and back user (group `dcf-work`) may call every broker, and the policy
   narrows verbs by caller (`push` for the host only). *Recommendation: yes.*
4. **The Operator's user is direct**: not brokered, a member of each account's group, one audit
   line per call. *Recommendation: yes.*
5. **Hooks only from the base branch as committed**, into a folder the broker owns, refreshed at
   start and by `task git:broker:hooks`; a hook may run only programs from the image; an
   `include.path` into the checkout is refused. *Recommendation: yes.*
6. **The git broker owns only the checkout's own git dir**; narrowing the other repositories under
   `/git-dirs` goes with ADR-0020's option 2 as its own backlog item. *Recommendation: yes.*
7. **Fixed uids per broker** from a reserved range (19900 to 19999) listed in `src/common`'s NOTES,
   overridable per Feature for an image that uses them; fixed because `/git-dirs` is shared by
   every container on the workstation. *Recommendation: yes.*
8. **Push enforces the branch rule** (`<type>/<id>/<n>`) besides refusing the base branch, force
   without lease, deletes, tags and mirrors. *Recommendation: yes; it costs one pattern and catches
   the `feat/` mistake.*
9. **With `credentials: openbao`, one login per call that needs a credential**, no token cached
   between calls. *Recommendation: yes; revisit if U1 with OpenBao misses the budget.*
10. **GitHub through a GitHub App installation token** minted in the broker's process from the App
    key in OpenBao; SSH certificates only where the forge trusts a CA, after an ADR amending ADR-0058
    decision 1 for a broker role. *Recommendation: yes.*
11. **No docker broker in the first round**; the tester keeps reporting "skipped" and the tests run in
    CI and the Operator's terminal. *Recommendation: yes.*
12. **No MCP front door in the first round**; an ADR when an agent shows friction the shim cannot fix.
    *Recommendation: yes.*
13. **The audit log** in each Feature's volume, owned by the account, readable by the Operator's user,
    no argument values, capped. *Recommendation: yes.*
14. **`sudo` per call first**, a daemon with `SO_PEERCRED` only if U1 misses 25 ms at the median.
    *Recommendation: yes.*

## 20. For the repository (found while writing)

- **Two ADRs are numbered 0058 on two branches**: `docs/adr/0058-an-openbao-ssh-*` on
  `feature/openbao-ssh-ca/1` and the audio gate's ADR-0058 on the audio branch. Whichever merges
  second needs renumbering.
- **"Gate" is taken twice**: the lexicon's "The gate" (OpenBao's unseal and login) and the audio
  branch's "Audio gate". The broker backlog items say "gate"; this proposal says policy or
  allow-list, and the backlog items could be reworded to match.
- **`task repo:setup` turns on a tracked config file** (`include.path ../.gitconfig`). Its own header
  explains why git never does that on its own; with agents able to write the checkout it is an
  injection path for `core.fsmonitor` and hooks today, broker or not. Worth a backlog item: set the
  two values directly (the task already does for the git-dirs case) and drop the include.
- **`core.hooksPath=.githooks` runs hooks from the work tree** for every git call in the devhost
  today, so any agent edit to `.githooks/` runs at the next commit as whoever commits; that includes
  the Operator's own commits.
- **The git wrapper honours a `.git` pointer outside `.git-dirs`** ("a pointer that works ... is left
  alone"): fine for a person, but a broker must never follow it (section 10.5).
- **`dcf-secret` reserves `DCF_SECRET_AS`** and refuses it; `openbao-agent-login` and the brokers
  both need it, so it is one item serving two.
