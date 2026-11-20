# Proposal: a facilitator, the communication layer between agents of any vendor

Ruled 2026-11-19

Status: ruled by the Operator on 2026-11-19 (section "Ruling", below); the design sections are the
design to build, and nothing is built. Backlog id: `facilitator-agent`. It serves the Operator,
through the host, who ruled on it; and the persona the Feature is for: an engineer who downloads
a Dev Container Feature, gives it their own vendor credentials, and holds conversations with
several AI agents running in their devcontainer. Vendor facts are marked **(docs read)** when a
vendor page was read for this proposal, **(matrix)** when taken from the capability matrix of
`docs/proposals/agents-v2.md` section 14 (itself from docs, 2026-10-29), and **(not checked)** when
neither; AGNTCY facts are from the project's GitHub pages **(docs read)**, and slice 0 replaces the
unchecked ones. The proposal itself ran nothing; the slice-0 spike did ([the spike note](../spikes/2026-11-19-agntcy.md), 2026-11-19), and its findings are
in 4.8 and 8.

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

Later the same day, three more directions: run the AGNTCY components in the devcontainer (agents
register an OASF record in a directory), have agents **sign their messages** so provenance and
lineage can be verified ("maybe even using the sign-packet feature"), and make the facilitator "a
multi module agentic application that uses its llm model to help the orchestration and routing".
"AGNCY" is read as AGNTCY. **"sign-packet" is the AOF Feature of that name** (the Operator's answer,
2026-11-19): it is taken over into this repository with register-engine and packet-relay (4.6).

A last direction, the same day, reverses the first draft's treatment of the `agents` Feature: **the
goal is to deprecate it**; the `claude-code` and a Copilot Feature evolve to enrich the
experience; `agents` becomes an internal common component those Features use, exposing standard
interoperability endpoints that other Features, this one first, consume. Section 7 is that design.

Rulings it rests on: separate processes in one devcontainer; cloud agents only through a local
interface; networking out of scope; **NFR-12** (a contract for agent CLIs works on two vendors or
names its fallback; ADR-0037); **NFR-13** (manage the environment, not the CLI); **NFR-1, 2, 5, 6,
7, 8, 10** as for every Feature; ADR-0048 (OpenBao keeps every token).

The Operator's rulings of 2026-11-19 are in the section "Ruling" before the architecture review; the
design sections below already say what was ruled.

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

In the picture the sender named both handles, so routing is by rule. Had you written "get someone to
tell a joke to the expert", the router module (4.3) would have asked the facilitator model to choose
from the directory, written its choice as a packet, and gone on the same way. Every arrow is a signed
packet (4.7).

Nothing in this picture is started by the Feature: the two participants, and whatever keeps them
alive, are the harness's. The deterministic core (explicit mentions, limits, signing) runs in
whichever process calls a tool; the Feature's own infrastructure (4.8) and the application's `serve`
(4.3) carry the rest.

## 3. Concepts and names

Existing words kept: **agent**, **handle** (a participant's address), **resident agent**,
**harness** is new (below). **"Adapter" stays the agents Feature's `agent-adapter-<cli>`** (LEXICON,
"CLI adapter"); this proposal does not reuse it, so the new word for how a process connects is
**attachment**.

| Proposed term | Meaning |
|---|---|
| **Facilitator** (the Feature, and the application) | The Feature `facilitator`: the communication layer, and the **facilitator application** it ships: a set of modules (4.3), some deterministic, some assisted by the facilitator's own model. It is not a participant; it speaks in a conversation as the handle `facilitator`. |
| **Facilitator model** | The LLM the application uses to decide and summarise: a local OpenAI-compatible endpoint, a one-turn vendor command run with the engineer's token, or an attached participant. Pluggable (4.3). |
| **Packet** | One signed message: an entry of the `conversation` register type (register-engine), in the format and with the signature of **sign-packet** (4.6, 4.7). The Operator's word, and the AOF Feature's own. |
| **Directory** | The set of agent records (OASF) the participants registered; where the route planner reads skills from (4.8). |
| **Backend** | The one setting that says what carries directory and delivery: `agntcy` (the real AGNTCY Agent Directory and SLIM, the default, and the first to be built) or `lean` (packet-relay, the safety hatch). The record is register-engine's in both. The modules see one interface either way (4.8). |
| **Infrastructure** | What the Feature itself starts and owns: the directory and SLIM node in `agntcy` mode, and the facilitator application. Participants are never infrastructure. |
| **Participant** | A named, running process that takes part: a **handle** (`jester`), a definition (the CLI profile or system prompt it is started with, the list key `definition`, kept by the harness), an **attachment**, an optional model label shown in the transcript. The engineer at the terminal is a participant too (`you`, kind `human`, declared in `facilitator.yml`). |
| **Participant component** (the component) | Internal code shared by vendoring, never published as a Feature: who a participant is (the definition, persona and skills), its identity, adding the MCP entry to its CLI through the CLI's own command, and the optional run half (kinds, lease, session names, adapter verbs) that today is the `agents` Feature (section 7). The MCP server itself is not in it; it is in the facilitator Feature. |
| **Endpoint** | One of the component's contracts that a Feature may consume alone: E1 to E4 (7.4). |
| **Harness** | Whatever keeps a participant process running: tmux, a process supervisor, a service, the vendor's own session, the `agents` Feature. Not this Feature's job. |
| **Attachment** | How a running participant connects to the layer. Primary: **MCP** (tools `receive`, `reply`, `say`, `who`), served by the facilitator Feature. Fallbacks: the **pump** (a loop that does `receive` and runs the vendor adapter's `run-once` verb), and for a local model the **model wrapper**, which is the pump for the `openai-compatible` CLI adapter. |
| **Conversation** | A thread with members: **direct** (you and one participant, or two participants) or **group** (three or more). Held as a register of the `conversation` type: group and direct, A2A-shaped. |
| **Turn** | One message by a participant in a conversation. A turn's **hops** are the number of participant-to-participant deliveries since the last human message. |
| **Mention routing** | Delivery by `@handle` in the text or the `to` argument, always honoured; no mention is for the router module (4.3, 4.4). |
| **Bubbling up** | Every message lands in the conversation's transcript, which a human follows; a message with no mention returns to the participant that asked. |
| **Hop limit** and **message budget** | The two guards against agents mentioning each other forever (4.5). |

## 4. Architecture

```
 vendor Features (user-facing)   participant component (vendored, thin)           facilitator Feature
 claude-code  participants/attach  E4 definition  E3 identity  E1 attach (MCP entry)   application:
 copilot      participants/attach  + run half: kinds, lease, session names, adapters    intake, guard, router,
 gemini (later)                          |                                              route planner, dispatcher,
                                         |  participant processes, kept running by a    collector, MCP server
   claude (domain-expert-one) --MCP-->   |  harness                                     (receive reply say who)
   copilot, gemini ------------MCP-->    v                                              sign-packet signer,
   local model (openai-compatible) ----> `receive reply say who` ------------------->   E2 directory client
   you: `facilitator chat` ------------------------------------------------------->   backend interface:
                                                                                       directory | transport |
                                                                                       record (register-engine)
                                                                                       (agntcy | lean, 4.8)
```

Section 7 says which of these the Operator's "deprecate `agents`" puts where; the rest of this
section is the facilitator's side of the line. The thin agent side (who an agent is, its identity,
its MCP entry) is the component's and the vendor Features'; the MCP server and everything behind it is
the facilitator's.

### 4.1 The participant file

`.devcontainer/participants.yml`, committed, **owned by the participant component (7)**, path set by
`PARTICIPANTS_FILE` (NFR-6). It is the **same list as today's `agents.yml`**, one list not two, with
the same required keys (`name`, `cli`, `kind`) and the same optional ones (folder, args, lifecycle,
identity, lease, `session-name`, `definition`, default). Only three keys are added: `attachment`,
`description` and `skills`. During the deprecation `agents.yml` and `AGENTS_FILE` are still read as
aliases (7.2). The facilitator application's own settings (its model, the backend, the human member,
the participant that is the fallback facilitator) go in a separate `.devcontainer/facilitator.yml`,
because only the facilitator reads them. In the example, `facilitator.yml` is the first block and
`participants.yml` the second:

```yaml
facilitator:                       # facilitator.yml: the application's own settings (4.3)
  model:
    cli: openai-compatible         # or: claude | copilot | gemini (the adapter's run-once verb)
    args: "--endpoint http://localhost:11434/v1 --model llama3.2"   # or: participant: copilot-lead
  fallback: copilot-lead           # at most one; gets what is addressed to no one when the application is not running
  humans: [you]                    # the engineer at the terminal (kind human)
participants:                      # participants.yml: the shared list
  - name: jester                   # the handle; letters, digits, - and _
    cli: openai-compatible         # a local model is a CLI adapter, shipped by the facilitator (D4, D8)
    kind: resident
    args: "--endpoint http://localhost:11434/v1 --model llama3.2"
    definition: personas/jester.md # the persona: the text sent as system prompt
    attachment: mcp                # mcp | pump
    description: tells jokes       # the OASF record (4.8), read by the router and route planner
    skills: [humour]
  - name: domain-expert-one
    cli: claude                    # the run half starts it (the harness); the facilitator never does
    kind: resident
    attachment: mcp                # the participant's own CLI calls the tools
  - name: copilot-lead
    cli: copilot
    kind: resident
    attachment: mcp
```

For an `mcp` participant the definition lives with its harness (its CLI's own profile or prompt); the
component prints the sentence to add to it (`task agents:snippet -- <name>`) and the vendor Feature's
`attach` option adds the MCP entry through the CLI's own command (7.3), because nothing may edit a
vendor's configuration by hand (NFR-13). The jester is a participant of `cli: openai-compatible`, and
the local-model adapter's `receive` loop is the model wrapper of D8.

### 4.2 Attachment: one primary, a fallback per vendor

A running agent is idle until something gives it a turn, and MCP is call-and-response: a server
cannot wake a model. So the primary attachment makes the agent **ask for its mail**: the MCP tool
`receive` blocks on the participant's inbox (up to `receiveWaitSeconds`, default 300) and returns
the next message or "nothing yet"; the definition says "loop: `receive`, answer with `reply`,
`receive` again". Every MCP-capable CLI can do that with the same four tools, so the contract is one
contract (NFR-12). The MCP server is the facilitator Feature's (`facilitator mcp`, stdio); the vendor
Feature only adds the entry that names it, through the CLI's own command (7.3).

| Participant | Primary attachment | Fallback (the vendor has no usable long-running form) |
|---|---|---|
| Claude Code | MCP: `--mcp-config` or a configured server **(docs read)**; MCP servers load under `-p` when named on the command line **(docs read)** | pump: a loop of `receive` and `agent-adapter-claude run-once`, which runs `claude -p "<prompt>" --output-format json`, then `--resume <session_id>`; the JSON carries `result`, `session_id` and `total_cost_usd` **(docs read)**; `--append-system-prompt` for the definition **(docs read)** |
| GitHub Copilot CLI | MCP: `copilot mcp` manages its servers **(docs read)**; the Agent Client Protocol, `copilot --acp --stdio` (public preview), is documented and its `session/new` carries MCP servers, with a public report that they were not loaded; not run, **(docs read, [the spike note](../spikes/2026-11-19-agntcy.md))** | pump through `agent-adapter-copilot run-once`: `copilot -p` with `--resume <id or name>`, `--allow-all-tools`, `--no-ask-user` **(matrix)**; auth by `COPILOT_GITHUB_TOKEN`, else `GH_TOKEN`, else `GITHUB_TOKEN`, a fine-grained token with the "Copilot Requests" permission, or `copilot login --with-token` **(docs read)** |
| Gemini CLI | MCP servers from `mcpServers` in its settings **(docs read, [the spike note](../spikes/2026-11-19-agntcy.md))**; the Agent Client Protocol, `gemini --acp`, is documented, and whether an `--acp` session reads `mcpServers` is not stated; not run | pump through `agent-adapter-gemini run-once`: `gemini -p`, `--output-format json` gives `response` and `stats` with no session id; the `stream-json` `init` event carries it **(docs read)**; `--resume latest\|index\|uuid` **(matrix)** |
| Local model (Ollama, llama.cpp server) | the CLI adapter `openai-compatible`, which the facilitator ships: its `receive` loop (the **model wrapper**, needing no model loop) calls the server's OpenAI-compatible chat endpoint with the definition and the conversation so far, and `reply`s. Ollama serves `/v1/chat/completions` **(not checked)**; llama.cpp's server is OpenAI-compatible **(not checked)**; the endpoint is stateless, so the wrapper keeps the messages | none needed |
| Cloud agent behind a local CLI or MCP | whichever of the rows above its local interface is | pump |

The pump carries no vendor flags: they are in each vendor's `agent-adapter-<cli>` and its optional
`run-once` verb (ADR-0037, exit 3 when absent), so the facilitator knows no vendor.

How a participant **replies and mentions others**: through the tools, not by parsing its output
(parsing a TUI's output is how an attachment breaks with each vendor release). `reply(text, to?)`,
`say(conversation, text, to)` (starts or joins a turn in another conversation) and `who()` (the
handles, so a participant does not invent one). The pump parses nothing either: it takes the
one-turn command's whole stdout as the reply to the asker, and a participant that wants another
recipient writes `@handle` at the start, the one text rule (section 4.4).

**What is not known and must be tested first (T1, manual, slice 0).** Whether each vendor's model
keeps looping on a blocking tool for hours: tool-call timeouts, context growth (every message adds
tokens), and idle cost. The **Agent Client Protocol** (a client drives an agent session and hands it
prompts; Copilot `--acp` and Gemini `--experimental-acp` in the matrix) is tried in the same run on
Copilot and Gemini, beside MCP, because it answers "a server cannot wake a model" natively. The design
degrades by configuration: `receiveWaitSeconds` shorter, or the pump instead. T1 on Claude Code (and
the ACP trial) decides the primary for the other vendors (decision D1, ruled: MCP with a blocking
`receive`, the pump as fallback). A turn hook that shows unread mail at each turn is a
vendor-specific optimisation, never the contract.

### 4.3 The facilitator application: modules, and what the model decides

The Operator's direction is a multi-module application whose own model helps orchestrate and route,
not only an `@mention` matcher. **Recommended: an explicit `@handle` is always routed by rule and
the model can never redirect it; the model fills the gaps** (nobody addressed, a request to break
up, many replies to join), and everything it decides is written as a packet, so a human can see and
veto why a message went where it did.

```
 intake -> guard -> router ----> route-planner* -> dispatcher -> (participants, via transport)
   |         |        |  \          |                |                 |
   |         |        |   directory client            |  <---- replies -+
   |         |        |                               v
   |         |        +-----------------------> collector/summarizer* -> bubbled up to you
   +---------+-------------------- signer (every packet) -------------------------------+
   * = LLM-assisted, through the model gateway        (all others deterministic)
```

| Module | Does | Deterministic or model |
|---|---|---|
| **Intake** | Authenticates the writer (token), parses `@handles`, attaches the conversation and its recent messages | deterministic |
| **Guard / limits** | Hop limit, message budget, rate, the facilitator's own model-call budget, pause and `/continue` (4.5) | deterministic, and runs at write time even when the application is not running |
| **Router** | Explicit mentions: by rule. Unaddressed in a group, or "someone should...": asks the model to choose handles **from the directory's list only** (an enumerated answer, validated; anything else is discarded and the fallback below used) | rule first, model for gaps |
| **Route planner** (`route-planner`) | Breaks a request into sub-asks (`ask`, an A2A task per assignee), writes the plan to the transcript as a packet; a human may `/veto` it before dispatch (default off for 1 to 3 sub-asks) | model |
| **Dispatcher** | Writes deliveries, tracks each task's state (`submitted` to `completed`), re-asks or marks `failed` on a timeout, never delivers past the guard | deterministic |
| **Collector / summariser** | When the sub-asks are done (or timed out), joins the replies into one message to the asker, each claim with a `ref` to the packet it came from | model (a plain concatenation is the fallback) |
| **Directory client** | Reads the registered agent records: handle, description, skills; feeds the router and route planner (4.8) | deterministic |
| **Signer** | Signs every packet, the facilitator's own included (4.7) | deterministic |
| **Model gateway** | One interface, `complete(prompt, schema) -> text`; backends below | deterministic code around a model |

**The facilitator model is pluggable** (`facilitator.yml`, `model:`): `cli` (a vendor's
`run-once` adapter verb, run with the engineer's own token: `claude`, `copilot`, `gemini`, or
`openai-compatible` for a local OpenAI-compatible endpoint, credentials none **(docs read, section
4.2)**), or `participant: <handle>` (an attached participant answers as a normal turn, so the
facilitator can be a vendor session someone already runs). There is no default model (D15). The call
is a stateless decision, so it needs no session and no harness; it is the application's own use of the
CLI through its adapter, not management of it (NFR-13).

**The application is optional at run time, and does not have to be running for the deterministic core.** `facilitator serve` is one more long-running process,
and, unlike a participant, **the Feature runs it**: it is part of the infrastructure of 4.8 (`autostart`
runs it from `postStartCommand`; a harness may run it instead). Without it, explicit mentions,
direct conversations, the guard and the signer work, because they run in whoever writes; unaddressed
group messages then use the fallback in 4.4. This keeps the deterministic core independent of any
model and testable without one.

**Guard against the model's own failure modes.** Message text reaches the model as data inside
delimiters and never as instructions; its answer is parsed against a schema; a handle that is not
in the conversation is dropped; its calls count against a budget (`facilitatorBudget`, default 20
model calls per conversation) and each is recorded with its prompt hash. A prompt-injected message
can make the router pick a wrong *member*; it cannot add a member, exceed a limit or edit a packet.

### 4.4 Routing rules

1. `@handle` in the text (or `to`) delivers to that participant, each mention once. `@all` delivers
   to every member of a group.
2. A message with no mention in a **direct** conversation goes to the other member. In a **group**
   it goes to the router module when the application runs (4.3); otherwise to the participant
   marked `facilitator: true`, else to every member, which the hop limit then bounds.
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
- **The facilitator's own model calls** are counted and capped (`facilitatorBudget`, 4.3).
- **Cost**: the layer cannot see a participant's spend except when the pump reads
  `total_cost_usd` from Claude's JSON **(docs read)**; it records it when there, and never guesses.
  The hop and message limits are the guard.

### 4.6 The store, and what a packet is

**The record is register-engine's, and the register Features come from AOF into this repository.**
The Operator's ruling takes over three AOF Features, published from `src/` here (backlog
`aof-features-takeover`, in progress):

| Feature | Version taken | Role in the facilitator |
|---|---|---|
| **sign-packet** | 0.5.1 | the signer and the packet format, **from the first version**: every packet is signed from day one, there is no unsigned mode |
| **register-engine** | 0.2.0 | the conversation record: a thread is a register of the **`conversation` type**, a packet is one entry in it. The facilitator supplies the type if the engine has none (the Operator: "we own it, add it if it's not there") |
| **packet-relay** | 0.3.0 | the `lean` hatch's transport (replacing the inbox files), and the later cross-container path |

**agentic-register and agentic-a2a are not taken now.** The devhost keeps its vendored agentic-register
(`local-features/agentic-register`) for the ledger; the facilitator does not use it. The `conversation`
type keeps the field names the old `messages` type had (group and direct, sub-threads, mentions as
principals, `reply_to`, `refs`, A2A tasks), so nothing is invented that the register already did. A
packet is a body of canonical JSON, hashed and signed, whose writer is verified against a roster.
Because the three Features are published from this repository, a downloader can name them
(`installsAfter` or `dependsOn`: slice 1 settles which, from their manifests); there is no longer a
blocker about the register being unpublished. What the three do not do, and so what the Feature adds
around them:

| Lacks | What the Feature adds |
|---|---|
| A `conversation` type, if register-engine has none | the type, owned here, added to register-engine |
| Zero-ceremony identity: every writer needs a key and a roster entry | `facilitator register` does it for a participant at registration (4.7) |
| Delivery: no blocking receive or "attached since" | the transport of 4.8 (SLIM in `agntcy`, packet-relay in `lean`); `receive` blocks on it; the record stays register-engine's |
| Limits: no hops, budget, rate or pause | the guard module; hops and the root message id are carried in the packet's `data` part |
| A model in the loop | the modules of 4.3; their decisions are packets of kind `message` from the handle `facilitator` |
| Participant definition | the directory (4.8) |

**Where conversations live (D12, ADR-0045).** In the Feature's state volume, as **working data**: lost
with the machine, never committed. The shared folder (tier 2) is a later item and needs a
register-engine mirror for the `conversation` type. Switching `backend` loses no conversation, because
the record is the same in both.

### 4.7 Identity, signing and lineage

**Who signs.** Every packet is signed with **sign-packet**, from the first version, by an identity
key: one per participant, one for `facilitator`, and the human's operator key. The facilitator verifies
and never writes an unsigned packet.

**Where the key lives, so the participant process does not hold a long-lived private key.** The
**signer module** signs on the participant's behalf, **after authenticating it by its participant
token** (4.2, section 5). The participant, a model reached by MCP, never sees a private key: it
asks `reply`, the signer signs. Keys are kept in OpenBao (ADR-0048, the master of every private
key) under `facilitator/keys/<handle>` and loaded into an ssh-agent for the sitting (the `ssh-agent`
Feature, key loading per `secrets-master-split.md`; how sign-packet takes a key from an agent is for
slice 1 to confirm). So the private half is in the agent's memory for a sitting and in OpenBao at
rest, in neither a file nor a participant. A harness that wants end-to-end signing may instead give a
participant its own key; the layer then verifies the signature and signs nothing for it.

**What this proves, and what it does not.** A valid packet proves that the key registered for
`jester` signed this exact body, in this chain, and that nobody changed or reordered it. With the
signer module it attests that the layer authenticated the participant's token at that moment: it
does not prove the model *meant* it, and a process that can read another participant's token (the
same Linux user, section 5) can write as it. Provenance here means "which registered identity, via
which authenticated route", not a hardware attestation.

**Lineage** is expressed with fields the `conversation` type has, so `verify` can walk it:

| Link | Field |
|---|---|
| what a message answers | `reply_to` (a message id) |
| what it derives from (a summary's sources, a sub-ask's origin) | `refs` (`thread:message_id`) |
| the human request the chain began with | the root message id, in the packet's `data` and as the last `ref` |
| a request and its outcome | `task_id`, the A2A task and its `status` entries |
| why it went to this recipient | a `facilitator` packet (route, plan) that `refs` it |

**How a chain is proved.** sign-packet's verification checks every packet's signature and register-engine
checks its place in its writer's chain and its roster. On top of them a new command,
`facilitator verify --conv <id> [--message <id>] [--format json]`, walks `reply_to` and `refs` from a
message back to a human-signed root, and for each hop checks: the signer is on the roster and is the
`from` the packet claims; the hop count is within the limit; the parent exists and is in the same
conversation or a referenced one; every summary `ref`s packets that exist. It prints the chain, one
line a hop, and exits 0 (a good chain), 1 (a break) or 2 (bad usage) (NFR-11 shape). It is a query
over the record, not a new format.

### 4.8 Backends: the real AGNTCY components, or lean

**The Operator's ruling (2026-11-19): start with AGNTCY, "that way we lead with its
requirements/environment, not the other way around."** The first version runs on the real AGNTCY
components (the Agent Directory and SLIM) and the environment is designed around their requirements;
where simplicity and exercising AGNTCY as designed pull apart, this design chooses AGNTCY and names the
cost. `lean` stays as the safety hatch for simpler uses (slice 5), and the ruling rejects shipping
`lean` as the default until the AGNTCY backend exists.

The facilitator's modules talk to **one backend interface of three parts**, so participant names,
`@mentions` and signed lineage are the same in both modes:

| Part | Does | `agntcy` mode (default, built first) | `lean` mode (the hatch) |
|---|---|---|---|
| **directory** | register, look up and list agent records (OASF) | the Agent Directory (`dir`) | register-engine's `agents` type (slice 1 confirms the engine has one, else the facilitator adds it) |
| **transport** | deliver a packet to a participant, block in `receive`, group sessions | SLIM | **packet-relay** |
| **record** | the signed, append-only conversation and its verification | **register-engine** (`conversation` type), signed by **sign-packet** | the same |

AGNTCY has no conversation store and signs nothing of ours, so the record is register-engine's in
both modes. That is what makes the hatch cheap: **switching modes loses no conversation**, only moves
directory and delivery. AGNTCY also carries A2A and MCP over SLIM (the `slim-a2a-*` and `slim-mcp-*`
packages; **run in the spike:** `slima2a` needs `slim-bindings` 3.x, but PyPI's `slim-mcp` 0.2.3 is pinned to bindings 1.4, fails against the 3.4.6 node, and worked only with 3.x bindings and a one-line patch, so it needs a patch or a fork); these are the protocols to use wherever a protocol over SLIM is wanted, including the later
cross-container path.

**Components, what each needs, and how the Feature gets and starts it** (all from the projects' GitHub
pages **(docs read)** unless marked; versions are those pages' latest at 2026-11-19 and are pinned
in the Feature, not floated):

| Component | Used for | Obtained (NFR-3: pinned, checksum-verified, through the shared download helper `dcf_curl`, ADR-0034) | Runs as | Needs | Maturity, licence |
|---|---|---|---|---|---|
| **Agent Directory** `dir`, CLI `dirctl` | OASF records, discovery, record signing and provenance | release binary of v1.9.1, one static file per platform (`dirctl-linux-amd64` 198 MB, `dirctl-linux-arm64` 184 MB exist; **run, [the spike note](../spikes/2026-11-19-agntcy.md)**). **No checksum file and no per-asset signature**: the SHA-256 comes from the release API and from the SLSA provenance file `dirctl-v1.9.1.intoto.jsonl` (both matched the download), so the Feature pins the SHA-256 itself | `dirctl daemon start`: apiserver and reconciler in one process, embedded SQLite, `127.0.0.1:8888`, state under `~/.agntcy/dir/` by default and under whatever `--data-dir` says (the Feature passes its volume). **Run:** about 150 MB RSS, 0.2 to 1.3 s to start; it also opens `5555` (OCI, loopback) and, **to all interfaces by default, `8999` (libp2p) and `8889` (HTTP gateway)**, which the Feature must set to loopback in `daemon.config.yaml`; a push is validated against `https://schema.oasf.outshift.com` unless `policy.operations` is emptied ([the spike note](../spikes/2026-11-19-agntcy.md)) | no Docker (the Compose route, with Zot and PostgreSQL, is not used) | v1.x (`v1.9.1`, 2026-11-18), no maturity statement; Apache-2.0; OpenSSF badges |
| **SLIM** node, `slimctl` | the transport: named routing, sessions, group membership, end-to-end MLS | slimctl v3.4.6 tarballs (gnu and musl, linux amd64 and arm64 both exist) with a `.sigstore.json` per asset, **verified for amd64 and arm64 by identity** (no checksum file; the release API digest matched). **There is no node binary among the release assets: the node is `slimctl slim start`** (an image `ghcr.io/agntcy/slim` also exists, `3.5.0` is `latest` with no release yet) ([the spike note](../spikes/2026-11-19-agntcy.md)) | `slimctl slim start --config <server config>` as a background process on `127.0.0.1:46357`; **run:** basic auth over plain-text loopback worked (a warning is logged, a wrong password is refused), about 20 MB RSS, 80 ms to start, no state on disk; other modes offered: JWT, mTLS, SPIFFE; the Feature picks basic auth with a generated secret kept in OpenBao | none for the node; **clients** (the MCP server instance, `chat`, the wrapper) use the `slim-bindings` Python package, a native wheel: PyPI has `3.3.9` (it reports node 3.4.6), one `py3-none` wheel each for manylinux_2_28 and musllinux_1_2 on **x86_64 and aarch64**, and `pip --require-hashes` worked. A message between two Python clients and a 3-member MLS group ran through the node ([the spike note](../spikes/2026-11-19-agntcy.md)). **`slim-bindings` is pinned with hashes through the shared download helper, or the exception to ADR-0034 is recorded in the ruling's ADR** | v3.x; Apache-2.0; no maturity statement |
| **AGNTCY Identity** (issuer CLI, node, badges, DIDs) | verifiable agent badges, bringing an existing ID | the CLI by its install script; the node by `launch_node.sh` | needs **Docker** | Docker-in-Docker, which does not start on every host (`wslc`) | docs read in the spike: releases `v0.0.25` and `v0.0.26` (a `v1.0.0-beta.1` tag exists), signed binaries for linux amd64 and arm64, the node **still needs Docker** (Compose with PostgreSQL); Apache-2.0. **Not default**: opt-in `identity: true`, slice 7 (D17) |
| **Agent Connect Protocol** | a REST interface to invoke a remote agent | not used | n/a | n/a | the repository's last change was May 2025 and its SDK was archived in June 2025; AGNTCY now carries **A2A and MCP over SLIM** (`slim-a2a-*`, `slim-mcp-*`), which is what to use in its place |

**How the Feature starts them** (infrastructure it owns, the opposite of participants):
`facilitator infra up|down|status|logs` start the directory daemon and the SLIM node as background
processes with a pidfile, a log and a health check under `/var/lib/devcontainer-features/facilitator/{dir,slim}`;
`autostart` (default `true` in `agntcy` mode) runs `infra up` and the application from
`postStartCommand`, never fatal. Ports bind to loopback only, and a port in use fails `check` with
the owner's name. The Feature restarts neither on crash; `status` says so, and `up` is idempotent.

**What you learn running it** (a note per component for `NOTES.md`):

- **dir**: what an OASF record is when it is real (a record's identity and digest, skills as a
  taxonomy), how records are stored (OCI) and signed, what `dirctl` can search; the cost is one more
  daemon and a records workflow to learn.
- **SLIM**: addressing by hierarchical name, sessions and group membership, MLS (the group keys
  change as members join and leave); the cost is a Rust node, a native client library, and a
  channel model that differs from "write a file".
- **Identity** (opt-in): how an agent badge binds a key to an OASF record; the cost is Docker.
- **Both together**: where AGNTCY stops (no conversation store, no limits, no model), which is
  exactly what the facilitator application adds.

**What is lost in `lean` mode:** AGNTCY's discovery API and any publishing to other directories;
SLIM's named sessions and its end-to-end encryption (lean delivery is packet-relay's, readable by the
same Linux user); streaming delivery (packet-relay waits); the directory's record signing and
provenance; readiness for AGNTCY-shaped cross-container paths (packet-relay is itself the later
cross-container path of the lean setup). **Kept:** participant names, `@mentions`, groups, signed
lineage and `facilitator verify`, the OASF records themselves (register-engine stores OASF 1.1.0 and
`facilitator directory export` prints the pure records).

**Switching:** `backend` option, or `FACILITATOR_BACKEND=lean` in `.env`, then `facilitator backend
switch lean|agntcy`: it stops the infrastructure it owns, re-registers each participant's OASF
record in the other directory (the same record), points the transport at the other mechanism, and
leaves every conversation as it is. There is **no silent fallback**: if `agntcy` cannot start,
`check` says why and offers the switch, so nobody believes they run AGNTCY when they do not.

**What could force the hatch** (listed as risks in section 9): components too young or churning,
resource weight, no linux arm64 build, authentication set-up, a host without Docker for Identity.
The hatch is built in slice 5; until then, a host where `agntcy` cannot start has the spike's findings
and `check`, not a switch.

### 4.9 How you talk to it

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

The facilitator model's credential is the same kind of thing: an `endpoint` needs none; a `command`
(`copilot -p`) uses the token its harness set in the environment of `facilitator serve`, from OpenBao
as above. The **identity keys** of 4.7 are the one secret the layer asks for, and it asks OpenBao
(`dcf-secret`, ADR-0048), never a file in git or in the state volume.

The layer's own secret is the **participant token**: `tokens/<handle>` (mode 600), which an MCP
entry passes as `FACILITATOR_TOKEN` so a participant can write only as itself. **This is a written
exception to ADR-0048** (OpenBao is the master of every token): the tokens are made at each container
start, valid only in that container, and worthless outside it; the exception is recorded in the
ruling's ADR (7.2). Honest limit: every process of one Linux user can read every token, so this stops a
mistake (one participant writing as another), not an attacker; real separation comes from
`agent-linux-user.md` (one user per agent), and the sandbox of each CLI
(`agent-least-privilege-inventory.md`). Conversations may hold what people said; they stay in the
volume as working data and are never committed (section 6), and the transcript export is a file the
engineer chooses to write.

## 6. What the Feature installs and what it must not

**Scope after the component (7): the facilitator Feature is the facilitator application, the MCP
server, and the AGNTCY or lean infrastructure, and nothing about vendors.** It pulls sign-packet,
register-engine and packet-relay (4.6) and consumes the component's endpoints. Installs: the
`facilitator` command (the modules of 4.3, an MCP server over stdio, `chat`, `pump`, the
`openai-compatible` adapter with its model wrapper), the Feature Taskfile (NFR-2), `facilitator-setup`
(state folders, idempotent, never fatal; NFR-5), the two AGNTCY binaries (pinned, checksum-verified
through `dcf_curl`, NFR-3: `dirVersion`, `slimVersion`) and the `slim-bindings` package (a pinned
requirement with hashes, or the recorded ADR-0034 exception), a state volume
`facilitator-state-${devcontainerId}` at `/var/lib/devcontainer-features/facilitator` (NFR-1). It plugs
into the run half as the integration `agent-integration-facilitator` (ADR-0036: `env` hands a
participant its `FACILITATOR_TOKEN`, `before-start` registers it); there is no `services.d/` folder.
The command needs a Python 3.11 runtime (decision D7), which is why the vendor Features, which stay
bash, do not carry the MCP server. The `lean` hatch downloads no AGNTCY binary.

**Must not (NFR-13):** install, update or log in to any vendor CLI; edit their settings files or
their MCP config except by the CLI's own command (done by the vendor Feature's `attach`, 7.3); start,
stop, restart or resume any participant; run a supervisor **for participants** (only for its own
infrastructure, 4.8); open a network port beyond the loopback ports of its own infrastructure; keep a
vendor credential. The vendor CLIs come from their own Features or the engineer.

| Option | Default | What |
|---|---|---|
| `installTaskfile` | `true` | the Taskfile, as every Feature |
| `hopLimit` | `6` | section 4.5 |
| `messageBudget` | `40` | section 4.5 |
| `receiveWaitSeconds` | `300` | how long `receive` blocks |
| `staleSeconds` | `900` | after which a participant counts as not attached |
| `facilitatorBudget` | `20` | model calls the application may make per conversation |
| `backend` | `agntcy` | `agntcy` (real Agent Directory and SLIM) or `lean` (packet-relay); the safety hatch (4.8). `FACILITATOR_BACKEND` overrides |
| `dirVersion`, `slimVersion` | pinned | the AGNTCY release to install; `latest` says what it resolves to (NFR-3) |
| `identity` | `false` | also run AGNTCY Identity (needs Docker) |
| `autostart` | `true` | `postStartCommand` runs `facilitator infra up` and `serve`, never fatal; participants are never started |

There is no signing option: signing is always on (4.7). Settings are plain variables too:
`FACILITATOR_FILE`, `FACILITATOR_HOP_LIMIT` and so on (NFR-6). `facilitator backend switch` must not
persist a backend that disagrees with the option or the variable.

Tasks (`task facilitator:<task>`; first is `version`): `version`, `check` (file valid, state
writable, per-participant attachment seen, no secrets printed), `participants`, `status` (who is
attached, last seen, each conversation's hops), `chat` (interactive), `send`, `transcript`,
`infra` (up, down, status, logs), `backend` (show, switch), `register` (a participant's OASF record, key and roster entry), `directory` (list, export), `verify` (4.7), `serve` (the application, which the Feature runs as infrastructure: ruling Q2), `snippet` (the persona sentence and the MCP entry for a participant), `pump` and `model` (run by a
harness; documented, not started by a task), `export` (a conversation to Markdown). `chat` is
`interactive: true`, and `send` and `transcript --json` take `CLI_ARGS` (NFR-7).

Tests (NFR-10): Docker-free unit tests in `task lint`: the routing rules (4.4), the loop limits, the
file lock under concurrent writers, the MCP protocol over stdio (initialize, `tools/list`,
`receive` blocking and timing out), the participant file parser, and the **two fake attachments**
(a fake MCP client and a fake `run-once` adapter with different capabilities) that NFR-12 asks for;
a list using only the fake pump must never call anything named `claude`; the model gateway with a fake model (the router cannot pick a handle outside the conversation, the budget stops it, an injected message cannot add a member); a signed chain verifies, and a tampered packet, a wrong signer and a broken `reply_to` each fail `facilitator verify`. Feature scenarios
(`devcontainer features test`) check the install on the base images and idempotence; the
`.github/workflows/test.yaml` matrix is a hand list, so `facilitator` and `copilot` are added to it,
and a scenario with `participants: true` has Python only if the Feature that needs it brings it (the
base images have no `python3`). Real-vendor tests are a manual checklist in `NOTES.md` (T1 above, then
each vendor: attach, one message, one reply, a hop limit), run with the engineer's own credentials;
none runs in CI.

## 7. Deprecating `agents`: a shared component, and the vendor Features that use it

**The Operator's ruling (2026-11-19):** deprecate the `agents` Feature; the `claude-code` and a
Copilot Feature evolve to enrich the experience; `agents` becomes an internal common component those
Features use, so that standard building blocks exist and interoperability endpoints are exposed for
other Features, this one among them.

### 7.1 What `agents` is today, and what it becomes

`agents` 2.1.3 does lifecycle: the list, kinds, a lease, session names, an adapter per CLI
(`agent-adapter-claude` ships in `claude-code`), `task agents -- <name>`, the container-start
`agents up`, and the verbs the workstation launcher (`task devcontainer:agent`) calls inside the
container. It was **never a conversation layer**. Split in two halves, which is also the line
between "the harness" and "the communication":

```
  run half (a harness; optional)               thin agent side (the component; what vendor Features carry)
  kinds resident / on-demand                    E4 participant definition (the list and its three new keys)
  lease, session names                          E3 identity (handle, token, key name in OpenBao)
  adapter verbs: start wake attach stop ...     E1 attach (the MCP entry, added through the CLI's command)
  `agents up` at container start
                                                in the facilitator Feature, not here: the MCP server,
                                                E2 directory registration, signing (sign-packet)
```

The run half is kept because the host and the workstation launcher depend on it, and moves into the
component. The connect half is new. Neither is a user-facing Feature.

### 7.2 The deprecation path (nothing breaks without a major version)

The deprecation convention is written in CONTRIBUTING (D21, ruled), citing the precedent the README
already sets (`claude-host`, `devcontainer:claude` and `devcontainer:ssh-key-import` deprecated with
one printed line and removed at the next major; ADR-0048 keeps `DCF_HOST_SSH_AGENT=key` "for one
major"): a Feature or option is deprecated in a **minor** (a notice from `version` and `check`, in
NOTES, and under "Deprecated" in the CHANGELOG, behaviour unchanged) and removed only in the next
**major**.

| Release | What changes | What a consumer does |
|---|---|---|
| `agents` 2.2.0 and `claude-code` (next minor) | the component is extracted; `claude-code` gains `participants` (7.3), which installs it; `agents` says in one line "deprecated, use claude-code `participants: true`" and, when the component is already installed by `claude-code`, installs nothing of its own. **Task names (`task agents:*`), the `agents` command, `AGENTS_FILE` and `.devcontainer/agents.yml` are unchanged.** | nothing is required. To move: set `"participants": true` on `claude-code`, remove the `agents` reference, optionally rename the file to `participants.yml` |
| `agents` 2.x | bug fixes only, no new keys; the new participant keys land in the component and are read from `participants.yml` or `agents.yml` alike | as above |
| `agents` 3.0.0 (the retirement) | installs nothing and prints where to go; `:2` stays in the registry. Released only when: (a) `claude-code` has carried the component for at least one release; (b) the office and DSNP, the documented adopters of `agents` (their `.devcontainer/DEVCONTAINER_CONTRIBUTION.md` says what each adopts; this repository sees their use only through that and the reference architecture), have moved; (c) the `devcontainer-cli` launcher's `devcontainer:agent` tasks are shown to work on the component alone; the Operator starts that release | remove the `agents` line if still there; `agents.yml` keeps working until the component's own next major |
| the component's next major | `agents.yml` and `AGENTS_FILE` aliases removed, and the `agents:` task namespace gets a `participants:` alias or replacement | rename the file and the settings (a CHANGELOG note in each vendor Feature) |

This repository's own devhost moves first (`.devcontainer/devcontainer.json` lists `./features/agents`
today). **One ADR records this ruling: ADR-0061, "The facilitator is built on AGNTCY first, the MCP
connection is split in two, and the agents Feature moves into a shared participant component".** It names and, where needed, supersedes in
part: ADR-0036 (the lease and integrations stay, in the component), ADR-0037 (the Feature name
`copilot-cli` becomes `copilot`; the contract tests run against the component), ADR-0041 (the session
name was rendered by the agents Feature from its `sessionName` option: the ADR gives it a home, a
vendor Feature option or the list key `session-name` alone), ADR-0025 (`components/` is a new top-level
folder class beside `local-features/`), ADR-0045 (conversations are working data, tier 4, until the
shared-folder mirror), ADR-0048 (the written exception for participant tokens, section 5), ADR-0034
(`slim-bindings` pinned through the shared download helper, or the exception recorded), and the
recorded decision "MCP: none for now" in `docs/principles/non-functional-requirements.md`
(`facilitator` is the first published Feature to offer an MCP server).

### 7.3 Where the component lives, and how vendor Features use it

`src/common` is itself a published Feature of **single shell helpers** (`dcf-persist.sh`,
`dcf-curl.sh`) that `task common:sync` copies verbatim into every Feature that uses them, because a
published Feature folder must be self-contained; `task common:check` (in `task lint`) fails when a
copy drifts. The component is a multi-file package with its own tests and version, not a helper.
**Recommended: the same pattern in directory form, in a new top-level `components/participant/`
(no `devcontainer-feature.json`, so never published on its own), with `task components:sync` and
`components:check` beside the common ones, and a `COMPONENT_VERSION` file.** Putting it in `src/common`
would make a tiny-helper Feature carry a Python package and its tests, and make a folder
that looks like a Feature but is not. (How the release workflow and the test globs treat a
folder under `components/` is not checked; it is outside `src/`, which they enumerate.)

Each vendor Feature carries a vendored copy and installs it **idempotently into one place**
(`/usr/local/lib/dcf-participant`, the same `agents` and `participant` commands on PATH, the same
Taskfile include) so two vendor Features installing it leave one. Copies at different versions: the
newer wins (with its own test), and the component is backward compatible within a major (NFR-5). The
component is **bash and awk like `agents` is today** (the base images have no `python3`): a user of
`claude-code` carries no Python and no SLIM client, because the MCP server is in the facilitator. The
**vendor Feature's options**:

| Option | Default | What |
|---|---|---|
| `participants` | `false` | install the component: the participant file reader, the `agents:` tasks, the run half and the connect half. The definitions are in the file, not in the option, because Feature options are flat strings and the list is already a committed file |
| `attach` | empty | `facilitator` adds the MCP entry that names the facilitator's server (E1) to this CLI **through the CLI's own supported command** (an optional adapter verb in `agent-adapter-<cli>`, exit 3 when absent, ADR-0037 style); other values reserved |

The line that keeps NFR-13: a vendor Feature installs the CLI, installs the component, and
registers an MCP entry through the CLI's own route; it never wraps the CLI, edits its settings files
by hand (Claude's managed drop-in is the existing route, ADR-0032) or starts a participant except
through the run half's explicit `task agents -- <name>`. The component's adapter verbs are tested
against two fake adapters and two real vendors, **ADR-0037 and NFR-12 held**.

**Copilot CLI belongs in a new `copilot` Feature, not in `gh`.** The `gh` Feature installs and
configures the GitHub CLI and its login (its NOTES do not mention Copilot); Copilot CLI is a
separate program with its own install, versions, state and trust gate **(matrix)**, and one `gh`
Feature doing both breaks "one tool, one Feature" (CONTRIBUTING). `copilot` orders after `gh` with
`installsAfter`, never `dependsOn`, since Copilot reads `COPILOT_GITHUB_TOKEN`, `GH_TOKEN` or
`GITHUB_TOKEN` **(docs read)**; it follows the id-equals-binary rule, so `copilot` (ADR-0037's
proposed `copilot-cli` was never confirmed); it carries `agent-adapter-copilot` and the same two
options. Whether Microsoft or GitHub publishes an official Copilot CLI Feature this one should
augment (NFR-4) is not checked and is the first thing slice 4 looks up. Gemini follows the same
pattern later.

### 7.4 The interoperability endpoints

Four local contracts, versioned with the component, that any Feature may consume. **The split of E1
(ruled):** the thin agent side is the component's and the vendor Features'; the MCP server is the
facilitator Feature's.

| Endpoint | Contract | Consumer today |
|---|---|---|
| **E1 attach** | `participant attach <cli>`: adds the MCP entry (the command `facilitator mcp`, with the participant's token in `FACILITATOR_TOKEN`) to the CLI through the CLI's own command; `participant snippet <name>` prints the definition sentence. **The MCP server** (`receive`, `reply`, `say`, `who`, its SLIM client, signing, the token check and hop counting) **ships in the facilitator Feature**, not in the component | the vendor Features' `attach` option; the facilitator's server |
| **E2 directory registration** | `facilitator register <name>`: writes the participant's OASF record, read from E4, to the configured directory (`dir`, or register-engine's `agents` type, 4.8). It lives in the facilitator, not in the component | the facilitator's directory client |
| **E3 identity** | the participant's handle, token file and key name in OpenBao as the component reads them from the list; **signing itself is sign-packet's** | the facilitator's signer and `facilitator verify` |
| **E4 definition** | `participant list --json`: each participant as the component reads it (`agents list --json` already exists) | everything above |

**Where the line falls:** the component and the vendor Features own *who a participant is, its
identity and how its CLI is pointed at the layer*; the facilitator Feature owns *what happens to a
conversation* (the MCP server, modules, routing, limits, backends, AGNTCY, signing). The facilitator
carries no vendor knowledge: its pump runs each vendor's `run-once`, and its snippets call E4. A
repository that never installs the facilitator still has the definition, the run half and E4. With the
facilitator not installed, `attach` has nothing to name and does nothing.

## 8. Slices

The Operator's order (ruled). The first version is on AGNTCY; the lean hatch comes later.

0. **Spike, by hand (a learning run, no Feature), done 2026-11-19, findings in [the spike note](../spikes/2026-11-19-agntcy.md):** run the AGNTCY Directory (`dirctl daemon`) and a
   SLIM node in this devhost: downloads and their asset names, checksums, linux arm64, ports, memory,
   start-up time, state paths, and a Python client sending and receiving on SLIM. It replaces every
   "not checked" in 4.8 (done). Plus **T1** (does an agent keep looping on a blocking `receive`): **done
   with Claude Code (Haiku, `-p`): it loops, and a 300 s blocking call did not time out**; the Agent Client
   Protocol and MCP on Copilot and Gemini were read from docs only (neither CLI is installed). Result: both components run here without
   Docker, so no ruling changes; what the Feature must do about it is the note's "Requirements" list.
1. **The AOF Features in:** sign-packet 0.5.1, register-engine 0.2.0 and packet-relay 0.3.0 move from
   the AOF repository into `src/` and are published here (backlog `aof-features-takeover`, in progress
   on branches `feature/aof-features-takeover/1`, `/2` and `/4`). agentic-register and agentic-a2a stay
   out. Slice 1 also confirms whether register-engine has a conversation type.
2. **`agents` becomes the shared component:** `components/participant/` from `src/agents`, the
   same behaviour, the `components:sync` and `components:check` tasks (whole trees; `curl-check`
   covers the vendored subfolders), tests with two fake adapters, `claude-code` with `participants:
   true`, `agents` 2.2.0 deprecated, this repository's devhost moved to `claude-code`. Task names
   unchanged.
3. **The first version, on AGNTCY:** `facilitator` 0.1.0 with `backend: agntcy` (`infra`, `dir`, SLIM,
   the MCP server, signing by sign-packet, the `conversation` type, `claude-code`'s `attach`, the
   `openai-compatible` adapter); one manual run, **Claude Code over MCP plus a local model** (the
   jester scenario), signed.
4. **The `copilot` Feature** 0.1.0: install (verified), `participants`, `attach`,
   `agent-adapter-copilot`; the second real vendor for the component's contracts (NFR-12). First
   thing: check whether an official Copilot CLI Feature exists (NFR-4, NFR-9).
5. **The lean hatch:** `backend: lean` on packet-relay, `backend switch`, with the conversations
   carried over.
6. **The AI facilitator:** `serve`, the model gateway, the router's gap-filling, route planner,
   collector/summariser, the budget.
7. **Retirement and reach:** `agents` 3.0.0 once its conditions hold (7.2), Gemini, AGNTCY Identity
   opt-in, per-agent Linux users, transcripts to the shared folder.

**Out of scope:** the facilitator Feature supervising or starting participants (the run half of the
component may, on request); the Agent Connect Protocol (inactive since May 2025, SDK archived June
2025; A2A and MCP over SLIM are used instead); AGNTCY components across containers or machines;
networking between containers or machines (a later requirement: packet-relay, or A2A over SLIM,
`slim-a2a-*`); taking agentic-register or agentic-a2a from AOF; other people's agents; installing or
logging in to vendor CLIs; billing or price tables; a web UI.

## 9. Risks and open questions

- **The loop on `receive` may not hold** (T1): a model may stop looping, hit a tool timeout or
  burn tokens waiting. Mitigation: shorter waits, the pump; named, not hidden.
- **Prompt injection through a participant's message** reaches another participant as its input.
  The hop limit does not stop it; each CLI's sandbox and permissions do (the inventory).
- **Attribution is weak** with one Linux user (section 5), and the signer attests the route, not
  the intent (4.7).
- **A model in the router** can be argued into a wrong choice; bounded by enumerated handles, the
  budget and a human `/veto`, not removed.
- **The AOF takeover is a dependency of the first version:** sign-packet, register-engine and
  packet-relay must be published here (slice 1) before `facilitator` can name them; a `conversation`
  type may have to be added to register-engine, which is then ours to maintain.
- **What could force the hatch to `lean`:** (1) **immaturity**: neither page states a maturity level,
  and SLIM is already on a third major version, so APIs may move under a pin; (2) **weight**: a Go
  daemon, a Rust node and a native Python client in every MCP server instance, memory and start-up
  unmeasured (the spike); (3) **no linux arm64** build or wheel, not visible on the pages read;
  (4) **authentication set-up**: four SLIM auth modes, and secrets to keep in OpenBao; (5) **Docker**
  for Identity and for `dir`'s Compose route, which does not start on every host. Because AGNTCY comes
  first, the hatch exists only from slice 5, and a user with such a host waits for it; the spike
  (slice 0) is where each of these is confirmed or ruled out before slice 3. A user then switches with
  `backend: lean` and `facilitator backend switch lean` (4.8); conversations survive.
- **The component is a new pattern** (a vendored directory, not a script): drift between vendored
  copies, two vendor Features installing different versions, and the release workflow possibly
  tripping on a folder without a `devcontainer-feature.json`; mitigated by `components:check`, the
  newer-wins rule and slice 2 being behaviour-neutral.
- **Deprecation reaches the Operator's own devhost first** (it lists `./features/agents`), and the
  launcher's `devcontainer:agent` tasks call into it; slice 2 and the retirement condition (c) cover
  both.
- **The run half stays in a component the facilitator does not need:** keeping lifecycle inside
  vendor Features risks the "unguided" growth again; D5 keeps it frozen to what exists.
- **A second moving part per participant:** in `agntcy` mode every MCP server instance is a SLIM
  client, so a SLIM outage stops `receive` for all; `check` and `status` show it, and the hatch is
  the remedy.
- **AGNTCY drift**: OASF and its tools move; only `register` and `directory export` touch them,
  pinned to OASF 1.1.0 as the register already is.
- **Vendor drift**: tool names, flags and MCP config formats change; only the pump and `snippet`
  know them, and every vendor fact above has a date.
- **Transcript privacy**: conversations hold what people and models say; volume only, export on
  request.
- **A participant that answers slowly** holds its chain; no timeout on a reply in slice 3 beyond
  the human's `/continue`. Open.
- **Group etiquette**: many members and no facilitator-role participant means broadcast; bounded
  only by the limits. Open whether to require a facilitator for groups over three.

## 10. Decisions for the Operator

All ruled on 2026-11-19; the column "Ruled" is what the design now says. The "Ruling" section below
has the Operator's words and the corrections.

| # | Decision | Options | Ruled |
|---|---|---|---|
| D1 | The primary attachment | (a) MCP with a blocking `receive`; (b) the pump everywhere; (c) a pty bridge; (d) the Agent Client Protocol (added by the review) | **(a)**, the pump as fallback through each vendor's `run-once` adapter verb; ACP tried in T1 (slice 0) |
| D2 | Who decides who speaks | deterministic only; a model decides every hop; hybrid | **Hybrid** (4.3) |
| D3 | The store and signing | unsigned JSONL first; the register from slice 1; own signed format | **Replaced by the AOF takeover:** register-engine's `conversation` type is the record, sign-packet signs from the first version, no unsigned mode (4.6) |
| D4 | Where participants are defined | one list, `participants.yml` with `agents.yml` as an alias; a new list; a section of `agents.yml` | **One list** (alias `agents.yml`); `facilitator.yml` for the application's settings; existing keys `cli`, `kind`, `definition`; a local model is a CLI adapter (4.1) |
| D5 | The `agents` Feature | keep; deprecate; retire at once | **Deprecate in 2.2.0, retire in 3.0.0 under the conditions of 7.2** |
| D6 | The Feature name | `facilitator`; `agent-facilitator`; `agent-chat` | **`facilitator`** |
| D7 | The runtime | Python 3.11 stdlib; a Go binary; bash only | **Python**, in the facilitator only |
| D8 | Ship a local-model wrapper | yes; no | **Yes**, as the `openai-compatible` adapter's `receive` loop |
| D9 | Loop guards | 6 hops, 40 messages, 10 a minute | **As written**, `/continue` extends |
| D10 | Identity | per-participant token files; none; per-user later | **Token files**, under a written exception to ADR-0048; per-user later |
| D11 | First vendors | Claude + local model; Copilot + local model; all three | **Claude plus a local model** |
| D12 | Transcripts | volume; committed; shared folder | **The volume now, as working data; the shared folder later** |
| D13 | The backends | AGNTCY default with a `lean` hatch; lean only; AGNTCY only | **AGNTCY first**; `lean` is the safety hatch, built in slice 5; one interface, no silent fallback |
| D14 | Where keys live | signer holds them; each participant holds its own | **Keys in OpenBao, loaded into an ssh-agent for the sitting** |
| D15 | Facilitator model default | local endpoint; a vendor command; an attached participant | **None by default** |
| D16 | Order of slices | spike, lean, AGNTCY; AGNTCY first; model first | **The order of section 8** (spike, AOF Features, component, AGNTCY first version, Copilot, lean, AI facilitator, retirement) |
| D17 | AGNTCY Identity | opt-in later; default now; never | **Opt-in, later** (slice 7) |
| D18 | Where the shared component lives | `components/participant/`; `src/common`; a published Feature | **`components/participant/`** |
| D19 | How a vendor Feature opts in | `participants` plus `attach`; a list in an option; a separate Feature | **`participants` and `attach`** |
| D20 | Copilot CLI's home | in `gh`; a new `copilot` Feature | **A new `copilot` Feature** |
| D21 | A deprecation convention | write it in CONTRIBUTING; ad hoc | **Write it**, citing the README and ADR-0048 precedent |
| D22 | Task and command names | keep `agents:` until the component's next major; rename now | **Keep** |
| D23 | Where E1 lives (the review's question) | all in the component; all in the facilitator; split | **Split:** the thin agent side in the component and vendor Features, the MCP server in the facilitator (7.4) |

**Questions, closed.** Q1: "sign-packet" is the AOF Feature of that name, taken over (4.6). Q2:
`serve` runs as infrastructure the Feature starts (4.3, 6). Q3: the plan veto is off by default for
1 to 3 sub-asks (4.3). The review's integration finding is accepted: the facilitator plugs into the run
half as `agent-integration-facilitator`, not a `services.d/` folder (6).

## Ruling (2026-11-19)

The Operator ruled on the proposal on 2026-11-19. Each decision as ruled:

1. **Default backend: AGNTCY first.** "Start with Agntcy. That way we lead with its
   requirements/environment, not the other way around." The first version runs on the real AGNTCY
   components (Agent Directory and SLIM) and the environment is designed around their requirements;
   `lean` stays as the safety hatch. This rejects the review's "ship `lean` as the default until
   slice 4" (4.8, 6, 8).
2. **The MCP connection is split.** The thin agent side goes in the shared participant component and
   the vendor Features: who an agent is (definition, persona, skills), its identity, and adding the
   MCP entry to its CLI through the CLI's own command. The MCP server itself (`receive`, `reply`,
   `say`, `who`, with its SLIM client, signing, token check and hop counting) ships in the facilitator
   Feature. This is the review's recommendation (7.4 E1).
3. **The register becomes installable by taking over AOF Features:** sign-packet (0.5.1),
   register-engine (0.2.0) and packet-relay (0.3.0) move from the AOF repository into `src/` and are
   published here (backlog `aof-features-takeover`, in progress on branches
   `feature/aof-features-takeover/1`, `/2` and `/4`). agentic-register and agentic-a2a are not taken
   now: the devhost keeps its vendored agentic-register for the ledger. sign-packet is the signer and
   the packet format from the first version; register-engine is the conversation record, with a
   `conversation` type the facilitator supplies if the engine has none ("we own it, add it if it's
   not there"); packet-relay is the lean hatch's transport, replacing the inbox files, and the later
   cross-container path. The `record: jsonl` and unsigned-first ideas, and the blocker about the
   register being unpublished, are removed (4.6).
4. **Order of work:** 0 spike by hand (AGNTCY Directory and SLIM in the devhost, plus T1, with the
   Agent Client Protocol tried on Copilot and Gemini beside MCP); 1 the AOF Features in; 2 `agents`
   becomes the shared component (`components/participant/`, claude-code `participants: true`,
   `agents` 2.2.0 deprecated); 3 the first version on AGNTCY, Claude plus a local model, signed; 4 the
   Copilot Feature; 5 the lean hatch; 6 the AI facilitator; 7 retire `agents`, plus Gemini and AGNTCY
   Identity opt-in (section 8).
5. **"sign-packet" answered:** it is the AOF Feature of that name. Q1 is closed.
6. **Accepted as recommended:** D1 (MCP with a blocking receive; the pump as fallback via each
   vendor's `run-once` adapter verb; ACP added to T1); D2 (hybrid routing); D4 (one list,
   `participants.yml`, `agents.yml` as an alias, `facilitator.yml` for the app; keys `cli`, `kind`,
   `definition`; a local model as a CLI adapter); D6 (`facilitator`); D7 (Python); D8 (the model
   wrapper); D9 (6 hops, 40 messages, 10 a minute, `/continue`); D10 and D14 (keys in OpenBao, loaded
   into an ssh-agent for the sitting; participant tokens as files under a written exception to
   ADR-0048); D11 (Claude plus a local model first); D12 (conversations in the volume, as working
   data, the shared folder later); D15 (no default facilitator model); D17 (Identity opt-in later);
   D18 (`components/participant/`); D19 (`participants` and `attach`); D20 (a new `copilot` Feature);
   D21 (a deprecation convention written in CONTRIBUTING); D22 (keep the `agents:` names until the
   component's next major); Q2 (`serve` runs as infrastructure the Feature starts); Q3 (plan veto off
   by default for 1 to 3 sub-asks). From the review: an `agent-integration-facilitator` integration in
   place of a `services.d/` folder; the ADRs the ruling must cover (0036, 0037, 0041, 0025, 0045,
   0048, 0034, and the "MCP: none" decision); `slim-bindings` pinned through the shared download
   helper or an exception to ADR-0034 recorded.
7. **Corrections:** the Agent Connect Protocol repository's last change was May 2025 (its SDK was
   archived in June 2025), not 2026-04-11; AGNTCY now carries A2A and MCP over SLIM (`slim-a2a-*`,
   `slim-mcp-*`), which are used wherever that protocol was named. `claude-code` does not register the
   register's MCP today; the agentic-register Feature registers itself.

**The ADR this ruling needs:** ADR-0061 ("The facilitator is built on AGNTCY first, …"), covering the records listed in 7.2 (ADR-0036, 0037, 0041,
0025, 0045, 0048, 0034 and the "MCP: none for now" decision), the home of `sessionName`, and the two
exceptions (participant token files; `slim-bindings` if it cannot go through the download helper).


### Ruling on the spike findings (2026-11-19)

After the AGNTCY spike (`docs/spikes/2026-11-19-agntcy.md`) the Operator ruled, as recommended:

- **E. No `slim-mcp`.** The facilitator Feature's own MCP server speaks MCP to the CLI over stdio and
  uses `slim-bindings` (3.x, pinned with hashes) directly for SLIM; PyPI's `slim-mcp` (pinned to
  bindings 1.4) is not used, patched or forked.
- **F. Agent records are checked offline by default.** The Directory daemon runs with
  `policy.operations: []`; a Feature option turns on the online OASF schema check.
- **G. SLIM is pinned to slimctl 3.4.6** (released, sigstore-signed, amd64 and arm64); move up when
  3.5.0 has a release, not only an image.

### Ruling on the first version (2026-11-20)

- **M, both:** every `@handle` in a message is delivered, each once (rule 1 as written); the first version's addressed-only reading is dropped, and the hop count bounds the chain.
- **N:** the participant component's keys are handled on a separate branch; the facilitator's own parser is left as it is.
- **O, token delivery:** the participant token reaches `facilitator mcp` through the agent's environment, set by its harness, never inside the CLI's MCP entry, because tokens are remade at each start.
- **P, keys when OpenBao is sealed:** the mode-600 file fallback stays for 0.x and is removed at 1.0.
- **Q:** the Operator releases 0.1.0 after the merge; an agent does not.

### Ruling on the MCP-only pivot (2026-11-20)

The Operator: "remove the chat, essentially making it just accessible through the MCP." A person talks
to the agents from their own Claude Code or Copilot session, attached to the facilitator's MCP server as
a participant of kind `human`; this replaces the terminal of 4.9. Built in facilitator 0.2.0.

1. **Seeing replies:** a non-blocking "any mail?" tool is the contract (`mail`). A turn hook that shows
   "N new messages" at each turn is a convenience, where the CLI has one (Claude Code does:
   `facilitator snippet <person>` prints a `UserPromptSubmit` hook; the Feature never edits Claude's
   settings).
2. **Loops through a person, option A:** messages sent through a person's session count as hops, like any
   other. Only an explicit `continue` tool call (the MCP form of `/continue`, a human-kind caller only)
   resets the hop count.
3. **The command line:** `chat` and `send` are dropped. `transcript`, `verify`, `status` and `check` stay
   as read-only admin tools. The other admin and infrastructure verbs stay: `version`, `setup`, `start`,
   `infra`, `register`, `participants`, `snippet`, `mcp`, `model`.
- **U:** `facilitator mcp` reads `FACILITATOR_HANDLE` (`--as` still accepted), so one MCP entry serves
  every agent whose harness sets `FACILITATOR_HANDLE` and `FACILITATOR_TOKEN`.

## Architecture review (2026-11-19)

**Verdict:** fit with changes

The facilitator itself (a deterministic core, limits in the layer, the register as the signed
record, AGNTCY behind one backend interface) fits the collection. The changes are about where the
deprecated `agents` Feature's new "connect half" is put: most of it belongs in the facilitator,
the register or a CLI adapter, not in a component that `claude-code` installs.

### Requirements checked

- **NFR-1** needs a line: met for the facilitator (section 6, `facilitator-state-*`). Not said for the run half's leases once they leave `agents`, or for the conversation record, which sits in the agentic-register Feature's volume (4.6, 4.8).
- **NFR-2** met (section 6, `version` first). The component's Taskfile is included by two vendor Features (7.3); say which install block registers it.
- **NFR-3** not met yet: `dir`'s checksum file and arm64 build are unknown (4.8, the spike). `slim-bindings` by pip is a second download route (finding 12).
- **NFR-4** needs a check for `copilot` (7.3 says it is not checked). Does not apply to `facilitator`.
- **NFR-5** met in the design (section 6; 7.3 "one place, newer wins"). The newer-wins rule needs its own test.
- **NFR-6** mostly met (section 6). `facilitator backend switch` (4.8) must not persist a backend that disagrees with the `backend` option or `FACILITATOR_BACKEND`.
- **NFR-7** partly met: `chat` is `interactive: true`, and `send` and `transcript --json` exist (4.9). `CLI_ARGS` is not mentioned.
- **NFR-8, NFR-9** do not apply to a proposal. 4.8 names the NOTES content. `copilot` needs NFR-9 if an official Feature exists.
- **NFR-10** met in the plan (section 6), with two gaps. The `.github/workflows/test.yaml` matrix is a hand list, so `facilitator` and `copilot` must be added. `debian:latest` and `ubuntu:latest` have no `python3` (`src/agents/agents.sh` says so and avoids it), so a `participants: true` scenario needs Python.
- **NFR-11** partly applies. `facilitator verify` claims the shape (4.7) but takes no paths. Give it exit 0, 1 and 2 and `--format json`, and say the rest does not apply.
- **NFR-12** met in form, not checked against the matrix. E1's fallback is named (the pump), but E1 rests on MCP clients and long blocking tool calls, and section 14 of `agents-v2.md` has no MCP row (finding 6).
- **NFR-13** partly met. The pump puts per-vendor flags in the facilitator (finding 3), and the vendor Features gain a facilitator-specific option (finding 4).

### Findings

1. **The default record cannot be installed by a downloader.** 4.8 says the record is the register "in both modes", and the default is `backend: agntcy`. 4.6 and D3 say the register cannot be pulled: it is vendored, unchanged, from AOF's private packages (`local-features/agentic-register/VENDORED.md`), and local Features are never published (ADR-0025). 4.6 also names an unsigned JSONL fallback that 4.8's table omits. Recommended change: make the record a setting of its own (`record: register|jsonl`), independent of `backend`, default `jsonl` until the register can be pulled, and show both settings in 4.8's table.
2. **The connect half is misplaced in the vendor Features.** E1 is useless without the conversation service that only the facilitator installs (7.4). In `agntcy` mode every E1 instance is a SLIM client with a native wheel (section 9). The component needs Python 3.11 (D7). Today `agents` is awk and bash, because base images lack `python3` (`src/agents/agents.sh`). Python reaches a Feature through `dependsOn` (the `phi-check` precedent), which cannot depend on an option, so every `claude-code` user would carry Python whether `participants` is on or off. Recommended change: the component keeps only the run half and E4 (`agents list --json`, which already exists), in bash; E1 ships in `facilitator`; E3 is the register's own signing and verification; E2 is the facilitator's directory client reading E4.
3. **The pump re-implements adapter knowledge.** 4.2's table puts each vendor's one-turn flags (`-p`, `--resume`, `--output-format json`, `--allow-all-tools`) in the facilitator's pump, and 9 says "only the pump and `snippet` know them". 7.4 says the facilitator "carries no vendor knowledge". ADR-0037 already defines the optional adapter verb `run-once` (exit 3 when absent). Recommended change: the pump becomes a loop around `agent-adapter-<cli> run-once`, and the facilitator model's `command:` becomes `cli:` through the same verb.
4. **MCP registration is placed in a facilitator-specific vendor option.** `attach: facilitator` on each vendor Feature (7.3) teaches every vendor Feature about one consumer. 7.3 also says `claude-code` already registers the register's MCP; in fact the agentic-register Feature registers itself (`claude mcp add --scope user` in `register/cli.py`). Two vendors have an MCP command (Claude Code, `copilot mcp`; both read from docs in 4.2). Recommended change: add an optional adapter verb `mcp-add <name> -- <command>` (exit 3 when absent), call it from the facilitator's setup, and drop the `attach` option.
5. **D1 omits a native route that two vendors in the matrix have.** Section 14.2 lists Copilot `--acp` and Gemini `--experimental-acp`: the Agent Client Protocol, where a client drives an agent session and hands it prompts. That is the gap 4.2 names ("a server cannot wake a model"), and two vendors pass NFR-12's test on paper. Recommended change: add ACP as an option of D1 and to T1, with Claude Code's ACP status read from its docs (the matrix does not state it).
6. **The design was not checked against the matrix (NFR-12).** E1 rests on facts that section 14.1 has no row for: an MCP client in interactive mode and under `-p`, a command to add a server, tool-call timeouts, and Gemini's MCP (marked "not checked" in 4.2). Recommended change: add those rows to the matrix, dated and sourced, before D1 is ruled.
7. **The participant keys break the list spec.** `name`, `cli` and `kind` are required today (`agents.sh`: "name, cli and kind are required"), and the `jester` and `copilot-lead` entries in 4.1 have neither `cli` nor `kind`. The human `you` reuses `kind` (resident or on-demand) with a new value, `human`. `persona` duplicates `definition` (ADR-0036: "the key for the CLI profile stays `definition`"). `facilitator: true` is the facilitator's own setting inside the shared list, and `endpoint` and `model` belong to one attachment. Recommended change: model a local model as a CLI adapter that the facilitator ships (`cli: openai-compatible`, endpoint and model in `args`); use `definition` for the persona; move `facilitator: true` and the human member into `facilitator.yml`. The shared list then gains only `attachment`, `description` and `skills`.
8. **E1's `services.d/` is a second plug-in mechanism.** ADR-0036 decided that integrations plug in through `agent-integration-<id>` executables with the verbs `env`, `before-start`, `check` and the rest. Handing a participant its `FACILITATOR_TOKEN` and registering it at start is what `env` and `before-start` do. Recommended change: the facilitator plugs into the run half as `agent-integration-facilitator`, and `services.d/` is dropped, or kept with the ADR saying why the integration contract does not fit.
9. **More accepted records are touched than 7.2 names.** ADR-0036 (the lease moves out of the `agents` Feature) and ADR-0037 (the `copilot-cli` name; the contract tests run against "the agents Feature") are named. Not named:
   - ADR-0041: the session name is rendered by the agents Feature from its `sessionName` option, and that option has no home in 7.3's option table.
   - ADR-0025: `components/` is a new top-level folder class beside `local-features/`.
   - The recorded decision "MCP: none for now" in `docs/principles/non-functional-requirements.md`: `facilitator` would be the first published Feature to offer an MCP server.

   Recommended change: one ADR at the ruling that names all five and gives `sessionName` a home (a vendor Feature option, or the list key `session-name` alone).
10. **The provenance record sits in tier 4 (ADR-0045).** Conversations and their signed lineage live in a volume (4.6, D12), which is the rebuildable-only tier, while the design exists to prove that lineage later. The register README says a `messages` register has no mirror, so adding one is a register change upstream in AOF. Recommended change: state in 4.6 that conversations are working set and lost with the machine, and keep a tier-2 mirror as a later item that needs a register release.
11. **Participant tokens bypass OpenBao (ADR-0048).** ADR-0048 makes OpenBao the master of every token the collection creates. SLIM's secret goes there (4.8), but `tokens/<handle>` is a file in the volume (section 5). Recommended change: either keep the tokens in OpenBao, or write the exception into the ADR (made at each start, valid only in that container, worthless outside it).
12. **Downloads outside `dcf_curl` (ADR-0034).** Section 6 does not say the `dir` and `slim` binaries go through `dcf_curl`. `slim-bindings` arrives by pip, which neither the helper nor `common:curl-check` covers. Recommended change: say that the binaries use `dcf_curl`, and record pip with `--require-hashes` as a named exception in the deprecation ADR.
13. **CI does not see the new folder.** `release.yaml` and `validate.yml` use `base-path-to-features: ./src`, so `components/` is safely never published. The `test.yaml` matrix is a hand list. `common:check` and `common:curl-check` glob `src/*/*.sh` one level deep, so a copy vendored into a subfolder (`src/claude-code/participant/`) escapes both. Recommended change: `components:check` compares whole trees, `curl-check` covers the vendored subfolders, and the component's unit tests run in `task lint` (ADR-0027).
14. **Lexicon collisions.**
    - "Model wrapper" clashes with **Wrapper** (an executable ahead of a tool, under the tool's own name).
    - "Packet" is a second name for a register entry, while the lexicon's **Entry** means one ledger record.
    - "Building block" and "endpoint" name the same thing (section 3, 7.4).

    Recommended change: drop "model wrapper" (finding 7 makes it an adapter), call a packet a "signed message" with one lexicon line, and keep "endpoint" only.
15. **New terms need lexicon entries that relate them to the old ones.** "Participant" against **Agent** ("any model doing work for the repository ... an inter or a back"; a local jester is neither) and against **Agent list** (which `participants.yml` renames). "Harness" against **Carrier** (what an agent runs on). "Conversation" against the register's "thread". Recommended change: the librarian adds Participant, Harness, Attachment, Facilitator and Participant component, each saying what existing term it extends or replaces, when the Operator rules.
16. **`serve` has two owners.** 4.3 says "the Feature runs it" (`autostart`). Section 6's task list says "run by a harness". Q2 asks whether a harness should run it. Running a server from `postStartCommand` has precedent in openbao's server mode (ADR-0048, decision 3). Recommended change: say the Feature runs it under `autostart`, the way it runs `dir` and SLIM, and close Q2.
17. **A deprecation convention already exists in practice.** 7.2 says none is written. The README already deprecates `claude-host`, `devcontainer:claude` and `devcontainer:ssh-key-import` with one printed line, removed at the next major, and ADR-0048 keeps `DCF_HOST_SSH_AGENT=key` "for one major". Recommended change: D21 cites these as the precedent it writes down.

### Open questions for the Operator

- **The default backend before the spike.** Section 6 sets `backend: agntcy` and `autostart: true`, which starts two daemons for every downloader, while every cell of 4.8 is unconfirmed until slice 0. Recommendation: keep the ruling as the target, ship `lean` as the default until slice 4 (section 8 already implies it), then switch with the "what changed" note.
- **Where E1 lives** (finding 2): in the vendor-installed component (the proposal) or in `facilitator` (the review). Recommendation: `facilitator`, so `claude-code` gains no Python or SLIM dependency.
- **Publishing the register** (D3, finding 1): a downloaded Feature can sign only once the register can be pulled. Recommendation: rule on it before slice 5, with `record: jsonl` until then.
- **ACP in D1** (finding 5). Recommendation: put it in T1 beside MCP before D1 is ruled.
- **Participant tokens** (finding 11): OpenBao, or a written exception. Recommendation: the exception, since the tokens are made per container start.
- **Conversations' tier** (finding 10): working set, or a mirror. Recommendation: working set now; a mirror after a register release.
