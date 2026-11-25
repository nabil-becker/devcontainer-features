# Data inventory and models

Part one says what data exists, where, and how sensitive it is. Part two draws the shape of the
main records. First version, written 2026-11-19; Mermaid and text here are the reviewed source.

Node ids are ontology ids (`docs/model/ontology.toml`); `external-` marks what is outside the
model. The term model itself is in [`docs/model/`](../model/README.md): this page does not repeat it.
Paths and ids only, never content. `%USERPROFILE%` and `%LOCALAPPDATA%` are placeholders.

## Part one: the inventory

### The four tiers

```mermaid
flowchart TB
  storage-tier["Storage tier (ADR 0045, amended by ADR 0049)"]
  external-t1["Tier 1 git: the reviewed record"]
  external-t2["Tier 2 the shared folder: /mnt/cloud-folder"]
  external-t3["Tier 3 the personal folder: never mounted unless asked"]
  external-t4["Tier 4 the working set: Feature volumes, rebuildable only"]
  custody["Custody: outside every tier"]
  storage-tier -->|contains| external-t1
  storage-tier -->|contains| external-t2
  storage-tier -->|contains| external-t3
  storage-tier -->|contains| external-t4
  storage-tier -.->|not placed in| custody
```

The rule: **if losing a machine would lose something, it is in the wrong tier.** Exceptions are
named in the rows ("bounded loss", "to verify").

### How to read the columns

| Column | Values |
|---|---|
| tier | 1 git, 2 the shared folder, 3 the personal folder, 4 the working set, custody, none |
| sensitivity | public (anyone may read), internal (the Operator's organisation), secret (a credential or key), personal (about a person). My classification from the source's wording; the sources do not carry this column, so each is "to verify" with the Operator. |
| survives rebuild | a container rebuild; for a volume, yes. A machine loss follows the tier. |

### The data

| What | Path or volume | Owner | Tier | Sensitivity | Survives rebuild | Source |
|---|---|---|---|---|---|---|
| Code, Features, docs, ADRs, lexicon, ontology | the repository (`src/`, `docs/`, `LEXICON.md`) | git (the Operator reviews) | 1 | public | yes | `CLAUDE.md`, `README.md` |
| The checkout's git dir | `%USERPROFILE%/.git-dirs/<repo>`, mounted whole at `/git-dirs` | git Feature | 1 | internal | yes | `src/git/NOTES.md`, `docs/adr/0020-*.md` |
| Global git config (identity, credential helper) | volume `git-config-${devcontainerId}` at `/var/lib/devcontainer-features/git` | git Feature | 4 | personal | yes | `src/git/NOTES.md`, `src/git/devcontainer-feature.json` |
| Claude Code login, settings, session history, adapter's session list | volume at `CLAUDE_CONFIG_DIR` (`/var/lib/devcontainer-features/claude-code`) | claude-code Feature | 4 | secret (login), personal (sessions) | yes | `src/claude-code/NOTES.md` |
| Claude Code memory | `.../claude-code/projects/*/memory/` in the same volume | the Operator, claude-code Feature | 4, belongs in 3 | personal | yes | `docs/adr/0049-*.md` (mirror to tier 3 is a backlog item; whether done: to verify) |
| `gh` login (token, settings) | volume at `GH_CONFIG_DIR` (`/var/lib/devcontainer-features/gh`) | gh Feature | 4 | secret | yes | `src/gh/NOTES.md` |
| Azure CLI login state | volume at `AZURE_CONFIG_DIR` (`/var/lib/devcontainer-features/az`) | az Feature | 4 | secret | yes | `src/az/NOTES.md` |
| Argo CD login session | volume at `ARGOCD_CONFIG_DIR` | argocd Feature | 4 | secret | yes | `src/argocd/NOTES.md` |
| Coder login (`session`, `url`) | volume at `CODER_CONFIG_DIR` | coder-cli Feature | 4 | secret | yes | `src/coder-cli/NOTES.md` |
| Kubeconfig (cluster credentials) | volume `/var/lib/devcontainer-features/kube-state` (`KUBECONFIG`) | kube-state Feature | 4 | secret | yes | `src/kube-state/NOTES.md` |
| OpenBao login token | `token` in volume `openbao-config-${devcontainerId}` (`BAO_CONFIG_PATH`) | openbao Feature | 4 | secret | yes | `src/openbao/NOTES.md` |
| OpenBao server storage (server mode): every secret, policy, role | `raft/` in the same volume | openbao Feature | 4, bounded-loss exception | secret | yes | `src/openbao/NOTES.md`, `docs/adr/0048-*.md` |
| OpenBao audit log (server mode) | `audit.log` in the same volume | openbao Feature | 4 | internal (content: to verify) | yes | `src/openbao/NOTES.md` |
| OpenBao AppRole secret ids (server mode) | `approle/<role>/`, mode 600, same volume | openbao Feature | 4 | secret | yes | `src/openbao/NOTES.md` |
| OpenBao snapshots | `DEST`: the personal folder (ruled 2026-11-10; the shared folder is ruled out) | openbao Feature, the Operator | 3 | secret (the whole store) | yes | the backlog item `openbao-backup-destination`, done 2026-11-10; `docs/reference-architectures/secrets-with-openbao.md`. Finding: `openbao-*.snap` files were seen in the shared folder, and the older open item `amend-openbao-local-storage` (2026-11-06) still says the shared folder |
| Unseal shares 1 to 3 and the recovery key | held by people; printed once by `task openbao:init` | the Operator | custody | secret | not applicable | `src/openbao/NOTES.md`, `docs/adr/0049-*.md` |
| OpenBao key file: unseal shares 4, 5 and the Operator's AppRole login | `%LOCALAPPDATA%\devcontainer-features-keys\openbao\<repo>-<cluster id>.keyfile`, DPAPI-protected | devcontainer-cli launcher | 3-like (workstation local; not roamed, not in the shared folder); tier name: to verify | secret | yes (not in the container) | `src/devcontainer-cli/NOTES.md` |
| ssh-agent private keys (opt-in key mode only) | volume `ssh-agent-key-${devcontainerId}` at `/var/lib/devcontainer-features/ssh-agent-key` | ssh-agent Feature | 4 | secret | yes | `src/ssh-agent/NOTES.md`, `src/ssh-agent/devcontainer-feature.json` |
| ssh-agent socket | `/var/lib/devcontainer-features/ssh-agent/agent.sock`, a mount of the host agent | launcher | none (a pipe to the host) | secret in use, nothing stored | no (re-mounted at start) | `src/ssh-agent/NOTES.md` |
| The shared documents, the register mirror, reviews, cost reports | `/mnt/cloud-folder` (host mount `/mnt/cloud-folder-host`) | cloud-folder Feature; the Operator | 2 | internal | yes | `src/cloud-folder/NOTES.md`, `docs/ledger/README.md` |
| The backlog | `/mnt/cloud-folder/TODO.md` (`DEVHOST_RECORDS_DIR`); `TODO.md` at the root when unset | secretary back, host | 2 (1 when unset) | internal | yes | `local-features/devhost/NOTES.md`, `docs/ledger/README.md` |
| The ledger, live store | volume agentic-register, `/var/lib/devcontainer-features/agentic-register/registers/ledger` | scribe back (signs) | 4, mirrored to 2 | internal | yes | `docs/ledger/README.md`, `local-features/devhost/NOTES.md` |
| The ledger mirror | `/mnt/cloud-folder/ledger` | agentic-register Feature | 2 | internal | yes | `docs/ledger/README.md` |
| Ledger reviews | `/mnt/cloud-folder/reviews/YYYY-MM-DD.md` | host (`/ledger-review`) | 2 | internal | yes | `docs/ledger/README.md` |
| Cost reports and cost store | `/mnt/cloud-folder/costs/costs-YYYY-MM-<engineer>.md` and `.jsonl` | `devhost-report` | 2 | internal (ids and numbers only) | yes | `docs/ledger/README.md`, `local-features/devhost/NOTES.md` |
| Cost history to the cut-over (cold storage) | `/mnt/cloud-folder/costs/archive/` | host, once | 2 | internal | yes | `docs/ledger/README.md` |
| Backs' state: offsets, locks, job logs, pending notes, `runs.jsonl` | volume `devhost-state-${devcontainerId}` at `DEVHOST_STATE` | devhost Feature | 4 | internal (job.log content: to verify) | yes | `local-features/devhost/NOTES.md` ("State") |
| rclone token and config, sync state, logs, VFS cache | volume at `/var/lib/devcontainer-features/cloud-folder` | cloud-folder Feature | 4 | secret (token) | yes | `src/cloud-folder/NOTES.md` |
| Agent list | `.devcontainer/agents.yml` | participant component (claude-code `participants: true`, or the deprecated agents Feature), the repo | 1 | public | yes | `src/agents/NOTES.md`, `src/claude-code/NOTES.md`, `.devcontainer/agents.yml` |
| Agent leases and start markers | `/var/lib/devcontainer-features/agents`, not a volume | participant component | 4 | internal | no, by design | `src/agents/NOTES.md` |
| The participant component itself | `/usr/local/lib/dcf-participant` (`COMPONENT_VERSION`, `installed-by`), `/usr/local/bin/agents` a symlink into it | the first Feature that installs it (newer copy wins) | 4 (image) | public | no (rebuilt) | `components/participant/install-participant.sh` |
| Launcher settings per machine | `.devcontainer/.env` on the workstation (git-ignored, `.gitignore`) | the Operator | 3-like (a workstation file) | internal | not applicable | `.devcontainer/devcontainer.json`, `src/devcontainer-cli/NOTES.md` |
| Audio relay folder (microphone socket, only while the gate is on) | `/mnt/wsl/devhost-audio` | launcher, audio gate | none | personal (live audio, stored nowhere) | no | `src/audio/NOTES.md`, `docs/adr/0058-*.md` |
| Audio ALSA default | `/etc/asound.conf` in the image | audio Feature | 4 (image) | public | no (rebuilt) | `src/audio/NOTES.md` |
| PHI-check exceptions (synthetic fixtures only) | a file named by the `exceptions` option | phi-check Feature, the repo | 1 | internal | yes | `src/phi-check/NOTES.md` |
| Registry layer list | `.devcontainer/registry.yml` (option `registryFile`, `COMPONENT_REGISTRY_FILE`) | component-registry Feature, the repo | 1 | public | yes | `src/component-registry/NOTES.md` |
| Who-you-are path (`COMPONENT_REGISTRY_WHOAMI`) | `.env` (git-ignored) or the launcher (later), per person | the person | none (a setting) | internal | not applicable (set again) | `src/component-registry/NOTES.md`, `docs/adr/0063-*.md` |
| A registry layer's `.layer` files and skill files | its source: a git repository, a folder or file share, one `.layer` file or an archive over http(s) (a folder of it, sha256-pinned if asked), a folder of a git repository, a folder in the cloud folder | the layer's owner | the owner's choice | internal; a person's own layer is personal | follows its source | `docs/proposals/component-registry.md` |
| Registry layer copies, the resolved view, `resolve.lock` | volume `component-registry-state-${devcontainerId}` at `/var/lib/devcontainer-features/component-registry`, owner-only | component-registry Feature | 4 | as its most sensitive layer (may be personal) | yes (refetched, rebuilt) | `src/component-registry/NOTES.md` |
| Namespaced components (1.7.0) | the resolved view's `skills/<ns>--<name>/`, `agents/<ns>:<name>/`, `meta/<kind>/<ns>:<name>/` and `meta/namespaced.tsv` in the component-registry volume, owner-only; the skills copied to the CLI's skills folder like any resolved skill | component-registry Feature | 4 | as the resolved view; from a source the Operator does not control, so instructions of lower trust, kept to their namespace | yes (rebuilt) | `src/component-registry/NOTES.md` "Layer namespaces", ADR-0073 |
| Resolved agent definitions (release 2) | the resolved view's `agents/<name>/` (`model`, `skills`, `from.tsv`) in the component-registry volume, owner-only; the model is handed to the CLI adapter as `AGENT_MODEL` for one call, never stored by the participant | component-registry Feature, read by the participant component | 4 | as the resolved view (may be personal) | yes (rebuilt) | `src/component-registry/NOTES.md`, `docs/proposals/component-registry.md` section 6.1 |
| Vendor templates (1.11.0, ADR-0077) | a layer's `templates/<vendor>/<file>.j2` at its source; the built-in base layer's in the image; the candidates that apply copied into the resolved view's `templates/` with `meta/templates.tsv`, owner-only | the layer's owner; component-registry Feature | the owner's choice; 4 in the view | as its layer (text, may be personal) | follows its source; the view is rebuilt | `src/component-registry/NOTES.md` "Vendor templates", ADR-0077 |
| Rendered files of one hand-over (1.11.0) | `renders/<cli>.<agent>.<pid>/` in the component-registry volume, owner-only, removed when the hand-over ends | component-registry Feature (`dcf-registry handover`, `render` writes where the person says) | 4 | as the resolved view (may be personal) | not kept | `src/component-registry/NOTES.md`, ADR-0077 |
| `explain` output | the terminal only | component-registry Feature | none | as the resolved view | not kept | `src/component-registry/NOTES.md` |
| Registry source secrets | OpenBao, read with `dcf-secret` | the layer's owner or the person | OpenBao's | secret | yes | `src/component-registry/NOTES.md` |
| Resolved skills in the CLI | the CLI's skills folders (Claude Code: `$CLAUDE_CONFIG_DIR/skills` for what every agent's view shares, `$CLAUDE_CONFIG_DIR/registry-agents/<agent>.<sum>/` per agent, its full view and its own skills, in the claude-code volume; Copilot CLI from copilot 0.3.0: `$COPILOT_HOME/skills` and `$COPILOT_HOME/registry-agents/<agent>.<sum>/`, in the copilot volume), owner-only, each copy marked `.component-registry` | the CLI adapter's `skills` verb (`dcf-registry handover`) | 4 | as the resolved view (may be personal) | yes (rebuilt by the next resolve) | `src/claude-code/NOTES.md`, `src/copilot/NOTES.md`, `docs/adr/0064-*.md`, `docs/adr/0074-*.md`, `docs/adr/0077-*.md` |
| Registry views per path and hand-over records (`paths/`, `handovers.tsv`: CLI, agent, folder, path) | the component-registry state volume, owner-only | component-registry Feature (1.8.0) | 4 | views as the resolved view; records internal | yes (rebuilt by the next start or refresh) | `src/component-registry/NOTES.md`, `docs/adr/0074-*.md` |
| The utility skills (built-in base layer) | `/usr/local/share/component-registry-feature/base` in the image | component-registry Feature | 4 (image) | public | no (rebuilt) | `src/component-registry/NOTES.md` |
| The devhost registry layer (the generic `architecture-review`) | `/usr/local/share/devhost/registry` in the image, from `local-features/devhost/share/registry` | devhost Feature (1.16.0) | 4 (image; its source is tier 1) | public | no (rebuilt) | `local-features/devhost/NOTES.md` |
| This repository's registry layer ("In this repository" for `architecture-review`) | `.devcontainer/registry/repo` | the repo | 1 | public | no | `src/component-registry/NOTES.md` (first real use) |
| This repository's who-you-are default | `containerEnv` `COMPONENT_REGISTRY_WHOAMI` = `${localEnv:COMPONENT_REGISTRY_WHOAMI:/devcontainer-features/operator}` (a role, never a person; a person's value in `.devcontainer/.env`) | the repo, the person | 1 (the default), none (a person's value) | internal | not applicable | `.devcontainer/devcontainer.json` |
| An agent's who-you-are path (`registry-path`) | an entry of `.devcontainer/participants.yml` (alias `agents.yml`) | the repo | 1 | internal | yes | `src/agents/NOTES.md` |
| Facilitator conversations: one register-engine register (`conversation` type) per conversation, every message signed | volume `facilitator-state-${devcontainerId}` at `/var/lib/devcontainer-features/facilitator` (`conversations/`) | facilitator Feature | 4 (working data, D12; a tier-2 mirror is a later item) | personal (what people and models said) | yes | `src/facilitator/NOTES.md` |
| Facilitator identity keys (each participant, each human, `facilitator`) | OpenBao `facilitator/keys/<handle>`; the 0.1.0 fallback `keys/<handle>` (mode 600) in the same volume | facilitator Feature | none (OpenBao); 4 for the fallback (ADR-0048 exception) | secret | yes | `src/facilitator/NOTES.md` ("Keys") |
| Facilitator participant and person tokens (a person's since 0.2.0) | `tokens/<handle>` (mode 600) in the same volume, made again at every container start | facilitator Feature | 4 (ADR-0048 exception, ADR-0061) | secret (worthless outside the container) | yes, replaced at start | `src/facilitator/NOTES.md` |
| What each person has read (the `mail` tool's marks) and the turn hook's cached line | `mail/<handle>.json`, `mail/<handle>.notice` (mode 600) in the same volume | facilitator Feature | 4 | personal (message ids; the line names conversations) | yes | `src/facilitator/NOTES.md` |
| SLIM's basic-auth password and app secret | OpenBao `facilitator/slim`; fallback `secrets/slim.json` (mode 600) | facilitator Feature | none (OpenBao); 4 for the fallback | secret | yes | `src/facilitator/NOTES.md` |
| AGNTCY Directory data (OASF records, SQLite, OCI store, `node.key`) | `dir/` in the same volume | facilitator Feature (dirctl daemon) | 4 | internal | yes | `src/facilitator/NOTES.md` |
| The facilitator node bundle (its CPython, `dirctl`, `slimctl`, `slim-bindings`, the application, `MANIFEST.json`) and its `SHA256SUMS` | the GitHub release `facilitator-bundle-v<version>`; `/opt/facilitator` in the Feature's image layer and in the node image; the digests in `src/facilitator/digests.txt` (tier 1) | the release (CI), the facilitator Feature | none (a release asset, rebuilt from the release; never in a volume) | public | yes (image layer) | `src/facilitator/NOTES.md` ("The bundle") |
| The node image's state (the hub's conversations, keys, Directory data) | the compose volume `facilitator-state` at `/var/lib/devcontainer-features/facilitator` (the Feature's path); its OpenBao's data in the volume `openbao-data` | the node image; OpenBao | 4 (a hub's roster is backed up with its OpenBao snapshot from slice N3, ruling BH) | as the Feature's rows above | yes | `bundles/facilitator/compose.yml` |
| A node's `mesh.yml` (role, trust domains, exposure, limits) | `.devcontainer/mesh.yml` (`FACILITATOR_MESH_FILE`); the image's `/etc/facilitator/mesh.yml` (mounted read-only on a hub, in the volume on a spoke, which `node join` writes) | the repo, the engineer | 1 (a spoke in the image: 4) | internal (domains and handles, no secrets) | yes | `src/facilitator/NOTES.md` ("A hub and its spokes") |
| A node's certificate key, certificate and its domain's trust bundle | `mesh/certs/<domain>/` in the facilitator volume (the key mode 600: SLIM reads it from a file) | facilitator Feature | 4 (the key: ADR-0069 decision 4's exception) | secret (key), public (certificates) | yes | `src/facilitator/NOTES.md` |
| A home domain's own CA key | `mesh/ca/` in the same volume (mode 600) | facilitator Feature | 4 (ADR-0069 decision 4) | secret | yes | ADR-0069 |
| A hub's intermediate CA (the issuing key of its domain) | its OpenBao's PKI mount (`pki-<domain>`) in `openbao-data` | the hub's OpenBao | 4 with the OpenBao snapshot (bounded-loss exception, ADR-0048) | secret, high value | yes | ADR-0069 |
| A domain's root CA key | offline, outside the hub and its OpenBao | the Operator | custody | secret, high value | not applicable | ADR-0069 |
| A hub's roster (joined and revoked nodes) and join tokens (hashed, 15 minutes) | `mesh/roster.json`, `mesh/invites.json` in the hub's volume; the roster also in its OpenBao KV (`secret/facilitator/mesh/roster`) | facilitator (hub) | 4, backed up with the OpenBao snapshot (ruling BH) | internal (roster); secret, hashed (tokens) | yes | `src/facilitator/NOTES.md` |
| Other nodes' admitted cards (certificate, packet keys, exposed participants) | `mesh/cards/` in the volume | facilitator Feature | 4 (refreshed from the hub's roster) | internal | yes | `src/facilitator/NOTES.md` |
| Replicas of shared conversations, their members' nodes, the outbox, lock two's refusals | `conversations/`, `mesh/convs/`, `mesh/outbox/`, `mesh/refused.log` in the volume | facilitator Feature | 4 | personal (what people and models said) | yes | `src/facilitator/NOTES.md` |
| The mesh's SLIM app secret | `mesh/secret` (mode 600) in every joined node's volume; the hub makes it, a join hands it over | facilitator Feature | 4 | secret (not rotated on a revoke) | yes | `src/facilitator/NOTES.md` |
| The HTTP clients of a node: state, the SHA-256 of each bearer token (never the token), who approved and when | `http/clients.json` in the facilitator volume (mode 600) | facilitator Feature (a person's `http token`, `approve`, `deny`, `revoke`) | 4 | secret (hashed) | yes | `src/facilitator/NOTES.md` ("MCP over HTTP for CLIs") |
| A bearer token's plain text | shown once by `facilitator http token`; then only in the client CLI's own config (`.claude.json`, `.mcp.json`, Copilot's `mcp-config.json`) | the person, the CLI | outside the Feature | secret | no | NOTES: treat the CLI's file as a secret |
| The audit log of HTTP enrolments, approvals, denials and revocations (hash-chained, not signed) | `http/audit.jsonl` in the volume (mode 600) | facilitator Feature | 4 | internal (names of clients and of the person) | yes | ruling BG's audit, built as a log (NOTES, Limits) |
| An HTTP client's signing key (the node signs for it) | as other keys: OpenBao `facilitator/keys/<client>`, or the 0.1.0 fallback file | facilitator Feature | 4 | secret | yes | ADR-0068 |
| The endpoint's TLS certificate and key | files named by `http.tls_cert` and `http.tls_key` (mode 600 for the key), or a reverse proxy's | the person who runs the node | the person's choice | secret (key) | no | NOTES |
| A hub's AppRole login for its OpenBao | a file the Operator writes (`node.issuer.approle`, e.g. in the hub's volume) | the Operator | 4 | secret | yes | `bundles/facilitator/compose.yml` |
| Participant list keys `attachment`, `description`, `skills`; facilitator settings | `.devcontainer/participants.yml` (alias `agents.yml`), `.devcontainer/facilitator.yml` | the repo | 1 | public | yes | `src/facilitator/NOTES.md` |
| Copilot login (`copilot login`), settings, sessions and the facilitator MCP entry (`mcp-config.json`, no token in it) | volume `copilot-home-${devcontainerId}` at `COPILOT_HOME` (`/var/lib/devcontainer-features/copilot`), owner-only; a repo may bind-mount a host folder | copilot Feature (the CLI writes it) | 4 | secret (the login file) | no | `src/copilot/NOTES.md` |
| A Copilot token in `COPILOT_GITHUB_TOKEN`, `GH_TOKEN` or `GITHUB_TOKEN` | the environment of the process that starts copilot; the Feature stores none (NFR-13) | the harness or the engineer | not stored | secret | not applicable | `src/copilot/NOTES.md` |
| Journal pieces, night-shift reports, iteration papers | `docs/journal/`, `docs/night-shift/`, `docs/iterations/` | host, journalist | 1 | public (name guard applies) | yes | `docs/journal/README.md`, `local-features/devhost/NOTES.md` |

### Features that hold nothing

`common`, `devcontainer-cli` (binaries only), `dsc`, `go-task`, `kubeconform`, `kustomize`,
`velero`: their NOTES say "Nothing of its own". Source: the data table in each `src/<id>/NOTES.md`.
`audio` stores no audio.

### What the inventory shows

- **Secrets sit in tier 4 volumes.** Logins for `gh`, `az`, `argocd`, `coder-cli`, `kube-state` and `cloud-folder` are rebuildable by logging in again, so tier 4 fits. They are not in OpenBao yet (planned, `docs/reference-architectures/secrets-with-openbao.md`).
- **One store is not rebuildable and is in tier 4:** OpenBao server storage (named exception, ADR 0048) and Claude Code memory (ADR 0049).
- **OpenBao snapshots belong in the personal folder (tier 3)**, by the 2026-11-10 ruling; snapshot files seen in the shared folder, and the older open item `amend-openbao-local-storage`, do not match it yet.
- **Two workstation files are in no tier of the model** (the key file and `.devcontainer/.env`). ADR 0045's tier 3 says the personal folder is "never mounted in the devhost unless asked"; whether a DPAPI key file under `%LOCALAPPDATA%` is tier 3: to verify.

## Part two: the models

The term model (what each word means, how words relate) is in
[`docs/model/ontology.toml`](../model/ontology.toml), explained in
[`docs/model/README.md`](../model/README.md). Below are the shapes of the records.

### The records and how they connect

```mermaid
erDiagram
  backlog ||--o{ backlog-item : holds
  ledger ||--o{ ledger-entry : holds
  ledger-entry }o--o| backlog-item : "item (backlog-id)"
  ledger-entry }o--o| ledger-entry : "corrects"
  adr }o--o{ adr : "supersedes"
  feature ||--o{ external-feature-option : declares
  feature ||--o{ external-mount : declares
  agent-list ||--o{ external-agent-entry : holds
  external-ontology ||--o{ external-ontology-id : defines
  external-ontology ||--o{ external-ontology-relation : defines
  external-ontology-relation }o--|| external-ontology-id : "subject, object"
```

### Ledger entry (`ledger-entry`)

One signed, canonical-JSON line of an agentic-register register. The body's `kind` is `work` (a
unit of work), `run` (a cost) or `roster` (who may write). Source: `local-features/agentic-register/SPEC.md` ("The body", "Kinds").

```mermaid
classDiagram
  class ledger_entry {
    v int = 2
    reg string
    key ssh-ed25519
    as principal
    seq int
    prev id or null
    saw ids
    at UTC time
    kind roster / work / run
    data object
  }
  class external_work_data {
    title string
    operator, session, asked string
    came_out, learned, decisions, decisions_needed, for_repository list
    friction list of tag, text
    cost cost
    corrects id
    agent principal
    item string
    pr int
    started_at, merged_at time
    conflicts, checks_red int
  }
  ledger_entry --> external_work_data : data when kind is work
```

| Field | Meaning | Source |
|---|---|---|
| `id` (derived) | SHA-256 of the body; names the entry | SPEC "The entry" |
| `as`, `key` | principal and its public key; the signature must match `key` | SPEC "The body" |
| `prev`, `seq`, `saw` | the chain of one key, and other entries seen | SPEC "The body" |
| `item` | a backlog id | SPEC, `work` fields |
| `corrects` | an entry this one replaces; never an edit | SPEC; `docs/ledger/README.md` |

The body is at most 65536 bytes; money is integer `usd_micro` (SPEC). Names and content never go in an entry (name guard).

### Backlog item (`backlog-item`)

A Markdown line in `TODO.md`. Source: the header of `/mnt/cloud-folder/TODO.md`.

```text
- [ ] **<backlog-id> <Title>** (<owner>). <What and why>. Added YYYY-MM-DD.
- [x] ... Done YYYY-MM-DD.
```

| Part | Rule |
|---|---|
| `backlog-id` | two to four kebab-case words; unique in the file; never reused or renamed |
| owner | host, the Operator, or engineers |
| section | `## Now`, `## Next`, `## Decisions for the Operator` |
| state | `[ ]` open, `[x]` done; a done item stays |

The secretary adds and ticks; it never rewords, removes or reorders. The agentic-register spec also
defines a backlog register type (`add`, `edit`, `tick`, `reopen`, `move`, `note`); whether this
repository uses it: to verify (SPEC "backlog" section; the ledger README names `TODO.md`).

### ADR (`adr`)

A Markdown file `docs/adr/NNNN-<slug>.md`. Source: `docs/adr/0000-template.md`, `docs/adr/README.md`.

| Part | Content |
|---|---|
| header table | Status (proposed, accepted, amended by, superseded), Date, Deciders |
| Context | the situation and its sources |
| Decision | in full sentences, present tense |
| Options considered | each option, with why it lost |
| Consequences | easier, harder, to do |
| Change log | one row per revision |

An ADR is rewritten or superseded only by the host; the librarian adds.

### Agents list entry (`agent-list`)

One item of `agents:` in `.devcontainer/agents.yml`. Source: `src/agents/NOTES.md`, `.devcontainer/agents.yml`.

```mermaid
classDiagram
  class agent_list {
    agents list
  }
  class external_agent_entry {
    name required
    cli required
    kind resident / on-demand, required
    folder default dot, inside the repo
    args list
    default bool
    lifecycle stateful / ephemeral
    identity default name
    lease container / none
  }
  agent_list --> external_agent_entry : holds
```

| Rule | Source |
|---|---|
| `name`, `cli`, `kind` are required; `folder` defaults to `.` | `src/agents/NOTES.md` |
| `ephemeral` with `resident` is refused | `src/agents/NOTES.md` |
| a stateful agent's lease is `container`; an ephemeral agent's is `none` | `src/agents/NOTES.md` |
| two stateful agents may not share an `identity` | `src/agents/NOTES.md` |

### Feature manifest (`feature`): `src/<id>/devcontainer-feature.json`

The fields this repository's Features use. Source: `src/git/devcontainer-feature.json`,
`src/ssh-agent/devcontainer-feature.json`, `src/claude-code/devcontainer-feature.json`.

```mermaid
classDiagram
  class feature {
    id
    version semver
    name
    description
    options map
    containerEnv map
    mounts list
    installsAfter list
    postCreateCommand
  }
  class external_feature_option {
    type boolean / string
    default
    description
  }
  class external_mount {
    source name with devcontainerId
    target path
    type volume / bind
  }
  feature --> external_feature_option : options
  feature --> external_mount : mounts
```

| Field | Example (read) | Meaning |
|---|---|---|
| `id`, `version` | `git`, bumped with each change | the unit the registry publishes |
| `options` | `installTaskfile`, `worktreeAware`, `gitCredentialHelper`, `mode`, `keyMode` | what a consumer sets |
| `containerEnv` | `GIT_CONFIG_GLOBAL`, `CLAUDE_CONFIG_DIR` | where the Feature's state is |
| `mounts` | `git-config-${devcontainerId}` to `/var/lib/devcontainer-features/git` | the named volume of its state (tier 4) |
| `installsAfter` | other Feature ids | order; only a published Feature can be named |

A Feature may not use `${localEnv}` in its own `mounts` (the CLI substitutes only `${devcontainerId}`): host paths are the repo's mounts or the launcher's (ADR 0020).

### The ontology (`ontology`): `docs/model/ontology.toml`

Source: `docs/model/ontology.toml` (header), `docs/model/README.md` (rules).

```mermaid
erDiagram
  external-ontology ||--|{ external-ontology-id : "one table per base name"
  external-ontology ||--|{ external-ontology-relation : "triples"
  external-ontology ||--|| external-types : "closed set"
  external-ontology ||--|| external-predicates : "closed set"
  external-ontology-id }o--|| external-types : "type"
  external-ontology-relation }o--|| external-predicates : "predicate"
  external-ontology-id {
    string id "kebab-case, unique"
    string type "role, record, mechanism, place, concept, product"
    string term "the bold term of LEXICON.md"
    string summary "one line"
  }
  external-ontology-relation {
    string subject "an id"
    string predicate "is-a, contains, briefs, returns, writes, keeps, checks, decides, runs, reads, uses, publishes, builds, pulls"
    string object "an id"
  }
```

Three more views are derived from it: `themes/*.toml` (labels, `id = "label"`), the C4 Markdown
files (Mermaid whose node ids are ids), and `LEXICON.md` (prose). `devhost-verify` guard `model`
keeps them in agreement.

### The component registry: layer, entry, resolved component

Source: `src/component-registry/NOTES.md` (component-registry 1.0.0), `docs/proposals/component-registry.md` sections 3.2 and 3.3.

```mermaid
classDiagram
  class Layer {
    id
    rank
    at
    sources
  }
  class Entry {
    path
    key
    type
    data
    locked
  }
  class ResolvedComponent {
    path
    values
    sourceOfEachValue
  }
  Layer "1" --> "*" Entry : holds
  Entry "*" --> "1" ResolvedComponent : merged into
```

On disk the resolved component is `skills/<name>/` (`SKILL.md` and its files) and
`meta/skills/<name>/`: `values/<key>`, `keys.tsv` (key, type, summary) and `provenance.tsv` (state,
key, type, layer, rank, version, `source:file:line`, data, why: `sourceOfEachValue`).

### Facilitator trust records (backlog `trust-docs`)

How the records of a node's trust connect: a **CA** signs a **node certificate** over the node's **key**; **trust bundles**
(CA certificates per domain) say whom a listener and a dialer trust; the node's **card** binds its packet keys to that
certificate; a **roster** (hub) or `node.peers` (peer) says which nodes may be admitted; a **join token** or an approved
**request** is how a node gets in; **HTTP clients** are the node's own callers; every act is an **audit** line and a signed
register entry.

| Record | Fields | Connects to |
| --- | --- | --- |
| Node key and certificate (`mesh/certs/<domain>/node.key`, `node.pem`) | ed25519 key (mode 600); X.509 with URI SAN `spiffe://<domain>/node/<id>`, DNS SAN = the name dialers use, serial, not before/after (24 h private, 1 h public) | signed by the domain's CA; presented on a listener or link; signs the card and every envelope |
| Trust bundle (`mesh/certs/<domain>/bundle.pem`) | the domain's CA certificates (PEM) | a listener's `client_ca` is the union of one level's bundles (lock one); lock two names the domain whose bundle a certificate chains to; `trust` maps the domain to a level |
| CA | a hub's: an OpenBao PKI (an intermediate, the root offline), or (0.7.0) an ssh-agent's key (no key file), or the built-in root and issuing CA (`mesh/ca/<domain>/root.key` until `export-root`, `ca.key`, mode 600); a peer's or a public domain's: its own CA (`mesh/ca/<domain>/ca.pem`, `ca.key` mode 600, DNS name constraints) | issues node certificates; its certificate is the bundle |
| Node card (`mesh/cards/<node>.json`) | node, domain, SPIFFE id, certificate, facilitator packet key, participants [handle, key, kind, exposure, description, skills, cid, optional opaque `badge`], `at`, signature by the certificate key | read by lock two to bind a packet key to a node and handle; restricted to the receiver's level; replaces itself when newer |
| Roster (`mesh/roster.json`, a hub's and an issuer's) | node: serial, joined, revoked, revoked_at, domain, key fingerprint, approved_by | admission of hello and renew; the source of the revoked list a hub sends; backed up to OpenBao KV |
| Join token (`mesh/invites.json`) | id, SHA-256 of the secret, made, expires (15 min), used | single use; names the CA bundle's hash; opens the join endpoint |
| Public join request (`mesh/requests.json`) | id, node, domain, CSR, key fingerprint, secret hash, status (pending, approved, denied, collected), certificate, approved_by/at | a person's `node approve`; becomes a roster entry |
| Mesh secret and rotation (`mesh/secret`, `mesh/rotation.json`) | the SLIM app secret; rotation: rid, new secret, pending nodes, deadline, state | rotated on every revoke and handed to the nodes that remain |
| HTTP client (`http/clients.json`) | name, token hash (SHA-256), status (enrolled, approved, denied, revoked), created/approved by and at, last seen | its SPIFFE id `spiffe://http.<home>/node/<id>/http/<client>`; approval lasts `approval_ttl` |
| Audit log (`http/audit.jsonl`) | at, event, client, by, hash of the previous line | replayed into the register |
| Signed audit register (`audit/audit-enrolment/`) | `enrolment` entries: event, subject, by, claimed, detail, SHA-256 of the replayed line; signed by the facilitator key | verified by `facilitator audit verify` (chain, no gap, whole log replayed) |

## Facilitator node, slice N5a additions (facilitator 0.6.0)

| Data | Where | Sensitive |
| --- | --- | --- |
| A node's own CA key (a peer's domain, a public domain) | `mesh/ca/<domain>/ca.key`, mode 600, state volume | yes: it issues certificates for that domain |
| Public join requests (a public key, a secret's hash) | `mesh/requests.json`, mode 600 | no secrets; the key is public |
| The mesh secret and its rotation (the new secret until handed over) | `mesh/secret`, `mesh/rotation.json`, mode 600 | yes |
| First-contact approvals of public nodes' agents | `mesh/approved.json` | no |
| The signed audit register | `audit/audit-enrolment/` (register-engine store) | no secrets; ids and names |

## Facilitator node, hub-on-kubernetes additions (facilitator 0.7.0)

| Data | Where | Sensitive |
| --- | --- | --- |
| A built-in hub's root CA key | `mesh/ca/<domain>/root.key` (mode 600) until `node issuer export-root` writes it to a file a person takes offline | yes: it signs new issuing CAs |
| A built-in hub's issuing CA key | `mesh/ca/<domain>/ca.key` (mode 600); gone after `node issuer migrate` (it is in OpenBao) | yes: it issues certificates for the domain |
| The CA key of the ssh-agent tier | the agent's memory only (an `ssh-agent` container beside the hub on Kubernetes); never a file | yes; custody is the person's backup of the key |
| The hub's roster backup (built-in or ssh-agent tier) | `mesh/roster.backup.json`, mode 600, the same volume | no secrets; node ids and serials |
| The hub's manifests | `bundles/facilitator/k8s` (base, overlays), `mesh.yml` in a ConfigMap, the state in a StatefulSet's volume claim | tier 1 in git; the claim is tier 4 |

## Facilitator node, cloud AI (OAuth) additions (facilitator 0.8.0)

| Data | Where | Sensitive |
| --- | --- | --- |
| The issuers the node trusts | `facilitator.yml` `http.issuers` (name, issuer URL, jwks_uri, algorithms, scope, audience), tier 1 in git | no |
| An issuer's signing keys (public) | memory only, fetched from the issuer's JWKS, kept an hour | no |
| An OAuth client | an entry of `http/clients.json` (mode 600): issuer, subject, the OAuth client_id as a label, status; **no token and no hash** | the subject can identify a person (an email, say) |
| The subject and issuer in the record | `data.via` of every message and status the client writes (a signed packet in the conversation register, replicated like the rest) | as the subject: choose an issuer whose subjects are opaque when that matters |
| An OAuth access token | never stored; read from the `Authorization` header and checked | yes; a log line keeps a reason, never the token |


## Facilitator node, approval of what crosses (facilitator 0.9.0)

| Data | Where | Sensitive |
| --- | --- | --- |
| The approval a node asks per level | `mesh.yml` `limits.<level>.approval` (`none`, `first-contact`, `every-message`, `per-conversation`), tier 1 in git | no |
| A held message | the conversation register as any message (replicated whatever the receiver asks); the receiving node's own `approval` notice marks it held | as the message |
| A person's answer | a signed `approved` or `denied` notice of the receiving node's facilitator in the conversation, and a `message-approved` or `message-denied` entry of the audit register (the message id, the person's handle, the conversation, the sender, the mode and level; no text) | no |
