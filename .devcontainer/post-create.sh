#!/usr/bin/env bash
# postCreateCommand for this repository's devcontainer (see devcontainer.json).
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)

# The checkout is bind-mounted with a foreign owner; git refuses it otherwise.
# (The git Feature's post-create hook does this once it is enabled in
# devcontainer.json; until then, by hand.)
git config --global --add safe.directory "$repo"

# PSScriptAnalyzer for `task lint` (same as the Lint workflow).
if ! pwsh -NoLogo -NoProfile -Command 'if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) { exit 1 }' >/dev/null 2>&1; then
  pwsh -NoLogo -NoProfile -Command 'Install-Module PSScriptAnalyzer -Scope CurrentUser -Force'
fi

# Repo git conventions (hooks for the DCO sign-off, `git cs` alias).
(cd "$repo" && task repo:setup)

echo "post-create: done. task $(task --version), devcontainer $(devcontainer --version), shellcheck $(shellcheck --version | sed -n 's/^version: //p')"
