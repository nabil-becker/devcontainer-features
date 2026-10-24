#!/usr/bin/env bash
# Docker-free tests of the git Feature's .git-dirs mapping: the wrapper
# (src/git/git-wrapper.sh), the shared helper (git-dirs.sh) and git-setup,
# run straight from src/ against temp folders. Part of `task lint`
# (`task test:git-unit`); runs anywhere with bash, dash or another POSIX sh,
# and git.
#
# Nothing here may touch a real repository or the caller's git config: every
# git dir lives under a fresh temp folder, the inherited GIT_* variables are
# dropped, and the global config, the dirs file, the identity file and the
# mapping root are all pointed into the temp folder. The "real" git the wrapper
# forwards to is whatever `git` was on PATH before the test put the wrapper
# under test in front of it (in a devcontainer that is the installed wrapper,
# which then sees GIT_DIR already settled).
#
# GIT_FEATURE_SRC=<dir> runs the same tests against another copy of src/git
# (used to show a test fails when the code it covers is removed).
set -u

here="$(cd "$(dirname "$0")" && pwd)"
src="${GIT_FEATURE_SRC:-$here/../../../src/git}"
src="$(cd "$src" && pwd)"
command -v git >/dev/null || { echo "git_dirs_test: no git on PATH" >&2; exit 1; }

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_NAMESPACE \
  GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_SETUP_SAFE_DIRECTORY GIT_SETUP_HOOKS_PATH

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
# Run from the temp folder: started from a checkout whose .git pointer maps
# under the real /git-dirs (this devhost), the checks' plain `git config
# --global` would map it against the fake GIT_DIRS_ROOT and git would refuse.
cd "$T" || exit 1

mkdir -p "$T/bin" "$T/real" "$T/state" "$T/work"
cp "$src/git-wrapper.sh" "$T/bin/git"
cp "$src/git-setup.sh" "$T/bin/git-setup"
cp "$src/dcf-persist.sh" "$T/bin/dcf-persist"
# The "real" git: the caller's own git, with the caller's PATH and without
# GIT_WRAPPER_REAL_GIT, which an installed wrapper would otherwise follow
# back to itself.
{
  echo '#!/bin/sh'
  echo 'unset GIT_WRAPPER_REAL_GIT'
  printf 'PATH=%q\n' "$PATH"
  echo 'export PATH'
  echo 'exec git "$@"'
} > "$T/real/git"
chmod +x "$T/bin/git" "$T/bin/git-setup" "$T/bin/dcf-persist" "$T/real/git"
export PATH="$T/bin:$PATH"
export GIT_WRAPPER_REAL_GIT="$T/real/git"
export GIT_WRAPPER_GITDIRS_LIB="$src/git-dirs.sh"
export GIT_WRAPPER_DIRS_FILE="$T/state/dirs.env"
export GIT_WRAPPER_IDENTITY_FILE="$T/no-identity.env"
export GIT_CONFIG_GLOBAL="$T/state/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_DIRS_ROOT="$T/git-dirs"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# git-setup reads the installed Feature options when present; these win.
export GIT_SETUP_SAFE_DIRECTORY=workspace GIT_SETUP_HOOKS_PATH=
: > "$GIT_CONFIG_GLOBAL"

pass=0
fail=0
check() { # <name> <command...>: the command's output is shown only on failure
  local name="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    pass=$((pass + 1))
    echo "ok   - $name"
  else
    fail=$((fail + 1))
    echo "FAIL - $name"
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/       /'
  fi
}
eq() { [ "$1" = "$2" ] || { echo "expected [$2], got [$1]"; return 1; }; }
in_dir() { (cd "$1" && shift && "$@"); }
gitdir_in() { in_dir "$1" git rev-parse --absolute-git-dir; }
top_in() { in_dir "$1" git rev-parse --show-toplevel; }

# The host layout: the git dir under <root>/<owner>/<repo>, a checkout whose
# folder name differs, and its .git a pointer holding a Windows path.
gd="$GIT_DIRS_ROOT/example-owner/example-repo"
co="$T/work/checkout"
setup_failed() { echo "git_dirs_test: fixture setup failed: $*" >&2; exit 1; }
mkdir -p "${gd%/*}" "$co/src"
git init -q -b main --separate-git-dir="$gd" "$co" || setup_failed init
git -C "$co" commit -q --allow-empty -m init || setup_failed commit
head0="$(git --git-dir="$gd" rev-parse HEAD)" || setup_failed rev-parse
cp "$gd/config" "$T/config.before" || setup_failed config
point() { printf '%s' "$1" > "$co/.git"; }

point 'gitdir: C:\Users\<user>\.git-dirs\example-owner\example-repo'
check "backslash Windows pointer maps onto the root" eq "$(gitdir_in "$co/src")" "$gd"
check "the work tree is the checkout root" eq "$(top_in "$co/src")" "$co"
check "git -C from outside maps too" eq "$(git -C "$co/src" rev-parse --absolute-git-dir)" "$gd"
check "git -C with .. segments maps too" eq "$(git -C "$co/src/../src" rev-parse --absolute-git-dir)" "$gd"

point "$(printf 'gitdir: c:/users/Someone/.Git-Dirs/example-owner/example-repo\r\n')"
check "mixed-case .Git-Dirs, forward slashes and CRLF map" eq "$(gitdir_in "$co")" "$gd"

point 'gitdir: D:/Profiles/another-user/.git-dirs/example-owner/example-repo/'
check "another user profile and a trailing slash map" eq "$(gitdir_in "$co")" "$gd"

point 'gitdir: C:/Users/<user>/repos/example-repo.git'
check "a pointer outside .git-dirs changes nothing (git fails)" bash -c "cd '$co' && ! git rev-parse --git-dir"

point 'gitdir: C:/Users/<user>/.git-dirs/example-owner/absent'
check "a mapped dir without HEAD changes nothing (git fails)" bash -c "cd '$co' && ! git rev-parse --git-dir"

git init -q --bare "$T/escape.git" || setup_failed escape
point 'gitdir: C:/Users/<user>/.git-dirs/../escape.git'
check "a pointer climbing out of the root with .. is not mapped" bash -c "cd '$co' && ! git rev-parse --git-dir"

point 'gitdir: C:\Users\<user>\.git-dirs\example-owner\example-repo'
placeholder="$T/nowhere/not-a-git-repository"
check "placeholder GIT_DIR in the checkout maps without a dirs file" \
  eq "$(cd "$co/src" && GIT_DIR="$placeholder" git rev-parse --absolute-git-dir)" "$gd"
check "placeholder GIT_DIR with a placeholder GIT_WORK_TREE maps too" \
  eq "$(cd "$co" && GIT_DIR="$placeholder" GIT_WORK_TREE="$T/nowhere" git rev-parse --show-toplevel)" "$co"
check "placeholder GIT_DIR outside any checkout is left alone" bash -c "cd '$T' && ! GIT_DIR='$placeholder' git rev-parse --git-dir"

git init -q "$co/tests/nested"
check "init inside the checkout creates a nested repository" test -d "$co/tests/nested/.git"
check "a nested repository resolves to itself" eq "$(top_in "$co/tests/nested")" "$co/tests/nested"

mkdir -p "$T/fixture"
check "init and commit in a temp folder stay there" bash -c "cd '$T/fixture' && git init -q && git commit -q --allow-empty -m x && [ \"\$(git rev-parse --show-toplevel)\" = '$T/fixture' ]"

wt="$co/.claude/worktrees/x"
check "worktree add under .claude/worktrees works through the mapping" in_dir "$co" git worktree add -q "$wt" -b x
check "the linked worktree resolves to itself" eq "$(top_in "$wt")" "$wt"
check "the linked worktree's git dir is inside the mapped one" eq "$(gitdir_in "$wt")" "$gd/worktrees/x"

git init -q "$T/other"
check "an explicit GIT_DIR/GIT_WORK_TREE (containerEnv) still wins" \
  eq "$(cd "$co" && GIT_DIR="$T/other/.git" GIT_WORK_TREE="$co" git rev-parse --absolute-git-dir)" "$T/other/.git"
check "an explicit --git-dir is not mapped" eq "$(cd "$co/src" && git --git-dir="$T/other/.git" rev-parse --absolute-git-dir)" "$T/other/.git"
check "a GIT_WORK_TREE set on its own is not mapped" bash -c "cd '$co' && ! GIT_WORK_TREE='$co' git rev-parse --git-dir"

# git-setup without GIT_DIR: map the workspace's pointer, record it for the
# placeholder restore, trust the top level and the git dir.
out="$(cd "$co/src" && git-setup 2>&1)"
rc=$?
check "git-setup (mapped) exits 0" eq "$rc" 0
check "git-setup reports the mapping" grep -qF -- "-> $gd (through $GIT_DIRS_ROOT)" <<<"$out"
check "git-setup records the mapped git dir" grep -qxF "DCF_GIT_DIR='$gd'" "$GIT_WRAPPER_DIRS_FILE"
check "git-setup records the checkout top level as work tree" grep -qxF "DCF_WORK_TREE='$co'" "$GIT_WRAPPER_DIRS_FILE"
check "safe.directory: the top level, not the sub-folder" bash -c "git config --global --get-all safe.directory | grep -qxF '$co' && ! git config --global --get-all safe.directory | grep -qxF '$co/src'"
check "safe.directory: the mapped git dir" bash -c "git config --global --get-all safe.directory | grep -qxF '$gd'"
check "git-setup reports the workspace usable" grep -qF "workspace $co: ok (main)" <<<"$out"
check "placeholder restore from the recorded dirs file (helper unavailable)" \
  eq "$(cd "$co/src" && GIT_WRAPPER_GITDIRS_LIB="$T/absent.sh" GIT_DIR="$placeholder" git rev-parse --absolute-git-dir)" "$gd"
check "git-setup run again keeps what it set" bash -c "cd '$co' && git-setup >/dev/null 2>&1 && git-setup | grep -qF 'safe.directory: $co (kept)'"

# The host-safety rule: the shared git dir's config is what git on Windows
# reads too; nothing in the container may write into it.
in_dir "$co" git status --porcelain >/dev/null 2>&1
in_dir "$co" git commit -q --allow-empty -m second >/dev/null 2>&1
in_dir "$co" git init -q >/dev/null 2>&1
in_dir "$co/src" git worktree list >/dev/null 2>&1
check "the shared git dir's config is unchanged" cmp "$T/config.before" "$gd/config"
check "no core.worktree in the shared git dir" bash -c "! git config --file '$gd/config' --get core.worktree"
check "the commit landed on the mapped git dir" bash -c "[ \"\$(git --git-dir='$gd' rev-parse HEAD~1)\" = '$head0' ]"

# git-setup when the mapping cannot apply: one line naming the mount, never fatal.
out="$(cd "$co" && GIT_DIRS_ROOT="$T/not-mounted" git-setup 2>&1)"
rc=$?
check "git-setup (not mounted) exits 0" eq "$rc" 0
check "git-setup names the missing mount and the line to add" \
  grep -qF "git dir: NOT MOUNTED - $co/.git points to C:\\Users\\<user>\\.git-dirs\\example-owner\\example-repo, expected at $T/not-mounted/example-owner/example-repo; the launcher adds the mount when started through the bootstrap tasks (task devcontainer:up), else add to devcontainer.json \"mounts\": [\"source=\${localEnv:DCF_HOST_HOME}/.git-dirs,target=$T/not-mounted,type=bind\"] (opened straight in VS Code, the launcher did not run: use \${localEnv:USERPROFILE} on a Windows host or \${localEnv:HOME} on Linux, macOS and WSL in place of \${localEnv:DCF_HOST_HOME}) and rebuild" <<<"$out"
check "git-setup (not mounted) removes a stale dirs file" test ! -e "$GIT_WRAPPER_DIRS_FILE"
check "git-setup (not mounted) still manages the global config" grep -qxF "safe.directory: $co (kept)" <<<"$out"
point 'gitdir: E:/elsewhere/example-repo.git'
out="$(cd "$co" && git-setup 2>&1)"
rc=$?
check "git-setup (outside the root) exits 0" eq "$rc" 0
check "git-setup says the pointer is outside .git-dirs" grep -qF "git dir: OUTSIDE .git-dirs - $co/.git points to E:/elsewhere/example-repo.git" <<<"$out"
check "git-setup (outside the root) names the launcher and the line to add" \
  grep -qF "(update the pointer); the launcher adds the mount when started through the bootstrap tasks (task devcontainer:up), else add to devcontainer.json \"mounts\": [\"source=\${localEnv:DCF_HOST_HOME}/.git-dirs,target=$GIT_DIRS_ROOT,type=bind\"] (opened straight in VS Code, the launcher did not run: use \${localEnv:USERPROFILE} on a Windows host or \${localEnv:HOME} on Linux, macOS and WSL in place of \${localEnv:DCF_HOST_HOME})" <<<"$out"
point 'gitdir: C:\Users\<user>\.git-dirs\example-owner\example-repo'

# The per-repo form (GIT_DIR and GIT_WORK_TREE in containerEnv) as before.
out="$(cd "$co" && GIT_DIR="$gd" GIT_WORK_TREE="$co" git-setup 2>&1)"
check "git-setup (containerEnv) records GIT_DIR as given" grep -qxF "DCF_GIT_DIR='$gd'" "$GIT_WRAPPER_DIRS_FILE"
check "git-setup (containerEnv) says where the values came from" grep -qF "from containerEnv" "$GIT_WRAPPER_DIRS_FILE"

check "the shared git dir's config is still unchanged" cmp "$T/config.before" "$gd/config"

# The helper itself, under the shell the wrapper runs in.
check "the helper resolves the same under sh" eq "$(sh -c ". '$src/git-dirs.sh'; dcf_gitdirs_resolve '$co'; echo \"\$DCF_GITDIRS_STATE \$DCF_GITDIRS_PATH\"")" "mapped $gd"

echo "git_dirs_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
