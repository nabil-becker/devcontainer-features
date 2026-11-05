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

# The records a repository keeps, relative to the root unless absolute. DEVHOST_RECORDS_DIR (a shared
# folder) moves the records that left git: the backlog to <it>/TODO.md, the Markdown ledger to
# <it>/ledger; an explicit DEVHOST_BACKLOG or DEVHOST_LEDGER_DIR still wins (devhost_common.py).
hk_records_dir() { [ -n "${DEVHOST_RECORDS_DIR:-}" ] && hk_abs "$1" "$DEVHOST_RECORDS_DIR"; }
hk_ledger_dir() {
  if [ -n "${DEVHOST_LEDGER_DIR:-}" ]; then hk_abs "$1" "$DEVHOST_LEDGER_DIR"
  elif [ -n "${DEVHOST_RECORDS_DIR:-}" ]; then printf '%s/ledger\n' "$(hk_records_dir "$1")"
  else hk_abs "$1" docs/ledger; fi
}
hk_backlog() {
  if [ -n "${DEVHOST_BACKLOG:-}" ]; then hk_abs "$1" "$DEVHOST_BACKLOG"
  elif [ -n "${DEVHOST_RECORDS_DIR:-}" ]; then printf '%s/TODO.md\n' "$(hk_records_dir "$1")"
  else hk_abs "$1" TODO.md; fi
}
# hk_ledger_register: the agentic-register register holding the ledger (DEVHOST_LEDGER_REGISTER), empty
# when the ledger is the Markdown files of hk_ledger_dir.
hk_ledger_register() { printf '%s\n' "${DEVHOST_LEDGER_REGISTER:-}"; }
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

# hk_fetch_key <job>: the back's own key from OpenBao, for a back that signs (secrets-master-split,
# section 7). Runs in the runner, around the back's claude run, never as a tool call.
#   - the AppRole is the back's own: role id and secret id under $OPENBAO_STATE_DIR/approle/<job>/
#     (written by `task devhost:approles:setup`, mode 600), the role reads dcf/register/<job> only;
#   - the login (`bao write auth/approle/login`, the two ids read from the files with @, never as
#     arguments) gives a token of 5 minutes that exists only in this function and in the environment
#     of the one `dcf-secret get` it is passed to; it is never exported, so the back's job, its
#     claude run and everything they start do not inherit it;
#   - the key is written to a fresh folder on tmpfs (DEVHOST_KEY_TMPFS, /dev/shm; never the disk), mode
#     700 and 600; the runner removes the folder on exit, success or failure.
# Sets HK_KEY_DIR and HK_KEY_FILE on success. Returns 0 (fetched), 1 (nothing to fetch: no bao or
# dcf-secret, or no role for this job; the back runs as before, HK_KEY_ERR says why when asked) or
# 2 (failed: HK_KEY_ERR is one plain line naming the fix; HK_KEY_RC the dcf-secret exit code when it
# ran: 10 unreachable, 11 sealed, 12 login refused, 13 denied, 14 no such secret).
# JOB_KEY_NAME (default register/<job>) and JOB_KEY_FIELD (default private_key) come from the job file.
# _hk_bao <args>: bao (DEVHOST_BAO), with the openbao Feature's env.sh applied (the server mode's default BAO_ADDR).
_hk_bao() (
  f="${OPENBAO_FEATURE_DIR:-/usr/local/share/openbao-feature}/env.sh"
  # shellcheck disable=SC1090  # installed by the openbao Feature
  [ -f "$f" ] && . "$f"
  "${DEVHOST_BAO:-bao}" "$@"
)

# _hk_keyfile_unlock: succeeds when the openbao Feature runs keyfile unlock (the OpenBao key file opens the
# store). Asks `openbao-setup unlock --status` (no secret, no stdin) and reads its "mode" field.
_hk_keyfile_unlock() {
  local exe="${DEVHOST_OPENBAO_SETUP:-/usr/local/bin/openbao-setup}"
  [ -x "$exe" ] || return 1
  "$exe" unlock --status </dev/null 2>/dev/null | grep -q '"mode"[[:space:]]*:[[:space:]]*"keyfile"'
}

# shellcheck disable=SC2034  # HK_* are read by the runner
hk_fetch_key() {
  local job="$1" od rid sid name field tok st rc err tfs
  HK_KEY_DIR=""; HK_KEY_FILE=""; HK_KEY_ERR=""; HK_KEY_RC=0
  od="${OPENBAO_STATE_DIR:-/var/lib/devcontainer-features/openbao}"
  name="${JOB_KEY_NAME:-register/$job}"; field="${JOB_KEY_FIELD:-private_key}"
  rid="$od/approle/$job/role_id"; sid="$od/approle/$job/secret_id"
  if ! command -v "${DEVHOST_BAO:-bao}" >/dev/null 2>&1 || ! command -v dcf-secret >/dev/null 2>&1; then
    HK_KEY_ERR="the openbao Feature is not installed here (no bao or dcf-secret)"; return 1
  fi
  if [ ! -r "$rid" ] || [ ! -r "$sid" ]; then
    HK_KEY_ERR="no AppRole for the $job back under $od/approle/$job: the Operator runs task devhost:approles:setup in a terminal (a role is made once, with the unseal shares)"; return 1
  fi
  tfs="${DEVHOST_KEY_TMPFS:-/dev/shm}"
  HK_KEY_DIR="$(umask 077; mktemp -d "$tfs/devhost-key.XXXXXX" 2>/dev/null)" \
    || { HK_KEY_DIR=""; HK_KEY_ERR="no tmpfs folder at $tfs for the key (it is never written to disk)"; return 2; }
  err="$HK_KEY_DIR/err"
  # The server's own default address in server mode comes from the openbao Feature's env.sh, as for dcf-secret.
  tok="$(_hk_bao write -field=token auth/approle/login role_id=@"$rid" secret_id=@"$sid" 2>"$err")"
  if [ -z "$tok" ]; then
    # What the server says is read from its own exit code, never from the words of the error.
    _hk_bao status >/dev/null 2>&1; st=$?
    case "$st" in
      2) HK_KEY_RC=11
         if _hk_keyfile_unlock; then HK_KEY_ERR="OpenBao is sealed: the Operator runs task dc:openbao:unlock on the workstation (nothing typed)"
         else HK_KEY_ERR="OpenBao is sealed: the Operator runs task openbao:unseal"; fi ;;
      0) HK_KEY_RC=12; HK_KEY_ERR="the AppRole login of the $job back was refused (role revoked or its secret id reissued elsewhere): task devhost:approles:setup, or task openbao:approle:issue ROLE=$job" ;;
      *) HK_KEY_RC=10; HK_KEY_ERR="OpenBao is unreachable: task openbao:server:status says whether it runs" ;;
    esac
    rm -f "$err"; return 2
  fi
  HK_KEY_FILE="$HK_KEY_DIR/key"
  rc=0
  ( umask 077; BAO_TOKEN="$tok" dcf-secret get "$name" --field "$field" >"$HK_KEY_FILE" 2>"$err" ) || rc=$?
  tok=""
  if [ "$rc" -ne 0 ]; then
    HK_KEY_RC="$rc"; HK_KEY_ERR="$(tail -n1 "$err" | head -c 300)"; [ -n "$HK_KEY_ERR" ] || HK_KEY_ERR="dcf-secret get $name failed ($rc)"
    rm -f "$HK_KEY_FILE" "$err"; HK_KEY_FILE=""; return 2
  fi
  rm -f "$err"
  return 0
}
