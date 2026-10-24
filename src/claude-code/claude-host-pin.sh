#!/usr/bin/env bash
# claude-host-pin: keep the session id pinned in the repo's .env files (HOST_SESSION,
# HOST_SESSION_<DIR>) equal to the id Claude Code really runs, which changes on
# /clear. Installed on PATH by the claude-code Feature next to claude-host; the one
# place that writes the pin.
#
# Hook mode (no arguments): an OPT-IN Claude Code SessionStart hook. Claude Code
# passes the hook input as JSON on stdin (session_id, cwd, source: startup, resume,
# clear or compact; hook_event_name, transcript_path). Register it in a repo's
# .claude/settings.json (the Feature manages no settings):
#   {"hooks": {"SessionStart": [
#     {"matcher": "startup|clear", "hooks": [{"type": "command", "command": "claude-host-pin"}]}]}}
# It looks at the same files, in the same order, as Task's `dotenv: ['.env',
# '.devcontainer/.env']` (the first file that defines a variable wins): the root .env, then
# .devcontainer/.env, the root being the nearest folder at or above cwd holding .devcontainer
# (CLAUDE_HOST_ENV_FILE overrides: that one file). It picks the
# variable like devcontainer:claude does (the folder with .devcontainer is the root:
# HOST_SESSION; a sub-folder DIR: HOST_SESSION_<base of DIR, upper-cased, every other
# character _>, rooms/solis -> HOST_SESSION_SOLIS) and writes session_id into that
# line of the first file that holds one, only when it differs, keeping quotes, comments and
# every other byte of the file. No such line in any file: nothing is added unless
# CLAUDE_HOST_PIN_CREATE=1 (then VAR=<id> is appended to .devcontainer/.env). A session_id that is not a UUID is ignored. Exit 0 always;
# notes go to stderr.
#
# claude-host-pin --replace <old-id> <new-id>: what claude-host's
# CLAUDE_HOST_UPDATE_PIN calls: the one HOST_SESSION... line holding <old-id> gets
# <new-id> (CLAUDE_HOST_PIN_VAR=<name> restricts the variable); not exactly one such
# line: nothing is changed. Exit 0, or 1 when nothing was updated.
set -u
uuid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# env_files <dir>: first line the root (the folder holding .devcontainer), then the .env files
# that apply above <dir>, one per line, in Task's dotenv order (root .env, then
# root/.devcontainer/.env; only those that exist), or CLAUDE_HOST_ENV_FILE alone. Returns 1
# when there is none.
env_files() {
  local d="$1" f n=0
  if [ -n "${CLAUDE_HOST_ENV_FILE:-}" ]; then
    f="$CLAUDE_HOST_ENV_FILE"; [ -f "$f" ] || return 1
    d="$(dirname "$f")"
    case "$d" in */.devcontainer) d="$(dirname "$d")" ;; esac
    printf '%s\n' "$(cd "$d" 2>/dev/null && pwd -P)" "$f"; return 0
  fi
  while :; do
    if [ -d "$d/.devcontainer" ]; then
      printf '%s\n' "$d"
      for f in "$d/.env" "$d/.devcontainer/.env"; do [ -f "$f" ] && { printf '%s\n' "$f"; n=1; }; done
      [ "$n" = 1 ]; return
    fi
    [ "$d" = / ] && return 1
    d="$(dirname "$d")"
  done
}

# holder <variable regex> <file>...: the first file with a line for the variable.
holder() {
  local name="$1" f; shift
  for f in "$@"; do
    [ -f "$f" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?${name}=" "$f" && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# set_value <file> <variable regex> <old regex or ''> <new>: replace the value on the
# one line of <variable> (holding <old> when given); keeps `export`, quotes and what
# follows the value. Returns 0 changed, 1 not changed.
set_value() {
  local f="$1" name="$2" old="$3" new="$4" n tmp lead valre
  lead="^[[:space:]]*(export[[:space:]]+)?${name}="
  n="$(grep -Ec "${lead}[\"']?${old}" "$f")"
  [ "$n" -eq 1 ] || { echo "claude-host-pin: $n lines of $f match${old:+ (holding $old)}; need exactly one, nothing changed." >&2; return 1; }
  tmp="$(mktemp)" || return 1
  valre="$old"; [ -n "$valre" ] || valre="[^\"'[:space:]#]*"
  # the value is what stands between the optional quote and a quote, blank or #
  sed "s/\(^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}${name}=[\"']\{0,1\}\)${valre}/\1${new}/I" "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$f"; rm -f "$tmp"
  return 0
}

if [ "${1:-}" = --replace ]; then
  old="${2:-}" new="${3:-}"
  [[ "$old" =~ $uuid && "$new" =~ $uuid ]] || { echo "claude-host-pin: --replace needs two UUIDs." >&2; exit 1; }
  files="$(env_files "$(pwd -P)")" || { echo "claude-host-pin: no .env or .devcontainer/.env found; nothing updated." >&2; exit 1; }
  files="$(printf '%s\n' "$files" | tail -n +2)"
  name="${CLAUDE_HOST_PIN_VAR:-HOST_SESSION[A-Za-z0-9_]*}"
  # the first file with a line of the variable holding <old>
  f=''
  while IFS= read -r c; do
    [ -f "$c" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?${name}=[\"']?${old}" "$c" && { f="$c"; break; }
  done <<< "$files"
  [ -n "$f" ] || { echo "claude-host-pin: no line of $name holds $old in $(printf '%s' "$files" | tr '\n' ' '); nothing updated." >&2; exit 1; }
  if set_value "$f" "$name" "$old" "$new"; then echo "claude-host-pin: updated $f: $old -> $new." >&2; exit 0; fi
  exit 1
fi

# hook mode: never fail the session
input="$(cat 2>/dev/null || true)"
field() { printf '%s' "$input" | tr -d '\n\r' | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\(\\([^\"\\\\]\\|\\\\.\\)*\\)\".*/\\1/p" | sed 's/\\\\/\\/g'; }
id="$(field session_id)" cwd="$(field cwd)" source="$(field source)"
if ! [[ "$id" =~ $uuid ]]; then echo "claude-host-pin: no valid session_id in the hook input; ignored." >&2; exit 0; fi
[ -n "$cwd" ] && cwd="$( (cd "$cwd" 2>/dev/null && pwd -P) || true)"
[ -n "$cwd" ] || cwd="$(pwd -P)"
files="$(env_files "$cwd")" || { echo "claude-host-pin: no .env or .devcontainer/.env above $cwd; nothing written." >&2; exit 0; }
root="$(printf '%s\n' "$files" | head -n 1)"
files="$(printf '%s\n' "$files" | tail -n +2)"
if [ "$cwd" = "$root" ] || [ -z "$root" ]; then
  var=HOST_SESSION
else
  var="HOST_SESSION_$(basename "$cwd" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')"
fi
mapfile -t flist <<< "$files"
f="$(holder "$var" "${flist[@]}")" || f=''
cur="$([ -n "$f" ] && sed -n "s/^[[:space:]]*\\(export[[:space:]]\\{1,\\}\\)\\{0,1\\}$var=[\"']\\{0,1\\}\\([^\"'[:space:]#]*\\).*/\\2/p" "$f" | tail -n 1)"
if [ -n "$f" ]; then
  if [ "${cur,,}" = "${id,,}" ]; then exit 0; fi
  set_value "$f" "$var" '' "$id" && echo "claude-host-pin: $var in $f: ${cur:-<empty>} -> $id (source ${source:-?})." >&2
elif [ -n "${CLAUDE_HOST_PIN_CREATE:-}" ]; then
  # no file holds the variable: append to .devcontainer/.env, the documented home, else the first file
  f="${flist[0]}"
  for c in "${flist[@]}"; do case "$c" in */.devcontainer/.env) f="$c" ;; esac; done
  nl=''; [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && nl='\n'
  printf "${nl}%s=%s\n" "$var" "$id" >> "$f"
  echo "claude-host-pin: added $var=$id to $f." >&2
else
  echo "claude-host-pin: no $var line in ${flist[*]}; nothing added (CLAUDE_HOST_PIN_CREATE=1 adds it)." >&2
fi
exit 0
