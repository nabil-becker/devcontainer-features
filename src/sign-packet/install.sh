#!/usr/bin/env bash
# The sign-packet Feature (SPEC.md, README.md). Installs:
#   /usr/local/lib/sign-packet/signpacket/   the library: packets, their checks, their order
#   /usr/local/lib/sign-packet/SPEC.md       the packet's specification
#   /usr/local/bin/sign-packet               the one command (tasks call it)
#   /usr/local/bin/sign-packet-setup         the post-create hook: the state folder, this instance's id
#   /usr/local/libexec/sign-packet/dcf-persist   the state-folder helper, this Feature's own copy
#   /usr/local/share/go-task/includes.d/sign-packet.yml   the Taskfile (installTaskfile)
# Options arrive as upper-cased environment variables: INSTALLTASKFILE.
# DESTDIR (tests only) installs under another root, as a user, and skips the system steps.
set -euo pipefail

INSTALLTASKFILE="${INSTALLTASKFILE:-true}"
DESTDIR="${DESTDIR:-}"

if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then
  echo "sign-packet: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"
version="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$feature_dir/devcontainer-feature.json" | head -n1)"

need_python() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'
}
if [ -z "$DESTDIR" ] && { ! need_python || ! command -v ssh-keygen >/dev/null 2>&1; }; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends python3 openssh-client
    rm -rf /var/lib/apt/lists/*
  fi
fi
if ! need_python; then
  echo "sign-packet: needs Python 3.11 or later (add ghcr.io/devcontainers/features/python, or a newer base image)." >&2
  exit 1
fi
if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "sign-packet: needs ssh-keygen (OpenSSH 8.1 or later), and apt-get is not available to install it." >&2
  exit 1
fi

lib="$DESTDIR/usr/local/lib/sign-packet"
bin="$DESTDIR/usr/local/bin"
libexec="$DESTDIR/usr/local/libexec/sign-packet"
mkdir -p "$lib/signpacket" "$bin" "$libexec"
rm -f "$lib"/signpacket/*.py
for f in "$feature_dir"/signpacket/*.py; do install -m 0644 "$f" "$lib/signpacket/"; done
install -m 0644 "$feature_dir/SPEC.md" "$lib/SPEC.md"
install -m 0755 "$feature_dir/bin/sign-packet" "$bin/sign-packet"
install -m 0755 "$feature_dir/sign-packet-setup.sh" "$bin/sign-packet-setup"
install -m 0755 "$feature_dir/dcf-persist.sh" "$libexec/dcf-persist"

includes="$DESTDIR/usr/local/share/go-task/includes.d"
if [ "$INSTALLTASKFILE" = "true" ]; then
  mkdir -p "$includes"
  install -m 0644 "$feature_dir/taskfile.yml" "$includes/sign-packet.yml"
  if [ -z "$DESTDIR" ] && command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
else
  rm -f "$includes/sign-packet.yml"
fi

echo "sign-packet $version installed (taskfile: $INSTALLTASKFILE)"
