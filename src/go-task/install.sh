#!/usr/bin/env bash
# Installs Task (https://taskfile.dev). Feature options arrive as upper-cased
# environment variables (see devcontainer-feature.json): VERSION.
set -euo pipefail

# Every download goes through dcf_curl (dcf-curl.sh, the collection's retry helper, vendored from
# src/common): curl with --retry and, on curl 7.71+, --retry-all-errors.
# shellcheck source=src/go-task/dcf-curl.sh
. "$(cd "$(dirname "$0")" && pwd)/dcf-curl.sh"

VERSION="${VERSION:-latest}"
TASKALIASES="${TASKALIASES:-false}"
TEAMALIASESFILE="${TEAMALIASESFILE:-.devcontainer/task-aliases.yml}"
YQVERSION="${YQVERSION:-4.54.1}"

if [ "$(id -u)" -ne 0 ]; then
  echo "go-task: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl ca-certificates)
command -v tar >/dev/null 2>&1 || missing+=(tar)
if [ "${#missing[@]}" -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
    rm -rf /var/lib/apt/lists/*
  else
    echo "go-task: missing ${missing[*]} and no apt-get to install them." >&2
    exit 1
  fi
fi

case "$(uname -m)" in
  x86_64 | amd64) task_arch=amd64 ;;
  aarch64 | arm64) task_arch=arm64 ;;
  armv7l) task_arch=arm ;;
  *)
    echo "go-task: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac

# Resolve "latest" through the GitHub redirect rather than the API (no token,
# no rate limit): releases/latest 302s to releases/tag/v<version>.
if [ "$VERSION" = "latest" ]; then
  VERSION="$(dcf_curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/go-task/task/releases/latest | sed -E 's#.*/tag/v?##')"
fi
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "go-task: could not resolve a Task version from '$VERSION'" >&2
  exit 1
fi

base_url="https://github.com/go-task/task/releases/download/v${VERSION}"
asset="task_linux_${task_arch}.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "go-task: downloading Task v${VERSION} (${asset})..."
dcf_curl -fsSL -o "$tmp/$asset" "$base_url/$asset"
dcf_curl -fsSL -o "$tmp/task_checksums.txt" "$base_url/task_checksums.txt"
(cd "$tmp" && grep " ${asset}\$" task_checksums.txt | sha256sum -c -)

mkdir -p "$tmp/task"
tar -xzf "$tmp/$asset" -C "$tmp/task"
install -m 0755 "$tmp/task/task" /usr/local/bin/task

# Shell completions ship in the release tarball.
if [ -f "$tmp/task/completion/bash/task.bash" ]; then
  install -D -m 0644 "$tmp/task/completion/bash/task.bash" /etc/bash_completion.d/task
fi
if [ -f "$tmp/task/completion/zsh/_task" ]; then
  install -D -m 0644 "$tmp/task/completion/zsh/_task" /usr/local/share/zsh/site-functions/_task
fi

/usr/local/bin/task --version

# ------------------------------------------------------------ team aliases ----
# Opt-in (taskAliases): the generator (task-aliases), a private sha256-verified yq to read the
# alias file and Task's JSON listing, the place the generated Taskfile is written, and the marker
# that makes task-features-registry include it in features.yml. docs/proposals/task-aliases.md.
share=/usr/local/share/go-task
state=/var/lib/devcontainer-features/go-task
if [ "$TASKALIASES" = "true" ]; then
  case "$(uname -m)" in
    x86_64 | amd64) yq_arch=amd64 ;;
    aarch64 | arm64) yq_arch=arm64 ;;
    armv7l) yq_arch=arm ;;
    *)
      echo "go-task: no yq build for $(uname -m); turn taskAliases off" >&2
      exit 1
      ;;
  esac
  if [ "$YQVERSION" = "latest" ]; then
    YQVERSION="$(dcf_curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/mikefarah/yq/releases/latest | sed -E 's#.*/tag/v?##')"
  fi
  YQVERSION="${YQVERSION#v}"
  if [[ ! "$YQVERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "go-task: could not resolve a yq version from '$YQVERSION'" >&2
    exit 1
  fi
  yq_url="https://github.com/mikefarah/yq/releases/download/v${YQVERSION}"
  yq_asset="yq_linux_${yq_arch}"
  echo "go-task: downloading yq v${YQVERSION} (${yq_asset}) for the task aliases..."
  dcf_curl -fsSL -o "$tmp/$yq_asset" "$yq_url/$yq_asset"
  dcf_curl -fsSL -o "$tmp/yq_checksums" "$yq_url/checksums"
  dcf_curl -fsSL -o "$tmp/yq_checksums_order" "$yq_url/checksums_hashes_order"
  # yq's checksums file has one column per hash type; the order file names them.
  col="$(grep -nxF SHA-256 "$tmp/yq_checksums_order" | cut -d: -f1)"
  want="$(awk -v a="$yq_asset" -v c="$((col + 1))" '$1 == a { print $c }' "$tmp/yq_checksums")"
  if [ -z "$col" ] || [ -z "$want" ]; then
    echo "go-task: no sha256 for $yq_asset in yq v${YQVERSION}'s checksums" >&2
    exit 1
  fi
  echo "$want  $tmp/$yq_asset" | sha256sum -c -
  mkdir -p "$share"
  install -m 0755 "$tmp/$yq_asset" "$share/yq"
  "$share/yq" --version
  feature_dir="$(cd "$(dirname "$0")" && pwd)"
  install -m 0755 "$feature_dir/task-aliases" /usr/local/bin/task-aliases
  printf 'team=%s\n' "$TEAMALIASESFILE" > "$share/aliases.conf"
  : > "$share/aliases.enabled"
  # The generated Taskfile: written by the user at run time, so the folder belongs to the remote
  # user (root when there is none), owner-only: every task run includes it (proposal, section 8).
  mkdir -p "$state"
  if [ ! -e "$state/aliases.yml" ]; then
    printf "# Generated by task-aliases (go-task Feature). Do not edit.\nversion: '3'\ntasks: {}\n" > "$state/aliases.yml"
  fi
  if [ -n "${_REMOTE_USER:-}" ] && [ "${_REMOTE_USER}" != root ] && id "${_REMOTE_USER}" >/dev/null 2>&1; then
    chown -R "${_REMOTE_USER}" "$state"
  fi
  chmod 0700 "$state"
  chmod 0600 "$state/aliases.yml"
else
  rm -f "$share/aliases.enabled"
fi

# ------------------------------------------------ Feature Taskfile registry ----
# Other Features from this collection drop a taskfile.yml into includes.d/;
# task-features-registry turns that folder into one includable Taskfile. It
# is installed unconditionally (a tiny sh script) and run now, so Features
# that installed before go-task are picked up; Features installing later run
# it themselves. See NOTES.md for the root Taskfile include.
feature_dir="$(cd "$(dirname "$0")" && pwd)"
install -m 0755 "$feature_dir/task-features-registry" /usr/local/bin/task-features-registry
mkdir -p /usr/local/share/go-task/includes.d
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  install -m 0644 "$feature_dir/taskfile.yml" /usr/local/share/go-task/includes.d/go-task.yml
fi
task-features-registry
