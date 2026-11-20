#!/usr/bin/env bash
# Docker-free tests of the component-registry Feature (src/component-registry): the layer list
# (the YAML subset, flow maps, unknown keys refused with file:line, git and path sources checked),
# COMPONENT_REGISTRY_WHOAMI (required, with how to set it; .env; --as), the .reg grammar and the
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
# skills verb (fake adapters with and without it), refresh, and remember into the writable layer.
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
cat > "$l1/corp.reg" <<'EOF'
; layer 1 corp-base (at /Corp)
[skills/architecture-artifacts]
body:text = @file architecture-artifacts/SKILL.md
classification:value = internal
lock classification
EOF
mkdir -p "$l1/architecture-artifacts"
printf '%s\n' '# Architecture artifacts' '' 'Produce the artifacts.' > "$l1/architecture-artifacts/SKILL.md"
cat > "$l2/dept.reg" <<'EOF'
; layer 2 dept (at /Corp/MyDepartment)
[skills/architecture-artifacts]
body:text = Draw C4, not UML.
terms:list = C4, ADR, SLA
[/Corp/Finance/skills/architecture-artifacts]
body:text = Use the finance templates.
EOF
cat > "$l3/mine.reg" <<'EOF'
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
contains "worked example: resolve reports the locked line" "$out" "skipped mine 1:mine.reg:5 skills/architecture-artifacts:classification: locked by corp-base at 1:corp.reg:5"
expected="$(printf '%s\n' '## Layer corp-base' '' '# Architecture artifacts' '' 'Produce the artifacts.' '' '## Layer dept' '' 'Draw C4, not UML.' '' '## Layer mine' '' 'Use colour-blind-safe colours.')"
check "worked example: body is the corp SKILL.md, then dept's line, then mine's, under layer headings" "$expected" "$(cat "$(V)/skills/architecture-artifacts/SKILL.md")"
lacks "worked example: the finance line does not apply" "$(cat "$(V)/skills/architecture-artifacts/SKILL.md")" "finance"
check "worked example: terms is C4, SLA" "$(printf 'C4\nSLA')" "$(val skills/architecture-artifacts terms)"
check "worked example: classification stays internal (locked by layer 1)" internal "$(val skills/architecture-artifacts classification)"
ex="$(dcf-registry explain skills/architecture-artifacts)"
contains "worked example: explain shows layer 3's line skipped by the lock" "$ex" "skipped      mine@tree-"
contains "worked example: explain names the lock that skipped it" "$ex" "classification:value = public  (locked by corp-base at 1:corp.reg:5)"
contains "worked example: explain shows the finance line as not applying" "$ex" "not-applying dept@"
contains "worked example: explain shows each layer's version" "$ex" "1 corp-base at /Corp, source 1 (path): fetched, tree-"
contains "explain with :key shows that key only" "$(dcf-registry explain /Corp/skills/architecture-artifacts:terms)" "terms:list = C4, SLA"
lacks "explain with :key leaves the other keys out" "$(dcf-registry explain skills/architecture-artifacts:terms)" "classification"

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
l="$(layer a)"; printf '[skills/x]\ncolor:value = blue\n' > "$l/a.reg"
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
l="$(layer a)"; printf '[skills/x]\ncolor:value = blue\n' > "$l/a.reg"
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
cat > "$l1/one.reg" <<'EOF'
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
cat > "$l2/two.reg" <<'EOF'
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
printf '[skills/v]\nv:value = 1\n[!/Corp/**]\n' > "$l2/y-excl.reg"
printf 'not a line\n[skills/q\nk:number = 1\n[/Corp/agents/helper]\nmodel:value = big\n' > "$l2/z-broken.reg"
out="$(dcf-registry resolve --as "$W" 2>&1)"; rc=$?
check "merge fixtures resolve (content never fails a resolve)" 0 "$rc"
check "type clash: the lowest layer's type wins" blue "$(val skills/x color)"
contains "type clash: reported by resolve" "$out" "skills/x:color: type clash: color is value, fixed by one at 1:one.reg:3"
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
contains "@replace: explain shows the dropped lines" "$(dcf-registry explain skills/y)" "dropped by @replace in two at 1:two.reg:"
check "! exclusion section: the sections above it in the file no longer apply" 1 "$(val skills/z z)"
contains "! exclusion section: explain says what excluded the line" "$(dcf-registry explain skills/z)" "excluded by [!/Corp/MyDepartment/**/skills/z]"
check "an exclusion without a component excludes every section above it in its file" "" "$(val skills/v v)"
check "! exclusion section: it excludes only the component it names" blue "$(val skills/x color)"
contains "an unreadable line is reported with its place" "$out" "skipped two 1:z-broken.reg:1: not a section"
contains "an unknown type is reported" "$out" "type 'number' is none of value, list, text, ref"
contains "a bad section header is reported" "$out" "1:z-broken.reg:2: a section header needs a closing ]"
contains "a kind not in this release is reported" "$out" "kind agents is not in this release"
check "a kind not in this release is not resolved" no "$([ -e "$(V)/agents" ] && echo yes || echo no)"
check "ref: the strongest line's path" /skills/x "$(val skills/w w)"
contains "a ref to nothing is reported by resolve" "$out" "dangling ref: skills/w:gone -> skills/missing (no component skills/missing for $W)"
ex="$(dcf-registry explain skills/w)"
contains "explain lists a dangling ref" "$ex" "skills/w:gone -> skills/missing (no component skills/missing"
contains "a list ref: item to nothing is dangling" "$ex" "skills/w:lines -> /skills/nowhere"
contains "a ref to a missing key is dangling" "$ex" "skills/w:nokey -> skills/x:nothere (skills/x has no key nothere)"
lacks "a ref to an existing key is not dangling" "$ex" "skills/w:key ->"
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
cat > "$l/a.reg" <<'EOF'
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
l="$(layer present)"; printf '[skills/x]\ncolor:value = blue\n' > "$l/a.reg"
printf 'layers:\n  - id: corp\n    at: /Corp\n    required: true\n    sources:\n      - { kind: path, path: %s/nowhere }\n  - id: b\n    at: /Corp\n    sources:\n      - { kind: path, path: %s }\n' "$C/layers" "$l" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "a required layer never fetched: exit 1" 1 "$rc"
contains "a required layer never fetched: said" "$out" "layer corp source 1 (path) is required and has never been fetched"
check "a required layer never fetched: no view is made" no "$([ -e "$(V)" ] && echo yes || echo no)"
printf 'layers:\n  - id: corp\n    at: /Corp\n    sources:\n      - { kind: http, url: "https://registry.example.invalid/l.reg", required: true }\n' > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "a required http source (not in this release): exit 1" 1 "$rc"
contains "an http source says it is not in this release" "$out" "kind http is not in this release of component-registry"

new_case path
l="$(layer a)"; printf '[skills/x]\n' > "$l/a.reg"
v1="$(registry-source-path version a "path=$l")"
check "path source: version is a tree fingerprint" tree "${v1%%-*}"
sleep 0.01; echo more >> "$l/a.reg"
check "path source: a changed file changes the version" changed "$([ "$(registry-source-path version a "path=$l")" != "$v1" ] && echo changed)"
registry-source-path version a "path=$C/none" >/dev/null 2>&1; check "path source: a missing folder is exit 1" 1 $?
registry-source-path version a "url=x" >/dev/null 2>&1; check "path source: an unknown setting is exit 2" 2 $?
registry-source-path frobnicate >/dev/null 2>&1; check "path source: an unknown verb is exit 3" 3 $?
check "path source: supports lists its verbs" "fetch version supports" "$(registry-source-path supports | tr '\n' ' ' | sed 's/ $//')"
printf 'layers:\n  - id: a\n    at: /Corp\n    sources:\n      - { kind: path, path: rel-layer }\n' > .devcontainer/registry.yml
mkdir rel-layer; printf '[skills/r]\nk:value = relative\n' > rel-layer/r.reg
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
printf '[skills/g]\nv:value = one\n' > "$g/g.reg"
git -C "$g" add -A; git -C "$g" commit -qm one; git -C "$g" tag -a v1 -m v1; c1="$(git -C "$g" rev-parse HEAD)"
printf '[skills/g]\nv:value = two\n' > "$g/g.reg"; git -C "$g" commit -qam two; c2="$(git -C "$g" rev-parse HEAD)"
check "git source: version of a branch is its commit" "$c2" "$(registry-source-git version g "url=$g" branch=main)"
check "git source: version of an annotated tag is the tagged commit" "$c1" "$(registry-source-git version g "url=$g" tag=v1)"
registry-source-git version g "url=$g" tag=v9 >/dev/null 2>&1; check "git source: an unknown tag is exit 1" 1 $?
registry-source-git version g "url=$g" >/dev/null 2>&1; check "git source: no ref is exit 2" 2 $?
out="$(registry-source-git version g "url=$g" branch=main auth.secret=registry/bad 2>&1)"; rc=$?
check "git source: a secret dcf-secret cannot read is exit 1" 1 "$rc"
contains "git source: a secret dcf-secret cannot read is named" "$out" "dcf-secret could not read registry/bad"
mkdir "$C/dest"; registry-source-git fetch g "$C/dest" "url=$g" "commit=$c1" >/dev/null 2>&1
check "git source: fetch at a commit" "v:value = one" "$(sed -n 2p "$C/dest/g.reg")"
check "git source: no .git in the layer copy" no "$([ -e "$C/dest/.git" ] && echo yes || echo no)"
printf 'layers:\n  - id: g\n    at: /Corp\n    sources:\n      - { kind: git, url: "%s", tag: v1 }\n  - id: h\n    at: /Corp\n    sources:\n      - kind: git\n        url: "%s"\n        branch: main\n        auth: { type: basic, secret: registry/none }\n' "$g" "$g" > .devcontainer/registry.yml
out="$(dcf-registry resolve --as /Corp 2>&1)"; rc=$?
check "git source: resolve exits 0" 0 "$rc"
contains "git source: fetched at the tag's commit" "$out" "layer g source 1 (git): fetched $c1"
check "git source: the higher layer (branch main) wins" two "$(val skills/g v)"
contains "git source: the auth secret is read with dcf-secret" "$(cat "$DCF_SECRET_CALLS")" "get registry/none"
lacks "git source: the secret never reaches the output" "$out" s3cret
contains "git source: explain shows the commit each layer was read at" "$(dcf-registry explain skills/g)" "g@$c1"
printf '[skills/g]\nv:value = three\n' > "$g/g.reg"; git -C "$g" commit -qam three
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
  l="$(layer a)"; printf '[skills/t]\nk:value = from-task\n' > "$l/a.reg"; path_list "a:/Corp:$l"
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
l="$(layer mine)"; printf '[skills/demo]\nbody:text = mine\n' > "$l/a.reg"
printf 'layers:\n  - id: mine\n    at: /Corp/me\n    writable: true\n    sources:\n      - { kind: path, path: "%s" }\n' "$l" > .devcontainer/registry.yml
out="$(COMPONENT_REGISTRY_SHARE_DIR="$base_share" dcf-registry resolve --as /Corp/me 2>&1)"
contains "base layer: the three utility skills and the layer's skill resolved" "$out" "resolved 4 component(s)"
for s in registry-refresh registry-explain registry-remember; do
  contains "base layer: $s has its SKILL.md with its front matter" "$(head -n 2 "$(V)/skills/$s/SKILL.md" 2>/dev/null)" "name: $s"
done
out="$(COMPONENT_REGISTRY_SHARE_DIR="$base_share" dcf-registry explain skills/registry-refresh 2>&1)"
contains "base layer: explain lists it as rank 0, builtin" "$out" "0 component-registry at /, source 1 (builtin): builtin, 1.1.0"
contains "base layer: explain names it for each line" "$out" "used         component-registry@1.1.0 1:component-registry.reg:"
printf '[skills/registry-refresh]\nbody:text = also say hello\n' >> "$l/a.reg"
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
l="$(layer a)"; printf '[skills/one]\nbody:text = one\n[skills/two]\nbody:text = two\n' > "$l/a.reg"; path_list "a:/Corp:$l"
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

# refresh: resolve for the view's path, then every adapter on PATH
out="$(PATH="$abin:$PATH" dcf-registry refresh 2>&1)"; rc=$?
check "refresh: exit 0" 0 "$rc"
contains "refresh: for the path the current view was resolved for" "$out" "refreshing for /Corp/me, the path the current view was resolved for"
contains "refresh: hands over to an adapter that takes skills" "$out" "took component-registry"
contains "refresh: names the adapter that cannot" "$out" "noskills: its adapter takes no resolved skills"
contains "refresh: says a CLI without live reload needs a restart" "$out" "when its session is restarted"
out="$(PATH="$abin:$PATH" dcf-registry refresh --as /Corp/other 2>&1)"
check "refresh --as: resolves for that path" /Corp/other "$(cat "$(V)/whoami")"
new_case refreshfail
l="$(layer a)"; printf '[skills/one]\nbody:text = one\n' > "$l/a.reg"; path_list "a:/Corp:$l"
out="$(PATH="$abin:$PATH" dcf-registry refresh 2>&1)"; rc=$?
check "refresh with no view and no who-you-are path: exit 2" 2 "$rc"
contains "refresh failing: nothing handed over" "$out" "nothing was handed over"

# remember
new_case remember
lm="$(layer mine)"; lb="$(layer base)"
printf '[skills/demo]\nbody:text = base text\n' > "$lb/a.reg"
printf 'layers:\n  - id: base\n    at: /Corp\n    sources:\n      - { kind: path, path: "%s" }\n  - id: mine\n    at: /Corp/me\n    writable: true\n    sources:\n      - { kind: path, path: "%s" }\n' "$lb" "$lm" > .devcontainer/registry.yml
dcf-registry resolve --as /Corp/me >/dev/null 2>&1
out="$(PATH="$abin:$PATH" dcf-registry remember -- "I am colour-blind; use safe colours" 2>&1)"; rc=$?
check "remember: exit 0" 0 "$rc"
check "remember: appended to the writable layer's folder" "[skills/*]" "$(sed -n 2p "$lm/remembered.reg")"
check "remember: the line as body:text" "body:text = I am colour-blind; use safe colours" "$(sed -n 3p "$lm/remembered.reg")"
contains "remember: refreshed, the line is in the resolved skill" "$(cat "$(V)/skills/demo/SKILL.md")" "I am colour-blind; use safe colours"
contains "remember: and handed over" "$out" "took component-registry"
PATH="$abin:$PATH" dcf-registry remember --skill skills/demo -- "Only for demo" >/dev/null 2>&1
check "remember --skill: that skill's section" "[skills/demo]" "$(grep -F '[skills/demo]' "$lm/remembered.reg")"
check "remember: appends, never rewrites (two entries)" 2 "$(grep -c '^; remembered ' "$lm/remembered.reg")"
contains "remember --skill: in the resolved skill" "$(cat "$(V)/skills/demo/SKILL.md")" "Only for demo"
check "remember: the base layer is never written" "a.reg" "$(find "$lb" -mindepth 1 -printf '%f\n')"
before="$(cat "$lm/remembered.reg")"
dcf-registry remember -- "" >/dev/null 2>&1; check "remember an empty line: exit 2" 2 $?
dcf-registry remember -- "@file /etc/passwd" >/dev/null 2>&1; check "remember a line starting with @: exit 2" 2 $?
dcf-registry remember --skill "../x" -- "y" >/dev/null 2>&1; check "remember with a bad skill name: exit 2" 2 $?
check "refused lines: nothing written" "$before" "$(cat "$lm/remembered.reg")"
sed -i 's/    writable: true//' .devcontainer/registry.yml
out="$(dcf-registry remember -- "x" 2>&1)"; rc=$?
check "remember with no writable layer: exit 1" 1 "$rc"
contains "remember with no writable layer: says how to mark one" "$out" "mark your own layer (one with a path source) writable: true"
printf 'layers:\n  - id: base\n    at: /Corp\n    writable: true\n    sources:\n      - { kind: path, path: "%s" }\n  - id: mine\n    at: /Corp/me\n    writable: true\n    sources:\n      - { kind: path, path: "%s" }\n' "$lb" "$lm" > .devcontainer/registry.yml
out="$(dcf-registry remember -- "x" 2>&1)"; rc=$?
check "remember with two writable layers: exit 2" 2 "$rc"
contains "remember with two writable layers: names them" "$out" "(base mine )"
repo_g="$(layer gitrepo)"; git -C "$repo_g" init -q; printf '[skills/g]\nbody:text = g\n' > "$repo_g/g.reg"; git -C "$repo_g" add . && git -C "$repo_g" commit -qm g
printf 'layers:\n  - id: g\n    at: /Corp\n    writable: true\n    sources:\n      - { kind: git, url: "%s", branch: main }\n' "$repo_g" > .devcontainer/registry.yml
out="$(dcf-registry remember -- "x" 2>&1)"; rc=$?
check "remember on a git layer: refused (exit 1)" 1 "$rc"
contains "remember on a git layer: not a writable kind" "$out" "has no path source"
printf 'layers:\n  - id: mine\n    at: /Corp\n    writable: true\n    sources:\n      - { kind: path, path: "%s/nosuch" }\n' "$C" > .devcontainer/registry.yml
out="$(dcf-registry remember -- "x" 2>&1)"; rc=$?
check "remember into a folder that is not there: exit 1" 1 "$rc"
contains "remember into a folder that is not there: says create it" "$out" "is not there; create it"

echo "component-registry unit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
