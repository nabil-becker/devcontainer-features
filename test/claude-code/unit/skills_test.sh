#!/usr/bin/env bash
# Docker-free tests of agent-adapter-claude's `skills` verb (claude-code 1.12.0, ADR-0064): the
# component registry's resolved skills (COMPONENT_REGISTRY_SKILLS) copied into Claude Code's
# personal skills folder ($CLAUDE_CONFIG_DIR/skills), each copy marked owned by the registry
# (.component-registry); supports lists it; the folder created even when there is nothing to copy
# (and said new, for /reload-skills); an unchanged skill not rewritten (idempotent); a changed one
# replaced; an owned copy no longer resolved removed; a skill folder without the marker never
# touched (a name clash said, the registry's copy not installed); never the repository's
# .claude/skills; owner-only copies; bad use without COMPONENT_REGISTRY_SKILLS. No claude runs:
# the verb never calls the CLI. Part of `task lint` (`task test:claude-unit`).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
adapter="$root/src/claude-code/agent-adapter-claude.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }

mkdir -p "$T/bin" "$T/view/skills" "$T/repo/.claude/skills/review" "$T/cfg"
# a claude that must never run for this verb
printf '#!/bin/sh\necho "claude $*" >> "%s/claude-calls"\nexit 1\n' "$T" > "$T/bin/claude"; chmod +x "$T/bin/claude"
echo 'the repository skill' > "$T/repo/.claude/skills/review/SKILL.md"
skill() { mkdir -p "$T/view/skills/$1"; printf '%s\n' "$2" > "$T/view/skills/$1/SKILL.md"; }
run() { (cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$T/cfg" COMPONENT_REGISTRY_SKILLS="$T/view/skills" bash "$adapter" skills host "$T/repo" 2>&1); }
S="$T/cfg/skills"

contains 'supports lists skills' "$(PATH="$T/bin:/usr/bin:/bin" bash "$adapter" supports)" 'skills'

out="$(PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$T/cfg" bash "$adapter" skills host "$T/repo" 2>&1)"; rc=$?
check 'no COMPONENT_REGISTRY_SKILLS: bad use (exit 2)' 2 "$rc"
contains 'no COMPONENT_REGISTRY_SKILLS: says what is needed' "$out" 'COMPONENT_REGISTRY_SKILLS'
check 'no COMPONENT_REGISTRY_SKILLS: nothing created' no "$([ -e "$S" ] && echo yes || echo no)"

# an empty resolved view: the folder is still made, and said to be new
out="$(run)"; rc=$?
check 'empty view: exit 0' 0 "$rc"
check 'empty view: the skills folder is created' yes "$([ -d "$S" ] && echo yes || echo no)"
contains 'empty view: a new folder is said (for /reload-skills)' "$out" '/reload-skills'
check 'the skills folder is owner-only' 700 "$(stat -c %a "$S")"

skill diagrams 'Use C4.'
mkdir -p "$T/view/skills/diagrams/ref"; echo 'a reference' > "$T/view/skills/diagrams/ref/notes.md"
skill review 'the registry review'
mkdir -p "$S/mine"; echo 'my own skill' > "$S/mine/SKILL.md"
out="$(run)"; rc=$?
check 'copy: exit 0' 0 "$rc"
check 'copy: SKILL.md copied' 'Use C4.' "$(cat "$S/diagrams/SKILL.md" 2>/dev/null)"
check 'copy: a nested file copied' 'a reference' "$(cat "$S/diagrams/ref/notes.md" 2>/dev/null)"
check 'copy: marked owned by the registry' yes "$([ -f "$S/diagrams/.component-registry" ] && echo yes || echo no)"
check 'copy: a copy is owner-only' 700 "$(stat -c %a "$S/diagrams")"
check 'copy: never the repository .claude/skills' 'the repository skill' "$(cat "$T/repo/.claude/skills/review/SKILL.md")"
check 'copy: the repository has no registry copy' no "$([ -e "$T/repo/.claude/skills/diagrams" ] && echo yes || echo no)"
check 'copy: a skill of a project name lands in the personal folder' 'the registry review' "$(cat "$S/review/SKILL.md" 2>/dev/null)"
check 'unowned: my own skill untouched' 'my own skill' "$(cat "$S/mine/SKILL.md")"
contains 'copy: counts' "$out" '2 resolved skill(s)'
contains 'copy: live in running sessions, old text in a used conversation' "$out" 'keeps its old text until it is used in a new conversation'
check 'no claude was run' '' "$(cat "$T/claude-calls" 2>/dev/null)"

m1="$(stat -c %Y "$S/diagrams/SKILL.md")"; i1="$(stat -c %i "$S/diagrams")"
out="$(run)"
contains 'idempotent: an unchanged skill is not rewritten' "$out" '0 copied, 2 unchanged, 0 removed'
check 'idempotent: the same folder' "$i1" "$(stat -c %i "$S/diagrams")"
check 'idempotent: the same file time' "$m1" "$(stat -c %Y "$S/diagrams/SKILL.md")"

skill diagrams 'Use C4, colour-blind safe.'
out="$(run)"
contains 'a changed skill is replaced' "$out" '1 copied, 1 unchanged'
check 'a changed skill: new text' 'Use C4, colour-blind safe.' "$(cat "$S/diagrams/SKILL.md")"
check 'a changed skill: still marked' yes "$([ -f "$S/diagrams/.component-registry" ] && echo yes || echo no)"

rm -rf "$T/view/skills/review"
out="$(run)"
contains 'an owned copy no longer resolved is removed' "$out" '1 removed'
check 'removed: gone from the skills folder' no "$([ -e "$S/review" ] && echo yes || echo no)"
check 'removed: my own skill still untouched' 'my own skill' "$(cat "$S/mine/SKILL.md")"

# a name clash with a skill the registry does not own: left as it is, said
skill mine 'the registry would like this name'
out="$(run)"; rc=$?
check 'name clash: exit 0' 0 "$rc"
check 'name clash: my own skill untouched' 'my own skill' "$(cat "$S/mine/SKILL.md")"
check 'name clash: no marker put into it' no "$([ -e "$S/mine/.component-registry" ] && echo yes || echo no)"
contains 'name clash: said' "$out" 'is not the registry'"'"'s'
contains 'name clash: counted' "$out" '1 left to their owner'
rm -rf "$T/view/skills/mine"
run >/dev/null
check 'an unowned skill no longer named by the view is not removed' 'my own skill' "$(cat "$S/mine/SKILL.md" 2>/dev/null)"

# a leftover half copy from an interrupted run is cleaned up
mkdir -p "$S/.diagrams.new.999"; run >/dev/null
check 'a leftover temporary copy is removed' no "$([ -e "$S/.diagrams.new.999" ] && echo yes || echo no)"

out="$(PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$T/cfg" COMPONENT_REGISTRY_SKILLS="$T/nosuch" bash "$adapter" skills host "$T/repo" 2>&1)"; rc=$?
check 'a folder that is not there: bad use (exit 2)' 2 "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
