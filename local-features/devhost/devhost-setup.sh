#!/usr/bin/env bash
# devhost-setup: the devhost Feature's postCreateCommand, run as the remote user from the
# workspace folder after every create/rebuild; also behind `task devhost:setup`.
# Idempotent, never fatal: a problem is reported, not allowed to abort the rest of
# post-create.
#
# Makes the job state directory usable (DEVHOST_STATE: the Feature's named volume at
# /var/lib/devcontainer-features/devhost, or a repo's bind mount over it; mounts arrive
# owned by root) through dcf-persist, then says what this container can do: whether claude
# and python3 are there, whether the repository in the current directory is wired (hooks
# in .claude/settings.json, a ledger folder) and what the next step is.
set -u

state="${DEVHOST_STATE:-/var/lib/devcontainer-features/devhost}"
dcf-persist --label devhost "$state"

if command -v claude >/dev/null 2>&1; then
  echo "devhost-setup: claude $(claude --version 2>/dev/null | head -n1 || echo present) (the backs run it headless)"
else
  echo "devhost-setup: claude not on PATH (add the claude-code Feature; the backs do nothing without it)"
fi
if command -v python3 >/dev/null 2>&1; then
  echo "devhost-setup: $(python3 --version 2>&1)"
else
  echo "devhost-setup: python3 not on PATH (the condenser, the guards and the tools need it)"
fi

root="${DEVHOST_ROOT:-$PWD}"
ledger="${DEVHOST_LEDGER_DIR:-docs/ledger}"
case "$ledger" in /*) ;; *) ledger="$root/$ledger" ;; esac
wired=1
if [ -f "$root/.claude/settings.json" ] && grep -q 'devhost-run-job' "$root/.claude/settings.json" 2>/dev/null; then
  echo "devhost-setup: hooks present in .claude/settings.json ($(grep -o 'devhost-run-job [a-z]*' "$root/.claude/settings.json" | sort -u | cut -d' ' -f2 | paste -sd, -))"
else
  echo "devhost-setup: no devhost hooks in ${root#"$PWD"/}/.claude/settings.json"; wired=0
fi
if [ -d "$ledger" ]; then
  echo "devhost-setup: ledger at ${ledger#"$root"/} ($(find "$ledger" -maxdepth 1 -name '*.md' | wc -l) files)"
else
  echo "devhost-setup: no ledger folder at ${ledger#"$root"/}"; wired=0
fi
if [ "$wired" = 1 ]; then
  echo "devhost-setup: ready; start the host session with claude-host (task claude-code:host)"
else
  echo "devhost-setup: next step: task devhost:init (scaffolds the hooks, the ledger, the backlog and the lexicon)"
fi
exit 0
