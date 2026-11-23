#!/bin/bash
# Scenario 'with_claude_code_participants' (see scenarios.json): the deprecated agents Feature next
# to claude-code with participants: true leaves one copy of the participant component, in
# whichever order the two install; the agents Feature keeps its version, its sessionName option
# and its deprecation line, and claude-code's post-start hook leaves agents up to the agents
# Feature's own.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

lib=/usr/local/lib/dcf-participant
check "one copy of the component" bash -c "[ \"\$(find /usr/local/lib -maxdepth 1 -name 'dcf-participant*' | wc -l)\" = 1 ]"
check "agents on PATH points into it" bash -c "[ \"\$(readlink -f \"\$(command -v agents)\")\" = $lib/agents.sh ]"
check "no second agents command" bash -c "[ \"\$(type -ap agents | wc -l)\" = 1 ]"
check "one installer recorded" bash -c "[ \"\$(wc -l < $lib/installed-by)\" = 1 ] && grep -qxE 'agents|claude-code' $lib/installed-by"
check "one agents include" bash -c "[ \"\$(grep -c '^  agents:' /usr/local/share/go-task/features.yml)\" = 1 ]"
check "the agents Feature version is baked" grep -qx '2.6.0' /usr/local/share/agents-feature/version
check "its sessionName option is kept" grep -qxF '{machine} {handle}' /usr/local/share/agents-feature/session-name
check "the adapter is there" command -v agent-adapter-claude

# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
setup='t=$(mktemp -d); mkdir -p "$t/repo/.devcontainer" "$t/bin"
printf "agents:\n  - name: host\n    cli: fake\n    kind: resident\n" > "$t/repo/.devcontainer/agents.yml"
printf "#!/bin/sh\necho \"\$*\" >> %s/calls\nexit 0\n" "$t" > "$t/bin/agent-adapter-fake"; chmod +x "$t/bin/agent-adapter-fake"
printf "version: '"'"'3'"'"'\nincludes:\n  features:\n    taskfile: /usr/local/share/go-task/features.yml\n    flatten: true\n" > "$t/repo/Taskfile.yml"
export PATH="$t/bin:$PATH" AGENTS_SETTLE_INTERVAL=0 AGENTS_SETTLE_TIMEOUT=0; cd "$t/repo"'
check "task agents:check works and says it is deprecated once" bash -c "$setup; out=\$(task agents:check 2>&1); printf '%s\n' \"\$out\" | grep -F 'host: cli fake, resident' && [ \"\$(printf '%s\n' \"\$out\" | grep -cx 'deprecated: use claude-code participants: true')\" = 1 ]"
check "the sessionName option reaches the agents command (no DCF_HOST_MACHINE: 'container')" bash -c "$setup; unset AGENTS_SESSION_NAME DCF_HOST_MACHINE; agents check | grep -F 'session name \"container host\"'"
check "claude-code's post-start hook leaves agents up to the agents Feature" bash -c "$setup; claude-code-post-start; ! test -e \"\$t/calls\""

reportResults
