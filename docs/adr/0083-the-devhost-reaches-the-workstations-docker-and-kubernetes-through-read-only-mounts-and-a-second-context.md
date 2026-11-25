# ADR-0083: The devhost reaches the workstation's Docker and Kubernetes through explicit mounts and a second context

| | |
|---|---|
| **Status** | accepted |
| **Date** | 2026-11-25 |
| **Deciders** | the Operator; proposed by the host |

## Context

The devhost runs docker-in-docker, so tests and agents are isolated from the workstation's
Docker. Testing the facilitator's OAuth flow with a real browser needs services published on
the workstation (the devhost forwards no ports), and deploying the hub to the workstation's
Kubernetes cluster needs access to its Docker engine (to build images the cluster can use
without a registry) and to the cluster's API. From inside the devhost, `127.0.0.1` is the
container itself, and no `kubectl` or kubeconfig was present.

## Decision

The devhost gets two opt-in reaches into the workstation, each by a visible mount and not by a
side door:

1. **Docker:** the workstation's Docker socket is mounted at `/var/run/docker-host.sock`.
   `.devcontainer/docker-host.sh` runs at every start, gives the `vscode` user access to the
   socket and creates a Docker context named `host`. docker-in-docker stays the default context;
   `docker --context host` (or `DOCKER_CONTEXT=host`) reaches the workstation's. Tests, agents
   and the start-time cleanup (ADR 0072) use only the internal Docker.
2. **Kubernetes:** the devhost installs `kubectl` (pinned), `kube-state`, `kustomize` and
   `kubeconform`, mounts the workstation's `~/.kube` read-only, and a start hook imports it into
   the kube-state volume (mode 600) and points the API server at `host.docker.internal:6443`.

## Options considered

### Option 1: the chosen one

Mounts and a named context are visible in `devcontainer.json`, reviewed in a pull request,
and removable by deleting a line. The Operator controls what the kubeconfig holds.

### Option 2: read the cluster's admin config through the `host` Docker context

Needs no rebuild, but takes full cluster-admin by a side door that works only because the
Docker socket is full control. Rejected: not visible, not reviewable.

### Option 3: run the test in the workstation's Docker with Claude Code on Windows

More moving parts and needs Claude Code installed on Windows. Chosen for the first run before
the cluster work, but not as the standing way.

## Consequences

- The devhost can build images and deploy to a test namespace on the workstation.
- The Docker socket is full control of the workstation's Docker: only the `host` context
  reaches it, and nothing automated uses it.
- The devhost does not start on a runtime without `/var/run/docker.sock` or without
  `%USERPROFILE%\.kube`; the fix is to remove the mount line.
- Pull requests 246 (Docker) and 247 (Kubernetes) carry the change.

## Change log

| Date | Change |
|---|---|
| 2026-11-25 | First draft. |
