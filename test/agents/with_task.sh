#!/bin/bash
# Scenario 'with_task' (see scenarios.json): the agents:* tasks through the go-task registry, in a
# consuming repository whose root Taskfile includes it flattened; `task agents` is the default task.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
setup='t=$(mktemp -d); mkdir -p "$t/repo/.devcontainer" "$t/repo/ops" "$t/bin"
printf "agents:\n  - name: pair\n    cli: fake\n    kind: on-demand\n" > "$t/repo/.devcontainer/agents.yml"
printf "agents:\n  - name: ops-agent\n    cli: fake\n    kind: on-demand\n" > "$t/repo/ops/agents.yml"
printf "#!/bin/sh\necho \"\$*\" >> %s/calls\nexit 0\n" "$t" > "$t/bin/agent-adapter-fake"; chmod +x "$t/bin/agent-adapter-fake"
printf "version: '"'"'3'"'"'\nincludes:\n  features:\n    taskfile: /usr/local/share/go-task/features.yml\n    flatten: true\n" > "$t/repo/Taskfile.yml"
export PATH="$t/bin:$PATH"; cd "$t/repo"'
check "the registry includes agents" grep -q '^  agents:' /usr/local/share/go-task/features.yml
check "task agents:check" bash -c "$setup; task agents:check | grep -F 'pair: cli fake, on-demand'"
check "task agents:check AGENTS_FILE=... (a task variable)" bash -c "$setup; task agents:check AGENTS_FILE=ops/agents.yml | grep -F 'from the task variable AGENTS_FILE'"
check "task agents -- <name> runs the start verb (refused without a terminal)" bash -c "$setup; ! task agents -- pair </dev/null"
check "task agents:list -- --json" bash -c "$setup; task agents:list -- --json | grep -F '\"name\":\"pair\"'"
check "task agents:version" bash -c "$setup; task agents:version | grep -x 2.1.1"

reportResults
