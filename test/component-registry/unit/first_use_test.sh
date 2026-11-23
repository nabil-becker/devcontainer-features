#!/usr/bin/env bash
# The component registry's first real use (slice 4 of docs/proposals/component-registry.md): the
# architecture-review skill split into the devhost Feature's generic layer
# (local-features/devhost/share/registry) and this repository's layer (.devcontainer/registry/repo),
# listed in .devcontainer/registry.yml. This test runs the real dcf-registry on the real layer list
# (the devhost layer's installed path, /usr/local/share/devhost/registry, pointed at its source
# folder) into a temp state folder and compares the resolved skills/architecture-review/SKILL.md
# with the devhost template copy (templates/claude/skills/architecture-review/SKILL.md) that
# `devhost-init` plants in a repository without the registry; this repository commits no copy of its own.
#
# The comparison is byte for byte: both layers say heading: false (component-registry 1.3.0), so
# text stacking adds no "## Layer <id>" line, and a change to either layer or to the committed skill
# that is not made in the template copy too fails here (the drift guard of architecture-skill-switch-over).
# Also: the generic layer alone resolves to a usable skill that names nothing of this repository.
# Part of `task lint` (`task test:registry-first-use`).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
src="$root/src/component-registry"
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

# The shape of the resolved skill (this repository commits no copy; the registry is the only source).
check "no layer heading is written (heading: false on both layers: the repo layer has its own heading)" 0 "$(grep -c '^## Layer ' "$resolved")"
check "front matter opens and closes" "---/---" "$(sed -n 1p "$resolved")/$(sed -n 4,12p "$resolved" | grep -m1 '^---$')"
contains "front matter has a name" "$(sed -n 2p "$resolved")" "name: architecture-review"
contains "front matter has a description" "$(sed -n 3p "$resolved")" "description: "
check "the devhost layer's method comes first" "$(sed -n '/^# /,$p' "$base_src/architecture-review/SKILL.md" | head -1)" "$(sed -n '/^# /p' "$resolved" | head -1)"
check "exactly one '## In this repository' section" 1 "$(grep -c '^## In this repository$' "$resolved")"
method_end="$(grep -n '^## In this repository$' "$resolved" | cut -d: -f1)"
check "the method text precedes the repository section" "$(grep -c '^## Steps$' "$base_src/architecture-review/SKILL.md")" "$(head -n "$method_end" "$resolved" | grep -c '^## Steps$')"
expl="$(dcf-registry explain skills/architecture-review --color never 2>&1)"
contains "explain attributes lines to the devhost layer" "$expl" "devhost@"
contains "explain attributes lines to this repository's layer" "$expl" "devcontainer-features@"
# Drift guard: the template devhost-init plants where there is no registry equals what resolves here.
if cmp -s "$resolved" "$template"; then same=yes; else same=no; diff -u "$template" "$resolved" | head -40; fi
check "the resolved skill equals the devhost template copy byte for byte" yes "$same"
check "this repository commits no copy of the skill (the registry resolves it)" no "$([ -e "$root/.claude/skills/architecture-review" ] && echo yes || echo no)"
# The real layer list through the base Claude template (component-registry 1.11.0, ADR-0077): what a
# hand-over gives Claude Code equals the resolved view byte for byte.
# shellcheck source=test/component-registry/unit/minijinja.sh
. "$here/minijinja.sh"
if need_minijinja "$T/mjbin"; then
  PATH="$T/mjbin:$PATH" dcf-registry render claude "$T/rendered" >/dev/null 2>&1
  check "the base Claude template renders the real layer list's skills byte for byte" "" "$(diff -r "$T/state/view/skills" "$T/rendered/skills" 2>&1)"
elif [ -n "${CI:-}" ]; then
  check "minijinja-cli is available in CI" yes no
else
  echo "skip - no minijinja-cli (offline?): the render check"
fi

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
