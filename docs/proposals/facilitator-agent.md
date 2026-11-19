# Proposal: a facilitator, the communication layer between agents of any vendor

draft 2026-11-19

Status: a design proposal, nothing built. Backlog id: `facilitator-agent`. It serves the Operator,
through the host, who rules on it; and the persona the Feature is for: an engineer who downloads
a Dev Container Feature, gives it their own vendor credentials, and holds conversations with
several AI agents running in their devcontainer. Vendor facts are marked **(docs read)** when a
vendor page was read for this proposal, **(matrix)** when taken from the capability matrix of
`docs/proposals/agents-v2.md` section 14 (itself from docs, 2026-10-29), and **(not checked)** when
neither; nothing was installed or run here.

## 1. The ask

The Operator, 2026-11-19: "I want it to be a 'facilitator agent' [whose] purpose is to facilitate
conversations between agents. The catch is that the agents are running externally and could be
different vendors. [...] I can have group conversations, or individual conversations. The
facilitator facilitates them, routing requests and bubbling up responses." Clarified: participants
are external processes (Claude, GitHub Copilot, Gemini in the devcontainer); the facilitator may
itself be a vendor tool or a local model; cloud agents are fine if they have a local interface (a
CLI or MCP); networking across containers is a separate, later requirement. The example: a
downloaded Feature, the engineer's own Copilot token running the facilitator, a Claude agent
"domain expert one", an open-source local model "fun jester", and "Hey @jester tell
@domain-expert-one a joke".

A further ruling the same day: "they are running as external processes, using some harness to
keep them running so our responsibility is the communication." So the Feature **does not start,
stop, supervise or resume anything**. Its whole job is: how a running participant is addressed,
how messages reach it, how replies come back, routing, limits, and the record.

Rulings it rests on: separate processes in one devcontainer; cloud agents only through a local
interface; networking out of scope; **NFR-12** (a contract for agent CLIs works on two vendors or
names its fallback; ADR-0037); **NFR-13** (manage the environment, not the CLI); **NFR-1, 2, 5, 6,
7, 8, 10** as for every Feature; ADR-0048 (OpenBao keeps every token).

## 2. The scenario, end to end

```
 You (terminal)      facilitator store         jester (local model)     domain-expert-one (Claude)
 `facilitator chat`  + MCP server per          kept running by the      kept running by the
                     participant (stdio)       harness, in `receive`    harness, in `receive`
     |                    |                          |                         |
     | "@jester tell @domain-expert-one a joke"     |                         |
     |--- send(conv c1) ->| route: mention=jester   |                         |
     |                    | hops=0, write msg m1    |                         |
     |                    |<---- receive() (waiting, long-poll) ---|          |
     |                    |---- m1 delivered ------>|                         |
     |                    |                         | (model writes a joke)   |
     |                    |<-- reply(to=domain-expert-one, "Why did...") ----|
     |                    | route: hops=1, write m2 |                         |
     |                    |---------------- m2 delivered ------------------->|
     |                    |                         |                         | (reads, reacts)
     |                    |<------------ reply("Ha. Old, but good.") --------|
     |                    | no mention: goes back to the asker of m2 (jester)|
     |                    |---- m3 delivered ------>|   hops=2                |
     |                    |                         | reply("Thanks.", to=you)|
     |<-- bubbled up: you see m1..m4 in the transcript, live (`chat` follows)|
     | `facilitator chat` prints every message of conversation c1 as it lands|
```

Nothing in this picture is started by the Feature: the two participants, and whatever keeps them
alive, are the harness's. The store and the routing are written by whichever process calls a
tool, so there is no facilitator daemon to keep running either (section 4.3).

## 3. Concepts and names

Existing words kept: **agent**, **handle** (a participant's address), **resident agent**,
**harness** is new (below). **"Adapter" stays the agents Feature's `agent-adapter-<cli>`** (LEXICON,
"CLI adapter"); this proposal does not reuse it, so the new word for how a process connects is
**attachment**.

| Proposed term | Meaning |
|---|---|
| **Facilitator** (the Feature, and a role) | The Feature `facilitator`: the communication layer. The **facilitator role** is a participant, any vendor or a local model, that receives what is addressed to no one, in a group conversation. The layer routes by rule; the role is who it falls to. |
| **Participant** | A named, running process that takes part: a **handle** (`jester`), a persona (a system prompt or profile it is started with, kept by the harness), an **attachment**, an optional model label shown in the transcript. The engineer at the terminal is a participant too (`you`, kind `human`). |
| **Harness** | Whatever keeps a participant process running: tmux, a process supervisor, a service, the vendor's own session, the `agents` Feature. Not this Feature's job. |
| **Attachment** | How a running participant connects to the layer. Primary: **MCP** (tools `receive`, `reply`, `say`, `who`). Fallbacks: the **pump** (a loop that does `receive` and runs a one-turn command), and the **model wrapper** (a pump for an OpenAI-compatible endpoint). |
| **Conversation** | A thread with members: **direct** (you and one participant, or two participants) or **group** (three or more). Held as in the register's `messages` type: group and direct, A2A-shaped. |
| **Turn** | One message by a participant in a conversation. A turn's **hops** are the number of participant-to-participant deliveries since the last human message. |
| **Mention routing** | Delivery by `@handle` in the text or the `to` argument; no mention means the asker (see 4.4). |
| **Bubbling up** | Every message lands in the conversation's transcript, which a human follows; a message with no mention returns to the participant that asked. |
| **Hop limit** and **message budget** | The two guards against agents mentioning each other forever (4.5). |

## 4. Architecture

```
                         .devcontainer/facilitator.yml  (participants: handle, kind, attachment, agent?)
                                          |
  you ---- `facilitator chat` ----+       v
                                  |   +-----------------------------------------+
  claude (domain-expert-one) --MCP--> |  facilitator MCP server (one per client)|
  copilot, gemini  ------------MCP--> |  = route + limits + write               |
  pump / model wrapper --(same code)-> +--------------------+--------------------+
                                                           |  flock, append-only
                                       /var/lib/devcontainer-features/facilitator/
                                         conversations/<c>.jsonl  inbox/<handle>/  tokens/<handle>
```

### 4.1 The participant file

`.devcontainer/facilitator.yml`, committed, path set by `FACILITATOR_FILE` (NFR-6). A new file, not
a section of `agents.yml`: `agents.yml` says how to start and lease something (the harness's
business), this says who may talk. One optional cross-reference keeps them honest:

```yaml
participants:
  - name: jester                   # the handle; letters, digits, - and _
    attachment: model              # mcp | pump | model
    endpoint: http://localhost:11434/v1     # model only; an OpenAI-compatible server
    model: llama3.2
    persona: personas/jester.md    # model/pump only: the text the wrapper sends as system prompt
  - name: domain-expert-one
    attachment: mcp                # the participant's own CLI calls the tools
    agent: expert                  # optional: a name in agents.yml, shown by `facilitator status`; never started from here
  - name: copilot-lead
    attachment: mcp
    facilitator: true              # at most one; receives what is addressed to no one in a group
```

For an `mcp` participant the persona lives with its harness (its CLI's own profile or prompt); the
Feature prints the MCP entry and the sentence to add to the persona (`task facilitator:snippet --
<name>`), because it must not edit a vendor's configuration (NFR-13).

### 4.2 Attachment: one primary, a fallback per vendor

A running agent is idle until something gives it a turn, and MCP is call-and-response: a server
cannot wake a model. So the primary attachment makes the agent **ask for its mail**: the MCP tool
`receive` blocks on the participant's inbox (up to `receiveWaitSeconds`, default 300) and returns
the next message or "nothing yet"; the persona says "loop: `receive`, answer with `reply`, `receive`
again". Every MCP-capable CLI can do that with the same four tools, so the contract is one
contract (NFR-12).

| Participant | Primary attachment | Fallback (the vendor has no usable long-running form) |
|---|---|---|
| Claude Code | MCP: `--mcp-config` or a configured server **(docs read)**; MCP servers load under `-p` when named on the command line **(docs read)** | pump: `claude -p "<prompt>" --output-format json`, then `--resume <session_id>` for the next message; the JSON carries `result`, `session_id` and `total_cost_usd` **(docs read)**; `--append-system-prompt` for the persona **(docs read)** |
| GitHub Copilot CLI | MCP: `copilot mcp` manages its servers **(docs read)** | pump: `copilot -p` with `--resume <id or name>`, `--allow-all-tools`, `--no-ask-user` **(matrix)**; auth by `COPILOT_GITHUB_TOKEN`, else `GH_TOKEN`, else `GITHUB_TOKEN`, a fine-grained token with the "Copilot Requests" permission, or `copilot login --with-token` **(docs read)** |
| Gemini CLI | MCP servers from its settings **(not checked)** | pump: `gemini -p`, `--output-format json` gives `response` and `stats` with no session id; the `stream-json` `init` event carries it **(docs read)**; `--resume latest\|index\|uuid` **(matrix)** |
| Local model (Ollama, llama.cpp server) | the **model wrapper**: a small process the Feature ships that does `receive` itself (no model loop needed), calls the server's OpenAI-compatible chat endpoint with the persona and the conversation so far, and `reply`s. Ollama serves `/v1/chat/completions` **(not checked)**; llama.cpp's server is OpenAI-compatible **(not checked)**; the endpoint is stateless, so the wrapper keeps the messages | none needed |
| Cloud agent behind a local CLI or MCP | whichever of the rows above its local interface is | pump |

How a participant **replies and mentions others**: through the tools, not by parsing its output
(parsing a TUI's output is how an attachment breaks with each vendor release). `reply(text, to?)`,
`say(conversation, text, to)` (starts or joins a turn in another conversation) and `who()` (the
handles, so a participant does not invent one). The pump parses nothing either: it takes the
one-turn command's whole stdout as the reply to the asker, and a participant that wants another
recipient writes `@handle` at the start, the one text rule (section 4.4).

**What is not known and must be tested first (T1, manual).** Whether each vendor's model keeps
looping on a blocking tool for hours: tool-call timeouts, context growth (every message adds
tokens), and idle cost. The design degrades by configuration: `receiveWaitSeconds` shorter, or the
pump instead. Slice 1 ends with T1 on Claude Code, and the finding decides the primary for the
other vendors (decision D1). A turn hook that shows unread mail at each turn, as the register's
`inbox --notice` does, is a vendor-specific optimisation, never the contract.

### 4.3 The router, and the facilitator role

Two ways to decide who speaks: **deterministic** routing by `@mention`, or a model-run
facilitator that reads each message and chooses. **Recommended: deterministic routing in the
layer; the facilitator is a participant, any vendor or local model, to whom unaddressed group
messages go and who may be asked to decide ("@copilot-lead who should take this?").** Reasons: a
model deciding every hop costs a turn per hop, fails in ways the Operator cannot read from a log,
and cannot be tested without a vendor; routing by rule is a unit test. A model-run facilitator is
then no special case, just the participant that happens to be addressed.

The route is computed **at write time by whoever writes** (an MCP server instance, `chat`, the
pump): it appends the message under a file lock, then appends a delivery to each target's inbox
folder. `receive` reads and marks its own inbox. So there is no facilitator daemon to supervise,
which keeps with "our responsibility is the communication, not the processes".

### 4.4 Routing rules

1. `@handle` in the text (or `to`) delivers to that participant, each mention once. `@all` delivers
   to every member of a group.
2. A message with no mention in a **direct** conversation goes to the other member; in a **group**
   it goes to the facilitator-role participant, else (none set) to every member, which the hop
   limit then bounds.
3. A reply with no mention goes to the **asker**: the author of the message it answers (so the
   jester's "tell @domain-expert-one a joke" is answered back to the jester, not broadcast).
4. A participant that is not attached (no `receive` for `staleSeconds`) is **not** skipped
   silently: the message is kept, the sender is told in the transcript ("`jester` has not been
   attached since 14:02; message waits"), and delivery happens when it attaches.
5. Every message is in the conversation's transcript, whoever it was for; `chat` follows it.

### 4.5 Loops and cost

Agents mentioning each other forever is the main hazard, so it is bounded in the layer, not by
politeness in a prompt:

- **Hop limit** (`hopLimit`, default 6): a message whose hops would pass it is written, flagged,
  and **not delivered**; the conversation pauses and `chat` says so. A human message resets hops;
  `/continue` lets it run another `hopLimit`.
- **Message budget** (`messageBudget`, default 40 per conversation): the same, for a conversation
  with many humans or many parallel chains.
- **Rate**: a participant may not write more than N messages a minute (`rateLimit`, default 10).
- **Cost**: the layer cannot see a participant's spend except when the pump reads
  `total_cost_usd` from Claude's JSON **(docs read)**; it records it when there, and never guesses.
  The hop and message limits are the guard.

### 4.6 The store

A conversation is `conversations/<id>.jsonl` in the state volume: one JSON line per message
(`id`, `from`, `to`, `text`, `reply_to`, `hops`, `at`, `flags`), appended under `flock`, never
edited. A delivery is a file in `inbox/<handle>/`. The fields are the names of the register's
`messages` type (thread, message, mentions, `reply_to`, A2A task states), so a register backend is
a mapping.

**Is the store the agentic-register's `messages` register? Not for the first slice, and this is
what it lacks:**

| Lacks | Detail |
|---|---|
| A published home | `local-features/agentic-register` is vendored and not published; a published Feature cannot name it in `installsAfter` or pull it (CLAUDE.md, "Git here"). |
| Zero-ceremony identity | every writer needs a signing key and a roster entry added with an operator key (`key new`, `roster --add-key`), for each participant. Right for a ledger; too heavy for "download, add a participant, talk". |
| Attribution when the layer writes | the sender of an entry is its signing principal; the layer writing for a participant would show every message as the layer's, unless it holds each participant's key. |
| Delivery | unread markers per principal and a polling `watch --follow`, but no claimed delivery, no blocking receive, no "attached since". |
| Limits | no hops, budget or rate; no pause state. |
| Participants | no definition of one (the `agents` register type, an OASF record, is the nearest, and is a later home for participant records). |

What it has and the layer reuses by shape: group and direct threads, sub-threads, mentions as
principals, refs, A2A tasks (`ask`, `task-status`) for "do this and tell me when done". Later
slice: a `register` store backend (`FACILITATOR_STORE=register`) for engineers who run the
register, writing as each participant's own key, so a conversation can be signed, mirrored and
queried. Decision D3.

### 4.7 How you talk to it

- **Terminal:** `facilitator chat [conversation]` (task `facilitator:chat`, `interactive: true`):
  one line in, `@jester ...` routes; the transcript follows live. `/new group jester
  domain-expert-one`, `/new direct jester`, `/continue`, `/who`, `/quit`. Non-interactive forms
  for agents and scripts: `facilitator send --conv c1 --text '...'`, `transcript --conv c1 --json`
  (NFR-7).
- **From a Claude or Copilot session:** that session is a participant with the same MCP tools
  (`say`, `who`), so "ask @jester for a joke" from inside Claude Code is a tool call.
  The engineer's own interactive session can be `you`, attached, as well as the terminal chat.

## 5. Credentials

The layer holds **none**. A participant authenticates to its vendor the way its CLI does, started
by its harness: Claude Code's own login or `ANTHROPIC_API_KEY` **(docs read)**; Copilot's
`COPILOT_GITHUB_TOKEN`, `GH_TOKEN` or `GITHUB_TOKEN` or `copilot login` **(docs read)**; Gemini's
login or key **(not checked)**; a local model endpoint, none. The recommended way to supply a token to
a harness is OpenBao: the harness's launch command is `dcf-secret get <name>` into the process's
environment, so nothing is written to a file in git or to the state volume (ADR-0048). The Feature
never writes a vendor token, never reads one, and prints none (no environment dumps from
`check` or `status`; they list names only).

The layer's own secret is the **participant token**: `tokens/<handle>` (mode 600), which an MCP
entry passes as `FACILITATOR_TOKEN` so a participant can write only as itself. Honest limit: every
process of one Linux user can read every token, so this stops a mistake (one participant writing
as another), not an attacker; real separation comes from `agent-linux-user.md` (one user per
agent), and the sandbox of each CLI (`agent-least-privilege-inventory.md`). Conversations may hold
what people said; they stay in the volume and are never committed (section 6), and the transcript
export is a file the engineer chooses to write.

## 6. What the Feature installs and what it must not

Installs: the `facilitator` command (a router and an MCP server over stdio, `chat`, `pump`, the
model wrapper), the Feature Taskfile (NFR-2), `facilitator-setup` (state folders, idempotent,
never fatal; NFR-5), a state volume `facilitator-state-${devcontainerId}` at
`/var/lib/devcontainer-features/facilitator` (NFR-1). Nothing downloaded if the command is bash and
a stdlib interpreter already present, otherwise one runtime requirement (decision D7).

**Must not (NFR-13):** install, update or log in to any vendor CLI; edit their settings files or
their MCP config (it prints the entry; the engineer or the harness adds it); start, stop, restart
or resume any participant; run a supervisor; open a network port (stdio and files only); keep a
credential. The vendor CLIs come from their own Features or the engineer.

| Option | Default | What |
|---|---|---|
| `installTaskfile` | `true` | the Taskfile, as every Feature |
| `hopLimit` | `6` | section 4.5 |
| `messageBudget` | `40` | section 4.5 |
| `receiveWaitSeconds` | `300` | how long `receive` blocks |
| `staleSeconds` | `900` | after which a participant counts as not attached |

Settings are plain variables too: `FACILITATOR_FILE`, `FACILITATOR_HOP_LIMIT` and so on (NFR-6).

Tasks (`task facilitator:<task>`; first is `version`): `version`, `check` (file valid, state
writable, per-participant attachment seen, no secrets printed), `participants`, `status` (who is
attached, last seen, each conversation's hops), `chat` (interactive), `send`, `transcript`,
`snippet` (the MCP entry and persona sentence for a participant), `pump` and `model` (run by a
harness; documented, not started by a task), `export` (a conversation to Markdown).

Tests (NFR-10): Docker-free unit tests in `task lint`: the routing rules (4.4), the loop limits, the
file lock under concurrent writers, the MCP protocol over stdio (initialize, `tools/list`,
`receive` blocking and timing out), the participant file parser, and the **two fake attachments**
(a fake MCP client and a fake one-turn command with different capabilities) that NFR-12 asks for;
a list using only the fake pump must never call anything named `claude`. Feature scenarios
(`devcontainer features test`) check the install on the base images and idempotence. Real-vendor
tests are a manual checklist in `NOTES.md` (T1 above, then each vendor: attach, one message, one
reply, a hop limit), run with the engineer's own credentials; none runs in CI.

## 7. The `agents` Feature, and what to keep, replace or retire

The `agents` Feature (2.1.3) does **lifecycle**: one list (`agents.yml`), kinds
(`resident`, `on-demand`), a lease, session names, an adapter per CLI (`agent-adapter-claude`), and
integrations that give a session its environment. It has no concept of one agent talking to
another, which is what the Operator called an unguided attempt. With the harness ruling the line is
clean:

```
  harness (not ours): keeps them running      facilitator (ours): connects them
  - the agents Feature, tmux, a service       - addressing, routing, limits, record
  - starts, leases, resumes, stops            - never starts or stops anything
```

| Piece | Verdict |
|---|---|
| `agents` list, kinds, lease, verbs, session names | **Keep, unchanged.** It is one harness among several, the one already in the devhost for Claude. |
| `agents` integrations, the Copilot adapter slice (`agent-adapter-copilot`), the lease for non-Claude CLIs | **Stop growing** them for the sake of multi-vendor conversation; they remain valid for lifecycle. |
| `agents` as the answer to "run several vendors" | **Replace** in the docs: NOTES says "to have them talk, add the facilitator". |
| Retiring `agents` | **Not now.** Revisit after slice 2: if no consumer uses a lease, narrow it to a documented harness recipe. |

Migration for a consumer that uses `agents`: **none required**. To make an agent a participant they
add one `participants:` entry (with `agent: <name>` pointing at its `agents.yml` entry) and the MCP
snippet to that agent's persona; `agents` keeps starting it. `facilitator status` reads the agents
Feature's records only to show "running" beside "attached".

## 8. Slices

1. **Thin slice** (`facilitator` 0.1.0): participant file, the store, deterministic routing, direct
   and group, hop limit and budget, the MCP server (`receive`, `reply`, `say`, `who`), `chat`, the
   **model wrapper**, tests with fakes, one manual run: **Claude Code over MCP plus a local model**
   (the jester scenario), and T1.
2. **Second and third vendors**: Copilot CLI, then Gemini CLI, over MCP; the pump for each; NOTES
   and the per-vendor checklist (NFR-12 met with two CLI vendors).
3. **Register backend**, signed transcripts, tasks (`ask`) in conversations.
4. **Hardening**: per-agent Linux users and tokens (with `agent-linux-user`), a facilitator that
   summarises, transcripts to the shared folder.

**Out of scope:** supervising or starting participants; networking between containers or machines
(a later requirement: the same tools over a bridge, probably A2A, which the register's messages are
already shaped for); other people's agents; installing or logging in to vendor CLIs; billing or
price tables; a web UI.

## 9. Risks and open questions

- **The loop on `receive` may not hold** (T1): a model may stop looping, hit a tool timeout or
  burn tokens waiting. Mitigation: shorter waits, the pump; named, not hidden.
- **Prompt injection through a participant's message** reaches another participant as its input.
  The hop limit does not stop it; each CLI's sandbox and permissions do (the inventory).
- **Attribution is weak** with one Linux user (section 5).
- **Vendor drift**: tool names, flags and MCP config formats change; only the pump and `snippet`
  know them, and every vendor fact above has a date.
- **Transcript privacy**: conversations hold what people and models say; volume only, export on
  request.
- **A participant that answers slowly** holds its chain; no timeout on a reply in slice 1 beyond
  the human's `/continue`. Open.
- **Group etiquette**: many members and no facilitator-role participant means broadcast; bounded
  only by the limits. Open whether to require a facilitator for groups over three.

## 10. Decisions for the Operator

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | The primary attachment | (a) MCP with a blocking `receive`; (b) the pump everywhere (a one-turn command per message); (c) a pty bridge into the running TUI | **(a)**, with (b) as the per-vendor fallback; confirm with T1 before slice 2 |
| D2 | Who decides who speaks | deterministic `@mention` routing; a model decides every hop; hybrid | **Deterministic, the facilitator is any participant** (section 4.3) |
| D3 | The store | own JSONL now, register later; the register now; register required | **Own now, register backend in slice 3** (it is unpublished and needs keys per participant) |
| D4 | Where participants are defined | new `facilitator.yml`; a section of `agents.yml` | **New file**, with an optional `agent:` cross-reference |
| D5 | The `agents` Feature | keep; narrow; retire | **Keep unchanged, stop growing its multi-vendor slices, revisit after slice 2** |
| D6 | The Feature name | `facilitator`; `agent-facilitator`; `agent-chat` | **`facilitator`** |
| D7 | The runtime | Python 3.11 stdlib (as the register); a Go binary; bash only | **Python stdlib**, a stated requirement in NOTES; bash cannot hold the MCP server comfortably |
| D8 | Ship a local-model wrapper | yes, small; no, a participant brings its own | **Yes**: nothing else gives a bare model an attachment |
| D9 | Loop guards | defaults 6 hops, 40 messages, 10 a minute; other | **As written**, a human `/continue` extends |
| D10 | Identity | per-participant token files now; none; per-user later | **Tokens now**, per-user with `agent-linux-user` |
| D11 | Slice-1 vendors | Claude + local model; Copilot + local model; all three | **Claude + local model**, Copilot and Gemini in slice 2 |
| D12 | Transcripts | volume only, export on request; committed to the repo; shared folder | **Volume only**; shared folder later |

Decisions needed from the Operator: all twelve, and in particular D1 and D5.

## Architecture review

Not yet written: the `architecture-review` skill runs on this proposal before the Operator rules.
