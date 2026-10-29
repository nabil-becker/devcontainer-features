#!/usr/bin/env bash
# agents: one list of a repository's agents, two kinds, one verb for every agent CLI.
# Installed on PATH by the agents Feature; behind `task agents -- <name>` and the other
# agents:* tasks inside, and `task devcontainer:agent -- <name>` from the host.
#
#   agents start <name> [--resume | --new [--yes]] [--] [extra CLI args...]
#   agents [start]   (no name: starts the agent marked `default: true` in the list; none: this text)
#   agents up [--no-wait] [--post-start]
#   agents list [--json]
#   agents stop <name> [--extras]
#   agents logs <name>
#   agents check
#   agents reset <name>... | --all [--purge] [--include-unlisted] [--yes] [--force]
#   agents leases [--json]
#   agents release <name> [--force]
#
# The list (the agent list) is a small YAML file, .devcontainer/agents.yml unless
# AGENTS_FILE names another path, relative to the repository root (the nearest folder at
# or above the current one holding .devcontainer). AGENTS_FILE is resolved like every
# setting (NFR-6): the task variable (passed here as AGENTS_FILE_TASK_VAR), then the root
# .env, then .devcontainer/.env, then the environment, then the default.
#
#   agents:
#     - name: host            # unique; letters, digits, - and _
#       cli: claude           # picks the adapter: agent-adapter-claude on PATH
#       kind: on-demand       # resident | on-demand
#       folder: .             # repo-relative (default .)
#       args: [--remote-control]   # handed to the CLI as they are (default none)
#       lifecycle: stateful   # stateful (default) | ephemeral (on-demand only)
#       identity: host        # the principal it acts as (default the name)
#       lease: container      # container (stateful, the default) | none (ephemeral)
#       definition: host      # the CLI's agent profile; read and checked, not passed yet
#       default: true         # at most one: what `agents` with no name starts
#
# Only that subset of YAML is read (comments, plain and quoted scalars, a flow or block
# list for args); the parser is awk, because bash, awk and sed are what every base image
# has (python3 and jq are not). Unknown keys are a warning.
#
# The lease (2.0). A stateful agent runs as exactly one live copy: every start through
# agents takes its lease first (the folder leases/<name> in the state folder, made with
# mkdir), a second start of a resident joins the running one and a second start of an
# on-demand agent is refused (exit 2). A dead holder's lease is taken over. An ephemeral
# agent takes none. `leases` shows them; `release` frees a dead one (--force a live one).
#
# Kinds. resident: runs in the background; start = make sure it runs, then attach.
# on-demand: start = a new session in this terminal; --resume opens its latest one.
# Without a terminal (stdin or stdout not a TTY) a resident is made to run and the
# attach command is printed (exit 0); an on-demand agent is refused (exit 2).
#
# Adapters (the contract, docs/proposals/agents.md section 5): each CLI Feature installs
#   agent-adapter-<cli> <verb> <name> <folder> [--extras] [-- args...]
# with the verbs start-bg, wake, attach, resume, new, list, stop, logs, supports, and the
# optional hint, record and (`agent-adapter-<cli> <verb> <id>`) session-busy, session-stop, session-remove. Exit 0
# done, 1 failed, 2 bad use, 3 not supported by this CLI; `list` prints
# name<TAB>id<TAB>state<TAB>folder per session, newest first (state running, stopped or
# failed). An unsupported verb falls back as section 6 says and says so in one line;
# a fallback never starts a second copy of something that may be running. A `list` that
# fails (any exit but 0 and 3) is not "cannot list": the agent's state is error, a resident
# is not started (the adapter's optional `hint <name> <folder>` says how to resume by hand),
# and nothing turns into a fresh session in its place.
#
# Exit: 0 done, 1 failed, 2 bad use (unknown agent, bad list, refused), 3 the CLI cannot.
set -uo pipefail

STATE_DIR="${AGENTS_STATE_DIR:-/var/lib/devcontainer-features/agents}"
DEFAULT_FILE=.devcontainer/agents.yml

warn() { printf 'agents: %s\n' "$*" >&2; }
die() { local rc="$1"; shift; printf 'agents: %s\n' "$*" >&2; exit "$rc"; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

# ------------------------------------------------------------ the list file ----
find_root() { # the nearest folder at or above here holding .devcontainer; else here
  local d
  d="$(pwd -P)"
  while :; do
    [ -d "$d/.devcontainer" ] && { printf '%s' "$d"; return 0; }
    [ "$d" = / ] && break
    d="$(dirname "$d")"
  done
  pwd -P
}

# dotenv_value <file> <var>: the value of the last line for var in the file (quotes,
# export and a trailing comment dropped); returns 1 when the file has no line for it.
dotenv_value() {
  grep -q "^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=" "$1" 2>/dev/null || return 1
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=[[:space:]]*//p" "$1" | tail -n 1 | tr -d '\r' |
    sed "s/[[:space:]]\{1,\}#.*\$//; s/[[:space:]]*\$//; s/^\"\(.*\)\"\$/\1/; s/^'\(.*\)'\$/\1/"
}

# resolve_file: ROOT, AF (as given), AF_SOURCE (where it came from), AF_ABS.
# Task hands its variable over as AGENTS_FILE_TASK_VAR; Task fills that variable from
# .env and the environment too, so it counts as a task variable only when it differs
# from both.
resolve_file() {
  local tv="${AGENTS_FILE_TASK_VAR:-}" ev="${AGENTS_FILE:-}" dv='' dsrc='' f v
  ROOT="$(find_root)"
  for f in "$ROOT/.env" "$ROOT/.devcontainer/.env"; do
    if [ -f "$f" ] && v="$(dotenv_value "$f" AGENTS_FILE)"; then
      dv="$v" dsrc="${f#"$ROOT"/}"
      break
    fi
  done
  if [ -n "$tv" ] && [ "$tv" != "$dv" ] && [ "$tv" != "$ev" ]; then
    AF="$tv" AF_SOURCE='the task variable AGENTS_FILE'
  elif [ -n "$dv" ]; then
    AF="$dv" AF_SOURCE="AGENTS_FILE in $dsrc"
  elif [ -n "$ev" ]; then
    AF="$ev" AF_SOURCE='AGENTS_FILE in the environment'
  else
    AF="$DEFAULT_FILE" AF_SOURCE='the default (AGENTS_FILE is not set)'
  fi
  case "$AF" in /*) AF_ABS="$AF" ;; *) AF_ABS="$ROOT/$AF" ;; esac
}

# The parser: the YAML subset above, one record per line out:
#   I <n> <line>             an entry starts
#   K <n> <key> <value>      name, cli, kind, folder, lifecycle, identity, lease, definition, default
#   A <n>                    the entry has args
#   G <n> <value>            one arg
#   W <line> <message>       a warning
#   E <line> <message>       an error (the last line)
# Written for mawk as well as gawk: no gensub, no regex intervals.
read -r -d '' PARSER <<'AWK'
function fail(msg) { printf "E\t%d\t%s\n", NR, msg; failed = 1; exit 2 }
function ind(s) { match(s, /^ */); return RLENGTH }
function plain(s,   i) {
  if (substr(s, 1, 1) == "#") return ""
  i = index(s, " #"); if (i > 0) s = substr(s, 1, i - 1)
  sub(/[ \t]+$/, "", s); return s
}
# quoted(s): s starts with a quote; sets QV (the value) and QR (the text after it)
function quoted(s,   q, i, ch, r, n) {
  q = substr(s, 1, 1); r = ""; i = 2; n = length(s)
  while (i <= n) {
    ch = substr(s, i, 1)
    if (q == "'" && ch == "'") { if (substr(s, i + 1, 1) == "'") { r = r "'"; i += 2; continue } ; break }
    if (q == "\"" && ch == "\\") { r = r substr(s, i + 1, 1); i += 2; continue }
    if (q == "\"" && ch == "\"") break
    r = r ch; i++
  }
  if (i > n) fail("a quoted value is not closed")
  QV = r; QR = substr(s, i + 1); sub(/^[ \t]+/, "", QR)
}
function scalar(s, what) {
  if (s ~ /^["']/) {
    quoted(s)
    if (QR != "" && substr(QR, 1, 1) != "#") fail("text after the quoted value of " what)
    return QV
  }
  if (s ~ /^[\[\{|>&*!%@`]/) fail(what " must be a plain or quoted value")
  return plain(s)
}
function emit_arg(v) {
  if (v == "") fail("an empty argument")
  if (v ~ /\t/) fail("a tab in an argument")
  printf "G\t%d\t%s\n", n, v
}
# flow(s): a [a, "b c", 'd'] list on one line
function flow(s,   v, ch) {
  s = substr(s, 2)
  while (1) {
    sub(/^[ \t]+/, "", s)
    if (s == "") fail("a [ list must close on the same line")
    ch = substr(s, 1, 1)
    if (ch == "]") { s = substr(s, 2); break }
    if (ch == "\"" || ch == "'") { quoted(s); v = QV; s = QR }
    else {
      if (ch == "[" || ch == "{") fail("nested lists are not supported in args")
      v = s; sub(/[,\]].*$/, "", v); s = substr(s, length(v) + 1); sub(/[ \t]+$/, "", v)
      if (v == "") fail("an empty item in the args list")
    }
    emit_arg(v)
    sub(/^[ \t]+/, "", s)
    ch = substr(s, 1, 1)
    if (ch == ",") { s = substr(s, 2); continue }
    if (ch == "]") { s = substr(s, 2); break }
    fail("expected , or ] in the args list")
  }
  sub(/^[ \t]+/, "", s)
  if (s != "" && substr(s, 1, 1) != "#") fail("text after the args list")
}
function keyline(t,   k, v) {
  if (t !~ /^[A-Za-z0-9_-]+:/) fail("expected key: value")
  k = t; sub(/:.*/, "", k)
  v = substr(t, length(k) + 2)
  if (v != "" && v !~ /^[ \t]/) fail("expected a space after " k ":")
  sub(/^[ \t]+/, "", v)
  if ((n, k) in seen) fail("'" k "' appears twice in one entry")
  seen[n, k] = 1
  inargs = 0; skipping = 0
  if (k == "args") {
    printf "A\t%d\n", n
    if (v == "" || substr(v, 1, 1) == "#") { inargs = 1; return }
    if (substr(v, 1, 1) == "[") { flow(v); return }
    fail("args must be a list: args: [--model, opus], or one - value per line below it")
  }
  if (k == "name" || k == "cli" || k == "kind" || k == "folder" || k == "lifecycle" || k == "identity" || k == "lease" || k == "definition" || k == "default") {
    if (v == "" || substr(v, 1, 1) == "#") fail("'" k "' has no value")
    if (k == "lease" && substr(v, 1, 1) == "{") fail("lease is one word, not a map: lease: container (or none)")
    v = scalar(v, "'" k "'")
    if (v ~ /\t/) fail("a tab in the value of '" k "'")
    printf "K\t%d\t%s\t%s\n", n, k, v
    return
  }
  printf "W\t%d\tunknown key '%s' (ignored)\n", NR, k
  skipping = 1
}
BEGIN { n = 0; itemind = -1; keyind = -1; inagents = 0; sawagents = 0; skiptop = 0 }
{
  line = $0; sub(/\r$/, "", line)
  t = line; sub(/^ +/, "", t)
  if (t == "" || substr(t, 1, 1) == "#") next
  if (substr(t, 1, 1) == "\t") fail("a tab in the indentation; indent with spaces")
  i = ind(line)
  if (i == 0) {
    if (t == "---") next
    inagents = 0; skiptop = 0; inargs = 0; skipping = 0
    if (t ~ /^agents:/) {
      if (sawagents) fail("'agents' appears twice")
      sawagents = 1
      v = plain(substr(t, 8)); sub(/^[ \t]+/, "", v)
      if (v == "") { inagents = 1; next }
      if (v ~ /^\[[ ]*\]$/) next
      fail("agents must be a list of entries, one '- name: ...' each")
    }
    if (t ~ /^[A-Za-z0-9_-]+:/) { k = t; sub(/:.*/, "", k); printf "W\t%d\tunknown top-level key '%s' (ignored)\n", NR, k; skiptop = 1; next }
    fail("expected agents: at the top level")
  }
  if (skiptop) next
  if (!inagents) fail("unexpected indentation")
  if (skipping && keyind >= 0 && i > keyind) next
  skipping = 0
  if (t == "-" || substr(t, 1, 2) == "- ") {
    if (inargs && i > itemind) {
      v = substr(t, 2); sub(/^[ \t]+/, "", v)
      if (v == "" || substr(v, 1, 1) == "#") fail("an empty item in the args list")
      emit_arg(scalar(v, "an argument"))
      next
    }
    if (itemind < 0) itemind = i
    if (i != itemind) fail("a list item at the wrong indentation")
    n++; inargs = 0
    printf "I\t%d\t%d\n", n, NR
    rest = substr(t, 2)
    if (rest ~ /^ *$/) { keyind = -1; next }
    if (rest ~ /^ *#/) { keyind = -1; next }
    keyind = i + 1 + ind(rest)
    sub(/^ +/, "", rest)
    if (substr(rest, 1, 1) == "{") fail("write an entry as key: value lines, not { }")
    keyline(rest)
    next
  }
  if (n == 0) fail("expected a list item, - name: ...")
  if (keyind < 0) { if (i <= itemind) fail("unexpected indentation"); keyind = i }
  if (i != keyind) fail("unexpected indentation")
  keyline(t)
}
END {
  if (failed) exit 2
  if (!sawagents) { printf "E\t0\tno agents: list in the file\n"; exit 2 }
}
AWK

# load_list: parse and check AF_ABS into N and the arrays NAME, CLI, KIND, FOLDER, ARGS
# (args joined by \x1f), LINE. A broken list exits 2 with every problem named.
load_list() {
  local out rc rec a b c errs=0 i j
  resolve_file
  if [ ! -f "$AF_ABS" ]; then
    die 2 "no agent list at $AF_ABS (from $AF_SOURCE); write one (see the agents Feature notes) or set AGENTS_FILE to its path relative to $ROOT."
  fi
  out="$(awk "$PARSER" "$AF_ABS")"; rc=$?
  N=0 NAME=() CLI=() KIND=() FOLDER=() ARGS=() LINE=() HASARGS=() LIFE=() IDENT=() LEASE=() DEF=() DFLT=()
  while IFS=$'\t' read -r rec a b c; do
    case "$rec" in
      I) N="$a"; LINE[a]="$b" FOLDER[a]=. ARGS[a]='' ;;
      K) case "$b" in
           name) NAME[a]="$c" ;; cli) CLI[a]="$c" ;; kind) KIND[a]="$c" ;; folder) FOLDER[a]="$c" ;;
           lifecycle) LIFE[a]="$c" ;; identity) IDENT[a]="$c" ;; lease) LEASE[a]="$c" ;; definition) DEF[a]="$c" ;; default) DFLT[a]="$c" ;;
         esac ;;
      A) HASARGS[a]=1 ;;
      G) if [ -n "${ARGS[a]:-}" ]; then ARGS[a]="${ARGS[a]}"$'\x1f'"$b"; else ARGS[a]="$b"; fi ;;
      W) warn "$AF:$a: $b" ;;
      E) die 2 "$AF:$a: $b" ;;
    esac
  done <<< "$out"
  [ "$rc" -eq 0 ] || die 2 "$AF: could not be read"
  for ((i = 1; i <= N; i++)); do
    local at="$AF:${LINE[i]}: entry $i"
    for a in name cli kind; do
      case "$a" in name) b="${NAME[i]:-}" ;; cli) b="${CLI[i]:-}" ;; kind) b="${KIND[i]:-}" ;; esac
      [ -n "$b" ] || { warn "$at has no '$a' (name, cli and kind are required)"; errs=$((errs + 1)); }
    done
    if [ -n "${NAME[i]:-}" ] && ! [[ "${NAME[i]}" =~ ^[A-Za-z0-9_-]+$ ]]; then
      warn "$at: name '${NAME[i]}' may hold only letters, digits, - and _"; errs=$((errs + 1))
    fi
    if [ -n "${CLI[i]:-}" ] && ! [[ "${CLI[i]}" =~ ^[A-Za-z0-9_-]+$ ]]; then
      warn "$at: cli '${CLI[i]}' may hold only letters, digits, - and _"; errs=$((errs + 1))
    fi
    case "${KIND[i]:-}" in resident | on-demand | '') ;; *) warn "$at: kind '${KIND[i]}' is neither resident nor on-demand"; errs=$((errs + 1)) ;; esac
    case "${FOLDER[i]}" in
      /*) warn "$at: folder '${FOLDER[i]}' must be relative to the repository root"; errs=$((errs + 1)) ;;
      .. | ../* | */.. | */../*) warn "$at: folder '${FOLDER[i]}' must stay inside the repository"; errs=$((errs + 1)) ;;
    esac
    for ((j = 1; j < i; j++)); do
      if [ -n "${NAME[i]:-}" ] && [ "${NAME[i]}" = "${NAME[j]:-}" ]; then
        warn "$at: name '${NAME[i]}' is already used by entry $j"; errs=$((errs + 1))
      fi
    done
    check_v2 "$i" "$at"; errs=$((errs + V2ERRS))
  done
  [ "$errs" -eq 0 ] || die 2 "$AF: $errs problem(s) in the agent list (above)."
}

# check_v2 <i> <at>: the 2.0 keys of entry i (lifecycle, identity, lease, definition), their
# defaults filled in; V2ERRS counts the problems (each said with its file and line).
check_v2() {
  local i="$1" at="$2" j a
  V2ERRS=0
  case "${LIFE[i]:-}" in
    '') LIFE[i]=stateful ;;
    stateful | ephemeral) ;;
    *) warn "$at: lifecycle '${LIFE[i]}' is neither stateful nor ephemeral"; V2ERRS=$((V2ERRS + 1)) ;;
  esac
  if [ "${LIFE[i]}" = ephemeral ] && [ "${KIND[i]:-}" = resident ]; then
    warn "$at: an ephemeral agent cannot be resident (the container start would create and discard it every time); make it on-demand, or stateful"; V2ERRS=$((V2ERRS + 1))
  fi
  case "${LEASE[i]:-}" in
    '') if [ "${LIFE[i]}" = ephemeral ]; then LEASE[i]=none; else LEASE[i]=container; fi ;;
    container)
      if [ "${LIFE[i]}" = ephemeral ]; then
        warn "$at: lease 'container' is for a stateful agent; an ephemeral agent takes no lease (lease: none, or leave it out)"; V2ERRS=$((V2ERRS + 1))
      fi ;;
    none)
      if [ "${LIFE[i]}" != ephemeral ]; then
        warn "$at: a stateful agent always holds its lease (lease: container); an agent without one is lifecycle: ephemeral"; V2ERRS=$((V2ERRS + 1))
      fi ;;
    machine | cluster)
      warn "$at: lease '${LEASE[i]}' is not supported: a lease beyond one container needs an atomic step shared by the containers, which bash, awk and sed do not have (the agents Feature notes say why); use lease: container"; V2ERRS=$((V2ERRS + 1)) ;;
    *) warn "$at: lease '${LEASE[i]}' is neither container nor none"; V2ERRS=$((V2ERRS + 1)) ;;
  esac
  [ -n "${IDENT[i]:-}" ] || IDENT[i]="${NAME[i]:-}"
  if [ -n "${IDENT[i]}" ] && ! [[ "${IDENT[i]}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    warn "$at: identity '${IDENT[i]}' may hold only letters, digits, - and _"; V2ERRS=$((V2ERRS + 1))
  fi
  if [ -n "${DEF[i]:-}" ]; then
    if ! [[ "${DEF[i]}" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
      warn "$at: definition '${DEF[i]}' may hold only letters, digits, ., :, - and _"; V2ERRS=$((V2ERRS + 1))
    fi
    args_of "$i"
    for a in ${CLIARGS[@]+"${CLIARGS[@]}"}; do
      case "$a" in
        --agent | --agent=*)
          warn "$at: definition '${DEF[i]}' and --agent in args name the profile twice; keep one"; V2ERRS=$((V2ERRS + 1)); break ;;
      esac
    done
  fi
  case "${DFLT[i]:-}" in
    '' | false) DFLT[i]='' ;;
    true)
      DFLT[i]=1
      for ((j = 1; j < i; j++)); do
        if [ -n "${DFLT[j]:-}" ]; then
          warn "$at: '${NAME[i]:-}' is marked default, and so is '${NAME[j]:-}' (entry $j); mark at most one agent default: true"; V2ERRS=$((V2ERRS + 1))
        fi
      done ;;
    *) warn "$at: default '${DFLT[i]}' is neither true nor false"; DFLT[i]=''; V2ERRS=$((V2ERRS + 1)) ;;
  esac
  [ "${LIFE[i]}" = stateful ] || return 0
  for ((j = 1; j < i; j++)); do
    if [ "${LIFE[j]}" = stateful ] && [ -n "${IDENT[i]}" ] && [ "${IDENT[i]}" = "${IDENT[j]}" ]; then
      warn "$at: identity '${IDENT[i]}' is already the identity of the stateful agent '${NAME[j]:-}' (entry $j); two stateful agents cannot share one (it would run as two live copies)"
      V2ERRS=$((V2ERRS + 1))
    fi
  done
}

# find_agent <name>: AI, the entry's index; exits 2 naming the agents when there is none.
find_agent() {
  local i names=''
  for ((i = 1; i <= N; i++)); do
    [ "${NAME[i]}" = "$1" ] && { AI="$i"; return 0; }
    names="$names ${NAME[i]}"
  done
  die 2 "no agent '$1' in $AF (agents:${names:- none})."
}

# default_agent: the name of the agent marked default: true, empty when none (or no list)
default_agent() {
  local i
  resolve_file
  [ -f "$AF_ABS" ] || return 0
  load_list
  for ((i = 1; i <= N; i++)); do [ -z "${DFLT[i]:-}" ] || { printf '%s' "${NAME[i]}"; return 0; }; done
}

args_of() { # the entry's args into the array CLIARGS
  CLIARGS=()
  [ -n "${HASARGS[$1]:-}" ] || return 0
  local IFS=$'\x1f'
  read -r -a CLIARGS <<< "${ARGS[$1]}"
}

# ---------------------------------------------------------------- adapters ----
feature_of() {
  case "$1" in
    claude) echo 'the claude-code Feature (1.7.0 or later)' ;;
    *) echo "the Feature of that CLI that provides agent-adapter-$1" ;;
  esac
}

# adapter_of <i>: ADAPTER and DIR (the absolute folder) for entry i; returns 1 (said) when
# the adapter or the folder is missing.
adapter_of() {
  local i="$1"
  ADAPTER="$(command -v "agent-adapter-${CLI[i]}" 2>/dev/null)" || ADAPTER=''
  if [ -z "$ADAPTER" ]; then
    warn "${NAME[i]}: no adapter for cli '${CLI[i]}' (agent-adapter-${CLI[i]} is not on PATH); add $(feature_of "${CLI[i]}") to devcontainer.json."
    return 1
  fi
  if ! DIR="$(cd "$ROOT/${FOLDER[i]}" 2>/dev/null && pwd -P)"; then
    warn "${NAME[i]}: folder '${FOLDER[i]}' does not exist under $ROOT."
    return 1
  fi
}

declare -A LISTS=() LIST_RC=() LIST_ERR=()
# sessions_of <cli>: the adapter's list, read once per run (LISTS, LIST_RC: 0 read, 3 the CLI
# cannot list, anything else the listing failed; LIST_ERR: what the adapter said, one line).
sessions_of() {
  local cli="$1" out rc errf err=''
  [ -n "${LIST_RC[$cli]:-}" ] && return 0
  errf="$(mktemp 2>/dev/null)" || errf=''
  out="$("$ADAPTER" list </dev/null 2>"${errf:-/dev/null}")"; rc=$?
  if [ -n "$errf" ]; then
    err="$(tr -d '\r' < "$errf" | sed '/^[[:space:]]*$/d; s/^agent-adapter-[A-Za-z0-9_-]*: //' | head -n 3 | tr '\n' ' ' | cut -c1-400)"
    [ "$rc" -eq 0 ] && cat "$errf" >&2
    rm -f "$errf"
  fi
  LISTS[$cli]="$out" LIST_RC[$cli]="$rc" LIST_ERR[$cli]="${err% }"
}
reread() { unset 'LIST_RC[$1]'; sessions_of "$1"; }

# state_of <i>: STATE (running, stopped, failed, none, unknown, error), SID (the id) and
# EXTRAS (how many more running sessions the agent has) from the adapter's list; a session
# is the agent's when its folder is the agent's and its name is the agent's name, or the
# name with a collision number, "host (2)". unknown: the CLI cannot list (exit 3, the
# agreed fallback); error: the listing failed (returns 1; nothing may be started on it). An
# on-demand agent shows only a running session; otherwise none (its stopped ones are only
# what --resume reaches).
state_of() {
  local i="$1" cli="${CLI[$1]}" nm id st fo first='' firstst='' running=0 runid=''
  sessions_of "$cli"
  STATE=none SID='' EXTRAS=0
  if [ "${LIST_RC[$cli]}" = 3 ]; then STATE=unknown; return 0; fi
  if [ "${LIST_RC[$cli]}" != 0 ]; then STATE=error; return 1; fi
  while IFS=$'\t' read -r nm id st fo; do
    [ -n "${nm:-}" ] || continue
    [ "$fo" = "$DIR" ] || continue
    case "$nm" in "${NAME[i]}") ;; "${NAME[i]} ("*")") [[ "$nm" =~ \([0-9]+\)$ ]] || continue ;; *) continue ;; esac
    if [ "$st" = running ]; then
      running=$((running + 1)); [ -z "$runid" ] && runid="$id"
    fi
    [ -z "$first" ] && { first="$id"; firstst="$st"; }
  done <<< "${LISTS[$cli]}"
  if [ "$running" -gt 0 ]; then STATE=running SID="$runid" EXTRAS=$((running - 1))
  elif [ -n "$first" ] && [ "${KIND[i]}" != on-demand ]; then STATE="$firstst" SID="$first"
  fi
  return 0
}

# list_failed <i>: say that the agent's sessions could not be listed (the adapter's reason),
# that nothing was started, and how to find and resume it by hand (the adapter's hint verb,
# else a general line).
list_failed() {
  local i="$1" cli="${CLI[$1]}" h
  warn "${NAME[i]}: the $cli sessions could not be listed${LIST_ERR[$cli]:+ (${LIST_ERR[$cli]})}; starting nothing, since it may be running or have a conversation to resume."
  if h="$("$ADAPTER" hint "${NAME[i]}" "$DIR" </dev/null 2>/dev/null)" && [ -n "$h" ]; then
    printf '%s\n' "$h" | sed "s/^/agents: ${NAME[i]}: /" >&2
  else
    warn "${NAME[i]}: check with $cli itself whether it runs, and resume its conversation by hand if it does not."
  fi
}

call() { # call <verb> <i> [adapter flags]: the adapter for entry i, CLI args after --
  local verb="$1" i="$2"; shift 2
  args_of "$i"
  "$ADAPTER" "$verb" "${NAME[i]}" "$DIR" "$@" -- ${CLIARGS[@]+"${CLIARGS[@]}"} ${PASS[@]+"${PASS[@]}"}
}

has_tty() {
  case "${AGENTS_TTY:-}" in 1) return 0 ;; 0) return 1 ;; esac
  [ -t 0 ] && [ -t 1 ]
}

# ------------------------------------------------- once per container start ----
start_id() {
  if [ -n "${AGENTS_START_ID:-}" ]; then printf '%s' "$AGENTS_START_ID"; return; fi
  # field 22 of /proc/1/stat: when PID 1 (the container's init) started; new on every start
  awk '{ print $22 }' /proc/1/stat 2>/dev/null || echo unknown
}
marker() { printf '%s/%s/%s/%s' "$STATE_DIR" "$(start_id)" "$(printf '%s' "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')" "$1"; }
mark_started() {
  local m; m="$(marker "$1")"
  if ! { mkdir -p "$(dirname "$m")" && : > "$m"; } 2>/dev/null; then
    warn "$1: could not write the start marker under $STATE_DIR."
  fi
}
marked() { [ -e "$(marker "$1")" ]; }

# ------------------------------------------------------------------ the lease ----
# A stateful agent's exclusive lease (docs/proposals/agents-v2.md section 6): the folder
# leases/<name> under the state folder exists while someone holds it; mkdir is the atomic take.
# Its holder file (key=value lines, written to a temporary name and renamed): state
# (starting|held), pid and pidstart (the agents process that took it), boot (field 22 of
# /proc/1/stat, or AGENTS_START_ID) and container (the hostname), carrier (session:<id>,
# process:<pid> or pending), time. Liveness (first rule that applies): no holder file and the
# folder older than 5 s: dead, younger: starting; another boot or container: dead; starting:
# alive while its pid is; held: alive while its pid is or the adapter's list shows the agent
# running; the adapter cannot list: cannot tell (held; never taken over on a guess); the
# listing failed: error (held). A takeover is serialised by leases/<name>.takeover (mkdir),
# re-judges the holder, renames the old folder away and takes it with mkdir. Folders are
# made 0777 (no sticky bit), so a holder of another user can be taken over and removed.
LEASE_DIR="$STATE_DIR/leases"
declare -A LEASE_TIME=()
LEASES_MINE='' # names whose lease this process holds and releases when it exits
LV='' LV_WHY='' LH_STATE='' LH_PID='' LH_PIDSTART='' LH_BOOT='' LH_CONTAINER='' LH_CARRIER='' LH_TIME='' LH_RAW='' JOINED=''

container_id() { cat /proc/sys/kernel/hostname 2>/dev/null || uname -n; }
# proc_start <pid>: when the process started (field 22 of its stat); fails when it is gone or a zombie
proc_start() {
  local s
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  s="$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null)" || return 1
  [ -n "$s" ] || return 1
  printf '%s\n' "$s" | awk '$1 == "Z" { exit 1 } { print $20 }'
}
pid_alive() { local s; s="$(proc_start "$1")" && [ -n "$s" ] && [ "$s" = "$2" ]; }
fmt_time() { date -d "@$1" +%H:%M:%S 2>/dev/null || printf '%s' "$1"; }

holder_write() { # <name> <state> <carrier>
  local d="$LEASE_DIR/$1" t
  t="$d/.holder.$$"
  [ -n "${LEASE_TIME[$1]:-}" ] || LEASE_TIME[$1]="$(date +%s)"
  { printf 'state=%s\npid=%s\npidstart=%s\nboot=%s\ncontainer=%s\ncarrier=%s\ntime=%s\n' \
      "$2" "$$" "$(proc_start $$)" "$(start_id)" "$(container_id)" "$3" "${LEASE_TIME[$1]}" > "$t" &&
      mv -f "$t" "$d/holder"; } 2>/dev/null
}
# holder_read <folder>: LH_* from its holder file (LH_RAW the whole file); 1 when there is none
holder_read() {
  local k v
  LH_STATE='' LH_PID='' LH_PIDSTART='' LH_BOOT='' LH_CONTAINER='' LH_CARRIER='' LH_TIME='' LH_RAW=''
  [ -f "$1/holder" ] || return 1
  LH_RAW="$(cat "$1/holder" 2>/dev/null)" || return 1
  while IFS='=' read -r k v; do
    case "$k" in
      state) LH_STATE="$v" ;; pid) LH_PID="$v" ;; pidstart) LH_PIDSTART="$v" ;; boot) LH_BOOT="$v" ;;
      container) LH_CONTAINER="$v" ;; carrier) LH_CARRIER="$v" ;; time) LH_TIME="$v" ;;
    esac
  done <<< "$LH_RAW"
}

# lease_verdict <i or empty> <name> [fresh]: LV (free, dead, starting, held, cannot-tell, error)
# and LV_WHY (why dead: no-holder, new-container, start-died, session-gone), the holder in LH_*.
# fresh: read the adapter's list again rather than this run's copy (a taker must see now).
lease_verdict() {
  local i="$1" h="$2" fresh="${3:-}" d="$LEASE_DIR/$2" age
  LV='' LV_WHY=''
  if ! holder_read "$d"; then
    [ -d "$d" ] || { LV=free; return 0; }
    age=$(($(date +%s) - $(stat -c %Y "$d" 2>/dev/null || date +%s)))
    if [ "$age" -gt 5 ]; then LV=dead LV_WHY=no-holder; else LV=starting; fi
    return 0
  fi
  if [ "$LH_BOOT" != "$(start_id)" ] || [ "$LH_CONTAINER" != "$(container_id)" ]; then
    LV=dead LV_WHY=new-container; return 0
  fi
  if [ "$LH_STATE" = starting ]; then
    if pid_alive "$LH_PID" "$LH_PIDSTART"; then LV=starting; else LV=dead LV_WHY=start-died; fi
    return 0
  fi
  if pid_alive "$LH_PID" "$LH_PIDSTART"; then LV=held; return 0; fi
  if [ -z "$i" ] || ! adapter_of "$i" 2>/dev/null; then LV=cannot-tell; return 0; fi
  [ -z "$fresh" ] || unset 'LIST_RC[${CLI[i]}]'
  if ! state_of "$i"; then LV=error; return 0; fi
  case "$STATE" in
    running) LV=held ;;
    unknown) LV=cannot-tell ;;
    *) LV=dead LV_WHY=session-gone ;;
  esac
}

# takeover_lock <name>: mkdir leases/<name>.takeover, waiting 0.2 s at a time; a lock whose pid
# is gone, or still there after 5 s, is stale and cleared.
takeover_lock() {
  local t="$LEASE_DIR/$1.takeover" n=0 p='' ps='' p2 ps2
  while ! mkdir -m 0777 "$t" 2>/dev/null; do
    if read -r p ps < "$t/pid" 2>/dev/null && ! pid_alive "$p" "$ps"; then
      read -r p2 ps2 < "$t/pid" 2>/dev/null && [ "$p2 $ps2" = "$p $ps" ] && rm -rf "$t"
      continue
    fi
    n=$((n + 1))
    if [ "$n" -ge 25 ]; then rm -rf "$t"; n=0; continue; fi
    sleep 0.2
  done
  printf '%s %s\n' "$$" "$(proc_start $$)" > "$t/pid" 2>/dev/null
}
takeover_unlock() { rm -rf "$LEASE_DIR/$1.takeover"; }

# lease_own <name>: this process now holds it (state starting) and releases it when it exits,
# also on TERM and HUP, unless lease_keep hands it to a background carrier.
lease_own() {
  LEASE_TIME[$1]="$(date +%s)"
  LEASES_MINE="$LEASES_MINE $1"
  holder_write "$1" starting pending
  trap 'exit 143' TERM; trap 'exit 129' HUP
}
lease_hold() { holder_write "$1" held "$2"; }
lease_drop() { # <name>: no longer this process's to release
  local h out=''
  for h in $LEASES_MINE; do [ "$h" = "$1" ] || out="$out $h"; done
  LEASES_MINE="$out"
  [ -n "${LEASES_MINE// /}" ] || trap - TERM HUP
}
lease_keep() { lease_drop "$1"; } # the lease outlives this process (a background session holds it)
# lease_release_own <name>: remove the lease if this process holds it
lease_release_own() {
  local d="$LEASE_DIR/$1"
  holder_read "$d" || return 0
  [ "$LH_PID" = "$$" ] || return 0
  mv "$d" "$d.released.$$" 2>/dev/null && rm -rf "$d.released.$$"
}
lease_exit() { local h; for h in $LEASES_MINE; do lease_release_own "$h"; done; }
# lease_remove <name>: remove the lease whoever holds it (stop, release), under the takeover lock
lease_remove() {
  local d="$LEASE_DIR/$1"
  [ -d "$d" ] || return 0
  takeover_lock "$1"
  mv "$d" "$d.released.$$" 2>/dev/null && rm -rf "$d.released.$$"
  takeover_unlock "$1"
  lease_drop "$1"
}

# lease_takeover <i>: the lease was judged dead (LV_WHY, LH_*); take it over under the lock.
# 0 taken; 1 not (someone else was quicker, or the holder came back to life).
lease_takeover() {
  local i="$1" h="${NAME[$1]}" d="$LEASE_DIR/${NAME[$1]}" raw="$LH_RAW" why="$LV_WHY" prev="$LH_CARRIER" took=''
  takeover_lock "$h"
  if [ -d "$d" ]; then
    holder_read "$d"
    if [ "$LH_RAW" != "$raw" ]; then
      lease_verdict "$i" "$h" fresh
      if [ "$LV" != dead ]; then takeover_unlock "$h"; return 1; fi
      why="$LV_WHY" prev="$LH_CARRIER"
    fi
    if mv "$d" "$d.stale.$$" 2>/dev/null; then
      mkdir -m 0777 "$d" 2>/dev/null && took=1
      rm -rf "$d.stale.$$"
    fi
  else
    mkdir -m 0777 "$d" 2>/dev/null && took=1
  fi
  [ -z "$took" ] || lease_own "$h"
  takeover_unlock "$h"
  [ -n "$took" ] || return 1
  echo "$h: its lease was stale ($why${prev:+, held by $prev}); taken over."
}

# lease_take <i>: take entry i's lease. 0 taken (this process holds it, state starting); 10 held
# by a live holder (LV, LH_*); 11 a start of it still in progress after AGENTS_LEASE_WAIT seconds
# (default 20); 12 the adapter's listing failed (nothing is taken on a guess); 1 the lease folder
# cannot be written.
lease_take() {
  local i="$1" h="${NAME[$1]}" polls=0 tries=0 max
  max=$((${AGENTS_LEASE_WAIT:-20} * 2))
  if [ ! -d "$LEASE_DIR" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null
    mkdir -m 0777 "$LEASE_DIR" 2>/dev/null
  fi
  if [ ! -d "$LEASE_DIR" ] || [ ! -w "$LEASE_DIR" ]; then
    warn "$h: the lease folder $LEASE_DIR cannot be written; nothing started."
    return 1
  fi
  while :; do
    if mkdir -m 0777 "$LEASE_DIR/$h" 2>/dev/null; then lease_own "$h"; return 0; fi
    tries=$((tries + 1))
    if [ "$tries" -gt 200 ]; then warn "$h: could not take its lease under $LEASE_DIR; nothing started."; return 1; fi
    lease_verdict "$i" "$h" fresh
    case "$LV" in
      free) ;;
      dead) lease_takeover "$i" && return 0 ;;
      starting)
        [ "$polls" -lt "$max" ] || return 11
        polls=$((polls + 1)); sleep 0.5 ;;
      error) return 12 ;;
      *) return 10 ;;
    esac
  done
}

# holder_desc: the live holder in words (from LV and LH_*)
holder_desc() {
  local since=''
  [ -z "$LH_TIME" ] || since=" since $(fmt_time "$LH_TIME")"
  case "$LV" in
    starting) printf 'a start of it is in progress (pid %s%s)' "${LH_PID:-?}" "$since" ;;
    cannot-tell) printf 'its lease is held%s and its CLI cannot say whether it still runs' "$since" ;;
    error) printf 'its lease is held%s and its sessions could not be listed' "$since" ;;
    *) printf 'its lease is held by %s%s (pid %s, this container)' "${LH_CARRIER:-?}" "$since" "${LH_PID:-?}" ;;
  esac
}
# refuse_held <i>: a second copy of a stateful agent that cannot be joined: exit 2
refuse_held() {
  local h="${NAME[$1]}"
  die 2 "$h is a stateful agent and already runs: $(holder_desc). A second copy is refused. Use that session; if it is gone, task agents:release -- $h frees the lease (--force for a live holder). To run several at once, make it lifecycle: ephemeral."
}
# join_line <i> <lease_take's code>: say that the resident runs already (its lease is held)
join_line() {
  local i="$1" h="${NAME[$1]}"
  if [ "$LV" = cannot-tell ]; then
    echo "$h: ${CLI[i]} cannot list its sessions; started earlier in this container start ($(holder_desc)), so not started again."
  elif [ "$2" = 11 ] || [ "$LV" = starting ]; then
    echo "$h: $(holder_desc); not starting a second copy."
  elif adapter_of "$i" 2>/dev/null && state_of "$i" && [ "$STATE" = running ]; then
    echo "$h: running ($SID)"
    [ "$EXTRAS" -eq 0 ] || echo "$h: $EXTRAS more running session(s) for this agent; task agents:stop -- $h --extras stops them."
  else
    echo "$h: running ($(holder_desc))"
  fi
}
# definition_note <i>: 2.0 reads and checks definition but hands it to no CLI yet
definition_note() {
  [ -z "${DEF[$1]:-}" ] || warn "${NAME[$1]}: definition '${DEF[$1]}' is read and checked, but agents 2.0 does not pass it to the CLI yet; the session starts without it."
}

# lease_run <i>: make_run (the resident runs in the background) under its lease. Returns as
# make_run; on 3 (no background mode) the lease stays this process's (the caller opens the
# session in the foreground, or releases it). JOINED=1 when another holder has it: nothing is
# started, one line says it runs.
lease_run() {
  local i="$1" h="${NAME[$1]}" r
  JOINED=''
  [ "${LEASE[i]}" = container ] || { make_run "$i"; return; }
  lease_take "$i"; r=$?
  case "$r" in
    0) ;;
    10 | 11) join_line "$i" "$r"; JOINED=1; return 0 ;;
    12) list_failed "$i"; return 1 ;;
    *) return 1 ;;
  esac
  make_run "$i"; r=$?
  case "$r" in
    0) lease_hold "$h" "session:${SID:-unknown}"; lease_keep "$h" ;;
    3) ;;
    *) lease_release_own "$h"; lease_drop "$h" ;;
  esac
  return "$r"
}

# fg_hold <i>: this process holds the lease for a session in this terminal (released on exit;
# an interrupt goes to the session, the release follows when it ends)
fg_hold() {
  [ "${LEASE[$1]}" = container ] || return 0
  lease_hold "${NAME[$1]}" "process:$$"
  trap ':' INT
}

# make_run <i>: make the resident run in the background (no attach). Prints one line on
# what it did. Returns 0 running, 1 failed, 3 the CLI has no background mode.
make_run() {
  local i="$1" nm="${NAME[$1]}" rc
  state_of "$i" || { list_failed "$i"; return 1; }
  case "$STATE" in
    running)
      echo "$nm: running ($SID)"
      [ "$EXTRAS" -gt 0 ] && echo "$nm: $EXTRAS more running session(s) for this agent; task agents:stop -- $nm --extras stops them."
      return 0 ;;
    stopped | failed)
      echo "$nm: $STATE ($SID); waking it with its conversation"
      call wake "$i" </dev/null >/dev/null; rc=$?
      if [ "$rc" -eq 3 ]; then
        echo "$nm: ${CLI[i]} cannot wake a stopped session; starting a fresh one in the background instead."
      elif [ "$rc" -eq 0 ]; then
        mark_started "$nm"; return 0
      else
        warn "$nm: waking failed."; return 1
      fi ;;
    unknown)
      if marked "$nm"; then
        echo "$nm: ${CLI[i]} cannot list its sessions; started earlier in this container start, so not started again."
        return 0
      fi
      echo "$nm: ${CLI[i]} cannot list its sessions, so 'make sure it runs' cannot be promised; starting it once for this container start." ;;
  esac
  call start-bg "$i" </dev/null >/dev/null; rc=$?
  case "$rc" in
    0) mark_started "$nm"; reread "${CLI[i]}"; state_of "$i"; echo "$nm: started in the background${SID:+ ($SID)}"; return 0 ;;
    3) return 3 ;;
    *) warn "$nm: starting it in the background failed."; return 1 ;;
  esac
}

# --------------------------------------------------------------------- verbs ----
cmd_start() {
  local name='' mode=plain yes='' rc
  PASS=()
  if [ $# -eq 0 ] || [ "${1#-}" != "$1" ]; then # no name: the list's default agent
    name="$(default_agent)"
    if [ -z "$name" ]; then
      [ $# -gt 0 ] || die 2 "start needs an agent name: agents start <name> [--resume|--new] [-- extra CLI args] (or mark one agent default: true in the list)"
      die 2 "start needs an agent name first, then flags: agents start <name> [--resume|--new] (or mark one agent default: true in the list)"
    fi
  else
    name="$1"; shift
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --resume) [ "$mode" = plain ] || die 2 "--resume and --new exclude each other"; mode=resume ;;
      --new) [ "$mode" = plain ] || die 2 "--resume and --new exclude each other"; mode=new ;;
      --yes) yes=1 ;;
      --) shift; PASS+=("$@"); break ;;
      *) PASS+=("$1") ;;
    esac
    shift
  done
  load_list
  find_agent "$name"
  local i="$AI"
  adapter_of "$i" || exit 1
  definition_note "$i"
  if [ "${KIND[i]}" = resident ]; then
    if [ "$mode" = new ]; then
      state_of "$i" || { list_failed "$i"; exit 1; }
      if [ "$STATE" = running ]; then
        if [ -z "$yes" ]; then
          has_tty || die 2 "$name: --new stops the running session ($SID) and starts a fresh one; it asks first, so run it from a terminal or add --yes."
          printf 'Stop %s (%s) and start a fresh session? [y/N] ' "$name" "$SID"
          local ans=''
          read -r ans || ans=''
          case "$ans" in y | Y | yes | YES | Yes) ;; *) echo "$name: nothing changed."; exit 0 ;; esac
        fi
        call stop "$i" </dev/null; rc=$?
        [ "$rc" -eq 0 ] || die "$rc" "$name: stopping the running session failed; nothing started."
      fi
      if [ "${LEASE[i]}" = container ]; then # released and taken again in this one run
        lease_remove "$name"
        lease_take "$i"; rc=$?
        [ "$rc" -eq 0 ] || refuse_held "$i"
      fi
      call start-bg "$i" </dev/null >/dev/null; rc=$?
      if [ "$rc" -eq 3 ]; then
        echo "$name: ${CLI[i]} has no background mode; opening a new session in this terminal instead."
        has_tty || die 2 "$name: a new interactive session needs a terminal."
        fg_hold "$i"
        call new "$i"; exit $?
      fi
      [ "$rc" -eq 0 ] || die 1 "$name: starting a fresh session failed."
      mark_started "$name"; reread "${CLI[i]}"; state_of "$i"
      if [ "${LEASE[i]}" = container ]; then lease_hold "$name" "session:${SID:-unknown}"; lease_keep "$name"; fi
      echo "$name: started a fresh session${SID:+ ($SID)}"
    else
      lease_run "$i"; rc=$?
      if [ "$rc" -eq 3 ]; then
        echo "$name: ${CLI[i]} has no background mode; opening a new session in this terminal instead (it runs as on-demand)."
        has_tty || die 2 "$name: a new interactive session needs a terminal."
        fg_hold "$i"
        call new "$i"; exit $?
      fi
      [ "$rc" -eq 0 ] || exit 1
      # a resident run in another terminal (its CLI has no background mode) cannot be joined
      case "$JOINED:$LH_CARRIER" in 1:process:*) [ "$LV" != held ] || refuse_held "$i" ;; esac
    fi
    if ! has_tty; then
      echo "$name: running; attach from a terminal with: task agents -- $name (from the host: task devcontainer:agent -- $name)"
      exit 0
    fi
    call attach "$i"; rc=$?
    if [ "$rc" -eq 3 ]; then
      warn "$name: ${CLI[i]} cannot attach to a background session; its recent output instead:"
      call logs "$i" </dev/null || true
      exit 1
    fi
    exit "$rc"
  fi
  # on-demand
  if ! has_tty; then
    die 2 "$name is an on-demand agent: it opens a new interactive session, which needs a terminal (stdin and stdout); refusing without one."
  fi
  if [ "$mode" = resume ] && [ "${LIFE[i]}" = ephemeral ]; then
    die 2 "$name is an ephemeral agent: nothing of it is kept, so there is no conversation to resume (--resume is for stateful agents)."
  fi
  if [ "${LEASE[i]}" = container ]; then # a stateful on-demand agent: one copy, held by this process
    lease_take "$i"; rc=$?
    case "$rc" in
      0) fg_hold "$i" ;;
      10 | 11) refuse_held "$i" ;;
      12) list_failed "$i"; exit 1 ;;
      *) exit 1 ;;
    esac
  fi
  if [ "$mode" = resume ]; then
    call resume "$i"; rc=$?
    if [ "$rc" -eq 3 ]; then
      echo "$name: ${CLI[i]} cannot resume a conversation; opening a new one instead."
      call new "$i"; exit $?
    fi
    exit "$rc"
  fi
  call new "$i"; exit $?
}

cmd_up() {
  local wait=1 post='' a
  for a in "$@"; do
    case "$a" in
      --no-wait) wait='' ;;
      --post-start) post=1 ;;
      *) die 2 "up: unknown argument '$a' (--no-wait, --post-start)" ;;
    esac
  done
  if [ -n "$post" ]; then
    resolve_file
    if [ ! -f "$AF_ABS" ]; then
      echo "agents: no agent list at $AF_ABS (from $AF_SOURCE); nothing to start."
      exit 0
    fi
    # never fatal at container start: whatever happens is said, the start goes on
    ( cmd_up_body "$wait" ) || echo "agents: some agents did not start (above); the container start goes on."
    exit 0
  fi
  cmd_up_body "$wait"
}

cmd_up_body() {
  local wait="$1" i rc=0 r
  PASS=()
  load_list
  declare -A settled=()
  for ((i = 1; i <= N; i++)); do
    if [ "${KIND[i]}" != resident ]; then
      echo "${NAME[i]}: on-demand, not started"
      continue
    fi
    adapter_of "$i" || { rc=1; continue; }
    if [ -n "$wait" ] && [ -z "${settled[${CLI[i]}]:-}" ]; then
      settle "${CLI[i]}"; settled[${CLI[i]}]=1
    fi
    definition_note "$i"
    lease_run "$i"; r=$?
    case "$r" in
      0) ;;
      3) lease_release_own "${NAME[i]}"; lease_drop "${NAME[i]}"
         echo "${NAME[i]}: skipped, ${CLI[i]} has no background mode (it runs as on-demand: task agents -- ${NAME[i]})" ;;
      *) rc=1 ;;
    esac
  done
  return "$rc"
}

# settle <cli>: after a rebuild a CLI may restore background sessions on its own; starting
# agents in that window makes copies. Wait until two reads AGENTS_SETTLE_INTERVAL seconds
# apart (default 3) list the same running sessions, at most AGENTS_SETTLE_TIMEOUT (30).
settle() {
  local cli="$1" interval="${AGENTS_SETTLE_INTERVAL:-3}" timeout="${AGENTS_SETTLE_TIMEOUT:-30}" start="$SECONDS" prev cur
  sessions_of "$cli"
  [ "${LIST_RC[$cli]}" = 0 ] || return 0
  prev="$(printf '%s\n' "${LISTS[$cli]}" | awk -F'\t' '$3 == "running" { print $2 }' | sort)"
  echo "waiting for restored $cli sessions…"
  while :; do
    sleep "$interval"
    reread "$cli"
    [ "${LIST_RC[$cli]}" = 0 ] || return 0
    cur="$(printf '%s\n' "${LISTS[$cli]}" | awk -F'\t' '$3 == "running" { print $2 }' | sort)"
    [ "$cur" = "$prev" ] && return 0
    if [ $((SECONDS - start)) -ge "$timeout" ]; then
      echo "agents: the $cli session list was still changing after ${timeout}s; going on."
      return 0
    fi
    prev="$cur"
  done
}

json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

cmd_list() {
  local json='' i first=1 st a c
  declare -A failed=()
  for a in "$@"; do
    case "$a" in --json) json=1 ;; *) die 2 "list: unknown argument '$a' (--json)" ;; esac
  done
  load_list
  [ -n "$json" ] && printf '['
  [ -z "$json" ] && printf '%-16s %-10s %-10s %-8s %-9s %-24s %-38s %s\n' NAME KIND LIFECYCLE CLI STATE LEASE ID FOLDER
  for ((i = 1; i <= N; i++)); do
    STATE='' SID='' EXTRAS=0
    if adapter_of "$i" 2>/dev/null; then
      if ! state_of "$i"; then
        c="${LIST_ERR[${CLI[i]}]}"; failed[${CLI[i]}]="${c:-the listing failed}"
      fi
    elif [ -z "$(command -v "agent-adapter-${CLI[i]}" 2>/dev/null)" ]; then
      STATE=no-adapter
    else
      STATE=no-folder
    fi
    st="$STATE"; [ "$EXTRAS" -gt 0 ] && st="$STATE+$EXTRAS"
    local state="$STATE" sid="$SID" extras="$EXTRAS"
    lease_of "$i"
    if [ -n "$json" ]; then
      [ -z "$first" ] && printf ','
      first=''
      printf '{"name":%s,"kind":%s,"cli":%s,"folder":%s,"state":%s,"id":%s,"extras":%d' \
        "$(json_str "${NAME[i]}")" "$(json_str "${KIND[i]}")" "$(json_str "${CLI[i]}")" \
        "$(json_str "${FOLDER[i]}")" "$(json_str "$state")" "$(json_str "$sid")" "$extras"
      [ "$state" = error ] && printf ',"error":%s' "$(json_str "${failed[${CLI[i]}]}")"
      printf ',"lifecycle":%s,"identity":%s,"lease":%s,"carrier":%s}' "$(json_str "${LIFE[i]}")" \
        "$(json_str "${IDENT[i]}")" "$(json_str "$LO_LEASE")" "$(json_str "$LO_CARRIER")"
    else
      printf '%-16s %-10s %-10s %-8s %-9s %-24s %-38s %s\n' "${NAME[i]}" "${KIND[i]}" "${LIFE[i]}" "${CLI[i]}" "$st" \
        "$LO_TEXT" "${sid:--}" "${FOLDER[i]}"
    fi
  done
  [ -n "$json" ] && printf ']\n'
  for c in "${!failed[@]}"; do
    warn "the $c sessions could not be listed: ${failed[$c]}"
  done
  return 0
}

cmd_stop() {
  local name="${1:-}" rc a
  local -a extras=()
  PASS=()
  [ -n "$name" ] || die 2 "stop needs an agent name: agents stop <name> [--extras]"
  shift
  for a in "$@"; do
    case "$a" in --extras) extras=(--extras) ;; *) die 2 "stop: unknown argument '$a' (--extras)" ;; esac
  done
  load_list
  find_agent "$name"
  adapter_of "$AI" || exit 1
  call stop "$AI" ${extras[@]+"${extras[@]}"} </dev/null; rc=$?
  [ "$rc" -eq 3 ] && die 3 "$name: ${CLI[AI]} cannot stop its sessions from outside; stop it where it runs."
  # stopped: the lease ends with it (not with --extras, which keeps the agent running)
  if [ "$rc" -eq 0 ] && [ "${#extras[@]}" -eq 0 ] && [ "${LEASE[AI]}" = container ]; then lease_remove "$name"; fi
  exit "$rc"
}

# lease_of <i>: entry i's lease for list: LO_LEASE (none, free, held, starting, stale),
# LO_CARRIER (none when unknown) and LO_TEXT (the LEASE column)
lease_of() {
  local i="$1"
  LO_LEASE=none LO_CARRIER=none LO_TEXT=-
  [ "${LEASE[i]}" = container ] || return 0
  lease_verdict "$i" "${NAME[i]}"
  case "$LV" in
    free) LO_LEASE=free LO_TEXT=free ;;
    dead) LO_LEASE=stale LO_TEXT=stale ;;
    starting) LO_LEASE=starting LO_TEXT=starting ;;
    *) LO_LEASE=held LO_TEXT="held ${LH_CARRIER:-?}" ;;
  esac
  [ "$LO_LEASE" = free ] || [ -z "$LH_CARRIER" ] || LO_CARRIER="$LH_CARRIER"
}

# agents leases [--json]: every lease in the state folder, judged as a start would judge it
cmd_leases() {
  local json='' a d h i first=1 st holder n=0
  for a in "$@"; do
    case "$a" in --json) json=1 ;; *) die 2 "leases: unknown argument '$a' (--json)" ;; esac
  done
  resolve_file
  N=0
  [ ! -f "$AF_ABS" ] || load_list
  [ -n "$json" ] && printf '['
  [ -z "$json" ] && printf '%-16s %-10s %-24s %-9s %s\n' HANDLE STATE CARRIER SINCE HOLDER
  for d in "$LEASE_DIR"/*/; do
    [ -d "$d" ] || continue
    h="$(basename "$d")"
    case "$h" in *.*) continue ;; esac
    i=''
    for ((a = 1; a <= N; a++)); do [ "${NAME[a]}" = "$h" ] && i="$a"; done
    lease_verdict "$i" "$h"
    case "$LV" in dead) st=stale ;; cannot-tell) st=unknown ;; *) st="$LV" ;; esac
    if [ "$LV_WHY" = new-container ]; then holder="pid ${LH_PID:-?}, an earlier container start"
    elif pid_alive "$LH_PID" "$LH_PIDSTART"; then holder="pid ${LH_PID:-?} (running), this container"
    else holder="pid ${LH_PID:-?} (exited), this container"; fi
    [ -n "$i" ] || holder="$holder; not in the list"
    n=$((n + 1))
    if [ -n "$json" ]; then
      [ -z "$first" ] && printf ','
      first=''
      printf '{"handle":%s,"state":%s,"carrier":%s,"since":%s,"pid":%s,"listed":%s}' "$(json_str "$h")" "$(json_str "$st")" \
        "$(json_str "${LH_CARRIER:-none}")" "${LH_TIME:-0}" "${LH_PID:-0}" "$([ -n "$i" ] && echo true || echo false)"
    else
      printf '%-16s %-10s %-24s %-9s %s\n' "$h" "$st" "${LH_CARRIER:--}" "$([ -n "$LH_TIME" ] && fmt_time "$LH_TIME" || echo -)" "$holder"
    fi
  done
  [ -n "$json" ] && printf ']\n'
  [ -n "$json" ] || [ "$n" -gt 0 ] || echo "agents: no lease is held."
  return 0
}

# agents release <name> [--force]: free a lease whose holder is dead; --force also a live one
cmd_release() {
  local name='' force='' a i=''
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      -*) die 2 "release: unknown argument '$a' (--force)" ;;
      *) [ -z "$name" ] || die 2 "release takes one name: agents release <name> [--force]"; name="$a" ;;
    esac
  done
  [ -n "$name" ] || die 2 "release needs an agent name: agents release <name> [--force]"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die 2 "release: '$name' is not an agent name"
  resolve_file
  N=0
  [ ! -f "$AF_ABS" ] || load_list
  for ((a = 1; a <= N; a++)); do [ "${NAME[a]}" = "$name" ] && i="$a"; done
  if [ ! -d "$LEASE_DIR/$name" ]; then echo "$name: holds no lease; nothing to release."; exit 0; fi
  lease_verdict "$i" "$name" fresh
  case "$LV" in
    free) echo "$name: holds no lease; nothing to release." ;;
    dead) lease_remove "$name"; echo "$name: lease released (its holder was gone: $LV_WHY)." ;;
    *)
      [ -n "$force" ] || die 2 "$name: $(holder_desc); releasing it would let a second copy start. Add --force if you know it does not run."
      lease_remove "$name"; echo "$name: lease released (forced; $(holder_desc))." ;;
  esac
}

cmd_logs() {
  local name="${1:-}" rc
  PASS=()
  [ -n "$name" ] || die 2 "logs needs an agent name: agents logs <name>"
  load_list
  find_agent "$name"
  adapter_of "$AI" || exit 1
  call logs "$AI" </dev/null; rc=$?
  [ "$rc" -eq 3 ] && die 3 "$name: ${CLI[AI]} keeps no output to show (logs not supported)."
  exit "$rc"
}

cmd_check() {
  local i
  load_list
  local d=""; for ((i = 1; i <= N; i++)); do [ -z "${DFLT[i]:-}" ] || d="${NAME[i]}"; done
  echo "agents: $AF_ABS (from $AF_SOURCE): $N agent(s)${d:+, default $d (agents with no name starts it)}"
  for ((i = 1; i <= N; i++)); do
    check_line "$i"
  done
}

# check_line <i>: one agent as agents check prints it
check_line() {
  local i="$1"
  args_of "$i"
  printf '  %s: cli %s, %s%s, %s (identity %s, lease %s), folder %s, args:' "${NAME[i]}" "${CLI[i]}" \
    "${DEF[i]:+definition ${DEF[i]}, }" "${KIND[i]}" "${LIFE[i]}" "${IDENT[i]}" "${LEASE[i]}" "${FOLDER[i]}"
  if [ "${#CLIARGS[@]}" -eq 0 ]; then printf ' none'; else printf ' [%s]' "${CLIARGS[@]}"; fi
  printf '\n'
}

# ------------------------------------------------------------------- reset ----
# reset: tidy the listed agents' sessions, from a container terminal (never from inside a
# session it would stop). Scope is always the agents in the list and their folders, never every
# session the CLI knows. Per agent: its running session the lookup picks is kept, every other
# running one is stopped (conversations kept), its record is set again (adapter `record`), and
# a resident left with no running session is started (woken with its conversation, or fresh
# after --purge). --purge also removes (adapter `session-remove`) the agent's ended sessions.
# Sessions in those folders that belong to no listed agent are reported and left alone, unless
# --include-unlisted. A dry run unless --yes (or a yes on a terminal). Refused unless --force: a
# stop of a session mid-turn (adapter `session-busy`; one it cannot tell about counts as not
# busy, with a note) and a removal where the folder has uncommitted changes (tracked files); a
# stop there only warns.

# owner_of <cli> <name> <folder>: the index of the listed agent the session belongs to, or none.
owner_of() {
  local j
  for ((j = 1; j <= N; j++)); do
    [ "${CLI[j]}" = "$1" ] && [ -n "${ADIR[j]:-}" ] && [ "${ADIR[j]}" = "$3" ] || continue
    case "$2" in "${NAME[j]}") echo "$j"; return 0 ;; "${NAME[j]} ("*")") [[ "$2" =~ \([0-9]+\)$ ]] && { echo "$j"; return 0; } ;; esac
  done
}

plan_add() { PL_CLI+=("$1"); PL_ID+=("$2"); PL_AGENT+=("$3"); PL_STATE+=("$4"); PL_FOLDER+=("$5"); PL_ACT+=("$6"); PL_WHY+=("$7"); }

cmd_reset() {
  local purge='' all='' unlisted='' yes='' force='' a i k rc=0 refused=0 changes=0 nm id st fo owner kept cli d ans
  local -a names=() sel=() starts=()
  PASS=()
  for a in "$@"; do
    case "$a" in
      --purge) purge=1 ;; --all) all=1 ;; --include-unlisted) unlisted=1 ;; --yes) yes=1 ;; --force) force=1 ;;
      -*) die 2 "reset: unknown argument '$a' (--all, --purge, --include-unlisted, --yes, --force)" ;;
      *) names+=("$a") ;;
    esac
  done
  if [ -n "$all" ] && [ "${#names[@]}" -gt 0 ]; then die 2 "reset: name agents or give --all, not both."; fi
  if [ -z "$all" ] && [ "${#names[@]}" -eq 0 ]; then
    die 2 "reset needs agent names or --all: agents reset <name>... | --all [--purge] [--include-unlisted] [--yes] [--force]"
  fi
  load_list
  local -a ADIR=() AADP=()
  declare -A CLIADP=() FOLDERS=()
  for ((i = 1; i <= N; i++)); do
    if adapter_of "$i" 2>/dev/null; then ADIR[i]="$DIR" AADP[i]="$ADAPTER" CLIADP[${CLI[i]}]="$ADAPTER"; fi
  done
  if [ -n "$all" ]; then
    for ((i = 1; i <= N; i++)); do sel+=("$i"); done
  else
    for a in "${names[@]}"; do find_agent "$a"; sel+=("$AI"); done
  fi
  PL_CLI=() PL_ID=() PL_AGENT=() PL_STATE=() PL_FOLDER=() PL_ACT=() PL_WHY=()
  for i in "${sel[@]}"; do
    if [ -z "${ADIR[i]:-}" ]; then adapter_of "$i" || true; rc=1; continue; fi
    cli="${CLI[i]}" ADAPTER="${AADP[i]}" DIR="${ADIR[i]}"
    sessions_of "$cli"
    case "${LIST_RC[$cli]}" in
      0) ;;
      3) warn "${NAME[i]}: $cli cannot list its sessions; nothing to reset."; rc=1; continue ;;
      *) warn "${NAME[i]}: the $cli sessions could not be listed${LIST_ERR[$cli]:+ (${LIST_ERR[$cli]})}; nothing reset."; rc=1; continue ;;
    esac
    FOLDERS["$cli"$'\t'"$DIR"]=1
    kept=''
    while IFS=$'\t' read -r nm id st fo; do
      [ -n "${nm:-}" ] || continue
      owner="$(owner_of "$cli" "$nm" "$fo")"
      [ "$owner" = "$i" ] || continue
      if [ "$st" = running ]; then
        if [ -z "$kept" ]; then kept="$id"; plan_add "$cli" "$id" "${NAME[i]}" "$st" "$fo" keep "the agent's session (the one it attaches to)"
        else plan_add "$cli" "$id" "${NAME[i]}" "$st" "$fo" stop 'a second running session (its conversation is kept)'; fi
      elif [ -n "$purge" ]; then plan_add "$cli" "$id" "${NAME[i]}" "$st" "$fo" remove 'ended (--purge)'
      else plan_add "$cli" "$id" "${NAME[i]}" "$st" "$fo" keep 'ended; its conversation is kept'
      fi
    done <<< "${LISTS[$cli]}"
    if [ "${KIND[i]}" = resident ] && [ -z "$kept" ]; then starts+=("$i"); fi
  done
  # sessions in those folders that belong to no listed agent
  for k in "${!FOLDERS[@]}"; do
    cli="${k%%$'\t'*}" d="${k#*$'\t'}"
    while IFS=$'\t' read -r nm id st fo; do
      [ -n "${nm:-}" ] && [ "$fo" = "$d" ] || continue
      [ -z "$(owner_of "$cli" "$nm" "$fo")" ] || continue
      if [ -z "$unlisted" ]; then plan_add "$cli" "$id" "($nm)" "$st" "$fo" untouched 'belongs to no listed agent (--include-unlisted to include it)'
      elif [ "$st" = running ]; then plan_add "$cli" "$id" "($nm)" "$st" "$fo" stop 'belongs to no listed agent (--include-unlisted)'
      elif [ -n "$purge" ]; then plan_add "$cli" "$id" "($nm)" "$st" "$fo" remove 'belongs to no listed agent, ended (--include-unlisted --purge)'
      else plan_add "$cli" "$id" "($nm)" "$st" "$fo" keep 'belongs to no listed agent, ended'
      fi
    done <<< "${LISTS[$cli]}"
  done
  # a session mid-turn is not stopped; uncommitted changes warn, and refuse a removal
  for ((k = 0; k < ${#PL_ID[@]}; k++)); do
    case "${PL_ACT[k]}" in stop | remove) ;; *) continue ;; esac
    if [ "${PL_ACT[k]}" = stop ]; then
      "${CLIADP[${PL_CLI[k]}]}" session-busy "${PL_ID[k]}" </dev/null >/dev/null 2>&1; a=$?
      case "$a" in
        0)
          if [ -n "$force" ]; then PL_WHY[k]="${PL_WHY[k]}; mid-turn right now (--force)"
          else PL_WHY[k]="would stop it, but it is mid-turn right now (busy); wait until it is idle, or --force" PL_ACT[k]=refused; refused=1; continue
          fi ;;
        1) ;;
        *) PL_WHY[k]="${PL_WHY[k]}; whether it is mid-turn is unknown (${PL_CLI[k]} does not say)" ;;
      esac
    fi
    if [ -n "$(git -C "${PL_FOLDER[k]}" status --porcelain --untracked-files=no 2>/dev/null | head -n 1)" ]; then
      if [ "${PL_ACT[k]}" = remove ] && [ -z "$force" ]; then
        PL_WHY[k]="would remove it (its conversation), but ${PL_FOLDER[k]} has uncommitted changes (git status); commit or stash them, or --force" PL_ACT[k]=refused; refused=1
      else
        PL_WHY[k]="${PL_WHY[k]}; warning: uncommitted changes in ${PL_FOLDER[k]}${force:+ (--force)}"
      fi
    fi
  done
  for ((k = 0; k < ${#PL_ID[@]}; k++)); do case "${PL_ACT[k]}" in stop | remove) changes=$((changes + 1)) ;; esac; done
  local w=16
  for ((k = 0; k < ${#PL_ID[@]}; k++)); do [ "${#PL_AGENT[k]}" -le "$w" ] || w="${#PL_AGENT[k]}"; done
  for i in "${starts[@]+"${starts[@]}"}"; do [ "${#NAME[i]}" -le "$w" ] || w="${#NAME[i]}"; done
  printf "%-${w}s %-38s %-8s %-9s %s\n" AGENT SESSION STATE ACTION WHY
  for ((k = 0; k < ${#PL_ID[@]}; k++)); do
    printf "%-${w}s %-38s %-8s %-9s %s\n" "${PL_AGENT[k]}" "${PL_ID[k]}" "${PL_STATE[k]}" "${PL_ACT[k]}" "${PL_WHY[k]}"
  done
  for i in "${starts[@]+"${starts[@]}"}"; do
    printf "%-${w}s %-38s %-8s %-9s %s\n" "${NAME[i]}" - - start "a resident with no running session: woken with its latest conversation, else a fresh one"
  done
  if [ "$changes" -eq 0 ] && [ "${#starts[@]}" -eq 0 ]; then
    if [ "$refused" -gt 0 ]; then
      echo "agents: reset: $refused refused (see above); nothing else to stop, remove or start."
      [ "$rc" -ne 0 ] || rc=2
    else
      echo "agents: reset: nothing to stop, remove or start."
    fi
    exit "$rc"
  fi
  if [ "$changes" -gt 0 ] && [ "${CLAUDE_CODE_CHILD_SESSION:-}" = 1 ] && [ -z "$force" ]; then
    die 2 "reset stops or removes sessions, and this runs inside a Claude Code session (CLAUDE_CODE_CHILD_SESSION=1), maybe one of them; run it from a container terminal or task devcontainer:shell (--force goes ahead)."
  fi
  if [ -z "$yes" ]; then
    if ! has_tty; then echo "agents: reset: a dry run, nothing changed; add --yes to do the above."; exit "$rc"; fi
    printf 'Do the above? [y/N] '
    ans=''; read -r ans || ans=''
    case "$ans" in y | Y | yes | YES | Yes) ;; *) echo "agents: reset: nothing changed."; exit 0 ;; esac
  fi
  for ((k = 0; k < ${#PL_ID[@]}; k++)); do
    case "${PL_ACT[k]}" in
      stop)
        "${CLIADP[${PL_CLI[k]}]}" session-stop "${PL_ID[k]}" </dev/null; a=$?
        case "$a" in 0) ;; 3) warn "${PL_CLI[k]} cannot stop a session by id; ${PL_ID[k]} left running."; rc=1 ;; *) rc=1 ;; esac ;;
      remove)
        "${CLIADP[${PL_CLI[k]}]}" session-remove "${PL_ID[k]}" </dev/null; a=$?
        case "$a" in 0) ;; 3) warn "${PL_CLI[k]} cannot remove sessions; ${PL_ID[k]} kept (--purge skipped)." ;; *) rc=1 ;; esac ;;
    esac
  done
  for i in "${sel[@]}"; do
    [ -n "${ADIR[i]:-}" ] && [ "${LIST_RC[${CLI[i]}]:-1}" = 0 ] || continue
    ADAPTER="${AADP[i]}" DIR="${ADIR[i]}"
    call record "$i" </dev/null; a=$?
    [ "$a" -eq 0 ] || [ "$a" -eq 3 ] || rc=1
  done
  for i in "${starts[@]+"${starts[@]}"}"; do
    ADAPTER="${AADP[i]}" DIR="${ADIR[i]}"
    reread "${CLI[i]}"
    lease_run "$i"; a=$?
    case "$a" in 0) ;; 3) lease_release_own "${NAME[i]}"; lease_drop "${NAME[i]}"; echo "${NAME[i]}: skipped, ${CLI[i]} has no background mode" ;; *) rc=1 ;; esac
  done
  [ "$refused" -eq 0 ] || [ "$rc" -ne 0 ] || rc=2
  exit "$rc"
}

verb="${1:-}"
[ $# -gt 0 ] && shift
trap lease_exit EXIT
case "$verb" in
  leases) cmd_leases "$@" ;;
  release) cmd_release "$@" ;;
  start) cmd_start "$@" ;;
  up) cmd_up "$@" ;;
  list) cmd_list "$@" ;;
  stop) cmd_stop "$@" ;;
  logs) cmd_logs "$@" ;;
  check) cmd_check ;;
  reset) cmd_reset "$@" ;;
  -h | --help | help) usage ;;
  '') if [ -n "$(default_agent 2>/dev/null)" ]; then cmd_start; fi
      usage >&2; exit 2 ;;
  *) die 2 "unknown verb '$verb' (start, up, list, stop, logs, check, reset, leases, release)" ;;
esac
