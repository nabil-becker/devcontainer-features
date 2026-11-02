# Shared by the backs' scripts (run-job.sh and the job files); sourced, never run.
# Everything a script needs to know about where it is lives here and nowhere else:
#   - the gate: the backs act only inside a container (a workstation session is never
#     touched), never inside a back's own claude run;
#   - the root, the state directory and the paths of the records, each from a DEVHOST_*
#     variable with a default (see NOTES.md, "Settings");
#   - the backs' models, each overridable from the environment (SCRIBE_MODEL=...).
# shellcheck shell=bash

# The models, sized by blast radius: the scribe and the secretary only record, the
# librarian judges what a stretch settled. The tester uses no model; "none" is what its
# metrics line records.
: "${SCRIBE_MODEL:=haiku}"
: "${SECRETARY_MODEL:=haiku}"
: "${LIBRARIAN_MODEL:=sonnet}"
: "${TESTER_MODEL:=none}"

: "${DEVHOST_SHARE:=/usr/local/share/devhost}"

# hk_in_container: true only inside a container. Docker writes /.dockerenv, Podman
# /run/.containerenv; a workstation has neither. DEVHOST_CONTAINER_MARKERS overrides the
# list (the tests use it to play workstation and container).
hk_in_container() {
  local m
  for m in ${DEVHOST_CONTAINER_MARKERS:-/.dockerenv /run/.containerenv}; do
    [ -e "$m" ] && return 0
  done
  return 1
}

# hk_root [cwd]: the repository the backs keep, a directory holding .claude/settings.json
# (the hooks live there, so that file is what makes a checkout a devhost repo).
# DEVHOST_ROOT when set (and only it: a wrong value means "not this repository"), else
# CLAUDE_PROJECT_DIR (Claude Code sets it for every hook), else the hook's cwd or its
# nearest ancestor. Prints nothing when none qualifies.
hk_root() {
  local r
  if [ -n "${DEVHOST_ROOT:-}" ]; then
    [ -f "${DEVHOST_ROOT}/.claude/settings.json" ] || return 1
    printf '%s\n' "${DEVHOST_ROOT%/}"; return 0
  fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "${CLAUDE_PROJECT_DIR}/.claude/settings.json" ]; then
    printf '%s\n' "${CLAUDE_PROJECT_DIR%/}"; return 0
  fi
  r="${1:-$PWD}"
  while [ -n "$r" ] && [ "$r" != / ] && [ "$r" != . ]; do
    if [ -f "$r/.claude/settings.json" ]; then printf '%s\n' "$r"; return 0; fi
    r="$(dirname "$r")"
  done
  return 1
}

# hk_state: the job state directory (offsets, locks, logs, runs.jsonl, pending files): the
# Feature's volume by default, outside the checkout so nothing is ever committed or synced.
hk_state() { printf '%s\n' "${DEVHOST_STATE:-/var/lib/devcontainer-features/devhost}"; }

# hk_abs <root> <path>: <path> as given when absolute, else under <root>.
hk_abs() { case "$2" in /*) printf '%s\n' "$2" ;; *) printf '%s\n' "${1%/}/$2" ;; esac; }

# The records a repository keeps, relative to the root unless absolute.
hk_ledger_dir() { hk_abs "$1" "${DEVHOST_LEDGER_DIR:-docs/ledger}"; }
hk_backlog() { hk_abs "$1" "${DEVHOST_BACKLOG:-TODO.md}"; }
hk_lexicon() { hk_abs "$1" "${DEVHOST_LEXICON:-LEXICON.md}"; }
hk_adr_dir() { hk_abs "$1" "${DEVHOST_ADR_DIR:-docs/adr}"; }
hk_model_dir() { hk_abs "$1" "${DEVHOST_MODEL_DIR:-docs/model}"; }
hk_night_shift_dir() { hk_abs "$1" "${DEVHOST_NIGHT_SHIFT_DIR:-docs/night-shift}"; }

# hk_jobs_dir: where `devhost-run-job <job>` finds jobs/<job>/job.sh; a repository may
# point DEVHOST_JOBS_DIR at its own set (same layout).
hk_jobs_dir() { printf '%s\n' "${DEVHOST_JOBS_DIR:-$DEVHOST_SHARE/jobs}"; }

# hk_engineer <root>: whose machine this is, for the metrics line, the cost report's file
# name and the entries: DEVHOST_ENGINEER as a slug, else "operator". Never the git identity:
# the handle is committed (ledger entries, the cost report's file name), and a git name may
# be a person's name.
hk_engineer() {
  local n="${DEVHOST_ENGINEER:-}"
  n="$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s\n' "${n:-operator}"
}

# hk_guard <kind> [job]: sets HK_GUARD to the command (as an array) that runs the guard of
# that kind (backlog: <before> <after>; docs: <snapshot dir> <root>), exit 1 when none is
# installed - the job then undoes its run, since an unguarded edit is worse than no edit.
# The guards ship with the Python half of the Feature (share/python/guards.py <kind> ...);
# a job folder may carry its own <kind>_guard.py with the same arguments.
# shellcheck disable=SC2034  # HK_GUARD is read by the job files
hk_guard() {
  local p
  if [ -f "$DEVHOST_SHARE/python/guards.py" ]; then
    HK_GUARD=(python3 "$DEVHOST_SHARE/python/guards.py" "$1"); return 0
  fi
  for p in "$DEVHOST_SHARE/python/$1_guard.py" "$(hk_jobs_dir)/${2:-}/$1_guard.py"; do
    [ -f "$p" ] && { HK_GUARD=(python3 "$p"); return 0; }
  done
  HK_GUARD=(); return 1
}

# hk_measures <main-count> <since-or-empty> <transcript>...: one Measures line for a
# ledger entry, from Claude Code's own transcripts, by the Feature's cost script
# (devhost-costs, the Python half) when it is installed; "not measured" otherwise, so the
# scribe never waits on it.
hk_measures() {
  local main="$1" since="$2"; shift 2
  local cmd=()
  if command -v devhost-costs >/dev/null 2>&1; then cmd=(devhost-costs)
  elif [ -f "$DEVHOST_SHARE/python/session_cost.py" ]; then cmd=(python3 "$DEVHOST_SHARE/python/session_cost.py")
  else echo "not measured"; return 0; fi
  # shellcheck disable=SC2086
  "${cmd[@]}" --measures "$@" --main "$main" ${since:+--since "$since"} 2>/dev/null || echo "not measured"
}
