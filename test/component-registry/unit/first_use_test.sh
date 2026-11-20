#!/usr/bin/env bash
# The component registry's first real use (slice 4 of docs/proposals/component-registry.md): the
# architecture-review skill split into the devhost Feature's generic layer
# (local-features/devhost/share/registry) and this repository's layer (.devcontainer/registry/repo),
# listed in .devcontainer/registry.yml. This test runs the real dcf-registry on the real layer list
# (the devhost layer's installed path, /usr/local/share/devhost/registry, pointed at its source
# folder) into a temp state folder and compares the resolved skills/architecture-review/SKILL.md
# with the committed .claude/skills/architecture-review/SKILL.md.
#
# The comparison is byte for byte: both layers say heading: false (component-registry 1.3.0), so
# text stacking adds no "## Layer <id>" line, and a change to either layer or to the committed skill
# that is not made in both fails here.
# Also: the devhost template copy equals the committed skill (no guard kept them identical), and the
# generic layer alone resolves to a usable skill that names nothing of this repository.
# Part of `task lint` (`task test:registry-first-use`).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
src="$root/src/component-registry"
skill="$root/.claude/skills/architecture-review/SKILL.md"
template="$root/local-features/devhost/share/python/templates/claude/skills/architecture-review/SKILL.md"
base_src="$root/local-features/devhost/share/registry"
installed=/usr/local/share/devhost/registry

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found)" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

bin="$T/bin"; mkdir -p "$bin"
for f in dcf-registry registry-source-path; do cp "$src/$f.sh" "$bin/$f"; chmod +x "$bin/$f"; done
mkdir -p "$T/share"; cp -R "$src/base" "$T/share/base"
export PATH="$bin:$PATH" COMPONENT_REGISTRY_SHARE_DIR="$T/share"
unset COMPONENT_REGISTRY_WHOAMI COMPONENT_REGISTRY_FILE COMPONENT_REGISTRY_WHOAMI_TASK_VAR COMPONENT_REGISTRY_FILE_TASK_VAR

# A repository in the temp folder with the real layer list and this repository's real layer; only
# the devhost layer's installed path is pointed at its source folder (the container is not rebuilt).
repo="$T/repo"; mkdir -p "$repo/.devcontainer/registry"
cp -R "$root/.devcontainer/registry/repo" "$repo/.devcontainer/registry/repo"
contains "the layer list names the devhost layer at its installed path" "$(cat "$root/.devcontainer/registry.yml")" "path: $installed"
sed "s#path: $installed\$#path: $base_src#" "$root/.devcontainer/registry.yml" > "$repo/.devcontainer/registry.yml"
cd "$repo" || exit 1

export COMPONENT_REGISTRY_STATE_DIR="$T/state"
out="$(dcf-registry resolve --as /devcontainer-features/operator 2>&1)"; rc=$?
check "resolve on the real layer list succeeds" 0 "$rc"
contains "resolve reports no skipped or unreadable line" "$out" "(0 line(s) skipped, 0 unreadable;"
resolved="$T/state/view/skills/architecture-review/SKILL.md"
check "the resolved skill is there" yes "$([ -f "$resolved" ] && echo yes || echo no)"

check "no layer heading is written (heading: false on both layers)" 0 "$(grep -c '^## Layer ' "$resolved")"
if cmp -s "$resolved" "$skill"; then same=yes; else same=no; diff -u "$skill" "$resolved" | head -40; fi
check "the resolved skill equals the committed skill byte for byte" yes "$same"
if cmp -s "$template" "$skill"; then tsame=yes; else tsame=no; fi
check "the devhost template copy equals the committed skill" yes "$tsame"

# The generic layer alone: a skill a consumer without this repository's rules can use.
mkdir -p "$T/alone/.devcontainer"; cd "$T/alone" || exit 1
printf 'layers:\n  - id: devhost\n    at: /\n    sources:\n      - { kind: path, path: "%s" }\n' "$base_src" > .devcontainer/registry.yml
export COMPONENT_REGISTRY_STATE_DIR="$T/state-alone"
dcf-registry resolve --as /someone >/dev/null 2>&1; rc=$?
check "the generic layer alone resolves" 0 "$rc"
alone="$(cat "$T/state-alone/view/skills/architecture-review/SKILL.md" 2>/dev/null)"
contains "alone: the front matter names the skill" "$(printf '%s\n' "$alone" | sed -n 2p)" "name: architecture-review"
contains "alone: the front matter describes it" "$(printf '%s\n' "$alone" | sed -n 3p)" "description: Review a proposal"
for w in NFR-12 NFR-13 agents-v2 non-functional-requirements.md "CLI adapter" "## In this repository"; do
  lacks "alone: names nothing of this repository ($w)" "$alone" "$w"
done

echo "first use: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
