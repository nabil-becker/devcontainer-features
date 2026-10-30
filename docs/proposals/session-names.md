# Proposal: session names you can tell apart

Status: Decided 2026-10-30 by the Operator (see section 'Decided'). Build not started.

Who this serves: the Operator, and anyone who runs several agents, often several named `host`, across machines and cannot tell their sessions apart in Claude Code's remote view; a consumer's maintainer gets the same, set once in the repository.

## 1. The ask, and the decided parts

The Operator (2026-10-29): sessions started through the agents CLI all show their bare handle (`host`) in the remote view; with four or five `host` sessions across machines nobody can tell them apart. Wanted: a template for the session's display name (machine name plus handle, for example), set once, optionally per agent; dynamic names are fine for ephemeral agents; take on little domain: use each CLI's own naming, do not recreate the CLI.

The Operator ruled on 2026-10-30 (next section). The design sections below carry the ruling; where they depart from the host's first sketch, section 12 says so.

## Decided (2026-10-30)

Accepted as proposed, with these changes and answers:

- **Finding 2 (copies after template changes):** the Claude adapter finds the agent's session by its record, then by the rendered name, the recorded (previous) name, any name the record has ever held for that handle and folder, or the bare handle; a bare wake accepts the saved name when it is any of those. Never a second session because the template changed.
- **Finding 4 (leaking env):** the agents Feature sets `AGENT_SESSION_NAME` explicitly on every call to a CLI adapter (start-bg, new, resume, wake, attach, stop, list, logs, ...): the rendered name where it applies, unset or empty where it does not.
- **Finding 5:** no capability in the `supports` verb list. A CLI that cannot name sessions ignores `AGENT_SESSION_NAME` (the NFR-12 fallback); `agents check` says which adapters use it only if it can tell without a new verb.
- **Finding 6:** "Session name" becomes a lexicon term (the librarian adds it after merge; the slices do not edit `LEXICON.md`).
- **Finding 7:** existing consumers add `"DCF_HOST_MACHINE": "${localEnv:DCF_HOST_MACHINE}"` to their `containerEnv`; the launcher prints a hint when it is missing, as it does for the FUSE slots; until then `{machine}` renders `container`.
- **Finding 8:** the length limit gets a source: Claude Code's own limit if documented, else a limit stated as this repository's choice with the reason; over-length is refused, never cut.
- **`{run}` is deferred** (not in these slices): ephemeral find-again first.
- **`{user}` is dropped** for now.
- **Open questions answered** (section 13): default stays `{handle}`; this repository uses `{machine} {handle}`, set in `.devcontainer/devcontainer.json` in the agents slice; `{machine}` unset renders `container`; over-length is refused; the separator is free text; CLIs that can only rename after the fact are ignored until they have a start flag; no rename verb, a changed template applies at the agent's next start.
- **Slices and versions:** devcontainer-cli 1.16.2, claude-code 1.9.0, agents 2.1.0; the agents-v2 roadmap shifts one minor (integrations 2.2, ephemeral runs 2.3).

## 2. Where the question sits

The **handle** (the agent's `name` in the list) stays the address: it keys the lease, the **carrier** record, `agents list`, every verb. The **session name** is a label the CLI shows. Today the agents Feature hands the handle to the **CLI adapter** as `<verb> <name> <folder>`, and the Claude adapter uses it twice: as `--name` and as part of how it finds the agent's session again (name and folder, plus its own record). That second use is the trap: a label that changes between starts would orphan the session and break the bare wake, which compares Claude Code's saved options with `--name <name> <args>`.

```
 list (repo)                 Feature option / env                launcher (workstation)
  - name: host                AGENTS_SESSION_NAME                 DCF_HOST_MACHINE=<COMPUTERNAME>
    session-name: "..."       default "{handle}"                        |  containerEnv
          \                          |                                  v
           v                         v                          DCF_HOST_MACHINE in the container
        agents: render ONE time per start  <---------------------------/
          |  handle=host repo=<folder> machine=<m>
          |  check: characters, length, no clash
          v
   rendered name  --- env AGENT_SESSION_NAME ---> agent-adapter-<cli> <verb> <handle> <folder>
                                                        |  claude: --name   copilot: -n
                                                        |  a CLI that cannot name: ignored
                                                        v
                                              the CLI's own list / remote view shows the name
   unchanged: lease, carrier record, `agents list` rows are keyed by the HANDLE
```

## 3. The format

An agents Feature option and an optional per-agent key, both a template string:

```yaml
agents:
  - name: host
    cli: claude
    session-name: "{machine} {handle}"      # optional; wins over the option
  - name: reviewer
    cli: claude
    lifecycle: ephemeral
```

- **Option** `sessionName` on the agents Feature, written to the Feature's settings like `AGENTS_FILE` (NFR-6: task variable, root `.env`, `.devcontainer/.env`, environment, default); default `{handle}`, today's behaviour exactly.
- **Key** `session-name:` in the list: flat, one scalar, so the awk reader stays. A value that starts with `{` must be quoted (the reader refuses an entry written as `{ }`; the quoted form is tested). Precedence: the agent's key, then the option, then `{handle}`.
- **Variables** (the closed set; anything else in braces is a list-check error):

| Variable | Value | Source |
|---|---|---|
| `{handle}` | the agent's name | the list |
| `{repo}` | the repository's folder name (the basename of the workspace root the list is in) | the container |
| `{machine}` | the workstation's name | `DCF_HOST_MACHINE`, set by the launcher |

`{run}` is deferred until ephemeral runs can be found again; `{user}` is dropped (Decided).

## 4. Where rendering happens

The agents Feature renders, once per start, and hands the adapter the finished string in the environment variable `AGENT_SESSION_NAME` (a name for the adapter to use, not a template). Reasons:

- The variables are environment facts that do not depend on the CLI; one renderer means one set of tests and every CLI gets the same name from the same list (NFR-12). Rendering in each adapter would repeat the template parser, the character rules per CLI.
- NFR-13: the Feature manages the environment (who, where, which run); the adapter only maps the name onto its CLI's own flag. Neither re-implements the CLI's naming.
- An environment variable, not a new positional argument: the adapter contract `<verb> <name> <folder>` does not change, an old adapter ignores it, and a new adapter falls back to the handle when it is unset (an older agents Feature). Nothing breaks in either order of upgrade.
- No `supports` line (Decided, finding 5): an adapter whose CLI cannot name sessions ignores `AGENT_SESSION_NAME` and the CLI keeps its own default title (the NFR-12 fallback). `agents check` says which adapters use it only if it can tell without a new verb.
- The Feature sets `AGENT_SESSION_NAME` on every adapter call (start-bg, new, resume, wake, attach, stop, list, logs, ...): the rendered name where it applies, unset or empty where it does not, so a value inherited from a parent session never leaks into a nested call.

The capability matrix (agents-v2 section 14.1) says two vendors name a session natively at start (Claude `--name`, Copilot `-n`), OpenCode with `run --title`, Codex only after the fact and Gemini not at all. That meets NFR-12's two-vendor test, so the template is neutral in the spec; what a CLI does with it is that CLI adapter's business.

## 5. Stability and the stateful agent

The rule: for a **stateful** agent the rendered name is identical at every start. Every variable in the set (`handle`, `repo`, `machine`) is stable. `{run}`, the one dynamic variable, is deferred (Decided) until an ephemeral run can be found again; it is not in these slices.

One residual instability, stated: `{machine}` changes if the workstation is renamed. That is a change of template result, handled as in section 6.

When `DCF_HOST_MACHINE` is empty (a CI run, Codespaces, a launcher older than the slice), `{machine}` renders `container`, a fixed word; the container's hostname is a container id that changes at every rebuild and would break stability. `agents check` warns that the name will not tell machines apart.

## 6. Changing the template for a running agent (the migration)

Decision: **a changed name applies to sessions started from then on; a session that exists keeps the name it has, and the adapter never makes a copy to rename one.**

How, in the Claude adapter, which finds the agent by its own record first (agent, folder, job id and session id, kept in the adapter's state, keyed by the handle):

1. Found by the record, a rename changes nothing: the record is keyed by the handle, not the label.
2. Bare wake: today's check is "saved options are exactly `--name <name> <args>`". It becomes "saved name is the current rendered name, any name the record has held, or the bare handle". The adapter records the name it used when it starts a session (a new field in its record). So a woken session keeps its old name and its conversation; a flag given with `--resume` would start a copy, which this avoids.
3. No record (an agent started by hand, a lost state folder): found by folder and by name, where the name is the rendered one, the recorded (previous) name, any name the record has ever held for that handle and folder, **or the bare handle** (Decided, finding 2). The handle match stays; it is cheap and it is what an existing deployment has.
4. The old name goes away when the session does: `agents stop` then `start`, or `reset`, starts a new session under the new name. `agents check` prints one line while the running session's name differs from the rendered one ("host: the running session is named `host`; the template gives `desktop host`; stop and start to apply").

Rejected: renaming a live session in place (Claude Code offers `/rename` interactively, nothing documented from outside; NFR-13 says not to drive the CLI's screen), and "match the handle for one release then stop": the record makes the handle match unnecessary for known agents, and an agent without a record is rare, so the handle match can stay indefinitely at no cost. A first-release-only window would turn a quiet label change into an orphaned session.

## 7. Characters, length, collisions

- **Template text**: letters, digits, space, and `. _ : @ / ( ) -` plus the `{variables}`. No tab or other control character (the adapter's list output is tab separated), no quote, backslash or `$`.
- **Values**: each variable's value is cut to the same set, every other character becoming `-` (a machine named `NABIL'S PC` renders `NABIL-S-PC`); `{machine}` keeps its case.
- **Length**: the limit is Claude Code's own if it documents one; otherwise a limit stated as this repository's choice, with the reason, not a measured one (Decided, finding 8; the slice settles it, the figure 60 was a guess). Over the limit is an error in `agents check` and a refused start, never a silent cut (a cut name can collide, and which end is lost would surprise). Leave room for the number Claude Code appends on a collision (` (2)`).
- **Two machines, same template**: they render the same name, which is correct: the remote view separates devices itself, and `{machine}` is how the label tells them apart where it does not. Two agents in one list rendering the same name in the same folder is refused by the list check (the adapter finds sessions by name and folder), whatever the template.
- **Claude's own numbering** (`host (2)`) is already matched by the adapter and is unaffected.

## 8. What the verbs print

`agents list` keeps the handle in HANDLE. A NAME column appears only when some agent's rendered name differs from its handle, so the default list is unchanged; `agents list --json` always carries `"sessionName"`. `agents check` prints the rendered name per agent and the warnings of sections 5 and 6. The handle remains the argument of every verb (`agents stop host`), never the session name.

## 9. The carrier and the lease

Unaffected. The lease folder, its holder file, the carrier (`session:<id>`) and the adapter's record are keyed by the handle and the session id. A rename changes a label only. `session-name` is not part of the identity, and two stateful agents cannot share an `identity` any more than before.

## 10. Launcher change

`DCF_HOST_MACHINE`: the launcher sets it from the workstation's name (`$env:COMPUTERNAME`; empty on a host where it is unknown) before it runs the devcontainer CLI, exactly as it sets `DCF_HOST_TYPE`, `DCF_HOST_HOME` and the others (ADR 0024). The bootstrap's `devcontainer.yml` passes it into the container with the other `DCF_HOST_*` values via `containerEnv` (`${localEnv:DCF_HOST_MACHINE}`); an existing consumer adds `"DCF_HOST_MACHINE": "${localEnv:DCF_HOST_MACHINE}"` to its `containerEnv` (until then `{machine}` renders `container`), and the launcher prints a hint when a repository's `devcontainer.json` lacks the line, as it does for the FUSE slots; a user can override it in their `.env` for a friendlier name (`DCF_HOST_MACHINE=desk`). `task devcontainer:info` lists it. It carries a name, never a secret or a path.

## 11. Tests

All Docker-free, in the existing suites.

- **Render** (agents unit tests): the default gives the handle; option versus key precedence; each variable; an unknown variable, an unclosed brace and a quoted `{handle}` value read right; the character set and the replacement of bad characters in values; 60 versus 61 characters; `{machine}` empty gives `container`; the same list rendered twice gives the same name.
- **Hand-off**: the fake adapter records the `AGENT_SESSION_NAME` it received; handle only when the template is the default; `AGENT_SESSION_NAME` is set or empty on every adapter call, a nested call never sees the parent's value; an old adapter ignoring the variable still starts.
- **Clash**: two agents rendering one name in one folder fail the check; in two folders they pass.
- **Claude adapter** (fake `claude`): `start-bg` and `new` pass `--name <rendered>`; unset gives `--name <handle>` as today; a record is found after the template changed; a bare wake of a session whose saved name is the old one stays bare (no copy); a session with no record is found by the rendered name and by the bare handle; the record carries the name it started with.
- **Launcher**: a test of `devcontainer:info` listing `DCF_HOST_MACHINE`, set and unset, in the existing host profile tests.
- **Lint**: the README and NOTES regenerate with `task docs`; the vendored-helper and version checks pass.

## 12. Where the host departs from its first sketch, and the slices

- **`{user}`** is dropped (Decided): the container user is `vscode`, useless as a label, so it would need a second launcher variable for a case (two Windows users on one machine) the Operator did not raise. Add it if asked.
- **`{run}`** is deferred (Decided), not a variable of these slices.
- **The name travels in an environment variable** rather than as a changed argument, as section 4 says.
- **The migration is "the record, then handle-or-rendered", with no one-release window** (section 6).
- **A fixed fallback for `{machine}`** and not the hostname (section 5).

| Slice | Content | Version |
|---|---|---|
| 1 | The launcher sets `DCF_HOST_MACHINE`, the bootstrap `containerEnv` passes it, `devcontainer:info` lists it, a hint when a repository lacks the line | devcontainer-cli 1.16.2 |
| 2 | The Claude adapter reads `AGENT_SESSION_NAME` (default the handle), `--name` from it, the record keeps the started name, the saved-name rule of the bare wake, the finding rule of section 6 (record, rendered, recorded, any held name, handle) | claude-code 1.9.0 |
| 3 | The agents Feature: the option, the key, the renderer, the checks, `AGENT_SESSION_NAME` on every adapter call, the NAME column and `sessionName` in the JSON, this repository's `{machine} {handle}` in `.devcontainer/devcontainer.json`, NOTES (the 2.x roadmap shifts: integrations 2.2, ephemeral runs 2.3), `task docs` | agents 2.1.0 |

Slices 1 and 2 are safe in either order and before 3; the Feature that renders comes last, so no consumer sees a name change until the three are published (an unpublished Feature cannot be pulled). A release is due after slice 3; the Operator starts it.

## 13. Open questions (answered 2026-10-30)

All answered by the Operator; none open. Default template `{handle}`; `{user}` dropped; `{machine}` unset renders `container`; over-length refused; the separator is free text; other CLIs ignored until they have a start flag; no rename verb (a changed template applies at the agent's next start).

### Facts checked 2026-10-30 (Claude Code 2.1.308)

Checked in the trusted folder, haiku sessions named `factcheck-*` (5 started, all stopped by id).

**Verdict: a name given with `--name` stays the displayed name** in every field observed, through the first turn, a stop and bare wake, and a resume with a prompt. Claude Code retitles only a session that has no `--name`.

| Step | Command (abridged) | Fields (`claude agents --json --all` `name`; state.json `name`, `nameSource`; transcript `customTitle`, `agentName`) |
| --- | --- | --- |
| start | `claude --bg --name factcheck-a --model haiku "<one line>"` | all `factcheck-a`; `nameSource: user` |
| after first turn | same session, `done` | unchanged |
| stop, bare wake | `claude stop <id>`, `claude --bg --resume <full id>` | unchanged |
| resume with a long, off-topic prompt | `claude --bg --resume <full id> "<prompt>"` | unchanged (state.json `intent` stays the first prompt) |
| different topic, named | `--name factcheck-b` with a multi-sentence prompt | unchanged |
| no `--name` (control) | `claude --bg --model haiku "<prompt>"` | `name` becomes `explain-tide-mechanics`, `nameSource: auto`; transcript `aiTitle` "How tides work" |
| `--remote-control` | `--name factcheck-rc --remote-control factcheck-rc-remote` | `name` and `customTitle` stay `factcheck-rc`; `respawnFlags` keeps a bare `--remote-control` (the value is dropped); state.json gains `bridgeSessionId` |

- **Title-like fields:** there is no `title` field in `claude agents --json`; the transcript carries `customTitle` and `agentName` (from `--name`), and `aiTitle` only for an unnamed session. `nameSource` (`user` or `auto`) in state.json says which.
- **Pinning:** `--name` is the supported way, and it is pinned by `nameSource: user`. `--help` has no `--title` or rename command; `/rename` and `Ctrl+R` in agent view are interactive only (from the docs, not run).
- **Remote Control:** the web side was not visible from the container. The local fields do not differ, and a name given to `--remote-control` is not stored, so the displayed name there is expected to follow `--name`.
- **Not reproduced:** the retitle the adapter notes saw (a resident named `framework` listed as "d47 d50 personalization medallion"). It is consistent with a session started without `--name` or one whose name was lost, or with a `/clear`, which was not tried. The adapter's records remain a sound safeguard, but a template-rendered `--name` can be relied on for a session started or woken by the adapter.

Consequence for this proposal: it can work on Claude Code 2.1.308, provided every start and wake passes `--name`.

## Architecture review (2026-10-30)

**Verdict:** fit with changes

Placement is sound overall: the template and its variables in the agents Feature, the machine name in the launcher as a `DCF_HOST_*` variable (ADR 0024), the CLI flag in each adapter. NFR-12 is met (two vendors name a session at start, matrix row "Name a session"), NFR-13 is met (the Feature renders environment facts; no CLI naming is re-implemented), NFR-6 is met for the option (section 3), NFR-10 for the tests (section 11). No accepted ADR conflicts; nothing needs superseding. The changes below are about the stability rule, ephemeral names and the contract's shape.

### Findings
1. **Claude Code may retitle a background session, so the rendered name may not stay in the remote view.** `src/claude-code/agent-adapter-claude.sh` ("records", line 148) says the name given with `--name` does not always stay, which is why the adapter keeps a record. The proposal never mentions it, and the whole ask (telling sessions apart) rests on the label persisting. Recommended change: before slice 2, check on a real session whether the rendered name survives a first prompt, and state the result in section 2; if it does not, say the feature is best-effort for Claude.
2. **The stability rule does not cover a lost record after two template changes.** `mine()` finds an unrecorded session only by `$NAME` or `$NAME (n)` in the folder; section 6 item 3 widens this to the rendered name or the handle, but a session started under an earlier rendered name (template changed twice, or `{machine}` renamed, record lost) matches neither, so a second live session starts. `want_flags` and `bare_ok` also compare the saved list with `--name $NAME`, so the bare wake needs the recorded name passed in, which is a change to the fixed-order comparison and deserves its own test (saved name differs, args equal, stays bare). Recommended change: say in section 6 that this case is a known limit and that `agents check` warns when a running session of the same folder carries an unknown name; do not promise "never a copy" without the record.
3. **`{run}` on ephemeral agents breaks the adapter's find-by-name.** `mine()` matches only `$NAME` and `$NAME (n)` (adapter lines 235-252) for `list`, `stop` and `logs`, and the record is one line per (handle, folder), replaced on write (`rec_put`). Ephemeral agents run in any number of copies and share a stateful agent's identity "to list background runs" (LEXICON, Ephemeral agent). A name like `reviewer a1b2c3` is not found by handle. Recommended change: add to section 6/11 how an ephemeral run is found again (by session id the adapter prints at start, or by a name prefix match of `<handle> `), and a test for `stop` and `list` of two ephemeral runs.
4. **Environment variable instead of an argument: acceptable, with two fixes.** It keeps `<verb> <name> <folder>` intact (ADR 0037, contract in agents.md) and an old adapter ignores it. But (a) a variable inherited from a parent session leaks: an agent running `agents start other` inside a session that was started with `AGENT_SESSION_NAME` set would pass the parent's name to the child if the Feature does not set or unset it on every call; (b) it must be set on every verb that reads names (`wake`, `attach`, `stop`, `list`), not only on start, because `want_flags` and `mine()` need it. Recommended change: section 4 states that the Feature exports or `unset`s `AGENT_SESSION_NAME` explicitly on each adapter call, and tests it with a nested call.
5. **"`supports` line `session-name`" is a capability, not a verb.** `supports` prints verbs and `agents check` prints them as "what each supports" (agents.sh lines 1243-1262); an unsupported verb answers exit 3 (adapter line 500). An environment variable cannot answer exit 3, so the NFR-12 fallback is only information. Recommended change: name it as a capability word in the `supports` output documented in agents.md, and say that the fallback (CLI keeps its default title) is the behaviour, not the check line.
6. **Lexicon.** "Session name" is a new concept and is not in `LEXICON.md`; it sits beside **Handle** (an address, not a label). `{run}`, "rendered name" and "template" are used as terms too. Recommended change: have the librarian define "session name" (a label the CLI shows, never an address) and use it consistently; section 3 says "`{repo}`" is the folder's basename while the lexicon speaks of the agent's folder, so check they agree for an agent whose folder is not the root.
7. **Launcher claim needs one qualifier.** ADR 0024 point 4 says the launcher sets `DCF_HOST_*` and the repository maps them with `containerEnv`; the bootstrap template does it for a new repository, but an existing consumer gets `{machine}` = `container` until it adds that mapping (ADR 0024 point 6, migration note). Section 10 reads as if it arrived automatically. Recommended change: say that, and that slice 1 ships a consumer-contribution note.
8. **Unsourced numbers.** "60 leaves room for ` (2)`" has no source in the code or the matrix; no CLI limit on a name length was checked. Recommended change: mark 60 as chosen, not measured, or check Claude's and Copilot's limits.

### Open questions for the Operator
- **Default template (section 13, 1):** agree, keep `{handle}`. The review adds nothing against it.
- **`{machine}` fallback (3):** agree with `container`, with the `agents check` warning; refusing would break CI and Codespaces for a label.
- **Rename in place (7):** recommend no `agents rename-session`; finding 2 shows stop-and-start is the honest path and a new verb would be the "new concept" NFR-13 warns about.
- **Other CLIs (6):** agree: ignore until the CLI has a start flag.
- **Ephemeral names (new):** should `{run}` stay in slice 3, or wait until finding 3's find-again rule is built? Recommendation: ship stateful names first and add `{run}` after, since the Operator's ask (five `host` sessions) is about stateful agents.
