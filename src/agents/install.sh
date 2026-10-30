#!/usr/bin/env bash
# Installs the agents Feature: the `agents` command (the agent list, the kinds, the verbs and
# the fallbacks; also the postStartCommand `agents up --post-start`) and the Feature Taskfile.
# Nothing is downloaded, so there is nothing to verify. No adapter is installed here: each CLI
# Feature brings its own (agent-adapter-<cli>; the claude-code Feature has agent-adapter-claude).
#
# State: none that must survive a rebuild. The agents live in each CLI's own state (claude-code's
# volume). /var/lib/devcontainer-features/agents holds the once-per-container-start markers used
# when an adapter cannot list its sessions, and leases/ (2.0), one folder per stateful agent that
# runs. It is deliberately not a volume (NFR-1 exception, NOTES "State"): a lease that survived a
# rebuild would be stale by definition, and markers and leases both record the container start,
# so a stale one never counts.
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
# The sessionName option (2.1): the template of the session names, read by `agents` when no
# AGENTS_SESSION_NAME, .env or task variable says otherwise.
session_name="${SESSIONNAME:-}"
[ -n "$session_name" ] || session_name='{handle}'
printf '%s\n' "$session_name" > /usr/local/share/agents-feature/session-name
chmod 0644 /usr/local/share/agents-feature/session-name
# Any user writes their markers here; the sticky bit keeps users out of each other's.
mkdir -p /var/lib/devcontainer-features/agents
chmod 1777 /var/lib/devcontainer-features/agents
# The leases: no sticky bit, so a dead holder owned by another user (root at post-start, the
# remote user in a terminal) can be taken over.
mkdir -p /var/lib/devcontainer-features/agents/leases
chmod 0777 /var/lib/devcontainer-features/agents/leases
echo "agents: installed agents ${version:-unknown}"

# ---------------------------------------------------- Feature Taskfile ----
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/agents.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
