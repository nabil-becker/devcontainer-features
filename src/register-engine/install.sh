#!/usr/bin/env bash
# The register-engine Feature (SPEC.md, README.md), a building block on the sign-packet Feature
# (AOF ADR 0028). Installs:
#   /usr/local/lib/register-engine/registerengine/   the engine: entries, rosters, reading, stores, sync, views
#   /usr/local/lib/register-engine/signpacket/       sign-packet's library, this Feature's own verbatim copy
#   /usr/local/lib/register-engine/types.d/          where the capability Features put their register types
#   /usr/local/lib/register-engine/SPEC.md           the register's specification
#   /usr/local/bin/register-engine                   the command (tasks call it): version, check, types, verify
#   /usr/local/share/go-task/includes.d/register-engine.yml   the Taskfile (installTaskfile)
# Options arrive as upper-cased environment variables: INSTALLTASKFILE.
# DESTDIR (tests only) installs under another root, as a user, and skips the system steps.
set -euo pipefail

INSTALLTASKFILE="${INSTALLTASKFILE:-true}"
DESTDIR="${DESTDIR:-}"

if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then
  echo "register-engine: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
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
  echo "register-engine: needs Python 3.11 or later (add ghcr.io/devcontainers/features/python, or a newer base image)." >&2
  exit 1
fi

lib="$DESTDIR/usr/local/lib/register-engine"
bin="$DESTDIR/usr/local/bin"
mkdir -p "$lib/registerengine" "$lib/signpacket" "$lib/types.d" "$bin"
chmod 0755 "$lib" "$lib/types.d"
rm -f "$lib"/registerengine/*.py "$lib"/signpacket/*.py   # replaced whole; types.d is the capabilities' own
for f in "$feature_dir"/registerengine/*.py; do install -m 0644 "$f" "$lib/registerengine/"; done
# On sign-packet's packets (AOF ADR 0024), through this Feature's own copy of its library (signpacket/,
# kept equal to src/sign-packet by `task signpacket:sync`): the command finds it first, so this Feature
# needs no other one installed, in any order, and a separate sign-packet Feature never changes it.
for f in "$feature_dir"/signpacket/*.py; do install -m 0644 "$f" "$lib/signpacket/"; done
install -m 0644 "$feature_dir/SPEC.md" "$lib/SPEC.md"
install -m 0755 "$feature_dir/bin/register-engine" "$bin/register-engine"

includes="$DESTDIR/usr/local/share/go-task/includes.d"
if [ "$INSTALLTASKFILE" = "true" ]; then
  mkdir -p "$includes"
  install -m 0644 "$feature_dir/taskfile.yml" "$includes/register-engine.yml"
  if [ -z "$DESTDIR" ] && command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
else
  rm -f "$includes/register-engine.yml"
fi

echo "register-engine $version installed (taskfile: $INSTALLTASKFILE)"
