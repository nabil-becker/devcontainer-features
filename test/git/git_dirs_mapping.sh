#!/bin/bash
# Scenario 'git_dirs_mapping' (see scenarios.json): default options,
# GIT_DIRS_ROOT=/tmp/git-dirs-test in containerEnv standing in for the one
# `.git-dirs` bind mount, no GIT_DIR/GIT_WORK_TREE. A checkout whose .git
# pointer holds a Windows path under .git-dirs works through the wrapper.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "mapping helper installed" test -r /usr/local/share/git-feature/git-dirs.sh
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "GIT_DIRS_ROOT comes from containerEnv" bash -c '[ "$GIT_DIRS_ROOT" = /tmp/git-dirs-test ]'

tmp="$(mktemp -d)"
cd "$tmp"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
export GIT_WRAPPER_DIRS_FILE="$tmp/dirs.env"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset GIT_DIR GIT_WORK_TREE
gd="$GIT_DIRS_ROOT/example-owner/example-repo"
co="$tmp/checkout"
mkdir -p "${gd%/*}" "$co/src"
git init -q -b main --separate-git-dir="$gd" "$co"
git -C "$co" commit -q --allow-empty -m init
cp "$gd/config" "$tmp/config.before"
printf 'gitdir: C:\\Users\\<user>\\.Git-Dirs\\example-owner\\example-repo\r\n' > "$co/.git"

check "a Windows pointer maps onto GIT_DIRS_ROOT" bash -c "cd '$co/src' && [ \"\$(git rev-parse --absolute-git-dir)\" = '$gd' ] && [ \"\$(git rev-parse --show-toplevel)\" = '$co' ]"
check "git-setup records the mapped git dir" bash -c "cd '$co' && git-setup | grep -qF -- '-> $gd' && grep -qxF \"DCF_GIT_DIR='$gd'\" '$tmp/dirs.env'"
check "placeholder GIT_DIR is restored" bash -c "cd '$co/src' && [ \"\$(GIT_DIR=/x/not-a-git-repository git rev-parse --absolute-git-dir)\" = '$gd' ]"
check "a worktree under .claude/worktrees resolves to itself" bash -c "cd '$co' && git worktree add -q .claude/worktrees/x -b x && [ \"\$(git -C .claude/worktrees/x rev-parse --show-toplevel)\" = '$co/.claude/worktrees/x' ]"
check "init in a temp folder stays there" bash -c "d=\$(mktemp -d) && cd \"\$d\" && git init -q && [ \"\$(git rev-parse --show-toplevel)\" = \"\$d\" ]"
check "the shared git dir's config is unchanged" bash -c "cd '$co' && git status >/dev/null && git init -q 2>/dev/null; cmp '$tmp/config.before' '$gd/config'"
check "a missing mount is named with the line to add" bash -c "cd '$co' && GIT_DIRS_ROOT=/tmp/absent git-setup | grep -qF 'target=/tmp/absent,type=bind'"

reportResults
