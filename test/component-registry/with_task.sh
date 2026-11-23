#!/bin/bash
# Scenario 'with_task' (see scenarios.json): with go-task (git comes with the base image), the tasks
# resolve through the Feature Taskfile registry and a git layer (a local repository at a tag)
# resolves.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

registry=/usr/local/share/go-task/features.yml
check "the tasks are registered" bash -c "task -t $registry --list-all | grep -E '^\\* component-registry:(resolve|explain|version|setup):' | wc -l | grep -qx 4"

# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
setup='t=$(mktemp -d); export GIT_CONFIG_GLOBAL="$t/gc"; git config --global user.email t@example.invalid; git config --global user.name t
git init -q "$t/remote"; printf "[skills/g]\nv:value = one\n" > "$t/remote/g.layer"; git -C "$t/remote" add -A; git -C "$t/remote" commit -qm one; git -C "$t/remote" tag v1
mkdir -p "$t/repo/.devcontainer"; printf "layers:\n  - id: g\n    at: /Corp\n    sources:\n      - { kind: git, url: \"%s/remote\", tag: v1 }\n" "$t" > "$t/repo/.devcontainer/registry.yml"
export COMPONENT_REGISTRY_STATE_DIR="$t/state"; cd "$t/repo"'
check "a git layer at a tag resolves" bash -c "$setup; dcf-registry resolve --as /Corp/me | grep -F 'layer g source 1 (git): fetched' && grep -qx one \"\$t/state/view/meta/skills/g/values/v\""
check "task component-registry:resolve with the who-you-are path as a task variable" bash -c "$setup; printf \"version: '3'\nincludes:\n  f:\n    taskfile: $registry\n    flatten: true\n\" > Taskfile.yml; task component-registry:resolve COMPONENT_REGISTRY_WHOAMI=/Corp/me | grep -F 'from the task variable'"

reportResults
