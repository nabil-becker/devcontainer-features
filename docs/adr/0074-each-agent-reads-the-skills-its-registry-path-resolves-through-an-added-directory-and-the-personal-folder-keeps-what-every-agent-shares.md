# ADR-0074: Each agent reads the skills its registry path resolves through an added directory, and the personal folder keeps what every agent shares

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-20 |
| **Deciders** | the Operator; proposed by the host |

Amends [ADR-0064](0064-the-cli-contract-gains-an-optional-skills-verb-and-the-component-registry-hands-resolved-skills-to-it-at-an-agent-s-start.md)
(its consequence "the resolved view and a CLI's skills folder are one per container"); ADR-0064
itself is not edited.

## Context

ADR-0064 hands the component registry's resolved skills to Claude Code's personal skills folder,
`$CLAUDE_CONFIG_DIR/skills`, at every agent's start. There is one resolved view
(`$COMPONENT_REGISTRY_STATE_DIR/view`) and one personal folder per container, so two agents with
different `registry-path`s overwrite each other: the latest start wins for every session (the
component registry notes, "Limits"; backlog item `agent-skills-folders`). A second fault rides
along: `agents start` resolves `--as` the agent's path and then hands over "the current view",
which another agent's resolve may have replaced in between.

Claude Code facts, from its skills documentation (https://code.claude.com/docs/en/skills, checked
2026-11-20) and CLI reference (https://code.claude.com/docs/en/cli-reference, checked 2026-11-20):

- Skills load from the managed folder, the personal folder (`~/.claude/skills`, here
  `$CLAUDE_CONFIG_DIR/skills`), the project's `.claude/skills`, nested `.claude/skills` on first
  access, plugins (`/plugin:skill`), and "`.claude/skills/<skill-name>/SKILL.md` in a directory you
  pass with `--add-dir`"; "When you add a directory with `--add-dir` or `/add-dir`, Claude Code
  loads the skills in that directory's `.claude/skills/`". "The `permissions.additionalDirectories`
  setting in `settings.json` grants file access only and loads none of these."
- Name clashes: "Enterprise over personal, and personal over project." An added directory's skill
  loses to "the enterprise, personal, or project skill, while the added directory's skill runs
  under a prefixed name": `/<folder name>:<skill>` (Claude Code 2.1.309 or later; this devhost runs
  2.1.311). Between two added directories, the one added first wins.
- Live reload: the personal folder, the project's and "a `.claude/skills/` inside an `--add-dir`
  directory" are watched; a change is picked up in the running session; `/reload-skills` when a new
  skill does not appear. Whether a folder created after the session started is watched is not
  stated (ADR-0064 assumed `/reload-skills`).
- Skill text may use `${CLAUDE_SESSION_ID}` and `${CLAUDE_SKILL_DIR}`, substituted when the skill
  runs.
- `CLAUDE_CONFIG_DIR` relocates "your settings, session history, and plugins": the login and the
  whole state.

## Decision

1. **A view per who-you-are path** (`component-registry` 1.8.0). `resolve` also points
   `paths/<path with / as +>` at the view it made; `view` stays the latest. `handover <cli> <name>
   <folder> --as <path>` reads that path's view, and without `--as` the who-you-are setting's, so a
   resolve for another agent in between no longer changes what an agent gets. The one resolve lock
   stays (the layer copies are shared between paths); views no pointer names are removed. Each
   hand-over is recorded (`handovers.tsv`: cli, name, folder, path, and whether the path was the
   agent's own or the setting).
2. **Claude Code splits the skills by agreement** (`claude-code` 1.14.0). The adapter's `skills`
   verb keeps each agent's full view (`registry-agents/<name>.<folder sum>/want`) and, at every
   hand-over, under its own lock, writes:
   - into the **personal folder** the skills every agent's view has alike (same name, same files);
   - into the **agent's own folder**, `registry-agents/<key>/registry/.claude/skills`, the rest of
     its view.
   The adapter passes `--add-dir <that>/registry` to every session of the agent it starts
   (`start-bg`, `new`, `resume`), last and once. Because a personal skill beats an added one, a
   name the views disagree on is never personal; when every agent shares one path, everything is
   personal and the own folders are empty, which is ADR-0064's behaviour unchanged.
3. **`/registry-refresh` refreshes the calling agent**: the skill runs `dcf-registry refresh
   --session "${CLAUDE_SESSION_ID}"`; `refresh` finds the agent whose session that is in each
   adapter's `list` and its record, resolves its own path and hands over to it alone. An unknown or
   unsubstituted id, or none, refreshes every recorded hand-over, each path resolved once.
4. **Cleanup**: `dcf-registry forget <cli> <name> <folder>` (the adapter's `skills` verb with
   `COMPONENT_REGISTRY_FORGET=1`) drops an agent's own folder and record; `agents up` (participant
   1.4.0) forgets the recorded agents of this repository that are no longer in the agent list; the
   adapter drops an agent whose folder no longer exists at any hand-over.
5. **Transparency** (the Operator's first condition, 2026-11-21). Each start that passes the
   flag prints one line, `<agent>: registry skills: <n> shared, <m> own -> --add-dir <folder>`
   (`(already in its args)` when it was); nothing when no flag is added. Each hand-over says where
   the skills went and which project skills win. The adapter's optional, read-only verb
   `skills-show <name> <folder>` gives the agent's own folder and skills and the shared ones;
   `agents check` prints them per agent with its mode, and `dcf-registry handovers --skills` for
   every recorded agent.
6. **Control and override** (the Operator's second condition, 2026-11-21). The agents list key
   `registry-skills: split | shared | off` per agent, else the container default
   `COMPONENT_REGISTRY_SKILLS_MODE` (the task variable, `.env`, `.devcontainer/.env`, the
   environment), else `split`. `split` is decisions 1 to 4; `shared` hands the agent's whole view
   to the personal folder as ADR-0064 did (the latest hand-over wins, no own folder, no flag);
   `off` resolves and hands over nothing for the agent and drops its own folder (its sessions still
   read the personal folder every session reads). The mode reaches the adapter as
   `COMPONENT_REGISTRY_SKILLS_MODE` through `dcf-registry handover --skills-mode`, is recorded and
   repeated by `refresh`. An `--add-dir` to the agent's own folder already in its args is never
   added twice; one to another folder is kept as it is.
7. **The limits are accepted** (the Operator's ruling S3, 2026-11-21): a committed project skill
   with the same name as an agent's own copy wins in that agent's sessions, and the own copy stays
   runnable as `/registry:<name>`; a plain `claude` started by hand sees only the shared skills.
   Both are documented, and the start line names each clash (the skill and the project path).
   Today's only real case is `architecture-review`; its switch-over (backlog) removes it.
8. **The contract** (ADR-0037, ADR-0064, the Operator's ruling S2): the optional `skills` verb also receives
   `COMPONENT_REGISTRY_PATH` and `COMPONENT_REGISTRY_SKILLS_MODE`, and may receive
   `COMPONENT_REGISTRY_FORGET=1`; an adapter may offer the read-only `skills-show`; where a CLI keeps an
   agent's own skills, and how its sessions read them, stays the adapter's (NFR-13).

## Options considered

### Option A: per-path views, the shared skills personal, the rest in an added directory per agent (chosen)

One login and one Claude Code state for every agent; only documented mechanisms (`--add-dir`, the
precedence and live-reload rules); no change at all where every agent shares a path. Costs: a
project skill of the same name beats an agent's own copy (the registry's then runs as
`/registry:<name>`, and the hand-over says so); a session not started through `agents` reads only
the shared part; a running session started before this release lacks the flag (its wake says so,
and `/add-dir <folder>` in it reads them); disk holds each agent's view twice (small text files).

### Option B: the brief's form, the personal folder for the default view and an added directory per agent

Lost: a personal skill beats an added directory's of the same name, so an agent whose path changes
a skill the default view also has would run the default text, and its own only as
`/registry:<name>`. This is the exact case per-agent folders exist for.

### Option C: a `CLAUDE_CONFIG_DIR` per agent

Lost: it moves the login, the settings, the session history, the plugins and the jobs
(https://code.claude.com/docs/en/settings), so each agent would need its own login and
`claude agents` would list only its own sessions; the participant component, the adapter's records
and the facilitator rely on one list.

### Option D: every registry skill in an added directory, none personal

Lost: the same project-skill clash for every skill, every session not started through `agents`
(a person typing `claude`) loses all registry skills, and today's single-path containers would
change behaviour for nothing.

### Option E: a plugin per agent (`--plugin-dir`)

Lost: plugin skills are namespaced (`/plugin:skill`), so every registry skill would change its
name, and the session-only plugin flag is the same per-start flag as `--add-dir` without its
plain names.

## Consequences

- Agents with different `registry-path`s in one container each read their own skills, live, under
  one login. Containers where every agent shares a path see no change but an empty added directory.
- The adapter's `skills` verb now knows about every agent's view, not only the caller's; another
  CLI implementing the verb decides its own split (or, without an added-directory mechanism, keeps
  the ADR-0064 limit and says so).
- Open: whether Claude Code saves `--add-dir` in a background session's options (`respawnFlags`)
  is not stated; the adapter compares it on a wake like any argument and says when it is missing.
  Whether an added directory's skills folder created after a session started is watched is not
  stated either; the adapter creates it before the first start.
- `src/component-registry/NOTES.md`, `src/claude-code/NOTES.md`, `src/agents/NOTES.md` (the
  contract) and the standing architecture documents carry the change.

## Change log

| Date | Change |
|---|---|
| 2026-11-20 | First draft, with `component-registry` 1.8.0, `claude-code` 1.14.0, participant 1.4.0 (backlog item `agent-skills-folders`). |
| 2026-11-21 | Decided by the Operator. S1: the mechanism (Option A, decisions 1 to 4) accepted with two conditions, "make sure there is transparency in that behavior, and a way for people to control or override it if need be"; decisions 5 and 6 answer them. S2: option (A), the two environment variables `COMPONENT_REGISTRY_PATH` and `COMPONENT_REGISTRY_FORGET` on the existing `skills` call (decision 8). S3: option 1, the limits accepted, documented, and a clash named in the start line (decision 7). Status accepted. |
| 2026-11-21 | Renumbered from 0068 to 0074 when merged with main (0068 to 0073 taken); versions after main: `component-registry` 1.8.0, `claude-code` 1.14.0, participant 1.4.0, `agents` 2.6.0, `copilot` 0.2.1. |
