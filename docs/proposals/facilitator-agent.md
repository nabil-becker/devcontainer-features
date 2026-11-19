# Proposal: a facilitator, the communication layer between agents of any vendor

draft 2026-11-19

Status: a design proposal, nothing built. Backlog id: `facilitator-agent`. It serves the Operator,
through the host, who rules on it; and the persona the Feature is for: an engineer who downloads
a Dev Container Feature, gives it their own vendor credentials, and holds conversations with
several AI agents running in their devcontainer. Vendor facts are marked **(docs read)** when a
vendor page was read for this proposal, **(matrix)** when taken from the capability matrix of
`docs/proposals/agents-v2.md` section 14 (itself from docs, 2026-10-29), and **(not checked)** when
neither; AGNTCY facts are from the project's GitHub pages **(docs read)**. Nothing was installed or run here.

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

Later the same day, three more directions: run a lean AGNTCY-style setup (agents register an OASF
record in a directory), have agents **sign their messages** so provenance and lineage can be
verified ("maybe even using the sign-packet feature"), and make the facilitator "a multi module
agentic application that uses its llm model to help the orchestration and routing". "AGNCY" is read
as AGNTCY. No Feature, task or document named "sign-packet" exists in this repository (searched);
it is read as the register's entry signing, and that is open question Q1.

A last direction, the same day, reverses the first draft's treatment of the `agents` Feature: **the
goal is to deprecate it**; the `claude-code` and a Copilot Feature evolve to enrich the
experience; `agents` becomes an internal common component those Features use, exposing standard
interoperability endpoints that other Features, this one first, consume. Section 7 is that design.

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

In the picture the sender named both handles, so routing is by rule. Had you written "get someone to
tell a joke to the expert", the router module (4.3) would have asked the facilitator model to choose
from the directory, written its choice as a packet, and gone on the same way. Every arrow is a signed
packet (4.7).

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
| **Facilitator** (the Feature, and the application) | The Feature `facilitator`: the communication layer, and the **facilitator application** it ships: a set of modules (4.3), some deterministic, some assisted by the facilitator's own model. It is not a participant; it speaks in a conversation as the handle `facilitator`. |
| **Facilitator model** | The LLM the application uses to decide and summarise: a local OpenAI-compatible endpoint, a one-turn vendor command run with the engineer's token, or an attached participant. Pluggable (4.3). |
| **Packet** | One signed message: a register entry with its signature (4.6, 4.7). The Operator's word; the register calls it an entry. |
| **Directory** | The set of agent records (OASF) the participants registered; where the planner reads skills from (4.8). |
| **Backend** | The one setting that says what carries directory, delivery and records: `agntcy` (the real AGNTCY Agent Directory and SLIM, the default) or `lean` (the register alone). The modules see one interface either way (4.8). |
| **Infrastructure** | What the Feature itself starts and owns: the directory and SLIM node in `agntcy` mode, and the facilitator application. Participants are never infrastructure. |
| **Participant** | A named, running process that takes part: a **handle** (`jester`), a persona (a system prompt or profile it is started with, kept by the harness), an **attachment**, an optional model label shown in the transcript. The engineer at the terminal is a participant too (`you`, kind `human`). |
| **Participant component** (the component) | Internal code shared by vendoring, never published as a Feature: the participant definition, identity and signing, the attachment endpoint, directory registration, and the optional run half (kinds, lease, session names, adapter verbs) that today is the `agents` Feature (section 7). |
| **Building block** | One of the component's parts a Feature can use alone: the four **endpoints** E1 to E4 (7.4). |
| **Harness** | Whatever keeps a participant process running: tmux, a process supervisor, a service, the vendor's own session, the `agents` Feature. Not this Feature's job. |
| **Attachment** | How a running participant connects to the layer. Primary: **MCP** (tools `receive`, `reply`, `say`, `who`). Fallbacks: the **pump** (a loop that does `receive` and runs a one-turn command), and the **model wrapper** (a pump for an OpenAI-compatible endpoint). |
| **Conversation** | A thread with members: **direct** (you and one participant, or two participants) or **group** (three or more). Held as in the register's `messages` type: group and direct, A2A-shaped. |
| **Turn** | One message by a participant in a conversation. A turn's **hops** are the number of participant-to-participant deliveries since the last human message. |
| **Mention routing** | Delivery by `@handle` in the text or the `to` argument, always honoured; no mention is for the router module (4.3, 4.4). |
| **Bubbling up** | Every message lands in the conversation's transcript, which a human follows; a message with no mention returns to the participant that asked. |
| **Hop limit** and **message budget** | The two guards against agents mentioning each other forever (4.5). |

## 4. Architecture

```
 vendor Features (user-facing)   participant component (vendored, internal)            facilitator Feature
 claude-code  participants/attach  E4 definition  E3 sign  E2 register  E1 attachment (MCP)   application:
 copilot      participants/attach  + run half: kinds, lease, session names, adapter verbs     intake, guard, router,
 gemini (later)                          |                                                    planner, dispatcher,
                                         |  participant processes, kept running by a harness  collector, signer use
   claude (domain-expert-one) --MCP-->   |                                                    backend interface:
   copilot, gemini ------------MCP-->    v                                                    directory | transport |
   local-model wrapper --------------> E1 `receive reply say who`  ----------------------->   record
   you: `facilitator chat` ----------------------------------------------------------------->  (agntcy | lean, 4.8)
```

Section 7 says which of these the Operator's "deprecate `agents`" puts where; the rest of this
section is the facilitator's side of the line.

### 4.1 The participant file

`.devcontainer/participants.yml`, committed, **owned by the participant component (7)**, path set by
`PARTICIPANTS_FILE` (NFR-6). It is the **same list as today's `agents.yml`**, one list not two: the
keys `agents` reads (name, cli, kind, folder, args, lifecycle, identity, lease, session-name, default)
stay, and the keys below are added. During the deprecation `agents.yml` and `AGENTS_FILE` are still
read as aliases (7.2). The facilitator application's own settings (its model, the backend) go in a
separate `.devcontainer/facilitator.yml`, because only the facilitator reads them. In the example,
`participants.yml` is the second block and `facilitator.yml` the first:

```yaml
facilitator:                       # the application's own model (4.3)
  model:
    endpoint: http://localhost:11434/v1   # or: command: "copilot -p"   or: participant: copilot-lead
    name: llama3.2
participants:
  - name: jester                   # the handle; letters, digits, - and _
    attachment: model              # mcp | pump | model
    endpoint: http://localhost:11434/v1     # model only; an OpenAI-compatible server
    model: llama3.2
    persona: personas/jester.md    # model/pump only: the text the wrapper sends as system prompt
    description: tells jokes       # the OASF record (4.8), read by the router and planner
    skills: [humour]
  - name: domain-expert-one
    cli: claude                    # the run half starts it (the harness); the facilitator never does
    attachment: mcp                # the participant's own CLI calls the tools
  - name: copilot-lead
    attachment: mcp
    facilitator: true              # at most one; the fallback for what is addressed to no one when the application is not running
```

For an `mcp` participant the persona lives with its harness (its CLI's own profile or prompt); the
component prints the sentence to add to the persona (`task agents:snippet -- <name>`) and the vendor
Feature's `attach` option registers the MCP entry through the CLI's own command (7.3), because
nothing may edit a vendor's configuration by hand (NFR-13).

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

### 4.3 The facilitator application: modules, and what the model decides

The Operator's direction is a multi-module application whose own model helps orchestrate and route,
not only an `@mention` matcher. **Recommended: an explicit `@handle` is always routed by rule and
the model can never redirect it; the model fills the gaps** (nobody addressed, a request to break
up, many replies to join), and everything it decides is written as a packet, so a human can see and
veto why a message went where it did.

```
 intake -> guard -> router ----> planner* ----> dispatcher -> (participants, via inbox)
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
| **Planner** | Breaks a request into sub-asks (`ask`, an A2A task per assignee), writes the plan to the transcript as a packet; a human may `/veto` it before dispatch (default off for 1 to 3 sub-asks) | model |
| **Dispatcher** | Writes deliveries, tracks each task's state (`submitted` to `completed`), re-asks or marks `failed` on a timeout, never delivers past the guard | deterministic |
| **Collector / summariser** | When the sub-asks are done (or timed out), joins the replies into one message to the asker, each claim with a `ref` to the packet it came from | model (a plain concatenation is the fallback) |
| **Directory client** | Reads the registered agent records: handle, description, skills; feeds the router and planner (4.8) | deterministic |
| **Signer** | Signs every packet, the facilitator's own included (4.7) | deterministic |
| **Model gateway** | One interface, `complete(prompt, schema) -> text`; backends below | deterministic code around a model |

**The facilitator model is pluggable** (`facilitator.yml`, `model:`): `endpoint` (an
OpenAI-compatible server, a local model, credentials none), `command` (a one-turn vendor command
that takes the prompt on stdin and prints the answer: `copilot -p`, `claude -p`, `gemini -p`, run
with the engineer's own token **(docs read, section 4.2)**), or `participant: <handle>` (an
attached participant answers as a normal turn, so the facilitator can be a vendor session someone
already runs). The call is a stateless decision, so it needs no session and no harness; it is the
application's own use of the CLI, not management of it (NFR-13).

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

A conversation is a register thread of type `messages` (group or direct, sub-threads, mentions as
principals, `reply_to`, `refs`, A2A tasks), and a **packet** is one entry in it: a body of canonical
JSON, hashed and signed, whose writer the register verifies against a roster (SPEC.md, "Entry" and
the `messages` type). **Recommended: the register is the store of record**, because it already is
what the Operator asks for (signed, verifiable, append-only, group and direct, MCP tools) and
inventing a second signed format would be the mistake the Operator warned of with `agents`. What it
lacks, and so what the Feature adds around it:

| Lacks | What the Feature adds |
|---|---|
| A published home: `local-features/agentic-register` is vendored and unpublished, so a downloaded Feature cannot name it in `installsAfter` or pull it | the blocker of decision D3; until it can be pulled, the store is an interface with two backends |
| Zero-ceremony identity: every writer needs a key and a roster entry added with an operator key | `facilitator register` does it for a participant at registration (4.7) |
| Delivery: unread markers and a polling `watch --follow`, but no claimed delivery, blocking receive or "attached since" | `inbox/<handle>/` beside the register, written by the dispatcher; `receive` blocks on it; the register stays the record |
| Limits: no hops, budget, rate or pause | the guard module; hops and the root message id are carried in the packet's `data` part |
| A model in the loop | the modules of 4.3; their decisions are packets of kind `message` from the handle `facilitator` |
| Participant definition | the directory (4.8) |

The other backend is a plain `conversations/<id>.jsonl` in the state volume, with the same field
names and **no signatures**: the zero-dependency path for a downloader until the register can be
pulled. Both keep the field names of the `messages` type, so a conversation moves between them.

### 4.7 Identity, signing and lineage

**Who signs.** Every packet is signed by an identity key: an Ed25519 key as the register uses
(`ssh-keygen -Y sign`, the public half on the register's roster). One per participant, one for
`facilitator`, and the human's operator key as the register already has it.

**Where the key lives, so the participant process does not hold a long-lived private key.** The
**signer module** signs on the participant's behalf, **after authenticating it by its participant
token** (4.2, section 5). The participant, a model reached by MCP, never sees a private key: it
asks `reply`, the signer signs. Keys are kept in OpenBao (ADR-0048, the master of every private
key) under `facilitator/keys/<handle>` and loaded into an ssh-agent for the sitting, which the
register already supports (a `.pub` whose private half an agent holds; the `ssh-agent` Feature, key
loading per `secrets-master-split.md`). So the private half is in the agent's memory for a sitting
and in OpenBao at rest, in neither a file nor a participant. A harness that wants end-to-end
signing may instead give a participant its own key and use `--key`; the layer then verifies the
signature and signs nothing for it.

**What this proves, and what it does not.** A valid packet proves that the key registered for
`jester` signed this exact body, in this chain, and that nobody changed or reordered it. With the
signer module it attests that the layer authenticated the participant's token at that moment: it
does not prove the model *meant* it, and a process that can read another participant's token (the
same Linux user, section 5) can write as it. Provenance here means "which registered identity, via
which authenticated route", not a hardware attestation.

**Lineage** is expressed with fields the register already has, so `verify` can walk it:

| Link | Field |
|---|---|
| what a message answers | `reply_to` (a message id) |
| what it derives from (a summary's sources, a sub-ask's origin) | `refs` (`thread:message_id`) |
| the human request the chain began with | the root message id, in the packet's `data` and as the last `ref` |
| a request and its outcome | `task_id`, the A2A task and its `status` entries |
| why it went to this recipient | a `facilitator` packet (route, plan) that `refs` it |

**How a chain is proved.** The register's `verify` checks every entry's signature, its place in its
writer's chain and its roster (and flags forks and refused entries). On top of it a new command,
`facilitator verify --conv <id> [--message <id>]`, walks `reply_to` and `refs` from a message back
to a human-signed root, and for each hop checks: the signer is on the roster and is the `from` the
packet claims; the hop count is within the limit; the parent exists and is in the same conversation
or a referenced one; every summary `ref`s packets that exist. It prints the chain, one line a hop,
and exits 1 on a break (NFR-11 shape). It is a query over the register's index, not a new format.

### 4.8 Backends: the real AGNTCY components, or lean

**The Operator's ruling (2026-11-19): run the real AGNTCY components in the devcontainer, partly
to learn from them, with a safety hatch to a lean setup for simpler uses.** Where simplicity and
exercising AGNTCY as designed pull apart, this proposal prefers exercising AGNTCY and names the cost.

The facilitator's modules talk to **one backend interface of three parts**, so participant names,
`@mentions` and signed lineage are the same in both modes:

| Part | Does | `agntcy` mode | `lean` mode |
|---|---|---|---|
| **directory** | register, look up and list agent records (OASF) | the Agent Directory (`dir`) | the register's `agents` type |
| **transport** | deliver a packet to a participant, block in `receive`, group sessions | SLIM | `inbox/<handle>/` files and a file wait |
| **record** | the signed, append-only conversation and its verification | **the register**, in both modes | the register |

AGNTCY has no conversation store and signs nothing of ours, so the record is the register's
signed entries in both modes. That is what makes the hatch cheap: **switching modes loses no
conversation**, only moves directory and delivery.

**Components, what each needs, and how the Feature gets and starts it** (all from the projects' GitHub
pages **(docs read)** unless marked; versions are those pages' latest at 2026-11-19 and are pinned
in the Feature, not floated):

| Component | Used for | Obtained (NFR-3: pinned, checksum-verified) | Runs as | Needs | Maturity, licence |
|---|---|---|---|---|---|
| **Agent Directory** `dir`, CLI `dirctl` | OASF records, discovery, record signing and provenance | release binary of v1.9.1; its asset names, checksum file and linux arm64 build are **not listed on the page read and must be confirmed in the spike**; images `dir-apiserver`, `dir-ctl`, `dir-reconciler` existed at v1.8.0 | `dirctl daemon start`: apiserver and reconciler in one process, embedded SQLite, localhost:8888, state under `~/.agntcy/dir/` (the Feature points it at its volume; how, **not checked**) | no Docker (the Compose route, with Zot and PostgreSQL, is not used) | v1.x, no maturity statement; Apache-2.0; OpenSSF badges |
| **SLIM** node, `slimctl` | the transport: named routing, sessions, group membership, end-to-end MLS | slimctl v3.4.6 tarballs with SHA-256 and `.sigstore.json` signatures per asset; **linux arm64 not visible** on the page read; the node binary or an image to confirm | `slim --config <server config>` as a background process on loopback; auth modes offered: basic auth, JWT, mTLS, SPIFFE; the Feature picks basic auth on loopback with a generated secret kept in OpenBao | none for the node; **clients** (our MCP server instance, `chat`, the wrapper) use the `slim-bindings` Python package, a native wheel (platform wheels **not checked**) | v3.x; Apache-2.0; no maturity statement |
| **AGNTCY Identity** (issuer CLI, node, badges, DIDs) | verifiable agent badges, bringing an existing ID | the CLI by its install script; the node by `launch_node.sh` | needs **Docker** | Docker-in-Docker, which does not start on every host (`wslc`) | no version or releases on the page; Apache-2.0. **Not default**: opt-in `identity: true`, slice 5 |
| **Agent Connect Protocol** | a REST interface to invoke a remote agent | not used | n/a | n/a | the repository was **archived 2026-04-11**; A2A, which the register's messages are already shaped as, is what is used instead |

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
SLIM's named sessions and its end-to-end encryption (lean delivery is files in the volume, readable
by the same Linux user); streaming delivery (lean waits on a file); the directory's record signing
and provenance; readiness for the cross-container requirement. **Kept:** participant names,
`@mentions`, groups, signed lineage and `facilitator verify`, the OASF records themselves (the
register stores OASF 1.1.0 and `facilitator directory export` prints the pure records).

**Switching:** `backend` option, or `FACILITATOR_BACKEND=lean` in `.env`, then `facilitator backend
switch lean|agntcy`: it stops the infrastructure it owns, re-registers each participant's OASF
record in the other directory (the same record), points the transport at the other mechanism, and
leaves every conversation as it is. There is **no silent fallback**: if `agntcy` cannot start,
`check` says why and offers the switch, so nobody believes they run AGNTCY when they do not.

**What could force the hatch** (listed as risks in section 9): components too young or churning,
resource weight, no linux arm64 build, authentication set-up, a host without Docker for Identity.

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
entry passes as `FACILITATOR_TOKEN` so a participant can write only as itself. Honest limit: every
process of one Linux user can read every token, so this stops a mistake (one participant writing
as another), not an attacker; real separation comes from `agent-linux-user.md` (one user per
agent), and the sandbox of each CLI (`agent-least-privilege-inventory.md`). Conversations may hold
what people said; they stay in the volume and are never committed (section 6), and the transcript
export is a file the engineer chooses to write.

## 6. What the Feature installs and what it must not

**Scope after the component (7): the facilitator Feature is the facilitator application and the
AGNTCY or lean infrastructure, and nothing about vendors.** It consumes the component's endpoints and
vendors only the connect half of the component. Installs: the `facilitator` command (the modules of 4.3, an MCP server over stdio, `chat`, `pump`, the
model wrapper), the Feature Taskfile (NFR-2), `facilitator-setup` (state folders, idempotent,
never fatal; NFR-5), in `agntcy` mode the two AGNTCY binaries (pinned, checksum-verified, NFR-3: `dirVersion`, `slimVersion`) and the `slim-bindings` package (a pinned requirement with hashes), a state volume `facilitator-state-${devcontainerId}` at
`/var/lib/devcontainer-features/facilitator` (NFR-1). The command needs a Python 3.11 runtime (decision D7); `lean` downloads nothing.

**Must not (NFR-13):** install, update or log in to any vendor CLI; edit their settings files or
their MCP config (it prints the entry; the engineer or the harness adds it); start, stop, restart
or resume any participant; run a supervisor **for participants** (only for its own infrastructure, 4.8); open a network port beyond the loopback ports of its own
infrastructure; keep a vendor credential. The vendor CLIs come from their own Features or the engineer.

| Option | Default | What |
|---|---|---|
| `installTaskfile` | `true` | the Taskfile, as every Feature |
| `hopLimit` | `6` | section 4.5 |
| `messageBudget` | `40` | section 4.5 |
| `receiveWaitSeconds` | `300` | how long `receive` blocks |
| `staleSeconds` | `900` | after which a participant counts as not attached |
| `facilitatorBudget` | `20` | model calls the application may make per conversation |
| `signing` | `auto` | `register` (sign every packet; needs the register), `off`, or `auto` (register when `agentic-register` is on PATH) |
| `backend` | `agntcy` | `agntcy` (real Agent Directory and SLIM) or `lean` (the register alone); the safety hatch (4.8). `FACILITATOR_BACKEND` overrides |
| `dirVersion`, `slimVersion` | pinned | the AGNTCY release to install; `latest` says what it resolves to (NFR-3) |
| `identity` | `false` | also run AGNTCY Identity (needs Docker) |
| `autostart` | `true` | `postStartCommand` runs `facilitator infra up` and `serve`, never fatal; participants are never started |

Settings are plain variables too: `FACILITATOR_FILE`, `FACILITATOR_HOP_LIMIT` and so on (NFR-6).

Tasks (`task facilitator:<task>`; first is `version`): `version`, `check` (file valid, state
writable, per-participant attachment seen, no secrets printed), `participants`, `status` (who is
attached, last seen, each conversation's hops), `chat` (interactive), `send`, `transcript`,
`infra` (up, down, status, logs), `backend` (show, switch), `register` (a participant's OASF record, key and roster entry), `directory` (list, export), `verify` (4.7), `serve` (the application; run by a harness), `snippet` (the MCP entry and persona sentence for a participant), `pump` and `model` (run by a
harness; documented, not started by a task), `export` (a conversation to Markdown).

Tests (NFR-10): Docker-free unit tests in `task lint`: the routing rules (4.4), the loop limits, the
file lock under concurrent writers, the MCP protocol over stdio (initialize, `tools/list`,
`receive` blocking and timing out), the participant file parser, and the **two fake attachments**
(a fake MCP client and a fake one-turn command with different capabilities) that NFR-12 asks for;
a list using only the fake pump must never call anything named `claude`; the model gateway with a fake model (the router cannot pick a handle outside the conversation, the budget stops it, an injected message cannot add a member); a signed chain verifies, and a tampered packet, a wrong signer and a broken `reply_to` each fail `facilitator verify`. Feature scenarios
(`devcontainer features test`) check the install on the base images and idempotence. Real-vendor
tests are a manual checklist in `NOTES.md` (T1 above, then each vendor: attach, one message, one
reply, a hop limit), run with the engineer's own credentials; none runs in CI.

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
  run half (a harness; optional)               connect half (the communication; what the facilitator uses)
  kinds resident / on-demand                    E4 participant definition (the list and its new keys)
  lease, session names                          E3 identity and signing (keys, packets)
  adapter verbs: start wake attach stop ...     E2 directory registration (OASF record)
  `agents up` at container start                E1 attachment endpoint (MCP receive reply say who, pump)
```

The run half is kept because the host and the workstation launcher depend on it, and moves into the
component. The connect half is new. Neither is a user-facing Feature.

### 7.2 The deprecation path (nothing breaks without a major version)

The repository has no written deprecation convention (CONTRIBUTING.md does not mention one);
proposed here as D21: a Feature or option is deprecated in a **minor** (a notice from `version` and
`check`, in NOTES, and under "Deprecated" in the CHANGELOG, behaviour unchanged) and removed only in
the next **major**.

| Release | What changes | What a consumer does |
|---|---|---|
| `agents` 2.2.0 and `claude-code` (next minor) | the component is extracted; `claude-code` gains `participants` (7.3), which installs it; `agents` says in one line "deprecated, use claude-code `participants: true`" and, when the component is already installed by `claude-code`, installs nothing of its own. **Task names (`task agents:*`), the `agents` command, `AGENTS_FILE` and `.devcontainer/agents.yml` are unchanged.** | nothing is required. To move: set `"participants": true` on `claude-code`, remove the `agents` reference, optionally rename the file to `participants.yml` |
| `agents` 2.x | bug fixes only, no new keys; the new participant keys land in the component and are read from `participants.yml` or `agents.yml` alike | as above |
| `agents` 3.0.0 (the retirement) | installs nothing and prints where to go; `:2` stays in the registry. Released only when: (a) `claude-code` has carried the component for at least one release; (b) the office and DSNP, the documented adopters of `agents` (their `.devcontainer/DEVCONTAINER_CONTRIBUTION.md` says what each adopts; this repository sees their use only through that and the reference architecture), have moved; (c) the `devcontainer-cli` launcher's `devcontainer:agent` tasks are shown to work on the component alone; the Operator starts that release | remove the `agents` line if still there; `agents.yml` keeps working until the component's own next major |
| the component's next major | `agents.yml` and `AGENTS_FILE` aliases removed, and the `agents:` task namespace gets a `participants:` alias or replacement | rename the file and the settings (a CHANGELOG note in each vendor Feature) |

This repository's own devhost moves first (`.devcontainer/devcontainer.json` lists `./features/agents`
today). A decision record for the deprecation, partly superseding ADR-0036 (the lease and
integrations stay, in the component) and the Feature name `copilot-cli` in ADR-0037, is written
when the Operator rules.

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
newer wins, and the component is backward compatible within a major (NFR-5). The **vendor Feature's
options**:

| Option | Default | What |
|---|---|---|
| `participants` | `false` | install the component: the participant file reader, the `agents:` tasks, the run half and the connect half. The definitions are in the file, not in the option, because Feature options are flat strings and the list is already a committed file |
| `attach` | empty | `facilitator` registers the component's MCP attachment (E1) with this CLI **through the CLI's own supported command**, as `claude-code` already does for the register's MCP at user scope; other values reserved |

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
augment (NFR-4) is not checked and is the first thing slice 3 looks up. Gemini follows the same
pattern later.

### 7.4 The interoperability endpoints

Four local contracts, versioned with the component, that any Feature may consume:

| Endpoint | Contract | Consumer today |
|---|---|---|
| **E1 attachment** | `participant mcp`: stdio MCP server with `receive`, `reply`, `say`, `who`; it forwards to a **conversation service** found through `/usr/local/lib/dcf-participant/services.d/`; with none installed the tools answer "no conversation service" | the facilitator installs its service there |
| **E2 directory registration** | `participant register <name>`: writes the participant's OASF record to the configured directory (the register's `agents` type or AGNTCY `dir`, 4.8) | the facilitator's directory client; any Feature that wants the roster |
| **E3 signed packets** | `participant sign` and `participant verify-packet`: the register's entry format, signed by the identity key the component fetches from OpenBao | the facilitator's signer and `facilitator verify`; a ledger-writing Feature |
| **E4 definition** | `participant list --json`: each participant as the component reads it | everything above |

**Where the line falls:** the component and the vendor Features own *who a participant is and how
it connects*; the facilitator Feature owns *what happens to a conversation* (modules, routing,
limits, backends, AGNTCY). The facilitator needs the connect half only and carries no vendor
knowledge; its pump and snippets call E4. A repository that never installs the facilitator still has
the definition, the run half and the endpoints.

## 8. Slices

0. **Spike (a learning run, no Feature):** run `dirctl daemon` and a SLIM node by hand in this
   devhost: confirm asset names, checksums, linux arm64, ports, state paths, memory and start-up
   time, and a Python client sending and receiving on SLIM. It replaces every "not checked" in 4.8
   before slice 4. May run at any time.
1. **Component extraction** (no new behaviour): `components/participant/` from `src/agents`, the
   `components:sync` and `components:check` tasks, tests with two fake adapters, `claude-code`'s
   `participants` option, `agents` 2.2.0 with the deprecation notice, this repository's devhost moved
   to `claude-code` with `participants: true`. Task names unchanged.
2. **The connect half and the facilitator, lean:** E1 to E4 (E3 unsigned), `claude-code`'s `attach`,
   the local-model wrapper, `facilitator` 0.1.0 with `backend: lean` only (`agntcy` refused "not
   yet"); one manual run, **Claude Code over MCP plus a local model** (the jester scenario), and T1.
3. **The `copilot` Feature** 0.1.0: install (verified), `participants`, `attach`,
   `agent-adapter-copilot`; the second real vendor for the component's contracts (NFR-12).
4. **The AGNTCY backend:** `infra`, `dir` and SLIM, `backend switch`; the default becomes `agntcy`
   here, with a "what changed" note.
5. **Provenance:** E2 and E3 for real (OASF records, signing with keys in OpenBao), `facilitator
   verify`, `directory export`.
6. **The model in the loop:** `serve`, the model gateway, the router's gap-filling, planner,
   collector/summariser, the budget.
7. **Retirement and reach:** `agents` 3.0.0 once its conditions hold (7.2), Gemini, Identity opt-in,
   per-agent Linux users, transcripts to the shared folder. The order of 3 to 7 is the Operator's.

**Out of scope:** the facilitator Feature supervising or starting participants (the run half of the component may, on request);  the Agent Connect Protocol (archived); AGNTCY components across containers or machines; networking between containers or machines
(a later requirement: the same tools over a bridge, probably A2A, which the register's messages are
already shaped for); other people's agents; installing or logging in to vendor CLIs; billing or
price tables; a web UI.

## 9. Risks and open questions

- **The loop on `receive` may not hold** (T1): a model may stop looping, hit a tool timeout or
  burn tokens waiting. Mitigation: shorter waits, the pump; named, not hidden.
- **Prompt injection through a participant's message** reaches another participant as its input.
  The hop limit does not stop it; each CLI's sandbox and permissions do (the inventory).
- **Attribution is weak** with one Linux user (section 5), and the signer attests the route, not
  the intent (4.7).
- **A model in the router** can be argued into a wrong choice; bounded by enumerated handles, the
  budget and a human `/veto`, not removed.
- **Two signed stores** (register and unsigned JSONL) can drift; one interface and one test suite.
- **What could force the hatch to `lean`:** (1) **immaturity**: neither page states a maturity level,
  and SLIM is already on a third major version, so APIs may move under a pin; (2) **weight**: a Go
  daemon, a Rust node and a native Python client in every MCP server instance, memory and start-up
  unmeasured (the spike); (3) **no linux arm64** build or wheel, not visible on the pages read;
  (4) **authentication set-up**: four SLIM auth modes, and secrets to keep in OpenBao; (5) **Docker**
  for Identity and for `dir`'s Compose route, which does not start on every host. A user switches
  with `backend: lean` and `facilitator backend switch lean` (4.8); conversations survive.
- **The component is a new pattern** (a vendored directory, not a script): drift between vendored
  copies, two vendor Features installing different versions, and the release workflow possibly
  tripping on a folder without a `devcontainer-feature.json`; mitigated by `components:check`, the
  newer-wins rule and slice 1 being behaviour-neutral.
- **Deprecation reaches the Operator's own devhost first** (it lists `./features/agents`), and the
  launcher's `devcontainer:agent` tasks call into it; slice 1 and the retirement condition (c) cover
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
- **A participant that answers slowly** holds its chain; no timeout on a reply in slice 1 beyond
  the human's `/continue`. Open.
- **Group etiquette**: many members and no facilitator-role participant means broadcast; bounded
  only by the limits. Open whether to require a facilitator for groups over three.

## 10. Decisions for the Operator

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | The primary attachment | (a) MCP with a blocking `receive`; (b) the pump everywhere (a one-turn command per message); (c) a pty bridge into the running TUI | **(a)**, with (b) as the per-vendor fallback; confirm with T1 before slice 2 |
| D2 | Who decides who speaks | deterministic only; a model decides every hop; hybrid | **Hybrid**: an explicit `@handle` is always by rule, the facilitator model fills gaps, plans and summarises (4.3); the deterministic core runs without it |
| D3 | The store and signing | unsigned JSONL first, signing with the register in slice 3; the register from slice 1; own signed format | **Register is the store of record (4.6); slice 1 unsigned so a downloader can start; slice 3 signs.** Needs the Operator's ruling on making the register pullable (it is vendored from a private registry) |
| D4 | Where participants are defined | one list, the component's `participants.yml` with `agents.yml` as an alias; a new `facilitator.yml` for participants; a section of `agents.yml` | **One list** (`participants.yml`, alias `agents.yml`); `facilitator.yml` only for the application's own settings (4.1, 7.2) |
| D5 | The `agents` Feature (replaces the first draft's "keep") | keep; deprecate; retire at once | **Deprecate in 2.2.0, no behaviour change, retire in 3.0.0 under the three conditions of 7.2**; the Operator's ruling |
| D6 | The Feature name | `facilitator`; `agent-facilitator`; `agent-chat` | **`facilitator`** |
| D7 | The runtime | Python 3.11 stdlib (as the register); a Go binary; bash only | **Python stdlib**, a stated requirement in NOTES; bash cannot hold the MCP server comfortably |
| D8 | Ship a local-model wrapper | yes, small; no, a participant brings its own | **Yes**: nothing else gives a bare model an attachment |
| D9 | Loop guards | defaults 6 hops, 40 messages, 10 a minute; other | **As written**, a human `/continue` extends |
| D10 | Identity | per-participant token files now; none; per-user later | **Tokens now**, per-user with `agent-linux-user` |
| D11 | Slice-1 vendors | Claude + local model; Copilot + local model; all three | **Claude + local model**, Copilot and Gemini in slice 2 |
| D18 | Where the shared component lives | `components/participant/` vendored like `src/common`; a new directory in `src/common`; a published Feature | **`components/participant/`**, same sync and check pattern in directory form (7.3) |
| D19 | How a vendor Feature opts in | `participants` boolean plus `attach`, definitions in the file; the list inside an option string; a separate Feature | **`participants` and `attach`**, definitions in the file (7.3) |
| D20 | Copilot CLI's home | in `gh`; a new `copilot` Feature | **A new `copilot` Feature**, `installsAfter` `gh` (7.3) |
| D21 | A deprecation convention | write it in CONTRIBUTING (deprecate in a minor, remove in the next major); ad hoc | **Write it**, applied first to `agents` (7.2) |
| D22 | Task and command names | keep `agents:` and `agents` in the component until its next major; rename now to `participants:` | **Keep**, alias later, so no consumer changes a script (7.2) |
| D13 | The backends | real AGNTCY (`dir`, SLIM) default with a `lean` hatch; lean only; AGNTCY only | **The Operator's ruling: `backend: agntcy` default, `lean` on the register, one interface, no silent fallback, conversations in the register either way** (4.8) |
| D16 | Order of slices | spike then lean then AGNTCY (as 8); AGNTCY first; model-in-the-loop first | **Spike, lean thin slice, AGNTCY backend**: the lean slice proves the experience, the spike de-risks the components |
| D17 | AGNTCY Identity | opt-in later; default now; never | **Opt-in later** (needs Docker, no stated version) |
| D14 | Where keys live | signer holds them (OpenBao, ssh-agent); each participant holds its own | **Signer, OpenBao at rest, ssh-agent for a sitting**; own key as an option |
| D15 | Facilitator model default | local endpoint; a vendor command; an attached participant | **None by default** (rules only); the engineer names one; a local endpoint is the documented first choice |
| D12 | Transcripts | volume only, export on request; committed to the repo; shared folder | **Volume only**; shared folder later |

Decisions needed from the Operator: all twenty-two (D5 and D13 are already the Operator's rulings, here for the record), in particular D1, D3, D16, D18 and D20.

**Open questions.** Q1: what "the sign-packet feature" is: no such Feature exists here; read as the
register's entry signing; please confirm or point to it. Q2: is the facilitator application's
`serve` acceptable as one more process a harness runs (4.3), given that the deterministic core
does not need it? Q3: should a human be able to veto a plan by default?

## Architecture review

Not yet written: the `architecture-review` skill runs on this proposal before the Operator rules.

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
