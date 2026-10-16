#!/bin/bash
# Auto-generated scenario: the devhost Feature with default options
# (installTaskfile=true). Run with:
#   devcontainer features test -f devhost --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib
# shellcheck source=test/devhost/functional.sh
source "$(dirname "$0")/functional.sh"

check "python3 on PATH" python3 --version
check "flock on PATH" command -v flock
check "share folder installed" test -d /usr/local/share/devhost/bin
check "version recorded" bash -c "grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' /usr/local/share/devhost/VERSION"
# The entrypoints this half of the Feature ships, plus whatever else landed as devhost-*
# (the Python half's briefing, report, costs, adr, verify, init): every one on PATH,
# executable and root-owned.
for name in run-job redact condense setup; do
  check "devhost-$name on PATH" command -v "devhost-$name"
done
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "every devhost-* tool is executable and root-owned" bash -c 'for f in /usr/local/bin/devhost-*; do [ -x "$f" ] && [ "$(stat -c %U "$f")" = root ] || { echo "bad: $f"; exit 1; }; done'
for job in scribe secretary librarian tester; do
  check "job $job installed" test -f "/usr/local/share/devhost/jobs/$job/job.sh"
done
check "briefs name no person" bash -c "! grep -rEiw 'nabil|justin|dsnp' /usr/local/share/devhost/jobs"
check "dcf-persist on PATH" command -v dcf-persist
check "DEVHOST_STATE points at the Feature's state dir" bash -c "[ \"\$DEVHOST_STATE\" = /var/lib/devcontainer-features/devhost ]"
# The Feature's volume is mounted in `devcontainer features test` (volume);
# any backing is accepted so the check is not engine-specific.
check "setup makes the state dir usable and reports it" bash -c "devhost-setup | grep -Eq '^devhost: /var/lib/devcontainer-features/devhost \((volume|bind|image), writable\)\$' && [ -w /var/lib/devcontainer-features/devhost ]"
check "setup is idempotent and never fatal" bash -c "devhost-setup >/dev/null; devhost-setup | grep -q '^devhost-setup: next step: task devhost:init'"
check "condense reads a transcript" bash -c "printf '{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Stake for the scribe: the thing needs an entry.\"}}\n' > /tmp/t.jsonl && devhost-condense /tmp/t.jsonl 0 2>/dev/null | grep -q '^STAKE for scribe'"
check "redact replaces a listed name and a forbidden word" bash -c "d=\$(mktemp -d) && mkdir -p \$d/.claude \$d/.devhost && echo '{}' > \$d/.claude/settings.json && echo Zebulonica > \$d/.devhost/redact-names.txt && [ \"\$(cd \$d && DEVHOST_FORBIDDEN_WORDS=Acme echo \"Zebulonica's AcmeCorp\" | DEVHOST_FORBIDDEN_WORDS=Acme devhost-redact)\" = \"the Operator's the OperatorCorp\" ]"
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/devhost.yml

devhost_functional

reportResults
