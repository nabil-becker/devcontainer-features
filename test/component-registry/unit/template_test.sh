#!/usr/bin/env bash
# Docker-free tests of vendor templates (component-registry 1.11.0, ADR-0077): each vendor's files
# rendered from the resolved view by minijinja-cli (the pinned version, need_minijinja), the merge
# unchanged. The built-in base template reproduces the view's skills byte for byte (front matter,
# none, heading: false, a namespaced skill, a skill's files, a SKILL.md from files, tabs, quotes,
# backslashes, CR, UTF-8), and a hand-over through it gives Claude Code exactly the files the
# 1.10.0 hand-over gave (the real agent-adapter-claude, split and shared, in temp config folders);
# a layer replacing a template whole, extending one block of it, adding its own (for: skill and
# for: once, an empty output not written); a lock in a lower layer holding; a namespaced layer's
# template never replacing the Operator's, writing only in its namespace's skill folders; a layer
# at another path not applying; explain naming the winner and the base it extends; a bad head
# skipped and reported (the template below wins), a template that does not render, a bad output
# path, an undefined name (strict), two templates for one file: the hand-over fails with the layer
# and file named and the CLI keeps its files; minijinja-cli missing: a clear line, files kept, and
# a CLI without templates still handed the view as before; dcf-registry render. Every Claude
# config folder is a temp one. Part of `task lint` (`task test:component-registry-unit`).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
src="$root/src/component-registry"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

# shellcheck source=test/component-registry/unit/minijinja.sh
. "$here/minijinja.sh"
bin="$T/bin" mjbin="$T/mjbin"
mkdir -p "$bin"
if ! need_minijinja "$mjbin"; then
  if [ -n "${CI:-}" ]; then echo "FAIL - minijinja-cli is needed in CI"; exit 1; fi
  echo "skip - no minijinja-cli (offline?); the template tests need it"; exit 0
fi
for f in dcf-registry registry-source-path; do cp "$src/$f.sh" "$bin/$f"; chmod +x "$bin/$f"; done
cp "$root/src/claude-code/agent-adapter-claude.sh" "$bin/agent-adapter-claude"; chmod +x "$bin/agent-adapter-claude"
cp "$root/src/copilot/agent-adapter-copilot.sh" "$bin/agent-adapter-copilot"; chmod +x "$bin/agent-adapter-copilot"
# a claude that must never run for the skills verb
printf '#!/bin/sh\necho "claude $*" >> "%s/claude-calls"\nexit 1\n' "$T" > "$bin/claude"; chmod +x "$bin/claude"
# a CLI without templates, which takes skills
# shellcheck disable=SC2016  # the fake adapter expands it when it runs
printf '#!/usr/bin/env bash\n[ "$1" = supports ] && { echo skills; exit 0; }\n[ "$1" = skills ] && { echo "took $COMPONENT_REGISTRY_SKILLS"; exit 0; }\nexit 3\n' > "$bin/agent-adapter-plain"
chmod +x "$bin/agent-adapter-plain"
mkdir -p "$T/share"; cp -R "$src/base" "$T/share/base"; echo 1.11.0 > "$T/share/version"
BASEPATH="$bin:/usr/bin:/bin"
export PATH="$mjbin:$BASEPATH" COMPONENT_REGISTRY_SHARE_DIR="$T/share"
export CLAUDE_CONFIG_DIR="$T/claude-config-never"
unset COMPONENT_REGISTRY_WHOAMI COMPONENT_REGISTRY_FILE COMPONENT_REGISTRY_WHOAMI_TASK_VAR COMPONENT_REGISTRY_FILE_TASK_VAR COMPONENT_REGISTRY_SKILLS_MODE
W=/Corp/me

new_case() {
  C="$T/case-$1"; mkdir -p "$C/repo/.devcontainer" "$C/layers"
  export COMPONENT_REGISTRY_STATE_DIR="$C/state"
  cd "$C/repo" || exit 1
}
layer() { mkdir -p "$C/layers/$1"; printf '%s' "$C/layers/$1"; }
# list <id:at[:ns]>...: path sources at $C/layers/<id>
list() {
  local spec id at ns
  echo "layers:" > .devcontainer/registry.yml
  for spec in "$@"; do
    IFS=: read -r id at ns <<< "$spec"
    printf '  - id: %s\n    at: %s\n' "$id" "$at" >> .devcontainer/registry.yml
    [ -z "$ns" ] || printf '    namespace: %s\n' "$ns" >> .devcontainer/registry.yml
    [ "$id" = corp ] || printf '    heading: false\n' >> .devcontainer/registry.yml
    printf '    sources:\n      - { kind: path, path: "%s" }\n' "$C/layers/$id" >> .devcontainer/registry.yml
  done
}
V() { printf '%s' "$COMPONENT_REGISTRY_STATE_DIR/view"; }
tpl() { mkdir -p "$1/templates/claude"; cat > "$1/templates/claude/$2"; }

# ------------------------------------------------------------ the base, byte for byte ----
new_case base
a="$(layer corp)"; b="$(layer bare)"; n="$(layer acme)"
mkdir -p "$a/fm" "$a/kit/sub" "$a/fromfiles"
printf -- '---\nname: fm\ndescription: "Quotes \\"q\\", a\ttab"\nallowed-tools: Read\n---\n# FM\n\nÉté, ünïcode; a back\\slash, a "quote", a\ttab, a CR\r\nand the end\n' > "$a/fm/SKILL.md"
echo 'kit file' > "$a/kit/notes.md"; echo 'nested' > "$a/kit/sub/deep.txt"
printf -- '---\nname: fromfiles\n---\nFrom files, no body.\n' > "$a/fromfiles/SKILL.md"
cat > "$a/corp.layer" <<'EOF'
[skills/fm]
body:text = @file fm/SKILL.md
description:value = Resolved description
tags:list = a, b, c
[skills/plain]
body:text = Plain text, no front matter.
[skills/kit]
body:text = The kit.
files:value = @dir kit
[skills/fromfiles]
files:value = @dir fromfiles
[skills/stacked]
body:text = corp says
EOF
printf '[skills/stacked]\nbody:text = bare says\n[skills/fm]\nbody:text = bare adds\n' > "$b/b.layer"
printf '[skills/tool]\nbody:text = an acme tool\n' > "$n/n.layer"
list corp:/Corp bare:/Corp acme:/:acme
out="$(dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check "base: resolve exit 0" 0 "$rc"
check "base: the base templates are components of the view (claude, and copilot from 2.1.0)" "$(printf 'used\ttemplates/claude/SKILL.md.j2\t-\tclaude\tSKILL.md.j2\tcomponent-registry\nused\ttemplates/copilot/SKILL.md.j2\t-\tcopilot\tSKILL.md.j2\tcomponent-registry')" "$(awk -F'\t' 'NR > 1 { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 }' "$(V)/meta/templates.tsv")"
out="$(dcf-registry render claude "$C/r1" 2>&1)"; rc=$?
check "render: exit 0" 0 "$rc"
contains "render: says what it rendered" "$out" "claude: 8 file(s) rendered from 1 template(s) into $C/r1, for $W"
d="$(diff -r "$(V)/skills" "$C/r1/skills" 2>&1)"
check "base: the rendered skills equal the view's byte for byte" "" "$d"
check "base: a CR survives the round trip" 1 "$(grep -c $'\r' "$C/r1/skills/fm/SKILL.md")"
check "base: a namespaced skill rendered by its folder name" yes "$([ -f "$C/r1/skills/acme--tool/SKILL.md" ] && echo yes || echo no)"
check "base: a skill's files kept" "nested" "$(cat "$C/r1/skills/kit/sub/deep.txt")"
out="$(dcf-registry render claude "$C/r1" 2>&1)"; rc=$?
check "render into a folder that is not empty: exit 2" 2 "$rc"
out="$(dcf-registry render plain "$C/r2" 2>&1)"; rc=$?
check "render a vendor with no template: exit 3" 3 "$rc"
contains "render a vendor with no template: says the view goes as it is" "$out" "the view's skills as they are"

# The hand-over through the template against the 1.10.0 hand-over (the view's skills straight to
# the adapter), with the real adapter, in two temp Claude config folders: the same files.
mkdir -p "$C/agentdir"
for mode in split shared; do
  rm -rf "$C/cfg-old" "$C/cfg-new"
  (CLAUDE_CONFIG_DIR="$C/cfg-old" COMPONENT_REGISTRY_SKILLS="$(readlink -f "$(V)")/skills" COMPONENT_REGISTRY_PATH="$W" COMPONENT_REGISTRY_SKILLS_MODE="$mode" agent-adapter-claude skills host "$C/agentdir" >/dev/null 2>&1)
  out="$(CLAUDE_CONFIG_DIR="$C/cfg-new" dcf-registry handover claude host "$C/agentdir" --as "$W" --skills-mode "$mode" 2>&1)"; rc=$?
  check "handover ($mode): exit 0" 0 "$rc"
  contains "handover ($mode): says the files were rendered" "$out" "claude: 8 file(s) rendered from 1 template(s)"
  d="$(diff -r "$C/cfg-old" "$C/cfg-new" 2>&1)"
  check "handover ($mode): Claude Code gets the same files as the 1.10.0 hand-over, byte for byte" "" "$d"
done
# Copilot (component-registry 2.1.0): its base template gives the view's skills byte for byte, and a
# hand-over through it gives Copilot CLI's folders exactly what the view's skills handed straight
# to its adapter give, in temp COPILOT_HOMEs.
out="$(dcf-registry render copilot "$C/rc" 2>&1)"; rc=$?
check "copilot: render exit 0" 0 "$rc"
check "copilot: the rendered skills equal the view's byte for byte" "" "$(diff -r "$(V)/skills" "$C/rc/skills" 2>&1)"
for mode in split shared; do
  rm -rf "$C/ch-old" "$C/ch-new"
  (COPILOT_HOME="$C/ch-old" COMPONENT_REGISTRY_SKILLS="$(readlink -f "$(V)")/skills" COMPONENT_REGISTRY_PATH="$W" COMPONENT_REGISTRY_SKILLS_MODE="$mode" agent-adapter-copilot skills host "$C/agentdir" >/dev/null 2>&1)
  out="$(COPILOT_HOME="$C/ch-new" dcf-registry handover copilot host "$C/agentdir" --as "$W" --skills-mode "$mode" 2>&1)"; rc=$?
  check "copilot handover ($mode): exit 0" 0 "$rc"
  contains "copilot handover ($mode): rendered" "$out" "copilot: 8 file(s) rendered from 1 template(s)"
  check "copilot handover ($mode): the same files as the view's skills give, byte for byte" "" "$(diff -r "$C/ch-old" "$C/ch-new" 2>&1)"
done
check "copilot handover: the skills reach Copilot's personal folder" "$(cat "$(V)/skills/fm/SKILL.md")" "$(cat "$C/ch-new/skills/fm/SKILL.md")"
check "handover: no render folder is left in the state folder" "" "$(ls -A "$COMPONENT_REGISTRY_STATE_DIR/renders" 2>/dev/null)"
check "handover: claude itself never ran" "" "$(cat "$T/claude-calls" 2>/dev/null)"
out="$(dcf-registry handover plain host "$C/agentdir" --as "$W" 2>&1)"
contains "handover: a CLI with no template gets the view's skills as before" "$out" "took $(readlink -f "$(V)")/skills"

# ------------------------------------------------------- replace, extend, add, lock ----
new_case override
m="$(layer mine)"
printf '[skills/one]\nbody:text = one body\n[skills/two]\nbody:text = two body\n' > "$m/m.layer"
list mine:/Corp
tpl "$m" SKILL.md.j2 <<'EOF'
{#- for: skill
    output: skills/{{ skill.dir }}/SKILL.md -#}
REPLACED {{ skill.name }}: {{ skill.body }}
EOF
dcf-registry resolve --as "$W" >/dev/null 2>&1
dcf-registry render claude "$C/r" >/dev/null 2>&1
check "replace: the layer's template wins whole" "REPLACED one: one body" "$(cat "$C/r/skills/one/SKILL.md")"
ex="$(dcf-registry explain templates/claude/SKILL.md.j2 2>&1)"
contains "replace: explain names the winner" "$ex" "Winner: mine (1:templates/claude/SKILL.md.j2); extends nothing"
contains "replace: explain says the base was replaced whole" "$ex" "overridden   component-registry@1.11.0 1:templates/claude/SKILL.md.j2"
contains "replace: and by whom" "$ex" "(replaced whole by mine at 1:templates/claude/SKILL.md.j2)"

tpl "$m" SKILL.md.j2 <<'EOF'
{#- for: skill
    output: skills/{{ skill.dir }}/SKILL.md -#}
{% extends "component-registry/SKILL.md.j2" %}
{% block body %}{{ super() }}
Our ADRs live in docs/adr/.
{% endblock %}
EOF
dcf-registry resolve --as "$W" >/dev/null 2>&1
rm -rf "$C/r"; dcf-registry render claude "$C/r" >/dev/null 2>&1
check "extend: one block changed, the rest the base's" "$(printf 'one body\n\nOur ADRs live in docs/adr/.\n')" "$(cat "$C/r/skills/one/SKILL.md")"
ex="$(dcf-registry explain templates/claude/SKILL.md.j2 2>&1)"
contains "extend: explain names the base it extends" "$ex" "Winner: mine (1:templates/claude/SKILL.md.j2); extends component-registry/SKILL.md.j2, the template of layer component-registry"
contains "extend: explain marks the base as extended" "$ex" "(extended by mine at 1:templates/claude/SKILL.md.j2"

rm "$m/templates/claude/SKILL.md.j2"
tpl "$m" checklist.md.j2 <<'EOF'
{#- for: skill
    output: skills/{{ skill.dir }}/checklist.md -#}
{% if skill.dir == "one" %}Checklist of {{ skill.name }}: {{ skill.values.body | length > 0 }}
{% endif %}
EOF
tpl "$m" index.md.j2 <<'EOF'
{#- for: once
    output: index.md -#}
{% for s in skills %}{{ s.dir }}
{% endfor %}
EOF
dcf-registry resolve --as "$W" >/dev/null 2>&1
rm -rf "$C/r"; out="$(dcf-registry render claude "$C/r" 2>&1)"
check "add: a template of the layer's own writes its file" "Checklist of one: True" "$(cat "$C/r/skills/one/checklist.md" 2>/dev/null)"
check "add: an output that renders empty is not written" no "$([ -e "$C/r/skills/two/checklist.md" ] && echo yes || echo no)"
check "add: the base's SKILL.md still rendered" "$(cat "$(V)/skills/two/SKILL.md")" "$(cat "$C/r/skills/two/SKILL.md")"
check "add: for: once renders one file with the skills list" "$(printf 'one\nregistry-explain\nregistry-refresh\ntwo')" "$(cat "$C/r/index.md")"
contains "add: explain templates lists every winner" "$(dcf-registry explain templates 2>&1)" "templates/claude/checklist.md.j2  mine (1:templates/claude/checklist.md.j2)  for: skill"
mkdir -p "$C/agentdir"
CLAUDE_CONFIG_DIR="$C/cfg" dcf-registry handover claude host "$C/agentdir" --as "$W" --skills-mode shared >/dev/null 2>&1
check "add: the added file reaches Claude Code" "Checklist of one: True" "$(cat "$C/cfg/skills/one/checklist.md" 2>/dev/null)"

new_case lock
d="$(layer dept)"; m="$(layer mine)"
printf '[skills/one]\nbody:text = one body\n' > "$d/d.layer"; : > "$m/m.layer"
tpl "$d" SKILL.md.j2 <<'EOF'
{#- for: skill
    output: skills/{{ skill.dir }}/SKILL.md
    lock: true -#}
DEPT {{ skill.body }}
EOF
tpl "$m" SKILL.md.j2 <<'EOF'
{#- for: skill
    output: skills/{{ skill.dir }}/SKILL.md -#}
MINE
EOF
list dept:/Corp mine:/Corp
out="$(dcf-registry resolve --as "$W" 2>&1)"
contains "lock: resolve reports the higher layer's template skipped" "$out" "skipped template mine 1:templates/claude/SKILL.md.j2 templates/claude/SKILL.md.j2: locked by dept at 1:templates/claude/SKILL.md.j2"
rm -rf "$C/r"; dcf-registry render claude "$C/r" >/dev/null 2>&1
check "lock: the lower layer's template holds" "DEPT one body" "$(cat "$C/r/skills/one/SKILL.md")"
contains "lock: explain says it is locked" "$(dcf-registry explain templates/claude/SKILL.md.j2 2>&1)" "Winner: dept (1:templates/claude/SKILL.md.j2), locked for every higher layer"

# ------------------------------------------------------------------ namespaces, at ----
new_case ns
o="$(layer own)"; n="$(layer acme)"; x="$(layer elsewhere)"
printf '[skills/mine]\nbody:text = my skill\n' > "$o/o.layer"
printf '[skills/tool]\nbody:text = the acme tool\n' > "$n/n.layer"
tpl "$n" SKILL.md.j2 <<'EOF'
{#- for: skill
    output: skills/{{ skill.dir }}/SKILL.md -#}
ACME OWNS {{ skill.dir }}
EOF
tpl "$n" extra.md.j2 <<'EOF'
{#- for: skill
    output: skills/{{ skill.dir }}/extra.md -#}
extra for {{ skill.name }}
EOF
tpl "$n" sneak.md.j2 <<'EOF'
{#- for: once
    output: skills/mine/sneak.md -#}
sneaked
EOF
: > "$x/x.layer"
tpl "$x" SKILL.md.j2 <<'EOF'
{#- for: skill
    output: skills/{{ skill.dir }}/SKILL.md -#}
ELSEWHERE
EOF
list own:/Corp acme:/:acme elsewhere:/Finance
dcf-registry resolve --as "$W" >/dev/null 2>&1
check "namespace: its template is its own component" yes "$(grep -qP '^used\ttemplates/claude/acme:SKILL.md.j2\tacme' "$(V)/meta/templates.tsv" && echo yes || echo no)"
rm -rf "$C/r"; out="$(dcf-registry render claude "$C/r" 2>&1)"; rc=$?
check "namespace: render exit 0" 0 "$rc"
check "namespace: the Operator's skill keeps the base template" "$(cat "$(V)/skills/mine/SKILL.md")" "$(cat "$C/r/skills/mine/SKILL.md")"
check "namespace: even its own skill's SKILL.md stays the Operator's template's" "$(cat "$(V)/skills/acme--tool/SKILL.md")" "$(cat "$C/r/skills/acme--tool/SKILL.md")"
contains "namespace: a namespace never replaces the Operator's file, said" "$out" "is written by templates/claude/SKILL.md.j2 of layer component-registry, which a namespace never replaces"
check "namespace: it adds a file to its own skills" "extra for acme:tool" "$(cat "$C/r/skills/acme--tool/extra.md" 2>/dev/null)"
check "namespace: nothing for the Operator's skills" no "$([ -e "$C/r/skills/mine/extra.md" ] && echo yes || echo no)"
check "namespace: never inside the Operator's skill folders" no "$([ -e "$C/r/skills/mine/sneak.md" ] && echo yes || echo no)"
contains "namespace: the refused path is said" "$out" "writes only inside its namespace's skill folders (skills/acme--<name>/); skills/mine/sneak.md not written"
check "at: a layer at another path does not apply" "not-applying" "$(awk -F'\t' '$6 == "elsewhere" { print $1 }' "$(V)/meta/templates.tsv")"
ex="$(dcf-registry explain templates/claude/acme:SKILL.md.j2 2>&1)"
contains "namespace: explain names the namespace" "$ex" "Namespace acme: only the layers with namespace: acme reach it"

# ------------------------------------------------------- bad templates, no minijinja ----
new_case bad
m="$(layer mine)"
printf '[skills/one]\nbody:text = one body\n' > "$m/m.layer"
list mine:/Corp
mkdir -p "$C/agentdir"
dcf-registry resolve --as "$W" >/dev/null 2>&1
CLAUDE_CONFIG_DIR="$C/cfg" dcf-registry handover claude host "$C/agentdir" --as "$W" --skills-mode shared >/dev/null 2>&1
good="$(cat "$C/cfg/skills/one/SKILL.md")"
check "bad: a first hand-over through the base" "one body" "$good"

printf '{#- output: x -#}\nno for\n' | tpl "$m" SKILL.md.j2
out="$(dcf-registry resolve --as "$W" 2>&1)"
contains "bad head: skipped and reported with its layer and file" "$out" "skipped template mine 1:templates/claude/SKILL.md.j2 templates/claude/SKILL.md.j2: the head has no for: (skill or once)"
contains "bad head: counted in the skipped lines" "$out" "(1 line(s) skipped"
check "bad head: the template below wins" component-registry "$(awk -F'\t' '$1 == "used" && $4 == "claude" { print $6 }' "$(V)/meta/templates.tsv")"
printf 'no head at all\n' | tpl "$m" SKILL.md.j2
contains "no head: reported" "$(dcf-registry resolve --as "$W" 2>&1)" "no head: a template starts with {#- for: skill  output: <path> -#}"
printf '{#- for: agent\n output: x -#}\n' | tpl "$m" SKILL.md.j2
contains "for: agent: not supported, said" "$(dcf-registry resolve --as "$W" 2>&1)" "for: agent is not supported"

printf '[skills/one]\nbody:text = one body, changed\n' > "$m/m.layer"
printf '{#- for: skill\n    output: skills/{{ skill.dir }}/SKILL.md -#}\n{%% if %%}broken\n' | tpl "$m" SKILL.md.j2
dcf-registry resolve --as "$W" >/dev/null 2>&1
out="$(CLAUDE_CONFIG_DIR="$C/cfg" dcf-registry handover claude host "$C/agentdir" --as "$W" --skills-mode shared 2>&1)"; rc=$?
check "syntax error: the hand-over fails (exit 1)" 1 "$rc"
contains "syntax error: the layer and file are named" "$out" "template templates/claude/SKILL.md.j2 of layer mine (1:templates/claude/SKILL.md.j2) does not render for skill one"
contains "syntax error: says the CLI keeps its skills" "$out" "Nothing was handed over; host's CLI keeps the skills it has."
check "syntax error: Claude Code keeps the files it had" "$good" "$(cat "$C/cfg/skills/one/SKILL.md")"
check "syntax error: no render folder left" "" "$(ls -A "$COMPONENT_REGISTRY_STATE_DIR/renders" 2>/dev/null)"
out="$(dcf-registry render claude "$C/rbad" 2>&1)"; rc=$?
check "syntax error: render exit 1" 1 "$rc"

printf '{#- for: skill\n    output: skills/{{ skill.dir }}/SKILL.md -#}\n{{ skill.no_such_field }}\n' | tpl "$m" SKILL.md.j2
dcf-registry resolve --as "$W" >/dev/null 2>&1
contains "strict: an undefined name is an error" "$(dcf-registry render claude "$C/rs" 2>&1)" "undefined"
printf '{#- for: skill\n    output: ../{{ skill.dir }} -#}\nx\n' | tpl "$m" SKILL.md.j2
dcf-registry resolve --as "$W" >/dev/null 2>&1
contains "output: a path out of the folder is refused" "$(dcf-registry render claude "$C/ro" 2>&1)" "is not a relative path of letters, digits, . _ - (no . or .. segment)"
printf '{#- for: skill\n    output: skills/{{ skill.dir }}/SKILL.md -#}\nX\n' | tpl "$m" SKILL.md.j2
printf '{#- for: skill\n    output: skills/{{ skill.dir }}/SKILL.md -#}\nY\n' | tpl "$m" other.md.j2
dcf-registry resolve --as "$W" >/dev/null 2>&1
contains "two templates for one file: refused" "$(dcf-registry render claude "$C/r2" 2>&1)" "both write skills/one/SKILL.md; one file has one template"
printf '{#- for: skill\n    output: skills/{{ skill.dir }}/SKILL.md -#}\n{%% include "/etc/hostname" %%}\n' | tpl "$m" SKILL.md.j2
rm -f "$m/templates/claude/other.md.j2"
dcf-registry resolve --as "$W" >/dev/null 2>&1
contains "a file outside the templates is never read" "$(dcf-registry render claude "$C/r3" 2>&1)" "non-trusted path"
printf '{#- for: skill\n    output: skills/{{ skill.dir }}/SKILL.md -#}\n{%% extends "mine/SKILL.md.j2" %%}\n' | tpl "$m" SKILL.md.j2
dcf-registry resolve --as "$W" >/dev/null 2>&1
contains "extends: only a lower layer's template can be extended" "$(dcf-registry render claude "$C/r4" 2>&1)" "template not found"

rm -f "$m/templates/claude/SKILL.md.j2"
dcf-registry resolve --as "$W" >/dev/null 2>&1
out="$(PATH="$BASEPATH" CLAUDE_CONFIG_DIR="$C/cfg" dcf-registry handover claude host "$C/agentdir" --as "$W" --skills-mode shared 2>&1)"; rc=$?
check "no minijinja-cli: the hand-over fails (exit 1)" 1 "$rc"
contains "no minijinja-cli: a clear line" "$out" "minijinja-cli is not on PATH (component-registry 1.11.0 installs it; rebuild the container)"
check "no minijinja-cli: Claude Code keeps the files it had" "$good" "$(cat "$C/cfg/skills/one/SKILL.md")"
out="$(PATH="$BASEPATH" dcf-registry handover plain host "$C/agentdir" --as "$W" 2>&1)"; rc=$?
check "no minijinja-cli: a CLI with no template is still handed over" 0 "$rc"
out="$(CLAUDE_CONFIG_DIR="$C/cfg" dcf-registry handover claude host "$C/agentdir" --as "$W" --skills-mode shared 2>&1)"; rc=$?
check "minijinja-cli back: the hand-over goes through" 0 "$rc"
check "minijinja-cli back: the changed skill arrives" "one body, changed" "$(cat "$C/cfg/skills/one/SKILL.md")"

echo
echo "template tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
