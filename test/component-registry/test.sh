#!/bin/bash
# Auto-generated scenario: the component-registry Feature with default options on the base image.
# The commands, the start hook, the version, the option and the Taskfile are installed; on a temp
# repository with two path layers the installed dcf-registry resolves and explains (the logic is
# covered Docker-free in test/component-registry/unit/registry_test.sh; this checks the installed
# commands run on this base image, its awk included). Run with:
#   devcontainer features test -f component-registry --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "dcf-registry on PATH" command -v dcf-registry
check "registry-source-git on PATH" command -v registry-source-git
check "registry-source-path on PATH" command -v registry-source-path
check "registry-source-http on PATH (1.2.0)" command -v registry-source-http
check "the http source's curl helper is installed" test -f /usr/local/share/component-registry-feature/dcf-curl.sh
check "the http source says what it supports" bash -c "registry-source-http supports | grep -qx version"
check "the http source refuses a secret over plain http" bash -c "registry-source-http version l url=http://x.example.invalid/a.layer auth.secret=s 2>&1 | grep -F allow-insecure"
check "registry-source-db on PATH (1.5.0)" command -v registry-source-db
check "the db source says what it supports" bash -c "registry-source-db supports | grep -qx version"
check "the db source refuses an unsupported driver (exit 3)" bash -c "registry-source-db version l driver=oracle table=t; [ \$? -eq 3 ]"
check "component-registry-setup on PATH" command -v component-registry-setup
check "dcf-persist on PATH" command -v dcf-persist
check "the Feature version is baked" grep -qx '2.2.0' /usr/local/share/component-registry-feature/version
check "the registryFile option is baked (default)" grep -qx 'REGISTRYFILE=.devcontainer/registry.yml' /usr/local/share/component-registry-feature/options.env
check "COMPONENT_REGISTRY_STATE_DIR set" bash -c "[ \"\$COMPONENT_REGISTRY_STATE_DIR\" = /var/lib/devcontainer-features/component-registry ]"
check "setup makes the state folder owner-only" bash -c "component-registry-setup >/dev/null && [ \"\$(stat -c %a \"\$COMPONENT_REGISTRY_STATE_DIR\")\" = 700 ]"
check "state folder writable by the user" test -w /var/lib/devcontainer-features/component-registry
check "taskfile registered" test -f /usr/local/share/go-task/includes.d/component-registry.yml
check "the built-in base layer is installed (1.1.0)" bash -c "for s in registry-refresh registry-explain; do test -f /usr/local/share/component-registry-feature/base/\$s/SKILL.md || exit 1; done; test -f /usr/local/share/component-registry-feature/base/component-registry.layer"
check "minijinja-cli on PATH at the pinned version (1.11.0)" bash -c "minijinja-cli --version | grep -qx 'minijinja-cli 3.1.0'"
check "the base Claude template is installed (1.11.0)" test -f /usr/local/share/component-registry-feature/base/templates/claude/SKILL.md.j2
check "the base Copilot template is installed (2.1.0)" test -f /usr/local/share/component-registry-feature/base/templates/copilot/SKILL.md.j2
check "the sources say what they support" bash -c "registry-source-path supports | grep -qx version && registry-source-git supports | grep -qx fetch"

# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
setup='t=$(mktemp -d); mkdir -p "$t/repo/.devcontainer" "$t/a" "$t/b"
printf "[skills/demo]\nbody:text = base\nterms:list = a, b\n" > "$t/a/a.layer"
printf "[skills/demo]\nbody:text = mine\nterms:list = !a\n" > "$t/b/b.layer"
printf "layers:\n  - id: base\n    at: /Corp\n    sources:\n      - { kind: path, path: \"%s/a\" }\n  - id: mine\n    at: /Corp/me\n    sources:\n      - { kind: path, path: \"%s/b\" }\n" "$t" "$t" > "$t/repo/.devcontainer/registry.yml"
export COMPONENT_REGISTRY_STATE_DIR="$t/state"; cd "$t/repo"'
check "resolve refuses without a who-you-are path" bash -c "$setup; dcf-registry resolve 2>&1 | grep -F COMPONENT_REGISTRY_WHOAMI; [ \"\${PIPESTATUS[0]}\" -eq 2 ]"
check "resolve merges two layers" bash -c "$setup; COMPONENT_REGISTRY_WHOAMI=/Corp/me dcf-registry resolve >/dev/null && grep -qx b \"\$t/state/view/meta/skills/demo/values/terms\" && grep -qx mine \"\$t/state/view/skills/demo/SKILL.md\""
check "render through the base template equals the view (1.11.0)" bash -c "$setup; COMPONENT_REGISTRY_WHOAMI=/Corp/me dcf-registry resolve >/dev/null && COMPONENT_REGISTRY_WHOAMI=/Corp/me dcf-registry render claude \"\$t/out\" >/dev/null && diff -r \"\$t/state/view/skills\" \"\$t/out/skills\""
check "explain names the layer of each line" bash -c "$setup; dcf-registry resolve --as /Corp/me >/dev/null && dcf-registry explain skills/demo | grep -F 'used         mine@tree-'"
check "the base layer's utility skills are resolved" bash -c "$setup; dcf-registry resolve --as /Corp/me >/dev/null && test -f \"\$t/state/view/skills/registry-refresh/SKILL.md\""
check "layer-list finds the list" bash -c "$setup; dcf-registry layer-list | grep -q registry.yml"
check "remember is removed (exit 1)" bash -c "dcf-registry remember -- note >/dev/null 2>&1; [ \"\$?\" -eq 1 ]"

reportResults
