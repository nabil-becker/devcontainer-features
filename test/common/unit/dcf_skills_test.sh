#!/usr/bin/env bash
# Docker-free test of the shared skills hand-over src/common/dcf-skills.sh (skills-shared-helper):
# sourced alone with a third, made-up vendor's settings (SK_CLI, SK_OWN, sk_home and the hooks), it
# splits two agents' views into the shared personal folder and each agent's own folder, marks its
# copies, never touches an unmarked one, calls the vendor's clash and reload hooks, and handles
# shared, off and forget; sk_add_dir adds --add-dir once and never twice; skills_show reports both
# folders. Also: each adapter carries the helper verbatim between its markers, once. The adapters'
# own suites cover each vendor's words (test:claude-unit, test:copilot-unit). Part of lint
# (`task test:common-unit`). Every folder is a temp one.
# shellcheck disable=SC2329,SC2031,SC1090  # the hooks are called by the sourced helper; each call runs in its own subshell on purpose
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
helper="$root/src/common/dcf-skills.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }

for a in src/claude-code/agent-adapter-claude.sh src/copilot/agent-adapter-copilot.sh; do
  check "$a carries the begin marker once" 1 "$(grep -c -F '# >>> dcf-skills.sh' "$root/$a")"
  awk -v b="# >>> dcf-skills.sh" -v e="# <<< dcf-skills.sh <<<" 'index($0, e) == 1 { p = 0 } p { print } index($0, b) == 1 { p = 1 }' "$root/$a" > "$T/emb"
  check "$a carries the helper verbatim" yes "$(cmp -s "$helper" "$T/emb" && echo yes || echo no)"
done

# one vendor-neutral run, in a subshell per call so die() ends only that call
run() { # run <mode> <name> <folder> <view> [forget]
  (
    die() { local rc="$1"; shift; echo "die: $*"; exit "$rc"; }
    note() { echo "note: $*"; }
    SK_CLI=demo SK_OWN=.demo/skills
    sk_home() { printf '%s' "$T/home"; }
    sk_reload_note() { echo "demo: reload (new=${1:-no}) $2"; }
    sk_handover_clash() { [ -d "$2/$1" ] && echo "demo: clash personal $1"; [ -d "$FOLDER/.demo/skills/$1" ] && echo "demo: clash project $1"; return 0; }
    sk_start_clash() { note "start clash $1"; }
    # shellcheck source=src/common/dcf-skills.sh
    . "$helper"
    NAME="$2" FOLDER="$3"
    if [ -n "${5:-}" ]; then COMPONENT_REGISTRY_FORGET=1 skills_handover
    else COMPONENT_REGISTRY_SKILLS="$4" COMPONENT_REGISTRY_SKILLS_MODE="$1" skills_handover; fi
  ) 2>&1
}
mkdir -p "$T/va/x" "$T/va/y" "$T/vb/x" "$T/vb/z" "$T/f1" "$T/f2/.demo/skills/z"
echo x > "$T/va/x/SKILL.md"; echo x > "$T/vb/x/SKILL.md"; echo y > "$T/va/y/SKILL.md"; echo z > "$T/vb/z/SKILL.md"
out="$(run split a "$T/f1" "$T/va")"
contains "first hand-over: the reload hook says the folder is new" "$out" "demo: reload (new=1) $T/home/skills"
check "one agent: its whole view personal" y "$(cat "$T/home/skills/y/SKILL.md")"
check "a copy is marked owned" yes "$([ -f "$T/home/skills/y/.component-registry" ] && echo yes || echo no)"
mkdir -p "$T/home/skills/mine"; echo own > "$T/home/skills/mine/SKILL.md"
out="$(run split b "$T/f2" "$T/vb")"
check "two views: what both have alike stays personal" x "$(cat "$T/home/skills/x/SKILL.md")"
check "two views: what they disagree on leaves the personal folder" no "$([ -e "$T/home/skills/y" ] && echo yes || echo no)"
own="$(ls -d "$T"/home/registry-agents/b.*/registry)"
check "b's own skill in its own folder (SK_OWN)" z "$(cat "$own/.demo/skills/z/SKILL.md")"
contains "the vendor's handover clash hook is called" "$out" "demo: clash project z"
contains "the lines start with SK_CLI" "$out" "demo: 1 resolved skill(s) in $T/home/skills"
check "an unmarked skill is never touched" own "$(cat "$T/home/skills/mine/SKILL.md")"
show="$( ( SK_OWN=.demo/skills; sk_home() { printf '%s' "$T/home"; }; . "$helper"; NAME=b FOLDER="$T/f2"; skills_show ) )"
contains "skills_show: own folder and skills" "$show" "own-skills	z"
contains "skills_show: shared" "$show" "shared-skills	x"
args="$( ( note() { echo "note: $*"; }; sk_start_clash() { note "start clash $1"; }; SK_OWN=.demo/skills; sk_home() { printf '%s' "$T/home"; }; . "$helper"; NAME=b FOLDER="$T/f2"
  sk_add_dir --add-dir /o; printf '%s ' "${SK_ARGS[@]}"; echo; sk_start_line
  sk_add_dir --add-dir "$ADD_DIR"; printf '%s ' "${SK_ARGS[@]}"; echo "has=$SK_HAS" ) 2>&1)"
contains "sk_add_dir: its own folder added last" "$args" "--add-dir /o --add-dir $own "
contains "sk_start_line: the start line" "$args" "note: b: registry skills: 1 shared, 1 own -> --add-dir $own"
contains "sk_start_line: the start clash hook" "$args" "note: start clash z"
contains "sk_add_dir: never twice" "$args" "--add-dir $own has=1"
out="$(run shared a "$T/f1" "$T/va")"
check "shared: no own folder" 0 "$(find "$T/home/registry-agents" -maxdepth 1 -name 'a.*' | wc -l)"
out="$(run off b "$T/f2" "$T/vb")"
check "off: the agent's own folder dropped" 0 "$(find "$T/home/registry-agents" -maxdepth 1 -name 'b.*' | wc -l)"
out="$(run split b "$T/f2" "$T/vb" forget)"
contains "forget with nothing left: said" "$out" "demo: b has no registry skills of its own here; nothing to remove."
out="$(run bogus b "$T/f2" "$T/vb")"
contains "a bad mode: refused" "$out" "die: skills: COMPONENT_REGISTRY_SKILLS_MODE is 'bogus'"

echo "dcf-skills: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
