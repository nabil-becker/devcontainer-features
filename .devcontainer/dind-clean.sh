#!/usr/bin/env bash
# Empties the docker-in-docker daemon of everything: images, containers,
# networks, volumes and the build cache. This daemon is only used for
# `task test` here, so nothing in it is worth keeping (dind-no-cache).
# Used by postStartCommand (every start) and by `task test` (after each run).
# Usage: dind-clean.sh [--wait]   --wait: give a starting dockerd up to 30 s.
set -uo pipefail

if [ "${1:-}" = "--wait" ]; then
  for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 1
  done
fi

if ! docker info >/dev/null 2>&1; then
  echo "dind-clean: no Docker daemon reachable (wslc?); nothing to clean"
  exit 0
fi

used() { docker system df --format '{{.Size}}' 2>/dev/null | paste -sd' ' -; }
before=$(used)
docker system prune -af --volumes >/dev/null 2>&1 || echo "dind-clean: docker system prune failed"
docker builder prune -af >/dev/null 2>&1 || echo "dind-clean: docker builder prune failed"
echo "dind-clean: pruned docker-in-docker (sizes before: ${before:-none}; after: $(used))"
exit 0
