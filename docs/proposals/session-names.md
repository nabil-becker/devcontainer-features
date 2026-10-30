# Proposal: session names you can tell apart

Status: proposed 2026-10-30, for the Operator to rule on after the architecture review. Build not started.

Who this serves: the Operator, and anyone who runs several agents, often several named `host`, across machines and cannot tell their sessions apart in Claude Code's remote view; a consumer's maintainer gets the same, set once in the repository.

## 1. The ask, and the decided parts

The Operator (2026-10-29): sessions started through the agents CLI all show their bare handle (`host`) in the remote view; with four or five `host` sessions across machines nobody can tell them apart. Wanted: a template for the session's display name (machine name plus handle, for example), set once, optionally per agent; dynamic names are fine for ephemeral agents; take on little domain: use each CLI's own naming, do not recreate the CLI.

Nothing is decided yet beyond that ask. Everything below is the host's recommendation. Where it departs from the host's first sketch, section 12 says so.

## 2. Where the question sits

The **handle** (the agent's `name` in the list) stays the address: it keys the lease, the **carrier** record, `agents list`, every verb. The **session name** is a label the CLI shows. Today the agents Feature hands the handle to the **CLI adapter** as `<verb> <name> <folder>`, and the Claude adapter uses it twice: as `--name` and as part of how it finds the agent's session again (name and folder, plus its own record). That second use is the trap: a label that changes between starts would orphan the session and break the bare wake, which compares Claude Code's saved options with `--name <name> <args>`.

```
 list (repo)                 Feature option / env                launcher (workstation)
  - name: host                AGENTS_SESSION_NAME                 DCF_HOST_MACHINE=<COMPUTERNAME>
    session-name: "..."       default "{handle}"                        |  containerEnv
          \                          |                                  v
           v                         v                          DCF_HOST_MACHINE in the container
        agents: render ONE time per start  <---------------------------/
          |  handle=host repo=<folder> machine=<m> run=<id, ephemeral only>
          |  check: characters, length, {run} only on ephemeral, no clash
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
    session-name: "{handle} {run}"          # ephemeral only
```

- **Option** `sessionName` on the agents Feature, written to the Feature's settings like `AGENTS_FILE` (NFR-6: task variable, root `.env`, `.devcontainer/.env`, environment, default); default `{handle}`, today's behaviour exactly.
- **Key** `session-name:` in the list: flat, one scalar, so the awk reader stays. A value that starts with `{` must be quoted (the reader refuses an entry written as `{ }`; the quoted form is tested). Precedence: the agent's key, then the option, then `{handle}`.
- **Variables** (the closed set; anything else in braces is a list-check error):

| Variable | Value | Source |
|---|---|---|
| `{handle}` | the agent's name | the list |
| `{repo}` | the repository's folder name (the basename of the workspace root the list is in) | the container |
| `{machine}` | the workstation's name | `DCF_HOST_MACHINE`, set by the launcher |
| `{run}` | six lowercase hex characters, new each start | the agents Feature; ephemeral agents only |

`{user}` is left out of the first slice (section 12, question 2).

## 4. Where rendering happens

The agents Feature renders, once per start, and hands the adapter the finished string in the environment variable `AGENT_SESSION_NAME` (a name for the adapter to use, not a template). Reasons:

- The variables are environment facts that do not depend on the CLI; one renderer means one set of tests and every CLI gets the same name from the same list (NFR-12). Rendering in each adapter would repeat the template parser, the character rules and the `{run}` rule per CLI.
- NFR-13: the Feature manages the environment (who, where, which run); the adapter only maps the name onto its CLI's own flag. Neither re-implements the CLI's naming.
- An environment variable, not a new positional argument: the adapter contract `<verb> <name> <folder>` does not change, an old adapter ignores it, and a new adapter falls back to the handle when it is unset (an older agents Feature). Nothing breaks in either order of upgrade.
- The adapter declares it applies the name with a `supports` line `session-name`; without it `agents check` says "does not name sessions" once and a start is not affected (NFR-12 fallback: the CLI keeps its own default title).

The capability matrix (agents-v2 section 14.1) says two vendors name a session natively at start (Claude `--name`, Copilot `-n`), OpenCode with `run --title`, Codex only after the fact and Gemini not at all. That meets NFR-12's two-vendor test, so the template is neutral in the spec; what a CLI does with it is that CLI adapter's business.

## 5. Stability and the stateful agent

The rule: for a **stateful** agent the rendered name is identical at every start. Every variable allowed there is stable (`handle`, `repo`, `machine`); `{run}` is not, so the list check refuses `{run}` on a stateful agent (and on `kind: resident`) with a message naming the key. An ephemeral agent takes no lease and is never found again by name, so `{run}` is welcome there and is the only dynamic part.

One residual instability, stated: `{machine}` changes if the workstation is renamed. That is a change of template result, handled as in section 6.

When `DCF_HOST_MACHINE` is empty (a CI run, Codespaces, a launcher older than the slice), `{machine}` renders `container`, a fixed word; the container's hostname is a container id that changes at every rebuild and would break stability. `agents check` warns that the name will not tell machines apart.

## 6. Changing the template for a running agent (the migration)

Decision: **a changed name applies to sessions started from then on; a session that exists keeps the name it has, and the adapter never makes a copy to rename one.**

How, in the Claude adapter, which finds the agent by its own record first (agent, folder, job id and session id, kept in the adapter's state, keyed by the handle):

1. Found by the record, a rename changes nothing: the record is keyed by the handle, not the label.
2. Bare wake: today's check is "saved options are exactly `--name <name> <args>`". It becomes "saved name is the current rendered name, or the name the record holds (the one this adapter started it with), or the bare handle". The adapter records the name it used when it starts a session (a new field in its record). So a woken session keeps its old name and its conversation; a flag given with `--resume` would start a copy, which this avoids.
3. No record (an agent started by hand, a lost state folder): found by folder and by name, where the name is the rendered one **or the bare handle**, the match it makes today. The handle match stays; it is cheap and it is what an existing deployment has.
4. The old name goes away when the session does: `agents stop` then `start`, or `reset`, starts a new session under the new name. `agents check` prints one line while the running session's name differs from the rendered one ("host: the running session is named `host`; the template gives `desktop host`; stop and start to apply").

Rejected: renaming a live session in place (Claude Code offers `/rename` interactively, nothing documented from outside; NFR-13 says not to drive the CLI's screen), and "match the handle for one release then stop": the record makes the handle match unnecessary for known agents, and an agent without a record is rare, so the handle match can stay indefinitely at no cost. A first-release-only window would turn a quiet label change into an orphaned session.

## 7. Characters, length, collisions

- **Template text**: letters, digits, space, and `. _ : @ / ( ) -` plus the `{variables}`. No tab or other control character (the adapter's list output is tab separated), no quote, backslash or `$`.
- **Values**: each variable's value is cut to the same set, every other character becoming `-` (a machine named `NABIL'S PC` renders `NABIL-S-PC`); `{machine}` keeps its case.
- **Length**: the rendered name is at most 60 characters. Over the limit is an error in `agents check` and a refused start, never a silent cut (a cut name can collide, and which end is lost would surprise). The 60 leaves room for the number Claude Code appends on a collision (` (2)`).
- **Two machines, same template**: they render the same name, which is correct: the remote view separates devices itself, and `{machine}` is how the label tells them apart where it does not. Two agents in one list rendering the same name in the same folder is refused by the list check (the adapter finds sessions by name and folder), whatever the template.
- **Claude's own numbering** (`host (2)`) is already matched by the adapter and is unaffected.

## 8. What the verbs print

`agents list` keeps the handle in HANDLE. A NAME column appears only when some agent's rendered name differs from its handle, so the default list is unchanged; `agents list --json` always carries `"sessionName"`. `agents check` prints the rendered name per agent, the warnings of sections 5 and 6, and which CLI adapters name sessions. The handle remains the argument of every verb (`agents stop host`), never the session name.

## 9. The carrier and the lease

Unaffected. The lease folder, its holder file, the carrier (`session:<id>`) and the adapter's record are keyed by the handle and the session id. A rename changes a label only. `session-name` is not part of the identity, and two stateful agents cannot share an `identity` any more than before.

## 10. Launcher change

`DCF_HOST_MACHINE`: the launcher sets it from the workstation's name (`$env:COMPUTERNAME`; empty on a host where it is unknown) before it runs the devcontainer CLI, exactly as it sets `DCF_HOST_TYPE`, `DCF_HOST_HOME` and the others (ADR 0024). The bootstrap's `devcontainer.yml` passes it into the container with the other `DCF_HOST_*` values via `containerEnv` (`${localEnv:DCF_HOST_MACHINE}`); a user can override it in their `.env` for a friendlier name (`DCF_HOST_MACHINE=desk`). `task devcontainer:info` lists it. It carries a name, never a secret or a path.

## 11. Tests

All Docker-free, in the existing suites.

- **Render** (agents unit tests): the default gives the handle; option versus key precedence; each variable; an unknown variable, an unclosed brace and a quoted `{handle}` value read right; the character set and the replacement of bad characters in values; 60 versus 61 characters; `{machine}` empty gives `container`; `{run}` accepted on ephemeral, refused on stateful and on resident, differs between two starts; the same list rendered twice gives the same name.
- **Hand-off**: the fake adapter records the `AGENT_SESSION_NAME` it received; handle only when the template is the default; an adapter without the `session-name` capability is called the same and `check` says so; an old adapter ignoring the variable still starts.
- **Clash**: two agents rendering one name in one folder fail the check; in two folders they pass.
- **Claude adapter** (fake `claude`): `start-bg` and `new` pass `--name <rendered>`; unset gives `--name <handle>` as today; a record is found after the template changed; a bare wake of a session whose saved name is the old one stays bare (no copy); a session with no record is found by the rendered name and by the bare handle; the record carries the name it started with.
- **Launcher**: a test of `devcontainer:info` listing `DCF_HOST_MACHINE`, set and unset, in the existing host profile tests.
- **Lint**: the README and NOTES regenerate with `task docs`; the vendored-helper and version checks pass.

## 12. Where the host departs from its first sketch, and the slices

- **`{user}`** is not in slice 1: the container user is `vscode`, useless as a label, so it would need a second launcher variable for a case (two Windows users on one machine) the Operator did not raise. Add it if asked.
- **The name travels in an environment variable** rather than as a changed argument, as section 4 says.
- **The migration is "the record, then handle-or-rendered", with no one-release window** (section 6).
- **A fixed fallback for `{machine}`** and not the hostname (section 5).

| Slice | Content | Version |
|---|---|---|
| 1 | The launcher sets `DCF_HOST_MACHINE`, `containerEnv` passes it, `devcontainer:info` lists it; the bootstrap comment documents it | devcontainer-cli patch (a new variable, nothing changes without a template) |
| 2 | The Claude adapter reads `AGENT_SESSION_NAME` (default the handle), `--name` from it, the record keeps the started name, the saved-name rule of the bare wake, the match by rendered name or handle, the `session-name` `supports` line | claude-code minor (additive; with no variable it behaves as today) |
| 3 | The agents Feature: the option, the key, the renderer, the checks, the variable to the adapter, the NAME column and `sessionName` in the JSON, NOTES, `task docs` | agents minor |

Slices 1 and 2 are safe in either order and before 3; the Feature that renders comes last, so no consumer sees a name change until the three are published (an unpublished Feature cannot be pulled). A release is due after slice 3; the Operator starts it.

## 13. Open questions

1. **Default template.** Keep `{handle}` (nothing changes until a repository opts in), or ship `{machine} {handle}` as the default? The recommendation is to keep `{handle}`: a default change renames every consumer's running sessions on the next start, which is the section 6 migration for everyone at once.
2. **`{user}`**: drop it (recommended) or add a `DCF_HOST_USER` in the same launcher slice?
3. **`{machine}` fallback**: the fixed word `container` (recommended), or refuse a template using `{machine}` when the launcher did not set it?
4. **Over-length name**: refuse (recommended) or cut the end?
5. **Separator in a template**: free text (as here) or a fixed joiner? Free text costs the character set of section 7.
6. **Other CLIs**: should the spec say now that an adapter whose CLI names only after the fact (Codex's `/rename`) applies the name at a later verb, or only that it ignores it until the CLI has a start flag (recommended)?
7. **Rename in place**: is leaving a running session under its old name until stopped acceptable, or should `agents` offer an explicit `agents rename-session <handle>` that does stop-and-start for the Operator?

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
