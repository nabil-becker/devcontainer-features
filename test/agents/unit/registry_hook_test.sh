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
# agents up, and on-demand agents too; the start limit (participant 1.2.0,
# COMPONENT_REGISTRY_START_WAIT): the fast path, a hanging layer source stopped at the limit, a lock
# held by another resolve, a bad value; agent definitions (participant 1.3.0, component-registry
# 1.6.0): resolve handed the listed agents, the model in AGENT_MODEL on the calls about the agent
# only, each path its own model in agents up, an adapter that ignores it, the registry's skills and
# model replacing the list's (the Operator's ruling of 2026-11-21), the list's where it sets none, nothing read without a layer list or the registry,
# check and list --json, and fake views (a bracketed model, one that is not a word, a skill name
# that is not one, a view for another path); each agent its own path's view (participant 1.4.0,
# ADR-0074: handover --as the registry-path, the records), an agent taken out of the list forgotten
# at agents up, registry-skills (split, shared, off) and the container default
# COMPONENT_REGISTRY_SKILLS_MODE, shown by check with the adapter's skills-show. Part of `task lint`
# (`task test:agents-registry`).
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
printf '#!/usr/bin/env bash\necho "$*" >> "%s/reg-calls"\n[ "$1" = resolve ] && echo "AGENTS=${COMPONENT_REGISTRY_AGENTS-unset}" >> "%s/reg-env"\nexec bash "%s/dcf-registry.real" "$@"\n' "$T" "$T" "$regbin" > "$regbin/dcf-registry"
# fakea: takes skills; records each call and, for skills, the folder and the skills in it
cat > "$bin/agent-adapter-fakea" <<'FAKE'
#!/usr/bin/env bash
verb="$1"; shift
[ "$verb" = supports ] && { printf '%s\n' start-bg wake attach resume new list stop logs skills skills-show; exit 0; }
[ "$verb" = skills-show ] && { printf 'own\t/own/%s\nown-skills\tdemo\nshared\t/shared\nshared-skills\ta b\n' "$1"; exit 0; }
echo "$verb|$*" >> "$CALLS_A"
echo "$verb|${AGENT_MODEL-unset}" >> "$MODELS_A"
[ "$verb" = list ] && { cat "$SESS_A" 2>/dev/null; exit 0; }
name="$1" folder="$2"
case "$verb" in
  skills) [ "${COMPONENT_REGISTRY_FORGET:-}" = 1 ] && { echo "forget|$name" >> "$CALLS_A"; exit 0; }
    [ -n "${FAKEA_SKILLS_FAIL:-}" ] && { echo "fakea: cannot write" >&2; exit 1; }
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
echo "$verb|${AGENT_MODEL-unset}" >> "$MODELS_B"
case "$verb" in new | resume | attach) exit 0 ;; *) exit 3 ;; esac
FAKE
chmod +x "$bin"/* "$regbin"/*

repo="$T/repo"; mkdir -p "$repo/.devcontainer" "$T/layer"
export SESS_A="$T/sess-a" CALLS_A="$T/calls-a" CALLS_B="$T/calls-b" T_SKILL="$T/skill-seen" MODELS_A="$T/models-a" MODELS_B="$T/models-b"
export AGENTS_SHARE_DIR="$T/agshare" AGENTS_STATE_DIR="$T/state" AGENTS_START_ID=start-1 AGENTS_SETTLE_INTERVAL=0 AGENTS_SETTLE_TIMEOUT=0
export COMPONENT_REGISTRY_STATE_DIR="$T/regstate" COMPONENT_REGISTRY_SHARE_DIR="$T/share"
# the test isolation rule: anything that can reach handover never touches the real Claude Code config
export CLAUDE_CONFIG_DIR="$T/claude-config"; mkdir -p "$CLAUDE_CONFIG_DIR"
unset AGENTS_FILE AGENTS_FILE_TASK_VAR AGENTS_TTY CLAUDE_CODE_CHILD_SESSION AGENTS_SESSION_NAME AGENTS_SESSION_NAME_TASK_VAR AGENT_SESSION_NAME DCF_HOST_MACHINE
unset COMPONENT_REGISTRY_WHOAMI COMPONENT_REGISTRY_FILE COMPONENT_REGISTRY_WHOAMI_TASK_VAR COMPONENT_REGISTRY_FILE_TASK_VAR
cat > "$T/layer/a.layer" <<'EOF'
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
reset() { rm -rf "$T/state" "$T/regstate"; : > "$SESS_A"; : > "$CALLS_A"; : > "$CALLS_B"; : > "$MODELS_A"; : > "$MODELS_B"; : > "$T/reg-calls"; : > "$T/reg-env"; rm -f "$T_SKILL"; unset FAKEA_SKILLS_FAIL; }
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
contains 'handover: one line, with the skills mode and where it came from' "$OUT" "host: the registry's resolved skills handed to fakea, registry skills split (from the default)."
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

# ------------------------------------- each agent its own path's view (participant 1.4.0) ----
reset
run 1 start rev
run 1 start host
contains 'own view: the hand-over names the agent'"'"'s path' "$(cat "$T/reg-calls")" "handover fakea rev $repo --as /Corp/review"
check 'own view: records both agents with their paths' "host /Corp/me whoami|rev /Corp/review as" "$(cd "$repo" && PATH="$regbin:$PATH" dcf-registry handovers | awk -F'\t' '{ print $2, $4, $5 }' | sort | paste -sd'|')"
check 'own view: a view kept per path' "for the reviewer only|for everyone at Corp" "$(tail -n 1 "$T/regstate/paths/+Corp+review/skills/demo/SKILL.md")|$(tail -n 1 "$T/regstate/paths/+Corp+me/skills/demo/SKILL.md")"
f1="$(grep '^skills-from' "$CALLS_A" | sed -n 1p | cut -d'|' -f2)"; f2="$(grep '^skills-from' "$CALLS_A" | sed -n 2p | cut -d'|' -f2)"
check 'own view: the two agents got two different views' yes "$([ -n "$f1" ] && [ "$f1" != "$f2" ] && echo yes || echo no)"
# an agent taken out of the list is forgotten at the next up; the sessions no agent started are not
(cd "$repo" && PATH="$bin:$regbin:/usr/bin:/bin" dcf-registry handover fakea >/dev/null 2>&1)
cp "$repo/.devcontainer/agents.yml" "$T/agents.keep2"
printf 'agents:\n  - name: host\n    cli: fakea\n    kind: resident\n' > "$repo/.devcontainer/agents.yml"
: > "$CALLS_A"
run 1 up
contains 'forget: said at up' "$OUT" 'rev: no longer in the agent list; its own registry skills are removed.'
contains 'forget: the adapter drops its copies' "$(cat "$CALLS_A")" 'forget|rev'
check 'forget: its record goes' "component-registry host" "$(cd "$repo" && PATH="$regbin:$PATH" dcf-registry handovers | cut -f2 | sort | paste -sd' ')"
lacks 'forget: a listed agent is never forgotten' "$(cat "$CALLS_A")" 'forget|host'
cp "$T/agents.keep2" "$repo/.devcontainer/agents.yml"

# ------------------------------- registry-skills and COMPONENT_REGISTRY_SKILLS_MODE (1.4.0) ----
cp "$repo/.devcontainer/agents.yml" "$T/agents.keep3"
printf 'agents:\n  - name: host\n    cli: fakea\n    kind: resident\n  - name: sh\n    cli: fakea\n    kind: resident\n    registry-skills: shared\n  - name: no\n    cli: fakea\n    kind: resident\n    registry-skills: off\n' > "$repo/.devcontainer/agents.yml"
reset
run 1 start sh
contains 'registry-skills shared: handed over with that mode' "$(cat "$T/reg-calls")" "handover fakea sh $repo --skills-mode shared"
contains 'registry-skills shared: said with where it came from' "$OUT" "registry skills shared (from registry-skills in the list)"
reset
run 1 start no
check 'registry-skills off: the agent starts (exit 0)' 0 "$RC"
check 'registry-skills off: never resolved' '' "$(grep '^resolve' "$T/reg-calls")"
contains 'registry-skills off: its copies forgotten' "$(cat "$T/reg-calls")" "forget fakea no $repo"
contains 'registry-skills off: one line' "$OUT" "no: registry skills off (from registry-skills in the list)"
contains 'registry-skills off: started' "$(cat "$CALLS_A")" 'start-bg|no'
reset
COMPONENT_REGISTRY_SKILLS_MODE=shared run 1 start host
contains 'container default (environment): applies to an agent with no key' "$(cat "$T/reg-calls")" "handover fakea host $repo --skills-mode shared"
contains 'container default: said with its source' "$OUT" "registry skills shared (from COMPONENT_REGISTRY_SKILLS_MODE in the environment)"
reset
COMPONENT_REGISTRY_SKILLS_MODE=off run 1 start sh
contains 'the key beats the container default' "$(cat "$T/reg-calls")" "handover fakea sh $repo --skills-mode shared"
reset
COMPONENT_REGISTRY_SKILLS_MODE=sometimes run 1 start host
contains 'a bad container default: said, split used' "$OUT" "not split, shared or off; using split"
contains 'a bad container default: handed over split' "$(cat "$T/reg-calls")" "--skills-mode split"
run 1 check
contains 'check: each agent its mode and where it came from' "$OUT" "registry skills shared (from registry-skills in the list)"
contains 'check: the default named' "$OUT" "host: cli fakea, resident, stateful (identity host, lease container), folder ., args: none, registry skills split (from the default)"
contains 'check: its own folder and skills (the adapter'"'"'s skills-show)' "$OUT" "    registry skills: own folder /own/host: demo (2 shared skill(s) besides)"
printf 'agents:\n  - name: x\n    cli: fakea\n    kind: resident\n    registry-skills: sometimes\n' > "$repo/.devcontainer/agents.yml"
run 1 check
check 'registry-skills bad value: refused (exit 2)' 2 "$RC"
contains 'registry-skills bad value: file and line' "$OUT" "registry-skills 'sometimes' must be split, shared or off"
cp "$T/agents.keep3" "$repo/.devcontainer/agents.yml"

# ------------------------------------------------ the start limit (participant 1.2.0) ----
# COMPONENT_REGISTRY_START_WAIT bounds resolve and the hand-over; past it the agent starts with the
# skills already in its folder, and one line says so.
reset
SECONDS=0; run 1 start host; took=$SECONDS
check 'start limit, fast path: handed over within the default limit' 1 "$(skills_calls)"
check 'start limit, fast path: well under 15 s' yes "$([ "$took" -lt 15 ] && echo yes || echo no)"
lacks 'start limit, fast path: no limit line' "$OUT" 'within 15s'
# a layer source that hangs (as a git fetch can): the whole fetch is stopped at the limit
# shellcheck disable=SC2016  # the fake expands its own variables
printf '#!/usr/bin/env bash\n[ "$1" = supports ] && { echo fetch; exit 0; }\nsleep 60 &\nwait\n' > "$regbin/registry-source-slow"; chmod +x "$regbin/registry-source-slow"
cp "$repo/.devcontainer/registry.yml" "$T/registry.keep"
printf '%s  - id: slow\n    at: /Corp\n    sources:\n      - { kind: slow, url: x }\n' "$REGLIST" > "$repo/.devcontainer/registry.yml"
reset
SECONDS=0; COMPONENT_REGISTRY_START_WAIT=2 run 1 start host; took=$SECONDS
check 'start limit, a hanging source: the agent still starts (exit 0)' 0 "$RC"
contains 'start limit, a hanging source: started' "$(cat "$CALLS_A")" 'start-bg|host'
contains 'start limit, a hanging source: one line, the limit and the last good skills' "$OUT" 'did not resolve within 2s'
contains 'start limit, a hanging source: says the skills already there are used' "$OUT" "starting with the last good skills already in fakea's skills folder"
check 'start limit, a hanging source: nothing handed over' 0 "$(skills_calls)"
check 'start limit, a hanging source: stopped near the limit (under 10 s)' yes "$([ "$took" -lt 10 ] && echo yes || echo no)"
check 'start limit, a hanging source: no fetch left running' '' "$(pgrep -f "$regbin/registry-source-slow" || true)"
cp "$T/registry.keep" "$repo/.devcontainer/registry.yml"
# another resolve holds the lock: waited for at most the limit, not COMPONENT_REGISTRY_LOCK_WAIT
reset; mkdir -p "$T/regstate"
flock "$T/regstate/resolve.lock" sleep 30 & holder=$!
sleep 1
SECONDS=0; COMPONENT_REGISTRY_START_WAIT=2 COMPONENT_REGISTRY_LOCK_WAIT=120 run 1 start host; took=$SECONDS
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check 'start limit, the lock held: the agent still starts (exit 0)' 0 "$RC"
contains 'start limit, the lock held: one line' "$OUT" 'did not resolve within 2s'
check 'start limit, the lock held: not the 120 s lock wait (under 10 s)' yes "$([ "$took" -lt 10 ] && echo yes || echo no)"
check 'start limit, the lock held: nothing handed over' 0 "$(skills_calls)"
reset
COMPONENT_REGISTRY_START_WAIT=abc run 1 start host
check 'start limit, a bad value: the default applies, handed over' 1 "$(skills_calls)"

# ------------------------------- agent definitions (participant 1.3.0, component-registry 1.6.0) ----
# The registry's agents/<name>: its model reaches the adapter in AGENT_MODEL on the calls about the
# agent (empty on the others); its skills replace the list entry's (the registry wins for both); read
# only when the view is for the agent's path; check and list --json show it.
cat > "$T/layer/agents.layer" <<'EOF'
[/Corp/agents/*]
model:value = sonnet
[/Corp/review/agents/rev]
model:value = opus
skills:list = ref:skills/demo, plan
kind:value = on-demand
EOF
reset
run 1 start host
check 'definition: the agent starts (exit 0)' 0 "$RC"
check 'definition: resolve is handed the listed agents and their CLIs' 'host:fakea,rev:fakea,pair:fakeb,od:fakea' "$(sed -n 's/^AGENTS=//p' "$T/reg-env" 2>/dev/null | head -n 1)"
check 'definition: the pattern model reaches start-bg in AGENT_MODEL' 'start-bg|sonnet' "$(grep '^start-bg' "$MODELS_A")"
check 'definition: AGENT_MODEL is empty on list' 'list|' "$(grep '^list' "$MODELS_A" | head -n 1)"
contains 'definition: one line names the model and its layer' "$OUT" "host: the component registry's agent definition: model sonnet (registry: corp)."
reset
run 1 start rev
check 'definition: the agent'"'"'s own path gets its own model' 'start-bg|opus' "$(grep '^start-bg' "$MODELS_A")"
contains 'definition: skills from the registry' "$OUT" 'skills [demo, plan] (registry: corp)'
run 1 check
check 'definition: check exits 0' 0 "$RC"
contains 'definition: check shows the model from the registry' "$OUT" 'rev: cli fakea, resident, stateful (identity rev, lease container), folder ., args: none, registry path /Corp/review, model opus (registry: corp), skills [demo, plan] (registry: corp)'
contains 'definition: check says host'"'"'s definition is not read (the view is rev'"'"'s)' "$OUT" "host: cli fakea, resident, stateful (identity host, lease container), folder ., args: none, registry: its definition is not read: the resolved view is for /Corp/review, not /Corp/me"
run 1 list --json
contains 'definition: list --json has the model' "$OUT" '"model":"opus"'
contains 'definition: list --json has the registry'"'"'s skills' "$OUT" '"skills":["demo","plan"]'
lacks 'definition: list --json has no model for an agent whose view is not read' "$(printf '%s' "$OUT" | sed 's/},{/}\n{/g' | grep '"name":"host"')" '"model"'
lacks 'definition: kind is never taken from the registry' "$OUT" '"name":"rev","kind":"on-demand"'
contains 'definition: resolve reports the skipped kind' "$(cd "$repo" && PATH="$bin:$regbin:/usr/bin:/bin" dcf-registry explain agents/rev 2>&1)" 'the agents list owns kind'
# up with two paths: each resident resolved for its own path, each with its own model
reset
run 1 up
check 'definition, up: host sonnet, rev opus' 'start-bg|sonnet start-bg|opus' "$(grep '^start-bg' "$MODELS_A" | tr '\n' ' ' | sed 's/ $//')"
# up with a path, another path, then the first path again: resolved again, its own definition
printf 'agents:\n  - name: host\n    cli: fakea\n    kind: resident\n  - name: rev\n    cli: fakea\n    kind: resident\n    registry-path: /Corp/review\n  - name: host2\n    cli: fakea\n    kind: resident\n' > "$repo/.devcontainer/agents.yml.3"
cp "$repo/.devcontainer/agents.yml" "$T/agents.keep"; mv "$repo/.devcontainer/agents.yml.3" "$repo/.devcontainer/agents.yml"
reset
run 1 up
check 'definition, up with a path again after another: resolved again' 3 "$(grep -c '^resolve' "$T/reg-calls")"
check 'definition, up with a path again after another: each its own model' 'start-bg|sonnet start-bg|opus start-bg|sonnet' "$(grep '^start-bg' "$MODELS_A" | tr '\n' ' ' | sed 's/ $//')"
cp "$T/agents.keep" "$repo/.devcontainer/agents.yml"
# model.<cli> under [agents/*]: each agent gets the model for its own CLI
cp "$T/layer/agents.layer" "$T/agents.layer.keep"
printf '[/Corp/agents/*]\nmodel.fakeb:value = b-model\n' >> "$T/layer/agents.layer"
reset
TTY=1 run 1 start pair
check 'definition, model.<cli>: the fakeb agent gets model.fakeb' 'new|b-model' "$(grep '^new' "$MODELS_B")"
contains 'definition, model.<cli>: the start line names the key' "$OUT" 'model b-model (registry: corp, model.fakeb)'
reset
run 1 start host
check 'definition, model.<cli>: the fakea agent keeps the plain model' 'start-bg|sonnet' "$(grep '^start-bg' "$MODELS_A")"
cp "$T/agents.layer.keep" "$T/layer/agents.layer"
# a CLI whose adapter does not read AGENT_MODEL (fakeb) starts as before
reset
TTY=1 run 1 start pair
check 'definition, fakeb: starts (exit 0)' 0 "$RC"
check 'definition, fakeb: given the model, which it may ignore' 'new|sonnet' "$(grep '^new' "$MODELS_B")"
# the registry wins (the Operator's ruling of 2026-11-21): its skills replace the list's, and its
# model replaces a --model in the list's args (the adapter swaps it; check says so)
cp "$repo/.devcontainer/agents.yml" "$T/agents.keep"
printf 'agents:\n  - name: rev\n    cli: fakea\n    kind: resident\n    registry-path: /Corp/review\n    skills: [mine]\n    args: [--model, haiku]\n  - name: host\n    cli: fakea\n    kind: resident\n    skills: [kept]\n' > "$repo/.devcontainer/agents.yml"
reset
run 1 start rev
contains 'definition, list skills: the registry replaces them, said' "$OUT" "skills [demo, plan] (registry: corp), replacing the list's skills [mine]"
contains 'definition, list args --model: the replacement is said' "$OUT" 'model opus (registry: corp), replacing --model haiku in its args'
check 'definition, list args --model: AGENT_MODEL is still the registry'"'"'s' 'start-bg|opus' "$(grep '^start-bg' "$MODELS_A")"
run 1 list --json
contains 'definition, list skills: list --json shows the registry'"'"'s skills' "$OUT" '"skills":["demo","plan"]'
lacks 'definition, list skills: list --json drops the replaced ones' "$(printf '%s' "$OUT" | sed 's/},{/}\n{/g' | grep '"name":"rev"')" '"mine"'
contains 'definition, the list fills what the registry leaves unset (host has no registry skills)' "$OUT" '"skills":["kept"]'
run 1 check
contains 'definition, check: the replaced skills and model are named' "$OUT" "replacing the list's skills [mine]"
cp "$T/agents.keep" "$repo/.devcontainer/agents.yml"
# no layer list: nothing read, AGENT_MODEL empty
reset; mv "$repo/.devcontainer/registry.yml" "$T/registry.keep"
run 1 start host
check 'definition, no layer list: AGENT_MODEL empty' 'start-bg|' "$(grep '^start-bg' "$MODELS_A")"
lacks 'definition, no layer list: nothing said of a definition' "$OUT" 'agent definition'
mv "$T/registry.keep" "$repo/.devcontainer/registry.yml"
# the registry absent: nothing read even when a view is there
reset; mkdir -p "$T/regstate/view/agents/host"; echo /Corp/me > "$T/regstate/view/whoami"; echo big > "$T/regstate/view/agents/host/model"
run 0 start host
check 'definition, registry absent: AGENT_MODEL empty' 'start-bg|' "$(grep '^start-bg' "$MODELS_A")"
# fake views, read by check (read-only, no resolve)
reset; mkdir -p "$T/regstate/view/agents/host"; echo /Corp/me > "$T/regstate/view/whoami"
echo 'claude-opus-4-5[1m]' > "$T/regstate/view/agents/host/model"; printf 'model\tteam\t1:x.layer:3\n' > "$T/regstate/view/agents/host/from.tsv"
run 1 check
contains 'fake view: a model with brackets is read' "$OUT" 'model claude-opus-4-5[1m] (registry: team)'
check 'fake view: check resolves nothing' '' "$(grep resolve "$T/reg-calls")"
echo 'two words; rm -rf /' > "$T/regstate/view/agents/host/model"; printf 'ok\nbad name\n' > "$T/regstate/view/agents/host/skills"
run 1 check
contains 'fake view: a model that is not one word is left out, said' "$OUT" "host: the registry's model 'two words; rm -rf /' is not one word; left out."
contains 'fake view: only skill names are read' "$OUT" 'skills [ok] (registry: ?)'
echo /Corp/other > "$T/regstate/view/whoami"
run 1 check
contains 'fake view for another path: not read, said' "$OUT" 'registry: its definition is not read: the resolved view is for /Corp/other, not /Corp/me'
rm -f "$T/layer/agents.layer"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
