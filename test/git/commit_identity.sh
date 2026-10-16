#!/bin/bash
# Scenario 'commit_identity' (see scenarios.json): commitName and commitEmail set.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

name="devhost agent"
email="devhost-agent@noreply.invalid"
check "identity file written" grep -q "^DCF_COMMIT_EMAIL='$email'$" /usr/local/share/git-feature/identity.env

tmp="$(mktemp -d)"
cd "$tmp"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
git init -q -b main repo
# The repository-local identity that used to win over the global one.
git -C repo config user.name "Real Person"
git -C repo config user.email "real.person@example.com"
git -C repo commit -q -s --allow-empty -m "signed"
last() { git -C repo log -1 --format="$1"; }
check "author is the bot" bash -c "[ \"$(last '%an <%ae>')\" = '$name <$email>' ]"
check "committer is the bot" bash -c "[ \"$(last '%cn <%ce>')\" = '$name <$email>' ]"
check "Signed-off-by is the bot" bash -c "[ \"$(last '%(trailers:key=Signed-off-by,valueonly)' | head -1)\" = '$name <$email>' ]"
check "the real address appears nowhere in the commit" bash -c "! git -C repo cat-file -p HEAD | grep -q real.person"
check "a caller's own variables win" bash -c "GIT_AUTHOR_EMAIL=me@example.com git -C repo commit -q --allow-empty -m own && [ \"\$(git -C repo log -1 --format=%ae)\" = me@example.com ] && [ \"\$(git -C repo log -1 --format=%ce)\" = '$email' ]"

reportResults
