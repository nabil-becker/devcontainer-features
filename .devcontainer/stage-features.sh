#!/usr/bin/env bash
# Copy every src/<id> and local-features/<id> Feature into .devcontainer/features/<id>
# (gitignored), so the devcontainer configs reference the unpublished Features by
# local path. `task features:stage` runs this on Linux/macOS; the Lint workflow runs
# it directly (the runner has no Task) before building .devcontainer/ci. A directory
# without devcontainer-feature.json is not a Feature (a leftover of a move, say) and is
# skipped with a warning; the same id in both trees is an error, because the second copy
# would land inside the first and the Feature would be missing its manifest.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf .devcontainer/features
mkdir -p .devcontainer/features
n=0
for d in src/*/ local-features/*/; do
  [ -d "$d" ] || continue
  id="$(basename "$d")"
  if [ ! -f "$d/devcontainer-feature.json" ]; then
    echo "not staged: $d has no devcontainer-feature.json (a leftover directory? remove it)" >&2
    continue
  fi
  if [ -e ".devcontainer/features/$id" ]; then
    echo "Feature id '$id' exists in both src/ and local-features/; keep one." >&2
    exit 1
  fi
  cp -r "$d" ".devcontainer/features/$id"
  n=$((n + 1))
done
echo "staged $n Features into .devcontainer/features"
