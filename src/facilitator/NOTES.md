## Deprecated in 0.3.0: `dirVersion` and `slimVersion`

The node bundle fixes the versions of `dirctl` (1.9.1) and `slimctl` (3.4.6), so the two options choose
nothing any more. **Replaced by `bundleVersion`.** To move: delete `dirVersion` and `slimVersion` from your
`devcontainer.json`, and set `bundleVersion` only if you need a bundle other than the one this Feature version
was made with. Until then they keep working as before: the pinned version or `latest` is accepted (with one line
`deprecated: use bundleVersion` from the install, `facilitator version` and `facilitator check`, on stderr), and
any other version is refused, as it was for want of a checksum. They are removed in **1.0.0**, the next major,
released only when no consumer's `devcontainer.json` names them.

## How it fits

```text
  you, in your own Claude Code          participants, kept running by THEIR harness (never by this Feature)
  (or Copilot) session                     claude (MCP)            local model (model wrapper)
        | stdio: say, mail, continue           | stdio: receive, reply  | /v1/chat/completions
        v                                      v                        v
  facilitator mcp (one shared entry; the handle from FACILITATOR_HANDLE, the kind from the roster)
        |
  facilitator application: intake -> guard -> router -> dispatcher -> collector     (deterministic, no model)
        |  signer: sign-packet, keys in OpenBao (or the 0.1.0 fallback file)
        |  record: register-engine, one `conversation` register per conversation
        |  transport: SLIM (slim-bindings)     directory: AGNTCY Directory (dirctl)
        v
  infrastructure the Feature starts on loopback: dirctl daemon (8888, 5555, 8999, 8889), SLIM node (46357), ssh-agent

  one node bundle per architecture, two installers:
  bundles/facilitator/install.sh --(release-bundle, the Operator)--> facilitator-<v>-linux-<arch>.tar.gz + SHA256SUMS
        |                                                                  |                       |
        | copy: bundle-build.sh (source build, no pin yet)    this Feature (mode node | leaf)   the node image (a hub)
        +-------------------------------------------------->  /opt/facilitator                 /opt/facilitator
```

| Data | Where it lives | Storage tier |
| --- | --- | --- |
| Conversations (signed registers), the roster of identities, attachment times | `/var/lib/devcontainer-features/facilitator` (volume `facilitator-state-${devcontainerId}`) | 4 working set (lost with the volume, never committed; ADR 0045) |
| Identity keys | OpenBao `facilitator/keys/<handle>`; fallback: `keys/<handle>` (mode 600) in the volume | none (OpenBao); 4 working set for the fallback |
| Participant and person tokens | `tokens/<handle>` (mode 600) in the volume, made again at every container start | 4 working set |
| What each person has read (the mail tool) | `mail/<handle>.json`, `mail/<handle>.notice` (mode 600) in the volume | 4 working set |
| SLIM's secrets (basic-auth password, app secret) | OpenBao `facilitator/slim`; fallback `secrets/slim.json` (mode 600) | as the keys |
| The Directory's records and node key | `dir/` in the volume | 4 working set |
| The node bundle | `/opt/facilitator` in the image layer; the release asset on GitHub | none (rebuilt from the release; never in the volume) |

Tiers are the four of ADR 0045: 1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

Used in: none yet

## What it is

The communication layer between agents of any vendor running in one devcontainer (proposal
`docs/proposals/facilitator-agent.md`, ADR-0061). Participants are external processes: a Claude Code
session, a local model, later Copilot and Gemini. **The Feature never starts, stops, configures or
resumes a participant** (NFR-13): its job is how a running participant is addressed, how a message reaches
it, how replies come back, routing, limits and the record.

- **Attachment:** a participant's CLI starts `facilitator mcp`, an MCP server over stdio; one shared MCP
  entry serves every agent, each one's handle and token in its environment (`FACILITATOR_HANDLE`,
  `FACILITATOR_TOKEN`; `--as <handle>` still works). An agent asks for its mail: `receive` blocks until a
  message is delivered.
- **A person talks through MCP too** (0.2.0; there is no terminal chat): a human of `facilitator.yml`
  attaches their own Claude Code or Copilot session to the same server with their own handle and token,
  and gets `say`, `mail` (never blocks), `transcript`, `continue` and `who`. "Ask @jester for a joke" is a
  `say`; "any mail?" is a `mail`. In Claude Code a turn hook can print "Facilitator: 2 new messages in
  c-1a2b3c4d" at each prompt.
- **Routing, deterministic** (no model in 0.1.0): every `@handle` in the text is delivered, each once
  ("@jester tell @domain-expert-one a joke" goes to both; the Operator's ruling of 2026-11-20 undid the
  first version's addressed-only reading), plus `to`, or `@all`; the hop count bounds the chain. No mention
  in a direct conversation goes to the other member, in a group to the `fallback` participant or everyone;
  a reply with no mention goes back to the asker. A participant
  that is not attached is never skipped: its message waits, the sender is told, and it is delivered when
  the participant calls `receive`.
- **Limits:** hop limit (6), message budget (40), rate (10 a minute); a person's `continue` resumes. A
  person's message counts as a hop like any other (option A); only `continue` resets the hops.
- **The record:** every message is a sign-packet packet signed with its writer's key, an entry of a
  register-engine register of the `conversation` type that this Feature supplies. `facilitator verify`
  walks each message back to the human who began the chain.
- **AGNTCY:** each participant's OASF record is pushed to the AGNTCY Agent Directory; delivery goes over a
  SLIM node, through `slim-bindings` directly (no `slim-mcp`, ruling E).

## What it installs

| Path | What |
| --- | --- |
| `/opt/facilitator/` | **The node bundle** (below): `bin/facilitator`, `bin/dirctl` (AGNTCY Directory 1.9.1, CLI and daemon), `bin/slimctl` (3.4.6, carries the SLIM node; not in mode `leaf`), `python/` (its own CPython 3.13.18), `lib/site-packages/` (`slim-bindings` 3.3.9, which reports node 3.4.6), `lib/facilitator/` (the application), `lib/registerengine/` and `lib/signpacket/` (its copies, ADR-0062), `lib/types.d/facilitator.py` (the `conversation` type), `lib/agntcy/` (the config templates), `MANIFEST.json` |
| `/opt/facilitator/lib/options.env` | The options as installed |
| `/usr/local/bin/facilitator`, `dirctl`, `slimctl` | Links into `/opt/facilitator/bin` (`slimctl` in mode `node` only) |
| `/usr/local/lib/register-engine/types.d/facilitator.py` | The same type, for `register-engine verify --type conversation`, when the register-engine Feature is installed |
| `/usr/local/bin/facilitator-setup`, `facilitator-start` | The post-create and post-start hooks |
| `/usr/local/share/go-task/includes.d/facilitator.yml` | The Taskfile (`installTaskfile`) |

From the distribution's apt when missing: OpenSSH (the signer), curl, tar and gzip. **No Python from the
system** since 0.3.0: the bundle carries its own. glibc only (the bundle's CPython, slimctl and wheel are the
gnu/manylinux builds).

## The bundle

One built, checksummed **node bundle** per architecture (linux amd64 and arm64), the same bytes for this Feature
and for the node image (ADR-0067, ruling Z1/C). It is built by one portable script,
[`bundles/facilitator/install.sh`](../../bundles/facilitator/install.sh) (bash, curl, tar, gzip, sha256sum; never
root), from this Feature's own source (the application and its copies of register-engine's and sign-packet's
libraries, so the copy checks cover what the bundle carries):

| In the bundle | From | Verified by |
| --- | --- | --- |
| `python/` | python-build-standalone 20261026, CPython 3.13.18 `install_only_stripped`, unchanged but for one `.pth` line naming `lib/site-packages` | its SHA-256, pinned in the script; the release's `SHA256SUMS`, the GitHub API digest and its GitHub build attestation (`gh attestation verify --repo astral-sh/python-build-standalone`) agreed on 2026-11-20 |
| `bin/dirctl` | AGNTCY Directory v1.9.1 release asset | its SHA-256: the GitHub API digest, equal to the subject of the release's SLSA provenance (`dirctl-v1.9.1.intoto.jsonl`; that provenance's signature not verified); dirctl publishes no checksum file |
| `bin/slimctl` | slimctl 3.4.6 gnu tarball | its SHA-256: the GitHub API digest, for a tarball whose sigstore bundle was verified by identity (agntcy/slim's release-rust workflow) in the spike of 2026-11-19 |
| `lib/site-packages/slim_bindings` | slim-bindings 3.3.9 manylinux wheel | PyPI's SHA-256, then `pip --require-hashes --no-index` |

Every download goes through the collection's download helper (`dcf_curl`, ADR-0034). `MANIFEST.json` records
the bundle's version, architecture, source commit, and each piece's version, URL and SHA-256. The same inputs give
the same bytes on one build host (sorted names, owner 0, times clamped to the source commit, `gzip -n`).

**Where this Feature takes it from**, the first that applies:

1. `bundle/facilitator-<v>-linux-<arch>.tar.gz` in the Feature's folder, staged by `task bundle:stage` for the
   Feature tests (git-ignored);
2. `FACILITATOR_ASSETS=<folder>` holding that file, for offline builds;
3. the release `facilitator-bundle-v<bundleVersion>` of this repository, **when `digests.txt` pins the asset**:
   downloaded and checked against the pin;
4. otherwise the bundle is **built here from the Feature's own source** by `bundle-build.sh` (a byte-identical
   copy of the script, `task bundle:check`), each upstream piece checked against the script's pins. This is how
   0.3.0 installs until the first `release-bundle` run is pinned.

A local file (1, 2) is checked against the pin when there is one, and refused when it differs; without a pin it is
checked against the `SHA256SUMS` beside it and the install says it is unpinned. The bundle is never cached in the
state volume: the Feature installs while the image is built, when no volume is mounted, so the cache is Docker's
layer cache of the Feature's step (and `FACILITATOR_ASSETS` for offline builds).

**Verify a bundle by hand:**

```sh
v=0.3.0; tag=facilitator-bundle-v$v
gh release download $tag --repo nabil-becker/devcontainer-features --pattern 'SHA256SUMS' --pattern "facilitator-$v-linux-amd64.tar.gz"
sha256sum -c --ignore-missing SHA256SUMS                       # the file against the release's sums
grep "facilitator-$v-linux-amd64.tar.gz" src/facilitator/digests.txt   # the same digest as the Feature's pin
gh attestation verify facilitator-$v-linux-amd64.tar.gz --repo nabil-becker/devcontainer-features   # built by release-bundle
tar -xzOf facilitator-$v-linux-amd64.tar.gz facilitator/MANIFEST.json   # what is inside, and each piece's SHA-256
```

**The release sequence** (ruling AC; the Operator starts each workflow, an agent never does):

1. A pull request changes the application or the bundle script and bumps the application version; it merges.
2. The Operator runs **`release-bundle`** (Actions, on `main`): amd64 on `ubuntu-latest`, arm64 on
   `ubuntu-24.04-arm`, each built natively and smoke-tested, then one release `facilitator-bundle-v<v>` with both
   tarballs, one `SHA256SUMS` and a build attestation per tarball.
3. A pull request pins it: `task bundle:pin -- <v>` checks each asset against `SHA256SUMS`, GitHub's digest and its
   attestation, and appends the lines to `digests.txt`; the Feature's version and CHANGELOG move with it.
4. The Operator merges it and runs the Feature **release**.
5. The Operator runs **`release-node-image`**: the released assets, refused unless they match `digests.txt` on
   `main`, become `ghcr.io/nabil-becker/facilitator-node:<v>` (amd64 and arm64) with an attestation.

## The node image (a hub)

A node with no developer, for an intranet hub, built from the same bundle
([`bundles/facilitator/Dockerfile`](../../bundles/facilitator/Dockerfile)): `debian:trixie-slim` by digest, plus
`ca-certificates`, `openssh-client` and `tini`; the bundle verified against its `SHA256SUMS` in a build stage and
copied to `/opt/facilitator`; user `facilitator` (uid 10001), no login shell; state in the volume
`/var/lib/devcontainer-features/facilitator` (the Feature's path, NFR-1); `/etc/facilitator/facilitator.yml` and
`participants.yml` mounted read-only when wanted; `ENTRYPOINT tini -- facilitator node run`;
`HEALTHCHECK facilitator infra status`; nothing exposed. `facilitator node run` starts the ssh-agent, the Directory
and SLIM, stays in the foreground, stops all three on a signal and exits non-zero when one dies, so the
container's restart policy supervises it. In 0.3.0 it runs **role standalone**: every port on loopback inside the
container; the hub's networking and trust come with slice N3.

The sample [`bundles/facilitator/compose.yml`](../../bundles/facilitator/compose.yml) runs the hub beside an
OpenBao 2.7.2 (by digest) on an internal network that publishes nothing (ruling AI). OpenBao starts sealed:
initialise it once and unseal it by hand after every start (ruling AB), from your own terminal:

```sh
docker compose -f bundles/facilitator/compose.yml up -d
docker compose -f bundles/facilitator/compose.yml exec openbao bao operator init     # once; keep the shares
docker compose -f bundles/facilitator/compose.yml exec openbao bao operator unseal   # after every start
docker compose -f bundles/facilitator/compose.yml exec hub facilitator check
```

Locally: `task bundle:build`, `task bundle:image` (tags `facilitator-node:<v>-local`), `task test:facilitator-image`.
Why not AGNTCY's own images or Helm charts (NFR-9): they run one daemon each, with no supervisor for the three
processes a node needs and no bundle shared with this Feature (not checked against their latest releases).

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
  humans: [you]                    # the people; each attaches their own session over MCP (default [you])
  fallback: domain-expert-one      # gets a group message addressed to no one (default: everyone)
```

## Verify

```sh
facilitator version          # facilitator 0.3.0 (backend agntcy; mode node; ...), bundle 0.3.0 linux-amd64, dirctl 1.9.1, slimctl 3.4.6
facilitator infra status     # agent, dir and slim healthy, every port on 127.0.0.1
facilitator check            # one line per part; exit 0 when ready
```

The jester scenario (the participants are started by you or your harness; you talk from Claude Code):

```sh
facilitator register --all                       # keys and tokens (yours too), OASF records in the Directory
facilitator snippet domain-expert-one            # how to attach its Claude Code (prints commands, runs none)
FACILITATOR_TOKEN="$(cat $FACILITATOR_HOME/tokens/jester)" \
  facilitator model --as jester --endpoint http://localhost:11434/v1 --model llama3.2 --definition personas/jester.md &
facilitator snippet you                          # your own session: the entry, the environment, the hook
FACILITATOR_HANDLE=you FACILITATOR_TOKEN="$(cat $FACILITATOR_HOME/tokens/you)" claude
#   > ask @jester to tell @domain-expert-one a joke      (say)
#   > any mail?                                          (mail)
facilitator verify --conv <id>                   # every message back to your signed one
```

### Talking to the agents from Claude Code (in place of `facilitator chat`)

`facilitator chat` and `facilitator send` are gone in 0.2.0 (the Operator's ruling of 2026-11-20: "remove
the chat, essentially making it just accessible through the MCP"). What you did in the chat, you now ask
your own Claude Code session to do; it calls the facilitator's tools for you.

1. Once: `facilitator register you` (or `register --all`; a person needs a token since 0.2.0), then
   `facilitator snippet you`, and run the `claude mcp add --scope user facilitator -- facilitator mcp` it
   prints (the same entry every agent uses; it names no handle).
2. Start Claude Code with your handle and token in its environment:
   `FACILITATOR_HANDLE=you FACILITATOR_TOKEN="$(cat $FACILITATOR_HOME/tokens/you)" claude`. Tokens are made
   again at each container start: start the session after the container, never put the token in the entry.
3. Optional: paste the `UserPromptSubmit` hook that `snippet` prints into `~/.claude/settings.json` (or
   `.claude/settings.local.json`). At each prompt it shows "Facilitator: N new messages in c-..." or
   nothing; it never fails a turn (`... 2>/dev/null || true`, a 10 s timeout, a cached answer when nothing
   changed). The Feature never writes Claude's settings (NFR-13).
4. Talk: "ask @jester for a joke" (`say`, a new conversation); "tell @jester and @domain-expert-one ..."
   (a group); "say in c-1a2b3c4d: ..." (`say` with `conversation`); "any mail?" (`mail`); "show me
   c-1a2b3c4d" (`transcript`); "who is there?" (`who`); "continue c-1a2b3c4d" when it paused (`continue`).

| `chat` did | Now |
| --- | --- |
| `@jester ...` with no conversation | `say {text: "@jester ..."}` (or `conversation: "new"`, `to`) |
| a line in the current conversation | `say {text, conversation: <id>}` |
| `/new group a b`, `/new direct a` | `say {text, to: [a, b]}` / `say {text, to: [a]}` |
| the transcript followed live | `mail` (unread, never waits) and `transcript {conversation, limit?}`; the turn hook says when there is mail |
| `/continue` | `continue {conversation}` |
| `/who`, `/convs` | `who` (handles and your conversations) |
| `facilitator send` in a script | none: a script attaches over MCP with a person's handle, or is an agent |

Copilot CLI: the same entry (`copilot mcp add facilitator -- facilitator mcp`) and environment. Copilot
has no hook that can show a line at each turn, so ask it "any mail?"; in a shell,
`facilitator mail --as you --notice` prints the same line.

### What changes for a person (option A)

Until 0.1.0 every message of yours began a new chain at hop 0, so a loop through your session (your
assistant answering an agent, the agent answering back) never hit the hop limit. From 0.2.0 a message of
yours in a conversation answers its last message and counts one hop more, like any other; it is held
like any other when the conversation is paused or past the hop limit. Only `continue` (your session's
tool; an agent is refused it) lets the conversation run another `hopLimit` (and resets the budget); its
last held message, often yours, is then delivered. With the default limit of 6, you get three exchanges
with one agent before you are asked to continue. A message in a new conversation (`say` with no
conversation, or `"new"`) still begins a new chain at hop 0. The message budget (40) and the rate (10 a
minute, which a person's messages are not counted against) are unchanged.

## Options

| Option | Default | What, and when to change it |
| --- | --- | --- |
| `installTaskfile` | `true` | The Taskfile, as every Feature. |
| `backend` | `agntcy` | What carries the directory and delivery. `lean` (packet-relay) is refused in this version: "not yet: slice 5". `FACILITATOR_BACKEND`. |
| `mode` | `node` | `node`: the whole bundle; the Directory, the SLIM node and the ssh-agent run here (`autostart`). `leaf`: **the thin client only**, for a machine that runs no node: the bundle without `slimctl`, no daemon at container start, `infra up` and `node run` refused, `check` ready without them. A leaf connects to a node over the network from slice N3 (`facilitator mcp --node`); in 0.3.0 it installs and answers MCP but has no node to reach. `FACILITATOR_MODE`. |
| `bundleVersion` | `0.3.0` | The node bundle (the release `facilitator-bundle-v<version>`), checked against `digests.txt`; `latest` means the bundle this Feature version was made with. With no pin, the bundle is built from the Feature's own source (above). |
| `dirVersion` | empty | **Deprecated in 0.3.0** (above): `1.9.1` or `latest` accepted with a notice, anything else refused. |
| `slimVersion` | empty | **Deprecated in 0.3.0** (above): `3.4.6` or `latest` accepted with a notice, anything else refused. |
| `hopLimit` | `6` | Hops since the message that began the chain (a person's later messages count too) before the conversation pauses. `FACILITATOR_HOP_LIMIT`. |
| `messageBudget` | `40` | Messages between two `continue`; past it participants' messages are kept and held. `FACILITATOR_MESSAGE_BUDGET`. |
| `rateLimit` | `10` | Messages a participant may write in a minute; one more is refused, not written. `FACILITATOR_RATE_LIMIT`. |
| `receiveWaitSeconds` | `300` | How long `receive` blocks without `wait_seconds` (a 300 s call held in the T1 run). `FACILITATOR_RECEIVE_WAIT_SECONDS`. |
| `staleSeconds` | `900` | Without a `receive` for this long a participant counts as not attached. `FACILITATOR_STALE_SECONDS`. |
| `facilitatorBudget` | `20` | Model calls per conversation for the AI facilitator; read and shown, unused before slice 6. `FACILITATOR_BUDGET`. |
| `identity` | `false` | AGNTCY Identity (needs Docker); `true` is refused: "not yet: slice 7". |
| `autostart` | `true` | `postStartCommand` runs `facilitator infra up`, never fatally; nothing in mode `leaf`. Turn off to start it by hand. `FACILITATOR_AUTOSTART`. |
| `dirOnlineCheck` | `false` | Check each pushed record against the online OASF schema server; off, the Directory checks nothing (`policy.operations: []`, ruling F). |

**Settings are plain variables too** (NFR-6), resolved: the command line, the repository's `.env`,
`.devcontainer/.env`, the environment, then the options as installed. Besides those above:
`FACILITATOR_HOME`, `PARTICIPANTS_FILE` (alias `AGENTS_FILE`), `FACILITATOR_FILE`, `FACILITATOR_HANDLE` and
`FACILITATOR_TOKEN` (who `facilitator mcp` attaches as, set per CLI by its harness or by the person), the ports
(`FACILITATOR_DIR_PORT` 8888, `FACILITATOR_DIR_OCI_PORT` 5555, `FACILITATOR_DIR_P2P_PORT` 8999,
`FACILITATOR_DIR_GATEWAY_PORT` 8889, `FACILITATOR_SLIM_PORT` 46357), `FACILITATOR_KEYS` (`auto` | `openbao` |
`file`), `FACILITATOR_DIRCTL` and `FACILITATOR_SLIMCTL` (other binaries), and, for tests only,
`FACILITATOR_TRANSPORT=poll` (no SLIM: the record is read every half second; `check` says so).

## State

`FACILITATOR_HOME` (`/var/lib/devcontainer-features/facilitator`, the named volume
`facilitator-state-${devcontainerId}`, made the remote user's by `facilitator-setup` through `dcf-persist`):
`conversations/<id>/` (one register-engine store per conversation), `roster.json`, `anchors` (the
facilitator's own key, the anchor of every conversation's roster), `keys/` (public keys; private ones only
in the fallback), `tokens/`, `attach/` (when each participant last called `receive`), `mail/` (what each
person's `mail` handed over, and the turn hook's cached line), `dir/` (the
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
(`facilitator-start`), valid only in this container, for each participant and, since 0.2.0, each person.
The participant's harness (or the person) puts it in the CLI's environment as `FACILITATOR_TOKEN`, with
`FACILITATOR_HANDLE`; the MCP server it starts inherits both and is refused without a matching token.
Whether a caller is a person or an agent comes from the roster (`register` takes it from
`facilitator.yml`'s `humans`), never from the caller. The
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
| `facilitator:status` | `facilitator status` | Who is attached; each conversation's messages, hops, budget, pause. Read only. |
| `facilitator:mail` | `facilitator mail [--as <h>] [--limit n] [--json] [--notice\|--hook]` | A person's unread messages, read only (the MCP `mail` marks them read). `--notice`: one line or nothing; `--hook`: the same as Claude Code hook JSON. Both always exit 0. |
| `facilitator:transcript` | `facilitator transcript --conv <id> [--limit n] [--json]` | Messages, routes, task states, notices. Read only. |
| `facilitator:verify` | `facilitator verify --conv <id> [--message <id>] [--format json]` | Exit 0 a good chain, 1 a break, 2 bad usage. |
| `facilitator:snippet` | `facilitator snippet <handle>` | The one shared `claude mcp add` command (or MCP entry), the `FACILITATOR_HANDLE` and `FACILITATOR_TOKEN` lines, the persona sentence; for a person, the turn hook and the Copilot note. |
| (a harness, or the person's CLI, runs it) | `facilitator mcp [--as <handle>]` | The MCP server a CLI starts; the handle from `FACILITATOR_HANDLE` when `--as` is absent (exit 2, naming both, when neither is set). |
| (a harness runs it) | `facilitator model --as <h> --endpoint <url> --model <m> --definition <file>` | The local-model wrapper. |
| (`postStartCommand`) | `facilitator-start` | Tokens made again; `infra up` when `autostart`; nothing in mode `leaf`. |
| (the node image's entrypoint; no task) | `facilitator node run` | The node in the foreground: setup, then the ssh-agent, the Directory and SLIM; a signal stops all three (exit 0), one dying stops the rest (exit 1). In a devcontainer use `infra up` instead. Refused in mode `leaf`. |

Removed in 0.2.0: `chat`, `send` and `continue` (a person's `continue` is the MCP tool, so no process
without the person's token can continue a conversation).

### The MCP tools (the attachment contract)

The tools listed follow the handle's kind in the roster; a tool of the other kind is refused.

An agent's:

| Tool | Arguments | Returns |
| --- | --- | --- |
| `receive` | `wait_seconds?` (0 to 3600) | `MESSAGE in conversation ...` with `structuredContent.message` {conversation, message_id, from, text, members, hops, parts}; or `nothing yet`. Several replies to one question waiting at once come as one turn (the collector, plain joining). |
| `reply` | `text`, `to?` | Answers what `receive` handed over (`reply_to`, hops + 1); no mention: back to the asker. Completes the delivery's A2A task. |
| `say` | `text`, `conversation?` (an id or `new`), `to?` | A turn in another conversation; needs a message received first (every chain begins with a human). |
| `who` | none | The handles, attached or not, and your conversations. |

A person's (none of them waits):

| Tool | Arguments | Returns |
| --- | --- | --- |
| `say` | `text`, `conversation?` (an id, or `new`), `to?` | No conversation, or `new`: one is made with the handles named (`@mention` or `to`; direct for one, a group for more) and your message is the chain's root, hop 0. A conversation of yours: your message answers its last message, one hop more (option A). Says where it went, or why it is held. |
| `mail` | `limit?` (1 to 200, default 20) | The unread messages of every conversation you are in, by conversation (the one with the oldest unread first), each in its order, with `from`, `hops`, whether it was addressed to you and whether it was held; then marked read. `more` counts what stays unread; paused conversations are named. `no new messages` when there are none. |
| `transcript` | `conversation`, `limit?` (1 to 500, default 50) | A conversation you are in: its last `limit` messages with their routes and notices, and how many earlier ones are not shown. |
| `continue` | `conversation` | A paused conversation runs another hop limit (and its budget is reset); its last held message is delivered. The only thing that resets the hops. |
| `who` | none | As an agent's. |

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
| `continue` | `thread, upto` | a human member (through the `continue` tool) |

Lineage: `reply_to` (what it answers), `refs` (what it derives from, the root always last), `root` (the
human message the chain began with; a person's message in a new conversation is its own root at hops 0,
and one in an existing conversation answers its last message, hops one more), `hops`, and the A2A task of
each delivery in its route.

## Pairs with

- **openbao**: keeps the keys and SLIM's secrets; without it, the 0.1.0 fallback files.
- **claude-code**: a Claude Code participant, or your own session; `facilitator snippet <handle>` prints
  the shared `claude mcp add` and, for a person, the turn hook. The claude-code Feature's `attach` option (a
  later step) will run that through the CLI's own command.
- **copilot**: a GitHub Copilot CLI participant, or your own session; its `attach: facilitator` registers the
  same shared entry through `copilot mcp add`, with the handle and token from the environment (no token in
  the entry), and its `agent-adapter-copilot run-once` is the pump's route.
- **register-engine**: optional; with it, `register-engine verify <store> --register <id> --type conversation`
  reads a conversation too. This Feature carries its own copy of the engine and of sign-packet's library.
- **go-task**: the Taskfile. Needs OpenSSH, installed with apt when missing; no system Python (the bundle has its own).

## Limits

- One container: participants, the Directory and SLIM are on loopback; across containers is slice N3. A leaf
  (`mode: leaf`) installs but has no node to reach before then; the node image runs role standalone.
- The arm64 bundle is built (a cross build) and checked here, but runs only on the arm64 runner of
  `release-bundle`; nothing on arm64 runs in CI's Feature tests.
- `agntcy` only; `lean` (packet-relay) is slice 5, and there is **no silent fallback**: when the
  Directory or SLIM cannot start, `check` says why.
- No model in the facilitator (slice 6): a group message addressed to no one goes to the `fallback`
  participant or to every member, bounded by the limits. `facilitatorBudget` is unused.
- The pump attachment and the vendor Features' `attach` option are not in this version.
- A slow participant holds its chain; no reply timeout before a person's `continue`.
- A person's session is not woken by a message: it sees mail when it calls `mail` (Claude Code's turn
  hook says so at the next prompt). Copilot CLI has no such hook.
- With option A a person gets `hopLimit / 2` exchanges with one agent before a `continue`; a new
  conversation begins a new chain.
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
   the two environment lines, give it the persona sentence: it calls `receive`.
3. A local model: `facilitator model --as jester --endpoint <url> --model <name> --definition <file>`.
4. Your own Claude Code (`facilitator snippet you`, the hook added): "ask @jester to tell @domain-expert-one
   a joke"; at the next prompt the hook line; "any mail?" shows four messages; then `facilitator verify --conv <id>`.
5. A hop limit: two agents told to answer each other; the conversation pauses at `hopLimit`; "continue <id>".

## Why it exists

No published Dev Container Feature connects agents of different vendors in a devcontainer. AGNTCY
publishes the Directory and SLIM but no conversation store, limits or signed record; MCP gateways connect
one client to many servers, not agents to each other. This Feature runs AGNTCY's components as
infrastructure and adds what they leave out.

## Version and upgrade

Pinned, in the bundle: CPython 3.13.18, dirctl 1.9.1, slimctl 3.4.6, slim-bindings 3.3.9 (node and bindings move
together). An upgrade of the Feature replaces `/opt/facilitator` whole; the volume (conversations, keys, tokens,
the Directory's data) is kept. A new AGNTCY or CPython version is a new bundle (the script's pins), released by
`release-bundle` and pinned in `digests.txt`. 0.x: the MCP tools, the packet fields and the CLI verbs may still
change before 1.0.

**From 0.2.0 to 0.3.0:** rebuild the container. The tree moves from `/usr/local/lib/facilitator` to
`/opt/facilitator` (the commands stay on `PATH`); the Feature no longer installs Python from apt; drop
`dirVersion` and `slimVersion` (deprecated). A Directory that refused to start after a container was removed
("daemon already running") now starts: its stale `daemon.pid` is removed.

**From 0.1.0 to 0.2.0:** `chat`, `send` and `continue` are removed from the command line and the Taskfile
(talk from your own Claude Code session, above); `facilitator register you` again (or `--all`) to make
your token; a `snippet` entry with `--as` keeps working, the shared entry without it is the new form; a
person's messages now count as hops.

## Inside

| Path | What |
| --- | --- |
| `facilitator/app.py` | intake, the dispatcher, a person's mail, the session (an agent's receive, reply, say, who; a person's say, mail, transcript, continue, who) |
| `facilitator/router.py`, `guard.py`, `collector.py` | the routing rules, the limits, plain joining |
| `facilitator/record.py`, `signer.py`, `verify.py` | the record over register-engine, keys and signing, `verify` |
| `facilitator/transport.py`, `directory.py`, `infra.py` | SLIM, the Directory client, the infrastructure |
| `facilitator/mcp.py`, `model.py`, `transcript.py`, `cli.py` | the MCP server, the model wrapper, the transcript, the command |
| `types.d/facilitator.py` | the `conversation` register type |
| `registerengine/`, `signpacket/` | copies of `src/register-engine` and `src/sign-packet` (`task registerengine:check`, `task signpacket:check`) |
| `bundle-build.sh` | the copy of `bundles/facilitator/install.sh` (`task bundle:check`) |
| `digests.txt` | the SHA-256 of each released bundle asset, one line each (`task bundle:pin`) |

Tests: `test/facilitator/unit/` (`task test:facilitator-unit`, part of `task lint`; `test_feature.py` builds a
skeleton bundle and installs it), `test/facilitator/node_image.sh` (`task test:facilitator-image`) and
`test/facilitator/integration/jester_flow.py` (`task test:facilitator-integration`; the `jester_flow` scenario).
