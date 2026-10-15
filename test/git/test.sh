#!/bin/bash
# Auto-generated scenario: the git Feature with default options
# (worktreeAware=true, safeDirectory=workspace, hooksPath=""). Run with:
#   devcontainer features test -f git --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "wrapper installed at /usr/local/bin/git" grep -q '^# devcontainer-features git wrapper' /usr/local/bin/git
check "git is the wrapper" bash -c "[ \"\$(command -v git)\" = /usr/local/bin/git ]"
check "git reports a version through the wrapper" bash -c "git --version | grep -E '^git version [0-9]+\.[0-9]+'"
check "wrapper is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/git)\" = root ]"
check "git-setup is on PATH" command -v git-setup
check "dcf-persist on PATH" command -v dcf-persist
check "options baked for git-setup" grep -q '^SAFEDIRECTORY=workspace$' /usr/local/share/git-feature/options.env
check "GIT_CONFIG_GLOBAL points into the Feature's state dir" bash -c "[ \"\$GIT_CONFIG_GLOBAL\" = /var/lib/devcontainer-features/git/gitconfig ]"
# The Feature's volume is mounted in `devcontainer features test` (volume);
# any backing is accepted so the check is not engine-specific.
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "git-setup succeeds outside a repository and reports the state dir" bash -c 'cd "$(mktemp -d)" && git-setup | grep -Eq "^git: /var/lib/devcontainer-features/git \((volume|bind|image), writable\)$"'
# shellcheck disable=SC2016
check "safe.directory lands in the global config inside the state dir" bash -c 'd="$(mktemp -d)" && cd "$d" && git-setup >/dev/null && git config --file /var/lib/devcontainer-features/git/gitconfig --get-all safe.directory | grep -qxF -- "$d"'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/git.yml

# Functional check of the wrapper: a checkout whose git dir sits outside the
# work tree (pointer file + GIT_DIR/GIT_WORK_TREE, as in a bind-mounted
# devcontainer), a linked worktree under it and an unrelated repository.
tmp="$(mktemp -d)"
cd "$tmp"  # never inside some repository the test runner happens to sit in
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
git init -q -b main "$tmp/main"
git -C "$tmp/main" commit -q --allow-empty -m init
mv "$tmp/main/.git" "$tmp/main.git"
echo "gitdir: $tmp/main.git" > "$tmp/main/.git"
git init -q -b main "$tmp/other"
export GIT_DIR="$tmp/main.git" GIT_WORK_TREE="$tmp/main"
wt="$tmp/main/.claude/worktrees/wt"

toplevel_is() { [ "$(git -C "$1" rev-parse --show-toplevel)" = "$1" ]; }
check "main checkout stays on GIT_DIR" toplevel_is "$tmp/main"
# Run from inside the checkout: outside the work tree the wrapper drops GIT_DIR.
check "worktree add works through GIT_DIR" git -C "$tmp/main" worktree add -q "$wt" -b wt
check "git -C <worktree> resolves to the worktree" toplevel_is "$wt"
check "plain git inside the worktree resolves to the worktree" bash -c "cd '$wt' && [ \"\$(git rev-parse --show-toplevel)\" = '$wt' ]"
check "-c key=value before -C is skipped, not taken as the subcommand" bash -c "[ \"\$(git -c core.pager=cat -C '$wt' rev-parse --show-toplevel)\" = '$wt' ]"
check "unrelated repository resolves to itself" toplevel_is "$tmp/other"

# GIT_DIR must not leak out of the work tree: a test fixture doing git init /
# commit in a temporary folder used to re-initialise the real repository and
# commit onto its branch.
head_before="$(git -C "$tmp/main" rev-parse HEAD)"
mkdir -p "$tmp/fixture" "$tmp/main/tests/tmp" "$tmp/main/src"
check "git init outside the work tree creates a repository there" bash -c "cd '$tmp/fixture' && git init -q && git commit -q --allow-empty -m x && [ \"\$(git rev-parse --show-toplevel)\" = '$tmp/fixture' ]"
check "git status outside the work tree is not the main checkout" bash -c "cd / && ! git status >/dev/null 2>&1"
check "git init in a sub-folder of the work tree creates a nested repository" bash -c "cd '$tmp/main/tests/tmp' && git init -q && [ \"\$(git rev-parse --show-toplevel)\" = '$tmp/main/tests/tmp' ]"
check "a plain sub-folder still resolves to the main checkout" bash -c "[ \"\$(git -C '$tmp/main/src' rev-parse --show-toplevel)\" = '$tmp/main' ]"
check "main checkout HEAD unchanged" bash -c "[ \"\$(git -C '$tmp/main' rev-parse HEAD)\" = '$head_before' ]"
check "main checkout config untouched (no core.worktree)" bash -c "! git -C '$tmp/main' config --local --get core.worktree"
# A re-init at the checkout root must not write core.worktree into the shared
# git dir either (git obeys GIT_WORK_TREE when the wrapper keeps it).
check "git init at the checkout root leaves the shared config alone" bash -c "cd '$tmp/main' && git init -q >/dev/null 2>&1; ! git config --local --get core.worktree && [ \"\$(git rev-parse HEAD)\" = '$head_before' ]"

reportResults
