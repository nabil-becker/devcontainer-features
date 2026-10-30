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
check "options baked: passphraseTimeout default" grep -q "^PASSPHRASETIMEOUT=120$" /usr/local/share/ssh-agent-feature/options.env
check "setup starts or keeps the agent on the fixed path" bash -c "ssh-agent-setup | grep -E 'started an agent|already answers'"
check "an agent answers on the fixed path" bash -c "ssh-add -l >/dev/null; [ \$? -le 1 ]"
check "the socket is a socket" test -S "$sock"
check "setup is idempotent: the live agent is reused" bash -c "ssh-agent-setup | grep -F 'already answers'"
check "the key volume is writable" test -w "$keys"

ssh-keygen -q -t ed25519 -N '' -C 'handmade' -f "$keys/handmade"
check "key-load loads a 0600 key from the volume" bash -c "[ \"\$(stat -c %a $keys/handmade)\" = 600 ] && ssh-agent-setup key-load | grep -E '[0-9]+ of [0-9]+ key' && ssh-add -l | grep -F handmade"
ssh-keygen -q -t ed25519 -N 'secret' -C protected -f "$keys/protected"
check "the start hook skips a protected key with one warning, exits 0 and keeps the agent and the other key" bash -c "ssh-agent-setup > '$tmp/hook.out' 2>&1 </dev/null; [ \$? -eq 0 ] && grep -F 'protected has a passphrase and the start hook never asks for one' '$tmp/hook.out' && grep -F 'task ssh-agent:setup' '$tmp/hook.out' && ssh-add -l | grep -F handmade && ! ssh-add -l | grep -F protected"
rm -f "$keys/protected" "$keys/protected.pub"
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

# key:age, and rotation without gh (the image has none; DCF_GH makes that certain): it stops after the new key is
# made, prints the resume message, and removes nothing old.
check "task key:age lists the key with a date, an age and a fingerprint" bash -c "task -t $registry ssh-agent:key:age | grep -E 'handmade: created [0-9]{4}-[0-9]{2}-[0-9]{2}, [0-9]+ day\\(s\\) old, SHA256:'"
new="handmade-$(date +%Y%m%d)"
check "task key:rotate -- --plan prints the steps and changes nothing" bash -c "task -t $registry ssh-agent:key:rotate NAME=handmade -- --plan | grep -F 'nothing was changed' && [ ! -e $keys/$new ]"
check "task key:rotate without gh stops after step 1 with the resume message" bash -c "DCF_GH=/nonexistent/gh task -t $registry ssh-agent:key:rotate NAME=handmade EMPTY_PASSPHRASE=1 > '$tmp/rotate.out' 2>&1; [ \$? -ne 0 ] && grep -F 'finish by registering it, then run key:rotate again with NEW=$new' '$tmp/rotate.out' && ! grep -F 'PRIVATE KEY' '$tmp/rotate.out'"
check "the old key is untouched and still loaded; the new one exists" bash -c "[ -f $keys/handmade ] && ssh-add -l | grep -F handmade && [ -f $keys/$new ] && [ -f $keys/$new.meta ]"
check "task key:retire removes a key and logs it in the allowed_signers history" bash -c "task -t $registry ssh-agent:key:retire NAME=$new && [ ! -e $keys/$new ] && grep -F 'valid-before=' $keys/allowed_signers.history"

reportResults
