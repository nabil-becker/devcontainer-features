"""test_friction.py: the version-literal check for container tests and the TODO.md merge driver."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[3] / ".github" / "scripts"
CHECK = SCRIPTS / "check_versions.py"


class VersionLiterals(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "src" / "agents").mkdir(parents=True)
        (self.root / "test" / "agents").mkdir(parents=True)
        (self.root / "src" / "agents" / "devcontainer-feature.json").write_text(json.dumps({"version": "2.0.1"}))

    def tearDown(self):
        self.tmp.cleanup()

    def run_check(self, body):
        (self.root / "test" / "agents" / "test.sh").write_text(body)
        return subprocess.run([sys.executable, "-I", str(CHECK), str(self.root)], capture_output=True, text=True)

    def test_a_stale_baked_version_is_named_with_file_and_line(self):
        done = self.run_check("#!/bin/bash\ncheck 'v' grep -qx '2.0.0' /usr/local/share/agents-feature/version\n")
        self.assertEqual(done.returncode, 1)
        self.assertIn("test/agents/test.sh:2:", done.stderr)
        self.assertIn("2.0.1", done.stderr)

    def test_a_stale_task_version_output_is_named(self):
        done = self.run_check("check 't' bash -c \"task agents:version | grep -x 1.0.3\"\n")
        self.assertEqual(done.returncode, 1)
        self.assertIn("test.sh:1:", done.stderr)

    def test_current_versions_regexes_comments_and_tool_versions_pass(self):
        done = self.run_check("# grep -qx '1.0.0' /usr/local/share/agents-feature/version\n"
                              "check 'a' grep -qx '2.0.1' /usr/local/share/agents-feature/version\n"
                              "check 'b' bash -c \"task agents:version | grep -E '^[0-9]+'\"\n"
                              "check 'c' bash -c \"argocd version | grep 3.5.4\"\n")
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_the_repository_itself_passes(self):
        done = subprocess.run([sys.executable, "-I", str(CHECK)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True,
                          env={**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}).stdout


A = "- [ ] **alpha-item Alpha** (host). Why. Added 2026-10-01."
B = "- [ ] **beta-item Beta** (host). Why. Added 2026-10-01."
TICK = "- [x] **alpha-item Alpha** (host). Why. Added 2026-10-01. Done 2026-10-02."


if __name__ == "__main__":
    unittest.main()
