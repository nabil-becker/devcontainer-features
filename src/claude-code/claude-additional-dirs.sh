#!/usr/bin/env bash
# claude-additional-dirs: write the claude-code Feature's additionalDirectories option as a
# managed-settings drop-in, so every Claude session in the container gets those folders as
# working directories without a wrapper around claude (`--add-dir`). Run by install.sh at
# build time; not installed on PATH.
#
#   claude-additional-dirs <comma-separated folders> <remote user's home> [<drop-in file>]
#
# The drop-in is /etc/claude-code/managed-settings.d/50-devcontainer-features-claude-code.json
# unless a third argument names another path:
#   {"permissions":{"additionalDirectories":["/a","/b c"]}}
# Why a managed drop-in: the image owns /etc/claude-code, so the user's own settings.json (in
# the Feature's volume) is never rewritten, and a rebuild writes the file afresh (a folder
# taken out of the option is gone again). Claude Code merges managed-settings.json and every
# managed-settings.d/*.json, lists combined, and a managed list combines with the user's,
# project and local lists.
#
# Folders: absolute paths, or `~` / `~/...`, expanded here to the remote user's home (the
# file holds absolute paths only, whatever Claude Code does with `~`). Spaces inside a path
# are kept; spaces around a comma are dropped; empty items, a trailing / and duplicates are
# dropped. A relative path or `~user` is refused (exit 2) and nothing is written. An empty
# option writes nothing and removes a drop-in an earlier build left. A folder need not exist
# at build time (a mount appears later).
set -euo pipefail

list="${1:-}" home="${2:-}" out="${3:-/etc/claude-code/managed-settings.d/50-devcontainer-features-claude-code.json}"

die() { printf 'claude-code: additionalDirectories: %s\n' "$*" >&2; exit 2; }
json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

dirs=()
IFS=',' read -r -a items <<< "$list"
for d in ${items[@]+"${items[@]}"}; do
  d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
  [ -n "$d" ] || continue
  # shellcheck disable=SC2088  # a literal ~ is what is matched, then expanded by hand
  case "$d" in
    '~' | '~/'*)
      [ -n "$home" ] || die "'$d' starts with ~, but the remote user's home is not known; give an absolute path."
      d="${home%/}${d#\~}" ;;
    '~'*) die "'$d': only ~ (the remote user's home) is expanded, not ~user; give an absolute path." ;;
    /*) ;;
    *) die "'$d' is not an absolute path (or ~/...); a relative path has no fixed meaning for every session." ;;
  esac
  case "$d" in *[[:cntrl:]]*) die "a control character in '$d'." ;; esac
  while [ "${#d}" -gt 1 ] && [ "${d%/}" != "$d" ]; do d="${d%/}"; done
  seen=''
  for e in ${dirs[@]+"${dirs[@]}"}; do [ "$e" = "$d" ] && seen=1; done
  [ -n "$seen" ] || dirs+=("$d")
done

if [ "${#dirs[@]}" -eq 0 ]; then
  if [ -e "$out" ]; then rm -f "$out"; echo "claude-code: additionalDirectories empty; removed $out."; fi
  exit 0
fi

body='' sep=''
for d in "${dirs[@]}"; do body="$body$sep$(json_str "$d")"; sep=','; done
mkdir -p "$(dirname "$out")"
printf '{"permissions":{"additionalDirectories":[%s]}}\n' "$body" > "$out.tmp"
chmod 0644 "$out.tmp"
mv -f "$out.tmp" "$out"
echo "claude-code: every Claude session gets ${#dirs[@]} additional working director$([ "${#dirs[@]}" -eq 1 ] && echo y || echo ies) ($out)."
