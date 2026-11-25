# ADR-0084: The workstation's lasting facilitator hub runs on Rancher Desktop from a git-ignored overlay, with the built-in issuer

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-25 |
| **Deciders** | the Operator; proposed by the host session |

## Context

The facilitator 0.7.0 release ships a hub on Kubernetes (`bundles/facilitator/k8s/`: a base and
the overlays `rancher-desktop` and `ssh-agent`) and a built-in issuer with three tiers for the CA
key (ADR-0078). The Operator wants a lasting hub on the workstation's local Rancher Desktop
cluster, so that the agents of several devcontainers can reach one another, with the MCP-over-HTTP
endpoint off. The cluster is reached from the devhost through the read-only mounts and second
context of ADR-0083. Three questions had real options: where the hub's own overlay lives, which
spokes join first, and where the CA key lives.

## Decision

- The hub's kustomize overlay lives in the folder `.devcontainer/facilitator-workstation/` of this
  repository, which is git-ignored. It holds `kustomization.yaml`, `mesh.yml`, `facilitator.yml`
  and `participants.yml`, and no secret. The base is `bundles/facilitator/k8s/base`; the image is
  the released node image pinned by digest.
- The hub's role is hub, its node name is `host.docker.internal` (so spokes in devcontainers reach
  it by a name they already resolve and the certificate matches), its trust is private, nothing is
  public, Directory peering is off, and the HTTP endpoint is off. Only the SLIM port (46358) and
  the join port (46359) are published, as LoadBalancer Services.
- The first spokes are this devhost and the office repository. Each adds the facilitator Feature
  in node mode and a committed `.devcontainer/mesh.yml` with the hub's trust domain.
- The built-in issuer is used, with the CA key as a file in the hub's volume (the third tier of
  ADR-0078). The Operator exports the root offline with `node issuer export-root`.
- The person-only commands (`node invite`, `node join`, `node issuer export-root`, approve,
  revoke) are printed for the Operator and never run by an agent; the guard that refuses them in
  an agent's job is not bypassed.
- Every kubectl call uses `--context rancher-desktop` and the current context is never changed,
  because the kubeconfig also holds a client's cluster. A task `facilitator:workstation-hub`
  renders, applies, shows the status of and deletes the hub, and says so plainly when the overlay
  folder is absent.

## Options considered

### Option 1: a git-ignored overlay folder in this repository, spokes devhost and office, built-in issuer with the key as a file (chosen)

The overlay stays next to the tooling that applies it, carries nothing a stranger needs, and
cannot leak a workstation detail into a release. The file tier needs no OpenBao or ssh-agent on
the cluster; the offline root export bounds the loss.

### Option 2: commit the overlay to this repository

Rejected: it describes one workstation, not a Feature, and every consumer would see it.

### Option 3: keep the overlay in the shared (cloud) folder or in the office repository

Rejected for now: it moves the hub's definition away from the devhost that applies it and
splits the records between repositories.

### Option 4: the CA key in OpenBao or in an ssh-agent

Rejected for the first hub: neither runs on the Rancher cluster, and the extra moving parts
outweigh the benefit for a hub that serves one workstation.

## Consequences

- The hub is rebuilt from a folder that git does not hold, so the folder is a tier-1 loss on a
  machine change (ADR-0045); it holds no secret and can be regenerated from this record.
- The CA key stays a file in the volume until the Operator exports the root; until then the
  hub's check warns, as intended.
- A spoke's `node join` writes hub fields into its committed `.devcontainer/mesh.yml`, which
  leaves a local diff; how to keep that out of commits is open.
- A Feature version newer than the pinned bundle (here Feature 0.8.0 against bundle 0.7.0) must be
  verified at the first rebuild; if it does not run, the hub is redeployed on the new release or
  the spoke's Feature is pinned to the 0.7.0 release.

## Change log

| Date | Change |
|---|---|
| 2026-11-25 | First draft, from the Operator's rulings of this date. |
