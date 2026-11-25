#!/usr/bin/env bash
# The node's mesh.yml lives in the facilitator volume, not in git (workstation-hub, ruling A, 2026-11-25):
# `facilitator node join` writes the hub's address into it, and that must not become a local diff of a
# committed file. The first start copies the committed template, .devcontainer/mesh.template.yml, to
# FACILITATOR_MESH_FILE; later starts leave the joined file alone. Used by postStartCommand. Never fails.
set -uo pipefail
target="${FACILITATOR_MESH_FILE:-}"
template="$(dirname "$0")/mesh.template.yml"
if [ -z "$target" ] || [ ! -f "$template" ]; then
  echo "mesh-seed: FACILITATOR_MESH_FILE or the template is missing; nothing to do"
  exit 0
fi
if [ -f "$target" ]; then
  echo "mesh-seed: $target is there (joined or edited); the template is not copied again"
  exit 0
fi
mkdir -p "$(dirname "$target")" && install -m 600 "$template" "$target" \
  && echo "mesh-seed: $target made from the template; run facilitator node join --token <token> to join the hub"
exit 0
