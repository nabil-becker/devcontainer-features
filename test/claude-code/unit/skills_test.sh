#!/usr/bin/env bash
# Docker-free tests of agent-adapter-claude's `skills` verb (claude-code 1.12.0, ADR-0064): the
# component registry's resolved skills (COMPONENT_REGISTRY_SKILLS) copied into Claude Code's
# personal skills folder ($CLAUDE_CONFIG_DIR/skills), each copy marked owned by the registry
# (.component-registry); supports lists it; the folder created even when there is nothing to copy
# (and said new, for /reload-skills); an unchanged skill not rewritten (idempotent); a changed one
# replaced; an owned copy no longer resolved removed; a skill folder without the marker never
# touched (a name clash said, the registry's copy not installed); never the repository's
# .claude/skills; owner-only copies; bad use without COMPONENT_REGISTRY_SKILLS. Per agent (1.14.0,
# ADR-0074): two agents of different paths split into personal and own folders, one path shared,
# a refresh that agrees again, a project clash said, forget, an agent whose folder is gone, two
# hand-overs at once, --add-dir on new and start-bg (once, none without a folder); the line each
# start prints, the duplicate rule, skills-show, the modes split, shared and off. No claude runs:
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
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

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

# ------------------------------------------------- per agent (claude-code 1.14.0, ADR-0074) ----
# Two agents of different registry paths: what their views share is personal, what differs goes to
# each agent's own folder (read through --add-dir); one path shared by two agents: all personal.
R="$T/pa"; mkdir -p "$R/cfg" "$R/fa" "$R/fb" "$R/fc/.claude/skills/review"
echo 'the project review' > "$R/fc/.claude/skills/review/SKILL.md"
view() { # view <name> <skill=text>...: a resolved view's skills folder
  local v="$R/view-$1" kv; shift; rm -rf "$v"; mkdir -p "$v"
  for kv in "$@"; do mkdir -p "$v/${kv%%=*}"; printf '%s\n' "${kv#*=}" > "$v/${kv%%=*}/SKILL.md"; done
}
hand() { # hand <agent> <folder> <view>
  (cd "$2" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" COMPONENT_REGISTRY_SKILLS="$R/view-$3" COMPONENT_REGISTRY_PATH="/Corp/$3" bash "$adapter" skills "$1" "$2" 2>&1)
}
PS="$R/cfg/skills"
key() { printf '%s.%s' "$1" "$(printf '%s' "$2" | cksum | cut -d' ' -f1)"; }
own() { printf '%s/cfg/registry-agents/%s/registry/.claude/skills' "$R" "$(key "$1" "$2")"; }
view x 'shared=same' 'diagrams=for x' 'xonly=x alone'
view y 'shared=same' 'diagrams=for y'
out="$(hand ana "$R/fa" x)"; rc=$?
check 'per agent: one agent, exit 0' 0 "$rc"
check 'per agent: one agent, its whole view is personal' 'for x' "$(cat "$PS/diagrams/SKILL.md" 2>/dev/null)"
check 'per agent: one agent, its own folder made and empty' 0 "$(find "$(own ana "$R/fa")" -mindepth 1 | wc -l)"
contains 'per agent: one agent, says where its own skills are read from' "$out" "--add-dir $R/cfg/registry-agents/$(key ana "$R/fa")/registry"
out="$(hand bob "$R/fb" y)"
check 'two paths: the shared skill stays personal' 'same' "$(cat "$PS/shared/SKILL.md" 2>/dev/null)"
check 'two paths: a skill they disagree on leaves the personal folder' no "$([ -e "$PS/diagrams" ] && echo yes || echo no)"
check 'two paths: a skill only one view has leaves the personal folder' no "$([ -e "$PS/xonly" ] && echo yes || echo no)"
check 'two paths: agent a gets its own diagrams' 'for x' "$(cat "$(own ana "$R/fa")/diagrams/SKILL.md" 2>/dev/null)"
check 'two paths: agent a gets its only skill' 'x alone' "$(cat "$(own ana "$R/fa")/xonly/SKILL.md" 2>/dev/null)"
check 'two paths: agent b gets its own diagrams' 'for y' "$(cat "$(own bob "$R/fb")/diagrams/SKILL.md" 2>/dev/null)"
check 'two paths: agent b never gets the other view'"'"'s skill' no "$([ -e "$(own bob "$R/fb")/xonly" ] && echo yes || echo no)"
check 'two paths: an own copy is marked owned' yes "$([ -f "$(own bob "$R/fb")/diagrams/.component-registry" ] && echo yes || echo no)"
check 'two paths: the agents folder is owner-only' 700 "$(stat -c %a "$R/cfg/registry-agents")"
check 'two paths: the shared skill is not copied to an own folder' no "$([ -e "$(own ana "$R/fa")/shared" ] && echo yes || echo no)"
out="$(hand cat "$R/fc" x)"
check 'same path: a third agent of path x gets the own copy of its path (diagrams is contested by b)' 'for x' "$(cat "$(own cat "$R/fc")/diagrams/SKILL.md" 2>/dev/null)"
check 'same path: the two x agents hold the same text' "$(cat "$(own ana "$R/fa")/diagrams/SKILL.md")" "$(cat "$(own cat "$R/fc")/diagrams/SKILL.md" 2>/dev/null)"
# a refresh: b's view changes to agree with x; diagrams becomes shared again and leaves the own folders
view y 'shared=same' 'diagrams=for x' 'xonly=x alone'
out="$(hand bob "$R/fb" y)"
check 'refresh: views agree again, the skill is personal' 'for x' "$(cat "$PS/diagrams/SKILL.md" 2>/dev/null)"
gone="$([ -e "$(own ana "$R/fa")/diagrams" ] && echo yes || echo no) $([ -e "$(own bob "$R/fb")/diagrams" ] && echo yes || echo no) $([ -e "$(own cat "$R/fc")/diagrams" ] && echo yes || echo no)"
check 'refresh: and gone from every own folder' "no no no" "$gone"
# a project skill of the same name beats an added directory's: said
view y 'shared=same' 'review=the registry review'
out="$(hand cat "$R/fc" y)"
contains 'project clash: said, with the prefixed name' "$out" "the project's $R/fc/.claude/skills/review wins in cat's sessions; the registry's runs as /registry:review"
check 'project clash: the repository skill is never touched' 'the project review' "$(cat "$R/fc/.claude/skills/review/SKILL.md")"
# cleanup: forget drops the agent's folder and the split is made again without it
out="$(cd "$R/fc" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" COMPONENT_REGISTRY_FORGET=1 bash "$adapter" skills cat "$R/fc" 2>&1)"; rc=$?
check 'forget: exit 0' 0 "$rc"
check 'forget: the agent folder is gone' no "$([ -e "$R/cfg/registry-agents/$(key cat "$R/fc")" ] && echo yes || echo no)"
check 'forget: ana and bob agree again, so everything is personal' 'x alone' "$(cat "$PS/xonly/SKILL.md" 2>/dev/null)"
check 'forget: an own folder empties' 0 "$(find "$(own bob "$R/fb")" -mindepth 1 -maxdepth 1 | wc -l)"
# an agent whose folder is gone is dropped at the next hand-over
view y 'shared=same' 'diagrams=for y'
hand bob "$R/fb" y >/dev/null
rm -rf "$R/fa"
out="$(hand bob "$R/fb" y)"
contains 'sweep: an agent whose folder is gone is said dropped' "$out" '1 agent(s) whose folder is gone'
check 'sweep: its folder is removed' no "$([ -e "$R/cfg/registry-agents/$(key ana "$R/fa")" ] && echo yes || echo no)"
check 'sweep: bob alone, its whole view personal' 'for y' "$(cat "$PS/diagrams/SKILL.md" 2>/dev/null)"
# the lock: two hand-overs at once both finish and leave a consistent split
mkdir -p "$R/fa"
view x 'shared=same' 'diagrams=for x'
hand ana "$R/fa" x >/dev/null & p1=$!; hand bob "$R/fb" y >/dev/null & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
check 'lock: two hand-overs at once, both exit 0' "0 0" "$r1 $r2"
check 'lock: the split is consistent (diagrams contested, in both own folders)' "for x|for y|no" "$(cat "$(own ana "$R/fa")/diagrams/SKILL.md" 2>/dev/null)|$(cat "$(own bob "$R/fb")/diagrams/SKILL.md" 2>/dev/null)|$([ -e "$PS/diagrams" ] && echo yes || echo no)"
# the agent's sessions get --add-dir <its folder>, last, once; an agent with no folder gets none
: > "$T/claude-calls"
(cd "$R/fa" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" bash "$adapter" new ana "$R/fa" -- --model opus >/dev/null 2>&1)
contains 'new: --add-dir the agent'"'"'s own folder, after its args' "$(cat "$T/claude-calls")" "--model opus --add-dir $R/cfg/registry-agents/$(key ana "$R/fa")/registry"
: > "$T/claude-calls"
(cd "$R/fa" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" bash "$adapter" new ana "$R/fa" -- --add-dir "$R/cfg/registry-agents/$(key ana "$R/fa")/registry" >/dev/null 2>&1)
check 'new: never twice' 1 "$(grep -o -- '--add-dir' "$T/claude-calls" | wc -l)"
: > "$T/claude-calls"
(cd "$R/fa" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" bash "$adapter" start-bg ana "$R/fa" >/dev/null 2>&1)
contains 'start-bg: --add-dir the agent'"'"'s own folder' "$(cat "$T/claude-calls")" "--bg --name ana --add-dir $R/cfg/registry-agents/$(key ana "$R/fa")/registry"
: > "$T/claude-calls"
mkdir -p "$R/fz"
(cd "$R/fz" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" bash "$adapter" new zed "$R/fz" >/dev/null 2>&1)
check 'new: an agent never handed skills gets no --add-dir' 0 "$(grep -c -- '--add-dir' "$T/claude-calls")"

# namespaced skills (component-registry 1.7.0) arrive by their folder name, <namespace>--<name>:
# split like any other skill, and the clash check uses that folder name
mkdir -p "$R/na" "$R/nb"
view nsx 'acme--review=acme for x' 'plain=same'
view nsy 'acme--review=acme for y' 'plain=same'
NC="$R/ncfg"; mkdir -p "$NC"
nhand() { (cd "$2" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$NC" COMPONENT_REGISTRY_SKILLS="$R/view-$3" bash "$adapter" skills "$1" "$2" 2>&1); }
nown() { printf '%s/registry-agents/%s/registry/.claude/skills' "$NC" "$(key "$1" "$2")"; }
nhand na "$R/na" nsx >/dev/null; nhand nb "$R/nb" nsy >/dev/null
check 'namespaced: a contested acme--review in each own folder' "acme for x|acme for y" "$(cat "$(nown na "$R/na")/acme--review/SKILL.md" 2>/dev/null)|$(cat "$(nown nb "$R/nb")/acme--review/SKILL.md" 2>/dev/null)"
check 'namespaced: not in the shared folder' no "$([ -e "$NC/skills/acme--review" ] && echo yes || echo no)"
check 'namespaced: the plain skill shared' same "$(cat "$NC/skills/plain/SKILL.md" 2>/dev/null)"
view nsy 'acme--review=acme for x' 'plain=same'
nhand nb "$R/nb" nsy >/dev/null
check 'namespaced: views agreeing again, acme--review shared' 'acme for x' "$(cat "$NC/skills/acme--review/SKILL.md" 2>/dev/null)"
view nsy 'acme--review=acme for y' 'plain=same'; nhand nb "$R/nb" nsy >/dev/null
mkdir -p "$R/na/.claude/skills/acme--review"; echo 'project copy' > "$R/na/.claude/skills/acme--review/SKILL.md"
out="$(cd "$R/na" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$NC" bash "$adapter" new na "$R/na" 2>&1)"
contains 'namespaced: a project clash named by the folder name' "$out" "the project's $R/na/.claude/skills/acme--review wins in its sessions; its own acme--review runs as /registry:acme--review."
out="$(cd "$R/na" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$NC" bash "$adapter" skills-show na "$R/na")"
check 'namespaced: skills-show lists it by its folder name' acme--review "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "own-skills" { print $2 }')"

# ------------------------------- transparency and control (claude-code 1.14.0, ADR-0074) ----
AD="$R/cfg/registry-agents/$(key ana "$R/fa")/registry"
newcall() { : > "$T/claude-calls"; (cd "$R/fa" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" bash "$adapter" "$@" 2>&1); }
out="$(newcall new ana "$R/fa")"
contains 'transparency: new says what it added' "$out" "ana: registry skills: $(find "$PS" -mindepth 2 -maxdepth 2 -name .component-registry | wc -l) shared, $(find "$AD/.claude/skills" -mindepth 2 -maxdepth 2 -name .component-registry | wc -l) own -> --add-dir $AD"
out="$(newcall start-bg ana "$R/fa")"
contains 'transparency: start-bg says it too' "$out" "ana: registry skills: "
out="$(newcall new ana "$R/fa" -- "--add-dir=$AD")"
check 'duplicate: --add-dir=<its folder> in its args, not added again' 0 "$(grep -c -- "--add-dir $AD" "$T/claude-calls")"
contains 'duplicate: said as already in its args' "$out" "(already in its args)"
newcall new ana "$R/fa" -- --add-dir /other "$AD" >/dev/null
check 'duplicate: its folder among several after one --add-dir, not added again' 1 "$(grep -o -- "$AD" "$T/claude-calls" | wc -l)"
newcall new ana "$R/fa" -- --add-dir /other >/dev/null
contains 'another folder: kept as it is, its own added after' "$(cat "$T/claude-calls")" "--add-dir /other --add-dir $AD"
lacks 'transparency: no clash, no clash line' "$(newcall new ana "$R/fa")" 'clash'
mkdir -p "$R/fa/.claude/skills/diagrams"; echo 'the project diagrams' > "$R/fa/.claude/skills/diagrams/SKILL.md"
out="$(newcall new ana "$R/fa")"
contains 'transparency: a project clash named in one line at the start' "$out" "ana: registry skills: clash: the project's $R/fa/.claude/skills/diagrams wins in its sessions; its own diagrams runs as /registry:diagrams."
rm -rf "$R/fa/.claude"
out="$(cd "$R/fz" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" bash "$adapter" new zed "$R/fz" 2>&1)"
lacks 'transparency: nothing added, nothing said' "$out" 'registry skills:'
# skills-show
contains 'skills-show is in supports' "$(PATH="$T/bin:/usr/bin:/bin" bash "$adapter" supports)" 'skills-show'
out="$(cd "$R/fa" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" bash "$adapter" skills-show ana "$R/fa")"
check 'skills-show: its own folder' "$AD" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "own" { print $2 }')"
check 'skills-show: its own skills' "diagrams" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "own-skills" { print $2 }')"
check 'skills-show: the shared ones' "shared" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "shared-skills" { print $2 }')"
out="$(cd "$R/fz" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" bash "$adapter" skills-show zed "$R/fz")"
check 'skills-show: an agent with no own folder' "-" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "own" { print $2 }')"
# modes
mode() { (cd "$2" && PATH="$T/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$R/cfg" COMPONENT_REGISTRY_SKILLS="$R/view-$3" COMPONENT_REGISTRY_PATH="/Corp/$3" COMPONENT_REGISTRY_SKILLS_MODE="$4" bash "$adapter" skills "$1" "$2" 2>&1); }
out="$(mode ana "$R/fa" x split)"
check 'mode split (explicit): as the default, diagrams contested stays own' 'for x' "$(cat "$AD/.claude/skills/diagrams/SKILL.md" 2>/dev/null)"
out="$(mode ana "$R/fa" x shared)"; rc=$?
check 'mode shared: exit 0' 0 "$rc"
check 'mode shared: its whole view personal' 'for x' "$(cat "$PS/diagrams/SKILL.md" 2>/dev/null)"
check 'mode shared: no own folder' no "$([ -e "$R/cfg/registry-agents/$(key ana "$R/fa")" ] && echo yes || echo no)"
contains 'mode shared: said, with what it means' "$out" "registry skills shared: the latest hand-over wins for every session"
out="$(newcall new ana "$R/fa")"
lacks 'mode shared: no --add-dir at the next start' "$(cat "$T/claude-calls")" '--add-dir'
mode ana "$R/fa" x split >/dev/null
out="$(mode ana "$R/fa" x off)"; rc=$?
check 'mode off: exit 0' 0 "$rc"
check 'mode off: its own folder dropped' no "$([ -e "$R/cfg/registry-agents/$(key ana "$R/fa")" ] && echo yes || echo no)"
check 'mode off: the split made again without it (bob alone: all personal)' 'for y' "$(cat "$PS/diagrams/SKILL.md" 2>/dev/null)"
out="$(mode ana "$R/fa" x sometimes)"; rc=$?
check 'mode: a bad value is bad use (exit 2)' 2 "$rc"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
