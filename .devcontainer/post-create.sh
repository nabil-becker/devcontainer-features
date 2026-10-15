#!/usr/bin/env bash
# postCreateCommand for this repository's devcontainer (see devcontainer.json).
# The Features' own hooks ran before this (git-setup: safe.directory for the
# checkout and its bind-mounted git dir, core.hooksPath; claude-code-setup,
# gh-setup: their state directories), so only what is specific to this repo
# is left. Idempotent.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)

# PSScriptAnalyzer for `task lint` (same as the Lint workflow).
if ! pwsh -NoLogo -NoProfile -Command 'if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { exit 1 }' >/dev/null 2>&1; then
  pwsh -NoLogo -NoProfile -Command 'Install-Module PSScriptAnalyzer -Scope CurrentUser -Force'
fi

# Repo git conventions (hooks for the DCO sign-off, `git cs` alias).
(cd "$repo" && task repo:setup)

# Report what the container can see, so a broken mount shows up at once.
echo "--- post-create check ---"
echo "task $(task --version), devcontainer $(devcontainer --version), shellcheck $(shellcheck --version | sed -n 's/^version: //p')"
echo "claude $(claude --version 2>/dev/null | head -1 || echo 'not installed'), gh $(gh --version | head -1 | cut -d' ' -f3)"
if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "git: ok ($(git -C "$repo" rev-parse --abbrev-ref HEAD); hooks: $(git -C "$repo" config core.hooksPath))"
else
  echo "git: NOT AVAILABLE (is the git-dir mount present?)"
fi
if docker info >/dev/null 2>&1; then echo "docker: daemon up (task test works here)"; else echo "docker: daemon NOT reachable (wslc has no --privileged; task test needs Docker Desktop or CI)"; fi
