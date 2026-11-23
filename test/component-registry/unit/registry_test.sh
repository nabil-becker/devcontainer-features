#!/usr/bin/env bash
# Docker-free tests of the component-registry Feature (src/component-registry): the layer list
# (the YAML subset, flow maps, unknown keys refused with file:line, git and path sources checked),
# COMPONENT_REGISTRY_WHOAMI (required, with how to set it; .env; --as), the .layer grammar and the
# match rule on fixture layers (the proposal's worked example of section 3.3 to the letter; scope
# and component, relative paths joined to at, * and **, specificity and its tie-breaks, ! exclusion
# sections, lock, @replace and a lock surviving it, a type clash, list !item and ref: items, @file,
# files = @dir overlays, a permission key from the lowest layer only, a kind not in this release,
# unreadable lines reported), the sources (path: version fingerprint, offline fallback; git: a
# local repository at a branch, an annotated tag and a commit, an unknown tag), resolve (unchanged
# layers skipped, a required layer never fetched, copies no layer names removed, the view swapped
# in, owner-only modes, idempotent, two concurrent runs), explain (provenance with layer and
# version, skipped lines and why, dangling refs, --uses), the setup script and the Taskfile; and
# release 1.1.0: the built-in base layer of utility skills, layer-list, handover to a CLI adapter's
# skills verb (fake adapters with and without it), refresh, and remember into the writable layer;
# and release 1.6.0: agent definitions (model and skills, the fields the registry never sets,
# COMPONENT_REGISTRY_AGENTS, the view's agents/<name>/, explain); and release 1.7.0: layer
# namespaces (two never mixing, two layers of one merging with a lock and @replace, the Operator's
# layers unaffected, refs kept inside, agent definitions, <ns>--<name> on disk, bad names refused).
# Part of `task lint` (`task test:component-registry-unit`).
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

bin="$T/bin"; mkdir -p "$bin"
for f in dcf-registry registry-source-git registry-source-path component-registry-setup dcf-persist; do
  cp "$src/$f.sh" "$bin/$f"; chmod +x "$bin/$f"
done
export PATH="$bin:$PATH" COMPONENT_REGISTRY_SHARE_DIR="$T/share"
# refresh and remember hand over to every adapter on PATH, and a devhost with the Feature
# installed has a real one: keep it away from the real Claude config folder.
export CLAUDE_CONFIG_DIR="$T/claude-config"; mkdir -p "$CLAUDE_CONFIG_DIR"
unset COMPONENT_REGISTRY_WHOAMI COMPONENT_REGISTRY_FILE COMPONENT_REGISTRY_WHOAMI_TASK_VAR COMPONENT_REGISTRY_FILE_TASK_VAR
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email test@example.invalid; git config --global user.name test
git config --global init.defaultBranch main

# new_case <name>: a fresh repository (with .devcontainer) and state folder; cd into the repo
new_case() {
  C="$T/case-$1"; mkdir -p "$C/repo/.devcontainer" "$C/layers"
  export COMPONENT_REGISTRY_STATE_DIR="$C/state"
  cd "$C/repo" || exit 1
}
# layer <name>: a layer folder under the case; prints its path
layer() { mkdir -p "$C/layers/$1"; printf '%s' "$C/layers/$1"; }
# path_list <id:at:folder>...: a layer list of path sources, lowest first
path_list() {
  local spec
  echo "layers:" > .devcontainer/registry.yml
  for spec in "$@"; do
    IFS=: read -r id at folder <<< "$spec"
    printf '  - id: %s\n    at: %s\n    sources:\n      - { kind: path, path: "%s" }\n' "$id" "$at" "$folder" >> .devcontainer/registry.yml
  done
}
V() { printf '%s' "$COMPONENT_REGISTRY_STATE_DIR/view"; }
val() { cat "$(V)/meta/$1/values/$2" 2>/dev/null; }
W=/Corp/MyDepartment/team/me

# ------------------------------------------------------------ worked example ----
new_case worked
l1="$(layer corp)"; l2="$(layer dept)"; l3="$(layer mine)"
cat > "$l1/corp.layer" <<'EOF'
; layer 1 corp-base (at /Corp)
[skills/architecture-artifacts]
body:text = @file architecture-artifacts/SKILL.md
classification:value = internal
lock classification
EOF
mkdir -p "$l1/architecture-artifacts"
printf '%s\n' '# Architecture artifacts' '' 'Produce the artifacts.' > "$l1/architecture-artifacts/SKILL.md"
cat > "$l2/dept.layer" <<'EOF'
; layer 2 dept (at /Corp/MyDepartment)
[skills/architecture-artifacts]
body:text = Draw C4, not UML.
terms:list = C4, ADR, SLA
[/Corp/Finance/skills/architecture-artifacts]
body:text = Use the finance templates.
EOF
cat > "$l3/mine.layer" <<'EOF'
; layer 3 mine (at /Corp/MyDepartment/team/me)
[/**/skills/architecture-artifacts]
body:text = Use colour-blind-safe colours.
terms:list = !ADR
classification:value = public
EOF
cat > .devcontainer/registry.yml <<EOF
# the proposal's three layers, as path sources
layers:
  - id: corp-base
    at: /Corp
    sources:
      - kind: path
        path: "$l1"
        required: true
  - id: dept
    at: /Corp/MyDepartment
    sources:
      - { kind: path, path: "$l2" }
  - id: mine
    at: $W
    sources:
      - { kind: path, path: "$l3" }   # git-ignored in a real repository
    writable: true
EOF
out="$(dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check "worked example: resolve exits 0" 0 "$rc"
contains "worked example: resolve reports the locked line" "$out" "skipped mine 1:mine.layer:5 skills/architecture-artifacts:classification: locked by corp-base at 1:corp.layer:5"
expected="$(printf '%s\n' '## Layer corp-base' '' '# Architecture artifacts' '' 'Produce the artifacts.' '' '## Layer dept' '' 'Draw C4, not UML.' '' '## Layer mine' '' 'Use colour-blind-safe colours.')"
check "worked example: body is the corp SKILL.md, then dept's line, then mine's, under layer headings" "$expected" "$(cat "$(V)/skills/architecture-artifacts/SKILL.md")"
lacks "worked example: the finance line does not apply" "$(cat "$(V)/skills/architecture-artifacts/SKILL.md")" "finance"
check "worked example: terms is C4, SLA" "$(printf 'C4\nSLA')" "$(val skills/architecture-artifacts terms)"
check "worked example: classification stays internal (locked by layer 1)" internal "$(val skills/architecture-artifacts classification)"
ex="$(dcf-registry explain skills/architecture-artifacts)"
contains "worked example: explain shows layer 3's line skipped by the lock" "$ex" "skipped      mine@tree-"
contains "worked example: explain names the lock that skipped it" "$ex" "classification:value = public  (locked by corp-base at 1:corp.layer:5)"
contains "worked example: explain shows the finance line as not applying" "$ex" "not-applying dept@"
contains "worked example: explain shows each layer's version" "$ex" "1 corp-base at /Corp, source 1 (path): fetched, tree-"
contains "explain with :key shows that key only" "$(dcf-registry explain /Corp/skills/architecture-artifacts:terms)" "terms:list = C4, SLA"
lacks "explain with :key leaves the other keys out" "$(dcf-registry explain skills/architecture-artifacts:terms)" "classification"

# explain --color (1.4.0): colour by layer, plain output unchanged
ESC="$(printf '\033')"
plain="$(dcf-registry explain skills/architecture-artifacts --color never)"
lacks "color never: no escape code" "$plain" "$ESC"
check "color never: the same as the default on a non-terminal (the 1.3.0 text)" "$plain" "$ex"
check "color=never: same as --color never" "$plain" "$(dcf-registry explain skills/architecture-artifacts --color=never)"
col="$(dcf-registry explain skills/architecture-artifacts --color always)"
contains "color always: escape codes are there" "$col" "${ESC}[38;5;"
contains "color always: a legend maps layer ids to colour names" "$col" "Colour by layer:"
contains "color always: the legend names corp-base and its colour" "$col" "[corp-base = "
contains "color always: skipped lines are dim and struck through" "$col" "${ESC}[2;9m  skipped"
contains "color always: every resolved line still carries its layer id" "$col" "used         corp-base@tree-"
nolegend="$(printf '%s\n' "$col" | sed -e "s/${ESC}\\[[0-9;]*m//g" | grep -v '^Colour by layer:')"
check "color always: stripped of escapes and the legend it is the plain text" "$plain" "$nolegend"
check "color auto: no colour when stdout is not a terminal" "$plain" "$(dcf-registry explain skills/architecture-artifacts --color auto)"
check "NO_COLOR with the default: no colour" "$plain" "$(NO_COLOR=1 dcf-registry explain skills/architecture-artifacts)"
contains "NO_COLOR with --color always: the flag wins" "$(NO_COLOR=1 dcf-registry explain skills/architecture-artifacts --color always)" "${ESC}[38;5;"
if command -v script >/dev/null 2>&1; then
  tty_out="$(script -qec 'dcf-registry explain skills/architecture-artifacts' /dev/null 2>&1 | tr -d '\r')"
  contains "color auto: colour on a terminal" "$tty_out" "${ESC}[38;5;"
  tty_nc="$(NO_COLOR=1 script -qec 'dcf-registry explain skills/architecture-artifacts' /dev/null 2>&1 | tr -d '\r')"
  lacks "color auto: NO_COLOR keeps a terminal plain" "$tty_nc" "$ESC"
fi
out="$(dcf-registry explain skills/architecture-artifacts --color pink 2>&1)"; rc=$?
check "color: a bad value is refused with exit 2" 2 "$rc"

# front matter of the lowest body stays at the top of SKILL.md
printf '%s\n' '---' 'name: architecture-artifacts' 'description: Draw it.' '---' '# Architecture artifacts' > "$l1/architecture-artifacts/SKILL.md"
dcf-registry resolve --as "$W" >/dev/null 2>&1
check "front matter is hoisted above the first layer heading" "---|name: architecture-artifacts|description: Draw it.|---|## Layer corp-base|" "$(head -n 5 "$(V)/skills/architecture-artifacts/SKILL.md" | tr '\n' '|')"

# second run: nothing changed, nothing fetched
out="$(dcf-registry resolve --as "$W" 2>&1)"
contains "an unchanged layer is not fetched again" "$out" "layer dept source 1 (path): unchanged at tree-"
before="$(cd "$(V)" && find skills meta -type f -exec cat {} + | cksum)"
dcf-registry resolve --as "$W" >/dev/null 2>&1
check "resolve is idempotent (the same view)" "$before" "$(cd "$(V)" && find skills meta -type f -exec cat {} + | cksum)"
check "only the current view is kept" 1 "$(find "$COMPONENT_REGISTRY_STATE_DIR/views" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
check "the view is a symlink into views/" "$COMPONENT_REGISTRY_STATE_DIR/views" "$(dirname "$(readlink -f "$(V)")")"
check "the state folder is owner-only" 700 "$(stat -c %a "$COMPONENT_REGISTRY_STATE_DIR")"
check "a resolved file is owner-only" 600 "$(stat -c %a "$(V)/skills/architecture-artifacts/SKILL.md")"
check "a layer copy is owner-only" 700 "$(stat -c %a "$COMPONENT_REGISTRY_STATE_DIR/copies/mine/1")"

# two resolves at once: both finish, one view
dcf-registry resolve --as "$W" >"$C/r1" 2>&1 & p1=$!
dcf-registry resolve --as "$W" >"$C/r2" 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
check "two concurrent resolves both succeed (the lock serialises them)" "0 0" "$r1 $r2"
check "after two concurrent resolves the view is whole" "$(printf 'C4\nSLA')" "$(val skills/architecture-artifacts terms)"

# offline: the layer folder disappears; the last good copy is used and said
mv "$l2" "$l2.away"
out="$(dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check "offline: resolve still exits 0" 0 "$rc"
contains "offline: resolve says it uses the last good copy" "$out" "layer dept source 1 (path): unreachable, using the last good copy (tree-"
check "offline: the layer's lines are still there" "$(printf 'C4\nSLA')" "$(val skills/architecture-artifacts terms)"
contains "offline: explain says the layer is offline" "$(dcf-registry explain skills/architecture-artifacts)" "2 dept at /Corp/MyDepartment, source 1 (path): offline, tree-"
mv "$l2.away" "$l2"

# a layer taken out of the list: its copy goes
path_list "corp-base:/Corp:$l1" "mine:$W:$l3"
out="$(dcf-registry resolve --as "$W" 2>&1)"
contains "a layer no longer listed: its copy is removed" "$out" "removed the copy of layer dept"
check "a layer no longer listed: no copy folder left" no "$([ -e "$COMPONENT_REGISTRY_STATE_DIR/copies/dept" ] && echo yes || echo no)"
check "without dept, terms comes from mine only (an empty list)" "" "$(val skills/architecture-artifacts terms)"

# -------------------------------------------------------- who you are ----
new_case whoami
l="$(layer a)"; printf '[skills/x]\ncolor:value = blue\n' > "$l/a.layer"
path_list "a:/Corp:$l"
out="$(dcf-registry resolve 2>&1)"; rc=$?
check "no COMPONENT_REGISTRY_WHOAMI: exit 2" 2 "$rc"
contains "no COMPONENT_REGISTRY_WHOAMI: says how to set it" "$out" "Set COMPONENT_REGISTRY_WHOAMI to your path"
contains "no COMPONENT_REGISTRY_WHOAMI: names --as" "$out" "--as <path>"
echo "COMPONENT_REGISTRY_WHOAMI=/Corp/Sales/me   # mine" > .env
out="$(dcf-registry resolve 2>&1)"; rc=$?
check "whoami from .env: resolves" 0 "$rc"
contains "whoami from .env: says where it came from" "$out" "resolving for /Corp/Sales/me (from COMPONENT_REGISTRY_WHOAMI in .env)"
contains "--as beats .env" "$(dcf-registry resolve --as /Corp/Other 2>&1)" "resolving for /Corp/Other (from --as)"
out="$(COMPONENT_REGISTRY_WHOAMI_TASK_VAR=/Corp/Task dcf-registry resolve 2>&1)"
contains "the task variable beats .env" "$out" "resolving for /Corp/Task (from the task variable"
out="$(dcf-registry resolve --as 'Corp/rel' 2>&1)"; rc=$?
check "a relative who-you-are path is refused" 2 "$rc"
out="$(dcf-registry resolve --as '/Corp/*' 2>&1)"; rc=$?
check "a who-you-are path with a wildcard is refused" 2 "$rc"
out="$(dcf-registry explain skills/x --as /Corp/Elsewhere 2>&1)"; rc=$?
check "explain for another who-you-are path refuses (it never resolves)" 1 "$rc"
contains "explain for another path says to resolve first" "$out" "run dcf-registry resolve --as /Corp/Elsewhere first"

# ------------------------------------------------------- the layer list ----
new_case list
l="$(layer a)"; printf '[skills/x]\ncolor:value = blue\n' > "$l/a.layer"
bad() { # <name> <expected text> <yaml>
  printf '%s\n' "$3" > .devcontainer/registry.yml
  out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
  check "list: $1 (exit 2)" 2 "$rc"; contains "list: $1 (message)" "$out" "$2"
}
bad "an unknown layer key, with file:line" ".devcontainer/registry.yml:4: unknown key 'colour' in a layer" "$(printf 'layers:\n  - id: a\n    at: /Corp\n    colour: red\n    sources:\n      - { kind: path, path: x }')"
bad "an unknown source key" ".devcontainer/registry.yml:5: unknown key 'branche' in a source" "$(printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: git, branche: main }')"
bad "an unknown auth key" ".devcontainer/registry.yml:7: unknown key 'token' in auth" "$(printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - kind: git\n        auth:\n          token: x')"
bad "an unknown top-level key" ":1: unknown top-level key 'whoami'" "$(printf 'whoami: /Corp/me\nlayers: []')"
bad "git without a ref" "a git source needs exactly one of branch, tag, commit" "$(printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: git, url: "https://git.example.invalid/r.git" }')"
bad "git with two refs" "exactly one of branch, tag, commit" "$(printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: git, url: u, tag: v1, branch: main }')"
bad "a relative at" "at 'Corp' must be an absolute path" "$(printf 'layers:\n  - id: a\n    at: Corp\n    sources:\n      - { kind: path, path: x }')"
bad "two layers with one id" "id 'a' is already used by layer 1" "$(printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: path, path: x }\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: path, path: y }')"
bad "a layer without sources" "has no sources" "$(printf 'layers:\n  - id: a\n    at: /Corp')"
bad "an unclosed flow map" "a { map must close on the same line" "$(printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: path, path: x')"
rm .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "no layer list: exit 2" 2 "$rc"
contains "no layer list: names the path and its source" "$out" "no layer list at $C/repo/.devcontainer/registry.yml (from the default"
mkdir -p "$T/share"; printf 'REGISTRYFILE=reg/list.yml\n' > "$T/share/options.env"
contains "the Feature option registryFile is the default" "$(dcf-registry resolve --as /Corp 2>&1)" "(from the Feature option registryFile)"
rm -f "$T/share/options.env"
mkdir -p reg; printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - kind: path\n        path: %s   # a comment\n' "$l" > reg/list.yml
echo "COMPONENT_REGISTRY_FILE=reg/list.yml" > .devcontainer/.env
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "COMPONENT_REGISTRY_FILE from .devcontainer/.env; block source with a comment" 0 "$rc"
check "COMPONENT_REGISTRY_FILE from .devcontainer/.env: resolved" blue "$(val skills/x color)"
printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - kind: git\n        url: "https://git.example.invalid/r.git"\n        tag: v1\n        auth:\n          type: basic\n          user: bot\n          secret: registry/a\n      - kind: path\n        path: %s\n' "$l" > reg/list.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "a block auth map parses; an unreachable git source is not fatal" 0 "$rc"
contains "an unreachable source with no copy is said" "$out" "layer a source 1 (git): not read, no copy yet"
rm .devcontainer/.env

# ------------------------------------------------------- merge rules ----
new_case merge
l1="$(layer one)"; l2="$(layer two)"
path_list "one:/Corp:$l1" "two:/Corp/MyDepartment:$l2"
cat > "$l1/one.layer" <<'EOF'
; types, locks, permissions, files
[skills/x]
color:value = blue
size:list = s, m
allowed-tools:list = Read
note:text = base note
files:value = @dir x-files
mode:value = strict
lock mode
[skills/y]
a:value = 1
b:value = 2
keep:value = locked
lock keep
[skills/z]
z:value = 1
EOF
mkdir -p "$l1/x-files"; echo base-a > "$l1/x-files/a.md"; echo base-b > "$l1/x-files/b.md"
cat > "$l2/two.layer" <<'EOF'
[skills/x]
color:list = red
size:list = l, !s
allowed-tools:list = Bash
note:text = @file missing.md
files:value = @dir x-files
mode:value = loose
[skills/y] @replace
c:value = 3
keep:value = replaced
[/**/skills/z]
z:value = 2
[!/Corp/MyDepartment/**/skills/z]
[skills/w]
w:ref = /skills/x
lines:list = ref:/skills/y, plain, ref:/skills/nowhere
gone:ref = skills/missing
key:ref = skills/x:color
nokey:ref = skills/x:nothere
EOF
mkdir -p "$l2/x-files"; echo dept-b > "$l2/x-files/b.md"
printf '[skills/v]\nv:value = 1\n[!/Corp/**]\n' > "$l2/y-excl.layer"
printf 'not a line\n[skills/q\nk:number = 1\n[/Corp/prompts/helper]\nmodel:value = big\n' > "$l2/z-broken.layer"
out="$(dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check "merge fixtures resolve (content never fails a resolve)" 0 "$rc"
check "type clash: the lowest layer's type wins" blue "$(val skills/x color)"
contains "type clash: reported by resolve" "$out" "skills/x:color: type clash: color is value, fixed by one at 1:one.layer:3"
contains "type clash: shown by explain" "$(dcf-registry explain skills/x:color)" "skipped      two@"
check "list: !item removes, items combined" "$(printf 'm\nl')" "$(val skills/x size)"
check "a permission key comes from the lowest layer only" Read "$(val skills/x allowed-tools)"
contains "a permission key from a higher layer is reported" "$out" "skills/x:allowed-tools: a permission key is taken from the component's lowest layer only"
check "lock: the locked key keeps the lower value" strict "$(val skills/x mode)"
contains "text @file missing: skipped and reported" "$out" "skills/x:note: no file missing.md in the layer copy"
check "text @file missing: the other text stays" "$(printf '## Layer one\n\nbase note')" "$(val skills/x note)"
check "files: a stronger layer's file of the same name replaces the weaker" dept-b "$(cat "$(V)/skills/x/b.md")"
check "files: the weaker layer's other files stay" base-a "$(cat "$(V)/skills/x/a.md")"
check "@replace drops the lower layer's lines" "" "$(val skills/y a)"
check "@replace keeps its own lines" 3 "$(val skills/y c)"
check "a locked key survives a higher @replace" locked "$(val skills/y keep)"
contains "@replace: explain shows the dropped lines" "$(dcf-registry explain skills/y)" "dropped by @replace in two at 1:two.layer:"
check "! exclusion section: the sections above it in the file no longer apply" 1 "$(val skills/z z)"
contains "! exclusion section: explain says what excluded the line" "$(dcf-registry explain skills/z)" "excluded by [!/Corp/MyDepartment/**/skills/z]"
check "an exclusion without a component excludes every section above it in its file" "" "$(val skills/v v)"
check "! exclusion section: it excludes only the component it names" blue "$(val skills/x color)"
contains "an unreadable line is reported with its place" "$out" "skipped two 1:z-broken.layer:1: not a section"
contains "an unknown type is reported" "$out" "type 'number' is none of value, list, text, ref"
contains "a bad section header is reported" "$out" "1:z-broken.layer:2: a section header needs a closing ]"
contains "a kind not in this release is reported" "$out" "kind prompts is not in this release"
check "a kind not in this release is not resolved" no "$([ -e "$(V)/prompts" ] && echo yes || echo no)"
check "ref: the strongest line's path" /skills/x "$(val skills/w w)"
contains "a ref to nothing is reported by resolve as a missing dependency" "$out" "missing dependency: skills/w:gone in layer"
contains "a ref to nothing: the target and why" "$out" "-> skills/missing (no component skills/missing for $W)"
ex="$(dcf-registry explain skills/w)"
contains "explain lists a dangling ref" "$ex" "skills/w:gone -> skills/missing (no component skills/missing"
contains "a list ref: item to nothing is dangling" "$ex" "skills/w:lines -> /skills/nowhere"
contains "a ref to a missing key is dangling" "$ex" "skills/w:nokey -> skills/x:nothere (skills/x has no key nothere)"
check "a ref to an existing key is ok" ok "$(awk -F'\t' '$1 == "skills/w" && $2 == "key" { print $6 }' "$(V)/meta/refs.tsv")"
contains "explain lists every reference as written and as resolved" "$ex" "References (1.7.0"
uses="$(dcf-registry explain skills/x --uses)"
contains "--uses lists a ref value" "$uses" "skills/w:w -> /skills/x (ok)"
contains "--uses lists a ref to one of its keys" "$uses" "skills/w:key -> skills/x:color (ok)"
contains "--uses lists a list ref: item" "$(dcf-registry explain skills/y --uses)" "skills/w:lines -> /skills/y (ok)"
check "--uses with nothing pointing at it" "  nothing" "$(dcf-registry explain skills/z --uses | tail -n 1)"
out="$(dcf-registry explain skills/nope 2>&1)"; rc=$?
check "explain of a component not in the view: exit 1" 1 "$rc"

# specificity inside one layer: the deeper match wins, then fewer wildcards, then the later line
new_case spec
l="$(layer a)"; path_list "a:/:$l"
cat > "$l/a.layer" <<'EOF'
[/Corp/MyDepartment/skills/s]
depth:value = shallow
[/Corp/*/team/me/skills/s]
tie:value = wildcard
[/**/skills/s]
depth:value = deep-wild
[/Corp/MyDepartment/team/me/skills/s]
tie:value = literal
[/Corp/MyDepartment/team/me/skills/s]
later:value = first
[/Corp/MyDepartment/team/me/skills/s]
later:value = second
[skills/s]
root:value = everyone
EOF
dcf-registry resolve --as "$W" >/dev/null 2>&1
check "specificity: a deeper ancestor of W beats a shallower one, whatever the order" deep-wild "$(val skills/s depth)"
check "specificity: at the same depth fewer wildcards win" literal "$(val skills/s tie)"
check "specificity: on a full tie the later line wins" second "$(val skills/s later)"
check "a layer at / with a relative section applies to everyone" everyone "$(val skills/s root)"
dcf-registry resolve --as /Corp/Finance >/dev/null 2>&1
check "who you are selects lines: under /Corp/Finance only /** applies" deep-wild "$(val skills/s depth)"
check "who you are selects lines: the team lines do not apply to /Corp/Finance" "" "$(val skills/s tie)"

# ------------------------------------------------------------- sources ----
new_case required
l="$(layer present)"; printf '[skills/x]\ncolor:value = blue\n' > "$l/a.layer"
printf 'layers:\n  - id: corp\n    at: /Corp\n    required: true\n    sources:\n      - { kind: path, path: %s/nowhere }\n  - id: b\n    at: /Corp\n    sources:\n      - { kind: path, path: %s }\n' "$C/layers" "$l" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "a required layer never fetched: exit 1" 1 "$rc"
contains "a required layer never fetched: said" "$out" "layer corp source 1 (path) is required and has never been fetched"
check "a required layer never fetched: no view is made" no "$([ -e "$(V)" ] && echo yes || echo no)"
printf 'layers:\n  - id: corp\n    at: /Corp\n    sources:\n      - { kind: http, url: "https://registry.example.invalid/l.layer", required: true }\n' > .devcontainer/registry.yml
# A devhost with the Feature installed has a registry-source-http on PATH; leave out
# every PATH folder that holds one, so this case does not depend on the machine.
nohttp=""; IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do [ -x "$d/registry-source-http" ] || nohttp="${nohttp:+$nohttp:}$d"; done
out="$(PATH="$nohttp" dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "a required http source with no registry-source-http on PATH: exit 1" 1 "$rc"
contains "an http source with no command says so" "$out" "no registry-source-http on PATH"

new_case path
l="$(layer a)"; printf '[skills/x]\n' > "$l/a.layer"
v1="$(registry-source-path version a "path=$l")"
check "path source: version is a tree fingerprint" tree "${v1%%-*}"
sleep 0.01; echo more >> "$l/a.layer"
check "path source: a changed file changes the version" changed "$([ "$(registry-source-path version a "path=$l")" != "$v1" ] && echo changed)"
registry-source-path version a "path=$C/none" >/dev/null 2>&1; check "path source: a missing folder is exit 1" 1 $?
registry-source-path version a "url=x" >/dev/null 2>&1; check "path source: an unknown setting is exit 2" 2 $?
registry-source-path frobnicate >/dev/null 2>&1; check "path source: an unknown verb is exit 3" 3 $?
check "path source: supports lists its verbs" "fetch version supports" "$(registry-source-path supports | tr '\n' ' ' | sed 's/ $//')"
printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: path, path: rel-layer }\n' > .devcontainer/registry.yml
mkdir rel-layer; printf '[skills/r]\nk:value = relative\n' > rel-layer/r.layer
mkdir -p sub/dir; (cd sub/dir && dcf-registry resolve --as /Corp >/dev/null 2>&1)
check "path source: a relative path is the repository's, from any folder in it" relative "$(val skills/r k)"

new_case git
cat > "$bin/dcf-secret" <<'EOF'
#!/bin/sh
echo "$*" >> "${DCF_SECRET_CALLS:-/dev/null}"
[ "$2" = registry/bad ] && { echo "dcf-secret: no such secret" >&2; exit 14; }
echo s3cret
EOF
chmod +x "$bin/dcf-secret"; export DCF_SECRET_CALLS="$C/secret-calls"
g="$C/remote"; git init -q "$g"
printf '[skills/g]\nv:value = one\n' > "$g/g.layer"
git -C "$g" add -A; git -C "$g" commit -qm one; git -C "$g" tag -a v1 -m v1; c1="$(git -C "$g" rev-parse HEAD)"
printf '[skills/g]\nv:value = two\n' > "$g/g.layer"; git -C "$g" commit -qam two; c2="$(git -C "$g" rev-parse HEAD)"
check "git source: version of a branch is its commit" "$c2" "$(registry-source-git version g "url=$g" branch=main)"
check "git source: version of an annotated tag is the tagged commit" "$c1" "$(registry-source-git version g "url=$g" tag=v1)"
registry-source-git version g "url=$g" tag=v9 >/dev/null 2>&1; check "git source: an unknown tag is exit 1" 1 $?
registry-source-git version g "url=$g" >/dev/null 2>&1; check "git source: no ref is exit 2" 2 $?
out="$(registry-source-git version g "url=$g" branch=main auth.secret=registry/bad 2>&1)"; rc=$?
check "git source: a secret dcf-secret cannot read is exit 1" 1 "$rc"
contains "git source: a secret dcf-secret cannot read is named" "$out" "dcf-secret could not read registry/bad"
mkdir "$C/dest"; registry-source-git fetch g "$C/dest" "url=$g" "commit=$c1" >/dev/null 2>&1
check "git source: fetch at a commit" "v:value = one" "$(sed -n 2p "$C/dest/g.layer")"
check "git source: no .git in the layer copy" no "$([ -e "$C/dest/.git" ] && echo yes || echo no)"
printf 'layers:\n  - id: g\n    at: /Corp\n    sources:\n      - { kind: git, url: "%s", tag: v1 }\n  - id: h\n    at: /Corp\n    sources:\n      - kind: git\n        url: "%s"\n        branch: main\n        auth: { type: basic, secret: registry/none }\n' "$g" "$g" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "git source: resolve exits 0" 0 "$rc"
contains "git source: fetched at the tag's commit" "$out" "layer g source 1 (git): fetched $c1"
check "git source: the higher layer (branch main) wins" two "$(val skills/g v)"
contains "git source: the auth secret is read with dcf-secret" "$(cat "$DCF_SECRET_CALLS")" "get registry/none"
lacks "git source: the secret never reaches the output" "$out" s3cret
contains "git source: explain shows the commit each layer was read at" "$(dcf-registry explain skills/g)" "g@$c1"
printf '[skills/g]\nv:value = three\n' > "$g/g.layer"; git -C "$g" commit -qam three
out="$(dcf-registry resolve --as /Corp 2>&1)"
contains "git source: a tag that did not move is unchanged" "$out" "layer g source 1 (git): unchanged at $c1"
check "git source: a branch that moved is fetched again" three "$(val skills/g v)"
mv "$g" "$g.away"
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "git source offline: exit 0" 0 "$rc"
contains "git source offline: the last good copy is used and said" "$out" "layer h source 1 (git): unreachable, using the last good copy"
check "git source offline: the values stay" three "$(val skills/g v)"
mv "$g.away" "$g"
sed -i 's/tag: v1/branch: main/' .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"
contains "git source: a changed pin is fetched, not taken from the old copy" "$out" "layer g source 1 (git): fetched"

# --------------------------------------------------- explain, setup, task ----
new_case setup
out="$(dcf-registry explain skills/x 2>&1)"; rc=$?
check "explain with no resolved view: exit 1" 1 "$rc"
contains "explain with no resolved view: says to resolve" "$out" "run dcf-registry resolve"
dcf-registry explain >/dev/null 2>&1; check "explain without a path: exit 2" 2 $?
dcf-registry frobnicate >/dev/null 2>&1; check "an unknown verb: exit 2" 2 $?
out="$(component-registry-setup 2>&1)"
check "setup makes the state folder owner-only" 700 "$(stat -c %a "$COMPONENT_REGISTRY_STATE_DIR")"
contains "setup says how to resolve" "$out" "no resolved view yet; set COMPONENT_REGISTRY_WHOAMI"
component-registry-setup >/dev/null 2>&1; check "setup is idempotent (exit 0 again)" 0 $?
chmod 755 "$COMPONENT_REGISTRY_STATE_DIR"; component-registry-setup >/dev/null 2>&1
check "setup repairs a widened mode" 700 "$(stat -c %a "$COMPONENT_REGISTRY_STATE_DIR")"

if command -v task >/dev/null 2>&1; then
  l="$(layer a)"; printf '[skills/t]\nk:value = from-task\n' > "$l/a.layer"; path_list "a:/Corp:$l"
  out="$(task -t "$src/taskfile.yml" resolve COMPONENT_REGISTRY_WHOAMI=/Corp/me 2>&1)"; rc=$?
  check "task resolve with the who-you-are path as a task variable" 0 "$rc"
  contains "task resolve: the task variable is named as the source" "$out" "from the task variable COMPONENT_REGISTRY_WHOAMI"
  contains "task explain hands the path on" "$(task -t "$src/taskfile.yml" explain -- skills/t 2>&1)" "k:value = from-task"
  contains "task version shows the layer list" "$(task -t "$src/taskfile.yml" version 2>&1)" "layer list: $C/repo/.devcontainer/registry.yml"
else
  echo "skip - task not installed: the Taskfile part"
fi

# ------------------------------------- release 1.1.0: base layer, handover, refresh, remember ----
# The built-in base layer: the Feature's utility skills, from COMPONENT_REGISTRY_SHARE_DIR/base.
base_share="$T/share-base"; mkdir -p "$base_share"; cp -R "$src/base" "$base_share/base"; echo 1.1.0 > "$base_share/version"
new_case base
l="$(layer mine)"; printf '[skills/demo]\nbody:text = mine\n' > "$l/a.layer"
printf 'layers:\n  - id: mine\n    at: /Corp/me\n    writable: true\n    sources:\n      - { kind: path, path: "%s" }\n' "$l" > .devcontainer/registry.yml
out="$(COMPONENT_REGISTRY_SHARE_DIR="$base_share" dcf-registry resolve --as /Corp/me 2>&1)"
contains "base layer: the two utility skills and the layer's skill resolved" "$out" "resolved 3 component(s)"
for s in registry-refresh registry-explain; do
  contains "base layer: $s has its SKILL.md with its front matter" "$(head -n 2 "$(V)/skills/$s/SKILL.md" 2>/dev/null)" "name: $s"
done
out="$(COMPONENT_REGISTRY_SHARE_DIR="$base_share" dcf-registry explain skills/registry-refresh 2>&1)"
contains "base layer: explain lists it as rank 0, builtin" "$out" "0 component-registry at /, source 1 (builtin): builtin, 1.1.0"
contains "base layer: explain names it for each line" "$out" "used         component-registry@1.1.0 1:component-registry.layer:"
printf '[skills/registry-refresh]\nbody:text = also say hello\n' >> "$l/a.layer"
COMPONENT_REGISTRY_SHARE_DIR="$base_share" dcf-registry resolve --as /Corp/me >/dev/null 2>&1
contains "base layer: a listed layer stacks on a utility skill" "$(cat "$(V)/skills/registry-refresh/SKILL.md")" "also say hello"
check "base layer: absent (no base folder) adds nothing (the two skills the layer names)" 1 "$(COMPONENT_REGISTRY_SHARE_DIR="$T/none" dcf-registry resolve --as /Corp/me 2>&1 | grep -c "resolved 2 component")"
printf 'layers:\n  - id: component-registry\n    at: /Corp\n    sources:\n      - { kind: path, path: "%s" }\n' "$l" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp/me 2>&1)"; rc=$?
check "base layer: its id is reserved (exit 2)" 2 "$rc"
contains "base layer: the reserved id is named" "$out" "id 'component-registry' is reserved"

# layer-list
new_case layerlist
out="$(dcf-registry layer-list)"; rc=$?
check "layer-list: no list, exit 1" 1 "$rc"
check "layer-list: prints the path it looked for" "$C/repo/.devcontainer/registry.yml" "$out"
path_list "a:/Corp:$(layer a)"
dcf-registry layer-list >/dev/null; check "layer-list: a list, exit 0" 0 $?

# handover: fake adapters, one taking skills, one without the verb
abin="$T/adapters"; mkdir -p "$abin"
# shellcheck disable=SC2016  # the fakes expand their own variables
printf '#!/usr/bin/env bash\n[ "$1" = supports ] && { echo skills; exit 0; }\n[ "$1" = skills ] && { echo "took $2 $3 from $COMPONENT_REGISTRY_SKILLS: $(ls "$COMPONENT_REGISTRY_SKILLS" | tr "\\n" " ")"; exit "${FAKE_SKILLS_RC:-0}"; }\nexit 3\n' > "$abin/agent-adapter-takes"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[ "$1" = supports ] && { echo new; exit 0; }\necho "called $1" >> "%s/nosk-calls"\nexit 3\n' "$T" > "$abin/agent-adapter-noskills"
chmod +x "$abin"/*
new_case handover
l="$(layer a)"; printf '[skills/one]\nbody:text = one\n[skills/two]\nbody:text = two\n' > "$l/a.layer"; path_list "a:/Corp:$l"
out="$(PATH="$abin:$PATH" dcf-registry handover takes 2>&1)"; rc=$?
check "handover with no resolved view: exit 1" 1 "$rc"
dcf-registry resolve --as /Corp/me >/dev/null 2>&1
out="$(PATH="$abin:$PATH" dcf-registry handover takes host /some/folder 2>&1)"; rc=$?
check "handover: exit 0" 0 "$rc"
contains "handover: the adapter gets the agent, the folder and the view's skills" "$out" "took host /some/folder from $COMPONENT_REGISTRY_STATE_DIR/views/"
contains "handover: the resolved skills are in that folder" "$out" "one two"
out="$(PATH="$abin:$PATH" dcf-registry handover takes 2>&1)"
contains "handover: default name and folder (component-registry, the repository root)" "$out" "took component-registry $C/repo from"
out="$(PATH="$abin:$PATH" dcf-registry handover noskills 2>&1)"; rc=$?
check "handover: an adapter without skills in supports, exit 3" 3 "$rc"
contains "handover: says its sessions keep their plain skills" "$out" "noskills: its adapter takes no resolved skills"
check "handover: the verb is never called when supports omits it" "" "$(cat "$T/nosk-calls" 2>/dev/null)"
out="$(PATH="$abin:$PATH" dcf-registry handover nosuchcli 2>&1)"; rc=$?
check "handover: no adapter on PATH, exit 3" 3 "$rc"
out="$(PATH="$abin:$PATH" FAKE_SKILLS_RC=1 dcf-registry handover takes 2>&1)"; rc=$?
check "handover: the adapter's failure is passed on (exit 1)" 1 "$rc"
dcf-registry handover >/dev/null 2>&1; check "handover without a CLI: exit 2" 2 $?

# refresh: resolve for the view's path, then every adapter on PATH (with no hand-over recorded:
# the records the hand-overs above made are taken away; 1.8.0 refreshes the recorded ones, below)
check "handover: recorded (cli, name, folder, path, path mode, skills mode)" "takes	host	/some/folder	/Corp/me	whoami	split" "$(dcf-registry handovers | head -n 1)"
rm -f "$COMPONENT_REGISTRY_STATE_DIR/handovers.tsv"
out="$(PATH="$abin:$PATH" dcf-registry refresh 2>&1)"; rc=$?
check "refresh: exit 0" 0 "$rc"
contains "refresh: for the path the current view was resolved for" "$out" "refreshing for /Corp/me, the path the current view was resolved for"
contains "refresh: hands over to an adapter that takes skills" "$out" "took component-registry"
contains "refresh: names the adapter that cannot" "$out" "noskills: its adapter takes no resolved skills"
contains "refresh: says a CLI without live reload needs a restart" "$out" "when its session is restarted"
out="$(PATH="$abin:$PATH" dcf-registry refresh --as /Corp/other 2>&1)"
check "refresh --as: resolves for that path" /Corp/other "$(cat "$(V)/whoami")"
new_case refreshfail
l="$(layer a)"; printf '[skills/one]\nbody:text = one\n' > "$l/a.layer"; path_list "a:/Corp:$l"
out="$(PATH="$abin:$PATH" dcf-registry refresh 2>&1)"; rc=$?
check "refresh with no view and no who-you-are path: exit 2" 2 "$rc"
contains "refresh failing: nothing handed over" "$out" "nothing was handed over"

# ------------------------------- 1.8.0: a view per who-you-are path, records, refresh, forget ----
rbin="$T/rec-adapter"; mkdir -p "$rbin"
# a fake adapter that takes skills and lists sessions: it logs each hand-over (agent, folder, path,
# the last line of the skill "mine") and each forget to rec-log; its list is the file rec-list
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\ncase "$1" in\n  supports) printf "skills\\nskills-show\\nlist\\n" ;;\n  skills-show) printf "own\\t/own/$2\\nown-skills\\tmine\\nshared\\t/shared\\nshared-skills\\tshared\\n" ;;\n  list) cat "%s/rec-list" 2>/dev/null ;;\n  skills) echo "$2 ${COMPONENT_REGISTRY_SKILLS_MODE:-unset}" >> "%s/rec-mode"; if [ "${COMPONENT_REGISTRY_FORGET:-}" = 1 ]; then echo "forget $2 $3" >> "%s/rec-log"; else echo "skills $2 $3 $COMPONENT_REGISTRY_PATH $(tail -n 1 "$COMPONENT_REGISTRY_SKILLS/mine/SKILL.md" 2>/dev/null)" >> "%s/rec-log"; fi ;;\n  *) exit 3 ;;\nesac\n' "$T" "$T" "$T" "$T" > "$rbin/agent-adapter-rec"
chmod +x "$rbin/agent-adapter-rec"
RP="$rbin:$bin:/usr/bin:/bin"
P() { printf '%s' "$COMPONENT_REGISTRY_STATE_DIR/paths/$1"; }
new_case perpath
l="$(layer a)"
printf '[/**/skills/shared]\nbody:text = same\n[/Corp/x/skills/mine]\nbody:text = for x\n[/Corp/y/skills/mine]\nbody:text = for y\n' > "$l/a.layer"
path_list "a:/Corp:$l"
dcf-registry resolve --as /Corp/x >/dev/null 2>&1; dcf-registry resolve --as /Corp/y >/dev/null 2>&1
check "per path: a view kept for /Corp/x" "for x" "$(tail -n 1 "$(P +Corp+x)/skills/mine/SKILL.md" 2>/dev/null)"
check "per path: a view kept for /Corp/y" "for y" "$(tail -n 1 "$(P +Corp+y)/skills/mine/SKILL.md" 2>/dev/null)"
check "per path: view is the latest resolve" /Corp/y "$(cat "$(V)/whoami")"
check "per path: two views on disk" 2 "$(find "$COMPONENT_REGISTRY_STATE_DIR/views" -mindepth 1 -maxdepth 1 | wc -l)"
: > "$T/rec-log"
PATH="$RP" dcf-registry handover rec ax /fx --as /Corp/x >/dev/null 2>&1
PATH="$RP" dcf-registry handover rec ay /fy --as /Corp/y >/dev/null 2>&1
PATH="$RP" dcf-registry handover rec az /fz --as /Corp/x >/dev/null 2>&1
check "two agents, two paths: each gets its own path's skills" "skills ax /fx /Corp/x for x|skills ay /fy /Corp/y for y|skills az /fz /Corp/x for x" "$(paste -sd'|' "$T/rec-log")"
check "same path: one view shared" "$(readlink -f "$(P +Corp+x)")" "$(grep -c . "$COMPONENT_REGISTRY_STATE_DIR/handovers.tsv" >/dev/null; readlink -f "$(P +Corp+x)")"
check "records: one line per agent" 3 "$(dcf-registry handovers | grep -c .)"
check "records: an agent's own path is mode as" "rec	ax	/fx	/Corp/x	as	split" "$(dcf-registry handovers | grep -P '\tax\t')"
out="$(PATH="$RP" dcf-registry handover rec aq /fq --as /Corp/never 2>&1)"; rc=$?
check "handover --as a path never resolved: exit 1" 1 "$rc"
contains "handover --as a path never resolved: says how" "$out" "resolve --as /Corp/never"
: > "$T/rec-log"
COMPONENT_REGISTRY_WHOAMI=/Corp/x PATH="$RP" dcf-registry handover rec aw /fw >/dev/null 2>&1
check "no --as: the who-you-are setting's view, not the latest" "skills aw /fw /Corp/x for x" "$(cat "$T/rec-log")"
check "no --as: recorded mode whoami" "rec	aw	/fw	/Corp/x	whoami	split" "$(dcf-registry handovers | grep -P '\taw\t')"
out="$(dcf-registry explain skills/mine --as /Corp/x 2>&1)"
contains "explain --as a path with its own view, not the latest" "$out" "resolved for /Corp/x"
# a resolve keeps every path's view (an agent may not have been handed its skills yet) and drops
# the views no pointer names; forget drops the pointers no record names (below)
dcf-registry resolve --as /Corp/z >/dev/null 2>&1; dcf-registry resolve --as /Corp/y >/dev/null 2>&1
check "prune: a resolve keeps an unrecorded path's view" yes "$([ -f "$(P +Corp+z)/whoami" ] && echo yes || echo no)"
check "prune: a recorded path's view stays" yes "$([ -f "$(P +Corp+x)/whoami" ] && echo yes || echo no)"
check "prune: only views a pointer names stay (x, y, z)" 3 "$(find "$COMPONENT_REGISTRY_STATE_DIR/views" -mindepth 1 -maxdepth 1 | wc -l)"
# refresh --session: the calling agent alone, for its own path
printf '[/Corp/x/skills/mine]\nbody:text = for x, changed\n' > "$l/b.layer"
printf 'ax\tsid-ax\trunning\t/fx\n' > "$T/rec-list"
: > "$T/rec-log"
out="$(PATH="$RP" dcf-registry refresh --session sid-ax 2>&1)"; rc=$?
check "refresh --session: exit 0" 0 "$rc"
contains "refresh --session: names the agent and its path" "$out" "refreshing ax (rec) for /Corp/x, its own path"
check "refresh --session: that agent alone, the new text" "skills ax /fx /Corp/x for x, changed" "$(cat "$T/rec-log")"
: > "$T/rec-log"
out="$(PATH="$RP" dcf-registry refresh --session no-such-session 2>&1)"
contains "refresh --session unknown: says so" "$out" "is no agent the registry has handed skills to"
check "refresh --session unknown: every recorded hand-over" 4 "$(grep -c '^skills ' "$T/rec-log")"
check "refresh: each path resolved once" 1 "$(printf '%s\n' "$out" | grep -c 'resolving for /Corp/x')"
: > "$T/rec-log"
# shellcheck disable=SC2016  # the literal text another CLI leaves in the skill
PATH="$RP" dcf-registry refresh --session '${CLAUDE_SESSION_ID}' >/dev/null 2>&1
check "refresh --session not substituted: taken as none, everything refreshed" 4 "$(grep -c '^skills ' "$T/rec-log")"
# forget
: > "$T/rec-log"
out="$(PATH="$RP" dcf-registry forget rec ay /fy 2>&1)"; rc=$?
check "forget: exit 0" 0 "$rc"
check "forget: the adapter drops the agent's copies" "forget ay /fy" "$(cat "$T/rec-log")"
check "forget: the record goes" 0 "$(dcf-registry handovers | grep -cP '\tay\t')"
check "forget: a path no record names loses its view" no "$([ -e "$(P +Corp+z)" ] && echo yes || echo no)"
lw="$(cat "$(V)/whoami")"
check "forget: the latest view's path keeps its view" yes "$([ -f "$(P "${lw//\//+}")/whoami" ] && echo yes || echo no)"
check "forget: a recorded path keeps its view" yes "$([ -f "$(P +Corp+x)/whoami" ] && echo yes || echo no)"
dcf-registry forget rec >/dev/null 2>&1; check "forget without name and folder: exit 2" 2 $?
# the skills mode (ADR-0074): --skills-mode, else COMPONENT_REGISTRY_SKILLS_MODE, else split
: > "$T/rec-mode"
PATH="$RP" dcf-registry handover rec ax /fx --as /Corp/x >/dev/null 2>&1
check "skills mode: the default is split, given to the adapter" "ax split" "$(tail -n 1 "$T/rec-mode")"
COMPONENT_REGISTRY_SKILLS_MODE=shared PATH="$RP" dcf-registry handover rec ax /fx --as /Corp/x >/dev/null 2>&1
check "skills mode: the setting (environment) applies" "ax shared" "$(tail -n 1 "$T/rec-mode")"
printf 'COMPONENT_REGISTRY_SKILLS_MODE=shared\n' > .env
PATH="$RP" dcf-registry handover rec ax /fx --as /Corp/x >/dev/null 2>&1
check "skills mode: the setting (.env) applies" "ax shared" "$(tail -n 1 "$T/rec-mode")"
check "skills mode: recorded" "rec	ax	/fx	/Corp/x	as	shared" "$(dcf-registry handovers | grep -P '\tax\t')"
PATH="$RP" dcf-registry handover rec ax /fx --as /Corp/x --skills-mode split >/dev/null 2>&1
check "skills mode: --skills-mode (the agents list) beats the setting" "ax split" "$(tail -n 1 "$T/rec-mode")"
rm -f .env
COMPONENT_REGISTRY_SKILLS_MODE=shared PATH="$RP" dcf-registry handover rec az /fz --as /Corp/x >/dev/null 2>&1
: > "$T/rec-mode"
PATH="$RP" dcf-registry refresh >/dev/null 2>&1
check "skills mode: refresh repeats each agent's recorded mode" "ax split|az shared" "$(grep -E '^a[xz] ' "$T/rec-mode" | sort | paste -sd'|')"
out="$(PATH="$RP" dcf-registry handover rec ax /fx --as /Corp/x --skills-mode sometimes 2>&1)"; rc=$?
check "skills mode: a bad value is refused (exit 2)" 2 "$rc"
contains "skills mode: says the values" "$out" "not split, shared or off"
: > "$T/rec-log"
PATH="$RP" dcf-registry handover rec az /fz --as /Corp/x --skills-mode off >/dev/null 2>&1
check "skills mode off: the adapter drops the agent's copies" "forget az /fz" "$(cat "$T/rec-log")"
check "skills mode off: no record" 0 "$(dcf-registry handovers | grep -cP '\taz\t')"
out="$(PATH="$RP" dcf-registry handovers --skills 2>&1)"
contains "handovers --skills: the agent, its path and mode" "$out" "ax (rec, /fx): path /Corp/x (its registry-path), registry skills split"
contains "handovers --skills: its own folder" "$out" "  own folder: /own/ax"
contains "handovers --skills: its own skills" "$out" "  own skills: mine"
contains "handovers --skills: the shared ones" "$out" "  shared (/shared): shared"
# a namespaced layer (1.7.0): each path's view holds the namespaced skill by its folder name, and the
# hand-over of that path gives it to the agent
new_case perpathns
ln="$(layer acme)"
printf '[/Corp/x/skills/review]\nbody:text = acme for x\n[/Corp/y/skills/review]\nbody:text = acme for y\n' > "$ln/a.layer"
printf 'layers:\n  - id: acme\n    at: /Corp\n    namespace: acme\n    sources:\n      - { kind: path, path: "%s" }\n' "$ln" > .devcontainer/registry.yml
dcf-registry resolve --as /Corp/x >/dev/null 2>&1; dcf-registry resolve --as /Corp/y >/dev/null 2>&1
check "namespaced, per path: /Corp/x's view holds acme--review" "acme for x" "$(tail -n 1 "$(P +Corp+x)/skills/acme--review/SKILL.md" 2>/dev/null)"
check "namespaced, per path: /Corp/y's view holds its own" "acme for y" "$(tail -n 1 "$(P +Corp+y)/skills/acme--review/SKILL.md" 2>/dev/null)"
out="$(PATH="$RP" dcf-registry handover rec nx /fx --as /Corp/x 2>&1)"
contains "namespaced, per path: the hand-over names it by its folder name" "$out" "namespaced skills are handed over by their folder name"
# the lock: two resolves for two paths at once both finish, each with its own view
new_case perpathlock
l="$(layer a)"; printf '[/**/skills/shared]\nbody:text = same\n' > "$l/a.layer"; path_list "a:/Corp:$l"
dcf-registry resolve --as /Corp/p >/dev/null 2>&1 & p1=$!
dcf-registry resolve --as /Corp/q >/dev/null 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
check "lock: two paths resolved at once, both exit 0" "0 0" "$r1 $r2"
check "lock: the first path's view is there" yes "$([ -f "$(P +Corp+p)/whoami" ] && echo yes || echo no)"
check "lock: the second path's view is there" yes "$([ -f "$(P +Corp+q)/whoami" ] && echo yes || echo no)"

# ---------------------------- release 1.3.0: heading: false and front matter values ----
new_case heading
ha="$(layer ha)"; hb="$(layer hb)"; hc="$(layer hc)"
mkdir -p "$ha/s"
printf '%s\n' '---' 'name: s' 'description: the base says' 'allowed-tools: Read' '---' '' '# S' '' 'Base text.' > "$ha/s/SKILL.md"
printf '[skills/s]\nbody:text = @file s/SKILL.md\n' > "$ha/a.layer"
printf '[skills/s]\nbody:text = Middle one.\nbody:text = Middle two.\ndescription:value = the middle says\n' > "$hb/b.layer"
printf '[skills/s]\nbody:text = Top text.\ndescription:value = the top says\n' > "$hc/c.layer"
printf 'layers:\n  - id: ha\n    at: /\n    heading: false\n    sources:\n      - { kind: path, path: "%s" }\n  - id: hb\n    at: /\n    heading: false\n    sources:\n      - { kind: path, path: "%s" }\n  - id: hc\n    at: /\n    sources:\n      - { kind: path, path: "%s" }\n' "$ha" "$hb" "$hc" > .devcontainer/registry.yml
dcf-registry resolve --as /x >/dev/null 2>&1; check "heading: resolve succeeds" 0 $?
expected="$(printf '%s\n' '---' 'name: s' 'description: the top says' 'allowed-tools: Read' '---' '' '# S' '' 'Base text.' '' 'Middle one.' '' 'Middle two.' '' '## Layer hc' '' 'Top text.')"
check "heading: false stacks without a heading, keeps the blank line after the front matter; a layer without it keeps its heading; description is the strongest value" "$expected" "$(cat "$(V)/skills/s/SKILL.md")"
out="$(dcf-registry explain skills/s:body --as /x 2>&1)"
contains "heading: false: explain still names each line's layer (ha)" "$out" "used         ha@"
contains "heading: false: explain still names each line's layer (hb)" "$out" "used         hb@"
contains "front matter: explain says the value is written into the front matter" "$(dcf-registry explain skills/s:description --as /x 2>&1)" "written into SKILL.md's front matter"
sed -i 's/    heading: false/    heading: maybe/' .devcontainer/registry.yml
out="$(dcf-registry resolve --as /x 2>&1)"; rc=$?
check "heading: a value other than true or false is refused (exit 2)" 2 "$rc"
contains "heading: the refusal names the line" "$out" "heading is true or false"
# Front matter values: added when the body has none, name too; a permission key stays the lowest's.
nc_="$(layer nofm)"
printf '[skills/t]\nbody:text = Just text.\nname:value = t\n' > "$nc_/a.layer"
mkdir -p "$nc_/u"; printf '%s\n' '---' 'name: u' 'description: >' '  folded over' '  two lines' 'model: x' '---' '' 'U.' > "$nc_/u/SKILL.md"
printf '[skills/u]\nbody:text = @file u/SKILL.md\ndescription:value = one line now\n' >> "$nc_/a.layer"
printf '[skills/t]\ndescription:value = added on top\nname:value = t2\n[skills/s]\nallowed-tools:value = Bash\n' > "$hc/d.layer"
printf 'layers:\n  - id: ha\n    at: /\n    heading: false\n    sources:\n      - { kind: path, path: "%s" }\n  - id: nofm\n    at: /\n    heading: false\n    sources:\n      - { kind: path, path: "%s" }\n  - id: hc\n    at: /\n    heading: false\n    sources:\n      - { kind: path, path: "%s" }\n' "$ha" "$nc_" "$hc" > .devcontainer/registry.yml
dcf-registry resolve --as /x >/dev/null 2>&1; check "front matter: resolve succeeds" 0 $?
check "front matter: made for a body without one, name and description from the strongest values" "$(printf '%s\n' '---' 'name: t2' 'description: added on top' '---' '' 'Just text.')" "$(cat "$(V)/skills/t/SKILL.md")"
contains "front matter: a permission key in a higher layer is not written (the lowest's stays)" "$(sed -n 4p "$(V)/skills/s/SKILL.md")" "allowed-tools: Read"
lacks "front matter: allowed-tools is never set from a value" "$(cat "$(V)/skills/s/SKILL.md")" "Bash"
check "front matter: a multi-line description is replaced whole, the keys after it kept" "$(printf '%s\n' '---' 'name: u' 'description: one line now' 'model: x' '---' '' 'U.')" "$(cat "$(V)/skills/u/SKILL.md")"

# ------------------------------------------- release 1.6.0: agent definitions ----
new_case agents
aa="$(layer corp)"; ab="$(layer dept)"; ac="$(layer mine)"
cat > "$aa/a.layer" <<'EOF'
[/Corp/agents/*]
model:value = sonnet
[agents/reviewer]
skills:list = ref:skills/review, ref:skills/diagrams
kind:value = resident
allowed-tools:list = Bash
[skills/review]
body:text = Review.
EOF
cat > "$ab/b.layer" <<'EOF'
[agents/reviewer]
model:value = opus
args:list = --dangerously-skip-permissions
definition:value = boss
model:value = two words
model:list = x
skills:value = one
color:value = red
EOF
cat > "$ac/c.layer" <<'EOF'
[/**/agents/reviewer]
skills:list = !ref:skills/diagrams, plan, ref:/Corp/skills/review:body, bad/one
EOF
path_list "corp:/Corp:$aa" "dept:/Corp/MyDepartment:$ab" "mine:$W:$ac"
out="$(COMPONENT_REGISTRY_AGENTS=host,reviewer,bad.name dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check "agents: resolve succeeds" 0 "$rc"
check "agents: model is the strongest value" opus "$(cat "$(V)/agents/reviewer/model" 2>/dev/null)"
check "agents: skills combined, !item removed, a ref gives its skill name, one name per line" "$(printf '%s\n' review plan)" "$(cat "$(V)/agents/reviewer/skills" 2>/dev/null)"
check "agents: a pattern [agents/*] reaches an agent named only in COMPONENT_REGISTRY_AGENTS" sonnet "$(cat "$(V)/agents/host/model" 2>/dev/null)"
check "agents: the requested names are kept in the view, a bad one left out" "$(printf '%s\n' host reviewer)" "$(cat "$(V)/agent-names")"
contains "agents: a bad requested name is said" "$out" "'bad.name' is not an agent name"
contains "agents: from.tsv names the layer and line of the model" "$(cat "$(V)/agents/reviewer/from.tsv")" "$(printf 'model\tdept\t1:b.layer:2')"
contains "agents: from.tsv names every layer of the skills" "$(cat "$(V)/agents/reviewer/from.tsv")" "$(printf 'skills\tmine\t1:c.layer:2')"
lacks "agents: from.tsv holds no skipped line" "$(cat "$(V)/agents/reviewer/from.tsv")" "kind"
contains "agents: a field the list owns is skipped (kind)" "$out" "agents/reviewer:kind: the agents list owns kind; the registry never sets it"
contains "agents: args is skipped as a possible widening" "$out" "agents/reviewer:args: the agents list owns args; the registry never sets it for an agent; it could widen a permission"
contains "agents: definition is skipped as a possible widening" "$out" "agents/reviewer:definition: the agents list owns definition"
contains "agents: a permission key is skipped even in the lowest layer" "$out" "agents/reviewer:allowed-tools: an agent definition carries no permission key"
contains "agents: a model of two words is skipped" "$out" "agents/reviewer:model: a model is one word"
contains "agents: model of another type is skipped" "$out" "model is one value: model:value = <model>"
contains "agents: skills of another type is skipped" "$out" "skills is a list"
contains "agents: an unknown field is skipped" "$out" "agents/reviewer:color: not an agent definition field (model, model.<cli>, skills)"
contains "agents: a skills item that names no skill is reported" "$out" "item 'bad/one' names no skill"
check "agents: a ref item is checked like any ref" ok "$(awk -F'\t' '$1 == "agents/reviewer" && $3 == "skills/review" { print $6; exit }' "$(V)/meta/refs.tsv")"
contains "agents: explain --uses lists the agent that names a skill" "$(dcf-registry explain skills/review --uses)" "agents/reviewer:skills -> skills/review"
ex="$(dcf-registry explain agents/reviewer)"
contains "agents: explain shows the model's lines" "$ex" "model:value = opus"
contains "agents: explain shows the overridden pattern line" "$ex" "overridden   corp@"
contains "agents: explain shows a skipped field and why" "$ex" "kind:value = resident  (the agents list owns kind"
contains "agents: explain says where the participant reads it" "$ex" "the participant reads model and skills from"
check "agents: an agent the pattern gives only a model has no skills file" no "$([ -e "$(V)/agents/host/skills" ] && echo yes || echo no)"
check "agents: the agents folder is owner-only" 700 "$(stat -c %a "$(V)/agents/reviewer")"
out="$(dcf-registry resolve --as "$W" 2>&1)"
check "agents: a later resolve without COMPONENT_REGISTRY_AGENTS keeps the view's names" sonnet "$(cat "$(V)/agents/host/model" 2>/dev/null)"
out="$(COMPONENT_REGISTRY_AGENTS='' dcf-registry resolve --as "$W" 2>&1)"
check "agents: an empty COMPONENT_REGISTRY_AGENTS clears them" no "$([ -e "$(V)/agents/host" ] && echo yes || echo no)"
check "agents: an agent a section names literally is still resolved" opus "$(cat "$(V)/agents/reviewer/model" 2>/dev/null)"
out="$(dcf-registry resolve --as /Corp/Finance/x 2>&1)"
check "agents: another path gets only the lines that apply to it (corp's pattern, not dept's opus)" sonnet "$(cat "$(V)/agents/reviewer/model" 2>/dev/null)"

# model.<cli> (the Operator's ruling of 2026-11-21): a model for agents of one CLI; it beats a plain
# model at the same layer and path, and loses to a higher layer's or a more specific path's plain one
new_case agentcli
ma="$(layer corp)"; mb="$(layer dept)"
cat > "$ma/a.layer" <<'EOF'
[/Corp/agents/*]
model:value = sonnet
model.copilot:value = gpt-5.4
model.nosuchcli:value = whatever
[/Corp/agents/ops]
model.claude:value = haiku
[/Corp/agents/rev]
model.claude:value = opus
lock model
EOF
cat > "$mb/b.layer" <<'EOF'
[/Corp/agents/ops]
model:value = big-dept
[/Corp/agents/rev]
model.claude:value = dept-tries
EOF
path_list "corp:/Corp:$ma" "dept:/Corp/MyDepartment:$mb"
out="$(COMPONENT_REGISTRY_AGENTS=host:claude,pair:copilot,odd:codex,ops:claude,rev:claude,bare dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check "model.<cli>: resolve succeeds" 0 "$rc"
check "model.<cli>: a claude agent under [agents/*] gets the plain model" sonnet "$(cat "$(V)/agents/host/model" 2>/dev/null)"
check "model.<cli>: a copilot agent under [agents/*] gets model.copilot (same layer and path: the suffix wins)" gpt-5.4 "$(cat "$(V)/agents/pair/model" 2>/dev/null)"
check "model.<cli>: a CLI with no suffixed key gets the plain model" sonnet "$(cat "$(V)/agents/odd/model" 2>/dev/null)"
check "model.<cli>: an agent with no CLI named gets the plain model" sonnet "$(cat "$(V)/agents/bare/model" 2>/dev/null)"
check "model.<cli>: a higher layer's plain model beats a lower layer's suffixed one" big-dept "$(cat "$(V)/agents/ops/model" 2>/dev/null)"
check "model.<cli>: the view records the CLI it resolved for" copilot "$(cat "$(V)/agents/pair/cli" 2>/dev/null)"
contains "model.<cli>: from.tsv names the key the model came from" "$(cat "$(V)/agents/pair/from.tsv")" "$(printf 'model\tcorp\t1:a.layer:3\tmodel.copilot')"
contains "model.<cli>: from.tsv names the plain key when it wins" "$(cat "$(V)/agents/ops/from.tsv")" "$(printf 'model\tdept\t1:b.layer:2\tmodel')"
check "model.<cli>: a lock on model holds model.<cli> in a higher layer" opus "$(cat "$(V)/agents/rev/model" 2>/dev/null)"
contains "model.<cli>: the locked line is reported" "$out" "a lock on model holds every model.<cli>"
contains "model.<cli>: explain shows the effective model, its key and layer" "$(dcf-registry explain agents/pair)" "Effective model for its CLI, copilot: gpt-5.4 (model.copilot from corp at 1:a.layer:3)"
lacks "model.<cli>: an unknown suffix is no problem" "$out" "nosuchcli"
: > "$mb/b.layer"
cat > "$ma/a.layer" <<'EOF'
[/Corp/agents/*]
model.copilot:value = gpt-5.4
[/Corp/MyDepartment/agents/*]
model:value = deeper-same-layer
EOF
out="$(COMPONENT_REGISTRY_AGENTS=pair:copilot dcf-registry resolve --as "$W" 2>&1)"
check "model.<cli>: a more specific path's plain model beats a less specific suffixed one (same layer)" deeper-same-layer "$(cat "$(V)/agents/pair/model" 2>/dev/null)"

# ------------------------------------------------- release 1.7.0: layer namespaces ----
new_case namespace
nm_="$(layer mine)"; nc_="$(layer community)"; na_="$(layer adapt)"; nb_="$(layer beta)"; nt_="$(layer top)"
cat > "$nm_/m.layer" <<'EOF'
[skills/arch-review]
body:text = Mine.
[skills/*]
tone:value = mine
[skills/plain]
body:text = Plain.
back:ref = skills/acme:arch-review
[skills/acme--x]
body:text = The Operator's own acme--x.
[skills/plain]
own:ref = skills/arch-review
[agents/reviewer]
skills:list = acme:arch-review, plain, pub:helper
EOF
mkdir -p "$nc_/ar"
printf '%s\n' '---' 'name: arch-review' 'description: community review' '---' '' 'Community text.' > "$nc_/ar/SKILL.md"
cat > "$nc_/c.layer" <<'EOF'
[skills/*]
color:value = community
[skills/arch-review]
body:text = @file ar/SKILL.md
style:value = strict
lock style
allowed-tools:value = Read
see:ref = skills/helper
out:ref = skills/plain
[skills/helper]
body:text = Community helper.
[skills/x]
body:text = Community x.
[agents/reviewer]
model:value = evil-model
skills:list = arch-review, other:thing
[skills/arch-review]
cross:ref = skills/beta:arch-review
dep:ref = skills/lint-tools:lint
EOF
cat > "$na_/a.layer" <<'EOF'
[skills/arch-review]
body:text = Adapted.
style:value = loose
allowed-tools:value = Bash
name:value = arch-review
[skills/helper] @replace
body:text = Replaced helper.
[skills/arch-review]
al:ref = skills/pub:arch-review
EOF
printf '[skills/arch-review]\nbody:text = Beta.\n' > "$nb_/b.layer"
printf '[skills/arch-review]\nbody:text = Top.\n' > "$nt_/t.layer"
cat > .devcontainer/registry.yml <<EOF
layers:
  - id: mine
    at: /Corp
    aliases: { pub: acme }
    sources:
      - { kind: path, path: "$nm_" }
  - id: community
    at: /
    namespace: acme
    sources:
      - { kind: path, path: "$nc_" }
  - id: beta
    at: /
    namespace: beta
    sources:
      - { kind: path, path: "$nb_" }
  - id: adapt
    at: /Corp
    namespace: acme
    aliases: { pub: beta }
    sources:
      - { kind: path, path: "$na_" }
  - id: top
    at: /Corp
    sources:
      - { kind: path, path: "$nt_" }
EOF
out="$(COMPONENT_REGISTRY_AGENTS=reviewer:claude dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check "namespace: resolve succeeds" 0 "$rc"
check "namespace: the Operator's own skill is untouched by the namespaced layers" "$(printf '%s\n' '## Layer mine' '' 'Mine.' '' '## Layer top' '' 'Top.')" "$(cat "$(V)/skills/arch-review/SKILL.md")"
check "namespace: a namespaced skill lands as <ns>--<name>, two layers of one namespace stacked in order, its SKILL.md named by its folder" \
  "$(printf '%s\n' '---' 'name: acme--arch-review' 'description: community review' '---' '## Layer community' '' 'Community text.' '' '## Layer adapt' '' 'Adapted.')" "$(cat "$(V)/skills/acme--arch-review/SKILL.md")"
check "namespace: two namespaces never mix (beta has only its own text)" "$(printf '%s\n' '---' 'name: beta--arch-review' '---' '## Layer beta' '' 'Beta.')" "$(cat "$(V)/skills/beta--arch-review/SKILL.md")"
check "namespace: no folder with a ':' in the view's skills" "" "$(find "$(V)/skills" -name '*:*')"
check "namespace: the metadata keeps the registry name" strict "$(val skills/acme:arch-review style)"
contains "namespace: a lock inside the namespace holds against its higher layer" "$out" "adapt 1:a.layer:3 skills/acme:arch-review:style: locked by community"
check "namespace: a permission key comes from the namespace's lowest layer" Read "$(val skills/acme:arch-review allowed-tools)"
contains "namespace: a higher layer's permission key in the namespace is skipped" "$out" "skills/acme:arch-review:allowed-tools: a permission key is taken from the component's lowest layer only"
check "namespace: @replace inside the namespace drops the weaker line" "$(printf '%s\n' '## Layer adapt' '' 'Replaced helper.')" "$(val skills/acme:helper body)"
check "namespace: an un-namespaced [skills/*] never reaches a namespaced skill" "" "$(val skills/acme:arch-review tone)"
check "namespace: a namespaced [skills/*] never reaches the Operator's skill" "" "$(val skills/arch-review color)"
check "namespace: the un-namespaced [skills/*] still reaches the Operator's own" mine "$(val skills/plain tone)"
check "namespace: the namespaced [skills/*] reaches its own namespace's skills" community "$(val skills/acme:arch-review color)"
contains "namespace: name:value in a namespace is never written into SKILL.md" "$(dcf-registry explain skills/acme:arch-review:name)" "not written into SKILL.md: a namespaced skill is named acme--arch-review there"
refs="$(cat "$(V)/meta/refs.tsv")"
contains "namespace: a ref inside a namespace resolves inside it" "$refs" "$(printf 'skills/acme:arch-review\tsee\tskills/helper\tskills/acme:helper\t-\tok')"
contains "namespace: a plain ref inside a namespace is its own namespace's, never the Operator's" "$refs" "$(printf 'skills/acme:arch-review\tout\tskills/plain\tskills/acme:plain\t-\tmissing')"
contains "namespace: an explicit ref from the Operator's layer into a namespace resolves" "$refs" "$(printf 'skills/plain\tback\tskills/acme:arch-review\tskills/acme:arch-review\t-\tok')"
contains "namespace: a namespaced skill named like an un-namespaced one's folder is not resolved" "$out" "skills/acme:x would be handed over as acme--x, the name of the un-namespaced skill skills/acme--x"
check "namespace: the Operator's skill keeps that folder" "$(printf '%s\n' '## Layer mine' '' "The Operator's own acme--x.")" "$(cat "$(V)/skills/acme--x/SKILL.md")"
check "namespace: an agent definition in a namespace never reaches the listed agent" no "$([ -e "$(V)/agents/reviewer/model" ] && echo yes || echo no)"
check "namespace: a namespaced agent definition is <ns>:<name> in the view" evil-model "$(cat "$(V)/agents/acme:reviewer/model" 2>/dev/null)"
check "namespace: the Operator's agent names a namespaced skill as <ns>:<name> (and through its layer's alias), handed over as <ns>--<name>" "$(printf '%s\n' acme--arch-review plain acme--helper)" "$(cat "$(V)/agents/reviewer/skills")"
check "namespace: a namespaced agent's plain skills are its namespace's, an explicit one another's" "$(printf '%s\n' acme--arch-review other--thing)" "$(cat "$(V)/agents/acme:reviewer/skills")"
check "namespace: namespaced.tsv maps the registry name to the folder" "$(printf 'skills/acme:arch-review\tacme\tskills/acme--arch-review')" "$(grep '^skills/acme:arch-review' "$(V)/meta/namespaced.tsv")"
# explicit references (the Operator's ruling N2, 2026-11-21): no prefix is the own namespace,
# <ns>:<name> any namespace from any layer; a missing target is a missing dependency; aliases
check "refs: a plain ref in the Operator's layer is the Operator's own" "skills/arch-review|ok" "$(awk -F'\t' '$1 == "skills/plain" && $2 == "own" { print $4 "|" $6 }' "$(V)/meta/refs.tsv")"
check "refs: an explicit ref from one namespace to another resolves" "skills/beta:arch-review|ok" "$(awk -F'\t' '$1 == "skills/acme:arch-review" && $2 == "cross" { print $4 "|" $6 }' "$(V)/meta/refs.tsv")"
check "refs: a missing namespace is a missing dependency" missing "$(awk -F'\t' '$1 == "skills/acme:arch-review" && $2 == "dep" { print $6 }' "$(V)/meta/refs.tsv")"
contains "refs: resolve names the referrer, the layer and the target of a missing dependency" "$out" "missing dependency: skills/acme:arch-review:dep in layer community -> skills/lint-tools:lint (no component skills/lint-tools:lint for $W; no layer of the list has namespace lint-tools)"
check "refs: a missing dependency does not stop resolve" 0 "$rc"
check "refs: an alias resolves before lookup" "skills/beta:arch-review|ok" "$(awk -F'\t' '$1 == "skills/acme:arch-review" && $2 == "al" { print $4 "|" $6 }' "$(V)/meta/refs.tsv")"
ex="$(dcf-registry explain skills/acme:arch-review)"
contains "refs: explain shows the alias" "$ex" "[pub:arch-review -> beta:arch-review (alias on adapt)]"
contains "refs: explain shows a plain ref resolved in the own namespace" "$ex" "out:ref = skills/plain"
contains "refs: explain shows the missing dependency of a namespace's plain ref" "$ex" "skills/acme:arch-review:out -> skills/plain = skills/acme:plain (missing dependency)"
contains "refs: explain lists missing dependencies with their layer" "$ex" "skills/acme:arch-review:dep -> skills/lint-tools:lint [namespace acme] (no component skills/lint-tools:lint"
contains "refs: explain --uses on a missing target says missing dependency" "$(dcf-registry explain skills/lint-tools:lint --uses)" "skills/acme:arch-review:dep -> skills/lint-tools:lint = skills/lint-tools:lint (missing dependency) [namespace acme]"
contains "refs: explain --uses shows an alias" "$(dcf-registry explain skills/beta:arch-review --uses)" "skills/acme:arch-review:al -> skills/pub:arch-review = skills/beta:arch-review (ok) [pub:arch-review -> beta:arch-review (alias on adapt)] [namespace acme]"
contains "refs: explain lists a layer's aliases" "$ex" "adapt at /Corp, source 1 (path):"
contains "refs: explain lists a layer's aliases (marker)" "$ex" ", aliases pub=beta"
ex="$(dcf-registry explain skills/acme:arch-review)"
contains "namespace: explain says the namespace and the hand-over name" "$ex" "Namespace acme: only the layers with namespace: acme reach it; handed over as acme--arch-review"
contains "namespace: explain shows the namespace on each line" "$ex" "used         adapt@"
contains "namespace: explain shows the namespace on each line (marker)" "$ex" "[namespace acme] 1:a.layer:2  body:text = Adapted."
contains "namespace: explain lists the layers with their namespace" "$ex" "adapt at /Corp, source 1 (path): fetched"
contains "namespace: explain lists the layers with their namespace (marker)" "$ex" ", namespace acme"
check "namespace: explain takes the folder name too" "$(dcf-registry explain skills/acme:arch-review:style)" "$(dcf-registry explain skills/acme--arch-review:style)"
contains "namespace: explain ns:name:key picks the key" "$(dcf-registry explain skills/acme:arch-review:style)" "style:value = strict [namespace acme]"
contains "namespace: explain --uses shows the resolved target and namespace" "$(dcf-registry explain skills/acme:helper --uses)" "skills/acme:arch-review:see -> skills/helper = skills/acme:helper (ok) [namespace acme]"
contains "namespace: explain of a namespaced agent says it applies to no listed agent" "$(dcf-registry explain agents/acme:reviewer)" "applies to no agent of the agents list"
lacks "namespace: explain of the Operator's skill shows no namespace" "$(dcf-registry explain skills/arch-review)" "[namespace"
printf '[skills/acme:arch-review]\nbody:text = Sneaking in.\n' > "$nt_/t2.layer"
out="$(dcf-registry resolve --as "$W" 2>&1)"
contains "namespace: an un-namespaced section cannot name a namespaced component" "$out" "segment 'acme:arch-review' of [skills/acme:arch-review]"
lacks "namespace: ...and its text never reaches it" "$(cat "$(V)/skills/acme--arch-review/SKILL.md")" "Sneaking"
rm -f "$nt_/t2.layer"
# hand-over: the adapter gets the folders, and the line says the mapping
cat > "$bin/agent-adapter-nsfake" <<EOF
#!/usr/bin/env bash
case "\$1" in supports) echo skills ;; skills) ls "\$COMPONENT_REGISTRY_SKILLS" > "$C/handed" ;; esac
EOF
chmod +x "$bin/agent-adapter-nsfake"
out="$(dcf-registry handover nsfake 2>&1)"; rc=$?
check "namespace: handover succeeds" 0 "$rc"
contains "namespace: handover hands the folder name over" "$(cat "$C/handed")" "acme--arch-review"
contains "namespace: handover says the mapping" "$out" "nsfake: namespaced skills are handed over by their folder name, <namespace>--<name>: acme:arch-review as acme--arch-review"
rm -f "$bin/agent-adapter-nsfake"
# the namespace name: refused with file:line
nsbad() { # <name> <namespace> <expected>
  printf 'layers:\n  - id: a\n    at: /\n    namespace: %s\n    sources:\n      - { kind: path, path: "%s" }\n' "$2" "$nc_" > .devcontainer/registry.yml
  out="$(dcf-registry resolve --as "$W" 2>&1)"; rc=$?
  check "namespace: $1 is refused (exit 2)" 2 "$rc"; contains "namespace: $1 names the line" "$out" "$3"
}
nsbad "upper case" Acme ".devcontainer/registry.yml:4: layer a: namespace 'Acme' may hold only lower-case letters and digits"
nsbad "a double hyphen" a--b "namespace 'a--b' may hold only"
nsbad "a colon" "a:b" "namespace 'a:b' may hold only"
nsbad "a trailing hyphen" acme- "namespace 'acme-' may hold only"
nsbad "the base layer's id" component-registry "namespace 'component-registry' is reserved"
albad() { # <name> <aliases line> <expected>
  printf 'layers:\n  - id: a\n    at: /\n    namespace: acme\n    aliases: %s\n    sources:\n      - { kind: path, path: "%s" }\n' "$2" "$nc_" > .devcontainer/registry.yml
  out="$(dcf-registry resolve --as "$W" 2>&1)"; rc=$?
  check "aliases: $1 is refused (exit 2)" 2 "$rc"; contains "aliases: $1 names the line" "$out" "$3"
}
albad "a bad target name" "{ pub: Beta }" ".devcontainer/registry.yml:5: layer a: alias 'pub: Beta': 'Beta' is not a namespace name"
albad "the layer's own namespace as target" "{ pub: acme }" "alias 'pub: acme' involves the layer's own namespace acme"
albad "the layer's own namespace as alias" "{ acme: beta }" "alias 'acme: beta' involves the layer's own namespace acme"
albad "a chain" "{ pub: mid, mid: beta }" "alias 'pub: mid' leads to another alias (mid); an alias is one hop"
albad "a reserved target" "{ pub: component-registry }" "namespace 'component-registry' is reserved"
albad "itself" "{ pub: pub }" "alias 'pub: pub' names itself"
albad "a block map" "" "aliases must be a one-line map"
albad "twice" "{ pub: beta, pub: gamma }" "alias 'pub' appears twice in one layer"
printf 'layers:\n  - id: a\n    at: /\n    namespace: acme\n    namespace: beta\n    sources:\n      - { kind: path, path: "%s" }\n' "$nc_" > .devcontainer/registry.yml
contains "namespace: twice in one layer is refused" "$(dcf-registry resolve --as "$W" 2>&1)" "'namespace' appears twice in one layer"

# release 2.0.0: .layer only; .reg is not read; writable is ignored; remember is removed
new_case layerext
l="$(layer x)"; printf '[skills/x]\ncolor:value = blue\n' > "$l/a.layer"; path_list "x:/Corp:$l"
out="$(dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check ".layer: resolve exit 0" 0 "$rc"
check ".layer: the file is read" "blue" "$(val skills/x color)"
lacks ".layer: no .reg line" "$out" "not read since 2.0.0"
l="$(layer y)"; printf '[skills/y]\ncolor:value = red\n' > "$l/old.reg"; printf '[skills/y]\nsize:value = big\n' > "$l/new.layer"; path_list "y:/Corp:$l"
out="$(dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check ".reg: resolve still exits 0 (a warning, not an error)" 0 "$rc"
check ".reg: the file is not read" "" "$(val skills/y color)"
check ".reg: the .layer beside it is read" "big" "$(val skills/y size)"
contains ".reg: one line names the file" "$out" "layer y source 1: not read since 2.0.0: old.reg; rename to .layer"
l="$(layer r)"; printf '[skills/r]\nk:value = v\n' > "$l/only.reg"
printf 'layers:\n  - id: r\n    at: /Corp\n    required: true\n    sources:\n      - { kind: path, path: "%s" }\n' "$l" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check "required layer with only .reg: resolves with nothing (exit 0)" 0 "$rc"
contains "required layer with only .reg: says so" "$out" "not read since 2.0.0: only.reg"
new_case removed
lm="$(layer mine)"; printf '[skills/x]\nk:value = v\n' > "$lm/remembered.layer"
printf 'layers:\n  - id: mine\n    at: /Corp/me\n    writable: true\n    sources:\n      - { kind: path, path: "%s" }\n' "$lm" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp/me 2>&1)"; rc=$?
check "writable: the old registry.yml still resolves" 0 "$rc"
contains "writable: one warning that it is ignored" "$out" "layer mine: writable is ignored since 2.0.0: the registry does not write layers; edit the layer"
check "writable: one line per writable layer" 1 "$(grep -c 'writable is ignored' <<< "$out")"
check "remembered.layer is an ordinary layer file" "v" "$(val skills/x k)"
out="$(dcf-registry remember -- "x" 2>&1)"; rc=$?
check "remember: removed, exit 1" 1 "$rc"
contains "remember: says removed in 2.0.0 and to edit the layer" "$out" "removed in 2.0.0: edit your layer"
check "remember: wrote nothing" "remembered.layer" "$(find "$lm" -mindepth 1 -printf '%f\n')"
new_case nowritable
l="$(layer a)"; printf '[skills/x]\nk:value = v\n' > "$l/a.layer"; path_list "a:/Corp:$l"
lacks "no writable: no warning" "$(dcf-registry resolve --as "$W" 2>&1)" "writable is ignored"

echo "component-registry unit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
