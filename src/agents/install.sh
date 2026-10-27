#!/usr/bin/env bash
# Installs the agents Feature: the `agents` command (the agent list, the kinds, the verbs and
# the fallbacks; also the postStartCommand `agents up --post-start`) and the Feature Taskfile.
# Nothing is downloaded, so there is nothing to verify. No adapter is installed here: each CLI
# Feature brings its own (agent-adapter-<cli>; the claude-code Feature has agent-adapter-claude).
#
# State: none that must survive a rebuild. The agents live in each CLI's own state (claude-code's
# volume). /var/lib/devcontainer-features/agents holds only the once-per-container-start markers
# used when an adapter cannot list its sessions; it is deliberately not a volume, and the markers
# are keyed by the container start, so a stale one never counts.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "agents: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"
version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$feature_dir/devcontainer-feature.json" | head -n 1)"

install -m 0755 "$feature_dir/agents.sh" /usr/local/bin/agents
mkdir -p /usr/local/share/agents-feature
printf '%s\n' "${version:-unknown}" > /usr/local/share/agents-feature/version
chmod 0644 /usr/local/share/agents-feature/version
# Any user writes their markers here; the sticky bit keeps users out of each other's.
mkdir -p /var/lib/devcontainer-features/agents
chmod 1777 /var/lib/devcontainer-features/agents
echo "agents: installed agents ${version:-unknown}"

# ---------------------------------------------------- Feature Taskfile ----
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/agents.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
