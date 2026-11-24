#!/usr/bin/env bash
# agent-adapter-copilot: the GitHub Copilot CLI adapter of the participant component's contract
# (src/agents/NOTES.md "The adapter contract", ADR-0037). Installed on PATH by the copilot Feature;
# the participant component (the agents command) and the facilitator's pump call it, nothing else
# does. The second real adapter beside agent-adapter-claude (NFR-12).
#
#   agent-adapter-copilot <verb> <name> <folder> [-- copilot args...]
#     (<name> is the participant's handle. The session's own name is $AGENT_SESSION_NAME when the
#     caller sets it and it is one line, else the handle: "session name" below)
#     new        cd <folder> && copilot --name <session name> <args>   (a terminal is needed)
#     resume     cd <folder> && copilot --resume <session name> <args> (its own picker is not
#                used: a name that no session has fails in Copilot with its own message)
#     hint       how to find and resume the participant by hand
#     run-once   one non-interactive turn: the prompt on stdin, the reply on stdout, exit when done:
#                cd <folder> && copilot -p <prompt> --silent --no-ask-user --no-auto-update <args>.
#                With no one to ask, a tool the CLI would ask about is refused; to let a turn use
#                tools, pass --allow-tool '<rule>' after -- (or set AGENT_ADAPTER_COPILOT_ALLOW_ALL_TOOLS=1
#                for --allow-all-tools; off by default, since an unattended turn is a trust decision
#                the engineer makes). AGENT_ADAPTER_COPILOT_CONTINUE=1 keeps one conversation per
#                (name, folder) across turns with --session-id <a UUID derived from both>; unset,
#                every turn is a fresh session and carries its own context (the facilitator sends
#                the conversation with each message). The prompt travels as an argument (-p), so
#                other processes of the same Linux user can read it in the process list; it is
#                refused above 100000 bytes (the kernel's limit on one argument is 128 KiB).
#     mcp-attach facilitator       (<target> instead of <name> <folder>)
#                register the facilitator's MCP entry through Copilot's own command:
#                copilot mcp add facilitator -- sh -c 'exec facilitator mcp --as "$FACILITATOR_HANDLE"'.
#                The entry holds no token and no handle: the harness starts copilot with
#                FACILITATOR_HANDLE and FACILITATOR_TOKEN in its environment and the MCP server
#                inherits them (the facilitator refuses a start without the token). Replaces an
#                entry of that name, so it is idempotent. Needs no login. With no facilitator on PATH
#                it registers nothing and says so (exit 0). Not a verb of the contract yet (the
#                contract's own `attach` opens a running session); other targets exit 2.
#   AGENT_MODEL (0.2.0): new and resume run with --model <it>, in place of any --model in the args
#     (the component registry's agent definition wins, handed over by the participant component;
#     Copilot CLI 1.0.114 `copilot --help`: "--model <model>  Set the AI model to use (use 'auto'
#     to let Copilot pick automatically)"); run-once is left as its caller sends it
#     skills     (0.3.0, ADR-0064, ADR-0077) the component registry's skills, rendered from the
#                copilot templates, in $COMPONENT_REGISTRY_SKILLS: the ones every agent shares into
#                $COPILOT_HOME/skills, the agent's own into a folder that new, resume and run-once
#                pass with --add-dir; see "skills" below. COMPONENT_REGISTRY_SKILLS_MODE split
#                (default), shared or off; COMPONENT_REGISTRY_FORGET=1 drops the agent's folder
#     skills-show  (0.3.0, read-only) the agent's own folder and skills, and the shared ones
#   agent-adapter-copilot supports   the verbs above that work, one per line
# Exit: 0 done, 1 failed, 2 bad use, 3 not supported.
#
# Not supported (exit 3), and why: start-bg, wake, attach, list, stop, logs, record and the
# session-* verbs, because Copilot CLI has no documented local background session, session list or
# stop (its --cloud and --connect sessions are GitHub-hosted); so a copilot participant is
# on-demand or ephemeral, never resident, and has no lease liveness from a list. trust, because
# the CLI keeps trusted folders in its own config.json, which a Feature never edits (NFR-13), and
# --trust-folder trusts one prompt-mode session only.
#
# COPILOT_HOME is the CLI's, set by the Feature to its volume; the adapter reads and writes nothing
# there but through `copilot mcp`. Telemetry, login and tokens are never touched: the token the CLI
# uses comes from its own login or COPILOT_GITHUB_TOKEN, GH_TOKEN, GITHUB_TOKEN in the environment.
set -u

die() { local rc="$1"; shift; printf 'agent-adapter-copilot: %s\n' "$*" >&2; exit "$rc"; }
note() { printf 'agent-adapter-copilot: %s\n' "$*" >&2; }

# skills (0.3.0, ADR-0064 and ADR-0077): the component registry's resolved skills for one agent,
# rendered from the copilot templates (component-registry 2.1.0) and handed over by dcf-registry in
# COMPONENT_REGISTRY_SKILLS (one folder per skill; COMPONENT_REGISTRY_PATH names the path). The same
# shape as agent-adapter-claude's verb (claude-code 1.14.0, ADR-0074), kept in step with it, in
# Copilot CLI's own places (docs read 2026-11-24: the CLI command reference, "Skill locations";
# https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference, page
# changed 2026-11-20), both in COPILOT_HOME (the Feature's volume, tier 4, owner-only; never the
# repository's .github/skills, .agents/skills or .claude/skills):
#   $COPILOT_HOME/skills, Copilot's personal skills folder: the skills every agent's view has alike;
#   $COPILOT_HOME/registry-agents/<name>.<folder sum>/registry/.github/skills, the agent's own folder,
#     passed with --add-dir <that>/registry to every session of the agent the adapter starts (new,
#     resume, run-once): Copilot loads .github/skills under an added directory.
# Copilot's order (first found wins for a name): project skills, then personal, then added
# directories; so a name the agents' views disagree on must not be personal, and a project or
# personal skill of the same name beats the agent's own copy (said; Copilot has no qualified name
# for the loser). Copilot does not watch its skills folders: a running session reads a change after
# /skills reload. COMPONENT_REGISTRY_SKILLS_MODE: split (the default), shared, off; FORGET=1 drops
# the agent's folder. Each copy is marked owned (.component-registry); an unmarked folder is never
# touched. Owner-only (umask 077).
copilot_home() { printf '%s' "${COPILOT_HOME:-$HOME/.copilot}"; }
# project_skill <folder> <name>: the project skill of that name Copilot would read first, if any
project_skill() { local p; for p in .github/skills .agents/skills .claude/skills; do [ -d "$1/$p/$2" ] && { printf '%s' "$1/$p/$2"; return 0; }; done; return 1; }
# The vendor's side of the shared hand-over below (dcf-skills.sh): Copilot CLI's places and words.
SK_CLI=copilot SK_OWN=.github/skills
sk_home() { copilot_home; }
sk_reload_note() { echo "copilot: a session started from now on reads them; a running one after /skills reload."; }
sk_handover_clash() { # <skill> <personal folder>
  local p
  if [ -d "$2/$1" ]; then
    echo "copilot: $1: the personal skill $2/$1 is not the registry's and wins in $NAME's sessions; the registry's is not used there."
  elif p="$(project_skill "$FOLDER" "$1")"; then
    echo "copilot: $1: the project's $p wins in $NAME's sessions (Copilot reads project skills first); the registry's is not used there."
  fi
}
sk_start_clash() { # <skill>
  local p
  if p="$(project_skill "$FOLDER" "$1")"; then note "$NAME: registry skills: clash: the project's $p wins in its sessions; its own $1 is not used."
  elif [ -d "$(copilot_home)/skills/$1" ]; then note "$NAME: registry skills: clash: the personal $(copilot_home)/skills/$1 wins in its sessions; its own $1 is not used."
  fi
}
# >>> dcf-skills.sh: vendored verbatim from src/common/dcf-skills.sh by `task common:sync`; edit it there (task common:check) >>>
# shellcheck shell=bash
# dcf-skills.sh: the component registry's skills hand-over, shared by the CLI adapters that take
# resolved skills (agent-adapter-claude, agent-adapter-copilot; ADR-0064, ADR-0074, ADR-0077). It is
# not sourced at run time: each adapter carries it verbatim between a begin and an end marker
# line (the Taskfile's common:check names them), so an adapter stays one self-contained file; `task common:sync` writes the copies and `task
# common:check` (part of lint) fails on a stale one. Edit it here, never in an adapter.
#
# What it does, for one agent (<name> <folder>, the adapter's NAME and FOLDER), from the folder
# dcf-registry handover gives in COMPONENT_REGISTRY_SKILLS (one folder per skill, rendered from the
# CLI's templates):
#   <home>/skills, the CLI's personal skills folder: the skills every agent's view has alike, so a
#     session no agent started has them;
#   <home>/registry-agents/<name>.<folder sum>/registry/<own>, the agent's own folder: the rest of its
#     view, which the adapter passes with --add-dir <that>/registry to every session of the agent.
# Each agent's full view is kept in registry-agents/<key>/want and the split is recomputed from every
# agent's view at each hand-over (under registry-agents/.lock). COMPONENT_REGISTRY_SKILLS_MODE: split
# (default), shared (the whole view personal, no own folder), off (as forget);
# COMPONENT_REGISTRY_FORGET=1 drops the agent's folder; an agent whose folder is gone is dropped at
# any hand-over. Each copy is marked owned (.component-registry); a copy no longer wanted is removed;
# an unmarked skill folder is never touched. Idempotent; owner-only (umask 077).
#
# The adapter sets, before it uses these functions:
#   SK_CLI                      the word its lines start with (claude, copilot)
#   SK_OWN                      the skills folder under an added directory (.claude/skills, .github/skills)
#   sk_home                     prints the CLI's home (CLAUDE_CONFIG_DIR, COPILOT_HOME)
#   sk_reload_note <new> <personal folder>   what a running session must do to read the change (<new>: 1 when the
#                               personal folder was just created)
#   sk_handover_clash <skill> <personal folder>   a line when a personal or project skill of that
#                               name beats the agent's own copy in the CLI
#   sk_start_clash <skill>      the same at a start, as note lines
#   die <rc> <text>, note <text>, NAME, FOLDER
# Verbs: skills_handover (skills), skills_show (skills-show); at a start, sk_add_dir then
# sk_start_line.

SKILLS_MARK=.component-registry
REG_ADD=registry   # the added directory's folder name: a clashing skill runs as /registry:<name>
agents_skills_dir() { printf '%s/registry-agents' "$(sk_home)"; }
# agent_key <name> <folder>: the key is made from the folder's real path, so the hand-over and a start
# agree however it is written (the same as the path given when it is already real)
agent_key() { local f; f="$(cd "$2" 2>/dev/null && pwd -P)" || f="$2"; printf '%s.%s' "$1" "$(printf '%s' "$f" | cksum | cut -d' ' -f1)"; }
# agent_add_dir <name> <folder>: the folder passed with --add-dir for that agent
agent_add_dir() { printf '%s/%s/%s' "$(agents_skills_dir)" "$(agent_key "$1" "$2")" "$REG_ADD"; }
skill_name_ok() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; }

# put_skills <dest> <src root> <name>...: each named skill copied from <src root> into <dest>,
# marked owned; an unchanged one left; an unowned folder of that name never touched (PUT_MINE).
# Adds to PUT_COPIED, PUT_SAME, PUT_MINE; PUT_RC 1 when a copy failed.
put_skills() {
  local dest="$1" src="$2" nm tmp; shift 2
  for nm in "$@"; do
    if [ -e "$dest/$nm" ] && [ ! -f "$dest/$nm/$SKILLS_MARK" ]; then
      note "skills: $dest/$nm is not the registry's (no $SKILLS_MARK in it), so it is left as it is and the registry's $nm is not installed there."
      PUT_MINE=$((PUT_MINE + 1)); continue
    fi
    if [ -f "$dest/$nm/$SKILLS_MARK" ] && diff -rq -x "$SKILLS_MARK" "$src/$nm" "$dest/$nm" >/dev/null 2>&1; then PUT_SAME=$((PUT_SAME + 1)); continue; fi
    tmp="$dest/.$nm.new.$$"
    rm -rf "$tmp"
    if ! { mkdir -p "$tmp" && cp -R "$src/$nm/." "$tmp/"; } 2>/dev/null; then
      rm -rf "$tmp"; note "skills: copying $nm into $dest failed."; PUT_RC=1; continue
    fi
    printf '%s\n' "Owned by the component registry (dcf-registry): the next resolve replaces or removes this folder. Change the layer, not this copy." > "$tmp/$SKILLS_MARK"
    if ! { rm -rf "${dest:?}/$nm" && mv "$tmp" "$dest/$nm"; }; then
      rm -rf "$tmp"; note "skills: replacing $dest/$nm failed."; PUT_RC=1; continue
    fi
    PUT_COPIED=$((PUT_COPIED + 1))
  done
}
# prune_skills <dest> <name>...: owned copies in <dest> not named are removed; adds to PRUNED
prune_skills() {
  local dest="$1" d nm; shift
  local -A want=()
  for nm in "$@"; do want[$nm]=1; done
  for d in "$dest"/*/; do
    [ -f "$d$SKILLS_MARK" ] || continue
    nm="$(basename "$d")"
    [ -n "${want[$nm]:-}" ] && continue
    rm -rf "${dest:?}/$nm" && PRUNED=$((PRUNED + 1))
  done
  for d in "$dest"/.*.new.*; do [ -e "$d" ] && rm -rf "$d"; done
  return 0
}

# skills_show (ADR-0074; the optional verb skills-show <name> <folder>): what the CLI holds for the
# agent, read-only, one tab-separated line each:
#   own <its own folder, the one --add-dir passes, or ->    own-skills <names, or ->
#   shared <the personal folder>                            shared-skills <the registry's there, or ->
skills_show() {
  local pers rd nm d o='' sh=''
  pers="$(sk_home)/skills" rd="$(agent_add_dir "$NAME" "$FOLDER")"
  for d in "$pers"/*/; do [ -f "$d$SKILLS_MARK" ] && sh="$sh${sh:+ }$(basename "$d")"; done
  if [ -d "$rd/$SK_OWN" ]; then
    for d in "$rd/$SK_OWN"/*/; do [ -f "$d$SKILLS_MARK" ] && o="$o${o:+ }$(basename "$d")"; done
    printf 'own\t%s\nown-skills\t%s\n' "$rd" "${o:--}"
  else
    printf 'own\t-\nown-skills\t-\n'
  fi
  printf 'shared\t%s\nshared-skills\t%s\n' "$pers" "${sh:--}"
  return 0
}
# count_owned <folder>: how many skills in it the registry owns
count_owned() { local d n=0; for d in "$1"/*/; do [ -f "$d$SKILLS_MARK" ] && n=$((n + 1)); done; printf '%s' "$n"; }

skills_handover() {
  local src="${COMPONENT_REGISTRY_SKILLS:-}" forget='' pers base me a d nm fo new='' anew='' swept=0
  local pc ps pr pm oc os orr own='' ref ok smode="${COMPONENT_REGISTRY_SKILLS_MODE:-split}"
  [ "${COMPONENT_REGISTRY_FORGET:-}" = 1 ] && forget=1
  # (1.14.0, ADR-0074) the mode the agents list (registry-skills) or the container
  # (COMPONENT_REGISTRY_SKILLS_MODE) chose: split (the default), shared (the whole view personal, the
  # latest hand-over wins, no own folder), off (as forget)
  case "$smode" in
    split | shared) ;;
    off) forget=1 ;;
    *) die 2 "skills: COMPONENT_REGISTRY_SKILLS_MODE is '$smode', not split, shared or off." ;;
  esac
  if [ -z "$forget" ]; then
    [ -n "$src" ] || die 2 "skills needs COMPONENT_REGISTRY_SKILLS, the resolved skills folder (dcf-registry handover sets it)."
    [ -d "$src" ] || die 2 "skills: COMPONENT_REGISTRY_SKILLS is '$src', which is not a folder."
  fi
  pers="$(sk_home)/skills" base="$(agents_skills_dir)"
  [ -d "$pers" ] || new=1
  (umask 077 && mkdir -p "$pers" "$base") 2>/dev/null || die 1 "skills: cannot create $pers or $base."
  umask 077
  if command -v flock >/dev/null 2>&1; then
    exec 7>>"$base/.lock"
    flock -w "${AGENT_ADAPTER_SKILLS_WAIT:-60}" 7 || die 1 "skills: another hand-over has held $base/.lock for ${AGENT_ADAPTER_SKILLS_WAIT:-60}s; try again."
  fi
  me="$base/$(agent_key "$NAME" "$FOLDER")"
  if [ -z "$forget" ] && [ "$smode" = shared ]; then
    # shared: no own folder; the whole view into the personal folder, as before 1.14.0
    rm -rf "$me"
    local -a all=()
    for d in "$src"/*/; do nm="$(basename "$d")"; [ -d "$d" ] || continue; if skill_name_ok "$nm"; then all+=("$nm"); else note "skills: '$nm' is not a skill name; skipped."; fi; done
    PUT_RC=0 PUT_COPIED=0 PUT_SAME=0 PUT_MINE=0 PRUNED=0
    put_skills "$pers" "$src" "${all[@]+"${all[@]}"}"
    prune_skills "$pers" "${all[@]+"${all[@]}"}"
    [ "$PUT_MINE" -eq 0 ] || own=", $PUT_MINE left to their owner"
    echo "$SK_CLI: $((PUT_COPIED + PUT_SAME)) resolved skill(s) in $pers ($PUT_COPIED copied, $PUT_SAME unchanged, $PRUNED removed$own): $NAME's whole view (registry skills shared: the latest hand-over wins for every session)."
    sk_reload_note "$new" "$pers"
    return "$PUT_RC"
  fi
  if [ -n "$forget" ]; then
    if [ -d "$me" ]; then rm -rf "$me"; echo "$SK_CLI: $NAME's own registry skills ($me) removed."
    else echo "$SK_CLI: $NAME has no registry skills of its own here; nothing to remove."; fi
  else
    [ -d "$me/$REG_ADD/$SK_OWN" ] || anew=1
    mkdir -p "$me/$REG_ADD/$SK_OWN" || die 1 "skills: cannot create $me."
    rm -rf "$me/.want.new"
    { mkdir -p "$me/.want.new" && cp -R "$src/." "$me/.want.new/"; } 2>/dev/null || { rm -rf "$me/.want.new"; die 1 "skills: copying the view into $me failed."; }
    if ! { rm -rf "$me/want" && mv "$me/.want.new" "$me/want"; }; then die 1 "skills: replacing $me/want failed."; fi
    printf '%s\t%s\t%s\n' "$NAME" "$FOLDER" "${COMPONENT_REGISTRY_PATH:-}" > "$me/agent"
  fi
  # an agent whose folder is gone is dropped (its sessions cannot start there any more)
  for a in "$base"/*/; do
    a="${a%/}"
    [ "$a" = "$me" ] && continue
    fo="$(cut -f2 "$a/agent" 2>/dev/null)"
    if [ -z "$fo" ] || [ ! -d "$fo" ]; then rm -rf "$a"; swept=$((swept + 1)); fi
  done
  # the split: a skill every agent's view has alike is personal, every other one is the agent's own
  local -a mirrors=() shared=() union=()
  local -A sk_seen=() isshared=()
  for a in "$base"/*/want; do [ -d "$a" ] && mirrors+=("$a"); done
  for a in "${mirrors[@]+"${mirrors[@]}"}"; do
    for d in "$a"/*/; do
      [ -d "$d" ] || continue
      nm="$(basename "$d")"
      [ -n "${sk_seen[$nm]:-}" ] && continue
      sk_seen[$nm]=1
      if skill_name_ok "$nm"; then union+=("$nm"); else note "skills: '$nm' is not a skill name; skipped."; fi
    done
  done
  for nm in "${union[@]+"${union[@]}"}"; do
    ok=1 ref=''
    for a in "${mirrors[@]}"; do
      [ -d "$a/$nm" ] || { ok=0; break; }
      if [ -z "$ref" ]; then ref="$a/$nm"; elif ! diff -rq "$ref" "$a/$nm" >/dev/null 2>&1; then ok=0; break; fi
    done
    [ "$ok" -eq 1 ] && { shared+=("$nm"); isshared[$nm]=1; }
  done
  # 1. every agent's own folder gets what it newly needs, 2. the personal folder becomes the shared
  # set, 3. each own folder drops what it no longer needs: a running session never misses a skill
  local -a mine_names=()
  PUT_RC=0
  for a in "${mirrors[@]+"${mirrors[@]}"}"; do
    local -a own_names=()
    for d in "$a"/*/; do nm="$(basename "$d")"; [ -d "$d" ] && skill_name_ok "$nm" && [ -z "${isshared[$nm]:-}" ] && own_names+=("$nm"); done
    PUT_COPIED=0 PUT_SAME=0 PUT_MINE=0
    put_skills "${a%/want}/$REG_ADD/$SK_OWN" "$a" "${own_names[@]+"${own_names[@]}"}"
    if [ "${a%/want}" = "$me" ]; then oc="$PUT_COPIED" os="$PUT_SAME"; mine_names=("${own_names[@]+"${own_names[@]}"}"); fi
  done
  PUT_COPIED=0 PUT_SAME=0 PUT_MINE=0 PRUNED=0
  [ "${#mirrors[@]}" -gt 0 ] && put_skills "$pers" "${mirrors[0]}" "${shared[@]+"${shared[@]}"}"
  prune_skills "$pers" "${shared[@]+"${shared[@]}"}"
  pc="$PUT_COPIED" ps="$PUT_SAME" pm="$PUT_MINE" pr="$PRUNED"
  for a in "${mirrors[@]+"${mirrors[@]}"}"; do
    local -a keep=()
    for d in "$a"/*/; do nm="$(basename "$d")"; [ -d "$d" ] && [ -z "${isshared[$nm]:-}" ] && keep+=("$nm"); done
    PRUNED=0
    prune_skills "${a%/want}/$REG_ADD/$SK_OWN" "${keep[@]+"${keep[@]}"}"
    [ "${a%/want}" = "$me" ] && orr="$PRUNED"
  done
  [ "$pm" -eq 0 ] || own=", $pm left to their owner"
  echo "$SK_CLI: $((pc + ps)) resolved skill(s) in $pers ($pc copied, $ps unchanged, $pr removed$own): the ones every agent's view has alike."
  [ "$swept" -eq 0 ] || echo "$SK_CLI: $swept agent(s) whose folder is gone no longer have registry skills of their own."
  if [ -z "$forget" ]; then
    echo "$SK_CLI: $((${oc:-0} + ${os:-0})) of $NAME's own in $me/$REG_ADD/$SK_OWN (${oc:-0} copied, ${os:-0} unchanged, ${orr:-0} removed), read through --add-dir $me/$REG_ADD."
    for nm in "${mine_names[@]+"${mine_names[@]}"}"; do
      sk_handover_clash "$nm" "$pers"
    done
    if [ -n "$anew" ]; then
      echo "$SK_CLI: $NAME's own skills folder is new: its next start passes --add-dir; a session of it running now reads it after /add-dir $me/$REG_ADD."
    fi
  fi
  sk_reload_note "$new" "$pers"
  return "$PUT_RC"
}

# sk_add_dir <args>... (at a start): ADD_DIR, the agent's own folder for --add-dir ('' when it has no
# skills folder), SK_HAS (1 when the args name it already: --add-dir <it>, --add-dir=<it>, or among
# several folders after one --add-dir) and SK_ARGS, the args with --add-dir <it> added last when the
# folder is there and the args do not name it. The adapter then runs set -- "${SK_ARGS[@]}".
sk_add_dir() {
  local a inadd=''
  SK_HAS='' SK_ARGS=("$@")
  ADD_DIR="$(agent_add_dir "$NAME" "$FOLDER")"
  if [ ! -d "$ADD_DIR/$SK_OWN" ]; then ADD_DIR=''; return 0; fi
  for a in "$@"; do
    case "$a" in
      --add-dir) inadd=1 ;;
      --add-dir=*) inadd=''; [ "${a#--add-dir=}" = "$ADD_DIR" ] && SK_HAS=1 ;;
      -*) inadd='' ;;
      *) [ -n "$inadd" ] && [ "$a" = "$ADD_DIR" ] && SK_HAS=1 ;;
    esac
  done
  [ -n "$SK_HAS" ] || SK_ARGS+=(--add-dir "$ADD_DIR")
}
# sk_start_line (after sk_add_dir, when ADD_DIR is set): one line, what the start passes (ADR-0074: the
# Operator asked for it to be seen), then a clash line for each own skill a CLI-side skill beats
sk_start_line() {
  local d
  note "$NAME: registry skills: $(count_owned "$(sk_home)/skills") shared, $(count_owned "$ADD_DIR/$SK_OWN") own -> --add-dir $ADD_DIR${SK_HAS:+ (already in its args)}"
  for d in "$ADD_DIR/$SK_OWN"/*/; do
    [ -f "$d$SKILLS_MARK" ] || continue
    sk_start_clash "$(basename "$d")"
  done
}
# <<< dcf-skills.sh <<<

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
  supports) printf '%s\n' new resume hint run-once skills skills-show supports; exit 0 ;;
  '') die 2 "usage: agent-adapter-copilot <verb> <name> <folder> [-- copilot args]" ;;
  start-bg | wake | attach | list | stop | logs | record | trust | session-busy | session-stop | session-remove)
    die 3 "'$verb' is not supported (Copilot CLI has no local background session, list or stop, and keeps its trusted folders itself)" ;;
  mcp-attach)
    target="${1:-}"
    [ "$target" = facilitator ] || die 2 "mcp-attach takes a target: facilitator (others are reserved)"
    command -v copilot >/dev/null 2>&1 || die 1 "copilot is not on PATH; the copilot Feature gets it from ghcr.io/devcontainers/features/copilot-cli"
    if ! command -v facilitator >/dev/null 2>&1; then
      echo "agent-adapter-copilot: the facilitator Feature is not installed; there is no entry to register (add it, then run task copilot:attach)"
      exit 0
    fi
    # shellcheck disable=SC2174  # only the last folder needs the mode
    if [ -n "${COPILOT_HOME:-}" ] && [ ! -d "$COPILOT_HOME" ]; then mkdir -p -m 0700 "$COPILOT_HOME" || die 1 "cannot create $COPILOT_HOME"; fi
    # remove then add: the CLI refuses a name that exists, and a stale entry must not stay
    copilot mcp remove facilitator </dev/null >/dev/null 2>&1 || true
    # shellcheck disable=SC2016  # the $ is for the sh that Copilot starts
    copilot mcp add facilitator </dev/null -- sh -c 'exec facilitator mcp --as "${FACILITATOR_HANDLE:?start copilot with FACILITATOR_HANDLE and FACILITATOR_TOKEN set}"' >/dev/null \
      || die 1 "'copilot mcp add facilitator' failed (is COPILOT_HOME private to its owner? Copilot refuses one writable by group or other)"
    echo "agent-adapter-copilot: registered the facilitator MCP entry (no token in it; start copilot with FACILITATOR_HANDLE and FACILITATOR_TOKEN set)"
    exit 0 ;;
  new | resume | hint | run-once | skills | skills-show) ;;
  *) die 3 "'$verb' is not supported" ;;
esac

[ $# -ge 2 ] || die 2 "$verb needs <name> <folder>"
NAME="$1" FOLDER="$2"; shift 2
# --extras (the contract's flag for stop) means nothing here; what follows the first -- is copilot's
while [ "${1:-}" = --extras ]; do shift; done
if [ "${1:-}" = -- ]; then shift; fi
SNAME="$NAME"
case "${AGENT_SESSION_NAME-}" in
  '') ;;
  *$'\n'* | *$'\r'* | *$'\t'*) note "$NAME: AGENT_SESSION_NAME has a line break or a tab; using the handle as the session name." ;;
  *) SNAME="$AGENT_SESSION_NAME" ;;
esac
[ -d "$FOLDER" ] || die 1 "$NAME: folder $FOLDER does not exist"
case "$verb" in
  skills) skills_handover; exit $? ;;
  skills-show) skills_show; exit $? ;;
esac
# The model (0.2.0): AGENT_MODEL, the model of the agent's definition in the component registry
# (participant 1.3.0), is passed as --model on new and resume, in place of any --model the args hold
# (the registry wins, the Operator's ruling of 2026-11-21; one line says what it replaced). A value
# that is not one word is left out with a note and the args are used as they are.
if [ -n "${AGENT_MODEL-}" ]; then
  case "$verb" in new | resume)
    model_re='^[][A-Za-z0-9._:/@-]+$'
    if [ "${#AGENT_MODEL}" -gt 100 ] || ! [[ "$AGENT_MODEL" =~ $model_re ]]; then
      note "$NAME: AGENT_MODEL is not one word; starting without it."
    else
      model_args=() model_was='' skip=0
      for a in "$@"; do
        if [ "$skip" -eq 1 ]; then model_was="$a"; skip=0; continue; fi
        case "$a" in
          --model) skip=1 ;;
          --model=*) model_was="${a#--model=}" ;;
          *) model_args+=("$a") ;;
        esac
      done
      [ -z "$model_was" ] || note "$NAME: the component registry's model $AGENT_MODEL replaces --model $model_was from the args."
      set -- --model "$AGENT_MODEL" ${model_args[@]+"${model_args[@]}"}
    fi ;;
  esac
fi

# (0.3.0, ADR-0077) the agent's own registry skills: every session of it the adapter starts (new,
# resume, run-once) gets --add-dir <its folder>, last, once; Copilot loads .github/skills under it.
case "$verb" in
  new | resume | run-once)
    sk_add_dir "$@"
    set -- "${SK_ARGS[@]+"${SK_ARGS[@]}"}"
    if [ -n "$ADD_DIR" ] && [ "$verb" != run-once ]; then sk_start_line; fi ;;
esac

case "$verb" in
  hint)
    echo "$NAME has no list to read (Copilot CLI has none); resume its conversation by hand: cd '$FOLDER' && copilot --resume '$SNAME'"
    exit 0 ;;
  new)
    command -v copilot >/dev/null 2>&1 || die 1 "copilot is not on PATH"
    cd "$FOLDER" && exec copilot --name "$SNAME" "$@" ;;
  resume)
    command -v copilot >/dev/null 2>&1 || die 1 "copilot is not on PATH"
    cd "$FOLDER" && exec copilot --resume "$SNAME" "$@" ;;
  run-once)
    prompt="$(cat)"
    case "$prompt" in *[![:space:]]*) ;; *) die 2 "run-once reads the prompt from stdin and got none" ;; esac
    [ "${#prompt}" -le 100000 ] || die 2 "run-once: the prompt is ${#prompt} bytes; the limit is 100000 (it travels as one argument)"
    command -v copilot >/dev/null 2>&1 || die 1 "copilot is not on PATH"
    args=(-p "$prompt" --silent --no-ask-user --no-auto-update)
    case "${AGENT_ADAPTER_COPILOT_ALLOW_ALL_TOOLS:-}" in 1 | true | yes) args+=(--allow-all-tools) ;; esac
    case "${AGENT_ADAPTER_COPILOT_CONTINUE:-}" in
      1 | true | yes)
        # a UUID that is the same for one (name, folder): sha256 of both, shaped as a version 5 UUID
        h="$(printf '%s\0%s' "$NAME" "$FOLDER" | sha256sum | cut -c1-32)"
        v="$(printf '%x' $(( (0x${h:16:1} & 3) | 8 )))"
        args+=(--session-id "${h:0:8}-${h:8:4}-5${h:13:3}-${v}${h:17:3}-${h:20:12}") ;;
    esac
    cd "$FOLDER" && exec copilot "${args[@]}" "$@" </dev/null ;;
esac
