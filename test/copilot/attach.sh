#!/bin/bash
# Scenario 'attach' (see scenarios.json): attach: facilitator at post-create. No facilitator Feature is
# installed in this image, so copilot-setup registers nothing and says so (the intent is kept in
# options.env); with a facilitator command on PATH, `task copilot:attach`'s command registers the
# entry through the real `copilot mcp add`, with no login and no token in the entry.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "the attach intent is recorded" grep -qx 'ATTACH=facilitator' /usr/local/share/copilot-feature/options.env
check "nothing is registered while the facilitator is not installed" bash -c "! copilot mcp list | grep -q facilitator"
check "setup says there is no entry to register" bash -c "copilot-setup | grep -q 'no entry to register'"
# shellcheck disable=SC2016  # expansion is meant to happen inside the inner bash
check "with a facilitator on PATH, setup registers the entry in COPILOT_HOME" bash -c '
  t=$(mktemp -d); mkdir -p "$t/bin"; printf "#!/bin/sh\nexit 0\n" > "$t/bin/facilitator"; chmod +x "$t/bin/facilitator"
  PATH="$t/bin:$PATH" copilot-setup | grep -q "registered the facilitator MCP entry" && copilot mcp list | grep -q "^  facilitator " && grep -q FACILITATOR_HANDLE "$COPILOT_HOME/mcp-config.json" && ! grep -qE "FACILITATOR_TOKEN=|\"env\"" "$COPILOT_HOME/mcp-config.json"'
check "a second setup leaves one entry" bash -c "t=\$(mktemp -d); mkdir -p \$t/bin; printf '#!/bin/sh\nexit 0\n' > \$t/bin/facilitator; chmod +x \$t/bin/facilitator; PATH=\$t/bin:\$PATH copilot-setup >/dev/null; [ \"\$(copilot mcp list | grep -c '^  facilitator ')\" = 1 ]"
check "the entry file is owner-only" bash -c "[ \"\$(stat -c %a \$COPILOT_HOME/mcp-config.json)\" = 600 ]"

reportResults
