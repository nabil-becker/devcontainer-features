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
#
# What it does: (1) vendors bootstrap/devcontainer.yml, bootstrap/host/* and
# the devcontainer-cli Feature's devcontainer-cli.sh into ./bootstrap/
# (always refreshed - re-run to update); (2) writes Taskfile.yml,
# .devcontainer/devcontainer.json, .devcontainer/env_mnt/.gitignore and
# .devcontainer/.env.example only if they don't exist, and gitignores
# .devcontainer/.env; (3) runs `task devcontainer:init` and `task devcontainer:up`.
set -euo pipefail

ref='' path='' source='' docker_path='' no_up=''
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) ref="$2"; shift 2 ;;
    --path) path="$2"; shift 2 ;;
    --source) source="$2"; shift 2 ;;
    --docker-path) docker_path="$2"; shift 2 ;;
    --no-up) no_up=true; shift ;;
    -h | --help) sed -n '2,25p' "$0"; exit 0 ;;
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

get_source_file() { # <relative> <destination>
  mkdir -p "$(dirname "$2")"
  case "$source" in
    http://* | https://*) curl -fsSL -o "$2" "$source/$1" ;;
    *) cp -f "$source/$1" "$2" ;;
  esac
}

echo "Bootstrapping $path from $source"
[ -n "$docker_path" ] && echo "  engine    DEVCONTAINER_DOCKER_PATH=$docker_path"

# 1. Vendor the devcontainer tasks (always refreshed): "<source path> <dest>".
#    The bash flavour is the devcontainer-cli Feature's own script, vendored
#    next to the PowerShell flavour.
while read -r src dest; do
  get_source_file "$src" "$path/$dest"
  echo "  vendored  $dest"
done <<'EOF'
bootstrap/devcontainer.yml bootstrap/devcontainer.yml
bootstrap/host/DevcontainerCli.psm1 bootstrap/host/DevcontainerCli.psm1
bootstrap/host/Invoke-DevcontainerCli.ps1 bootstrap/host/Invoke-DevcontainerCli.ps1
bootstrap/host/Initialize-DevcontainerCli.ps1 bootstrap/host/Initialize-DevcontainerCli.ps1
bootstrap/host/Reset-WslcStorage.ps1 bootstrap/host/Reset-WslcStorage.ps1
src/devcontainer-cli/devcontainer-cli.sh bootstrap/host/devcontainer-cli.sh
EOF
chmod +x "$path/bootstrap/host/devcontainer-cli.sh"

# 2. Templates, only where nothing exists yet.
while read -r src dest; do
  if [ -e "$path/$dest" ]; then
    echo "  kept      $dest (exists)"
  else
    get_source_file "$src" "$path/$dest"
    echo "  wrote     $dest"
  fi
done <<'EOF'
bootstrap/Taskfile.yml Taskfile.yml
bootstrap/devcontainer.json .devcontainer/devcontainer.json
bootstrap/env_mnt.gitignore .devcontainer/env_mnt/.gitignore
bootstrap/env.example .devcontainer/.env.example
EOF

if ! grep -qxF '.devcontainer/.env' "$path/.gitignore" 2>/dev/null; then
  printf '\n# devcontainer task settings - may hold host-specific paths\n.devcontainer/.env\n' >> "$path/.gitignore"
  echo "  gitignored .devcontainer/.env"
fi

if ! grep -q 'bootstrap/devcontainer\.yml' "$path/Taskfile.yml"; then
  cat >&2 <<'EOF'
WARNING: Taskfile.yml already exists and does not include the devcontainer tasks. Add:

  dotenv: ['.env', '.devcontainer/.env']
  includes:
    devcontainer:
      taskfile: ./bootstrap/devcontainer.yml
    features:
      taskfile: /usr/local/share/go-task/features.yml
      optional: true
      flatten: true
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
