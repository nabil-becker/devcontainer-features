#!/bin/bash
# Scenario 'aliases' (see scenarios.json): taskAliases=true, remoteUser=vscode.
# A temp workspace with a root Taskfile that includes features.yml the way the Feature documents, and
# a team file; the generator output must reach `task --list` through the flattened include.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

ws="$(mktemp -d)"
mkdir -p "$ws/.devcontainer" "$ws/sub"
cat > "$ws/Taskfile.yml" <<'E'
version: '3'
includes:
  features:
    taskfile: /usr/local/share/go-task/features.yml
    optional: true
    flatten: true
tasks:
  hello:
    desc: say hello
    cmds:
      - echo "hello {{.WHO | default "nobody"}}"
E
cat > "$ws/.devcontainer/task-aliases.yml" <<'E'
aliases:
  hi: hello
  hi-me:
    task: hello
    desc: Greet me
    vars: { WHO: me }
  hello: go-task:version
  gone: no-such-task
E

check "yq installed privately, pinned" bash -c "/usr/local/share/go-task/yq --version | grep -F v4.54.1"
check "task-aliases on PATH" command -v task-aliases
check "features.yml includes the generated aliases, flattened" bash -c "grep -A3 'task-aliases:' /usr/local/share/go-task/features.yml | grep -F 'flatten: true'"
check "the generated file is writable by the remote user" test -w /var/lib/devcontainer-features/go-task/aliases.yml
check "task --list works before any generation" bash -c "cd $ws && task --list"
check "go-task:aliases generates and reports" bash -c "cd $ws/sub && task go-task:aliases | grep -E '^aliases: 2 ok, 2 not generated'"
check "the shadowing alias is refused" bash -c "cd $ws && task go-task:aliases | grep -E '^hello +go-task:version +shadows'"
check "the broken alias is reported" bash -c "cd $ws && task go-task:aliases | grep -E '^gone +no-such-task +broken'"
check "an alias shows in task --list" bash -c "cd $ws && task --list | grep -F 'hi-me:'"
check "task <alias> runs the target" bash -c "cd $ws && task hi --silent | grep -Fx 'hello nobody'"
check "task <alias> passes its fixed vars" bash -c "cd $ws && task hi-me --silent | grep -Fx 'hello me'"
check "the real task is untouched" bash -c "cd $ws && task hello --silent | grep -Fx 'hello nobody'"
printf 'aliases: { hey: hello }\n' > "$ws/.devcontainer/task-aliases.yml"
check "regenerates after the file changes, without a rebuild" bash -c "cd $ws && task go-task:aliases >/dev/null && task --list | grep -F 'hey:' && ! task --list | grep -F 'hi-me:'"
printf 'aliases: [unclosed\n' > "$ws/.devcontainer/task-aliases.yml"
check "a broken file never fails: exit 0 and task --list still works" bash -c "cd $ws && task-aliases generate >/dev/null && task --list"

reportResults
