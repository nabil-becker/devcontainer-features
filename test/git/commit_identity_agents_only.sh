#!/bin/bash
# Scenario 'commit_identity_agents_only' (see scenarios.json): the identity with
# commitWhenEnv=CLAUDECODE, so it applies to agents' git only.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

name="devhost agent"
email="devhost-agent@noreply.invalid"
check "identity file names the variable" grep -q "^DCF_COMMIT_WHEN_ENV='CLAUDECODE'$" /usr/local/share/git-feature/identity.env

tmp="$(mktemp -d)"
cd "$tmp"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL CLAUDECODE
git init -q -b main repo
git -C repo config user.name "Real Person"
git -C repo config user.email "real.person@example.com"
last() { git -C repo log -1 --format="$1"; }
git -C repo commit -q --allow-empty -m "by the person"
check "a person's commit keeps their identity" bash -c "[ \"$(last '%an <%ae> %cn <%ce>')\" = 'Real Person <real.person@example.com> Real Person <real.person@example.com>' ]"
CLAUDECODE=1 git -C repo commit -q -s --allow-empty -m "by an agent"
check "an agent's commit is the bot" bash -c "[ \"$(last '%an <%ae> %cn <%ce>')\" = '$name <$email> $name <$email>' ]"
check "an agent's sign-off is the bot" bash -c "[ \"$(last '%(trailers:key=Signed-off-by,valueonly)' | head -1)\" = '$name <$email>' ]"
CLAUDECODE='' git -C repo commit -q --allow-empty -m "empty marker"
check "an empty marker counts as a person" bash -c "[ \"$(last '%ae')\" = real.person@example.com ]"

reportResults
