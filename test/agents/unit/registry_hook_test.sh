#!/usr/bin/env bash
# Docker-free tests of the participant component's component-registry start hook (participant
# 1.1.0, ADR-0064): before an agent's CLI starts, `dcf-registry resolve` (--as the entry's
# registry-path, else COMPONENT_REGISTRY_WHOAMI) and `dcf-registry handover`, which calls the
# adapter's optional `skills` verb when its supports lists it. Against the real dcf-registry
# (src/component-registry, path layers) and two fake adapters (NFR-12): fakea takes skills,
# fakeb does not (supports omits it, the verb answers 3). Cases: the registry absent (nothing said,
# nothing run), no layer list (one line, the agent starts), resolve failing (no who-you-are path;
# one line, the agent still starts, nothing handed over), skills handed over (the resolved folder
# reaches the adapter), a CLI without the verb (one line, plain skills), the adapter's skills verb
# failing (one line, the agent still starts), the per-agent registry-path (parsed, shown by check,
# refused when not an absolute path, with file:line; resolved --as it), one resolve per path in
# agents up, and on-demand agents too. Part of `task lint` (`task test:agents-registry`).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
agents_sh="${AGENTS_SH:-$root/components/participant/agents.sh}"
reg="$root/src/component-registry"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"; else fail=$((fail + 1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass=$((pass + 1)); echo "ok   - $1" ;; *) fail=$((fail + 1)); echo "FAIL - $1 (no '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail=$((fail + 1)); echo "FAIL - $1 ('$3' found in '$2')" ;; *) pass=$((pass + 1)); echo "ok   - $1" ;; esac; }

bin="$T/bin" regbin="$T/regbin"; mkdir -p "$bin" "$regbin"
cp "$agents_sh" "$bin/agents"
# the registry, in its own folder so a case can leave it off PATH; a wrapper logs each call
cp "$reg/dcf-registry.sh" "$regbin/dcf-registry.real"
cp "$reg/registry-source-path.sh" "$regbin/registry-source-path"
# shellcheck disable=SC2016  # the wrapper expands its own variables
printf '#!/usr/bin/env bash\necho "$*" >> "%s/reg-calls"\nexec bash "%s/dcf-registry.real" "$@"\n' "$T" "$regbin" > "$regbin/dcf-registry"
# fakea: takes skills; records each call and, for skills, the folder and the skills in it
cat > "$bin/agent-adapter-fakea" <<'FAKE'
#!/usr/bin/env bash
verb="$1"; shift
[ "$verb" = supports ] && { printf '%s\n' start-bg wake attach resume new list stop logs skills; exit 0; }
echo "$verb|$*" >> "$CALLS_A"
[ "$verb" = list ] && { cat "$SESS_A" 2>/dev/null; exit 0; }
name="$1" folder="$2"
case "$verb" in
  skills) [ -n "${FAKEA_SKILLS_FAIL:-}" ] && { echo "fakea: cannot write" >&2; exit 1; }
    printf 'skills-from|%s|%s\n' "$COMPONENT_REGISTRY_SKILLS" "$(ls "$COMPONENT_REGISTRY_SKILLS" | tr '\n' ' ')" >> "$CALLS_A"
    cat "$COMPONENT_REGISTRY_SKILLS/demo/SKILL.md" > "$T_SKILL" 2>/dev/null; exit 0 ;;
  start-bg) n=$(( $(grep -c . "$SESS_A" 2>/dev/null) + 1 ))
    { printf '%s\tida-%s\trunning\t%s\n' "$name" "$n" "$folder"; cat "$SESS_A" 2>/dev/null; } > "$SESS_A.new"
    mv "$SESS_A.new" "$SESS_A"; echo "ida-$n" ;;
  attach | resume | new | stop | logs | wake) ;;
  *) exit 3 ;;
esac
exit 0
FAKE
# fakeb: no skills verb (supports omits it, the verb answers 3)
cat > "$bin/agent-adapter-fakeb" <<'FAKE'
#!/usr/bin/env bash
verb="$1"; shift
[ "$verb" = supports ] && { printf '%s\n' new resume attach; exit 0; }
echo "$verb|$*" >> "$CALLS_B"
case "$verb" in new | resume | attach) exit 0 ;; *) exit 3 ;; esac
FAKE
chmod +x "$bin"/* "$regbin"/*

repo="$T/repo"; mkdir -p "$repo/.devcontainer" "$T/layer"
export SESS_A="$T/sess-a" CALLS_A="$T/calls-a" CALLS_B="$T/calls-b" T_SKILL="$T/skill-seen"
export AGENTS_SHARE_DIR="$T/agshare" AGENTS_STATE_DIR="$T/state" AGENTS_START_ID=start-1 AGENTS_SETTLE_INTERVAL=0 AGENTS_SETTLE_TIMEOUT=0
export COMPONENT_REGISTRY_STATE_DIR="$T/regstate" COMPONENT_REGISTRY_SHARE_DIR="$T/share"
unset AGENTS_FILE AGENTS_FILE_TASK_VAR AGENTS_TTY CLAUDE_CODE_CHILD_SESSION AGENTS_SESSION_NAME AGENTS_SESSION_NAME_TASK_VAR AGENT_SESSION_NAME DCF_HOST_MACHINE
unset COMPONENT_REGISTRY_WHOAMI COMPONENT_REGISTRY_FILE COMPONENT_REGISTRY_WHOAMI_TASK_VAR COMPONENT_REGISTRY_FILE_TASK_VAR
cat > "$T/layer/a.reg" <<'EOF'
[/Corp/skills/demo]
body:text = for everyone at Corp
[/Corp/review/skills/demo]
body:text = for the reviewer only
EOF
REGLIST="layers:
  - id: corp
    at: /Corp
    sources:
      - { kind: path, path: \"$T/layer\" }
"
cat > "$repo/.devcontainer/agents.yml" <<'YAML'
agents:
  - name: host
    cli: fakea
    kind: resident
  - name: rev
    cli: fakea
    kind: resident
    registry-path: /Corp/review
  - name: pair
    cli: fakeb
    kind: on-demand
  - name: od
    cli: fakea
    kind: on-demand
YAML
reset() { rm -rf "$T/state" "$T/regstate"; : > "$SESS_A"; : > "$CALLS_A"; : > "$CALLS_B"; : > "$T/reg-calls"; rm -f "$T_SKILL"; unset FAKEA_SKILLS_FAIL; }
# run <with registry: 1|0> <agents args...>: OUT and RC; only the test's folders and the system
# folders on PATH, so a registry installed in this container is never the one used
run() {
  local p="$bin:/usr/bin:/bin"; [ "$1" = 1 ] && p="$bin:$regbin:/usr/bin:/bin"; shift
  OUT="$(cd "$repo" && PATH="$p" AGENTS_TTY="${TTY:-0}" agents "$@" 2>&1)"; RC=$?
}
skills_calls() { grep -c '^skills|' "$CALLS_A"; }

# ----------------------------------------------------------- registry absent ----
reset; rm -f "$repo/.devcontainer/registry.yml"
run 0 start host
check 'registry absent: the agent starts (exit 0)' 0 "$RC"
contains 'registry absent: started' "$(cat "$CALLS_A")" 'start-bg|host'
lacks 'registry absent: nothing said about the registry' "$OUT" 'registry'
check 'registry absent: no skills handed over' 0 "$(skills_calls)"

# ----------------------------------------------------------- no layer list ----
reset
run 1 start host
check 'no layer list: the agent starts (exit 0)' 0 "$RC"
contains 'no layer list: one line says so' "$OUT" 'host: the component registry has no layer list'
contains 'no layer list: plain skills' "$OUT" 'starting with the plain skills'
check 'no layer list: never resolved' '' "$(grep resolve "$T/reg-calls")"
check 'no layer list: no skills handed over' 0 "$(skills_calls)"

# ------------------------------------------------- resolve fails, never blocks ----
reset; printf '%s' "$REGLIST" > "$repo/.devcontainer/registry.yml"
run 1 start host
check 'resolve fails (no who-you-are path): the agent still starts (exit 0)' 0 "$RC"
contains 'resolve fails: started' "$(cat "$CALLS_A")" 'start-bg|host'
contains 'resolve fails: one line with the reason' "$OUT" 'host: the component registry did not resolve (who are you?'
contains 'resolve fails: the skills stay' "$OUT" 'starting with the skills as they were'
check 'resolve fails: nothing handed over' 0 "$(skills_calls)"

# ------------------------------------------------------------- handed over ----
reset; export COMPONENT_REGISTRY_WHOAMI=/Corp/me
run 1 start host
check 'handover: exit 0' 0 "$RC"
contains 'handover: one line' "$OUT" "host: the registry's resolved skills handed to fakea."
check 'handover: the skills verb once' 1 "$(skills_calls)"
contains 'handover: the adapter gets the agent and its folder' "$(cat "$CALLS_A")" "skills|host $repo"
contains 'handover: COMPONENT_REGISTRY_SKILLS is the resolved view' "$(cat "$CALLS_A")" "$T/regstate/views/"
contains 'handover: the resolved skill reaches the adapter' "$(cat "$T_SKILL")" 'for everyone at Corp'
lacks 'handover: the reviewer scope does not apply to /Corp/me' "$(cat "$T_SKILL")" 'reviewer'
check 'handover: before the CLI starts' 'skills' "$(grep -v '^list' "$CALLS_A" | head -n 1 | cut -d'|' -f1)"
contains 'handover: resolved for the who-you-are setting' "$(cat "$T/regstate/view/whoami")" '/Corp/me'

# ------------------------------------------------------- the per-agent path ----
reset
run 1 start rev
contains 'registry-path: resolved --as it' "$(cat "$T/reg-calls")" 'resolve --as /Corp/review'
contains 'registry-path: said in the line' "$OUT" '(as /Corp/review)'
contains 'registry-path: the view is the agent'"'"'s' "$(cat "$T/regstate/view/whoami")" '/Corp/review'
contains 'registry-path: its scope applies' "$(cat "$T_SKILL")" 'for the reviewer only'
run 1 check
contains 'registry-path: check shows it' "$OUT" 'rev: cli fakea, resident, stateful (identity rev, lease container), folder ., args: none, registry path /Corp/review'
cp "$repo/.devcontainer/agents.yml" "$T/agents.keep"
printf 'agents:\n  - name: x\n    cli: fakea\n    kind: resident\n    registry-path: Corp/x\n' > "$repo/.devcontainer/agents.yml"
run 1 check
check 'registry-path relative: refused (exit 2)' 2 "$RC"
contains 'registry-path relative: file and line' "$OUT" "agents.yml:2: entry 1: registry-path 'Corp/x' must be an absolute path"
printf 'agents:\n  - name: x\n    cli: fakea\n    kind: resident\n    registry-path: /Corp/**\n' > "$repo/.devcontainer/agents.yml"
run 1 check
check 'registry-path with a wildcard: refused (exit 2)' 2 "$RC"
printf 'agents:\n  - name: x\n    cli: fakea\n    kind: resident\n    registry-path: /Corp/x\n    registry-path: /Corp/y\n' > "$repo/.devcontainer/agents.yml"
run 1 check
check 'registry-path twice: refused (exit 2)' 2 "$RC"
contains 'registry-path twice: says so with its line' "$OUT" "agents.yml:6: 'registry-path' appears twice in one entry"
cp "$T/agents.keep" "$repo/.devcontainer/agents.yml"

# --------------------------------------------------- a CLI without the verb ----
reset
TTY=1 run 1 start pair
check 'no skills verb (fakeb): the agent starts (exit 0)' 0 "$RC"
contains 'no skills verb: one line' "$OUT" 'pair: fakeb takes no resolved skills (its adapter has no skills verb); starting with its plain skills.'
contains 'no skills verb: new was called' "$(cat "$CALLS_B")" 'new|pair'
check 'no skills verb: the verb is never called when supports omits it' '' "$(grep '^skills' "$CALLS_B")"

# ------------------------------------------------ the adapter's verb failing ----
reset; export FAKEA_SKILLS_FAIL=1
run 1 start host
check 'skills verb fails: the agent still starts (exit 0)' 0 "$RC"
contains 'skills verb fails: one line' "$OUT" "host: handing the registry's skills to fakea failed"
contains 'skills verb fails: started' "$(cat "$CALLS_A")" 'start-bg|host'
unset FAKEA_SKILLS_FAIL

# ------------------------------------------------------- on-demand, and up ----
reset
TTY=1 run 1 start od
contains 'on-demand: handed over before new' "$(grep -v '^list\|^skills-from' "$CALLS_A" | cut -d'|' -f1 | tr '\n' ' ')" 'skills new'
reset
run 1 up
check 'up: exit 0' 0 "$RC"
check 'up: one resolve per path (host for the setting, rev for its own)' 2 "$(grep -c '^resolve' "$T/reg-calls")"
check 'up: each resident handed over' 2 "$(skills_calls)"
lacks 'up: an on-demand agent is not resolved for' "$OUT" 'od: the registry'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
