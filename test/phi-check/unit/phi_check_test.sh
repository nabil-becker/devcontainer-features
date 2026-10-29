#!/usr/bin/env bash
# Docker-free tests of the phi-check Feature (src/phi-check): the Python unittest suite in
# test_phi_check.py (every rule with a positive and a near-miss, no output line holding the matched
# value, fail-closed paths, exit codes, the exceptions file, standard input, the importable module),
# then a mutation check: three deliberately broken copies of the patterns must each make that suite
# fail. Part of `task lint` (`task test:phi-check-unit`). Needs python3.
set -u
exec </dev/null

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../../src/phi-check"

if ! command -v python3 >/dev/null 2>&1; then echo "phi-check unit tests need python3" >&2; exit 1; fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail=0
echo "== unit suite"
if ! python3 "$here/test_phi_check.py"; then fail=1; fi

echo "== mutation check: a broken pattern must fail the suite"
mutate() { # <name> <sed expression>
  local copy="$T/$1"
  mkdir -p "$copy"
  cp "$src/phi_patterns.py" "$src/phi-check.py" "$src/devcontainer-feature.json" "$copy/"
  sed -i "$2" "$copy/phi_patterns.py"
  if cmp -s "$src/phi_patterns.py" "$copy/phi_patterns.py"; then
    echo "FAIL - mutation '$1' changed nothing (the sed expression no longer matches the module)"; fail=1; return
  fi
  if PHI_CHECK_SRC="$copy" python3 "$here/test_phi_check.py" >/dev/null 2>&1; then
    echo "FAIL - mutation '$1' passed the suite"; fail=1
  else
    echo "ok   - mutation '$1' is caught"
  fi
}
mutate ssn-group-00 's/ or group == "00"//'
mutate mbi-allows-S 's/_L = "\[AC-HJKMNP-RT-Y\]"/_L = "[A-Z]"/'
mutate window-of-five 's/^_WINDOW = 1 /_WINDOW = 2 /'

exit "$fail"
