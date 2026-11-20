#!/bin/bash
# Scenario 'participants' (see scenarios.json): participants: true installs the participant
# component (what the agents Feature installed up to 2.1.3) once, in /usr/local/lib/dcf-participant:
# the agents command on PATH, the agents:* tasks through the go-task registry, the state folders,
# and the post-start hook that runs agents up; no agents Feature, so no deprecation line.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

lib=/usr/local/lib/dcf-participant
check "agents on PATH" command -v agents
check "agents is the component's, root-owned" bash -c "[ \"\$(readlink -f \"\$(command -v agents)\")\" = $lib/agents.sh ] && [ \"\$(stat -c %U $lib/agents.sh)\" = root ]"
check "the component version is there" bash -c "grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' $lib/COMPONENT_VERSION"
check "installed by claude-code" grep -qx claude-code $lib/installed-by
check "the state folder is there and sticky" bash -c "[ \"\$(stat -c %a /var/lib/devcontainer-features/agents)\" = 1777 ]"
check "the lease folder is open, not sticky" bash -c "[ \"\$(stat -c %a /var/lib/devcontainer-features/agents/leases)\" = 777 ]"
check "the agents taskfile is registered" grep -q '^  agents:' /usr/local/share/go-task/features.yml
check "the participants marker is set" test -f /usr/local/share/claude-code/participants
check "no agents Feature files" bash -c "! test -e /usr/local/share/agents-feature"
check "the post-start hook is on PATH" command -v claude-code-post-start

# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
setup='t=$(mktemp -d); mkdir -p "$t/repo/.devcontainer" "$t/bin"
printf "agents:\n  - name: host\n    cli: fake\n    kind: resident\n  - name: pair\n    cli: fake\n    kind: on-demand\n" > "$t/repo/.devcontainer/agents.yml"
printf "#!/bin/sh\necho \"\$*\" >> %s/calls\n[ \"\$1\" = list ] && cat %s/sessions 2>/dev/null\nexit 0\n" "$t" "$t" > "$t/bin/agent-adapter-fake"; chmod +x "$t/bin/agent-adapter-fake"
printf "version: '"'"'3'"'"'\nincludes:\n  features:\n    taskfile: /usr/local/share/go-task/features.yml\n    flatten: true\n" > "$t/repo/Taskfile.yml"
export PATH="$t/bin:$PATH" AGENTS_SETTLE_INTERVAL=0 AGENTS_SETTLE_TIMEOUT=0; cd "$t/repo"'
check "task agents:check reads the list" bash -c "$setup; task agents:check | grep -F 'pair: cli fake, on-demand'"
check "task agents:check prints no deprecation line" bash -c "$setup; ! task agents:check 2>&1 | grep -q deprecated"
check "task agents:version shows the component" bash -c "$setup; task agents:version 2>/dev/null | head -n 1 | grep -qx \"participant \$(cat $lib/COMPONENT_VERSION)\""
check "the post-start hook starts the resident only" bash -c "$setup; claude-code-post-start >/dev/null; grep -c start-bg \"\$t/calls\" | grep -qx 1 && ! grep -q pair \"\$t/calls\""
check "the post-start hook never fails" bash -c "cd \"\$(mktemp -d)\" && claude-code-post-start"

reportResults
