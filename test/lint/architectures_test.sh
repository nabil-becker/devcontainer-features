#!/usr/bin/env bash
# Docker-free test of .github/scripts/check_architectures.py against a scratch tree: a fragment that
# matches passes; an unknown Feature id, a major that is not the current one, a bare id, an option the
# Feature does not have, a local Feature named by its published id, a wrong option type, a fragment
# that does not parse, an anti-pattern missing its "Caught by", and a 'jsonc planned' fragment that
# already passes each fail; a 'jsonc planned' fragment naming an option not built yet passes.
# Part of `task lint`. SCRIPT points the test at another copy of the script.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
script="${SCRIPT:-$here/../../.github/scripts/check_architectures.py}"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/tool" "$T/local-features/loc" "$T/docs/reference-architectures"
cat > "$T/src/tool/devcontainer-feature.json" <<'JSON'
{ "id": "tool", "version": "2.3.4", "options": {
  "version": { "type": "string", "default": "latest" },
  "flag": { "type": "boolean", "default": false },
  "kind": { "type": "string", "enum": ["a", "b"], "default": "a" } } }
JSON
printf '{ "id": "loc", "version": "0.1.0", "options": { "name": { "type": "string" } } }\n' \
  > "$T/local-features/loc/devcontainer-feature.json"
printf '# Index\n\n- [Example](example.md)\n' > "$T/docs/reference-architectures/README.md"

P=ghcr.io/nabil-becker/devcontainer-features
arch() { # <features object body> [fence info] [anti-pattern tail]
  local tail="${3:-- **Caught by:** nothing yet}"
  cat > "$T/docs/reference-architectures/example.md" <<DOC
# Example

\`\`\`text
diagram
\`\`\`

\`\`\`jsonc
{
  // a comment, and a trailing comma below
  "features": {
    $1,
  }
}
\`\`\`

## Best practices

- Do it.

## Anti-patterns

### AP1 Thing

- **Don't:** a
- **Why:** b
- **Instead:** c
$tail
DOC
  if [ -n "${2:-}" ]; then
    # shellcheck disable=SC2016
    printf '\n```jsonc planned\n{ "features": { %s } }\n```\n' "$2" >> "$T/docs/reference-architectures/example.md"
  fi
}

pass=0 fail=0
run() { # <name> <expected exit> [expected text]
  local out rc want
  out="$(python3 -I "$script" "$T" 2>&1)"; rc=$?
  if [ "$rc" = "$2" ] && { [ -z "${3:-}" ] || printf '%s' "$out" | grep -qF -- "$3"; }; then
    pass=$((pass + 1)); echo "ok   - $1"
  else
    want="exit $2"; [ -n "${3:-}" ] && want="$want and \"$3\""
    fail=$((fail + 1)); echo "FAIL - $1 (expected $want, got exit $rc)"; echo "$out"
  fi
}

arch "\"$P/tool:2\": { \"version\": \"1.0\", \"flag\": true, \"kind\": \"b\" }, \"./features/loc\": { \"name\": \"x\" }, \"ghcr.io/other/features/thing:9\": { \"anything\": 1 }"
run "a matching fragment passes (comments, trailing commas, a local and a third-party Feature)" 0 "1 fragment"

arch "\"$P/nothere:1\": {}"
run "an id that is not in src/ fails" 1 "no Feature 'nothere' in src/"

arch "\"$P/loc:0\": {}"
run "a local Feature named by its published id fails and says what to write" 1 "reference it as ./features/loc"

arch "\"$P/tool:1\": {}"
run "a major that is not the current one fails" 1 "the major is 2"

arch "\"$P/tool\": {}"
run "a bare id (no major) fails" 1 "name the major"

arch "\"$P/tool:2.3\": {}"
run "a minor in the tag fails" 1 "the major is 2"

arch "\"$P/tool:2\": { \"flagg\": true }"
run "an option the Feature does not have fails" 1 "option 'flagg' is not"

arch "\"$P/tool:2\": { \"flag\": \"yes\" }"
run "a wrong option type fails" 1 "is a boolean"

arch "\"$P/tool:2\": { \"kind\": \"c\" }"
run "a value outside the enum fails" 1 "one of"

arch "\"./features/nothere\": {}"
run "a local reference to nothing fails" 1 "no Feature 'nothere'"

arch "\"$P/tool:2\": {}" "\"$P/tool:2\": { \"mode\": \"server\" }"
run "a planned fragment with an option not built yet passes" 0

arch "\"$P/tool:2\": {}" "\"$P/tool:2\": { \"flag\": true }"
run "a planned fragment that already passes fails" 1 "passes now"

arch "\"$P/tool:2\": {}" "" "- **Don't:** only"
run "an anti-pattern without its Caught by fails" 1 "has no '- **Caught by:**'"

arch "\"$P/tool:2\": {"
sed -i 's/"features": {/"features" {/' "$T/docs/reference-architectures/example.md"
run "a fragment that does not parse fails" 1 "does not parse"

arch "\"$P/tool:2\": {}"
printf '# Index\n' > "$T/docs/reference-architectures/README.md"
run "an architecture not linked from the index fails" 1 "not linked from README.md"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
