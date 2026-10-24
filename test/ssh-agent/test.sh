#!/bin/bash
# Auto-generated scenario: the ssh-agent Feature with default options (keyMode=false). Run with:
#   devcontainer features test -f ssh-agent --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

sock=/var/lib/devcontainer-features/ssh-agent/agent.sock
check "SSH_AUTH_SOCK is the fixed path" bash -c "[ \"\$SSH_AUTH_SOCK\" = $sock ]"
check "ssh-add on PATH" command -v ssh-add
check "ssh-keygen on PATH" command -v ssh-keygen
check "ssh-agent on PATH" command -v ssh-agent
check "the socket folder exists and is writable by anyone (sticky)" bash -c "[ \"\$(stat -c %a /var/lib/devcontainer-features/ssh-agent)\" = 1777 ]"
check "the Feature does not mount a volume over the socket folder" bash -c "! findmnt -n /var/lib/devcontainer-features/ssh-agent >/dev/null 2>&1"
check "the key volume is its own folder" test -d /var/lib/devcontainer-features/ssh-agent-key

check "dcf-persist on PATH" command -v dcf-persist
check "ssh-agent-setup on PATH" command -v ssh-agent-setup
check "options baked for ssh-agent-setup" grep -q '^KEYMODE=false$' /usr/local/share/ssh-agent-feature/options.env
check "ssh-agent-setup exits 0 and reports" bash -c "ssh-agent-setup | grep -E '^ssh-agent: '"
check "without the launcher it says the host is unknown" bash -c "env -u DCF_HOST_SSH_AGENT ssh-agent-setup | grep -F 'host unknown'"
check "none names the host type and both ways round" bash -c "DCF_HOST_SSH_AGENT=none DCF_HOST_TYPE=windows-docker ssh-agent-setup | grep -F 'host type windows-docker' && DCF_HOST_SSH_AGENT=none ssh-agent-setup | grep -F 'VS Code'"
check "check exits 1 when no agent answers" bash -c "! ssh-agent-setup check"
check "key tasks refuse with keyMode off" bash -c "ssh-agent-setup key-load 2>&1 | grep -F 'keyMode: true'"

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/ssh-agent.yml

reportResults
