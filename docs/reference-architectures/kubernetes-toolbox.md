# Kubernetes toolbox

A devcontainer that renders and validates Kubernetes manifests, operates Argo CD and Velero, and keeps the
cluster credentials in one place that survives a rebuild, with every CLI pinned to the version of the thing it
talks to.

## Who it is for, and when to use it

Use it when an engineer or a consumer's maintainer works on a GitOps repository: kustomizations to build and
check before they are pushed, an Argo CD server to diff and sync against, a Velero installation to inspect and
back up, and one or more kubeconfigs to keep off the checkout. The laptop and the pipeline then run the same
versions, so what renders here renders there.

Not for: building images or running a cluster (no Docker or minikube here), or a repository that only needs one of
the CLIs (take that Feature alone; none depends on another). `kube-state` matters only to the tools that read a
kubeconfig, which are `kubectl` and `velero`: `kustomize` and `kubeconform` work on files and `argocd` keeps its own
login.

## Diagram

```text
 WORKSTATION (host)                        CONTAINER ENGINE
 +--------------------------+  task dc:up       |
 | launcher only            |------------------>|
 | (see the Windows         |  task dc:exec     v
 |  workstation devhost)    |      +--------------------------------------------------------------+
 +--------------------------+      | DEVCONTAINER                                                 |
                                   |                                                              |
   git remote  <-- push/pull ----> |  /workspaces/gitops   manifests, kustomizations (tier 1)     |
   (the pipeline runs the          |                                                              |
    same versions)                 |  kustomize    kustomize build, build:all                     |
                                   |  kubeconform  validate, validate:kustomize                   |
                                   |      renders and checks files: offline, no KUBECONFIG       |
                                   |                                                              |
   Kubernetes schemas, CRD   <-----|--  schemas fetched over HTTPS at validation time             |
   catalog (network)               |                                                              |
                                   |  kubectl (official Feature)       velero                     |
   KUBERNETES API  <---------------|--  reads KUBECONFIG --------------+ backups, restores         |
   (the cluster)                   |        ^                                                     |
                                   |  kube-state: KUBECONFIG -> /var/lib/devcontainer-features/   |
   ARGO CD SERVER  <---------------|--  argocd   kube-state/config   (its own login, not          |
                                   |  login, apps, diff, sync          KUBECONFIG)                |
                                   |                                                              |
                                   |  volumes (tier 4): kube-state-config, argocd-config          |
                                   +--------------------------------------------------------------+
   Velero backup storage: in the cluster's own object store; this container holds none of it
```

## `devcontainer.json`

Pin each CLI to what it talks to: `kustomize` and `kubeconform` to the pipeline's versions, `argocd` and `velero` to
the servers'. The two official Features are not part of this collection and are not checked.

```jsonc
{
  "name": "k8s-toolbox",
  "image": "mcr.microsoft.com/devcontainers/base:debian",
  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": {},
    // kubectl only: kube-state orders itself after this Feature, velero reads its kubeconfig, and
    // kustomize --enable-helm needs helm on PATH if a chart is inflated (then drop "helm": "none").
    "ghcr.io/devcontainers/features/kubectl-helm-minikube:1": {
      "helm": "none",
      "minikube": "none"
    },
    "ghcr.io/nabil-becker/devcontainer-features/go-task:1": {},
    "ghcr.io/nabil-becker/devcontainer-features/kustomize:1": {
      "version": "5.8.3"
    },
    "ghcr.io/nabil-becker/devcontainer-features/kubeconform:1": {
      "version": "0.8.0"
    },
    "ghcr.io/nabil-becker/devcontainer-features/argocd:1": {
      "version": "3.5.4"
    },
    "ghcr.io/nabil-becker/devcontainer-features/velero:1": {
      "version": "1.18.4"
    },
    "ghcr.io/nabil-becker/devcontainer-features/kube-state:1": {
      "restrictPermissions": true
    }
  },
  // No mounts, no containerEnv: KUBECONFIG and ARGOCD_CONFIG_DIR are set by the Features, each on a volume.
  // For the host disk instead, bind the same targets from ~/.devcontainer-homes (task devcontainer:homes
  // creates the folders), or bind the workstation's own ~/.kube on the kube-state target.
  "remoteUser": "vscode"
}
```

The version numbers are examples: set each to the version of what it talks to, and bump it when that is upgraded
(`velero version` shows client and server). In the repository, a root `Taskfile.yml` includes the go-task registry
(`/usr/local/share/go-task/features.yml`, `flatten: true`) so `task kustomize:build:all`,
`task kubeconform:validate:kustomize DIR=overlays/prod`, `task argocd:diff APP=<name>`, `task velero:backups` and
`task kube-state:import FILE=./cluster.yaml` appear in `task --list`.

## Data and its storage tier

Tiers as in [ADR 0045](../adr/0045-four-storage-tiers-govern-where-data-lives-and-a-machine-loss-must-lose-nothing.md):
1 git, 2 shared folder, 3 personal folder, 4 working set (rebuildable only).

| Data | Where it lives | Tier | A rebuild | Losing the machine |
| --- | --- | --- | --- | --- |
| Manifests, kustomizations, overlays, the Feature versions in `devcontainer.json` and its lock file | the repository | 1 | untouched | kept once pushed |
| The kubeconfig (cluster credentials) | volume `kube-state-config-${devcontainerId}`, file `KUBECONFIG=/var/lib/devcontainer-features/kube-state/config`, mode 0600 | 4 | kept | import it again: `task kube-state:import FILE=...` or the cloud's own command (`az aks get-credentials`) |
| The Argo CD login (contexts, servers, tokens) | volume `argocd-config-${devcontainerId}` at `ARGOCD_CONFIG_DIR` | 4 | kept | `task argocd:login SERVER=...` |
| Velero's own state | none in the container: it reads `KUBECONFIG`; the backups live in the cluster's object store | the cluster's | untouched | untouched |
| Rendered manifests | standard output; nothing written | none | not applicable | not applicable |
| CRD and Kubernetes schemas | fetched over HTTPS at each validation, not kept | none | fetched again | fetched again |
| A kubeconfig or Argo CD config kept on the host disk instead | `~/.devcontainer-homes/<repo>/<id>` or the workstation's `~/.kube`, bound on the same target | a durable tier 4 folder; ADR 0045 does not name it | kept, also across an engine reset | kept only if the disk is |

The kubeconfig and the Argo CD config hold credentials: neither belongs in a synced checkout.

## On the workstation, and in the container

| On the workstation (host) | In the container |
| --- | --- |
| the launcher: `task dc:up`, `rebuild`, `exec`, `stop`; nothing else is installed | every CLI: `kustomize`, `kubeconform`, `argocd`, `velero`, `kubectl` |
| a kubeconfig file, if you import from one (`kube-state:import FILE=` reads a path in the workspace or a mounted path) | the kubeconfig volume, `kube-state:import`, `:contexts`, `:use` |
| a browser, for `argocd login --sso` | `argocd:login`, `:apps`, `:diff`, `:sync`; `velero:backups`, `:backup`, `:describe`, `:restores`, `:schedules` |
| nothing of the cluster | contact with the cluster and the Argo CD server, and with the schema locations |

## Best practices

- **Pin every CLI to its counterpart.** `kustomize` and `kubeconform` to the versions your pipeline runs, `argocd` to
  the Argo CD server's version and `velero` to the Velero server's. `latest` is resolved once at image build, so two
  builds a month apart can differ. Commit the lock file (`task devcontainer:lock`).
- **Validate what Argo CD will sync, then diff, then sync.** `task kubeconform:validate:kustomize DIR=<overlay>` before
  the push, `task argocd:diff APP=<name>` before `task argocd:sync APP=<name>`: the sync changes the cluster.
- **Import the kubeconfig once and keep it out of the checkout.** The volume survives a rebuild; for an engine reset,
  bind a host folder on the same target. `kube-state-setup` sets mode 0600 and reports what backs the folder.
- **Know which tool reads what.** `kubectl` and `velero` read `KUBECONFIG`; `argocd` keeps its own session; `kustomize`
  and `kubeconform` read files only. Only the first two need `kube-state`.
- **Read the lines, not only the exit code, of `task kustomize:build:all`.** It builds every directory and reports at the
  end, and it also builds bases and components that are not meant to render alone, which can show `FAIL`.
- **Run the schema check online, with a catalog you control.** Point `CRD_CATALOG` at a mirror where the network is
  restricted; `-strict` rejects unknown fields, so drop it through `KUBECONFORM_FLAGS` only for extension fields you
  mean.
- **Add `helm` only if charts are inflated.** `kustomize --enable-helm` and remote bases fetch at build time and need
  the network.

## Anti-patterns

### K1. Assuming a tool reads the kubeconfig

- **Don't:** route `kustomize`, `kubeconform` or `argocd` through `kube-state`, or expect `kubectl`'s context to decide
  where they act.
- **Why:** 2026-10-17 "kubeconform NOTES.md brought to standard, version bumped" and 2026-10-19 "Installer
  documentation standardized for four Features": the root README and `kube-state`'s NOTES had said that `kustomize` and
  `kubeconform` read `KUBECONFIG`; they do not (fixed in kube-state 1.0.1). A reader would have looked for a cluster
  setting that does nothing.
- **Instead:** `kube-state` for `kubectl` and `velero`; `argocd:login` for Argo CD; nothing for the two file tools.
- **Caught by:** nothing yet; the NOTES now state it per Feature.

### K2. A kubeconfig or Argo CD config in the checkout, or mounted by hand per repository

- **Don't:** hand-mount `~/.kube` into each repository, or point `KUBECONFIG` or `ARGOCD_CONFIG_DIR` into a synced
  checkout.
- **Why:** 2026-10-16 "Add kube Feature for KUBECONFIG state (TD-07)": the Feature exists so Velero and kustomize users
  stop hand-mounting the kubeconfig. Both files hold credentials, and a synced checkout uploads them.
- **Instead:** the Feature's volume, or a host folder bound on the same target; `kube-state-setup` reports `image` when
  no mount backs the folder, in which case the login does not survive.
- **Caught by:** `kube-state-setup`'s mode and backing report. Nothing yet stops a kubeconfig being committed: the
  devhost's secrets guard matches known token and PEM private-key patterns, which a kubeconfig's base64
  `client-key-data` or a bearer token does not match.

### K3. A client that drifts from its server

- **Don't:** leave `version` at `latest`, or let `argocd` and `velero` fall behind the servers they talk to.
- **Why:** no incident in the ledger; the NOTES of `velero` and `argocd` say the Feature does not check the match, and
  `latest` is resolved at image build, so two builds differ.
- **Instead:** pin to the server's version, and bump with the server (`velero version` shows both).
- **Caught by:** nothing yet.

### K4. Trusting an offline `kubeconform` pass

- **Don't:** read a green `kubeconform` run with no network as a full check.
- **Why:** no incident in the ledger; the NOTES explain that with the default `-ignore-missing-schemas` an unreachable
  CRD schema is skipped silently, so a green run offline checks less than it seems to.
- **Instead:** run it where the schema locations answer, point `CRD_CATALOG` at a mirror, or drop the flag through
  `KUBECONFORM_FLAGS` and accept the failures.
- **Caught by:** nothing yet.

### K5. Syncing without a diff

- **Don't:** run `task argocd:sync` before `task argocd:diff`, or sync with `--prune` unseen.
- **Why:** no incident in the ledger; the task changes the cluster, and its description says to diff first.
- **Instead:** diff, read it, then sync, from a context you have checked with `task kube-state:contexts`.
- **Caught by:** nothing yet (the task's description is the only guard).

### K6. A hand-written download step for a tool

- **Don't:** add your own `curl | tar` step to a post-create script or a Dockerfile for one of these CLIs.
- **Why:** 2026-10-28 "Diagnosis of the failing kubeconform check on PR #87": a release download was cut off after 90
  seconds (curl exit 56) and failed the job; the installers had no retry.
- **Instead:** the Features, which download through `dcf-curl` (retries every error) and verify the release checksum
  before installing.
- **Caught by:** `task common:curl-check` and ADR 0034, for the Features of this collection; nothing yet for a
  consumer's own scripts.
