#!/usr/bin/env bash
# Installs phi-check: a linter-style command that refuses files holding
# protected health information (see NOTES.md). It is one Python 3 script and
# one importable module of patterns, both standard library only, so nothing
# is downloaded and there is nothing to verify or pin: the Feature's version
# is the tool's version. Python comes from the dependsOn on the official
# python Feature (os-provided, no tools); a missing python3 is a loud warning
# rather than a failure, so the Feature still installs on a tool that
# ignores dependsOn. Feature options arrive as upper-cased environment
# variables (see devcontainer-feature.json): EXCEPTIONS.
set -euo pipefail

EXCEPTIONS="${EXCEPTIONS:-.phi-exceptions.txt}"

if [ "$(id -u)" -ne 0 ]; then
  echo "phi-check: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

case "$EXCEPTIONS" in
  '' | *$'\n'*) echo "phi-check: the exceptions option must be one non-empty line." >&2; exit 1 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "phi-check: WARNING - python3 not found; this Feature's dependsOn on ghcr.io/devcontainers/features/python:1 should have installed it (check the build log for that Feature). phi-check is installed anyway but cannot run until python3 is on PATH." >&2
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"
share=/usr/local/share/phi-check
mkdir -p "$share"
install -m 0644 "$feature_dir/phi_patterns.py" "$share/phi_patterns.py"
install -m 0755 "$feature_dir/phi-check.py" /usr/local/bin/phi-check
# The default exceptions file name, read by phi-check (PHI_CHECK_EXCEPTIONS overrides it).
printf '%s\n' "$EXCEPTIONS" > "$share/exceptions-default"
chmod 0644 "$share/exceptions-default"

if command -v python3 >/dev/null 2>&1; then
  echo "phi-check: $(/usr/local/bin/phi-check --version) (module at $share/phi_patterns.py)"
else
  echo "phi-check: installed at /usr/local/bin/phi-check (python3 missing)"
fi

# ---------------------------------------------------- Feature Taskfile ----
# Drop this Feature's taskfile.yml where the go-task Feature's registry picks
# it up (namespace = Feature id), and refresh the registry if go-task is
# already installed; otherwise go-task refreshes it when it installs. See
# the go-task Feature README for the one-line root Taskfile include.
if [ "${INSTALLTASKFILE:-true}" = "true" ]; then
  includes_d=/usr/local/share/go-task/includes.d
  mkdir -p "$includes_d"
  install -m 0644 "$(cd "$(dirname "$0")" && pwd)/taskfile.yml" "$includes_d/phi-check.yml"
  if command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
fi
