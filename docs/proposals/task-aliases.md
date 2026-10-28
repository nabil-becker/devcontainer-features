# Proposal: the go-task Feature makes aliases easy to specify

Status: draft, for the Operator to confirm. The shape in section 1 was decided by the Operator on 2026-10-28; the rest is this draft's reading of it. Nothing here is built.

Who this serves: every engineer, who wants the team's words (the lexicon, or a theme) as task names, and the Operator, who wants their own shortcuts, without hand-wiring includes in each repository.

## 1. Decided (2026-10-28)

- An alias points at an existing task. It may carry fixed variables (`{ task: timesheet:week, vars: { PERSON: me } }`); it takes no free command-line arguments.
- Two layers: a **team file** committed in the consuming repository, and a **personal file** never committed, kept for now in the go-task Feature's own named volume.
- `task-features-registry` (with its generator) writes one small wrapper task per alias, so each shows in `task --list`.
- Personal wins over team on a clash, with a warning. An alias that shadows a real task is refused. An alias whose target does not exist is reported as broken, never failing a build or a start.
- Regenerated at container start and by `task go-task:aliases`, not only at image build.
- Also decided by the Operator (2026-10-28, from section 12): the team file holds plain lexicon words and theme words stay personal (ADR 0004); `yq` is the parser (pinned, verified); `taskAliases` is off by default; an alias that points at another alias is refused; aliases are supported with the flattened `features` include (unflattened, they appear under its namespace, and NOTES says so).

## 2. The picture

```
 repo (committed)                      volume go-task-<id> (never committed)
 .devcontainer/task-aliases.yml        /var/lib/devcontainer-features/go-task/task-aliases.yml
   team layer: lexicon words             personal layer: my shortcuts
              \                         /       (later: a host folder bind-mounted over it)
               v                       v
        task-aliases generate   <- postStartCommand, and `task go-task:aliases`
          | 1. read both files, check names and targets
          |    against `task --list-all --json` of the repo's root Taskfile
          | 2. personal wins a clash (warning); shadowing a real task is refused;
          |    a missing target is reported, no wrapper made
          v
   /var/lib/devcontainer-features/go-task/aliases.yml   (generated, one wrapper per alias)
          ^ included once, optional, flatten, by features.yml (written at image build)
          |
 root Taskfile: includes: features: {taskfile: .../features.yml, optional, flatten}   (already there)
          v
 task --list  ->  ts  "alias for timesheet:week"
```

The repository adds nothing to its root Taskfile: the `features` include it already has carries the aliases. This is why the generated file lives in the volume (writable by the user at start) and `features.yml` (root-owned, built at image build) only gets one static include line for it.

## 3. The file format

One format for both layers:

```yaml
# .devcontainer/task-aliases.yml (team). Words from LEXICON.md.
aliases:
  briefing: devhost:briefing            # short form: the target task
  cost-report:                          # long form
    task: devhost:report
    desc: The month's agent spend       # optional; default "alias for devhost:report"
```

```yaml
# personal task-aliases.yml (volume). Fixed variables allowed, free arguments not.
aliases:
  ts:
    task: timesheet:week
    vars: { PERSON: me }
  tab:                                  # a theme word (the bar layer); personal, see section 9
    task: devhost:costs
```

Rules, checked by the generator (a violation drops that alias and is reported; the rest still work):

| Field | Rule |
|---|---|
| name | matches `^[a-z][a-z0-9_-]*(:[a-z][a-z0-9_-]*)*$`. Colons allowed (namespaced words such as `bar:tab`; the registry already has `registry:refresh`). |
| `task` | required; must be a real task (not another alias); same character set |
| `vars` | optional map of name to a plain string, number or boolean. A value containing `{{`, or a map (`sh:`, `ref:`), is rejected: templates and shell variables are code |
| `desc` | optional single line, emitted quoted |
| any other key | rejected (no `cmds`, `deps`, `dir`, `env`, `preconditions`) |

## 4. Generation: what is emitted

One wrapper per accepted alias, in the generated file (version `'3'`, header "Generated, do not edit"):

```yaml
tasks:
  ts:
    desc: 'alias for timesheet:week'
    dir: '{{.USER_WORKING_DIR}}'        # taskfiles:check rule; the target sets its own dir anyway
    cmds:
      - task: timesheet:week
        vars: { PERSON: 'me' }
```

Naming: **not namespaced**. The aliases file is included by `features.yml` with `flatten: true`, so the wrapper is `ts`, not `features:ts` or `go-task:ts`; that is the point of an alias. If the repository does not flatten the `features` include, the alias appears under that namespace; NOTES says flatten is the supported setup.

Values are written as single-quoted YAML scalars by the generator, never interpolated unquoted, so a value cannot break out of its string.

## 5. Options on the go-task Feature (defaults)

| Option | Default | Meaning |
|---|---|---|
| `taskAliases` | `false` | opt in. Installs the generator and `yq` (pinned, sha256-verified like `task`; one more download, so off by default), the volume mount and the post-start hook |
| `teamAliasesFile` | `.devcontainer/task-aliases.yml` | workspace-relative path of the team file; absent file means no team layer |
| `personalAliasesFile` | `/var/lib/devcontainer-features/go-task/task-aliases.yml` | the personal file; absent means no personal layer |
| `yqVersion` | pinned | the `yq` release; `latest` says what it resolves to (NFR-3) |

Also plain variables `GO_TASK_*` (NFR-6). A repository opts in with one line, `"ghcr.io/nabil-becker/devcontainer-features/go-task:1": { "taskAliases": true }`, and commits the team file. The Feature adds the named volume `go-task-${devcontainerId}` at `/var/lib/devcontainer-features/go-task` (NFR-1), set up with a verbatim copy of `dcf-persist` (the collection's pattern, `src/common/NOTES.md`; `task lint` checks the copy).

## 6. Conflicts and errors

Never fatal: the generator always exits 0 at start, prints a report, and always writes a valid generated file (empty `tasks: {}` at worst).

| Situation | Result |
|---|---|
| Same name in both files | personal wins; warning names both files |
| Name equals a real task (from `task --list-all --json`, ignoring wrappers the generator made itself) | alias refused, listed as `shadows` |
| Name equals a Task `aliases:` entry of a real task, or an include alias such as `dc` (see section 7) | refused, listed as `shadows` |
| Target does not exist (a Feature removed, a typo) | no wrapper; listed as `broken`; fixed by editing the file or rebuilding |
| Target is another alias | refused: aliases point at real tasks only |
| Bad name, unknown key, templated var, unreadable YAML | that alias (or that file) skipped and reported; the other layer still loads |

Reporting: `task go-task:aliases` prints the table (alias, target, layer, status: ok, overridden, shadows, broken, invalid) and, with `--json`, the same for agents (NFR-7); `task go-task:registered` appends a line "aliases: N ok, M broken" and points to it. The report is also kept in the volume (`aliases.report`) so a start-time warning can be re-read.

## 7. Interaction with Task itself (Task 3.54)

Checked against the installed binary's behaviour only in outline; every row marked "test" is verified by a test in slice 1 before the design relies on it.

| Question | Expectation | Handled by |
|---|---|---|
| Two included Taskfiles with `flatten: true` defining the same task name | Task fails the whole run ("found multiple tasks ... included by ...") | The generator checks first and refuses the clash; this is why shadowing must be refused, not merely warned (test) |
| Task's own `aliases:` on a task, or on an include (`aliases: [dc]` in the root Taskfile) | An alias is another lookup key for a task, separate from tasks; a wrapper named like an existing alias is ambiguous | Names already taken by a task alias are read from the JSON listing (`aliases` field); include aliases are read from the root Taskfile's `includes:` with `yq`; both refused (test: wrapper named `dc:up`) |
| Nested flatten: `features.yml` is flattened into the root and itself flattens the aliases file | Expected to work (flatten applies per include); tasks come out as plain names | test with the real root Taskfile of this repository |
| `task <alias>` runs the wrapper, which calls the target through `task:` | Normal task call; the target's `deps`, `preconditions` and `dir` apply; `vars` passed to a task call override the target's defaults | test |
| `task --list` shows wrappers | They have a `desc`, so yes | test |

An alternative the Operator excluded implicitly: using Task's `aliases:` field on the target task. That cannot be done from outside (the target's Taskfile is not ours, and the personal layer has no Taskfile to edit), and it cannot carry variables; hence wrappers.

## 8. Security

A personal alias file is something the user wrote and the container runs, so it is held to "calls existing tasks, nothing else": the format has no command field; `vars` accept only plain scalars (no `{{`, no `sh:`); every emitted value is a quoted scalar; names and targets match a fixed pattern; the generator never evals or sources a file. The team file is committed code from the repository and gets the same checks. The generated file is regenerated, never hand-edited, and a shell in the container can already run anything, so the aim is that the alias layer adds no new way to run code, not that it sandboxes the user. The volume and file are owner-only (mode 600 / 700).

## 9. Fit with personalization and the themes

- **Personalization** (draft, open): a personal alias file is a preference by its own test (it binds one person, never committed). It is the first preference with a mechanism; if the personalization proposal is accepted, its workstation-folder idea (option E) is exactly the "personalization folder on the host" below.
- **Host folder, later:** the launcher bind-mounts the workstation file's folder over `/var/lib/devcontainer-features/go-task` (the override pattern in `src/common/NOTES.md`: the last mount on a target wins), or, to keep the volume's other content, mounts one file read-only at a second fixed path that the generator reads as a third layer, ranked above the volume's file. No generator change beyond reading one more path; `personalAliasesFile` already names the path. A launcher variable `DCF_HOST_TASK_ALIASES` would follow the `DCF_HOST_*` pattern (ADR 0024).
- **Themes** change no id, path or command, and no committed output speaks in them (ADR 0004; the bar layer). A committed team file full of bar words would break that for this repository. So here the team file carries the lexicon's plain words (if it carries any) and a theme's words live in a personal file; a consumer with its own theme is free to commit its theme's words in its own team file, and the Feature does not care. Decision for the Operator, section 12.

## 10. Tests

All in a test scenario of the go-task Feature (`taskAliases: true`) plus unit tests of the generator (it takes the paths as arguments, so no container is needed, runs in `task lint` anywhere):

1. The format: short and long form, vars, desc default, every rejected case in section 3.
2. Generation: golden output for a fixture; quoting survives `'`, `:` and `#` in values; output is valid for `task --list`.
3. Conflicts: personal over team with a warning; shadowing a real task, a task alias and an include alias (`dc`) refused; a missing target is `broken` with no wrapper; alias to alias refused; one bad file does not stop the other layer.
4. Never fatal: bad YAML, missing Taskfile, missing `yq` all leave exit 0 and a valid empty file.
5. Integration (scenario): the generated file reaches `task --list` through `features.yml` with `flatten`; `task ts` calls the target with its fixed vars; `go-task:aliases --json`; regeneration after the personal file changes without a rebuild.
6. Hook: `postStartCommand` runs, is idempotent, and does not slow a start (timed; budget a second).
7. `task-features-registry` still passes its existing tests: with `taskAliases` off, `features.yml` is byte-identical to today's.

## 11. Slices and version bumps

Smallest first. Each is its own change with `task docs`.

| Slice | Content | go-task version |
|---|---|---|
| 1 | The generator (`task-aliases`, a bash script over `yq`), the format, the checks, `go-task:aliases` (generate and report), the static optional include in `features.yml` (only when `taskAliases` is on), `yq` install, the options `taskAliases` and `teamAliasesFile`, NOTES; team layer only, run by hand; unit and integration tests; the Task-semantics tests of section 7 | 1.1.2 to 1.2.0 (new option, new task) |
| 2 | The volume and `dcf-persist`, `personalAliasesFile`, the personal layer and the clash rules, `postStartCommand` | 1.3.0 |
| 3 | `--json`, the "aliases: N ok, M broken" line in `go-task:registered`, the report file | 1.3.1 |
| 4 | The host folder: launcher variable, bind mount, third layer (this repository's devcontainer-cli Feature and bootstrap; with the personalization decision) | 1.4.0, and devcontainer-cli |

Then the consumers adopt: the office and DSNP pin the new go-task, add the option and (optionally) a team file. A release is due after slice 2; the Operator starts it.

## 12. Open questions

Items 1 to 3 were decided on 2026-10-28 (section 1). Items 4 to 8 are settled while building slice 1 (4, 5) or slice 2 (6 to 8).

1. **Theme words in a committed team file** (section 9): plain words only in the team file, theme words personal? Recommended yes.
2. **Parser:** a YAML reader is needed and the base images have none. Recommended: `yq` (one pinned, verified Go binary, as `task` is), which also reads `task --list-all --json`. Alternatives: python3 (not on every base image) or a restricted line format (fragile). This is why `taskAliases` is off by default.
3. **Default for `taskAliases`:** off (recommended, because of the extra download) or on.
4. **Finding the workspace and the root Taskfile at start:** the post-start hook runs in the workspace folder; to confirm it is also the folder of the root Taskfile in both consumers (the office, DSNP).
5. **Include aliases:** whether Task's JSON listing exposes them; if not, the generator reads the root Taskfile's `includes:` itself (section 7); also what Task does when a wrapper has the same name as an include alias (the slice 1 tests answer this).
6. **Warnings at start:** where they show (the post-start log is easy to miss); candidate: also one line in the next `task --list`'s generated header, or the devhost briefing. Left to slice 3.
7. **Descriptions:** `desc` default is "alias for <target>"; with fixed variables, show them ("alias for timesheet:week PERSON=me")? Recommended yes.
8. **Layers of the host's own tasks:** this repository's devhost aliases (for example the lexicon's words) would be this repository's own team file; whether it commits one is a separate backlog item once slice 1 lands.
