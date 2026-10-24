#!/usr/bin/env bash
# Copy every src/<id> and local-features/<id> Feature into .devcontainer/features/<id>
# (gitignored), so the devcontainer configs reference the unpublished Features by
# local path. `task features:stage` runs this on Linux/macOS; the Lint workflow runs
# it directly (the runner has no Task) before building .devcontainer/ci.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf .devcontainer/features
mkdir -p .devcontainer/features
n=0
for d in src/*/ local-features/*/; do
  [ -d "$d" ] || continue
  cp -r "$d" ".devcontainer/features/$(basename "$d")"
  n=$((n + 1))
done
echo "staged $n Features into .devcontainer/features"
