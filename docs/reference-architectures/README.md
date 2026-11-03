# Reference architectures

Four ways the Features of this collection are assembled, each with what runs where, where its data lives and what
has gone wrong in the combination. They are for an engineer or a consumer's maintainer who wants to assemble an
environment from the Features without working out how they combine. The rules behind them are in the root
[README](../../README.md) ("How the pieces fit") and in [CONTRIBUTING.md](../../CONTRIBUTING.md); the decisions are
the [ADRs](../adr/README.md).

| Architecture | Use it when | Features |
| --- | --- | --- |
| [Windows workstation devhost](windows-workstation-devhost.md) | a Windows machine, the checkout in a synced folder, sessions and builds in a container started from PowerShell | `devcontainer-cli`, `git`, `ssh-agent`, `gh`, `go-task`, `common`, `cloud-folder`, `claude-code` |
| [Secrets with OpenBao](secrets-with-openbao.md) | keys and tokens in one place behind one gate (unseal once per server start, log in once per sitting); phase 1 of ADR 0048 | `openbao`, `ssh-agent`, `gh`, `az` |
| [Agentic devhost](agentic-devhost.md) | agents do the work and keep the records, with guards and a bot identity | `agents`, `claude-code`, `git`, `phi-check`, `go-task`, and the local `devhost` and `agentic-register` |
| [Kubernetes toolbox](kubernetes-toolbox.md) | rendering and validating manifests, operating Argo CD and Velero, one kubeconfig | `kustomize`, `kubeconform`, `argocd`, `velero`, `kube-state` |

They combine. This repository's own devhost is the Windows workstation devhost with the agentic devhost on top, and
the secrets architecture is the next layer for the keys both of them use. The Kubernetes toolbox stands apart: none
of its Features depends on another, and it needs only the launcher from the Windows page.

## What every page has

- who it is for and when to use it, and when not;
- an ASCII diagram: the workstation (host), the launcher, the container, the Features, the volumes and the external
  services;
- a complete `devcontainer.json` fragment in a `jsonc` block, using the published ids
  (`ghcr.io/nabil-becker/devcontainer-features/<id>:<major>`) and only options that exist;
- a table of each piece of data and its storage tier, from [ADR 0045](../adr/0045-four-storage-tiers-govern-where-data-lives-and-a-machine-loss-must-lose-nothing.md):
  tier 1 git, tier 2 shared folder (the `cloud-folder` mount), tier 3 personal folder, tier 4 working set (Feature
  volumes, rebuildable only). The test: if losing a machine would lose it, it is in the wrong tier;
- what runs on the workstation and what runs in the container;
- **Best practices** and **Anti-patterns** for the combination. An anti-pattern has Don't, Why (a real case: an issue
  or a dated ledger entry, or "no incident" said plainly), Instead and Caught by (a check, test, guard or ADR, or
  "nothing yet").

## The fragments cannot drift

`task architectures:check` (part of `task lint`, Docker-free) parses every `jsonc` fragment in this folder and fails,
naming file and line, when it names a Feature id that is not in `src/`, a major that is not the Feature's current
one, or an option that is not in its `devcontainer-feature.json` (right type, inside the enum). A Feature that is
local and unpublished is written `./features/<id>`; naming it by a published id fails. Official and third-party
Features are not checked. A block fenced `jsonc planned` is a design not built yet: it must keep failing, and the
check says so the day it would pass, so it moves into the checked fragment. The check also requires each page to
carry a diagram, both sections, the four labels on every anti-pattern, and a link from this index.
