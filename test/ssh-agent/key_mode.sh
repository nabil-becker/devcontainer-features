#!/bin/bash
# Scenario 'key_mode' (see scenarios.json): keyMode: true. The in-container agent runs on the fixed path
# (started by the post-start hook), loads a 0600 key put in the key volume, refuses a 0644 one, and the
# key tasks work end to end: key:new, key:load, git:signing, git:verify.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

sock=/var/lib/devcontainer-features/ssh-agent/agent.sock
keys=/var/lib/devcontainer-features/ssh-agent-key
registry=/usr/local/share/go-task/features.yml
tmp="$(mktemp -d)"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"

check "options baked: keyMode on" grep -q '^KEYMODE=true$' /usr/local/share/ssh-agent-feature/options.env
check "setup starts or keeps the agent on the fixed path" bash -c "ssh-agent-setup | grep -E 'started an agent|already answers'"
check "an agent answers on the fixed path" bash -c "ssh-add -l >/dev/null; [ \$? -le 1 ]"
check "the socket is a socket" test -S "$sock"
check "setup is idempotent: the live agent is reused" bash -c "ssh-agent-setup | grep -F 'already answers'"
check "the key volume is writable" test -w "$keys"

ssh-keygen -q -t ed25519 -N '' -C 'handmade' -f "$keys/handmade"
check "key-load loads a 0600 key from the volume" bash -c "[ \"\$(stat -c %a $keys/handmade)\" = 600 ] && ssh-agent-setup key-load | grep -E '[0-9]+ of [0-9]+ key' && ssh-add -l | grep -F handmade"
cp "$keys/handmade" "$keys/loose"
chmod 644 "$keys/loose"
check "a 0644 key is refused" bash -c "ssh-agent-setup key-load 2>&1 | grep -F 'refusing loose: mode 644'"
rm -f "$keys/loose"

check "task key:new generates a key and prints only the public half" bash -c "task -t $registry ssh-agent:key:new NAME=sign EMPTY_PASSPHRASE=1 COMMENT=ci | tee '$tmp/new.out' | grep -F 'ssh-ed25519 ' && ! grep -F 'PRIVATE KEY' '$tmp/new.out'"
check "key:new left a 0600 private key" bash -c "[ \"\$(stat -c %a $keys/sign)\" = 600 ]"
check "task key:load reloads" task -t "$registry" ssh-agent:key:load
check "task keys lists both keys" bash -c "task -t $registry ssh-agent:keys | grep -F ci"
check "task git:signing needs KEY with two keys" bash -c "! task -t $registry ssh-agent:git:signing SCOPE=global"
check "task git:signing by public key file" bash -c "task -t $registry ssh-agent:git:signing KEY=$keys/sign.pub SCOPE=global && [ \"\$(git config --global gpg.format)\" = ssh ]"
check "task git:verify signs and verifies through the in-container agent" bash -c "task -t $registry ssh-agent:git:verify | grep -F 'ok:'"
check "task key:remove DELETE=1 removes it from the volume" bash -c "task -t $registry ssh-agent:key:remove NAME=sign DELETE=1 && [ ! -e $keys/sign ]"

reportResults
