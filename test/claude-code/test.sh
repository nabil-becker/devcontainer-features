#!/bin/bash
# Auto-generated scenario: the claude-code Feature with default options
# (install=auto, version=stable) on an image without a prior claude, so the
# native binary is installed. Run with:
#   devcontainer features test -f claude-code --skip-scenarios .
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "claude is on PATH" command -v claude
check "claude reports a version" bash -c "claude --version | grep -E '^[0-9]+\.[0-9]+\.[0-9]+'"
check "native binary installed" bash -c "[ \"\$(command -v claude)\" = /usr/local/bin/claude ]"
check "binary is root-owned" bash -c "[ \"\$(stat -c %U /usr/local/bin/claude)\" = root ]"
check "autoupdater disabled" bash -c "[ \"\$DISABLE_AUTOUPDATER\" = 1 ]"

check "claude-host on PATH" command -v claude-host
check "claude-host without HOST_SESSION runs claude" bash -c "HOST_SESSION= claude-host --version | grep -E '^[0-9]+\.[0-9]+\.[0-9]+'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "claude-host rejects a non-UUID" bash -c 'HOST_SESSION=not-a-uuid claude-host --version; [ "$?" -eq 2 ]'

# CLAUDE_HOST_PRINT_FLAG=1: print the flag pair, exit 0, never start claude.
# A fake claude first on PATH records being called; the transcript is looked up
# under a throwaway CLAUDE_CONFIG_DIR for the current directory.
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "claude-host print flag: transcript present prints --resume" bash -c '
  u=11111111-2222-3333-4444-555555555555; t=$(mktemp -d); mkdir -p "$t/bin" "$t/cfg/projects/$(pwd -P | sed "s/[^A-Za-z0-9]/-/g")"
  printf "#!/bin/sh\n[ \"\$1\" = agents ] && { echo \"[]\"; exit 0; }\necho called >> %s/called\n" "$t" > "$t/bin/claude"; chmod +x "$t/bin/claude"; : > "$t/cfg/projects/$(pwd -P | sed "s/[^A-Za-z0-9]/-/g")/$u.jsonl"
  out=$(PATH="$t/bin:$PATH" CLAUDE_CONFIG_DIR="$t/cfg" HOST_SESSION=$u CLAUDE_HOST_PRINT_FLAG=1 claude-host 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "--resume $u" ] && [ ! -e "$t/called" ]'
# shellcheck disable=SC2016
check "claude-host print flag: no transcript prints --session-id" bash -c '
  u=11111111-2222-3333-4444-555555555555; t=$(mktemp -d); mkdir -p "$t/bin" "$t/cfg"
  printf "#!/bin/sh\n[ \"\$1\" = agents ] && { echo \"[]\"; exit 0; }\necho called >> %s/called\n" "$t" > "$t/bin/claude"; chmod +x "$t/bin/claude"
  out=$(PATH="$t/bin:$PATH" CLAUDE_CONFIG_DIR="$t/cfg" HOST_SESSION=$u CLAUDE_HOST_PRINT_FLAG=1 claude-host 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "--session-id $u" ] && [ ! -e "$t/called" ]'
# shellcheck disable=SC2016
check "claude-host print flag: HOST_SESSION unset prints nothing" bash -c '
  t=$(mktemp -d); mkdir -p "$t/bin"
  printf "#!/bin/sh\n[ \"\$1\" = agents ] && { echo \"[]\"; exit 0; }\necho called >> %s/called\n" "$t" > "$t/bin/claude"; chmod +x "$t/bin/claude"
  out=$(PATH="$t/bin:$PATH" HOST_SESSION= CLAUDE_HOST_PRINT_FLAG=1 claude-host 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -e "$t/called" ]'
# shellcheck disable=SC2016
check "claude-host print flag: a non-UUID is still exit 2" bash -c 'HOST_SESSION=not-a-uuid CLAUDE_HOST_PRINT_FLAG=1 claude-host >/dev/null 2>&1; [ "$?" -eq 2 ]'

# claude-fleet: installed beside claude-host; with a fake claude that lists no live session,
# --plan names what it would start and starts nothing (the logic is covered Docker-free in
# test/claude-code/unit/live_session_test.sh; this checks the installed command works here).
check "claude-fleet on PATH" command -v claude-fleet
check "agent-adapter-claude on PATH" command -v agent-adapter-claude
check "agent-adapter-claude is root-owned" bash -c "[ \"\$(stat -c %U \"\$(command -v agent-adapter-claude)\")\" = root ]"
check "agent-adapter-claude supports wake" bash -c "agent-adapter-claude supports | grep -qx wake"
# shellcheck disable=SC2016
check "claude-host prints the deprecation line" bash -c 'HOST_SESSION= claude-host --version 2>&1 >/dev/null | grep -q "claude-host: deprecated"'
# shellcheck disable=SC2016
check "agent-adapter-claude list reads claude agents --json --all" bash -c '
  t=$(mktemp -d); mkdir -p "$t/bin"
  echo "[{\"id\":\"b1\",\"cwd\":\"/tmp\",\"kind\":\"background\",\"startedAt\":1,\"sessionId\":\"s1\",\"name\":\"host\",\"pid\":5}]" > "$t/agents.json"
  printf "#!/bin/sh\n[ \"\$1\" = agents ] && exec cat %s/agents.json\nexit 1\n" "$t" > "$t/bin/claude"; chmod +x "$t/bin/claude"
  [ "$(PATH="$t/bin:$PATH" agent-adapter-claude list)" = "$(printf "host\ts1\trunning\t/tmp")" ]'

check "claude-host-pin on PATH" command -v claude-host-pin
# shellcheck disable=SC2016
check "claude-host-pin never fails on bad input" bash -c 'echo garbage | claude-host-pin 2>/dev/null'
# shellcheck disable=SC2016
check "claude-fleet without SESSIONS exits 2" bash -c 'env -u SESSIONS -u SESSIONS_B64 claude-fleet >/dev/null 2>&1; [ "$?" -eq 2 ]'
# shellcheck disable=SC2016
check "claude-fleet --plan starts nothing" bash -c '
  t=$(mktemp -d); mkdir -p "$t/bin" "$t/w"
  printf "#!/bin/sh\n[ \"\$1\" = agents ] && [ \"\$2\" = --json ] && { echo \"[]\"; exit 0; }\necho called >> %s/called\n" "$t" > "$t/bin/claude"; chmod +x "$t/bin/claude"
  out=$(cd "$t/w" && PATH="$t/bin:$PATH" SESSIONS="a|S_A|.|" S_A=11111111-2222-3333-4444-555555555555 claude-fleet --plan 2>&1); rc=$?
  [ "$rc" -eq 0 ] && [ ! -e "$t/called" ] && printf "%s" "$out" | grep -q "a: would start: .*claude-host --bg"'

check "claude-code-setup on PATH" command -v claude-code-setup
check "dcf-persist on PATH" command -v dcf-persist
check "CLAUDE_CONFIG_DIR points at the Feature's state dir" bash -c "[ \"\$CLAUDE_CONFIG_DIR\" = /var/lib/devcontainer-features/claude-code ]"
# The Feature's volume is mounted in `devcontainer features test` (volume);
# any backing is accepted so the check is not engine-specific.
check "setup makes the state dir usable and reports it" bash -c "claude-code-setup | grep -Eq '^claude-code: /var/lib/devcontainer-features/claude-code \((volume|bind|image), writable\)\$' && [ -w /var/lib/devcontainer-features/claude-code ]"
check "setup is idempotent" bash -c "claude-code-setup | grep -Eq '^claude-code: /var/lib/devcontainer-features/claude-code \((volume|bind|image), writable\)\$'"
# shellcheck disable=SC2016
check "setup honours an overriding CLAUDE_CONFIG_DIR" bash -c 'd=$(mktemp -d)/cfg; CLAUDE_CONFIG_DIR="$d" claude-code-setup | grep -q "^claude-code: $d (image, writable)" && [ -d "$d" ]'

check "taskfile registered" test -f /usr/local/share/go-task/includes.d/claude-code.yml

reportResults
