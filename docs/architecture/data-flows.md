# Data flows

How data moves between the workstation, the container, the shared folder, GitHub and the
registry. Diagrams first. First version, written 2026-11-19; Mermaid and text here are the
reviewed source, Whiteboard boards are generated from them later.

Node ids are ontology ids (`docs/model/ontology.toml`); `external-` marks what is outside the
model. Paths and ids only, never content. `%USERPROFILE%` and `%LOCALAPPDATA%` are placeholders.
Where a fact is not read from a file it says "to verify".

## Trust boundaries

Five zones. Every arrow that crosses a dotted frame is a place where data leaves one owner's
hands.

```mermaid
flowchart LR
  subgraph external-zone-ws["Zone 1: workstation (the Operator's machine)"]
    workstation["Workstation"]
  end
  subgraph external-zone-ct["Zone 2: container (the devhost)"]
    devhost["Devhost"]
  end
  subgraph external-zone-sf["Zone 3: the shared folder"]
    external-shared-folder["Shared folder (tier 2)"]
  end
  subgraph external-zone-gh["Zone 4: GitHub"]
    external-github["GitHub"]
  end
  subgraph external-zone-reg["Zone 5: the Feature registry"]
    feature-registry["Feature registry"]
  end
  workstation -->|launches, binds folders| devhost
  devhost -->|reads, writes records| external-shared-folder
  workstation -->|syncs folder| external-shared-folder
  devhost -->|pushes branches| external-github
  external-github -->|release publishes| feature-registry
  feature-registry -->|Features pulled at build| devhost
```

- One person (the Operator) owns zones 1 to 3. GitHub and the registry are public.
- Sources: `docs/model/c4-context.md`, `src/cloud-folder/NOTES.md`, `.github/workflows/release.yaml`.

## 1. Workstation to launcher to container

The launcher is the `devcontainer-cli` Feature's host tasks. It reads `.devcontainer/.env` and
the environment, passes `DCF_HOST_*` variables and adds bind mounts. The container never
reads the host on its own.

```mermaid
flowchart LR
  subgraph external-zone-ws["Workstation"]
    external-env[".devcontainer/.env"]
    external-gitdirs["%USERPROFILE%/.git-dirs"]
    external-hostagent["Host SSH agent socket (some hosts)"]
    external-cloudsync["Synced folder (DCF_HOST_CLOUD_FOLDER)"]
    external-relay["Audio relay folder (DCF_HOST_AUDIO=wslg)"]
    launcher["Launcher: task devcontainer:up"]
  end
  subgraph external-zone-ct["Container"]
    external-gitdirs-ct["/git-dirs"]
    external-sock["ssh-agent/agent.sock"]
    host-mount["/mnt/cloud-folder-host"]
    external-audio["/mnt/wsl/devhost-audio"]
    external-vars["DCF_HOST_TYPE, _MACHINE, _FUSE, _AUDIO, _SSH_AGENT"]
  end
  external-env -->|settings| launcher
  launcher -->|containerEnv from localEnv| external-vars
  external-gitdirs -->|bind mount, whole folder| external-gitdirs-ct
  external-hostagent -->|bind mount, socket only| external-sock
  external-cloudsync -->|bind mount| host-mount
  external-relay -->|bind mount, gated by TTL| external-audio
```

- The whole `.git-dirs` folder is mounted: every container sees every git dir there (ADR 0020, accepted by the Operator 2026-10-21). The git wrapper maps the checkout's `.git` pointer onto `/git-dirs`.
- The agent socket is mounted only on hosts that have a unix socket; Windows engines get none (`src/ssh-agent/NOTES.md`). No keys cross.
- `HOST_MOUNTS=false` removes the launcher's own mounts (`src/devcontainer-cli/NOTES.md`).
- Sources: `.devcontainer/devcontainer.json`, `docs/adr/0020-*.md`, `src/devcontainer-cli/NOTES.md`, `src/audio/NOTES.md`.

## 2. Feature state into named volumes

Each Feature that holds state declares one named volume and a `*_DIR` variable. `dcf-persist`
hands it to the remote user. A repo may replace a volume with a bind mount on the same target.

```mermaid
flowchart LR
  subgraph external-zone-ct["Container"]
    feature["Features' setup hooks"]
    external-persist["dcf-persist"]
  end
  subgraph external-vols["Named volumes: /var/lib/devcontainer-features/..."]
    feature-state["Feature state"]
    external-vclaude["claude-code: login, settings, sessions, memory"]
    external-vgit["git: global config"]
    external-vgh["gh: token"]
    external-vaz["az, argocd, coder-cli, kube-state: logins, kubeconfig"]
    external-vbao["openbao-config: token, raft, audit.log, approle"]
    external-vcf["cloud-folder: rclone token, sync state"]
    external-vdh["devhost, agentic-register: jobs state, ledger store"]
  end
  feature -->|calls| external-persist
  external-persist -->|prepares| feature-state
  feature-state --- external-vclaude
  feature-state --- external-vgit
  feature-state --- external-vgh
  feature-state --- external-vaz
  feature-state --- external-vbao
  feature-state --- external-vcf
  feature-state --- external-vdh
```

- Volumes survive a rebuild and are deleted by an engine storage reset or a move to another engine. They are tier 4, rebuildable only (ADR 0045).
- Two exceptions are named: openbao server storage (ADR 0048, bounded loss) and Claude Code memory (ADR 0049: belongs in tier 3, not yet mirrored; backlog item named there).
- `go-task`, `kubeconform`, `kustomize`, `dsc`, `velero`, `devcontainer-cli`, `common` hold no data of their own.
- Sources: `src/common/NOTES.md`, every `src/*/NOTES.md` data table, `docs/adr/0045-*.md`, `docs/adr/0049-*.md`.

## 3. Records

The scribe, secretary and librarian are backs. They run after a turn, inside the devhost only.
With `DEVHOST_RECORDS_DIR` and `DEVHOST_LEDGER_REGISTER` set (as in this repository's
`.devcontainer/devcontainer.json`) the records leave git.

```mermaid
flowchart TB
  subgraph external-zone-ct["Container"]
    inter["Session (the host)"]
    scribe["Scribe"]
    secretary["Secretary"]
    librarian["Librarian"]
    external-regstore["Register store: volume agentic-register/registers/ledger"]
    adr["ADR docs/adr"]
    lexicon["Lexicon LEXICON.md"]
    external-model["docs/model/ontology.toml"]
  end
  subgraph external-zone-sf["Shared folder (DEVHOST_RECORDS_DIR=/mnt/cloud-folder)"]
    backlog["Backlog TODO.md"]
    external-mirror["ledger/ mirror"]
    external-reviews["reviews/"]
    cost-store["costs/ reports and jsonl"]
  end
  subgraph external-zone-gh["GitHub"]
    external-gitrepo["Repository: ADRs, lexicon, model"]
  end
  inter -->|turn ends| scribe
  inter -->|turn ends| secretary
  inter -->|turn ends| librarian
  scribe -->|signs entries| external-regstore
  external-regstore -->|mirror| external-mirror
  scribe -->|cost of each stretch| external-regstore
  secretary -->|adds, ticks| backlog
  librarian -->|adds| adr
  librarian -->|adds| lexicon
  librarian -->|adds| external-model
  inter -->|ledger review| external-reviews
  inter -->|cost report| cost-store
  adr -->|commit, push| external-gitrepo
  lexicon -->|commit, push| external-gitrepo
```

- Unset, everything works as before: Markdown ledger in `docs/ledger/`, `TODO.md` at the root, in git.
- The live ledger store stays in the volume (fast). `devhost-ledger mirror` copies to the shared folder only when that folder exists, and `devhost-setup` restores a fresh volume from it at every create.
- Each ledger entry is signed with the scribe's own key, fetched from OpenBao into tmpfs (see flow 4).
- Backlog outside the repository has no `backlog_ids` check in `devhost-verify`.
- Sources: `local-features/devhost/NOTES.md` ("Records outside git"), `docs/ledger/README.md`, `docs/adr/0054-*.md`, `docs/adr/0043-*.md`.

## 4. Secrets

OpenBao keeps every secret the collection creates. `ssh-agent` only uses keys. The design is
`docs/reference-architectures/secrets-with-openbao.md`; parts are planned, not built. Read the
"What exists today" table there before relying on a row.

```mermaid
flowchart LR
  subgraph external-zone-ws["Workstation"]
    external-keyfile["OpenBao key file (DPAPI): shares 4, 5, approle login"]
    external-hostkeys["Operator's own agent keys"]
    external-custody["Custody: shares 1 to 3, held by people"]
  end
  subgraph external-zone-ct["Container"]
    central-server["OpenBao server or central server"]
    external-bao["bao CLI + dcf-secret"]
    external-sshagent["ssh-agent socket"]
    external-gh["gh token (volume gh)"]
    scribe["Scribe, backs (AppRole)"]
  end
  subgraph external-zone-pf["Personal folder (tier 3)"]
    snapshot["Snapshots openbao-*.snap"]
  end
  external-keyfile -->|unseal, login at up| central-server
  external-custody -.->|rebuilds key file; never in container| external-keyfile
  external-bao -->|reads, writes| central-server
  scribe -->|key fetched into tmpfs| external-bao
  external-hostkeys -->|socket mount, no key crosses| external-sshagent
  central-server -->|backup, server mode| snapshot
  external-bao -.->|planned: fetch long-lived credentials| external-gh
```

- Unseal shares and the recovery key are custody, outside every tier (ADR 0049). They are never in the container.
- The key file is DPAPI-protected, Windows only, one file per server, not in the checkout, git or the shared folder. On a domain-joined machine the domain backup key also opens it (`src/devcontainer-cli/NOTES.md`).
- Snapshots go to the path in `DEST`; the ruling (the backlog item `openbao-backup-destination`, done 2026-11-10) puts them in the personal folder (tier 3), never the shared folder. A snapshot holds the whole server store: secret.
- Today `gh` and `az` still keep their own logins in their own volumes; they move to OpenBao later.
- The SSH certificate authority key never leaves OpenBao (`src/openbao/NOTES.md`, openbao 1.6.0, unreleased at the time of writing: to verify).
- Sources: `docs/reference-architectures/secrets-with-openbao.md`, `src/openbao/NOTES.md`, `src/ssh-agent/NOTES.md`, `src/gh/NOTES.md`, `docs/adr/0048-*.md`, `docs/adr/0049-*.md`.

## 5. The cloud folder

The `cloud-folder` Feature gives one fixed path, `/mnt/cloud-folder`, for documents that must
never go in git. Three modes fill it.

```mermaid
flowchart LR
  external-remote["Shared folder: document library or personal drive"]
  subgraph external-zone-ws["Workstation"]
    external-syncclient["Sync client's host folder"]
    launcher["Launcher"]
  end
  subgraph external-zone-ct["Container"]
    host-mount["/mnt/cloud-folder-host"]
    external-mp["/mnt/cloud-folder (mountPoint)"]
    external-rclone["rclone: sync or mount"]
    external-cfvol["Volume cloud-folder: token, config, sync state, VFS cache"]
  end
  external-remote <-->|sync client| external-syncclient
  external-syncclient -->|bind mount| launcher
  launcher -->|host mode| host-mount
  host-mount -->|link| external-mp
  external-remote <-->|bisync or mount| external-rclone
  external-rclone -->|fills| external-mp
  external-rclone -->|keeps| external-cfvol
```

- Host mode needs no sign-in in the container. Sync and mount modes keep an rclone token in the volume (secret, tier 4).
- Mount mode needs FUSE, granted per machine only with `DCF_HOST_FUSE=1` (ADR 0031).
- When nothing is mounted the mount point is absent, so the status fails and no one writes into a bare folder.
- Sources: `src/cloud-folder/NOTES.md`, `docs/adr/0031-*.md`.

## 6. Code to GitHub, release to the registry

The host (the session) commits, pushes and opens pull requests. The Operator reviews and merges
(ADR 0040). The Operator starts the release; an agent never does.

```mermaid
flowchart LR
  subgraph external-zone-ct["Container"]
    devhost["Devhost: topic branch, signed-off commits"]
    external-tests["task lint, task test"]
  end
  subgraph external-zone-gh["GitHub"]
    external-github["Repository, protected main"]
    external-checks["Required checks: validate, lint, tests, DCO"]
    release["Release workflow (manual)"]
  end
  subgraph external-zone-reg["Feature registry (GHCR)"]
    feature-registry["ghcr.io/.../devcontainer-features/id"]
  end
  consuming-repo["Consuming repos: office, DSNP"]
  devhost -->|verify before commit| external-tests
  devhost -->|push branch, open PR| external-github
  external-github -->|runs| external-checks
  external-github -->|Operator starts| release
  release -->|publishes tags major, minor, patch, latest| feature-registry
  feature-registry -->|pulled at devcontainer build| consuming-repo
```

- Commits carry the bot identity and a co-author trailer at an unclaimable address (ADR 0002, `CLAUDE.md`). No ledger or backlog content is pushed when the records are outside git.
- Pre-commit runs `devhost-verify`: no secrets, no names from the redact list.
- The release job has `contents: read` and `packages: write` only; READMEs are not generated there.
- Sources: `CLAUDE.md`, `.github/workflows/release.yaml`, `docs/adr/0040-*.md`, `docs/model/c4-context.md`.

## 7. The component registry

Built in slice 1 (component-registry 1.0.0): sources `git` and `path`, the view in the Feature's
volume. Later: the `http` and `cloud-folder` sources (slice 3) and the hand-over to the CLI's
skills folder (slice 2), drawn dashed.

```mermaid
flowchart LR
  external-sources["Layer sources: git, a folder or file share"]
  external-http["Later: http, cloud folder"]
  master-of-secrets["OpenBao"]
  subgraph external-zone-ct["Container"]
    component-registry["component-registry: dcf-registry"]
    external-copies["Layer copies, tier 4, owner-only"]
    external-view["Resolved view, tier 4, owner-only"]
    external-cli-skills["The CLI's skills folder, tier 4"]
  end
  launcher["Launcher"]
  external-sources -->|registry-source-git, -path| external-copies
  external-http -.->|later| external-copies
  master-of-secrets -->|dcf-secret: source secrets| external-copies
  launcher -.->|later: mounts a share, sets whoami| component-registry
  external-copies --> component-registry
  component-registry -->|resolve| external-view
  external-view -.->|later: skills verb| external-cli-skills
```

- Who you are (`COMPONENT_REGISTRY_WHOAMI`) comes from `.env` or the launcher, never a committed file.
- A layer copy and the view are as sensitive as their most sensitive layer (a person's own layer may hold health facts): owner-only, never committed. `explain` prints to the terminal only.
- Sources: `src/component-registry/NOTES.md`, `docs/proposals/component-registry.md`, `docs/adr/0063-*.md`.

## Gaps seen while drawing

- Claude Code memory sits in a tier 4 volume though it cannot be rebuilt (ADR 0049 names the move to tier 3; whether it has shipped: to verify).
- OpenBao snapshot files were seen in the shared folder although the 2026-11-10 ruling puts them in the personal folder; the older open item `amend-openbao-local-storage` still says the shared folder. One of the two needs closing.
- `/git-dirs` shows every git dir to every container (accepted, ADR 0020).
