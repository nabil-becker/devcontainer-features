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
| **Harness** | Whatever keeps a participant process running: tmux, a process supervisor, a service, the vendor's own session, the `agents` Feature. Not this Feature's job. |
| **Attachment** | How a running participant connects to the layer. Primary: **MCP** (tools `receive`, `reply`, `say`, `who`). Fallbacks: the **pump** (a loop that does `receive` and runs a one-turn command), and the **model wrapper** (a pump for an OpenAI-compatible endpoint). |
| **Conversation** | A thread with members: **direct** (you and one participant, or two participants) or **group** (three or more). Held as in the register's `messages` type: group and direct, A2A-shaped. |
| **Turn** | One message by a participant in a conversation. A turn's **hops** are the number of participant-to-participant deliveries since the last human message. |
| **Mention routing** | Delivery by `@handle` in the text or the `to` argument, always honoured; no mention is for the router module (4.3, 4.4). |
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
    attachment: mcp                # the participant's own CLI calls the tools
    agent: expert                  # optional: a name in agents.yml, shown by `facilitator status`; never started from here
  - name: copilot-lead
    attachment: mcp
    facilitator: true              # at most one; the fallback for what is addressed to no one when the application is not running
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

Installs: the `facilitator` command (the modules of 4.3, an MCP server over stdio, `chat`, `pump`, the
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

0. **Spike (a learning run, no Feature):** run `dirctl daemon` and a SLIM node by hand in this
   devhost: confirm asset names, checksums, linux arm64, ports, state paths, memory and start-up
   time, and that a Python client can send and receive on SLIM. Its findings replace every
   "not checked" in 4.8 before slice 2 is built.
1. **Thin slice** (`facilitator` 0.1.0, `lean` only; `backend: agntcy` is refused with "not yet"):
   participant file, the backend interface, direct and group, `@mention` routing, hop limit and
   budget, the MCP server (`receive`, `reply`, `say`, `who`), `chat`, the local-model wrapper, tests
   with fakes; one manual run: **Claude Code over MCP plus a local model** (the jester scenario),
   and T1. The record is the register where it can be pulled, else the unsigned store (D3).
2. **The AGNTCY backend:** `infra`, the `dir` and SLIM installs and clients, `backend switch`; the
   default becomes `agntcy` in this release, with a "what changed" note for consumers.
3. **Provenance:** `register` (OASF record, key, roster entry), the signer with keys in OpenBao and an
   ssh-agent, `facilitator verify`, `directory export`.
4. **The model in the loop:** `serve`, the model gateway, router for gaps, planner,
   collector/summariser, the facilitator budget; each with a fake-model test.
5. **Second and third vendors** (Copilot CLI, Gemini CLI over MCP, the pump), **Identity** opt-in,
   per-agent Linux users, transcripts to the shared folder; order for the Operator to set.

**Out of scope:** supervising or starting participants; the Agent Connect Protocol (archived); AGNTCY components across containers or machines; networking between containers or machines
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
| D4 | Where participants are defined | new `facilitator.yml`; a section of `agents.yml` | **New file**, with an optional `agent:` cross-reference |
| D5 | The `agents` Feature | keep; narrow; retire | **Keep unchanged, stop growing its multi-vendor slices, revisit after slice 2** |
| D6 | The Feature name | `facilitator`; `agent-facilitator`; `agent-chat` | **`facilitator`** |
| D7 | The runtime | Python 3.11 stdlib (as the register); a Go binary; bash only | **Python stdlib**, a stated requirement in NOTES; bash cannot hold the MCP server comfortably |
| D8 | Ship a local-model wrapper | yes, small; no, a participant brings its own | **Yes**: nothing else gives a bare model an attachment |
| D9 | Loop guards | defaults 6 hops, 40 messages, 10 a minute; other | **As written**, a human `/continue` extends |
| D10 | Identity | per-participant token files now; none; per-user later | **Tokens now**, per-user with `agent-linux-user` |
| D11 | Slice-1 vendors | Claude + local model; Copilot + local model; all three | **Claude + local model**, Copilot and Gemini in slice 2 |
| D13 | The backends | real AGNTCY (`dir`, SLIM) default with a `lean` hatch; lean only; AGNTCY only | **The Operator's ruling: `backend: agntcy` default, `lean` on the register, one interface, no silent fallback, conversations in the register either way** (4.8) |
| D16 | Order of slices | spike then lean then AGNTCY (as 8); AGNTCY first; model-in-the-loop first | **Spike, lean thin slice, AGNTCY backend**: the lean slice proves the experience, the spike de-risks the components |
| D17 | AGNTCY Identity | opt-in later; default now; never | **Opt-in later** (needs Docker, no stated version) |
| D14 | Where keys live | signer holds them (OpenBao, ssh-agent); each participant holds its own | **Signer, OpenBao at rest, ssh-agent for a sitting**; own key as an option |
| D15 | Facilitator model default | local endpoint; a vendor command; an attached participant | **None by default** (rules only); the engineer names one; a local endpoint is the documented first choice |
| D12 | Transcripts | volume only, export on request; committed to the repo; shared folder | **Volume only**; shared folder later |

Decisions needed from the Operator: all seventeen (D13 is already the Operator's ruling, here for the record), in particular D1, D3, D5 and D16.

**Open questions.** Q1: what "the sign-packet feature" is: no such Feature exists here; read as the
register's entry signing; please confirm or point to it. Q2: is the facilitator application's
`serve` acceptable as one more process a harness runs (4.3), given that the deterministic core
does not need it? Q3: should a human be able to veto a plan by default?

## Architecture review

Not yet written: the `architecture-review` skill runs on this proposal before the Operator rules.
