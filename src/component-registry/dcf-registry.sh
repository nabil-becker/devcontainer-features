#!/usr/bin/env bash
# dcf-registry: the component registry's command. Layers of agentic components, read from any
# number of sources, merged by value type into one resolved view for who you are.
# Installed on PATH by the component-registry Feature; behind `task component-registry:resolve`
# and `task component-registry:explain`.
#
#   dcf-registry resolve [--as <path>]          fetch each layer, merge, swap in the resolved view
#   dcf-registry explain <path> [--uses] [--as <path>] [--color auto|always|never]
#                                               read-only: who said each line, at which version;
#                                               --uses lists what refers to <path>
#   dcf-registry version                        the Feature version and the layer list in use
#   dcf-registry layer-list                     print the layer list's path; exit 0 when it is
#                                               there, 1 when not (the agents start hook asks)
#   dcf-registry handover <cli> [<name> <folder>] [--as <path>] [--skills-mode split|shared|off]
#                                               hand the view resolved for that path (default: the
#                                               who-you-are setting's) to that CLI's adapter
#                                               (agent-adapter-<cli> skills, when its supports lists
#                                               it; exit 3 when it cannot take them) and record it;
#                                               the mode (default COMPONENT_REGISTRY_SKILLS_MODE,
#                                               else split) says how the CLI keeps them
#   dcf-registry forget <cli> <name> <folder>   (1.8.0) the adapter drops that agent's own copies
#                                               and the record goes
#   dcf-registry handovers [--skills]           (1.8.0) the records: cli, name, folder, path, path
#                                               mode, skills mode; --skills: each agent's own
#                                               skills too (the adapter's skills-show)
#   dcf-registry refresh [--as <path>] [--session <id>]
#                                               resolve, then hand over (/registry-refresh): --as
#                                               one path to every CLI adapter on PATH; --session the
#                                               agent whose session that is (an adapter's list);
#                                               else every recorded hand-over, each path resolved once
#   dcf-registry render <vendor> <folder> [--as <path>]
#                                               (1.11.0, ADR-0077) render that vendor's winning
#                                               templates from the view into a new folder: what a
#                                               hand-over to its CLI gets; explain templates/<vendor>
#                                               says whose template won
#
# Who you are is a path (/Corp/MyDepartment/team/me): --as, else COMPONENT_REGISTRY_WHOAMI from
# the task variable, the root .env, .devcontainer/.env or the environment (NFR-6); never in a
# committed file. The layer list is .devcontainer/registry.yml (the Feature option registryFile)
# unless COMPONENT_REGISTRY_FILE names another path relative to the repository root (the nearest
# folder at or above here holding .devcontainer), found in the same order.
#
#   layers:                       # lowest first
#     - id: corp-base             # unique; letters, digits, - and _
#       at: /Corp                 # where its relative section paths are mounted
#       required: true            # optional: never fetched stops resolve (on a source too)
#       writable: true            # ignored since 2.0.0 (the registry does not write layers)
#       heading: false            # optional (1.3.0): stack its text without a "## Layer <id>" line
#       namespace: acme           # optional (1.7.0): its components are acme:<name>, and it merges
#                                 # only with layers of the same namespace (see below)
#       aliases: { acme: acme-public }   # optional (1.7.0): in this layer's references, acme: is
#                                 # acme-public: (one hop; never the layer's own namespace)
#       sources:                  # merged in this order
#         - kind: git             # registry-source-git on PATH
#           url: https://git.example.invalid/corp/registry.git
#           tag: v3               # exactly one of branch, tag, commit
#           auth: { type: basic, user: bot, secret: registry/corp }   # optional, dcf-secret
#         - { kind: git, url: https://git.example.invalid/corp/monorepo.git, branch: main, path: registry/corp }   # 2.2.0: a folder of the repository is the layer root
#         - { kind: http, url: "https://github.com/acme/registry/releases/download/v3/registry.tar.gz", archive: tar.gz, sha256: "<64 hex>", path: registry, max-size: 200M }   # 2.2.0: an archive (max-size optional, default 100M)
#         - { kind: http, url: "https://registry.example.invalid/corp.layer", auth: { type: bearer, secret: registry/corp } }
#         - { kind: cloud-folder, remote: registry/mine }   # a folder under the cloud folder
#         - { kind: path, path: .registry-mine }   # repo-relative or absolute folder
#         - { kind: db, driver: postgres, host: db.example.invalid, database: registry, user: reader, table: registry_rows, auth: { secret: registry/db } }   # 1.5.0
#         - { kind: db, driver: sqlite, path: registry.db, query: "SELECT section, key, type, data, locked FROM rows" }
#
# Only that subset of YAML is read (comments, plain and quoted scalars, block entries, one-line
# { } maps); unknown keys are refused with file:line. The parser is awk (NFR-7).
#
# A layer's content is one or more *.layer files (*.reg is not read since 2.0.0) at the root of its copy (the grammar is in the
# Feature NOTES and docs/proposals/component-registry.md section 3.2); the merge is section 3.3.
#
# State (owner-only, never committed) in COMPONENT_REGISTRY_STATE_DIR
# (/var/lib/devcontainer-features/component-registry):
#   copies/<layer>/<n>/        the layer copy of the layer's n-th source; <n>.meta its pin,
#                              version and fetch time
#   views/<stamp>/ and view    the resolved views; `view` is a symlink swapped in one rename,
#                              to the latest resolve
#   paths/<key>                (1.8.0) one symlink per who-you-are path (/ becomes +), to that
#                              path's latest view, swapped the same way: agents with different
#                              paths each keep their own view
#   handovers.tsv              (1.8.0) cli, name, folder, path, path mode (as: the agent's own path;
#                              whoami: the who-you-are setting), skills mode (split, shared) of
#                              every hand-over, for refresh
#   resolve.lock               flock, so two resolves never interleave (one lock for every path:
#                              the layer copies are shared); handovers.lock guards the records
# The resolved view: skills/<name>/ (SKILL.md and its files, what a consumer copies),
# agents/<name>/ (1.6.0, an agent definition: model, skills and from.tsv, what the participant
# reads at the agent's start), meta/<kind>/<name>/ (provenance.tsv, keys.tsv, values/<key>),
# meta/refs.tsv, meta/problems.tsv, meta/namespaced.tsv (1.7.0), layers.tsv, whoami and agent-names.
#
# Layer namespaces (1.7.0, ADR-0073 decision 4): a layer with namespace: acme brings acme:<name> for
# every component it names (its [skills/arch-review] is skills/acme:arch-review), so a layer pointed
# at a public or community source cannot change anything outside its namespace. Its sections match,
# lock, @replace and set types only among the layers of the same namespace, which merge with each
# other exactly as layers do (order, specificity, locks, permission keys from the namespace's lowest
# layer); the layers without a namespace are the Operator's own and never merge into a namespaced
# component, nor it into theirs. References are explicit (the Operator's ruling of 2026-11-21): a ref,
# a list ref: item or an agent's skills item without a prefix names the referrer's own namespace,
# <ns>:<name> namespace <ns> from any layer (after the layer's alias); nothing names the
# un-namespaced set from inside a namespace. A target not in the view is a missing dependency:
# resolve says it and goes on; installing the namespace is the user's. Each layer's aliases
# ({ acme: acme-public }) map a namespace name in its own references, one hop. In the view a
# namespaced skill is skills/<ns>--<name>/ (a ':' is no skill folder name; its SKILL.md is named
# the same, whatever its text says), its metadata under its registry name,
# meta/skills/<ns>:<name>/; a namespaced agent definition is agents/<ns>:<name>/ and matches no
# agent of the agents list. explain takes either name.
#
# Agent definitions (1.6.0): an agents/<name> component holds two fields, model:value and
# skills:list, and model.<cli>:value, a model for agents of that CLI only; a line for any other key
# is skipped and reported (the agents list owns the rest, and an agent definition carries no
# permission). resolve also resolves agents/<name> for every name in COMPONENT_REGISTRY_AGENTS
# (comma-separated name:cli items; the participant sets it to the listed agents and their CLIs), so
# a pattern such as [agents/*] reaches them and the effective model is picked for each agent's CLI;
# without it the current view's names are kept.
#
# The built-in base layer (1.1.0): the Feature's own utility skills (registry-refresh,
# registry-explain), read from $SHARE_DIR/base, are layer rank 0 with the id
# component-registry at /, below every listed layer and always present when a list is resolved;
# explain shows it as "0 component-registry at /, source 1 (builtin)". The id is reserved.
#
# Exit: 0 done, 1 failed (a required layer never fetched, the lock, no resolved view), 2 bad use
# (no who-you-are path, a bad layer list, an unknown verb).
set -uo pipefail

STATE_DIR="${COMPONENT_REGISTRY_STATE_DIR:-/var/lib/devcontainer-features/component-registry}"
SHARE_DIR="${COMPONENT_REGISTRY_SHARE_DIR:-/usr/local/share/component-registry-feature}"
# Component kinds: a path is split at the first of these segments. Only ACTIVE_KINDS are
# resolved in this release; lines of the others are reported, not merged.
KINDS="skills agents prompts settings lexicon"
ACTIVE_KINDS="skills agents"
declare -A S_KIND S_REQ S_LINE S_ARGS S_PIN
# The built-in base layer: the Feature's utility skills, rank 0, below every listed layer.
BASE_ID=component-registry
BASE_DIR="${COMPONENT_REGISTRY_BASE_DIR:-$SHARE_DIR/base}"

warn() { printf 'dcf-registry: %s\n' "$*" >&2; }
say() { printf 'dcf-registry: %s\n' "$*"; }
die() { local rc="$1"; shift; printf 'dcf-registry: %s\n' "$*" >&2; exit "$rc"; }
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

# Everything this command writes is as sensitive as its most sensitive layer (a person's own
# layer may hold health facts): owner-only.
umask 077

# ------------------------------------------------------------------ settings ----
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

# dotenv_value <file> <var>: the value of the last line for var (quotes, export and a trailing
# comment dropped); 1 when the file has no line for it.
dotenv_value() {
  grep -q "^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=" "$1" 2>/dev/null || return 1
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=[[:space:]]*//p" "$1" | tail -n 1 | tr -d '\r' |
    sed "s/[[:space:]]\{1,\}#.*\$//; s/[[:space:]]*\$//; s/^\"\(.*\)\"\$/\1/; s/^'\(.*\)'\$/\1/"
}

# setting <VAR>: prints value<TAB>source. The task variable (VAR_TASK_VAR) when it differs from
# both .env and the environment (Task fills it from those too), then .env, .devcontainer/.env,
# then the environment; nothing when unset.
setting() {
  local var="$1" tvn="${1}_TASK_VAR" tv ev dv='' dsrc='' f v
  tv="${!tvn:-}" ev="${!var:-}"
  for f in "$ROOT/.env" "$ROOT/.devcontainer/.env"; do
    if [ -f "$f" ] && v="$(dotenv_value "$f" "$var")"; then dv="$v" dsrc="${f#"$ROOT"/}"; break; fi
  done
  if [ -n "$tv" ] && [ "$tv" != "$dv" ] && [ "$tv" != "$ev" ]; then printf '%s\tthe task variable %s' "$tv" "$var"
  elif [ -n "$dv" ]; then printf '%s\t%s in %s' "$dv" "$var" "$dsrc"
  elif [ -n "$ev" ]; then printf '%s\t%s in the environment' "$ev" "$var"
  fi
}

resolve_settings() {
  local s def=.devcontainer/registry.yml
  ROOT="$(find_root)"
  # shellcheck disable=SC1091  # written by install.sh at image build
  [ -f "$SHARE_DIR/options.env" ] && . "$SHARE_DIR/options.env"
  s="$(setting COMPONENT_REGISTRY_FILE)"
  if [ -n "$s" ]; then RF="${s%%$'\t'*}" RF_SOURCE="${s#*$'\t'}"
  elif [ -n "${REGISTRYFILE:-}" ]; then RF="$REGISTRYFILE" RF_SOURCE='the Feature option registryFile'
  else RF="$def" RF_SOURCE='the default (COMPONENT_REGISTRY_FILE is not set)'
  fi
  case "$RF" in /*) RF_ABS="$RF" ;; *) RF_ABS="$ROOT/$RF" ;; esac
}

# valid_path <path>: absolute, segments of letters, digits, . _ -, no wildcards
valid_path() { [[ "$1" =~ ^(/[A-Za-z0-9._-]+)+$ ]] || [ "$1" = / ]; }

resolve_whoami() { # $1: the --as value, may be empty
  local s
  if [ -n "$1" ]; then WHOAMI="$1" WHOAMI_SOURCE='--as'
  else
    s="$(setting COMPONENT_REGISTRY_WHOAMI)"
    [ -n "$s" ] || die 2 "who are you? Set COMPONENT_REGISTRY_WHOAMI to your path in the registry, for example COMPONENT_REGISTRY_WHOAMI=/Corp/MyDepartment/team/me in $ROOT/.env (git-ignored) or from the launcher, or pass --as <path>. It is per person and never goes in a committed file."
    WHOAMI="${s%%$'\t'*}" WHOAMI_SOURCE="${s#*$'\t'}"
  fi
  WHOAMI="${WHOAMI%/}"; [ -n "$WHOAMI" ] || WHOAMI=/
  valid_path "$WHOAMI" || die 2 "who-you-are path '$WHOAMI' (from $WHOAMI_SOURCE) must be absolute, like /Corp/MyDepartment/team/me: segments of letters, digits, . _ and -, no wildcards."
}

# ------------------------------------------------------------- the layer list ----
# The parser: the YAML subset above, one record per line out (tab-separated):
#   Y <n> <line>                      layer n starts
#   K <n> <key> <value> <line>        id, at, required, writable, heading, namespace
#   S <n> <m> <line>                  source m of layer n starts
#   P <n> <m> <key> <value> <line>    kind, url, branch, tag, commit, path, remote, required,
#                                     driver, host, port, database, user, sslmode, table, query, allow-insecure, auth.type, auth.secret, auth.user, auth.header
#   A <n> <alias> <namespace> <line> an alias of layer n (1.7.0)
#   E <line> <message>                an error (the last line)
# Written for mawk as well as gawk: no gensub, no regex intervals.
read -r -d '' LIST_PARSER <<'AWK'
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
function setkey(where, k, v,   id) {
  if (v ~ /\t/) fail("a tab in the value of '" k "'")
  if (where == "layer") {
    if (k !~ /^(id|at|required|writable|heading|namespace)$/) fail("unknown key '" k "' in a layer (id, at, sources, required, writable, heading, namespace, aliases)")
    if ((n, k) in seen) fail("'" k "' appears twice in one layer")
    seen[n, k] = 1
    printf "K\t%d\t%s\t%s\t%d\n", n, k, v, NR
    return
  }
  if (where == "aliases") {
    if ((n, "alias", k) in seen) fail("alias '" k "' appears twice in one layer")
    seen[n, "alias", k] = 1
    printf "A\t%d\t%s\t%s\t%d\n", n, k, v, NR
    return
  }
  if (where == "source") {
    if (k !~ /^(kind|url|branch|tag|commit|path|remote|required|allow-insecure|archive|sha256|max-size|driver|host|port|database|user|sslmode|table|query)$/) fail("unknown key '" k "' in a source (kind, url, branch, tag, commit, path, remote, required, allow-insecure, archive, sha256, max-size, driver, host, port, database, user, sslmode, table, query, auth)")
    id = k
  } else {
    if (k !~ /^(type|secret|user|header)$/) fail("unknown key '" k "' in auth (type, secret, user, header)")
    id = "auth." k
  }
  if ((n, m, id) in seen) fail("'" id "' appears twice in one source")
  seen[n, m, id] = 1
  printf "P\t%d\t%d\t%s\t%s\t%d\n", n, m, id, v, NR
}
# flowmap(s, where): a { k: v, k: "v", auth: { ... } } map on one line; FR is the text after it
function flowmap(s, where,   k, v, ch) {
  s = substr(s, 2)
  while (1) {
    sub(/^[ \t]+/, "", s)
    if (s == "") fail("a { map must close on the same line")
    if (substr(s, 1, 1) == "}") { s = substr(s, 2); break }
    if (!match(s, /^[A-Za-z0-9_-]+:/)) fail("expected key: value in the { map")
    k = substr(s, 1, RLENGTH - 1); s = substr(s, RLENGTH + 1)
    sub(/^[ \t]+/, "", s)
    ch = substr(s, 1, 1)
    if (ch == "{") {
      if (where != "source" || k != "auth") fail("only auth may hold a { map")
      if ((n, m, "auth") in seen) fail("'auth' appears twice in one source")
      seen[n, m, "auth"] = 1
      flowmap(s, "auth"); s = FR
    } else if (ch == "\"" || ch == "'") { quoted(s); setkey(where, k, QV); s = QR }
    else {
      if (k == "auth" && where == "source") fail("auth must be a map: auth: { type: basic, secret: <name> }")
      v = s; sub(/[,}].*$/, "", v); s = substr(s, length(v) + 1); sub(/[ \t]+$/, "", v)
      if (v == "") fail("'" k "' has no value")
      if (s == "") fail("a { map must close on the same line")
      setkey(where, k, v)
    }
    sub(/^[ \t]+/, "", s)
    ch = substr(s, 1, 1)
    if (ch == ",") { s = substr(s, 2); continue }
    if (ch == "}") { s = substr(s, 2); break }
    fail("expected , or } in the { map")
  }
  FR = s
}
function after(s) { sub(/^[ \t]+/, "", s); if (s != "" && substr(s, 1, 1) != "#") fail("text after the { map") }
# keyline(t, where): one key: value line of a layer, a source or an auth map
function keyline(t, where,   k, v) {
  if (t !~ /^[A-Za-z0-9_-]+:/) fail("expected key: value")
  k = t; sub(/:.*/, "", k)
  v = substr(t, length(k) + 2)
  if (v != "" && v !~ /^[ \t]/) fail("expected a space after " k ":")
  sub(/^[ \t]+/, "", v)
  if (where == "layer" && k == "sources") {
    if ((n, "sources") in seen) fail("'sources' appears twice in one layer")
    seen[n, "sources"] = 1
    if (v == "" || substr(v, 1, 1) == "#") { ctx = "srcwait"; return }
    if (plain(v) ~ /^\[[ ]*\]$/) return
    fail("sources must be a list: one '- kind: ...' entry per line below it")
  }
  if (where == "layer" && k == "aliases") {
    if ((n, "aliases") in seen) fail("'aliases' appears twice in one layer")
    seen[n, "aliases"] = 1
    if (substr(v, 1, 1) == "{") { flowmap(v, "aliases"); after(FR); return }
    fail("aliases must be a one-line map: aliases: { acme: acme-public }")
  }
  if (where == "source" && k == "auth") {
    if ((n, m, "auth") in seen) fail("'auth' appears twice in one source")
    seen[n, m, "auth"] = 1
    if (v == "" || substr(v, 1, 1) == "#") { ctx = "authwait"; return }
    if (substr(v, 1, 1) == "{") { flowmap(v, "auth"); after(FR); return }
    fail("auth must be a map: auth: { type: basic, secret: <name> }")
  }
  if (v == "" || substr(v, 1, 1) == "#") fail("'" k "' has no value")
  setkey(where, k, scalar(v, "'" k "'"))
}
function newlayer(t, i,   rest) {
  n++; m = 0; ctx = "layer"; LK = -1; SI = -1
  printf "Y\t%d\t%d\n", n, NR
  rest = substr(t, 2)
  if (rest ~ /^ *(#.*)?$/) return
  LK = i + 1 + ind(rest); sub(/^ +/, "", rest)
  if (substr(rest, 1, 1) == "{") fail("write a layer as key: value lines, not { }")
  keyline(rest, "layer")
}
function newsource(t, i,   rest) {
  m++; ctx = "source"; SK = -1
  printf "S\t%d\t%d\t%d\n", n, m, NR
  rest = substr(t, 2)
  if (rest ~ /^ *(#.*)?$/) return
  SK = i + 1 + ind(rest); sub(/^ +/, "", rest)
  if (substr(rest, 1, 1) == "{") { flowmap(rest, "source"); after(FR); SK = -2; return }
  keyline(rest, "source")
}
BEGIN { n = 0; ctx = "top"; LI = -1; sawlayers = 0 }
{
  line = $0; sub(/\r$/, "", line)
  t = line; sub(/^ +/, "", t)
  if (t == "" || substr(t, 1, 1) == "#") next
  if (substr(t, 1, 1) == "\t") fail("a tab in the indentation; indent with spaces")
  i = ind(line)
  dash = (t == "-" || substr(t, 1, 2) == "- ")
  if (i == 0) {
    if (t == "---") next
    if (t ~ /^layers:/) {
      if (sawlayers) fail("'layers' appears twice")
      sawlayers = 1
      v = plain(substr(t, 8)); sub(/^[ \t]+/, "", v)
      if (v == "") { ctx = "layers"; next }
      if (v ~ /^\[[ ]*\]$/) { ctx = "none"; next }
      fail("layers must be a list of entries, one '- id: ...' each")
    }
    if (t ~ /^[A-Za-z0-9_-]+:/) { k = t; sub(/:.*/, "", k); fail("unknown top-level key '" k "' (the file holds layers: only)") }
    fail("expected layers: at the top level")
  }
  if (ctx == "authwait") {
    if (!dash && i > SK) { AK = i; ctx = "auth" }
    else fail("auth: needs its keys indented below it, or auth: { type: basic, secret: <name> }")
  }
  if (ctx == "auth") {
    if (!dash && i == AK) { keyline(t, "auth"); next }
    if (i > AK) fail("unexpected indentation")
    ctx = "source"
  }
  if (ctx == "source") {
    if (SK == -1 && !dash && i > SI) SK = i
    if (!dash && i == SK) { keyline(t, "source"); next }
    if (dash && i == SI) { newsource(t, i); next }
    if (i > SK && SK >= 0) fail("unexpected indentation")
    ctx = "layer"
  }
  if (ctx == "srcwait") {
    if (dash && i > LK) { SI = i; newsource(t, i); next }
    ctx = "layer"
  }
  if (ctx == "layer") {
    if (LK == -1 && !dash && i > LI) LK = i
    if (!dash && i == LK) { keyline(t, "layer"); next }
    if (dash && i == LI) { newlayer(t, i); next }
    fail("unexpected indentation")
  }
  if (ctx == "layers") {
    if (dash) { LI = i; newlayer(t, i); next }
    fail("expected a list item, - id: ...")
  }
  fail("unexpected indentation")
}
END {
  if (failed) exit 2
  if (!sawlayers) { printf "E\t0\tno layers: list in the file\n"; exit 2 }
}
AWK

# Layer namespaces (1.7.0, ADR-0073 decision 4): a name of lower-case letters and digits in words
# joined by one -, at most 40 characters (so <ns>--<name>, a namespaced skill's folder, splits at its
# first --). component-registry (the built-in base layer) and anthropic-skills (Claude Code's
# synced skills) are reserved.
NS_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
NS_RESERVED="$BASE_ID anthropic-skills"

# load_list: parse and check RF_ABS into NL and the arrays L_ID, L_AT, L_REQ, L_LINE, L_NSRC, L_NS and,
# keyed "<n>.<m>", S_KIND, S_REQ, S_LINE, S_ARGS (key=value lines handed to the source).
load_list() {
  local out rc rec a b c d errs=0 i j at k v
  [ -f "$RF_ABS" ] || die 2 "no layer list at $RF_ABS (from $RF_SOURCE); write one (see the component-registry Feature notes) or set COMPONENT_REGISTRY_FILE to its path relative to $ROOT."
  out="$(awk "$LIST_PARSER" "$RF_ABS")"; rc=$?
  NL=0; L_ID=() L_AT=() L_WR=() L_HD=() L_NS=() L_NSL=() L_AL=() L_ALL=() L_REQ=() L_LINE=() L_NSRC=() S_KIND=() S_REQ=() S_LINE=() S_ARGS=() S_PIN=()
  while IFS=$'\t' read -r rec a b c d _; do
    case "$rec" in
      Y) NL="$a"; L_LINE[a]="$b" L_NSRC[a]=0 L_REQ[a]=false ;;
      K) case "$b" in id) L_ID[a]="$c" ;; at) L_AT[a]="$c" ;; required) L_REQ[a]="$c" ;; writable) L_WR[a]="$c" ;; heading) L_HD[a]="$c" ;; namespace) L_NS[a]="$c" L_NSL[a]="$d" ;; esac ;;
      S) L_NSRC[a]="$b"; S_LINE["$a.$b"]="$c" S_REQ["$a.$b"]=false S_ARGS["$a.$b"]='' ;;
      A) L_AL[a]+="$b=$c " L_ALL[a]="$d" ;;
      P) case "$c" in
           kind) S_KIND["$a.$b"]="$d" ;;
           required) S_REQ["$a.$b"]="$d" ;;
           *) S_ARGS["$a.$b"]+="$c=$d"$'\n' ;;
         esac ;;
      E) die 2 "$RF:$a: $b" ;;
    esac
  done <<< "$out"
  [ "$rc" -eq 0 ] || die 2 "$RF: could not be read"
  for ((i = 1; i <= NL; i++)); do
    at="$RF:${L_LINE[i]}: layer $i"
    if [ -z "${L_ID[i]:-}" ]; then warn "$at has no id"; errs=$((errs + 1))
    elif ! [[ "${L_ID[i]}" =~ ^[A-Za-z0-9_-]+$ ]]; then warn "$at: id '${L_ID[i]}' may hold only letters, digits, - and _"; errs=$((errs + 1))
    fi
    for ((j = 1; j < i; j++)); do
      [ -n "${L_ID[i]:-}" ] && [ "${L_ID[i]}" = "${L_ID[j]:-}" ] && { warn "$at: id '${L_ID[i]}' is already used by layer $j"; errs=$((errs + 1)); }
    done
    [ "${L_ID[i]:-}" = "$BASE_ID" ] && { warn "$at: id '$BASE_ID' is reserved for the Feature's built-in base layer (its utility skills); pick another"; errs=$((errs + 1)); }
    if [ -z "${L_AT[i]:-}" ]; then warn "$at has no at (the path the layer is mounted at, like /Corp)"; errs=$((errs + 1))
    else
      L_AT[i]="${L_AT[i]%/}"; [ -n "${L_AT[i]}" ] || L_AT[i]=/
      valid_path "${L_AT[i]}" || { warn "$at: at '${L_AT[i]}' must be an absolute path without wildcards"; errs=$((errs + 1)); }
    fi
    case "${L_REQ[i]}" in true | false) ;; *) warn "$at: required is true or false"; errs=$((errs + 1)) ;; esac
    case "${L_WR[i]:-false}" in true | false) ;; *) warn "$at: writable is true or false"; errs=$((errs + 1)) ;; esac
    case "${L_HD[i]:-true}" in true | false) ;; *) warn "$at: heading is true or false"; errs=$((errs + 1)) ;; esac
    if [ -n "${L_NS[i]+x}" ]; then
      v="${L_NS[i]}"
      if ! [[ "$v" =~ $NS_RE ]] || [ "${#v}" -gt 40 ]; then
        warn "$RF:${L_NSL[i]}: layer ${L_ID[i]:-$i}: namespace '$v' may hold only lower-case letters and digits, in words joined by one - (like acme or acme-tools), at most 40 characters"; errs=$((errs + 1))
      elif [[ " $NS_RESERVED " == *" $v "* ]]; then
        warn "$RF:${L_NSL[i]}: layer ${L_ID[i]:-$i}: namespace '$v' is reserved; pick another"; errs=$((errs + 1))
      fi
    fi
    # aliases (1.7.0): <alias>: <namespace>, both namespace names, one hop, never the layer's own
    local al an at2
    for al in ${L_AL[i]:-}; do
      an="${al%%=*}" at2="${al#*=}"
      for v in "$an" "$at2"; do
        if ! [[ "$v" =~ $NS_RE ]] || [ "${#v}" -gt 40 ]; then
          warn "$RF:${L_ALL[i]}: layer ${L_ID[i]:-$i}: alias '$an: $at2': '$v' is not a namespace name (lower-case letters and digits in words joined by one -, at most 40)"; errs=$((errs + 1)); continue 2
        fi
      done
      if [[ " $NS_RESERVED " == *" $at2 "* ]]; then warn "$RF:${L_ALL[i]}: layer ${L_ID[i]:-$i}: alias '$an: $at2': namespace '$at2' is reserved"; errs=$((errs + 1)); continue; fi
      if [ "$an" = "$at2" ]; then warn "$RF:${L_ALL[i]}: layer ${L_ID[i]:-$i}: alias '$an: $at2' names itself"; errs=$((errs + 1)); continue; fi
      if [ -n "${L_NS[i]:-}" ] && { [ "$an" = "${L_NS[i]}" ] || [ "$at2" = "${L_NS[i]}" ]; }; then
        warn "$RF:${L_ALL[i]}: layer ${L_ID[i]:-$i}: alias '$an: $at2' involves the layer's own namespace ${L_NS[i]}; a name without a prefix already means it"; errs=$((errs + 1)); continue
      fi
      if [[ " ${L_AL[i]} " == *" $at2="* ]]; then
        warn "$RF:${L_ALL[i]}: layer ${L_ID[i]:-$i}: alias '$an: $at2' leads to another alias ($at2); an alias is one hop, name the namespace itself"; errs=$((errs + 1)); continue
      fi
    done
    [ "${L_NSRC[i]}" -gt 0 ] || { warn "$at has no sources"; errs=$((errs + 1)); }
    for ((j = 1; j <= L_NSRC[i]; j++)); do
      k="$i.$j"; at="$RF:${S_LINE[$k]}: layer ${L_ID[i]:-$i} source $j"
      case "${S_REQ[$k]}" in true | false) ;; *) warn "$at: required is true or false"; errs=$((errs + 1)) ;; esac
      [ "${L_REQ[i]}" = true ] && S_REQ[$k]=true
      v="${S_KIND[$k]:-}"
      if [ -z "$v" ]; then warn "$at has no kind"; errs=$((errs + 1)); continue; fi
      [[ "$v" =~ ^[a-z0-9-]+$ ]] || { warn "$at: kind '$v' may hold only lower-case letters, digits and -"; errs=$((errs + 1)); continue; }
      # The kinds this release installs are checked here, so a mistake names its line.
      case "$v" in
        http)
          grep -q '^url=' <<< "${S_ARGS[$k]}" || { warn "$at: an http source needs url"; errs=$((errs + 1)); }
          grep -q '^\(branch\|tag\|commit\|remote\)=' <<< "${S_ARGS[$k]}" && { warn "$at: an http source takes url, archive, sha256, path, max-size, allow-insecure and auth (type, user, secret, header) only"; errs=$((errs + 1)); }
          if grep -q '^\(sha256\|path\)=' <<< "${S_ARGS[$k]}" && ! grep -q '^archive=' <<< "${S_ARGS[$k]}"; then warn "$at: sha256 and path belong to an archive source (archive: tar.gz, tgz or zip)"; errs=$((errs + 1)); fi
          v="$(sed -n 's/^max-size=//p' <<< "${S_ARGS[$k]}")"
          [ -z "$v" ] || [[ "$v" =~ ^[1-9][0-9]*[KMG]?$ ]] || { warn "$at: max-size is a number of bytes or a number with K, M or G (binary), not 0 or negative: '$v'"; errs=$((errs + 1)); }
          v="$(sed -n 's/^archive=//p' <<< "${S_ARGS[$k]}")"
          case "$v" in '' | tar.gz | tgz | zip) ;; *) warn "$at: archive is tar.gz, tgz or zip"; errs=$((errs + 1)) ;; esac ;;
        cloud-folder)
          grep -q '^remote=' <<< "${S_ARGS[$k]}" || { warn "$at: a cloud-folder source needs remote (a folder under the cloud folder)"; errs=$((errs + 1)); }
          grep -q '^\(url\|branch\|tag\|commit\|path\|allow-insecure\|archive\|sha256\|max-size\|auth\.[a-z]*\)=' <<< "${S_ARGS[$k]}" && { warn "$at: a cloud-folder source takes remote only (the cloud folder's own set-up is its log-in)"; errs=$((errs + 1)); } ;;
        git)
          grep -q '^url=' <<< "${S_ARGS[$k]}" || { warn "$at: a git source needs url"; errs=$((errs + 1)); }
          [ "$(grep -c '^\(branch\|tag\|commit\)=' <<< "${S_ARGS[$k]}")" -eq 1 ] || { warn "$at: a git source needs exactly one of branch, tag, commit"; errs=$((errs + 1)); }
          grep -q '^\(remote\|allow-insecure\|archive\|sha256\|max-size\|auth\.header\)=' <<< "${S_ARGS[$k]}" && { warn "$at: a git source takes url, branch, tag or commit, path (a folder of the repository), and auth (type, user, secret)"; errs=$((errs + 1)); } ;;
        db)
          grep -q '^driver=' <<< "${S_ARGS[$k]}" || { warn "$at: a db source needs driver (sqlite or postgres)"; errs=$((errs + 1)); }
          [ "$(grep -c '^\(table\|query\)=' <<< "${S_ARGS[$k]}")" -eq 1 ] || { warn "$at: a db source needs exactly one of table, query"; errs=$((errs + 1)); }
          grep -q '^\(url\|branch\|tag\|commit\|remote\|allow-insecure\|archive\|sha256\|max-size\|auth\.\(type\|user\|header\)\)=' <<< "${S_ARGS[$k]}" && { warn "$at: a db source takes driver, path or host, port, database, user, sslmode, table or query, and auth.secret only"; errs=$((errs + 1)); }
          if grep -q '^driver=sqlite$' <<< "${S_ARGS[$k]}"; then
            grep -q '^path=' <<< "${S_ARGS[$k]}" || { warn "$at: a sqlite db source needs path"; errs=$((errs + 1)); }
            # A relative path is the repository's; the source gets it absolute.
            v="$(sed -n 's/^path=//p' <<< "${S_ARGS[$k]}")"
            case "$v" in /* | '') ;; *) S_ARGS[$k]="$(grep -v '^path=' <<< "${S_ARGS[$k]}")"$'\n'"path=$ROOT/$v"$'\n' ;; esac
          elif grep -q '^driver=postgres$' <<< "${S_ARGS[$k]}"; then
            for v in host database user; do grep -q "^$v=" <<< "${S_ARGS[$k]}" || { warn "$at: a postgres db source needs $v"; errs=$((errs + 1)); }; done
          fi ;;
        path)
          grep -q '^path=' <<< "${S_ARGS[$k]}" || { warn "$at: a path source needs path"; errs=$((errs + 1)); }
          grep -q '^\(url\|branch\|tag\|commit\|remote\|archive\|sha256\|max-size\|auth\.[a-z]*\)=' <<< "${S_ARGS[$k]}" && { warn "$at: a path source takes path only (the folder's own permissions are its log-in)"; errs=$((errs + 1)); }
          # A relative path is the repository's; the source gets it absolute.
          v="$(sed -n 's/^path=//p' <<< "${S_ARGS[$k]}")"
          case "$v" in /*) ;; *) S_ARGS[$k]="$(grep -v '^path=' <<< "${S_ARGS[$k]}")"$'\n'"path=$ROOT/$v"$'\n' ;; esac ;;
      esac
      # The pin: what the list says to read. A changed pin is another copy, never the old one.
      S_PIN[$k]="kind=${S_KIND[$k]}"$'\x1f'"$(printf '%s' "${S_ARGS[$k]}" | LC_ALL=C sort | tr '\n' '\037')"
    done
  done
  [ "$errs" -eq 0 ] || die 2 "$RF: $errs problem(s) above; nothing was resolved"
}

# -------------------------------------------------------------------- fetch ----
meta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

# source_args <key>: the source's key=value lines as arguments, into SARGS
source_args() { SARGS=(); local l; while IFS= read -r l; do [ -n "$l" ] && SARGS+=("$l"); done <<< "${S_ARGS[$1]}"; }

# fetch_source <n> <m>: brings the layer copy up to date. Sets SRC_STATE (fetched, unchanged,
# offline, missing), SRC_VER, SRC_AT (when the copy was fetched) and SRC_NOTE.
fetch_source() {
  local n="$1" m="$2" k="$1.$2" id="${L_ID[$1]}" kind cmd dir meta ver rc oldpin oldver new
  kind="${S_KIND[$k]}" cmd="registry-source-${S_KIND[$k]}"
  dir="$STATE_DIR/copies/$id/$m" meta="$STATE_DIR/copies/$id/$m.meta"
  SRC_STATE='' SRC_VER='' SRC_AT='' SRC_NOTE=''
  source_args "$k"
  oldpin="$(meta_get "$meta" pin)" oldver="$(meta_get "$meta" version)"
  if [ "$oldpin" != "$(printf '%s' "${S_PIN[$k]}" | tr '\037' ' ')" ]; then
    # Another pin (or none yet): the old copy is something else and never a fallback.
    rm -rf "$dir" "$meta"; oldver=''
  fi
  if ! command -v "$cmd" >/dev/null 2>&1; then
    case "$kind" in
      db) SRC_NOTE="no $cmd on PATH (component-registry 1.5.0 or later installs it)" ;;
      http) SRC_NOTE="no $cmd on PATH (component-registry 1.2.0 or later installs it)" ;;
      cloud-folder) SRC_NOTE="no $cmd on PATH (the cloud-folder Feature, 1.4.0 or later, installs it)" ;;
      *) SRC_NOTE="no $cmd on PATH (the Feature that owns the $kind transport installs it)" ;;
    esac
    offline_or_missing; return
  fi
  ver="$("$cmd" version "$id" "${SARGS[@]}" 2>"$TMP/err")"; rc=$?
  ver="$(printf '%s' "$ver" | tail -n 1 | tr -d '\t\r')"
  if [ "$rc" -eq 0 ] && [ -n "$ver" ] && [ "$ver" = "$oldver" ] && [ -d "$dir" ]; then
    SRC_STATE=unchanged SRC_VER="$ver" SRC_AT="$(meta_get "$meta" fetched)"; return
  fi
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    SRC_NOTE="$cmd version failed (exit $rc): $(grep -m 1 . "$TMP/err")"; offline_or_missing; return
  fi
  new="$dir.new.$$"; rm -rf "$new"; mkdir -p "$new"
  if ! "$cmd" fetch "$id" "$new" "${SARGS[@]}" 2>"$TMP/err" >/dev/null; then
    rm -rf "$new"; SRC_NOTE="$cmd fetch failed: $(grep -m 1 . "$TMP/err")"; offline_or_missing; return
  fi
  # A source that cannot say its version (exit 3) is fetched every time; its version is the time.
  [ "$rc" -eq 3 ] || [ -z "$ver" ] && ver="fetched-$(date -u +%Y%m%dT%H%M%SZ)"
  rm -rf "$dir"; mv "$new" "$dir"
  SRC_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  { printf 'pin=%s\n' "$(printf '%s' "${S_PIN[$k]}" | tr '\037' ' ')"; printf 'version=%s\nfetched=%s\n' "$ver" "$SRC_AT"; } > "$meta"
  SRC_STATE=fetched SRC_VER="$ver"
}

offline_or_missing() {
  if [ -d "$dir" ] && [ -f "$meta" ]; then
    SRC_STATE=offline SRC_VER="$(meta_get "$meta" version)" SRC_AT="$(meta_get "$meta" fetched)"
  else
    SRC_STATE=missing
  fi
}

# ------------------------------------------------------------------- merge ----
# The resolver: reads the manifest (rank, layer, at, source, version, copy folder, .layer file per
# line), parses every .layer file, applies the match rule for W and merges by type (proposal 3.3).
# Writes meta/ in VIEW itself and prints to stdout:
#   C <component> <folder>             copy the folder's files into the component (in order)
#   N <component>                      a component resolved
#   R <component> <layer> <loc> <key> <reason>   a line skipped (reported by resolve)
#   Q <layer> <loc> <reason>           a line that could not be read
read -r -d '' RESOLVER <<'AWK'
function q(s) { gsub(/'/, "'\\''", s); return "'" s "'" }
# tsv(s): one TSV field; an empty one is "-", since bash read collapses two tabs into one
function tsv(s) { gsub(/[\t\r\n]/, " ", s); return s == "" ? "-" : s }
function first(s,   i) { i = index(s, "/"); return i ? substr(s, 1, i - 1) : s }
function rest(s,   i) { i = index(s, "/"); return i ? substr(s, i + 1) : "" }
# Layer namespaces (1.7.0): a namespaced component is <kind>/<ns>:<name>. cns(c) is its namespace
# ("" for the Operator's own), cbare(c) the <kind>/<name> its layers' sections match, disk(c) where
# it lands in the view: a skill as skills/<ns>--<name> (the folder and SKILL.md name Claude Code and
# the adapters take; a ':' is no skill folder name), anything else under its registry name.
function cns(c,   n) { n = c; sub(/^[^\/]*\//, "", n); return index(n, ":") ? substr(n, 1, index(n, ":") - 1) : "" }
function cbare(c,   k, n) { k = c; sub(/\/.*$/, "", k); n = c; sub(/^[^\/]*\//, "", n); sub(/^[^:]*:/, "", n); return k "/" n }
function disk(c,   ns) { ns = cns(c); if (ns == "" || c !~ /^skills\//) return c; return "skills/" ns "--" substr(cbare(c), 8) }
# segmatch(p, s): pattern p matches path s; both without a leading /, "" is the root.
# * is one segment, ** any number (none included).
function segmatch(p, s,   ph) {
  if (p == "") return s == ""
  ph = first(p)
  if (ph == "**") {
    if (segmatch(rest(p), s)) return 1
    if (s == "") return 0
    return segmatch(p, rest(s))
  }
  if (s == "") return 0
  if (ph == "*" || ph == first(s)) return segmatch(rest(p), rest(s))
  return 0
}
# deepest(scope): the depth of the deepest of W and its ancestors the scope matches, -1 for none
function deepest(scope,   d, anc, k) {
  for (d = NW; d >= 0; d--) {
    anc = ""
    for (k = 1; k <= d; k++) anc = anc (k > 1 ? "/" : "") WSEG[k]
    if (segmatch(scope, anc)) return d
  }
  return -1
}
function wildcards(p,   a, n, k, c) { n = split(p, a, "/"); c = 0; for (k = 1; k <= n; k++) if (a[k] == "*" || a[k] == "**") c++; return c }
function strength(rank, d, wild, ord) { return ((rank * 100 + d) * 100 + (99 - wild)) * 1000000 + ord }
function problem(loc, why) { printf "Q\t%s\t%s\t%s\n", CURLAYER, loc, why; print CURLAYER "\t" loc "\t" why >> PROBLEMS }
# section(path, loc): a section header's path, joined to the layer's at, split into scope and
# component at the first kind segment. Sets SECOK.
function section(raw, loc,   path, excl, a, n, k, scope, comp, found, seg) {
  SECOK = 0
  excl = 0
  if (substr(raw, 1, 1) == "!") { excl = 1; raw = substr(raw, 2) }
  if (raw == "") { problem(loc, "an empty section path"); return }
  if (substr(raw, 1, 1) == "/") path = raw; else path = (AT == "/" ? "" : AT) "/" raw
  sub(/\/+$/, "", path)
  n = split(path, a, "/")
  scope = ""; comp = ""; found = 0
  for (k = 2; k <= n; k++) {
    seg = a[k]
    if (seg !~ /^[A-Za-z0-9._-]+$/ && seg != "*" && seg != "**") { problem(loc, "segment '" seg "' of [" raw "]: letters, digits, . _ - or a whole * or ** only"); return }
    if (!found && (seg in KIND)) found = k
    if (!found) scope = scope (scope == "" ? "" : "/") seg
    else comp = comp (comp == "" ? "" : "/") seg
  }
  NS++
  Sscope[NS] = scope; Scomp[NS] = comp; Sexcl[NS] = excl; Sfile[NS] = FILEID; Srank[NS] = RANK
  Slayer[NS] = CURLAYER; Sloc[NS] = loc; Sord[NS] = ++ORD; Swild[NS] = wildcards(scope) + wildcards(comp)
  Sraw[NS] = (excl ? "!" : "") raw
  Sreplace[NS] = 0; Sns[NS] = NSP
  SECOK = 1
}
function entry(t, loc,   k, ty, data, p) {
  if (!SECOK) { problem(loc, CURSEC ? "under a section header that could not be read" : "outside a section; start one with [path]"); return }
  if (Sexcl[NS]) { problem(loc, "an exclusion section [!...] holds no entries"); return }
  if (Scomp[NS] == "") { problem(loc, "[" Sraw[NS] "] names no component (no " KINDLIST " segment)"); return }
  NLN++
  Lsec[NLN] = NS; Lrank[NLN] = RANK; Llayer[NLN] = CURLAYER; Lver[NLN] = VER; Lloc[NLN] = loc
  Lord[NLN] = ++ORD; Lcopy[NLN] = COPY
  if (t ~ /^lock[ \t]/) {
    k = t; sub(/^lock[ \t]+/, "", k); sub(/[ \t]+$/, "", k)
    Llock[NLN] = 1; Lkey[NLN] = k; Ltype[NLN] = "lock"; Ldata[NLN] = ""
    return
  }
  p = index(t, "=")
  k = substr(t, 1, p - 1); data = substr(t, p + 1)
  sub(/[ \t]+$/, "", k); sub(/^[ \t]/, "", data); sub(/[ \t]+$/, "", data)
  ty = k; sub(/^[^:]*:/, "", ty); sub(/:.*$/, "", k)
  Llock[NLN] = 0; Lkey[NLN] = k; Ltype[NLN] = ty; Ldata[NLN] = data
}
function parse(file,   ln, nr, t, loc, p, hdr, dir) {
  nr = 0; SECOK = 0; CURSEC = 0; FILEID++
  while ((getline ln < file) > 0) {
    nr++
    sub(/\r$/, "", ln)
    t = ln; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
    loc = SRC ":" REL ":" nr
    if (t == "" || substr(t, 1, 1) == ";") continue
    if (substr(t, 1, 1) == "[") {
      CURSEC = 1; SECOK = 0
      p = index(t, "]")
      if (p == 0) { problem(loc, "a section header needs a closing ]"); continue }
      hdr = substr(t, p + 1); sub(/^[ \t]+/, "", hdr)
      if (hdr != "" && hdr != "@replace") { problem(loc, "after [path] only @replace may follow"); continue }
      section(substr(t, 2, p - 2), loc)
      if (SECOK && hdr == "@replace") {
        if (Sexcl[NS]) { problem(loc, "an exclusion section cannot be @replace"); SECOK = 0; continue }
        Sreplace[NS] = 1
      }
      continue
    }
    if (t ~ /^lock[ \t]+[A-Za-z0-9_.-]+$/) { entry(t, loc); continue }
    if (t ~ /^[A-Za-z0-9_.-]+:[A-Za-z]+[ \t]*=/) {
      p = t; sub(/[ \t]*=.*$/, "", p); sub(/^[^:]*:/, "", p)
      if (p !~ /^(value|list|text|ref)$/) { problem(loc, "type '" p "' is none of value, list, text, ref"); continue }
      entry(t, loc); continue
    }
    problem(loc, "not a section, an entry (key:type = data), a lock (lock key) or a comment (;)")
  }
  close(file)
}
# nohead(layer): 1 when the layer stacks its text without a heading (heading: false in the list)
function nohead(l) { return index(NOHEAD, " " l " ") > 0 }
# setfm(fm, key, val): the front matter (---...---, or none) with key: val, replacing the key's line
# and its indented continuation lines, else added before the closing ---
function setfm(fm, key, val,   ln, nl, x, o, done, skip) {
  if (fm == "") fm = "---\n---"
  nl = split(fm, ln, "\n"); o = ""; done = 0; skip = 0
  for (x = 1; x <= nl; x++) {
    if (skip && ln[x] ~ /^[ \t]/) continue
    skip = 0
    if (x > 1 && x < nl && !done && index(ln[x], key ":") == 1) { o = o "\n" key ": " val; done = 1; skip = 1; continue }
    if (x == nl && !done) o = o "\n" key ": " val
    o = o (x > 1 ? "\n" : "") ln[x]
  }
  return o
}
function isperm(k) { return k == "allowed-tools" || k == "disallowed-tools" || k ~ /^permission/ }
# ismodel(k) (1.6.0): model, or model.<cli> (the model for agents of that CLI only)
function ismodel(k) { return k == "model" || k ~ /^model\.[A-Za-z0-9_-]+$/ }
# agentwhy(key, type, data) (1.6.0): why a line of an agent definition is skipped, "" when it is a
# field. Only model and model.<cli> (one value each) and skills (a list); the agents list owns every
# other field, and an agent definition never carries a permission (rule 3 alone would keep the
# lowest layer's, which is not the repository).
function agentwhy(k, t, d) {
  if (index(" name cli kind folder lifecycle identity lease default session-name registry-path attachment args definition ", " " k " "))
    return "the agents list owns " k "; the registry never sets it for an agent" (k == "args" || k == "definition" ? "; it could widen a permission" : "")
  if (isperm(k)) return "an agent definition carries no permission key"
  if (!ismodel(k) && k != "skills") return "not an agent definition field (model, model.<cli>, skills)"
  if (ismodel(k) && t != "value") return k " is one value: " k ":value = <model>"
  if (k == "skills" && t != "list") return "skills is a list: skills:list = <name>, ref:skills/<name>"
  if (ismodel(k) && (length(d) > 100 || d !~ /^[][A-Za-z0-9._:\/@-]+$/)) return "a model is one word of letters, digits and . _ : / @ [ ] - (at most 100)"
  return ""
}
# agentout(c, n, cand, cs) (1.6.0): the agent definition's machine-readable view,
# VIEW/agents/<name>/: model (one line: the effective model for the agent's CLI), cli (the CLI it was
# resolved for, when the participant named it), skills (one name per line; a
# ref:[scope/]skills/<name>[:key] item gives its name) and from.tsv (field, layer, source:file:line,
# key of each line used). The effective model: the strongest of the model line and the
# model.<the agent's cli> line by layer, then specificity, then fewer wildcards; on a tie there the
# suffixed key wins, then the later line.
function agentout(c, n, cand, cs,   dir, a, i, x, nit, it, items, out, seen, cli, mk, best, bbase, bsuf, base, suf) {
  dir = VIEW "/" c; CNSA = cns(c)
  system("mkdir -p " q(dir))
  cli = (c in ACLI) ? ACLI[c] : ""
  if (cli != "") { print cli > (dir "/cli"); close(dir "/cli") }
  best = 0; bbase = -1; bsuf = -1
  for (a = 1; a <= n; a++) {
    i = cand[a]; mk = Lkey[i]
    if (Llock[i] || ST[i] != "used" || KT[mk] != "value" || !(mk == "model" || (cli != "" && mk == "model." cli))) continue
    base = int(cs[a] / 1000000); suf = (mk != "model")
    if (base > bbase || (base == bbase && (suf > bsuf || (suf == bsuf && Lord[i] > Lord[best])))) { best = i; bbase = base; bsuf = suf }
  }
  if (best && Ldata[best] != "") { print Ldata[best] > (dir "/model"); close(dir "/model") }
  if (("skills" in RES) && KT["skills"] == "list" && RES["skills"] != "") {
    nit = split(RES["skills"], items, "\n"); out = ""; split("", seen)
    for (x = 1; x <= nit; x++) {
      # 1.7.0: an item is the skill's name as the CLI knows it, <ns>--<name> for a namespaced one.
      # References are explicit: a name without a prefix is a skill of the agent definition's own
      # namespace, <ns>:<name> one of namespace <ns> (after the alias of the item's layer), from any
      # layer; a ref: item reads the same way (refparse).
      it = items[x]; ins = CNSA; ilay = ITL[c, "skills", it]
      if (it ~ /^ref:/) {
        refparse(substr(it, 5), CNSA, ilay)
        if (RT_WHY != "" || RT_KIND != "skills") { printf "R\t%s\t-\t-\tskills\titem '%s' names no skill (a name, <namespace>:<name> or ref:skills/[<namespace>:]<name>)\n", c, items[x]; continue }
        ins = RT_NS; it = RT_NAME
      } else {
        if (it ~ /(^|\/)skills\//) sub(/^.*skills\//, "", it)
        if (match(it, /^[a-z0-9]+(-[a-z0-9]+)*:/)) { ins = aliased(ilay, substr(it, 1, RLENGTH - 1)); it = substr(it, RLENGTH + 1) }
      }
      if (it !~ /^[A-Za-z0-9._-]+$/) { printf "R\t%s\t-\t-\tskills\titem '%s' names no skill (a name, <namespace>:<name> or ref:skills/[<namespace>:]<name>)\n", c, items[x]; continue }
      if (ins != "") it = ins "--" it
      if (it in seen) continue
      seen[it] = 1; out = out it "\n"
    }
    if (out != "") { printf "%s", out > (dir "/skills"); close(dir "/skills") }
  }
  printf "" > (dir "/from.tsv")
  if (best && Ldata[best] != "") print "model\t" Llayer[best] "\t" Lloc[best] "\t" Lkey[best] >> (dir "/from.tsv")
  for (a = 1; a <= n; a++) {
    i = cand[a]
    if (Lkey[i] == "skills" && !Llock[i] && ST[i] == "used") print "skills\t" Llayer[i] "\t" Lloc[i] "\tskills" >> (dir "/from.tsv")
  }
  close(dir "/from.tsv")
}
# safe relative name inside a layer copy: no leading /, no .. segment
function inside(r) { return r != "" && substr(r, 1, 1) != "/" && r !~ /(^|\/)\.\.(\/|$)/ }
function readfile(f,   ln, out, n) {
  out = ""; n = 0
  while ((getline ln < f) > 0) { out = out (n++ ? "\n" : "") ln }
  close(f)
  return out
}
function exists(f,   ln, r) { r = (getline ln < f); close(f); return r >= 0 }
function isdir(f) { return system("test -d " q(f)) == 0 }
function prov(state, i, reason) {
  print state "\t" Lkey[i] "\t" Ltype[i] "\t" Llayer[i] "\t" Lrank[i] "\t" Lver[i] "\t" Lloc[i] "\t" tsv(Ldata[i]) "\t" tsv(reason) > PROV
}
function report(c, i, reason) { printf "R\t%s\t%s\t%s\t%s\t%s\n", c, Llayer[i], Lloc[i], Lkey[i], reason }
# refparse(s, rns, lay) (1.7.0): a reference [scope/]kind/[ns:]name[:key], made by a line of layer
# lay in a component of namespace rns ("" for the Operator's own). References are explicit: no
# prefix is the referrer's own namespace; ns:name is namespace ns from any layer (after the layer's
# alias, one hop). Nothing names the un-namespaced set from inside a namespace. kind/a:b is ns a,
# name b when that component is in the view, else name a, key b when that one is, else (neither)
# ns a when a can be a namespace. Sets RT_COMP, RT_KEY, RT_NS, RT_NAME, RT_KIND, RT_ALIAS (the
# alias note, "" for none) and RT_WHY ("" when well formed).
function aliased(lay, x) { return ((lay, x) in AL) ? AL[lay, x] : x }
function mkcomp(k, ns, nm) { return k "/" (ns == "" ? "" : ns ":") nm }
function refparse(s, rns, lay,   a, n, k, found, kind, rst, pt, np, ans, acomp, bcomp, nsre, nsread) {
  RT_COMP = ""; RT_KEY = ""; RT_WHY = ""; RT_NS = ""; RT_NAME = ""; RT_KIND = ""; RT_ALIAS = ""
  sub(/^\//, "", s)
  n = split(s, a, "/"); found = 0; rst = ""
  for (k = 1; k <= n; k++) {
    if (!found && (a[k] in KIND)) { found = 1; kind = a[k]; continue }
    if (found) rst = rst (rst == "" ? "" : "/") a[k]
  }
  if (!found) { RT_WHY = "names no component"; return }
  RT_KIND = kind
  if (rst == "" || index(rst, "/")) { RT_WHY = "names no component (" kind "/[<namespace>:]<name>[:<key>])"; RT_COMP = kind (rst == "" ? "" : "/" rst); return }
  np = split(rst, pt, ":"); nsread = 0
  nsre = "^[a-z0-9]+(-[a-z0-9]+)*$"
  if (np == 1) { RT_NS = rns; RT_NAME = pt[1] }
  else if (np == 3) { RT_NS = aliased(lay, pt[1]); RT_NAME = pt[2]; RT_KEY = pt[3]; nsread = 1 }
  else if (np == 2) {
    ans = aliased(lay, pt[1]); acomp = mkcomp(kind, ans, pt[2]); bcomp = mkcomp(kind, rns, pt[1])
    if ((acomp in INCOMP) || (!(bcomp in INCOMP) && pt[1] ~ nsre)) { RT_NS = ans; RT_NAME = pt[2]; nsread = 1 }
    else { RT_NS = rns; RT_NAME = pt[1]; RT_KEY = pt[2] }
  } else { RT_WHY = "names no component (" kind "/[<namespace>:]<name>[:<key>])"; RT_COMP = kind "/" rst; return }
  if (nsread && RT_NS != pt[1]) RT_ALIAS = pt[1] ":" RT_NAME " -> " RT_NS ":" RT_NAME " (alias on " lay ")"
  RT_COMP = mkcomp(kind, RT_NS, RT_NAME)
}
function resolve(c,   i, j, n, d, x, y, cand, cs, lowrank, rmax, rloc, rlay, k, ty, tmp, parts, kd, out, items, it, nit, a, na, b, w, blk, lastlay, fm, p, base, nkeys) {
  base = META "/" c
  CNS = cns(c); CB = cbare(c)
  system("mkdir -p " q(base "/values"))
  PROV = base "/provenance.tsv"
  printf "" > PROV
  n = 0; split("", cand); split("", cs)
  for (i = 1; i <= NLN; i++) {
    j = Lsec[i]
    # 1.7.0: a line reaches a component of its own namespace only (none: the Operator's own)
    if (Sns[j] != CNS || !segmatch(Scomp[j], CB)) continue
    d = deepest(Sscope[j])
    if (d < 0) { if (Scomp[j] == CB) NA[++nna] = i; continue }
    x = 0
    for (y = j + 1; y <= NS; y++) {
      if (!Sexcl[y] || Sfile[y] != Sfile[j]) continue
      if ((Scomp[y] == "" || segmatch(Scomp[y], CB)) && deepest(Sscope[y]) >= 0) { x = y; break }
    }
    if (x) { EX[++nex] = i; EXBY[nex] = x; continue }
    cand[++n] = i; cs[n] = strength(Lrank[i], d, Swild[j], Lord[i])
  }
  # weakest first: insertion sort on strength
  for (a = 2; a <= n; a++) {
    tmp = cand[a]; w = cs[a]
    for (b = a - 1; b >= 1 && cs[b] > w; b--) { cand[b + 1] = cand[b]; cs[b + 1] = cs[b] }
    cand[b + 1] = tmp; cs[b + 1] = w
  }
  lowrank = -1
  for (a = 1; a <= n; a++) if (lowrank < 0 || Lrank[cand[a]] < lowrank) lowrank = Lrank[cand[a]]
  # locks: the lowest layer that locks a key keeps it
  split("", LOCKR); split("", LOCKI)
  for (a = 1; a <= n; a++) {
    i = cand[a]; if (!Llock[i]) continue
    k = Lkey[i]
    if (!(k in LOCKR) || Lrank[i] < LOCKR[k]) { LOCKR[k] = Lrank[i]; LOCKI[k] = i }
  }
  # @replace: the strongest replacing section that applies drops every weaker line
  rmax = -1
  for (j = 1; j <= NS; j++) {
    if (!Sreplace[j] || Sns[j] != CNS || !segmatch(Scomp[j], CB)) continue
    d = deepest(Sscope[j]); if (d < 0) continue
    x = 0
    for (y = j + 1; y <= NS; y++) if (Sexcl[y] && Sfile[y] == Sfile[j] && (Scomp[y] == "" || segmatch(Scomp[y], CB)) && deepest(Sscope[y]) >= 0) { x = y; break }
    if (x) continue
    w = strength(Srank[j], d, Swild[j], Sord[j])
    if (w > rmax) { rmax = w; rloc = Sloc[j]; rlay = Slayer[j] }
  }
  split("", KT); split("", KTI); split("", ST); split("", WHY); split("", KORDER); nkeys = 0
  for (a = 1; a <= n; a++) {
    i = cand[a]; k = Lkey[i]
    if (Llock[i]) {
      if (LOCKI[k] == i) { ST[i] = "used"; WHY[i] = "locks " k " for every higher layer" }
      else if (Lrank[i] == LOCKR[k]) { ST[i] = "used"; WHY[i] = "locks " k " (also locked at " Lloc[LOCKI[k]] ")" }
      else { ST[i] = "overridden"; WHY[i] = "already locked by " Llayer[LOCKI[k]] " at " Lloc[LOCKI[k]] }
      continue
    }
    if (rmax >= 0 && cs[a] < rmax && !((k in LOCKR) && Lrank[i] <= LOCKR[k])) { ST[i] = "dropped"; WHY[i] = "dropped by @replace in " rlay " at " rloc; continue }
    if (c ~ /^agents\// && (AWHY = agentwhy(k, Ltype[i], Ldata[i])) != "") { ST[i] = "skipped"; WHY[i] = AWHY; continue }
    if (isperm(k) && Lrank[i] > lowrank) { ST[i] = "skipped"; WHY[i] = "a permission key is taken from the component's lowest layer only (rank " lowrank ")"; continue }
    if (c ~ /^agents\// && k ~ /^model\./ && ("model" in LOCKR) && Lrank[i] > LOCKR["model"]) { ST[i] = "skipped"; WHY[i] = "locked by " Llayer[LOCKI["model"]] " at " Lloc[LOCKI["model"]] " (a lock on model holds every model.<cli>)"; continue }
    if ((k in LOCKR) && Lrank[i] > LOCKR[k]) { ST[i] = "skipped"; WHY[i] = "locked by " Llayer[LOCKI[k]] " at " Lloc[LOCKI[k]]; continue }
    if (!(k in KT)) { KT[k] = Ltype[i]; KTI[k] = i; KORDER[++nkeys] = k }
    if (Ltype[i] != KT[k]) { ST[i] = "skipped"; WHY[i] = "type clash: " k " is " KT[k] ", fixed by " Llayer[KTI[k]] " at " Lloc[KTI[k]]; continue }
    if (k == "files" && (Ltype[i] != "value" || Ldata[i] !~ /^@dir[ \t]/)) { ST[i] = "skipped"; WHY[i] = "files takes @dir <folder>: files:value = @dir <folder>"; continue }
    if (k == "body" && Ltype[i] != "text") { ST[i] = "skipped"; WHY[i] = "body is the SKILL.md text: body:text = ..."; continue }
    ST[i] = "alive"
  }
  # merge by type
  split("", RES)
  for (kd = 1; kd <= nkeys; kd++) {
    k = KORDER[kd]; ty = KT[k]
    if (ty == "value" || ty == "ref") {
      w = 0
      for (a = 1; a <= n; a++) { i = cand[a]; if (Lkey[i] == k && ST[i] == "alive") w = i }
      if (k == "files") {
        for (a = 1; a <= n; a++) {
          i = cand[a]; if (Lkey[i] != k || ST[i] != "alive") continue
          p = Ldata[i]; sub(/^@dir[ \t]+/, "", p); sub(/\/+$/, "", p)
          if (!inside(p) || !isdir(Lcopy[i] "/" p)) { ST[i] = "skipped"; WHY[i] = "no folder " p " in the layer copy"; continue }
          ST[i] = "used"; WHY[i] = (i == w ? "the strongest files line; its files replace weaker ones of the same name" : "files overlaid, a stronger line's file of the same name replaces it")
          printf "C\t%s\t%s\n", disk(c), Lcopy[i] "/" p
          RES[k] = p
        }
        continue
      }
      for (a = 1; a <= n; a++) {
        i = cand[a]; if (Lkey[i] != k || ST[i] != "alive") continue
        if (i == w) { ST[i] = "used"; WHY[i] = "the strongest line" } else { ST[i] = "overridden"; WHY[i] = "a stronger line wins: " Lloc[w] }
      }
      RES[k] = Ldata[w]
      if (ty == "ref") REFS[++nrefs] = c SUBSEP k SUBSEP Ldata[w] SUBSEP Llayer[w]
    } else if (ty == "list") {
      nit = 0; split("", items)
      for (a = 1; a <= n; a++) {
        i = cand[a]; if (Lkey[i] != k || ST[i] != "alive") continue
        ST[i] = "used"; WHY[i] = "items combined"
        na = split(Ldata[i], parts, ",")
        for (b = 1; b <= na; b++) {
          it = parts[b]; sub(/^[ \t]+/, "", it); sub(/[ \t]+$/, "", it)
          if (it == "") continue
          if (substr(it, 1, 1) == "!") {
            it = substr(it, 2)
            for (x = 1; x <= nit; x++) if (items[x] == it) { for (y = x; y < nit; y++) items[y] = items[y + 1]; nit--; x-- }
            continue
          }
          for (x = 1; x <= nit; x++) if (items[x] == it) break
          if (x > nit) items[++nit] = it
          ITL[c, k, it] = Llayer[i]
        }
      }
      out = ""
      for (x = 1; x <= nit; x++) {
        out = out (x > 1 ? "\n" : "") items[x]
        if (items[x] ~ /^ref:/) REFS[++nrefs] = c SUBSEP k SUBSEP substr(items[x], 5) SUBSEP ITL[c, k, items[x]]
      }
      RES[k] = out
    } else {
      # text: stacked from the lowest layer to the highest, one heading per layer unless the layer
      # says heading: false (1.3.0), then its text follows the one before after a blank line
      out = ""; lastlay = ""; fm = ""; bare = 0
      for (a = 1; a <= n; a++) {
        i = cand[a]; if (Lkey[i] != k || ST[i] != "alive") continue
        blk = Ldata[i]
        if (blk ~ /^@file[ \t]/) {
          p = blk; sub(/^@file[ \t]+/, "", p)
          if (!inside(p) || isdir(Lcopy[i] "/" p) || !exists(Lcopy[i] "/" p)) { ST[i] = "skipped"; WHY[i] = "no file " p " in the layer copy"; continue }
          blk = readfile(Lcopy[i] "/" p)
        }
        # The first block's front matter (--- ... ---) stays at the top of SKILL.md.
        if (out == "" && k == "body" && blk ~ /^---\n/) {
          p = index(substr(blk, 5), "\n---")
          if (p) { fm = substr(blk, 1, p + 7); blk = substr(blk, p + 8); sub(/^\n+/, "", blk) }
        }
        ST[i] = "used"; WHY[i] = "stacked"
        if (out == "") bare = nohead(Llayer[i])
        if (Llayer[i] != lastlay && !nohead(Llayer[i])) out = out (out == "" ? "" : "\n\n") "## Layer " Llayer[i] "\n\n" blk
        else out = out (out == "" ? "" : "\n\n") blk
        lastlay = Llayer[i]
      }
      RES[k] = out
      if (k == "body") { HASBODY = 1; BODYFM = fm; BODYOUT = out; BODYBARE = bare }
    }
  }
  # SKILL.md: the body, its front matter carrying the resolved name and description values (1.3.0)
  if (HASBODY) {
    fm = BODYFM
    if (c ~ /^skills\//) {
      for (x = 1; x <= 2; x++) {
        k = (x == 1 ? "name" : "description")
        if (!(k in RES) || KT[k] != "value" || RES[k] == "") continue
        if (k == "name" && CNS != "") {
          for (a = 1; a <= n; a++) { i = cand[a]; if (Lkey[i] == k && ST[i] == "used" && WHY[i] == "the strongest line") WHY[i] = "the strongest line; not written into SKILL.md: a namespaced skill is named " substr(disk(c), 8) " there" }
          continue
        }
        fm = setfm(fm, k, RES[k])
        for (a = 1; a <= n; a++) { i = cand[a]; if (Lkey[i] == k && ST[i] == "used" && WHY[i] == "the strongest line") WHY[i] = "the strongest line; written into SKILL.md's front matter" }
      }
      # 1.7.0: a namespaced skill's SKILL.md is always named <ns>--<name>, whatever its text says, so
      # it can never take the name of a skill outside its namespace
      if (CNS != "") fm = setfm(fm, "name", substr(disk(c), 8))
    }
    # a bare first block (heading: false) keeps the blank line between the front matter and the text
    printf "%s%s\n", (fm == "" ? "" : fm (BODYBARE ? "\n\n" : "\n")), BODYOUT > (base "/body.md"); close(base "/body.md")
  }
  HASBODY = 0; BODYFM = ""; BODYOUT = ""; BODYBARE = 0
  # provenance: every candidate line, then lines that do not apply
  for (a = 1; a <= n; a++) {
    i = cand[a]
    prov(ST[i] == "alive" ? "used" : ST[i], i, WHY[i])
    if (ST[i] == "skipped") report(c, i, WHY[i])
  }
  for (x = 1; x <= nex; x++) prov("excluded", EX[x], "excluded by [" Sraw[EXBY[x]] "] at " Sloc[EXBY[x]])
  for (x = 1; x <= nna; x++) prov("not-applying", NA[x], "scope /" Sscope[Lsec[NA[x]]] " is neither " WHO " nor an ancestor of it")
  nex = 0; nna = 0
  close(PROV)
  printf "" > (base "/keys.tsv")
  for (kd = 1; kd <= nkeys; kd++) {
    k = KORDER[kd]
    if (!(k in RES)) continue
    RK[c, k] = 1
    printf "%s", RES[k] (RES[k] == "" ? "" : "\n") > (base "/values/" k); close(base "/values/" k)
    out = RES[k]; if (KT[k] == "text") { gsub(/\n/, " ", out); if (length(out) > 60) out = substr(out, 1, 57) "..." } else gsub(/\n/, ", ", out)
    print k "\t" KT[k] "\t" out >> (base "/keys.tsv")
  }
  close(base "/keys.tsv")
  if (c ~ /^agents\//) agentout(c, n, cand, cs)
  printf "N\t%s\t%s\n", c, disk(c)
}
BEGIN {
  FS = "\t"
  NK = split(KINDLIST, tmp, " "); for (i = 1; i <= NK; i++) KIND[tmp[i]] = 1
  NA_ = split(ACTIVE, tmp, " "); for (i = 1; i <= NA_; i++) ACT[tmp[i]] = 1
  gsub(/ /, ", ", KINDLIST)
  NW = (WHO == "/" ? 0 : split(substr(WHO, 2), WSEG, "/"))
  PROBLEMS = META "/problems.tsv"
  printf "" > PROBLEMS
  # 1.7.0: ALIASES is "<layer>:<alias>=<namespace> ...", NSLIST the namespaces of the list's layers
  na_ = split(ALIASES, tmp, " ")
  for (i = 1; i <= na_; i++) { p_ = index(tmp[i], ":"); q_ = index(tmp[i], "="); AL[substr(tmp[i], 1, p_ - 1), substr(tmp[i], p_ + 1, q_ - p_ - 1)] = substr(tmp[i], q_ + 1) }
  na_ = split(NSLIST, tmp, " "); for (i = 1; i <= na_; i++) NSKNOWN[tmp[i]] = 1
}
{
  RANK = $1; CURLAYER = $2; AT = $3; SRC = $4; VER = $5; COPY = $6; REL = $7; NSP = ($8 == "-" ? "" : $8)
  parse(COPY "/" REL)
}
END {
  # The components: the literal component paths of the sections that apply to W.
  nc = 0
  for (j = 1; j <= NS; j++) {
    b = Scomp[j]
    if (Sexcl[j] || b == "" || wildcards(b) > 0) continue
    split(b, cp, "/")
    # 1.7.0: a namespaced layer's component is <kind>/<ns>:<name>
    c = (Sns[j] == "" ? b : cp[1] "/" Sns[j] ":" substr(b, length(cp[1]) + 2))
    if (c in SEEN) continue
    if (deepest(Sscope[j]) < 0) continue
    if (!(cp[1] in ACT)) { CURLAYER = Slayer[j]; problem(Sloc[j], "kind " cp[1] " is not in this release; [" Sraw[j] "] is not resolved"); SEEN[c] = 1; continue }
    if (b !~ /^[a-z]+\/[A-Za-z0-9_-][A-Za-z0-9._-]*$/) { CURLAYER = Slayer[j]; problem(Sloc[j], "a " cp[1] " component is " cp[1] "/<name>, one segment: [" Sraw[j] "]"); SEEN[c] = 1; continue }
    SEEN[c] = 1; COMP[++nc] = c; FIRSTJ[c] = j
  }
  # 1.7.0: a namespaced skill whose folder name (<ns>--<name>) is already an un-namespaced skill's
  # is not resolved: the Operator's own skill keeps the name.
  x = 0
  for (y = 1; y <= nc; y++) {
    c = COMP[y]
    if (cns(c) != "" && disk(c) != c && (disk(c) in SEEN)) {
      CURLAYER = Slayer[FIRSTJ[c]]
      problem(Sloc[FIRSTJ[c]], c " would be handed over as " substr(disk(c), 8) ", the name of the un-namespaced skill " disk(c) "; that one keeps it and " c " is not resolved")
      continue
    }
    COMP[++x] = c
  }
  nc = x
  # agents the participant asked for (1.6.0): resolved even when only a pattern names them
  na = split(AGENTNAMES, an, " ")
  for (x = 1; x <= na; x++) {
    p = index(an[x], ":"); c = "agents/" (p ? substr(an[x], 1, p - 1) : an[x])
    if (p) ACLI[c] = substr(an[x], p + 1)
    if (!(c in SEEN)) { SEEN[c] = 1; COMP[++nc] = c }
  }
  for (a = 2; a <= nc; a++) { t = COMP[a]; for (b = a - 1; b >= 1 && COMP[b] > t; b--) COMP[b + 1] = COMP[b]; COMP[b + 1] = t }
  for (y = 1; y <= nc; y++) INCOMP[COMP[y]] = 1
  for (x = 1; x <= nc; x++) resolve(COMP[x])
  # refs: each with its target: ok, missing (a missing dependency, 1.7.0) or dangling (malformed)
  printf "" > (META "/refs.tsv")
  # 1.7.0: the namespaced components and the names they are handed over by
  printf "" > (META "/namespaced.tsv")
  for (y = 1; y <= nc; y++) if (cns(COMP[y]) != "") print COMP[y] "\t" cns(COMP[y]) "\t" disk(COMP[y]) >> (META "/namespaced.tsv")
  close(META "/namespaced.tsv")
  for (x = 1; x <= nrefs; x++) {
    split(REFS[x], rf, SUBSEP)
    refparse(rf[3], cns(rf[1]), rf[4])
    st = "ok"; why = ""
    if (RT_WHY != "") { st = "dangling"; why = RT_WHY }
    else if (!(RT_KIND in ACT)) { st = "dangling"; why = "kind " RT_KIND " is not in this release" }
    else if (!(RT_COMP in INCOMP)) {
      st = "missing"; why = "no component " RT_COMP " for " WHO
      if (RT_NS != "" && !(RT_NS in NSKNOWN)) why = why "; no layer of the list has namespace " RT_NS
    }
    else if (RT_KEY != "" && !((RT_COMP, RT_KEY) in RK)) { st = "missing"; why = RT_COMP " has no key " RT_KEY }
    print rf[1] "\t" rf[2] "\t" tsv(rf[3]) "\t" tsv(RT_COMP) "\t" tsv(RT_KEY) "\t" st "\t" tsv(why) "\t" tsv(rf[4]) "\t" tsv(RT_ALIAS) >> (META "/refs.tsv")
  }
  close(META "/refs.tsv")
}
AWK

# ---------------------------------------------------------------- templates ----
# Vendor templates (1.11.0, ADR-0077): each vendor's files are rendered from Jinja templates by
# minijinja-cli; the merge above is unchanged. A template is a file templates/<vendor>/<file>.j2 at
# the root of a layer's copy (the built-in base layer ships templates/claude/SKILL.md.j2). It is a
# component of the kind template, templates/<vendor>/<file>.j2 (templates/<vendor>/<ns>:<file>.j2 in
# a namespaced layer), and it starts with a head, a Jinja comment:
#   {#- for: skill                                    skill: once per resolved skill; once: one file
#       output: skills/{{ skill.dir }}/SKILL.md        the path written, itself a template
#       lock: true -#}                                 optional: no higher layer replaces it
# Precedence is layer precedence (a layer's templates apply when its at is the who-you-are path or
# an ancestor of it): the highest layer's template wins whole and never stacks with the one below;
# the lowest layer that locks a template keeps it; a namespaced layer's templates compete only with
# its namespace's. A template changes one block of a lower one with {% extends "<layer>/<file>.j2" %}
# (the base: "component-registry/SKILL.md.j2"): each candidate is kept in the view at
# templates/<own|ns/<ns>>/<vendor>/<layer>/<file>.j2, beside a link to every lower layer of its
# group, so a template can extend only what is below it. resolve writes meta/templates.tsv (every
# candidate: state, component, namespace, vendor, file, layer, rank, version, source:path, for,
# output, lock, extends, why); a head that cannot be read is skipped and reported, as a line is.
# Rendering is the hand-over's (render_view): a template only writes files.

# TPL_HEAD: the head of one template file -> for, output, lock, extends, error ("-" for none)
read -r -d '' TPL_HEAD <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
{ ln[NR] = $0 }
END {
  f = ""; o = ""; lk = ""; ex = ""; err = ""; hend = 0
  if (NR == 0 || ln[1] !~ /^\{#/) err = "no head: a template starts with {#- for: skill  output: <path> -#}"
  else {
    for (i = 1; i <= NR; i++) if (index(ln[i], "#}")) { hend = i; break }
    if (!hend) err = "the head comment {# ... #} is not closed"
  }
  for (i = 1; !err && i <= hend; i++) {
    t = ln[i]
    if (i == 1) sub(/^\{#-?/, "", t)
    if (i == hend) sub(/-?#\}.*$/, "", t)
    t = trim(t)
    if (t !~ /^(for|output|lock):/) continue
    k = t; sub(/:.*$/, "", k); v = trim(substr(t, length(k) + 2))
    if (k in seen) { err = "'" k ":' appears twice in the head"; break }
    seen[k] = 1
    if (v ~ /\t/) { err = "a tab in " k ":"; break }
    if (k == "for") {
      if (v == "agent") { err = "for: agent is not supported: an agent definition does not become a CLI-native agent file (ADR-0077); for: skill or once"; break }
      if (v != "skill" && v != "once") { err = "for: is skill or once, not '" v "'"; break }
      f = v
    } else if (k == "output") {
      if (v == "") { err = "output: is empty"; break }
      o = v
    } else {
      if (v != "true" && v != "false") { err = "lock: is true or false, not '" v "'"; break }
      lk = v
    }
  }
  if (!err && f == "") err = "the head has no for: (skill or once)"
  if (!err && o == "") err = "the head has no output: (the path written)"
  for (i = hend + 1; !err && i <= NR; i++) {
    if (match(ln[i], /\{%-?[ \t]*extends[ \t]+["'][^"']+["']/)) {
      ex = substr(ln[i], RSTART, RLENGTH); sub(/^[^"']*["']/, "", ex); sub(/["']$/, "", ex); break
    }
  }
  printf "%s\t%s\t%s\t%s\t%s\n", (f == "" ? "-" : f), (o == "" ? "-" : o), (lk == "" ? "false" : lk), (ex == "" ? "-" : ex), (err == "" ? "-" : err)
}
AWK

# TPL_MERGE: the candidate rows (group, vendor, file, strength, rank, source, layer, version, loc,
# folder, for, output, lock, extends, error, applies), sorted, to the states of meta/templates.tsv
# plus the folder: used (the winner), overridden (replaced whole by it, or extended), skipped (a
# head error, or locked by a lower layer), not-applying (the layer's at is not W or an ancestor).
read -r -d '' TPL_MERGE <<'AWK'
BEGIN { FS = OFS = "\t" }
function flush(   i, h, w, why, base) {
  if (!n) return
  h = 0; w = 0
  for (i = 1; i <= n; i++) if (!h && A[i] == "yes" && E[i] == "-" && LK[i] == "true") h = i
  for (i = 1; i <= n; i++) {
    S[i] = "alive"; Y[i] = "-"
    if (A[i] != "yes") { S[i] = "not-applying"; Y[i] = "the layer is at " AT[i] ", not the who-you-are path or an ancestor of it"; continue }
    if (E[i] != "-") { S[i] = "skipped"; Y[i] = E[i]; continue }
    if (h && i > h) { S[i] = "skipped"; Y[i] = "locked by " L[h] " at " LOC[h]; continue }
    w = i
  }
  for (i = 1; i <= n; i++) {
    if (S[i] != "alive") continue
    if (i == w) { S[i] = "used"; Y[i] = (h == i ? "the winning template; locked for every higher layer" : "the winning template, the highest layer's") ; continue }
    S[i] = "overridden"; Y[i] = "replaced whole by " L[w] " at " LOC[w]
    base = X[w]; sub(/\/.*$/, "", base)
    if (X[w] != "-" && base == L[i]) Y[i] = "extended by " L[w] " at " LOC[w] " ({% extends \"" X[w] "\" %})"
  }
  for (i = 1; i <= n; i++)
    print S[i], (G == "-" ? "templates/" V "/" F : "templates/" V "/" G ":" F), G, V, F, L[i], R[i], VER[i], LOC[i], FOR[i], O[i], LK[i], X[i], Y[i], D[i]
  n = 0
}
{
  if ($1 != G || $2 != V || $3 != F) { flush(); G = $1; V = $2; F = $3 }
  n++; R[n] = $5; L[n] = $7; VER[n] = $8; LOC[n] = $9; D[n] = $10; FOR[n] = $11; O[n] = $12
  LK[n] = $13; X[n] = $14; E[n] = $15; A[n] = $16; AT[n] = $17
}
END { flush() }
AWK

tpl_applies() { [ "$1" = / ] || [ "$WHOAMI" = "$1" ] || [[ "$WHOAMI" == "$1"/* ]]; }

# resolve_templates <stage>: the template components of every layer copy read in this resolve (TSRC:
# rank, layer, at, source, version, folder, namespace) into <stage>/templates/ and
# <stage>/meta/templates.tsv. Sets TPL_SKIPPED.
resolve_templates() {
  local stage="$1" rec rank id at m ver dir ns rel vendor file head fr out lk ex err ap gdir
  local rows="$TMP/tpl.rows"
  TPL_SKIPPED=0
  : > "$rows"
  for rec in "${TSRC[@]+"${TSRC[@]}"}"; do
    IFS=$'\t' read -r rank id at m ver dir ns <<< "$rec"
    [ -d "$dir/templates" ] || continue
    ap=no; tpl_applies "$at" && ap=yes
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      vendor="${rel#templates/}"; file="${vendor#*/}"; vendor="${vendor%%/*}"
      err='-'
      if [ -L "$dir/$rel" ]; then err="a symlink is not read; put the template file itself in the layer"
      elif ! [[ "$rel" =~ ^templates/[a-z0-9][a-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9._-]*\.j2$ ]]; then
        warn "skipped template $id $m:$rel: a template is templates/<vendor>/<file>.j2 (a vendor of lower-case letters, digits and -; a file of letters, digits, . _ -)"
        TPL_SKIPPED=$((TPL_SKIPPED + 1)); continue
      elif [ "$(wc -c < "$dir/$rel")" -gt 262144 ]; then err="larger than 256 KiB"
      fi
      fr='-' out='-' lk=false ex='-'
      if [ "$err" = - ]; then
        head="$(LC_ALL=C awk "$TPL_HEAD" "$dir/$rel")"
        IFS=$'\t' read -r fr out lk ex err <<< "$head"
      fi
      printf '%s\t%s\t%s\t%010d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${ns:--}" "$vendor" "$file" "$((rank * 1000 + m))" "$rank" "$m" "$id" "$ver" "$m:$rel" "$dir/$rel" \
        "$fr" "$out" "$lk" "$ex" "$err" "$ap" "$at" >> "$rows"
    done < <(cd "$dir" && find templates -mindepth 1 -maxdepth 3 \( -type f -o -type l \) | LC_ALL=C sort)
  done
  printf 'state\tcomponent\tnamespace\tvendor\tfile\tlayer\trank\tversion\tsource\tfor\toutput\tlock\textends\twhy\n' > "$stage/meta/templates.tsv"
  [ -s "$rows" ] || return 0
  local st comp g v f lay rk vr loc fo o l x why src
  declare -A trank=()
  while IFS=$'\t' read -r st comp g v f lay rk vr loc fo o l x why src; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "$comp" "$g" "$v" "$f" "$lay" "$rk" "$vr" "$loc" "$fo" "$o" "$l" "$x" "$why" >> "$stage/meta/templates.tsv"
    case "$st" in
      skipped) TPL_SKIPPED=$((TPL_SKIPPED + 1)); warn "skipped template $lay $loc $comp: $why" ;;
      used | overridden)
        if [ "$g" = - ]; then gdir=own; else gdir="ns/$g"; fi
        mkdir -p "$stage/templates/$gdir/$v/$lay"
        cp "$src" "$stage/templates/$gdir/$v/$lay/$f"
        trank["$gdir/$v/$lay"]="$rk" ;;
    esac
  done < <(LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k3,3 -k4,4 "$rows" | awk "$TPL_MERGE")
  # each layer's folder links to the lower layers of its group: {% extends "<layer>/<file>.j2" %}
  local a b
  for a in "${!trank[@]}"; do
    for b in "${!trank[@]}"; do
      [ "${a%/*}" = "${b%/*}" ] && [ "${trank[$b]}" -lt "${trank[$a]}" ] || continue
      ln -s "../${b##*/}" "$stage/templates/$a/${b##*/}"
    done
  done
}

# mj <args>: minijinja-cli as the registry runs it: no config file, no MINIJINJA_* setting from
# the environment, no environment in the template, strict (an undefined name is an error), no
# escaping, no trailing newline added, a fuel limit (a runaway loop stops).
mj() {
  local -a unset_mj=()
  local x
  for x in $(compgen -e); do case "$x" in MINIJINJA_*) unset_mj+=(-u "$x") ;; esac; done
  env "${unset_mj[@]+"${unset_mj[@]}"}" minijinja-cli --config-file /dev/null --no-newline --strict \
    --autoescape none --fuel "${COMPONENT_REGISTRY_TEMPLATE_FUEL:-5000000}" "$@"
}

# js <string>: the string as a JSON string (bytes kept; control characters escaped)
js() {
  local LC_ALL=C s="$1" i c
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"
  if [[ "$s" == *[$'\x01'-$'\x1f']* ]]; then
    for ((i = 1; i < 32; i++)); do
      printf -v c '%b' "\\x$(printf '%02x' "$i")"
      s="${s//"$c"/$(printf '\\u%04x' "$i")}"
    done
  fi
  printf '"%s"' "$s"
}
# jfile <file>: the file's bytes as a JSON string ("" when there is none)
jfile() { local c=''; [ -f "$1" ] && { c="$(cat "$1"; printf x)"; c="${c%x}"; }; js "$c"; }

# skill_json <view> <dir> <name> <ns>: the skill object of the context
skill_json() {
  local view="$1" d="$2" name="$3" ns="$4" LC_ALL=C text='' fm='' body rest pre k t s first=1 f
  [ -f "$view/skills/$d/SKILL.md" ] && { text="$(cat "$view/skills/$d/SKILL.md"; printf x)"; text="${text%x}"; }
  body="$text"
  # front matter: the --- block and the blank lines after it, exactly as SKILL.md holds them, so
  # front_matter + body is SKILL.md byte for byte
  if [[ "$text" == $'---\n'* ]]; then
    rest="${text:4}"
    if [[ "$rest" == $'---\n'* ]]; then fm=$'---\n---\n'; body="${rest:4}"
    elif [[ "$rest" == *$'\n---\n'* ]]; then pre="${rest%%$'\n---\n'*}"; fm=$'---\n'"$pre"$'\n---\n'; body="${rest:$((${#pre} + 5))}"
    fi
    if [ -n "$fm" ]; then while [[ "$body" == $'\n'* ]]; do fm+=$'\n'; body="${body:1}"; done; fi
  fi
  printf '{"name":%s,"dir":%s,"namespace":%s,"has_skill_md":%s,"text":%s,"front_matter":%s,"body":%s,"values":{' \
    "$(js "$name")" "$(js "$d")" "$(js "$ns")" "$([ -f "$view/skills/$d/SKILL.md" ] && echo true || echo false)" \
    "$(js "$text")" "$(js "$fm")" "$(js "$body")"
  if [ -f "$view/meta/skills/$name/keys.tsv" ]; then
    while IFS=$'\t' read -r k t _; do
      [ -n "$k" ] && [ -f "$view/meta/skills/$name/values/$k" ] || continue
      [ "$first" = 1 ] || printf ','
      first=0
      if [ "$t" = list ]; then
        printf '%s:[' "$(js "$k")"; s=''
        while IFS= read -r f; do printf '%s%s' "$s" "$(js "$f")"; s=','; done < "$view/meta/skills/$name/values/$k"
        printf ']'
      else
        s="$(cat "$view/meta/skills/$name/values/$k"; printf x)"; s="${s%x}"; s="${s%$'\n'}"
        printf '%s:%s' "$(js "$k")" "$(js "$s")"
      fi
    done < "$view/meta/skills/$name/keys.tsv"
  fi
  printf '},"files":['
  s=''
  while IFS= read -r f; do [ -n "$f" ] && { printf '%s%s' "$s" "$(js "$f")"; s=','; }; done \
    < <(cd "$view/skills/$d" && find . -type f ! -path ./SKILL.md | sed 's|^\./||' | LC_ALL=C sort)
  printf ']}'
}

# render_view <vendor> <view folder> <out>: the vendor's winning templates rendered from the view
# into <out> (made anew). <out>/skills/<dir>/ starts with each skill's own files (from files =
# @dir), never its SKILL.md; then each template writes its output, once per skill (for: skill; a
# namespaced template only its namespace's skills, and only inside their folders) or once (for:
# once). An output that renders empty is not written. Returns 0 rendered (RENDER_NOTE says what),
# 4 the vendor has no template in the view (the hand-over gives the view's skills as they are), 1
# failed (RENDER_ERR names the template, its layer and file, and minijinja's message).
render_view() {
  local v="$1" view="$2" out="$3" rows st comp g f lay rk vr loc fo o l x why gdir tpl safe
  local d nm ns item ctx path n=0 nt=0 skills_json s msg
  RENDER_ERR='' RENDER_NOTE=''
  [ -f "$view/meta/templates.tsv" ] || return 4
  rows="$(awk -F'\t' -v v="$v" 'NR > 1 && $1 == "used" && $4 == v { print ($3 == "-" ? 0 : 1) "\t" $0 }' "$view/meta/templates.tsv" | LC_ALL=C sort -t $'\t' -k1,1 -k3,3 | cut -f2-)"
  [ -n "$rows" ] || return 4
  if ! command -v minijinja-cli >/dev/null 2>&1; then
    RENDER_ERR="minijinja-cli is not on PATH (component-registry 1.11.0 installs it; rebuild the container), so the $v templates cannot be rendered"
    return 1
  fi
  rm -rf "$out"; mkdir -p "$out/skills" || { RENDER_ERR="cannot create $out"; return 1; }
  ctx="$out.ctx"; mkdir -p "$ctx"
  # the skills: their folder, registry name and namespace
  local -a sd=() sn=() sns=()
  declare -A regname=()
  if [ -f "$view/meta/namespaced.tsv" ]; then
    while IFS=$'\t' read -r comp g d; do [[ "$comp" == skills/* ]] && regname["${d#skills/}"]="${comp#skills/}"; done < "$view/meta/namespaced.tsv"
  fi
  for d in "$view"/skills/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; d="${d##*/}"
    nm="${regname[$d]:-$d}" ns=''
    [ -n "${regname[$d]:-}" ] && ns="${nm%%:*}"
    sd+=("$d") sn+=("$nm") sns+=("$ns")
    mkdir -p "$out/skills/$d"
    cp -R "$view/skills/$d/." "$out/skills/$d/" && rm -f "$out/skills/$d/SKILL.md"
  done
  skills_json='['; s=''
  for ((n = 0; n < ${#sd[@]}; n++)); do skills_json+="$s{\"name\":$(js "${sn[n]}"),\"dir\":$(js "${sd[n]}"),\"namespace\":$(js "${sns[n]}")}"; s=','; done
  skills_json+=']'; n=0
  declare -A claimed=()
  while IFS=$'\t' read -r st comp g _ f lay rk vr loc fo o l x why; do
    if [ "$g" = - ]; then gdir=own; else gdir="ns/$g"; fi
    tpl="$view/templates/$gdir/$v/$lay/$f" safe="$view/templates/$gdir/$v"
    nt=$((nt + 1))
    local -a items=()
    if [ "$fo" = once ]; then items=(-1)
    else for ((s = 0; s < ${#sd[@]}; s++)); do { [ "$g" = - ] || [ "${sns[s]}" = "$g" ]; } && items+=("$s"); done
    fi
    for item in "${items[@]+"${items[@]}"}"; do
      {
        printf '{"vendor":%s,"whoami":%s,"template":{"component":%s,"layer":%s,"file":%s},"skills":%s' \
          "$(js "$v")" "$(js "$(cat "$view/whoami" 2>/dev/null)")" "$(js "$comp")" "$(js "$lay")" "$(js "$f")" "$skills_json"
        [ "$item" = -1 ] || printf ',"skill":%s' "$(skill_json "$view" "${sd[item]}" "${sn[item]}" "${sns[item]}")"
        printf '}'
      } > "$ctx/ctx.json"
      if ! path="$(mj --no-include --template "$o" '' "$ctx/ctx.json" 2>"$ctx/err")"; then
        RENDER_ERR="template $comp of layer $lay ($loc): its output: '$o' does not render: $(grep -m 1 . "$ctx/err")"; return 1
      fi
      if ! [[ "$path" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || [[ "/$path/" == */./* || "/$path/" == */../* ]] || [ "${#path}" -gt 255 ]; then
        RENDER_ERR="template $comp of layer $lay ($loc): output '$path' is not a relative path of letters, digits, . _ - (no . or .. segment)"; return 1
      fi
      if [ "$g" != - ] && [[ "$path" != "skills/$g--"*/* ]]; then
        warn "template $comp of layer $lay ($loc): a namespaced template writes only inside its namespace's skill folders (skills/$g--<name>/); $path not written"
        continue
      fi
      if [ -n "${claimed[$path]:-}" ]; then
        if [ "$g" = - ]; then RENDER_ERR="template $comp of layer $lay ($loc) and ${claimed[$path]} both write $path; one file has one template"; return 1; fi
        warn "template $comp of layer $lay ($loc): $path is written by ${claimed[$path]}, which a namespace never replaces; not written"
        continue
      fi
      if ! mj --safe-path "$safe" "$tpl" "$ctx/ctx.json" > "$ctx/out" 2>"$ctx/err"; then
        msg="$(grep -v '^[[:space:]]*$' "$ctx/err" | head -n 3 | tr '\n' ' ')"
        if [ "$item" = -1 ]; then x=''; else x=" for skill ${sd[item]}"; fi
        RENDER_ERR="template $comp of layer $lay ($loc) does not render$x: ${msg% }"; return 1
      fi
      claimed[$path]="$comp of layer $lay"
      [ -s "$ctx/out" ] || continue
      if ! { mkdir -p "$out/$(dirname "$path")" && mv "$ctx/out" "$out/$path"; }; then RENDER_ERR="cannot write $out/$path"; return 1; fi
      n=$((n + 1))
    done
  done <<< "$rows"
  rm -rf "$ctx"
  RENDER_NOTE="$n file(s) rendered from $nt template(s)"
  return 0
}

# --------------------------------------------------------------------- verbs ----
cmd_resolve() {
  local as='' n m k kind dir v rc failed=0 stamp stage keep id f line c layer loc key why st out
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) [ $# -ge 2 ] || die 2 "--as needs a path"; as="$2"; shift 2 ;;
      --as=*) as="${1#--as=}"; shift ;;
      *) die 2 "resolve: unknown argument '$1' (resolve [--as <path>])" ;;
    esac
  done
  resolve_settings
  resolve_whoami "$as"
  load_list
  for ((n = 1; n <= NL; n++)); do
    [ "${L_WR[n]:-false}" = true ] && warn "layer ${L_ID[n]}: writable is ignored since 2.0.0: the registry does not write layers; edit the layer"
  done
  mkdir -p "$STATE_DIR" 2>/dev/null || die 1 "cannot create the state folder $STATE_DIR (run component-registry-setup)"
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  [ -w "$STATE_DIR" ] || die 1 "the state folder $STATE_DIR is not writable by $(id -un) (run component-registry-setup)"
  command -v flock >/dev/null 2>&1 || die 1 "flock (util-linux) is needed to serialise resolve runs"
  exec 9>"$STATE_DIR/resolve.lock"
  flock -w "${COMPONENT_REGISTRY_LOCK_WAIT:-120}" 9 || die 1 "another resolve has held $STATE_DIR/resolve.lock for ${COMPONENT_REGISTRY_LOCK_WAIT:-120}s; try again"
  TMP="$(mktemp -d "$STATE_DIR/tmp.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$STATE_DIR/copies" "$STATE_DIR/views"

  say "resolving for $WHOAMI (from $WHOAMI_SOURCE), layers in $RF"
  stamp="$(date -u +%Y%m%dT%H%M%SZ).$$"
  stage="$STATE_DIR/views/$stamp"
  mkdir -p "$stage/meta" "$stage/skills"
  : > "$TMP/manifest"
  printf 'rank\tlayer\tat\tsource\tkind\tversion\tstate\tfetched\tnote\tnamespace\taliases\n' > "$stage/layers.tsv"
  # The built-in base layer first (rank 0): the utility skills, read where the Feature installed
  # them, never fetched.
  TSRC=()
  if [ -d "$BASE_DIR" ]; then
    v="$(cat "$SHARE_DIR/version" 2>/dev/null || echo unknown)"
    TSRC+=("0"$'\t'"$BASE_ID"$'\t'"/"$'\t'"1"$'\t'"$v"$'\t'"$BASE_DIR"$'\t'"-")
    printf '0\t%s\t/\t1\tbuiltin\t%s\tbuiltin\t-\tthe Feature'"'"'s utility skills, %s\t-\t-\n' "$BASE_ID" "$v" "$BASE_DIR" >> "$stage/layers.tsv"
    while IFS= read -r f; do
      [ -n "$f" ] && printf '0\t%s\t/\t1\t%s\t%s\t%s\t-\n' "$BASE_ID" "$v" "$BASE_DIR" "$f" >> "$TMP/manifest"
    done < <(cd "$BASE_DIR" && find . -maxdepth 1 -type f -name '*.layer' | sed 's|^\./||' | LC_ALL=C sort)
  fi
  for ((n = 1; n <= NL; n++)); do
    id="${L_ID[n]}"
    for ((m = 1; m <= L_NSRC[n]; m++)); do
      k="$n.$m"; kind="${S_KIND[$k]}"
      fetch_source "$n" "$m"
      dir="$STATE_DIR/copies/$id/$m"
      case "$SRC_STATE" in
        fetched) say "layer $id source $m ($kind): fetched $SRC_VER" ;;
        unchanged) say "layer $id source $m ($kind): unchanged at $SRC_VER" ;;
        offline) warn "layer $id source $m ($kind): unreachable, using the last good copy ($SRC_VER, fetched $SRC_AT): $SRC_NOTE" ;;
        missing)
          if [ "${S_REQ[$k]}" = true ]; then
            warn "layer $id source $m ($kind) is required and has never been fetched: $SRC_NOTE"; failed=1
          else
            warn "layer $id source $m ($kind): not read, no copy yet: $SRC_NOTE"
          fi ;;
      esac
      v="${L_AL[n]:-}"; v="${v% }"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$id" "${L_AT[n]}" "$m" "$kind" "${SRC_VER:--}" "$SRC_STATE" "${SRC_AT:--}" "${SRC_NOTE:--}" "${L_NS[n]:--}" "${v:--}" | tr -d '\r' >> "$stage/layers.tsv"
      [ "$SRC_STATE" = missing ] && continue
      TSRC+=("$n"$'\t'"$id"$'\t'"${L_AT[n]}"$'\t'"$m"$'\t'"$SRC_VER"$'\t'"$dir"$'\t'"${L_NS[n]:--}")
      oldreg=''
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$id" "${L_AT[n]}" "$m" "$SRC_VER" "$dir" "$f" "${L_NS[n]:--}" >> "$TMP/manifest"
      done < <(cd "$dir" && find . -maxdepth 1 -type f -name '*.layer' | sed 's|^\./||' | LC_ALL=C sort)
      while IFS= read -r f; do [ -n "$f" ] && oldreg="${oldreg:+$oldreg, }$f"; done < <(cd "$dir" && find . -maxdepth 1 -type f -name '*.reg' | sed 's|^\./||' | LC_ALL=C sort)
      [ -z "$oldreg" ] || warn "layer $id source $m: not read since 2.0.0: $oldreg; rename to .layer"
    done
  done
  if [ "$failed" -ne 0 ]; then
    rm -rf "$stage"
    die 1 "a required layer was never fetched; the resolved view was left as it was"
  fi

  # Copies no layer still names go (a layer removed from the list, or a source dropped).
  for dir in "$STATE_DIR"/copies/*; do
    [ -d "$dir" ] || continue
    id="$(basename "$dir")" keep=0
    for ((n = 1; n <= NL; n++)); do [ "${L_ID[n]}" = "$id" ] && keep="$n"; done
    if [ "$keep" -eq 0 ]; then rm -rf "$dir"; say "removed the copy of layer $id (no longer in the list)"; continue; fi
    for f in "$dir"/*; do
      v="$(basename "$f")"; v="${v%.meta}"; v="${v%%.new.*}"
      [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -le "${L_NSRC[keep]}" ] && [[ "$f" != *.new.* ]] || rm -rf "$f"
    done
  done

  printf '%s\n' "$WHOAMI" > "$stage/whoami"
  # The agents whose definitions are resolved even when only a pattern names them (1.6.0):
  # COMPONENT_REGISTRY_AGENTS (the participant's listed agents), else the current view's names, so
  # a refresh keeps them. A name that is not a handle is left out, said once.
  local names='' nm
  if [ -n "${COMPONENT_REGISTRY_AGENTS+x}" ]; then names="${COMPONENT_REGISTRY_AGENTS//,/ }"
  elif [ -f "$STATE_DIR/view/agent-names" ]; then names="$(tr '\n' ' ' < "$STATE_DIR/view/agent-names")"
  fi
  : > "$stage/agent-names"
  for nm in $names; do
    if [[ "$nm" =~ ^[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)?$ ]]; then grep -q -- "^${nm%%:*}\(:\|\$\)" "$stage/agent-names" || printf '%s\n' "$nm" >> "$stage/agent-names"
    else warn "COMPONENT_REGISTRY_AGENTS: '$nm' is not an agent name, or name:cli (letters, digits, - and _); left out"; fi
  done
  date -u +%Y-%m-%dT%H:%M:%SZ > "$stage/resolved"
  # The layers that stack their text without a heading (heading: false), space-separated.
  nohead=' '; for ((n = 1; n <= NL; n++)); do [ "${L_HD[n]:-true}" = false ] && nohead+="${L_ID[n]} "; done
  # 1.7.0: each layer's aliases as <layer>:<alias>=<namespace>, and the namespaces of the list
  local aliases='' nslist='' al
  for ((n = 1; n <= NL; n++)); do
    for al in ${L_AL[n]:-}; do aliases+="${L_ID[n]}:$al "; done
    [ -z "${L_NS[n]:-}" ] || nslist+="${L_NS[n]} "
  done
  out="$(awk -v WHO="$WHOAMI" -v KINDLIST="$KINDS" -v ACTIVE="$ACTIVE_KINDS" -v META="$stage/meta" -v VIEW="$stage" -v NOHEAD="$nohead" -v ALIASES="$aliases" -v NSLIST="$nslist" \
    -v AGENTNAMES="$(tr '\n' ' ' < "$stage/agent-names")" "$RESOLVER" "$TMP/manifest")"; rc=$?
  [ "$rc" -eq 0 ] || { rm -rf "$stage"; die 1 "the merge failed (awk exit $rc); the resolved view was left as it was"; }
  local nres=0 nskip=0 nprob=0
  while IFS=$'\t' read -r line c layer loc key why; do
    case "$line" in
      C) mkdir -p "$stage/$c"; cp -R "$layer/." "$stage/$c/" ;;
      # N <component> <where it lands in the view>: a namespaced skill as skills/<ns>--<name> (1.7.0)
      N) nres=$((nres + 1)); mkdir -p "$stage/$layer"
         [ -f "$stage/meta/$c/body.md" ] && cp "$stage/meta/$c/body.md" "$stage/$layer/SKILL.md" ;;
      R) nskip=$((nskip + 1)); warn "skipped $layer $loc $c:$key: $why" ;;
      Q) nprob=$((nprob + 1)); warn "skipped $c $layer: $loc" ;;
    esac
  done <<< "$out"
  local nmiss=0 rlay note
  while IFS=$'\t' read -r c key v loc line st why rlay note; do
    [ "$note" != - ] || note=''
    case "$st" in
      dangling) warn "dangling ref: $c:$key -> $v ($why)" ;;
      # 1.7.0: a missing dependency, like a chart's: said, never fatal; installing it is the user's
      missing) nmiss=$((nmiss + 1)); warn "missing dependency: $c:$key in layer ${rlay:--} -> $v${note:+ [$note]} ($why)" ;;
    esac
  done < "$stage/meta/refs.tsv"
  # 1.11.0 (ADR-0077): the template components, kept in the view with their provenance
  resolve_templates "$stage"
  nskip=$((nskip + TPL_SKIPPED))

  # Swap in: `view` is a symlink replaced in one rename, so a reader sees the old or the new.
  ln -s "views/$stamp" "$STATE_DIR/view.new.$$"
  mv -Tf "$STATE_DIR/view.new.$$" "$STATE_DIR/view"
  # (1.8.0) the same for this path's own pointer, so an agent of another path keeps its view
  mkdir -p "$STATE_DIR/paths"
  ln -s "../views/$stamp" "$STATE_DIR/paths/$(path_key "$WHOAMI").new.$$"
  mv -Tf "$STATE_DIR/paths/$(path_key "$WHOAMI").new.$$" "$STATE_DIR/paths/$(path_key "$WHOAMI")"
  prune_views
  say "resolved $nres component(s) for $WHOAMI into $STATE_DIR/view ($nskip line(s) skipped, $nprob unreadable; $nmiss missing dependenc$([ "$nmiss" -eq 1 ] && echo y || echo ies); dcf-registry explain <path> says why)"
}

# view_path: the current view or die
view_path() {
  VIEW="$STATE_DIR/view"
  [ -f "$VIEW/whoami" ] || die 1 "no resolved view in $STATE_DIR yet; run dcf-registry resolve (task component-registry:resolve)"
}

# path_key <path> (1.8.0): the file name of a who-you-are path's pointer under paths/ (/ becomes +;
# a path holds letters, digits, . _ - and /, so the key is one file name and never collides)
path_key() { printf '%s' "${1//\//+}"; }

# prune_views [--pointers] (1.8.0, under the resolve lock held exclusive): every view that neither
# `view` nor a path pointer names goes. With --pointers (forget), first the pointers of paths no
# hand-over record names, but the latest view's; a resolve never drops a pointer, so a path resolved
# for an agent that has not been handed its skills yet keeps its view.
prune_views() {
  local p k t d
  declare -A keep=() inuse=()
  t="$(cat "$STATE_DIR/view/whoami" 2>/dev/null)" && keep["$(path_key "$t")"]=1
  if [ "${1:-}" != --pointers ]; then for d in "$STATE_DIR"/paths/*; do keep["$(basename "$d")"]=1; done; fi
  if [ -f "$STATE_DIR/handovers.tsv" ]; then
    while IFS=$'\t' read -r _ _ _ p _; do [ -n "$p" ] && keep["$(path_key "$p")"]=1; done < "$STATE_DIR/handovers.tsv"
  fi
  for d in "$STATE_DIR"/paths/*; do
    [ -L "$d" ] || { [ -e "$d" ] && rm -rf "$d"; continue; }
    k="$(basename "$d")"
    if [ -z "${keep[$k]:-}" ]; then rm -f "$d"; continue; fi
    t="$(readlink "$d")"; inuse["${t##*/}"]=1
  done
  t="$(readlink "$STATE_DIR/view" 2>/dev/null)" && inuse["${t##*/}"]=1
  for d in "$STATE_DIR"/views/*; do
    [ -d "$d" ] || continue
    [ -n "${inuse[$(basename "$d")]:-}" ] || rm -rf "$d"
  done
}

# view_for [<path>] (1.8.0): VIEW, the view to read, and VPATH and VMODE, what a hand-over records.
# A path given: that path's own view (or die). None: the view of the who-you-are setting when it has
# one, else the latest view.
view_for() {
  local as="${1:-}" s
  if [ -n "$as" ]; then
    as="${as%/}"; [ -n "$as" ] || as=/
    valid_path "$as" || die 2 "'$as' is not a who-you-are path (absolute, segments of letters, digits, . _ and -)"
    VIEW="$STATE_DIR/paths/$(path_key "$as")" VMODE=as
    [ -f "$VIEW/whoami" ] || die 1 "no view resolved for $as yet; run dcf-registry resolve --as $as"
  else
    VMODE=whoami VIEW="$STATE_DIR/view"
    s="$(setting COMPONENT_REGISTRY_WHOAMI)"
    if [ -n "$s" ]; then
      s="${s%%$'\t'*}"; s="${s%/}"; [ -n "$s" ] || s=/
      valid_path "$s" && [ -f "$STATE_DIR/paths/$(path_key "$s")/whoami" ] && VIEW="$STATE_DIR/paths/$(path_key "$s")"
    fi
    [ -f "$VIEW/whoami" ] || die 1 "no resolved view in $STATE_DIR yet; run dcf-registry resolve (task component-registry:resolve)"
  fi
  VPATH="$(cat "$VIEW/whoami")"
}

# record_handover <cli> <name> <folder> <path> <mode> [<skills mode>] | forget: one line per cli,
# name and folder
record_handover() {
  local cli="$1" name="$2" folder="$3" path="${4:-}" mode="${5:-}" smode="${6:-split}" f="$STATE_DIR/handovers.tsv"
  exec 6>>"$STATE_DIR/handovers.lock"
  flock -w 30 6 || { warn "the hand-over records are busy ($STATE_DIR/handovers.lock); not recorded"; exec 6>&-; return 0; }
  (umask 077
   { [ -f "$f" ] && awk -F'\t' -v c="$cli" -v n="$name" -v d="$folder" '!($1 == c && $2 == n && $3 == d)' "$f"
     [ "$mode" = forget ] || printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cli" "$name" "$folder" "$path" "$mode" "$smode"
   } > "$f.new.$$" && mv -f "$f.new.$$" "$f")
  exec 6>&-
}

# normalise <path>: [scope/]kind/[ns:]name[:key] -> NP_COMP, NP_KEY. The name may be a namespaced
# one (1.7.0): kind/ns:name:key is plain; kind/a:b is the namespaced component a:b when the view
# (VIEW) holds one or a ref names it (a missing dependency), else the key b of a; a skill's folder
# name ns--name is taken for ns:name too.
normalise() {
  local s="$1" k found='' seg comp='' last pre
  local -a parts
  NP_KEY=''
  s="${s#/}"
  IFS=/ read -r -a segs <<< "$s"
  for seg in "${segs[@]}"; do
    if [ -z "$found" ]; then for k in $KINDS; do [ "${seg%%:*}" = "$k" ] && found=1; done; fi
    [ -n "$found" ] && comp="${comp:+$comp/}$seg"
  done
  case "$comp" in */*) pre="${comp%/*}/" last="${comp##*/}" ;; *) pre='' last="$comp" ;; esac
  IFS=: read -r -a parts <<< "$last"
  case "${#parts[@]}" in
    2) if [ -n "${VIEW:-}" ] && { [ -d "$VIEW/meta/$pre$last" ] || awk -F'\t' -v c="$pre$last" '$4 == c { f = 1; exit } END { exit !f }' "$VIEW/meta/refs.tsv" 2>/dev/null; }; then :
       else last="${parts[0]}" NP_KEY="${parts[1]}"; fi ;;
    3) last="${parts[0]}:${parts[1]}" NP_KEY="${parts[2]}" ;;
    0 | 1) ;;
    *) last="${parts[0]}:${parts[1]}" NP_KEY="${last#*:*:}" ;;
  esac
  if [[ "$last" == *--* && "$last" != *:* ]] && [ -n "${VIEW:-}" ] && [ ! -d "$VIEW/meta/$pre$last" ] && [ -d "$VIEW/meta/$pre${last%%--*}:${last#*--}" ]; then
    last="${last%%--*}:${last#*--}"
  fi
  NP_COMP="$pre$last"
}

# Colour for explain (1.4.0): six colours of the Okabe-Ito set (distinguishable with the usual
# colour-vision deficiencies; never red against green alone), one per layer in layer order, wrapping
# after six. The layer id is on every line already, so colour is never the only signal. Skipped
# lines and dangling refs are dim and struck through. Colour off prints exactly the 1.3.0 text.
EX_PALETTE=('38;5;208' '38;5;74' '38;5;36' '38;5;220' '38;5;33' '38;5;175')
EX_NAMES=(orange sky-blue teal yellow blue purple)
declare -A EX_LAYER_COLOUR=()
EX_COLOUR=0
# paint <sgr> <text>: the text in that style when colour is on.
paint() { if [ "$EX_COLOUR" -eq 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
# lcolour <layer id>: the SGR code of a layer's colour (none for an unknown id, such as a lock's).
lcolour() { printf '%s' "${EX_LAYER_COLOUR[$1]:-}"; }
# pline <sgr> <text>: a whole line, painted.
pline() { if [ -n "$1" ]; then paint "$1" "$2"; printf '\n'; else printf '%s\n' "$2"; fi; }

# explain_templates <path> (1.11.0, ADR-0077): read-only. templates (or templates/<vendor>) lists
# each template component and the layer whose template wins; templates/<vendor>/[<ns>:]<file>.j2
# shows every candidate, lowest first, the winner and the base it extends.
explain_templates() {
  local p="${1#/}" who="$2" st comp g v f lay rk vr loc fo o l x why i=0 n id s w='' sgr
  p="${p%/}"
  [ -f "$VIEW/meta/templates.tsv" ] || die 1 "the view resolved for $who holds no templates (resolved before component-registry 1.11.0); run dcf-registry resolve"
  if [[ "$p" != templates/*/* ]]; then
    printf 'Templates (ADR-0077), resolved for %s at %s; the winner of each:\n' "$who" "$(cat "$VIEW/resolved")"
    s="$(awk -F'\t' -v v="${p#templates}" 'NR > 1 && $1 == "used" && (v == "" || "/" $4 == v) { printf "  %s  %s (%s)  for: %s, output: %s%s%s\n", $2, $6, $9, $10, $11, ($12 == "true" ? ", locked" : ""), ($13 != "-" ? ", extends " $13 : "") }' "$VIEW/meta/templates.tsv")"
    if [ -n "$s" ]; then printf '%s\n' "$s"; else echo "  none"; fi
    return 0
  fi
  awk -F'\t' -v c="$p" 'NR > 1 && $2 == c { f = 1 } END { exit !f }' "$VIEW/meta/templates.tsv" ||
    die 1 "no template $p in the view resolved for $who (dcf-registry explain templates lists them; a template is templates/<vendor>/<file>.j2 in a layer)"
  if [ "$EX_COLOUR" -eq 1 ]; then
    while IFS=$'\t' read -r n id _; do EX_LAYER_COLOUR[$id]="${EX_PALETTE[$((i % 6))]}"; i=$((i + 1)); done < <(awk -F'\t' 'NR > 1 { print $1 "\t" $2 }' "$VIEW/layers.tsv")
  fi
  printf '%s, resolved for %s at %s\n' "$p" "$who" "$(cat "$VIEW/resolved")"
  case "${p##*/}" in *:*) s="${p##*/}"; s="${s%%:*}"; printf 'Namespace %s: only the layers with namespace: %s reach it; it renders that namespace'"'"'s skills only, inside their folders.\n' "$s" "$s" ;; esac
  echo "Candidates (lowest first; the highest wins whole, a lock in a lower layer holds):"
  while IFS=$'\t' read -r st comp g v f lay rk vr loc fo o l x why; do
    [ "$comp" = "$p" ] || continue
    printf -v s '  %-12s %s@%s %s  for: %s, output: %s%s%s  (%s)' "$st" "$lay" "$vr" "$loc" "$fo" "$o" "$([ "$l" = true ] && echo ', lock: true')" "$([ "$x" != - ] && echo ", extends $x")" "$why"
    case "$st" in used) sgr="$(lcolour "$lay")" ;; *) sgr="$([ "$EX_COLOUR" -eq 1 ] && echo '2;9')" ;; esac
    pline "$sgr" "$s"
    [ "$st" = used ] && w="$lay"$'\t'"$loc"$'\t'"$x"$'\t'"$l"
  done < "$VIEW/meta/templates.tsv"
  if [ -z "$w" ]; then echo "No winner: no candidate could be used; a hand-over renders nothing for it."; return 0; fi
  IFS=$'\t' read -r lay loc x l <<< "$w"
  printf 'Winner: %s (%s)%s' "$lay" "$loc" "$([ "$l" = true ] && echo ', locked for every higher layer')"
  if [ "$x" != - ]; then printf '; extends %s, the template of layer %s\n' "$x" "${x%%/*}"; else printf '; extends nothing (it replaces the templates below it whole)\n'; fi
  return 0
}

# render <vendor> <folder> [--as <path>] (1.11.0, ADR-0077): what a hand-over to that vendor's CLI
# would get, rendered into a new folder, read-only for the view; to preview a template.
cmd_render() {
  local as='' real
  local -a pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) [ $# -ge 2 ] || die 2 "--as needs a path"; as="$2"; shift 2 ;;
      --as=*) as="${1#--as=}"; shift ;;
      -*) die 2 "render: unknown option '$1' (render <vendor> <folder> [--as <path>])" ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  [ "${#pos[@]}" -eq 2 ] || die 2 "render needs a vendor and a folder: dcf-registry render <vendor> <folder> [--as <path>]"
  [[ "${pos[0]}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die 2 "render: '${pos[0]}' is not a vendor name (lower-case letters, digits and -)"
  if [ -e "${pos[1]}" ] && [ -n "$(ls -A "${pos[1]}" 2>/dev/null)" ]; then die 2 "render: ${pos[1]} is not empty; name a new folder"; fi
  resolve_settings
  [ -d "$STATE_DIR" ] || die 1 "no state folder $STATE_DIR; run dcf-registry resolve first"
  command -v flock >/dev/null 2>&1 || die 1 "flock (util-linux) is needed to read the view while no resolve swaps it"
  exec 8>>"$STATE_DIR/resolve.lock"
  flock -s -w "${COMPONENT_REGISTRY_LOCK_WAIT:-120}" 8 || die 1 "a resolve has held $STATE_DIR/resolve.lock for ${COMPONENT_REGISTRY_LOCK_WAIT:-120}s; try again"
  view_for "$as"
  real="$(readlink -f "$VIEW")"
  render_view "${pos[0]}" "$real" "${pos[1]}"
  case $? in
    0) say "${pos[0]}: $RENDER_NOTE into ${pos[1]}, for $VPATH" ;;
    4) say "${pos[0]}: no template in the view resolved for $VPATH; a hand-over gives that CLI the view's skills as they are"; return 3 ;;
    *) rm -rf "${pos[1]}.ctx"; die 1 "${pos[0]}: $RENDER_ERR" ;;
  esac
}

cmd_explain() {
  local path='' uses=0 as='' color=auto who st key type layer ver loc data why k t s i n id sgr
  while [ $# -gt 0 ]; do
    case "$1" in
      --uses) uses=1; shift ;;
      --as) [ $# -ge 2 ] || die 2 "--as needs a path"; as="$2"; shift 2 ;;
      --color) [ $# -ge 2 ] || die 2 "--color needs auto, always or never"; color="$2"; shift 2 ;;
      --color=*) color="${1#--color=}"; shift ;;
      -*) die 2 "explain: unknown option '$1' (explain <path> [--uses] [--color auto|always|never])" ;;
      *) [ -z "$path" ] || die 2 "explain takes one path"; path="$1"; shift ;;
    esac
  done
  [ -n "$path" ] || die 2 "explain needs a path: dcf-registry explain skills/<name>[:key] [--uses]"
  case "$color" in
    always) EX_COLOUR=1 ;;
    never) EX_COLOUR=0 ;;
    auto) if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then EX_COLOUR=1; else EX_COLOUR=0; fi ;;
    *) die 2 "--color takes auto, always or never, not '$color'" ;;
  esac
  view_path
  who="$(cat "$VIEW/whoami")"
  if [ -n "$as" ] && [ "${as%/}" != "$who" ]; then
    # (1.8.0) that path's own view, when one was resolved
    if valid_path "${as%/}" && [ -f "$STATE_DIR/paths/$(path_key "${as%/}")/whoami" ]; then
      VIEW="$STATE_DIR/paths/$(path_key "${as%/}")"; who="$(cat "$VIEW/whoami")"
    else
      die 1 "no view is resolved for $as (the latest is for $who); run dcf-registry resolve --as $as first (explain never resolves)"
    fi
  fi
  case "${path#/}" in templates | templates/*) explain_templates "$path" "$who"; return $? ;; esac
  normalise "$path"
  [ -n "$NP_COMP" ] || die 2 "'$path' names no component (a path with a ${KINDS// /, } segment, like skills/diagrams)"
  if [ "$uses" -eq 1 ]; then
    printf 'What refers to %s%s (resolved for %s):\n' "$NP_COMP" "${NP_KEY:+:$NP_KEY}" "$who"
    # 1.7.0: the resolved target when a namespace or an alias is involved, and a missing dependency
    s="$(awk -F'\t' -v c="$NP_COMP" -v k="$NP_KEY" 'function ns(x,  n) { n = x; sub(/^[^\/]*\//, "", n); return index(n, ":") ? " [namespace " substr(n, 1, index(n, ":") - 1) "]" : "" }
      $4 == c && (k == "" || $5 == k) { printf "  %s:%s -> %s%s (%s)%s%s\n", $1, $2, $3, (ns($1) != "" || ns($4) != "" || ($9 != "" && $9 != "-") ? " = " $4 : ""), ($6 == "missing" ? "missing dependency" : $6), ($9 != "" && $9 != "-" ? " [" $9 "]" : ""), ns($1) }' "$VIEW/meta/refs.tsv")"
    if [ -n "$s" ]; then printf '%s\n' "$s"; else echo "  nothing"; fi
    return 0
  fi
  [ -f "$VIEW/meta/$NP_COMP/provenance.tsv" ] || die 1 "no component $NP_COMP in the view resolved for $who (dcf-registry resolve, or check the path)"
  # 1.7.0: a namespaced component says its namespace on every line of its own
  local ns='' nsl='' disk
  case "${NP_COMP#*/}" in *:*) ns="${NP_COMP#*/}"; ns="${ns%%:*}"; nsl=" [namespace $ns]" ;; esac
  if [ -n "$ns" ]; then
    disk="$(awk -F'\t' -v c="$NP_COMP" '$1 == c { print $3; exit }' "$VIEW/meta/namespaced.tsv" 2>/dev/null)"
    printf '%s, resolved for %s at %s\n' "$NP_COMP" "$who" "$(cat "$VIEW/resolved")"
    printf 'Namespace %s: only the layers with namespace: %s reach it%s.\n' "$ns" "$ns" "$([ "$disk" != "$NP_COMP" ] && [ -n "$disk" ] && printf '; handed over as %s' "${disk#*/}")"
  else
    printf '%s, resolved for %s at %s\n' "$NP_COMP" "$who" "$(cat "$VIEW/resolved")"
  fi
  if [ "$EX_COLOUR" -eq 1 ]; then
    i=0
    while IFS=$'\t' read -r n id _; do
      EX_LAYER_COLOUR[$id]="${EX_PALETTE[$((i % 6))]}"
      i=$((i + 1))
    done < <(awk -F'\t' 'NR > 1 { print $1 "\t" $2 }' "$VIEW/layers.tsv")
    printf 'Colour by layer:'
    i=0
    while IFS=$'\t' read -r n id _; do
      printf ' '; paint "${EX_PALETTE[$((i % 6))]}" "[$id = ${EX_NAMES[$((i % 6))]}]"
      i=$((i + 1))
    done < <(awk -F'\t' 'NR > 1 { print $1 "\t" $2 }' "$VIEW/layers.tsv")
    printf '; skipped lines and dangling refs are dim and struck through\n'
  fi
  echo "Layers (lowest first):"
  while IFS= read -r s; do
    id="$(printf '%s' "$s" | awk '{ print $2 }')"
    pline "$(lcolour "$id")" "$s"
  done < <(awk -F'\t' 'NR > 1 { printf "  %s %s at %s, source %s (%s): %s, %s%s%s%s\n", $1, $2, $3, $4, $5, $7, $6, ($7 == "offline" ? ", the last good copy from " $8 : ""), ($10 != "" && $10 != "-" ? ", namespace " $10 : ""), ($11 != "" && $11 != "-" ? ", aliases " $11 : "") }' "$VIEW/layers.tsv")
  while IFS=$'\t' read -r k t s; do
    [ -n "$NP_KEY" ] && [ "$k" != "$NP_KEY" ] && continue
    printf '\n%s:%s = %s%s\n' "$k" "$t" "$s" "$nsl"
    while IFS=$'\t' read -r st key type layer _ ver loc data why; do
      [ "$key" = "$k" ] || continue
      [ "$why" != - ] || why=''
      if [ "$type" = lock ]; then s="lock $key"; else s="$key:$type = $data"; fi
      printf -v s '  %-12s %s@%s%s %s  %s%s' "$st" "$layer" "$ver" "$nsl" "$loc" "$s" "${why:+  ($why)}"
      case "$st" in used) sgr="$(lcolour "$layer")" ;; *) sgr='2;9' ;; esac
      pline "$sgr" "$s"
    done < "$VIEW/meta/$NP_COMP/provenance.tsv"
  done < "$VIEW/meta/$NP_COMP/keys.tsv"
  # Lines that did not make a key: skipped, dropped, excluded, not applying, locks.
  s="$(awk -F'\t' -v k="$NP_KEY" -v nsl="$nsl" 'FILENAME == ARGV[1] { has[$1] = 1; next } (k == "" || $2 == k) && !($2 in has) { printf "  %-12s %s@%s%s %s  %s  (%s)\n", $1, $4, $6, nsl, $7, ($3 == "lock" ? "lock " $2 : $2 ":" $3 " = " $8), $9 }' "$VIEW/meta/$NP_COMP/keys.tsv" "$VIEW/meta/$NP_COMP/provenance.tsv")"
  if [ -n "$s" ]; then
    printf '\nOther lines:\n'
    while IFS= read -r t; do pline "$([ "$EX_COLOUR" -eq 1 ] && echo '2;9')" "$t"; done <<< "$s"
  fi
  # 1.7.0: every reference of the component, as written and as resolved (an alias said); then the
  # missing dependencies (a target not in the view: the user installs it) and the malformed ones
  s="$(awk -F'\t' -v c="$NP_COMP" -v k="$NP_KEY" -v nsl="$nsl" '$1 == c && (k == "" || $2 == k) { printf "  %s:%s -> %s = %s%s (%s)%s%s\n", $1, $2, $3, $4, ($5 != "-" ? ":" $5 : ""), ($6 == "missing" ? "missing dependency" : $6), ($9 != "" && $9 != "-" ? " [" $9 "]" : ""), nsl }' "$VIEW/meta/refs.tsv")"
  [ -z "$s" ] || printf '\nReferences (1.7.0: no prefix is the own namespace, <ns>:<name> namespace <ns>):\n%s\n' "$s"
  s="$(awk -F'\t' -v c="$NP_COMP" -v k="$NP_KEY" -v nsl="$nsl" '$1 == c && $6 == "missing" && (k == "" || $2 == k) { printf "  %s:%s -> %s%s (%s)%s, in layer %s\n", $1, $2, $3, nsl, $7, ($9 != "" && $9 != "-" ? " [" $9 "]" : ""), $8 }' "$VIEW/meta/refs.tsv")"
  if [ -n "$s" ]; then
    printf '\nMissing dependencies (resolve goes on without them; add the layer that brings them):\n'
    while IFS= read -r t; do pline "$([ "$EX_COLOUR" -eq 1 ] && echo '2;9')" "$t"; done <<< "$s"
  fi
  s="$(awk -F'\t' -v c="$NP_COMP" -v k="$NP_KEY" -v nsl="$nsl" '$1 == c && $6 == "dangling" && (k == "" || $2 == k) { printf "  %s:%s -> %s%s (%s)\n", $1, $2, $3, nsl, $7 }' "$VIEW/meta/refs.tsv")"
  if [ -n "$s" ]; then
    printf '\nDangling refs:\n'
    while IFS= read -r t; do pline "$([ "$EX_COLOUR" -eq 1 ] && echo '2;9')" "$t"; done <<< "$s"
  fi
  case "$NP_COMP" in agents/*)
    printf '\nAgent definition (1.6.0): the participant reads model and skills from %s/%s/ at the agent'"'"'s start.\n' "$VIEW" "$NP_COMP"
    if [ -f "$VIEW/$NP_COMP/model" ]; then
      awk -F'\t' -v m="$(head -n 1 "$VIEW/$NP_COMP/model")" -v cli="$(cat "$VIEW/$NP_COMP/cli" 2>/dev/null)" '$1 == "model" { printf "Effective model%s: %s (%s from %s at %s)\n", (cli == "" ? "" : " for its CLI, " cli), m, $4, $2, $3 }' "$VIEW/$NP_COMP/from.tsv"
    fi
    echo "The registry wins: its skills replace the agents list's, and its model a model chosen in the agent's CLI arguments."
    [ -z "$ns" ] || echo "A namespaced agent definition (namespace $ns) applies to no agent of the agents list in this release." ;;
  esac
  return 0
}

cmd_version() {
  local s
  echo "component-registry $(cat "$SHARE_DIR/version" 2>/dev/null || echo unknown)"
  resolve_settings
  echo "layer list: $RF_ABS (from $RF_SOURCE)$([ -f "$RF_ABS" ] || echo ', not there yet')"
  s="$(setting COMPONENT_REGISTRY_WHOAMI)"
  if [ -n "$s" ]; then echo "who you are: ${s%%$'\t'*} (from ${s#*$'\t'})"; else echo "who you are: not set (COMPONENT_REGISTRY_WHOAMI)"; fi
  if [ -f "$STATE_DIR/view/whoami" ]; then echo "resolved view: for $(cat "$STATE_DIR/view/whoami") at $(cat "$STATE_DIR/view/resolved")"; else echo "resolved view: none yet"; fi
  for s in "$STATE_DIR"/paths/*; do
    [ -f "$s/whoami" ] && echo "  a view for $(cat "$s/whoami") at $(cat "$s/resolved")"
  done
  return 0
}

cmd_layer_list() {
  [ $# -eq 0 ] || die 2 "layer-list takes no arguments"
  resolve_settings
  printf '%s\n' "$RF_ABS"
  [ -f "$RF_ABS" ]
}

# handover <cli> [<name> <folder>] [--as <path>] (1.1.0; --as and the record 1.8.0): the consumer
# step of release 1, skills. The CLI's adapter (agent-adapter-<cli>, installed by that CLI's
# Feature) copies the resolved view's skills into the CLI's own skills folders with its optional
# `skills` verb (ADR-0064, amending the CLI contract of ADR-0037), given the folder in
# COMPONENT_REGISTRY_SKILLS and the path in COMPONENT_REGISTRY_PATH. The view is the one resolved for
# --as (an agent's registry-path), else for the who-you-are setting, else the latest (1.8.0, ADR-0074:
# agents with different paths each get their own). It is read under a shared hold of resolve.lock,
# so a resolve never swaps it out mid-copy. <name> and <folder> are the agent's, as every adapter verb
# takes them (default: component-registry and the repository root, the sessions no agent started).
# A hand-over is recorded in handovers.tsv (refresh repeats it). Exit 0 handed over, 1 failed or no
# view, 2 bad use, 3 the CLI cannot take resolved skills (no adapter, or its supports does not list
# skills, or the verb answers 3): its sessions keep their plain skills (NFR-12), and one line says so.
skills_adapter() { # skills_adapter <cli>: AD, the adapter that takes skills; returns 3 (said) when none
  AD="$(command -v "agent-adapter-$1" 2>/dev/null)" || AD=''
  if [ -z "$AD" ]; then say "$1: no agent-adapter-$1 on PATH; its sessions keep their plain skills"; return 3; fi
  # read whole first: grep -q stops early, and under pipefail the adapter's SIGPIPE would fail it
  local sup; sup="$("$AD" supports </dev/null 2>/dev/null)" || sup=''
  if ! printf '%s\n' "$sup" | grep -qx skills; then
    say "$1: its adapter takes no resolved skills (no skills verb); its sessions keep their plain skills"
    return 3
  fi
}
cmd_handover() {
  local cli name folder as='' real rc smode='' s
  local -a pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) [ $# -ge 2 ] || die 2 "--as needs a path"; as="$2"; shift 2 ;;
      --as=*) as="${1#--as=}"; shift ;;
      --skills-mode) [ $# -ge 2 ] || die 2 "--skills-mode needs split, shared or off"; smode="$2"; shift 2 ;;
      --skills-mode=*) smode="${1#--skills-mode=}"; shift ;;
      -*) die 2 "handover: unknown option '$1' (handover <cli> [<name> <folder>] [--as <path>])" ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  cli="${pos[0]:-}" name="${pos[1]:-$BASE_ID}" folder="${pos[2]:-}"
  [ -n "$cli" ] || die 2 "handover needs a CLI: dcf-registry handover <cli> [<name> <folder>] [--as <path>]"
  [[ "$cli" =~ ^[A-Za-z0-9_-]+$ ]] || die 2 "handover: '$cli' is not a CLI name"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die 2 "handover: '$name' is not an agent name"
  resolve_settings
  [ -n "$folder" ] || folder="$ROOT"
  # (1.8.0, ADR-0074) how the CLI keeps the agent's skills: --skills-mode (the agents list's
  # registry-skills), else the setting COMPONENT_REGISTRY_SKILLS_MODE, else split
  if [ -z "$smode" ]; then s="$(setting COMPONENT_REGISTRY_SKILLS_MODE)"; smode="${s%%$'\t'*}"; fi
  case "${smode:=split}" in
    split | shared) ;;
    off) cmd_forget "$cli" "$name" "$folder"; return $? ;;
    *) die 2 "skills mode '$smode' is not split, shared or off (--skills-mode, COMPONENT_REGISTRY_SKILLS_MODE)" ;;
  esac
  skills_adapter "$cli" || return 3
  [ -d "$STATE_DIR" ] || die 1 "no state folder $STATE_DIR; run dcf-registry resolve first"
  command -v flock >/dev/null 2>&1 || die 1 "flock (util-linux) is needed to read the view while no resolve swaps it"
  exec 8>>"$STATE_DIR/resolve.lock"
  flock -s -w "${COMPONENT_REGISTRY_LOCK_WAIT:-120}" 8 || die 1 "a resolve has held $STATE_DIR/resolve.lock for ${COMPONENT_REGISTRY_LOCK_WAIT:-120}s; try again"
  view_for "$as"
  real="$(readlink -f "$VIEW")"
  [ -d "$real/skills" ] || die 1 "the resolved view $real has no skills folder; run dcf-registry resolve"
  # 1.11.0 (ADR-0077): the CLI's files are rendered from its templates (the base layer's, or a
  # layer's that replaces or extends them); a CLI with no template gets the view's skills as they
  # are. A template that does not render, or no minijinja-cli, fails the hand-over: the adapter is
  # not called and the CLI keeps the files it has.
  local src="$real/skills" rdir="$STATE_DIR/renders/$cli.$name.$$" rr
  rm -rf "$rdir"; mkdir -p "$STATE_DIR/renders"
  render_view "$cli" "$real" "$rdir"; rr=$?
  case "$rr" in
    0) src="$rdir/skills"; say "$cli: $RENDER_NOTE (dcf-registry explain templates/$cli says which layer's)" ;;
    4) ;;
    *) rm -rf "$rdir" "$rdir.ctx"; exec 8>&-
       warn "$cli: $RENDER_ERR. Nothing was handed over; $name's CLI keeps the skills it has."
       return 1 ;;
  esac
  COMPONENT_REGISTRY_SKILLS="$src" COMPONENT_REGISTRY_PATH="$VPATH" COMPONENT_REGISTRY_SKILLS_MODE="$smode" "$AD" skills "$name" "$folder" </dev/null; rc=$?
  rm -rf "$rdir" "$rdir.ctx"
  [ "$rc" -eq 0 ] && record_handover "$cli" "$name" "$folder" "$VPATH" "$VMODE" "$smode"
  # 1.7.0: a namespaced skill goes to the CLI by its folder name, <ns>--<name>; say which
  local nsk
  nsk="$(awk -F'\t' '$1 ~ /^skills\// { printf "%s%s as %s", (n++ ? ", " : ""), substr($1, 8), substr($3, 8) }' "$real/meta/namespaced.tsv" 2>/dev/null)"
  [ "$rc" -ne 0 ] || [ -z "$nsk" ] || say "$cli: namespaced skills are handed over by their folder name, <namespace>--<name>: $nsk"
  exec 8>&-
  if [ "$rc" -eq 3 ]; then say "$cli: its adapter answered that it cannot take resolved skills; its sessions keep their plain skills"; fi
  return "$rc"
}

# forget <cli> <name> <folder> (1.8.0): the agent is gone (the participant component calls it for an
# agent no longer in the agents list); the adapter's skills verb with COMPONENT_REGISTRY_FORGET=1
# drops the agent's own copies, the record goes, and a path no record names any more loses its view.
cmd_forget() {
  local cli="${1:-}" name="${2:-}" folder="${3:-}" rc=0
  [ $# -eq 3 ] && [ -n "$cli" ] && [ -n "$name" ] && [ -n "$folder" ] || die 2 "forget needs <cli> <name> <folder>"
  [[ "$cli" =~ ^[A-Za-z0-9_-]+$ ]] || die 2 "forget: '$cli' is not a CLI name"
  [ -d "$STATE_DIR" ] || { say "nothing recorded"; return 0; }
  if skills_adapter "$cli" >/dev/null; then
    COMPONENT_REGISTRY_FORGET=1 "$AD" skills "$name" "$folder" </dev/null; rc=$?
    [ "$rc" -ne 3 ] || rc=0
  fi
  [ "$rc" -eq 0 ] || { warn "$cli: the adapter could not drop $name's copies (exit $rc); its record is kept"; return "$rc"; }
  record_handover "$cli" "$name" "$folder" '' forget
  if command -v flock >/dev/null 2>&1; then
    exec 9>>"$STATE_DIR/resolve.lock"
    if flock -w "${COMPONENT_REGISTRY_LOCK_WAIT:-120}" 9; then prune_views --pointers; fi
    exec 9>&-
  fi
  say "forgot $name ($cli, $folder)"
}

cmd_handovers() {
  local show='' c n f p m sm out sup
  case "${1:-}" in '') ;; --skills) show=1 ;; *) die 2 "handovers takes no arguments but --skills" ;; esac
  [ -f "$STATE_DIR/handovers.tsv" ] || return 0
  if [ -z "$show" ]; then cat "$STATE_DIR/handovers.tsv"; return 0; fi
  # --skills (1.8.0, ADR-0074): one block per agent, with what its CLI holds for it
  while IFS=$'\t' read -r c n f p m sm; do
    [ -n "$c" ] || continue
    printf '%s (%s, %s): path %s (%s), registry skills %s\n' "$n" "$c" "$f" "$p" "$([ "$m" = as ] && echo its registry-path || echo the who-you-are setting)" "${sm:-split}"
    out='' sup="$(agent-adapter-"$c" supports </dev/null 2>/dev/null)" || sup=''
    if printf '%s\n' "$sup" | grep -qx skills-show; then out="$(agent-adapter-"$c" skills-show "$n" "$f" </dev/null 2>/dev/null)" || out=''; fi
    if [ -z "$out" ]; then echo "  $c does not say where it keeps them (no skills-show)"; continue; fi
    printf '%s\n' "$out" | awk -F'\t' '
      $1 == "own" { own = $2 } $1 == "own-skills" { os = $2 } $1 == "shared-skills" { ss = $2 } $1 == "shared" { sf = $2 }
      END { printf "  own folder: %s\n  own skills: %s\n  shared (%s): %s\n", own, os, sf, ss }'
  done < "$STATE_DIR/handovers.tsv"
}

# refresh [--as <path>] [--session <id>] (1.1.0; per agent 1.8.0, /registry-refresh): resolve now and
# hand over again.
#   --as <path>     that path, handed to every CLI adapter on PATH for the sessions no agent started
#   --session <id>  the agent whose session that is (the id in an adapter's list): its own path
#                   (its record), resolved and handed to it alone; an unknown id refreshes everything
#   neither         every recorded hand-over, each distinct path resolved once (an agent of the
#                   who-you-are setting: the setting now); with no record, the path the latest view
#                   was resolved for, to every CLI adapter on PATH (1.1.0)
# A CLI whose adapter cannot take them is named (exit 3 of handover); the refresh still succeeds.
refresh_paths() { # refresh_paths <path>...: resolve each once; RESOLVED[path]=ok or failed
  local p rc
  for p in "$@"; do
    [ -n "${RESOLVED[$p]:-}" ] && continue
    bash "$0" resolve --as "$p"; rc=$?
    if [ "$rc" -eq 0 ]; then RESOLVED[$p]=ok; else RESOLVED[$p]=failed; warn "resolve for $p failed (exit $rc); the skills of that path stay as they were"; fi
  done
}
cmd_refresh() {
  local as='' sid='' cli n=0 rc fail=0 s c nm fo p mode sm who cur=''
  local -a recs=()
  declare -gA RESOLVED=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) [ $# -ge 2 ] || die 2 "--as needs a path"; as="$2"; shift 2 ;;
      --as=*) as="${1#--as=}"; shift ;;
      --session) [ $# -ge 2 ] || die 2 "--session needs a session id"; sid="$2"; shift 2 ;;
      --session=*) sid="${1#--session=}"; shift ;;
      *) die 2 "refresh: unknown argument '$1' (refresh [--as <path>] [--session <id>])" ;;
    esac
  done
  # a session id the CLI did not substitute (another CLI reads ${CLAUDE_SESSION_ID} as it is) is none
  [[ "$sid" =~ ^[A-Za-z0-9_-]+$ ]] || sid=''
  resolve_settings
  s="$(setting COMPONENT_REGISTRY_WHOAMI)"; [ -z "$s" ] || { cur="${s%%$'\t'*}"; cur="${cur%/}"; [ -n "$cur" ] || cur=/; }
  [ -f "$STATE_DIR/handovers.tsv" ] && mapfile -t recs < "$STATE_DIR/handovers.tsv"
  if [ -z "$as" ] && [ -n "$sid" ]; then
    for cli in $(compgen -c agent-adapter- 2>/dev/null | sed 's/^agent-adapter-//' | LC_ALL=C sort -u); do
      [[ "$cli" =~ ^[A-Za-z0-9_-]+$ ]] || continue
      s="$(agent-adapter-"$cli" list </dev/null 2>/dev/null | awk -F'\t' -v w="$sid" '$2 == w { print $1 "\t" $4; exit }')"
      [ -n "$s" ] || continue
      nm="${s%%$'\t'*}" fo="${s#*$'\t'}"
      for s in "${recs[@]+"${recs[@]}"}"; do
        IFS=$'\t' read -r c n2 f2 p mode sm <<< "$s"
        [ "$c" = "$cli" ] && [ "$n2" = "$nm" ] && [ "$f2" = "$fo" ] || continue
        [ "$mode" = whoami ] && [ -n "$cur" ] && p="$cur"
        say "refreshing $nm ($cli) for $p, its own path"
        refresh_paths "$p"
        [ "${RESOLVED[$p]}" = ok ] || die 1 "resolve failed; nothing was handed over, the skills stay as they were"
        if [ "$mode" = as ] || [ -z "$cur" ]; then ( cmd_handover "$cli" "$nm" "$fo" --as "$p" --skills-mode "${sm:-split}" ); else ( cmd_handover "$cli" "$nm" "$fo" --skills-mode "${sm:-split}" ); fi
        rc=$?
        say "a CLI that does not watch its skills folder reads the new skills when its session is restarted"
        return "$rc"
      done
    done
    say "session $sid is no agent the registry has handed skills to; refreshing every recorded hand-over"
  fi
  if [ -z "$as" ] && [ "${#recs[@]}" -gt 0 ]; then
    for s in "${recs[@]}"; do
      IFS=$'\t' read -r c nm fo p mode sm <<< "$s"
      [ "$mode" = whoami ] && [ -n "$cur" ] && p="$cur"
      [ -n "$p" ] || continue
      refresh_paths "$p"
      [ "${RESOLVED[$p]}" = ok ] || { fail=1; continue; }
      if [ "$mode" = as ] || [ -z "$cur" ]; then ( cmd_handover "$c" "$nm" "$fo" --as "$p" --skills-mode "${sm:-split}" ); else ( cmd_handover "$c" "$nm" "$fo" --skills-mode "${sm:-split}" ); fi
      rc=$?
      case "$rc" in 0 | 3) ;; *) fail=1; warn "$c: the handover to $nm failed (exit $rc)" ;; esac
    done
    who="$(printf '%s\n' "${!RESOLVED[@]}" | LC_ALL=C sort | tr '\n' ' ')"
    say "refreshed ${#recs[@]} hand-over(s) for ${who% }"
    say "a CLI that does not watch its skills folder reads the new skills when its session is restarted"
    return "$fail"
  fi
  local -a hv=()
  if [ -n "$as" ]; then hv=(--as "$as")
  elif [ -f "$STATE_DIR/view/whoami" ]; then
    as="$(cat "$STATE_DIR/view/whoami")"
    [ "$as" = "$cur" ] || hv=(--as "$as")
    say "refreshing for $as, the path the current view was resolved for (--as names another)"
  fi
  if [ -n "$as" ]; then bash "$0" resolve --as "$as"; else bash "$0" resolve; fi
  rc=$?
  [ "$rc" -eq 0 ] || die "$rc" "resolve failed; nothing was handed over, the skills stay as they were"
  for cli in $(compgen -c agent-adapter- 2>/dev/null | sed 's/^agent-adapter-//' | LC_ALL=C sort -u); do
    [[ "$cli" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    n=$((n + 1))
    ( cmd_handover "$cli" "${hv[@]+"${hv[@]}"}" ); rc=$?
    case "$rc" in 0 | 3) ;; *) fail=1; warn "$cli: the handover failed (exit $rc)" ;; esac
  done
  [ "$n" -gt 0 ] || say "no CLI adapter on PATH (agent-adapter-<cli>); the resolved view is ready, nothing was handed over"
  say "a CLI that does not watch its skills folder reads the new skills when its session is restarted"
  return "$fail"
}

# remember (removed in 2.0.0): the registry does not write layers.
cmd_remember() {
  warn "remember is removed in 2.0.0: edit your layer (the registry does not write layers)"
  exit 1
}

case "${1:-}" in
  resolve) shift; cmd_resolve "$@" ;;
  explain) shift; cmd_explain "$@" ;;
  version) shift; cmd_version ;;
  layer-list) shift; cmd_layer_list "$@" ;;
  handover) shift; cmd_handover "$@" ;;
  forget) shift; cmd_forget "$@" ;;
  handovers) shift; cmd_handovers "$@" ;;
  refresh) shift; cmd_refresh "$@" ;;
  remember) shift; cmd_remember "$@" ;;
  render) shift; cmd_render "$@" ;;
  -h | --help | help | '') usage ;;
  *) die 2 "unknown verb '$1' (resolve, explain, version, layer-list, handover, forget, handovers, refresh, remember, render)" ;;
esac
