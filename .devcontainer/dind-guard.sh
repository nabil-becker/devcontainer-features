#!/usr/bin/env bash
# Refuses (exit 1) when the filesystem holding /var/lib/docker has less than
# MIN_FREE_GB (default 20) free; FORCE=1 overrides. Used by `task test`.
set -euo pipefail

min=${MIN_FREE_GB:-20}
path=${DOCKER_ROOT:-/var/lib/docker}
[ -d "$path" ] || path=/
free_gb=$(df -Pk "$path" | awk 'NR==2 {print int($4/1024/1024)}')

if [ "$free_gb" -lt "$min" ]; then
  if [ "${FORCE:-}" = "1" ]; then
    echo "dind-guard: only ${free_gb} GB free on $path (< ${min} GB); continuing because FORCE=1"
    exit 0
  fi
  echo "dind-guard: only ${free_gb} GB free on $path, need ${min} GB. Run .devcontainer/dind-clean.sh, or FORCE=1 task test to override." >&2
  exit 1
fi
echo "dind-guard: ${free_gb} GB free on $path"
