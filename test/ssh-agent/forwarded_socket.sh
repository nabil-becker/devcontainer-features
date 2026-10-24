#!/bin/bash
# Scenario 'forwarded_socket' (see scenarios.json): a forwarded host agent is simulated by an ssh-agent
# started on the fixed path inside the container, as the launcher's bind-mounted socket would appear.
# Signing goes through it; nothing but throwaway keys exists.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

sock=/var/lib/devcontainer-features/ssh-agent/agent.sock
tmp="$(mktemp -d)"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
rm -f "$sock"
ssh-agent -a "$sock" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C 'throwaway' -f "$tmp/id"
ssh-add -q "$tmp/id"

check "ssh-add -l reaches the agent through SSH_AUTH_SOCK" bash -c "ssh-add -l | grep -F throwaway"
printf 'message\n' > "$tmp/msg"
check "ssh-keygen -Y sign signs through the agent" bash -c "ssh-keygen -Y sign -f '$tmp/id.pub' -n git '$tmp/msg'"
printf 'dcf %s\n' "$(awk '{print $1 " " $2}' "$tmp/id.pub")" > "$tmp/allowed"
check "ssh-keygen -Y verify accepts the signature" bash -c "ssh-keygen -Y verify -f '$tmp/allowed' -I dcf -n git -s '$tmp/msg.sig' < '$tmp/msg'"

check "ssh-agent-setup reports the socket mode" bash -c "DCF_HOST_SSH_AGENT=socket DCF_HOST_TYPE=linux ssh-agent-setup | grep -F \"the host's agent reachable at $sock, 1 key(s) loaded\""
check "check exits 0" bash -c "DCF_HOST_SSH_AGENT=socket ssh-agent-setup check"
check "key tasks refuse in socket mode" bash -c "! DCF_HOST_SSH_AGENT=socket ssh-agent-setup key-new"

registry=/usr/local/share/go-task/features.yml
check "the check task is registered" bash -c "task -t $registry --list-all | grep -F 'ssh-agent:check'"
check "task ssh-agent:check runs" task -t "$registry" ssh-agent:check
check "task ssh-agent:keys lists the key" bash -c "task -t $registry ssh-agent:keys | grep -F throwaway"
check "task ssh-agent:git:signing configures git" bash -c "task -t $registry ssh-agent:git:signing SCOPE=global && [ \"\$(git config --global gpg.format)\" = ssh ] && [ \"\$(git config --global commit.gpgsign)\" = true ]"
check "task ssh-agent:git:verify signs and verifies" bash -c "task -t $registry ssh-agent:git:verify | grep -F 'ok:'"

ssh-agent -k >/dev/null 2>&1 || true
reportResults
