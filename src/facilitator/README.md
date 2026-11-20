
# facilitator (conversations between agents of any vendor, on AGNTCY) (facilitator)

The communication layer between agents of any vendor running in the devcontainer: an MCP server each participant's CLI starts (receive, reply, say, who), deterministic routing by @handle with hop, budget and rate limits, every message a sign-packet packet in a register-engine conversation register, verified back to the human who began it. Runs on the AGNTCY Agent Directory (dirctl) and a SLIM node, on loopback, started as infrastructure; never starts, stops or configures a participant. Includes a local-model wrapper for any OpenAI-compatible endpoint and a terminal chat.

## Example Usage

```json
"features": {
    "ghcr.io/nabil-becker/devcontainer-features/facilitator:0": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| installTaskfile | Install this Feature's Taskfile into /usr/local/share/go-task/includes.d so its tasks appear under facilitator: in a root Taskfile that includes /usr/local/share/go-task/features.yml (the go-task Feature). | boolean | true |
| backend | What carries the directory and delivery: agntcy (the AGNTCY Agent Directory and SLIM). lean (packet-relay) is refused in this version: not yet, slice 5. FACILITATOR_BACKEND overrides. | string | agntcy |
| dirVersion | The AGNTCY Directory release (dirctl) to install, verified against the SHA-256 pinned in install.sh. latest means the version pinned here (1.9.1); another version needs its checksums added. | string | 1.9.1 |
| slimVersion | The slimctl release (which carries the SLIM node: slimctl slim start) to install, verified against the SHA-256 pinned in install.sh. latest means the version pinned here (3.4.6). | string | 3.4.6 |
| hopLimit | Participant-to-participant deliveries since the human's message before the conversation pauses (/continue resumes). FACILITATOR_HOP_LIMIT. | string | 6 |
| messageBudget | Messages a conversation may hold between two /continue before participants' messages are held. FACILITATOR_MESSAGE_BUDGET. | string | 40 |
| rateLimit | Messages a participant may write in a minute; one more is refused. FACILITATOR_RATE_LIMIT. | string | 10 |
| receiveWaitSeconds | How long the MCP tool receive blocks when no wait_seconds is given. FACILITATOR_RECEIVE_WAIT_SECONDS. | string | 300 |
| staleSeconds | After this long without a receive a participant counts as not attached: its messages wait, and the sender is told. FACILITATOR_STALE_SECONDS. | string | 900 |
| facilitatorBudget | Model calls the facilitator application may make per conversation. Read and shown; no model is called before slice 6. FACILITATOR_BUDGET. | string | 20 |
| identity | Also run AGNTCY Identity (needs Docker). Refused in this version when true: not yet, slice 7. | boolean | false |
| autostart | postStartCommand starts the infrastructure (facilitator infra up: the Directory, the SLIM node, the facilitator's ssh-agent), never fatally. Participants are never started. FACILITATOR_AUTOSTART. | boolean | true |
| dirOnlineCheck | Check each pushed agent record against the online OASF schema server (schema.oasf.outshift.com); off, records are checked offline (the Directory's policy.operations: []). FACILITATOR_DIR_ONLINE_CHECK. | boolean | false |

## How it fits

```text
  you: facilitator chat / send            participants, kept running by THEIR harness (never by this Feature)
        |                                  claude (MCP)            local model (model wrapper)
        |                                      | stdio                  | /v1/chat/completions
        v                                      v                        v
  facilitator application: intake -> guard -> router -> dispatcher -> collector     (deterministic, no model)
        |  signer: sign-packet, keys in OpenBao (or the 0.1.0 fallback file)
        |  record: register-engine, one `conversation` register per conversation
        |  transport: SLIM (slim-bindings)     directory: AGNTCY Directory (dirctl)
        v
  infrastructure the Feature starts on loopback: dirctl daemon (8888, 5555, 8999, 8889), SLIM node (46357), ssh-agent
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Conversations (signed registers), the roster of identities, attachment times | `/var/lib/devcontainer-features/facilitator` (volume `facilitator-state-${devcontainerId}`) | 4 working set (lost with the volume, never committed; ADR 0045) |
| Identity keys | OpenBao `facilitator/keys/<handle>`; fallback: `keys/<handle>` (mode 600) in the volume | none (OpenBao); 4 working set for the fallback |
| Participant tokens | `tokens/<handle>` (mode 600) in the volume, made again at every container start | 4 working set |
| SLIM's secrets (basic-auth password, app secret) | OpenBao `facilitator/slim`; fallback `secrets/slim.json` (mode 600) | as the keys |
| The Directory's records and node key | `dir/` in the volume | 4 working set |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: none yet

## What it is

The communication layer between agents of any vendor running in one devcontainer (proposal
`docs/proposals/facilitator-agent.md`, ADR-0061). Participants are external processes: a Claude Code
session, a local model, later Copilot and Gemini. **The Feature never starts, stops, configures or
resumes a participant** (NFR-13): its job is how a running participant is addressed, how a message reaches
it, how replies come back, routing, limits and the record.

- **Attachment:** a participant's CLI starts `facilitator mcp --as <handle>`, an MCP server over stdio with
  four tools. A participant asks for its mail: `receive` blocks until a message is delivered.
- **Routing, deterministic** (no model in 0.1.0): every `@handle` in the text is delivered, each once
  ("@jester tell @domain-expert-one a joke" goes to both; the Operator's ruling of 2026-11-20 undid the
  first version's addressed-only reading), plus `to`, or `@all`; the hop count bounds the chain. No mention
  in a direct conversation goes to the other member, in a group to the `fallback` participant or everyone;
  a reply with no mention goes back to the asker. A participant
  that is not attached is never skipped: its message waits, the sender is told, and it is delivered when
  the participant calls `receive`.
- **Limits:** hop limit (6), message budget (40), rate (10 a minute); `/continue` resumes.
- **The record:** every message is a sign-packet packet signed with its writer's key, an entry of a
  register-engine register of the `conversation` type that this Feature supplies. `facilitator verify`
  walks each message back to the human who began the chain.
- **AGNTCY:** each participant's OASF record is pushed to the AGNTCY Agent Directory; delivery goes over a
  SLIM node, through `slim-bindings` directly (no `slim-mcp`, ruling E).

## What it installs

| Path | What |
| --- | --- |
| `/usr/local/bin/dirctl` | AGNTCY Directory v1.9.1 (CLI and daemon), the release asset, verified against the SHA-256 pinned in `install.sh` |
| `/usr/local/bin/slimctl` | slimctl 3.4.6, which carries the SLIM node (`slimctl slim start`), from the gnu release tarball, verified the same way |
| `/usr/local/lib/facilitator/venv/` | The Feature's own venv with `slim-bindings` 3.3.9 (it reports node 3.4.6): the manylinux wheel downloaded with the collection's download helper, checked against its pinned SHA-256, then installed with `pip --require-hashes --no-index` |
| `/usr/local/lib/facilitator/` | The application (`facilitator/`), its own copies of register-engine's and sign-packet's libraries (ADR-0062: it installs alone), the `conversation` type (`types.d/facilitator.py`), the Directory's and SLIM's config templates (`agntcy/`), the options as installed (`options.env`) |
| `/usr/local/lib/register-engine/types.d/facilitator.py` | The same type, for `register-engine verify --type conversation`, when the register-engine Feature is installed |
| `/usr/local/bin/facilitator`, `facilitator-setup`, `facilitator-start` | The command (run isolated, `python -I`) and the post-create and post-start hooks |
| `/usr/local/share/go-task/includes.d/facilitator.yml` | The Taskfile (`installTaskfile`) |

**How the downloads are verified.** Each download goes through the collection's download helper
(`dcf_curl`, ADR-0034) and `sha256sum -c` against a SHA-256 pinned in `install.sh` per architecture
(linux amd64 and arm64) before anything is installed; a mismatch fails the build. Where each hash came from
(checked 2026-11-20): **dirctl** publishes no checksum file and no signature per asset; its pin is the
GitHub release API's asset digest, which equals the subject of the release's SLSA provenance
(`dirctl-v1.9.1.intoto.jsonl`; that provenance's own signature was not verified). **slimctl**: the release
API's digest, for tarballs whose sigstore bundles were verified by identity (agntcy/slim's release-rust
workflow) in the spike of 2026-11-19. **slim-bindings**: PyPI's SHA-256 for the wheel. No pip index is used,
so no exception to ADR-0034 is needed. Python 3.11 or later, `python3-venv`, OpenSSH, curl and tar come from
the distribution's apt when missing. glibc only (the pinned builds are gnu/manylinux).

## Using it in devcontainer.json

```jsonc
"features": {
  "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
  "ghcr.io/nabil-becker/devcontainer-features/openbao:1": {},       // optional: keys in OpenBao
  "ghcr.io/nabil-becker/devcontainer-features/facilitator:0": {}
}
```

Then, in the repository: `.devcontainer/participants.yml` (or the existing `.devcontainer/agents.yml`):

```yaml
participants:                      # or agents: (the participant component's list, ADR-0061)
  - name: jester                   # the handle: lowercase letters, digits, - and _
    cli: openai-compatible
    kind: resident
    definition: personas/jester.md # the persona, sent as the model's system prompt
    description: tells jokes       # into the OASF record
    skills: [humour]
  - name: domain-expert-one
    cli: claude
    kind: resident
    attachment: mcp                # mcp (the default) | pump (a later slice)
```

and, optionally, `.devcontainer/facilitator.yml`:

```yaml
facilitator:
  humans: [you]                    # the people at a terminal (default [you])
  fallback: domain-expert-one      # gets a group message addressed to no one (default: everyone)
```

## Verify

```sh
facilitator version          # facilitator 0.1.0 (backend agntcy; ...), dirctl 1.9.1, slimctl 3.4.6, slim-bindings 3.4.6
facilitator infra status     # agent, dir and slim healthy, every port on 127.0.0.1
facilitator check            # one line per part; exit 0 when ready
```

The jester scenario, from a terminal (the participants are started by you or your harness):

```sh
facilitator register --all                       # keys, tokens, OASF records in the Directory
facilitator snippet domain-expert-one            # how to attach its Claude Code (prints commands, runs none)
FACILITATOR_TOKEN="$(cat $FACILITATOR_HOME/tokens/jester)" \
  facilitator model --as jester --endpoint http://localhost:11434/v1 --model llama3.2 --definition personas/jester.md &
facilitator chat                                 # then: @jester tell @domain-expert-one a joke
facilitator verify --conv <id>                   # every message back to your signed one
```

## Options

| Option | Default | What, and when to change it |
| --- | --- | --- |
| `installTaskfile` | `true` | The Taskfile, as every Feature. |
| `backend` | `agntcy` | What carries the directory and delivery. `lean` (packet-relay) is refused in this version: "not yet: slice 5". `FACILITATOR_BACKEND`. |
| `dirVersion` | `1.9.1` | The Directory release; `latest` means the pinned 1.9.1. Another version needs its two checksums added to `install.sh`. |
| `slimVersion` | `3.4.6` | The slimctl release (the SLIM node); `latest` means the pinned 3.4.6 (3.5.0 has an image but no release yet, ruling G). |
| `hopLimit` | `6` | Participant-to-participant deliveries after a human's message before the conversation pauses. `FACILITATOR_HOP_LIMIT`. |
| `messageBudget` | `40` | Messages between two `/continue`; past it participants' messages are kept and held. `FACILITATOR_MESSAGE_BUDGET`. |
| `rateLimit` | `10` | Messages a participant may write in a minute; one more is refused, not written. `FACILITATOR_RATE_LIMIT`. |
| `receiveWaitSeconds` | `300` | How long `receive` blocks without `wait_seconds` (a 300 s call held in the T1 run). `FACILITATOR_RECEIVE_WAIT_SECONDS`. |
| `staleSeconds` | `900` | Without a `receive` for this long a participant counts as not attached. `FACILITATOR_STALE_SECONDS`. |
| `facilitatorBudget` | `20` | Model calls per conversation for the AI facilitator; read and shown, unused before slice 6. `FACILITATOR_BUDGET`. |
| `identity` | `false` | AGNTCY Identity (needs Docker); `true` is refused: "not yet: slice 7". |
| `autostart` | `true` | `postStartCommand` runs `facilitator infra up`, never fatally. Turn off to start it by hand. `FACILITATOR_AUTOSTART`. |
| `dirOnlineCheck` | `false` | Check each pushed record against the online OASF schema server; off, the Directory checks nothing (`policy.operations: []`, ruling F). |

**Settings are plain variables too** (NFR-6), resolved: the command line, the repository's `.env`,
`.devcontainer/.env`, the environment, then the options as installed. Besides those above:
`FACILITATOR_HOME`, `PARTICIPANTS_FILE` (alias `AGENTS_FILE`), `FACILITATOR_FILE`, the ports
(`FACILITATOR_DIR_PORT` 8888, `FACILITATOR_DIR_OCI_PORT` 5555, `FACILITATOR_DIR_P2P_PORT` 8999,
`FACILITATOR_DIR_GATEWAY_PORT` 8889, `FACILITATOR_SLIM_PORT` 46357), `FACILITATOR_KEYS` (`auto` | `openbao` |
`file`), `FACILITATOR_DIRCTL` and `FACILITATOR_SLIMCTL` (other binaries), and, for tests only,
`FACILITATOR_TRANSPORT=poll` (no SLIM: the record is read every half second; `check` says so).

## State

`FACILITATOR_HOME` (`/var/lib/devcontainer-features/facilitator`, the named volume
`facilitator-state-${devcontainerId}`, made the remote user's by `facilitator-setup` through `dcf-persist`):
`conversations/<id>/` (one register-engine store per conversation), `roster.json`, `anchors` (the
facilitator's own key, the anchor of every conversation's roster), `keys/` (public keys; private ones only
in the fallback), `tokens/`, `attach/` (when each participant last called `receive`), `dir/` (the
Directory's data, `node.key` included), `slim/` (its rendered config), `secrets/` (fallback only), `run/`
(pidfiles, the ssh-agent's socket), `logs/`. **Conversations are working data**: lost with the volume,
never committed (D12); a tier-2 mirror is a later item.

### Keys: OpenBao, or the 0.1.0 fallback (an ADR-0048 exception)

`facilitator register` makes an Ed25519 key per identity (each participant, each human, and
`facilitator`). When OpenBao answers `ready` (`dcf-secret status`), the private half goes to
`facilitator/keys/<handle>` and is never written to a file: it is loaded through a pipe into the
facilitator's own ssh-agent for the sitting, and packets are signed through the agent. **When OpenBao is
not ready, the private key is kept in `keys/<handle>`, mode 600, in the volume, and `keys/FALLBACK` says
so.** This is a written exception to ADR-0048 for 0.1.0 only: a downloader without the openbao Feature can
still sign. The fallback stays for the 0.x versions and is removed at 1.0 (the Operator's ruling of
2026-11-20): from 1.0 a key is only ever in OpenBao. `facilitator register <handle> --new-key` moves a key
into OpenBao once it is there.
`FACILITATOR_KEYS=openbao` refuses the fallback.

### Participant tokens (the ADR-0048 exception of ADR-0061)

`tokens/<handle>` (mode 600) is made at registration and again at every container start
(`facilitator-start`), valid only in this container. The participant's harness puts it in the CLI's
environment as `FACILITATOR_TOKEN`; the MCP server it starts inherits it and is refused without it. The
token is never written into the CLI's MCP entry (`claude mcp add`, an MCP config file), because tokens are
made again at each start and an entry would go stale; `facilitator snippet` says so. Every
process of one Linux user can read every token: this stops one participant writing as another by
mistake, not an attacker.

## Commands and tasks

| Task | Command | What |
| --- | --- | --- |
| `facilitator:version` | `facilitator version` | What is installed. |
| `facilitator:check` | `facilitator check` | One line per part, each port's owner when it is taken, each participant registered and last seen; no secret printed; exit 1 when not ready. |
| `facilitator:setup` | `facilitator-setup` | The state folder and the facilitator's key (idempotent, never fatal). |
| `facilitator:infra` | `facilitator infra up\|down\|status\|logs [agent\|dir\|slim]` | The infrastructure; `up` is idempotent, nothing is restarted on a crash (`status` says so). |
| `facilitator:participants` | `facilitator participants` | The list and who is registered. |
| `facilitator:register` | `facilitator register <handle>... \| --all` | Key, token, OASF record. |
| `facilitator:status` | `facilitator status` | Who is attached; each conversation's messages, hops, budget, pause. |
| `facilitator:chat` | `facilitator chat [<conv>]` | Interactive: `@handle ...`, `/new group a b`, `/new direct a`, `/conv`, `/continue`, `/who`, `/quit`. |
| `facilitator:send` | `facilitator send --text ... [--conv] [--to] [--json]` | For scripts; with no `--conv` a conversation is made with the handles named. |
| `facilitator:transcript` | `facilitator transcript --conv <id> [--json]` | Messages, routes, task states, notices. |
| `facilitator:verify` | `facilitator verify --conv <id> [--message <id>] [--format json]` | Exit 0 a good chain, 1 a break, 2 bad usage. |
| `facilitator:snippet` | `facilitator snippet <handle>` | The `claude mcp add` command (or the MCP entry), the token line and the persona sentence. |
| (a harness runs it) | `facilitator mcp --as <handle>` | The MCP server a CLI starts. |
| (a harness runs it) | `facilitator model --as <h> --endpoint <url> --model <m> --definition <file>` | The local-model wrapper. |
| (`postStartCommand`) | `facilitator-start` | Tokens made again; `infra up` when `autostart`. |

### The MCP tools (the attachment contract)

| Tool | Arguments | Returns |
| --- | --- | --- |
| `receive` | `wait_seconds?` (0 to 3600) | `MESSAGE in conversation ...` with `structuredContent.message` {conversation, message_id, from, text, members, hops, parts}; or `nothing yet`. Several replies to one question waiting at once come as one turn (the collector, plain joining). |
| `reply` | `text`, `to?` | Answers what `receive` handed over (`reply_to`, hops + 1); no mention: back to the asker. Completes the delivery's A2A task. |
| `say` | `text`, `conversation?` (an id or `new`), `to?` | A turn in another conversation; needs a message received first (every chain begins with a human). |
| `who` | none | The handles, attached or not, and your conversations. |

### The record: the `conversation` register type

One register per conversation, named by its id (`c-<8 hex>`); the facilitator's key is the anchor and
writes the roster (each member's key, role `agent`). The kinds (field names from AOF's `messages` type):

| Kind | Data | Written by |
| --- | --- | --- |
| `thread` | `thread, kind (group\|direct), members[], humans[], title?` | facilitator |
| `message` | `thread, message_id, parts[{kind: text, text}], root, hops, reply_to?, mentions?, to?, refs?` | the member it is from |
| `route` | `thread, message_id, rule, to[], tasks[{task, assignee}], held[{principal, reason}]` | facilitator |
| `status` | `task, state (working\|completed\|...), text?` | the task's assignee |
| `notice` | `thread, code (stale\|hop-limit\|budget\|paused\|not-member\|unknown-handle\|...), text, refs?` | facilitator |
| `continue` | `thread, upto` | a human member |

Lineage: `reply_to` (what it answers), `refs` (what it derives from, the root always last), `root` (the
human message the chain began with; a human's message is its own root at hops 0), `hops`, and the A2A
task of each delivery in its route.

## Pairs with

- **openbao**: keeps the keys and SLIM's secrets; without it, the 0.1.0 fallback files.
- **claude-code**: a Claude Code participant; `facilitator snippet <handle>` prints its `claude mcp add`.
  The claude-code Feature's `attach` option (a later step) will run that through the CLI's own command.
- **copilot**: a GitHub Copilot CLI participant; its `attach: facilitator` registers one MCP entry through
  `copilot mcp add` that takes the handle from `FACILITATOR_HANDLE` and the token from `FACILITATOR_TOKEN` in
  the environment (no token in the entry), and its `agent-adapter-copilot run-once` is the pump's route.
- **register-engine**: optional; with it, `register-engine verify <store> --register <id> --type conversation`
  reads a conversation too. This Feature carries its own copy of the engine and of sign-packet's library.
- **go-task**: the Taskfile. Needs Python 3.11 and OpenSSH, installed with apt when missing.

## Limits

- One container: participants, the Directory and SLIM are on loopback; across containers is a later item.
- `agntcy` only; `lean` (packet-relay) is slice 5, and there is **no silent fallback**: when the
  Directory or SLIM cannot start, `check` says why.
- No model in the facilitator (slice 6): a group message addressed to no one goes to the `fallback`
  participant or to every member, bounded by the limits. `facilitatorBudget` is unused.
- The pump attachment and the vendor Features' `attach` option are not in this version.
- A slow participant holds its chain; no reply timeout before the human's `/continue`.
- The participant component's own `agents` command does not know `participants:`, `attachment`,
  `description` or `skills` yet; it warns on the three keys and reads only `agents.yml`.
- SLIM runs basic auth over plain-text loopback (its log warns about it); the SLIM node keeps no state, so a
  restart drops sessions (the record keeps every message).
- Attribution is "which registered identity, via which authenticated route", not proof of intent, with
  one Linux user for every participant.
- Troubleshooting: `facilitator check` names the part and a port's owner; `facilitator infra logs dir|slim`;
  `facilitator verify` names each broken link.

### Manual checklist (real vendors, with your own credentials; none runs in CI)

1. `facilitator infra up && facilitator register --all && facilitator check`.
2. Claude Code: `facilitator snippet domain-expert-one`, run the `claude mcp add` it prints, start Claude with
   the token line, give it the persona sentence: it calls `receive`.
3. A local model: `facilitator model --as jester --endpoint <url> --model <name> --definition <file>`.
4. `facilitator chat`: `@jester tell @domain-expert-one a joke`; four messages, then `facilitator verify --conv <id>`.
5. A hop limit: two agents told to answer each other; the conversation pauses at `hopLimit`; `/continue`.

## Why it exists

No published Dev Container Feature connects agents of different vendors in a devcontainer. AGNTCY
publishes the Directory and SLIM but no conversation store, limits or signed record; MCP gateways connect
one client to many servers, not agents to each other. This Feature runs AGNTCY's components as
infrastructure and adds what they leave out.

## Version and upgrade

Pinned: dirctl 1.9.1, slimctl 3.4.6, slim-bindings 3.3.9 (node and bindings move together). An upgrade
of the Feature replaces the library and the binaries; the volume (conversations, keys, tokens, the
Directory's data) is kept. A new AGNTCY version is a new Feature version with its checksums added; the
Directory config template follows the pinned dirctl's `daemon config init`. 0.x: the MCP tools, the
packet fields and the CLI verbs may still change before 1.0.

## Inside

| Path | What |
| --- | --- |
| `facilitator/app.py` | intake, the dispatcher, the participant session (receive, reply, say, who) |
| `facilitator/router.py`, `guard.py`, `collector.py` | the routing rules, the limits, plain joining |
| `facilitator/record.py`, `signer.py`, `verify.py` | the record over register-engine, keys and signing, `verify` |
| `facilitator/transport.py`, `directory.py`, `infra.py` | SLIM, the Directory client, the infrastructure |
| `facilitator/mcp.py`, `model.py`, `chat.py`, `cli.py` | the MCP server, the model wrapper, chat, the command |
| `types.d/facilitator.py` | the `conversation` register type |
| `registerengine/`, `signpacket/` | copies of `src/register-engine` and `src/sign-packet` (`task registerengine:check`, `task signpacket:check`) |

Tests: `test/facilitator/unit/` (`task test:facilitator-unit`, part of `task lint`) and
`test/facilitator/integration/jester_flow.py` (`task test:facilitator-integration`; the `jester_flow` scenario).

## Changes

### [0.1.0] - 2026-11-20

#### Added

- The facilitator, first version, on AGNTCY (ADR-0061, slice 3 of the facilitator proposal): conversations
  between agents of any vendor in one devcontainer, by `@handle`, with a hop limit, a message budget and a
  rate limit, every message a signed packet in a register-engine `conversation` register, and
  `facilitator verify` walking each message back to the human who began the chain.
- The MCP server `facilitator mcp --as <handle>` (tools `receive`, `reply`, `say`, `who`), authenticated by a
  participant token; the local-model wrapper `facilitator model`; `facilitator chat`, `send` and
  `transcript --json`; `facilitator snippet` for attaching a Claude Code participant.
- The infrastructure on loopback, started by `facilitator infra up` and by `autostart`: the AGNTCY Directory
  (dirctl 1.9.1) and a SLIM node (slimctl 3.4.6), each pinned by SHA-256; slim-bindings 3.3.9 in the
  Feature's own venv.
- Keys in OpenBao when it is ready; otherwise, in mode-600 files in the volume. This fallback stays for the 0.x
  versions and is removed at 1.0, when a key will only ever be in OpenBao.
- Every `@handle` in a message is delivered, each once, as the proposal's routing rule 1 says: "@jester tell
  @domain-expert-one a joke" goes to both (the Operator's ruling of 2026-11-20). The hop count bounds the chain.
- The participant token reaches `facilitator mcp` through the agent's environment, set by its harness, never in
  the CLI's MCP entry, because tokens are made again at each start.
- Version 0.1.0 rather than 1.0.0: the MCP tools, the packet fields and the verbs may change before 1.0.

The full history is in [CHANGELOG.md](https://github.com/nabil-becker/devcontainer-features/blob/main/src/facilitator/CHANGELOG.md).

---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nabil-becker/devcontainer-features/blob/main/src/facilitator/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
