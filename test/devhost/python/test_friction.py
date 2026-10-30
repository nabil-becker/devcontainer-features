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
DRIVER = SCRIPTS / "merge_todo.py"


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


class TodoMergeDriver(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.name", "t")
        git(self.repo, "config", "user.email", "t@noreply.invalid")
        git(self.repo, "config", "merge.devhost-todo.driver", f"{sys.executable} -I {DRIVER} %O %A %B")
        (self.repo / ".gitattributes").write_text("TODO.md merge=devhost-todo\n")
        self.write(["# To do", "", A, B, "", "## Done", ""])
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-qm", "base")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, lines):
        (self.repo / "TODO.md").write_text("\n".join(lines) + "\n")

    def side(self, branch, lines):
        git(self.repo, "checkout", "-q", "-b", branch, "main")
        self.write(lines)
        git(self.repo, "commit", "-qam", branch)

    def merged(self, one, two):
        git(self.repo, "checkout", "-q", one)
        git(self.repo, "merge", "-q", "--no-edit", two)
        return (self.repo / "TODO.md").read_text().splitlines()

    def test_both_sides_tick_the_same_item_gives_one_ticked_line(self):
        self.side("one", ["# To do", "", TICK, B, "", "## Done", ""])
        self.side("two", ["# To do", "", TICK + " Also by two.", B, "", "## Done", ""])
        lines = self.merged("one", "two")
        self.assertEqual([x for x in lines if "alpha-item" in x], [TICK + " Also by two."])
        self.assertIn(B, lines)

    def test_both_add_different_items_at_the_same_spot_keeps_both(self):
        c, d = "- [ ] **gamma-item Gamma** (host). Why.", "- [ ] **delta-item Delta** (host). Why."
        self.side("one", ["# To do", "", A, B, c, "", "## Done", ""])
        self.side("two", ["# To do", "", A, B, d, "", "## Done", ""])
        lines = self.merged("one", "two")
        self.assertIn(c, lines)
        self.assertIn(d, lines)
        self.assertEqual(len([x for x in lines if "alpha-item" in x]), 1)

    def test_one_side_ticks_the_other_adds_gives_both_effects(self):
        c = "- [ ] **gamma-item Gamma** (host). Why."
        self.side("one", ["# To do", "", TICK, B, "", "## Done", ""])
        self.side("two", ["# To do", "", A, B, c, "", "## Done", ""])
        lines = self.merged("one", "two")
        self.assertIn(TICK, lines)
        self.assertNotIn(A, lines)
        self.assertIn(c, lines)

    def test_union_alone_would_double_the_tick(self):
        # the old behaviour (merge=union), so the cases above fail without the dedupe
        self.side("one", ["# To do", "", TICK, B, "", "## Done", ""])
        self.side("two", ["# To do", "", TICK + " Also by two.", B, "", "## Done", ""])
        (self.repo / ".gitattributes").write_text("TODO.md merge=union\n")
        git(self.repo, "checkout", "-q", "one")
        git(self.repo, "merge", "-q", "--no-edit", "two")
        lines = (self.repo / "TODO.md").read_text().splitlines()
        self.assertEqual(len([x for x in lines if "alpha-item" in x]), 2)


if __name__ == "__main__":
    unittest.main()
