#!/usr/bin/env bash
# One-shot bootstrap for a repo that should be driven through
# `task devcontainer:*`. Linux/macOS entry point; Windows uses bootstrap.ps1.
# Run from the repo root on a host that has Task and a Docker-compatible
# engine:
#
#   curl -fsSL https://raw.githubusercontent.com/nabil-becker/devcontainer-features/main/bootstrap/bootstrap.sh | bash
#
# Every setting can come from the command line, from an environment variable,
# or from a .env file in the repo (./.env or ./.devcontainer/.env, loaded
# first; existing environment wins over the file; flags win over both):
#
#   --ref <git-ref>          DEVCONTAINER_BOOTSTRAP_REF      (default main)
#   --path <dir>             DEVCONTAINER_BOOTSTRAP_PATH     (default cwd)
#   --source <url|dir>       DEVCONTAINER_BOOTSTRAP_SOURCE   (default raw GitHub URL for the ref)
#   --docker-path <cli>      DEVCONTAINER_DOCKER_PATH        (default docker on PATH)
#   --no-up                  DEVCONTAINER_BOOTSTRAP_NO_UP=true
#   --bootstrap-dir <dir>    BOOTSTRAP_DIR                   (default .devcontainer/cli_bootstrap.ignore;
#                            repo-relative, no absolute path, no ..)
#   --no-gitignore           BOOTSTRAP_GITIGNORE=false       (do not git-ignore the vendored folder)
#
# What it does: (1) vendors bootstrap/devcontainer.yml, bootstrap/host/* and
# the devcontainer-cli Feature's devcontainer-cli.sh (with dcf-curl.sh, its
# download helper) into the bootstrap folder
# (always refreshed - re-run to update), and git-ignores that folder: in
# .devcontainer/.gitignore when it is under .devcontainer/, else in the repo's
# root .gitignore (created or appended, a line is never duplicated);
# (2) writes Taskfile.yml (including the vendored devcontainer.yml with
# `optional: true`), .devcontainer/devcontainer.json, .devcontainer/.env.example
# and the starter .devcontainer/shutdown-check.sh (see bootstrap/SHUTDOWN.md)
# only if they don't exist, and gitignores .devcontainer/.env; (3) runs
# `task devcontainer:init` and `task devcontainer:up`.
# A repository that vendored into ./bootstrap/ keeps working untouched; a
# re-run vendors into the new folder, prints a migration note and repoints a
# root Taskfile include of exactly ./bootstrap/devcontainer.yml (adding optional: true to that include when it has none).
set -euo pipefail

ref='' path='' source='' docker_path='' no_up='' bootstrap_dir='' no_gitignore=''
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) ref="$2"; shift 2 ;;
    --path) path="$2"; shift 2 ;;
    --source) source="$2"; shift 2 ;;
    --docker-path) docker_path="$2"; shift 2 ;;
    --no-up) no_up=true; shift ;;
    --bootstrap-dir) bootstrap_dir="$2"; shift 2 ;;
    --no-gitignore) no_gitignore=true; shift ;;
    -h | --help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "bootstrap: unknown argument $1" >&2; exit 2 ;;
  esac
done

import_dotenv() { # never overrides variables already in the environment
  [ -f "$1" ] || return 0
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"; value="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="$(printf '%s' "$value" | sed -E "s/^[[:space:]]*//; s/[[:space:]]*$//; s/^(\"(.*)\"|'(.*)')$/\2\3/")"
    if [ -z "${!key+x}" ]; then export "$key=$value"; fi
  done < "$1"
  echo "  loaded    $1"
}

path="${path:-${DEVCONTAINER_BOOTSTRAP_PATH:-$PWD}}"
path="$(cd "$path" && pwd)"
import_dotenv "$path/.env"
import_dotenv "$path/.devcontainer/.env"

ref="${ref:-${DEVCONTAINER_BOOTSTRAP_REF:-main}}"
source="${source:-${DEVCONTAINER_BOOTSTRAP_SOURCE:-https://raw.githubusercontent.com/nabil-becker/devcontainer-features/$ref}}"
docker_path="${docker_path:-${DEVCONTAINER_DOCKER_PATH:-}}"
case "${no_up:-${DEVCONTAINER_BOOTSTRAP_NO_UP:-}}" in 1 | true | yes) no_up=true ;; *) no_up=false ;; esac
[ -n "$docker_path" ] && export DEVCONTAINER_DOCKER_PATH="$docker_path"

default_bootstrap_dir='.devcontainer/cli_bootstrap.ignore'
explicit_dir=false
if [ -n "${bootstrap_dir:-${BOOTSTRAP_DIR:-}}" ]; then explicit_dir=true; fi
bdir="${bootstrap_dir:-${BOOTSTRAP_DIR:-$default_bootstrap_dir}}"
bad_dir() { echo "bootstrap: BOOTSTRAP_DIR '$bdir' $1; give a path relative to the repository root, inside it (for example $default_bootstrap_dir)." >&2; exit 2; }
bdir="${bdir//\\//}"
case "$bdir" in /* | [A-Za-z]:*) bad_dir 'is an absolute path' ;; esac
while :; do
  case "$bdir" in ./*) bdir="${bdir#./}" ;; */) bdir="${bdir%/}" ;; *) break ;; esac
done
case "$bdir" in '' | . | .devcontainer) bad_dir 'would vendor into the repository root or all of .devcontainer' ;; esac
case "$bdir" in .. | ../* | */../* | */..) bad_dir 'escapes the repository (..)' ;; esac
case "no_gitignore:${no_gitignore:-}:${BOOTSTRAP_GITIGNORE:-}" in
  no_gitignore:true:* | no_gitignore::false | no_gitignore::0 | no_gitignore::no) gitignore_bootstrap=false ;;
  *) gitignore_bootstrap=true ;;
esac

# Retry a dropped connection: this script arrives by curl | bash, so it cannot use the
# Features' vendored dcf_curl; same flags as src/common/dcf-curl.sh (--retry-all-errors when
# curl has it, 7.71+, so a TLS reset (35) or a cut transfer (56) is retried too).
curl_retry=(--retry 3 --retry-delay 2 --retry-connrefused)
case "$(curl --help all 2>&1 || true)" in *--retry-all-errors*) curl_retry+=(--retry-all-errors) ;; esac

get_source_file() { # <relative> <destination>
  mkdir -p "$(dirname "$2")"
  case "$source" in
    http://* | https://*) curl "${curl_retry[@]}" -fsSL -o "$2" "$source/$1" ;;
    *) cp -f "$source/$1" "$2" ;;
  esac
}

echo "Bootstrapping $path from $source"
echo "  folder    $bdir/ (vendored launcher and tasks; BOOTSTRAP_DIR overrides)"
[ -n "$docker_path" ] && echo "  engine    DEVCONTAINER_DOCKER_PATH=$docker_path"

# 1. Vendor the devcontainer tasks (always refreshed): "<source path> <dest>".
#    The bash flavour is the devcontainer-cli Feature's own script, vendored
#    next to the PowerShell flavour.
while read -r src dest; do
  dest="${dest/@BDIR@/$bdir}"
  get_source_file "$src" "$path/$dest"
  echo "  vendored  $dest"
done <<'EOF'
bootstrap/devcontainer.yml @BDIR@/devcontainer.yml
bootstrap/host/DevcontainerCli.psm1 @BDIR@/host/DevcontainerCli.psm1
bootstrap/host/Invoke-DevcontainerCli.ps1 @BDIR@/host/Invoke-DevcontainerCli.ps1
bootstrap/host/Initialize-DevcontainerCli.ps1 @BDIR@/host/Initialize-DevcontainerCli.ps1
bootstrap/host/Reset-WslcStorage.ps1 @BDIR@/host/Reset-WslcStorage.ps1
bootstrap/host/Initialize-DevcontainerHomes.ps1 @BDIR@/host/Initialize-DevcontainerHomes.ps1
bootstrap/host/devcontainer-homes.sh @BDIR@/host/devcontainer-homes.sh
src/devcontainer-cli/devcontainer-cli.sh @BDIR@/host/devcontainer-cli.sh
src/devcontainer-cli/dcf-curl.sh @BDIR@/host/dcf-curl.sh
EOF
chmod +x "$path/$bdir/host/devcontainer-cli.sh" "$path/$bdir/host/devcontainer-homes.sh"

# Git-ignore the vendored folder (BOOTSTRAP_GITIGNORE=false skips): a line in
# .devcontainer/.gitignore when the folder is under .devcontainer/, else in the
# repository's root .gitignore. Created if missing, the line appended only when
# absent (with or without the trailing or a leading slash), nothing else touched.
ensure_ignore_line() { # <gitignore file> <line ending in />
  local f="$1" line="$2" bare="${2%/}"
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ] && { grep -qxF "$line" "$f" || grep -qxF "$bare" "$f" || grep -qxF "/$line" "$f" || grep -qxF "/$bare" "$f"; }; then
    echo "  kept      ${f#"$path"/} (already ignores $line)"
    return 0
  fi
  if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then echo >> "$f"; fi
  printf '%s\n' "$line" >> "$f"
  echo "  gitignored $line in ${f#"$path"/}"
}
if $gitignore_bootstrap; then
  case "$bdir" in
    .devcontainer/*) ensure_ignore_line "$path/.devcontainer/.gitignore" "${bdir#.devcontainer/}/" ;;
    *) ensure_ignore_line "$path/.gitignore" "/$bdir/" ;;
  esac
else
  echo "  skipped   git-ignoring $bdir/ (BOOTSTRAP_GITIGNORE=false)"
fi

# 2. Templates, only where nothing exists yet.
while read -r src dest; do
  if [ -e "$path/$dest" ]; then
    echo "  kept      $dest (exists)"
  else
    get_source_file "$src" "$path/$dest"
    if [ "$dest" = Taskfile.yml ]; then # the include names the chosen folder
      sed "s|{{BOOTSTRAP_DIR}}|$bdir|g" "$path/$dest" > "$path/$dest.tmp" && mv -f "$path/$dest.tmp" "$path/$dest"
    fi
    echo "  wrote     $dest"
  fi
done <<'EOF'
bootstrap/Taskfile.yml Taskfile.yml
bootstrap/devcontainer.json .devcontainer/devcontainer.json
bootstrap/env.example .devcontainer/.env.example
bootstrap/shutdown-check.sh .devcontainer/shutdown-check.sh
EOF

if ! grep -qxF '.devcontainer/.env' "$path/.gitignore" 2>/dev/null; then
  printf '\n# devcontainer task settings - may hold host-specific paths\n.devcontainer/.env\n' >> "$path/.gitignore"
  echo "  gitignored .devcontainer/.env"
fi

# Old form: a repository that vendored into ./bootstrap/ keeps working untouched
# until it re-runs the bootstrap; this run vendored into the new folder.
if ! $explicit_dir && [ "$bdir" != bootstrap ] && [ -f "$path/bootstrap/devcontainer.yml" ]; then
  old_include='./bootstrap/devcontainer.yml'
  new_include="./$bdir/devcontainer.yml"
  if grep -Eq "^[[:space:]]*taskfile:[[:space:]]*['\"]?\./bootstrap/devcontainer\.yml['\"]?[[:space:]]*(#.*)?$" "$path/Taskfile.yml"; then
    sed -E "s#^([[:space:]]*taskfile:[[:space:]]*['\"]?)\./bootstrap/devcontainer\.yml#\1$new_include#" "$path/Taskfile.yml" > "$path/Taskfile.yml.tmp" \
      && cat "$path/Taskfile.yml.tmp" > "$path/Taskfile.yml" && rm -f "$path/Taskfile.yml.tmp"
    echo "  repointed Taskfile.yml: taskfile: $old_include -> $new_include (only that value; to undo, change it back)"
    # The vendored folder is git-ignored, so a fresh clone lacks it until the bootstrap ran: the include
    # must be optional. Add `optional: true` to that include block unless the block already has an optional key.
    awk -v target="$new_include" '
      { line[NR] = $0 }
      END {
        for (t = 1; t <= NR; t++) if (line[t] ~ /^[ \t]*taskfile:/ && index(line[t], target) > 0) break
        if (t > NR) { for (i = 1; i <= NR; i++) print line[i]; exit }
        match(line[t], /^[ \t]*/); ind = RLENGTH; pad = substr(line[t], 1, ind)
        has = 0
        for (i = t - 1; i >= 1; i--) { if (line[i] ~ /^[ \t]*(#.*)?$/) continue; match(line[i], /^[ \t]*/); if (RLENGTH < ind) break; if (line[i] ~ /^[ \t]*optional:/) has = 1 }
        for (i = t + 1; i <= NR; i++) { if (line[i] ~ /^[ \t]*(#.*)?$/) continue; match(line[i], /^[ \t]*/); if (RLENGTH < ind) break; if (line[i] ~ /^[ \t]*optional:/) has = 1 }
        for (i = 1; i <= NR; i++) { print line[i]; if (i == t && !has) { print pad "optional: true"; added = 1 } }
        if (added) print "ADDED" > "/dev/stderr"
      }' "$path/Taskfile.yml" > "$path/Taskfile.yml.tmp" 2> "$path/Taskfile.yml.added" || true
    [ -s "$path/Taskfile.yml.tmp" ] && cat "$path/Taskfile.yml.tmp" > "$path/Taskfile.yml"
    if grep -q ADDED "$path/Taskfile.yml.added"; then echo "  added     optional: true to that include (the folder is git-ignored; a fresh clone lacks it until the bootstrap ran)"; fi
    rm -f "$path/Taskfile.yml.tmp" "$path/Taskfile.yml.added"
  fi
  cat <<EOF
MIGRATION: this repository vendored the bootstrap into ./bootstrap/ before; this run vendored into $bdir/.
  - The include in Taskfile.yml should be:  taskfile: $new_include   with optional: true (the folder is git-ignored,
    so a fresh clone lacks it until this bootstrap runs; added above when the include block had no such line).
  - Once the include points at $bdir/, ./bootstrap/ is unused and can be deleted (git rm -r bootstrap).
    Nothing was deleted here, and while the include still names ./bootstrap/devcontainer.yml it keeps working as it was.
EOF
fi

if ! grep -qF "$bdir/devcontainer.yml" "$path/Taskfile.yml" && ! grep -q 'bootstrap/devcontainer\.yml' "$path/Taskfile.yml"; then
  cat >&2 <<EOF
WARNING: Taskfile.yml already exists and does not include the devcontainer tasks. Add (the first run on a fresh
clone is the bootstrap one-liner, because $bdir/ is git-ignored):

  dotenv: ['.env', '.devcontainer/.env']
  includes:
    devcontainer:
      taskfile: ./$bdir/devcontainer.yml
      optional: true
      aliases: [dc]
    features:
      taskfile: /usr/local/share/go-task/features.yml
      optional: true
      flatten: true
EOF
fi

if ! grep -q 'shutdown:check' "$path/Taskfile.yml"; then
  cat >&2 <<'EOF'
NOTE: Taskfile.yml has no shutdown:check task, so devcontainer:stop and :rebuild run no check of this
repository (see bootstrap/SHUTDOWN.md in the collection). To use .devcontainer/shutdown-check.sh, add under tasks:

  shutdown:check:
    desc: 'Shutdown check run by devcontainer:stop and :rebuild inside the container (edit .devcontainer/shutdown-check.sh).'
    cmds:
      - sh .devcontainer/shutdown-check.sh
EOF
fi

# 3. Init, then up.
if ! command -v task >/dev/null 2>&1; then
  echo 'WARNING: Task is not on PATH (https://taskfile.dev/installation). Files are in place; run "task devcontainer:up" once it is.' >&2
  exit 0
fi
cd "$path"
task devcontainer:init
if $no_up; then
  echo 'Skipping "task devcontainer:up" (--no-up / DEVCONTAINER_BOOTSTRAP_NO_UP).'
else
  task devcontainer:up
  echo 'Devcontainer is up. Next: task devcontainer:shell, or Reopen in Container in your editor.'
fi
