#!/usr/bin/env bash
# claude-host-pin: keep the session id pinned in .devcontainer/.env (HOST_SESSION,
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
# It finds .devcontainer/.env upwards from cwd (or CLAUDE_HOST_ENV_FILE), picks the
# variable like devcontainer:claude does (the folder with .devcontainer is the root:
# HOST_SESSION; a sub-folder DIR: HOST_SESSION_<base of DIR, upper-cased, every other
# character _>, rooms/solis -> HOST_SESSION_SOLIS) and writes session_id into that
# line, only when it differs, keeping quotes, comments and every other byte of the
# file. No such line: nothing is added unless CLAUDE_HOST_PIN_CREATE=1 (then
# VAR=<id> is appended). A session_id that is not a UUID is ignored. Exit 0 always;
# notes go to stderr.
#
# claude-host-pin --replace <old-id> <new-id>: what claude-host's
# CLAUDE_HOST_UPDATE_PIN calls: the one HOST_SESSION... line holding <old-id> gets
# <new-id> (CLAUDE_HOST_PIN_VAR=<name> restricts the variable); not exactly one such
# line: nothing is changed. Exit 0, or 1 when nothing was updated.
set -u
uuid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# find_env <dir>: the .devcontainer/.env above <dir>, or CLAUDE_HOST_ENV_FILE.
find_env() {
  local d="$1"
  if [ -n "${CLAUDE_HOST_ENV_FILE:-}" ]; then printf '%s' "$CLAUDE_HOST_ENV_FILE"; return 0; fi
  while :; do
    [ -f "$d/.devcontainer/.env" ] && { printf '%s' "$d/.devcontainer/.env"; return 0; }
    [ "$d" = / ] && return 1
    d="$(dirname "$d")"
  done
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
  f="$(find_env "$(pwd -P)")" && [ -f "$f" ] || { echo "claude-host-pin: no .devcontainer/.env found; nothing updated." >&2; exit 1; }
  name="${CLAUDE_HOST_PIN_VAR:-HOST_SESSION[A-Za-z0-9_]*}"
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
f="$(find_env "$cwd")" && [ -f "$f" ] || { echo "claude-host-pin: no .devcontainer/.env above $cwd; nothing written." >&2; exit 0; }
root="$(cd "$(dirname "$f")/.." 2>/dev/null && pwd -P)"
if [ "$cwd" = "$root" ] || [ -z "$root" ]; then
  var=HOST_SESSION
else
  var="HOST_SESSION_$(basename "$cwd" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')"
fi
cur="$(sed -n "s/^[[:space:]]*\\(export[[:space:]]\\{1,\\}\\)\\{0,1\\}$var=[\"']\\{0,1\\}\\([^\"'[:space:]#]*\\).*/\\2/p" "$f" | tail -n 1)"
if grep -Eq "^[[:space:]]*(export[[:space:]]+)?$var=" "$f"; then
  if [ "${cur,,}" = "${id,,}" ]; then exit 0; fi
  set_value "$f" "$var" '' "$id" && echo "claude-host-pin: $var in $f: ${cur:-<empty>} -> $id (source ${source:-?})." >&2
elif [ -n "${CLAUDE_HOST_PIN_CREATE:-}" ]; then
  nl=''; [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && nl='\n'
  printf "${nl}%s=%s\n" "$var" "$id" >> "$f"
  echo "claude-host-pin: added $var=$id to $f." >&2
else
  echo "claude-host-pin: $f has no $var line; nothing added (CLAUDE_HOST_PIN_CREATE=1 adds it)." >&2
fi
exit 0
