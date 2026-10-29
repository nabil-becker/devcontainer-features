#!/usr/bin/env bash
# Docker-free test that the PSScriptAnalyzer step (.github/scripts/Invoke-PSScriptAnalyzer.ps1)
# checks tracked and non-ignored files only: in a scratch repository a clean tracked script
# passes, a bad script in a git-ignored folder is not scanned, and a bad tracked script fails.
# Fails on the earlier behaviour (a recursive scan of the folder tree). Part of `task lint`.
# SCRIPT points the test at another copy of the script.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
script="${SCRIPT:-$here/../../.github/scripts/Invoke-PSScriptAnalyzer.ps1}"
settings="$here/../../.github/PSScriptAnalyzerSettings.psd1"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.github" "$T/material.ignore"
cp "$settings" "$T/.github/"
printf 'material.ignore/\n' > "$T/.gitignore"
printf 'Write-Output "fine"\n' > "$T/good.ps1"
# A finding under the settings: an unused-parameter-style Error/Warning (Invoke-Expression).
printf 'Invoke-Expression "1"\n' > "$T/material.ignore/bad.ps1"
git -C "$T" init -q
git -C "$T" add -A

pass=0 fail=0
check() { # <name> <expected exit> <actual exit> <output>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected exit $2, got $3)"; echo "$4"; fi
}

out="$(pwsh -NoLogo -NoProfile -File "$script" -Root "$T" 2>&1)"; rc=$?
check "a bad script in a git-ignored folder is not scanned" 0 "$rc" "$out"
case "$out" in *"2 files, 0 findings"*) pass=$((pass + 1)); echo "ok   - only the tracked files scanned (script + settings)";;
  *) fail=$((fail + 1)); echo "FAIL - expected '2 files, 0 findings', got: $out";; esac

printf 'Invoke-Expression "1"\n' > "$T/tracked-bad.ps1"
git -C "$T" add -A
out="$(pwsh -NoLogo -NoProfile -File "$script" -Root "$T" 2>&1)"; rc=$?
check "a bad tracked script still fails" 1 "$rc" "$out"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
