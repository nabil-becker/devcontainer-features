#!/usr/bin/env bash
# Installs Task (https://taskfile.dev). Feature options arrive as upper-cased
# environment variables (see devcontainer-feature.json): VERSION.
set -euo pipefail

VERSION="${VERSION:-latest}"

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
  VERSION="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/go-task/task/releases/latest | sed -E 's#.*/tag/v?##')"
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
curl -fsSL -o "$tmp/$asset" "$base_url/$asset"
curl -fsSL -o "$tmp/task_checksums.txt" "$base_url/task_checksums.txt"
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
