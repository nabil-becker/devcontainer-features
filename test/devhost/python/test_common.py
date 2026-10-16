"""One source of truth for the DEVHOST_* settings: the bin scripts import the python/ module."""
from __future__ import annotations

import re
import subprocess
import sys
import unittest

import helpers as h

BIN_DIR = h.PYTHON_DIR.parent / "bin"


class OneCommon(h.RepoCase):
    def test_no_second_common_module_in_bin(self):
        self.assertEqual(sorted(p.name for p in BIN_DIR.glob("*common*.py")), [])

    def test_every_default_lives_in_devhost_common_only(self):
        defaults = {"docs/ledger", "TODO.md", "LEXICON.md", "docs/adr", "docs/night-shift", ".devhost/redact-names.txt"}
        for path in BIN_DIR.glob("*.py"):
            text = path.read_text(encoding="utf-8")
            for value in defaults:
                self.assertNotIn(f'"{value}"', text, f"{path.name} repeats the default {value}")
            self.assertIsNone(re.search(r"^\s*(from|import) common\b", text, re.M), path.name)

    def test_redact_script_uses_the_shared_defaults(self):
        root = self.root
        h.write(root / ".devhost" / "redact-names.txt", "Someone Special\n")
        self.env["DEVHOST_FORBIDDEN_WORDS"] = "acme"
        done = subprocess.run([sys.executable, str(BIN_DIR / "redact.py")], input="Someone Special's AcmeCorp",
                              capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout, "the Operator's the OperatorCorp")


if __name__ == "__main__":
    unittest.main()
