#!/bin/bash
# Scenario 'participants' (see scenarios.json): claude-code and copilot both with participants: true
# leave ONE copy of the participant component in /usr/local/lib/dcf-participant, in whichever
# order they install; the agents command calls agent-adapter-copilot for an entry with cli: copilot
# and never reaches for claude; copilot has no background mode, so a resident entry falls back to on-demand.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

lib=/usr/local/lib/dcf-participant
check "one copy of the component" bash -c "[ \"\$(find /usr/local/lib -maxdepth 1 -name 'dcf-participant*' | wc -l)\" = 1 ]"
check "agents on PATH points into it" bash -c "[ \"\$(readlink -f \"\$(command -v agents)\")\" = $lib/agents.sh ]"
check "no second agents command" bash -c "[ \"\$(type -ap agents | wc -l)\" = 1 ]"
check "one installer recorded" bash -c "[ \"\$(wc -l < $lib/installed-by)\" = 1 ] && grep -qxE 'copilot|claude-code' $lib/installed-by"
check "one agents include" bash -c "[ \"\$(grep -c '^  agents:' /usr/local/share/go-task/features.yml)\" = 1 ]"
check "both adapters are there" bash -c "command -v agent-adapter-claude && command -v agent-adapter-copilot"
check "claude-code's post-start marker is set, copilot has no post-start hook" bash -c "test -f /usr/local/share/claude-code/participants && ! command -v copilot-post-start"

# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
setup='t=$(mktemp -d); mkdir -p "$t/repo/.devcontainer" "$t/bin"
printf "participants:\n  - name: pilot\n    cli: copilot\n    kind: on-demand\n  - name: dozer\n    cli: copilot\n    kind: resident\n" > "$t/repo/.devcontainer/participants.yml"
printf "#!/bin/sh\necho \"\$*\" >> %s/calls\nexit 0\n" "$t" > "$t/bin/copilot"; chmod +x "$t/bin/copilot"
printf "version: '"'"'3'"'"'\nincludes:\n  features:\n    taskfile: /usr/local/share/go-task/features.yml\n    flatten: true\n" > "$t/repo/Taskfile.yml"
export PATH="$t/bin:$PATH" AGENTS_SETTLE_INTERVAL=0 AGENTS_SETTLE_TIMEOUT=0; cd "$t/repo"'
check "agents check reads the copilot entries and the adapter's supports" bash -c "$setup; out=\$(agents check 2>&1); printf '%s\n' \"\$out\" | grep -F 'pilot: cli copilot, on-demand' && printf '%s\n' \"\$out\" | grep -F 'copilot:'"
check "a resident copilot participant falls back to on-demand (no start-bg), says so, starts nothing" bash -c "$setup; out=\$(agents start dozer </dev/null 2>&1); printf '%s\n' \"\$out\" | grep -F 'copilot has no background mode' && ! test -e \"\$t/calls\""

reportResults
