#!/bin/bash
# Auto-generated scenario: the agents Feature with default options. The command, its state
# folder, the version and the Taskfile are installed; on a list in a temp repository with a fake
# adapter the verbs work (the logic is covered Docker-free in test/agents/unit/agents_test.sh;
# this checks the installed command runs on this base image, its awk included). Run with:
#   devcontainer features test -f agents --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "agents on PATH" command -v agents
check "agents is root-owned" bash -c "[ \"\$(stat -c %U \"\$(command -v agents)\")\" = root ]"
check "the Feature version is baked" grep -qx '2.1.0' /usr/local/share/agents-feature/version
check "the sessionName option is baked (default {handle})" grep -qx '{handle}' /usr/local/share/agents-feature/session-name
check "the state folder is there and sticky" bash -c "[ \"\$(stat -c %a /var/lib/devcontainer-features/agents)\" = 1777 ]"
check "the lease folder is there, open to every user, not sticky" bash -c "[ \"\$(stat -c %a /var/lib/devcontainer-features/agents/leases)\" = 777 ]"
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/agents.yml
check "no adapter of its own" bash -c "! ls /usr/local/bin/agent-adapter-* 2>/dev/null"

# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
setup='t=$(mktemp -d); mkdir -p "$t/repo/.devcontainer" "$t/bin"
printf "agents:\n  - name: host\n    cli: fake\n    kind: resident\n    args: [--x, \"a b\"]\n  - name: pair\n    cli: fake\n    kind: on-demand\n" > "$t/repo/.devcontainer/agents.yml"
printf "#!/bin/sh\necho \"\$*\" >> %s/calls\n[ \"\$1\" = list ] && cat %s/sessions 2>/dev/null\nexit 0\n" "$t" "$t" > "$t/bin/agent-adapter-fake"; chmod +x "$t/bin/agent-adapter-fake"
export PATH="$t/bin:$PATH" AGENTS_SETTLE_INTERVAL=0 AGENTS_SETTLE_TIMEOUT=0; cd "$t/repo"'
check "check reads the list" bash -c "$setup; agents check | grep -F 'host: cli fake, resident, stateful (identity host, lease container), folder ., args: [--x] [a b]'"
check "a missing list names the path and its source" bash -c "$setup; rm .devcontainer/agents.yml; agents check 2>&1 | grep -F 'from the default'; [ \"\${PIPESTATUS[0]}\" -eq 2 ]"
check "up starts the resident only" bash -c "$setup; agents up >/dev/null; grep -c start-bg \"\$t/calls\" | grep -qx 1 && ! grep -q 'pair' \"\$t/calls\""
check "an on-demand agent without a terminal is refused" bash -c "$setup; agents start pair </dev/null >/dev/null 2>&1; [ \$? -eq 2 ]"
check "a resident without a terminal is started and not attached" bash -c "$setup; agents start host </dev/null | grep -F 'attach from a terminal' && ! grep -q '^attach' \"\$t/calls\""
check "the post-start hook never fails" bash -c "cd \"\$(mktemp -d)\" && agents up --post-start | grep -F 'nothing to start'"

reportResults
