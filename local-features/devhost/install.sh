#!/usr/bin/env bash
# Installs the devhost way of working: the backs' runner and jobs, the name guard, the
# condenser, the Python tools (briefing, cost report, ADR, verify, init) and the post-create
# setup. Feature options arrive as upper-cased environment variables (see
# devcontainer-feature.json): INSTALLTASKFILE.
#
# Layout: everything under this folder's share/ goes to /usr/local/share/devhost/ as is
# (bin/, jobs/, python/), and every file under share/bin/entrypoints/<name> becomes
# /usr/local/bin/devhost-<name> - a small bash script that execs the real file - so a tool
# added to either half of the Feature is installed without this script knowing its name.
#
# State: devcontainer-feature.json points DEVHOST_STATE at
# /var/lib/devcontainer-features/devhost and mounts a named volume there, so the jobs'
# offsets, logs and metrics survive rebuilds and never land in the checkout. That target
# exists only once the container runs; nothing here writes to it (the post-create hook does).
set -euo pipefail

INSTALLTASKFILE="${INSTALLTASKFILE:-true}"

if [ "$(id -u)" -ne 0 ]; then
  echo "devhost: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

# python3 (standard library only) runs the condenser, the guards and the tools; flock
# (util-linux) keeps two runs of one job apart. Both are in every Debian/Ubuntu base image
# this collection targets; installed only when missing.
missing=()
command -v python3 >/dev/null 2>&1 || missing+=(python3)
command -v flock >/dev/null 2>&1 || missing+=(util-linux)
if [ ${#missing[@]} -gt 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}"
    rm -rf /var/lib/apt/lists/*
  else
    echo "devhost: ${missing[*]} missing and apt-get is unavailable." >&2
    exit 1
  fi
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"
share=/usr/local/share/devhost

# Replace, never merge: a re-run (or a newer version) must not keep files the Feature no
# longer ships.
rm -rf "$share"
mkdir -p "$share"
cp -r "$feature_dir/share/." "$share/"
chmod -R a+rX "$share"
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$feature_dir/devcontainer-feature.json" > "$share/VERSION"

# Stale wrappers from an earlier version go first, so the set on PATH is exactly what this
# version ships.
for old in /usr/local/bin/devhost-*; do
  [ -f "$old" ] && grep -qs '^# devhost-' "$old" && rm -f "$old"
done
if [ -d "$share/bin/entrypoints" ]; then
  for entry in "$share/bin/entrypoints"/*; do
    [ -f "$entry" ] || continue
    install -m 0755 "$entry" "/usr/local/bin/devhost-$(basename "$entry")"
  done
fi
install -m 0755 "$feature_dir/devhost-setup.sh" /usr/local/bin/devhost-setup
# dcf-persist is the shared state-directory helper the hook calls (verbatim copy of
# src/common/dcf-persist.sh; every Feature of this collection installs the same file).
install -m 0755 "$feature_dir/dcf-persist.sh" /usr/local/bin/dcf-persist

echo "devhost: $(cat "$share/VERSION") at $share ($(python3 --version 2>&1); $(for w in /usr/local/bin/devhost-*; do basename "$w"; done | paste -sd' ' -))"

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/devhost.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
