"""shutdown.py: each rule on a temporary repository (clean and pushed, locks, pending stretches,
night shift) and the entrypoint's exit status and lines."""
from __future__ import annotations

import os
import sys
import time
import unittest
from pathlib import Path

import helpers as h

try:
    import fcntl
except ImportError:  # Windows: the lock rule cannot run there
    fcntl = None


class Shutdown(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.sd = h.load("shutdown")
        self.state = Path(self.env["DEVHOST_STATE"])
        remote = self.base / "remote.git"
        h.git(self.base, "init", "-q", "--bare", str(remote))
        h.git(self.root, "remote", "add", "origin", str(remote))
        h.git(self.root, "push", "-q", "-u", "origin", "work")

    def commit(self, name: str = "a.txt") -> None:
        h.write(self.root / name, "x\n")
        h.git(self.root, "add", "-A")
        h.git(self.root, "commit", "-q", "-m", "change")

    def test_ready_when_clean_and_pushed(self):
        findings, notes = self.sd.run(self.root)
        self.assertEqual(findings, [])
        self.assertEqual(notes, [])
        done = h.run(["shutdown"], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("ready to stop", done.stdout)

    def test_changed_and_untracked_files_are_findings(self):
        h.write(self.root / "docs" / "ledger" / "README.md", "edit\n")
        h.git(self.root, "add", "-A")
        h.write(self.root / "scratch.txt", "x\n")
        h.write(self.root / ".claude" / "settings.json", "{\"a\": 1}\n")
        text = "\n".join(self.sd.tree(self.root))
        self.assertIn("2 changed file(s)", text)
        self.assertIn("1 untracked file(s): scratch.txt", text)

    def test_unpushed_commit_is_a_finding(self):
        self.commit()
        self.assertIn("1 commit(s) not pushed", self.sd.pushed(self.root)[0])
        h.git(self.root, "push", "-q")
        self.assertEqual(self.sd.pushed(self.root), [])

    def test_no_upstream_is_a_finding(self):
        h.git(self.root, "switch", "-q", "-c", "lonely")
        self.assertIn("no upstream", self.sd.pushed(self.root)[0])

    def test_detached_head_is_a_finding(self):
        h.git(self.root, "checkout", "-q", "--detach")
        self.assertIn("detached HEAD", self.sd.pushed(self.root)[0])

    def test_unfinished_branch_is_a_finding_and_a_merged_one_a_note(self):
        h.git(self.root, "branch", "-q", "-m", "work", "feature/x/1")
        h.git(self.root, "push", "-q", "-u", "origin", "feature/x/1")
        self.commit()
        h.git(self.root, "push", "-q", "origin", "feature/x/1")
        h.git(self.root, "branch", "-q", "fix/y/1", "main")
        h.fake_gh(self.base, {})
        findings, notes = self.sd.run(self.root)
        self.assertEqual(findings, ["branch feature/x/1 has commits that add to main and no pull request (unfinished work)"])
        h.fake_gh(self.base, {"feature/x/1": ["OPEN"], "fix/y/1": ["MERGED"]})
        findings, notes = self.sd.run(self.root)
        self.assertEqual(findings, [])
        self.assertEqual(notes, ["branch fix/y/1: its pull request merged and it still exists (task devhost:branches PRUNE=1)"])

    def test_stash_is_a_note_not_a_failure(self):
        h.write(self.root / "docs" / "ledger" / "README.md", "edit\n")
        h.git(self.root, "add", "-A")
        h.git(self.root, "stash", "-q")
        findings, notes = self.sd.run(self.root)
        self.assertEqual(findings, [])
        self.assertIn("1 stash(es)", notes[0])
        self.assertEqual(h.run(["shutdown"], self.root, self.env).returncode, 0)

    def test_missing_state_is_fine(self):
        self.assertEqual(self.sd.locks(self.root), [])
        self.assertEqual(self.sd.pending(self.root), [])

    @unittest.skipIf(fcntl is None, "flock is not available")
    def test_a_held_lock_is_a_finding_and_a_free_one_is_not(self):
        for job in ("scribe", "tester"):
            (self.state / job).mkdir(parents=True)
            (self.state / job / "lock").write_text("")
        self.assertEqual(self.sd.locks(self.root), [])
        with open(self.state / "scribe" / "lock", "rb") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            found = self.sd.locks(self.root)
            self.assertEqual(len(found), 1)
            self.assertIn("scribe back is running", found[0])
        with open(self.state / "tester" / "lock", "rb") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            self.assertIn("tester run is in progress", "\n".join(self.sd.locks(self.root)))
        self.assertEqual(self.sd.locks(self.root), [])

    def test_a_non_empty_pending_file_is_a_finding(self):
        job = self.state / "scribe"
        job.mkdir(parents=True)
        (job / "pending-aaa").write_text("")
        self.assertEqual(self.sd.pending(self.root), [])
        (job / "pending-bbb").write_text("a unit still open")
        found = self.sd.pending(self.root)
        self.assertEqual(len(found), 1)
        self.assertIn("pending-bbb", found[0])
        self.assertEqual(h.run(["shutdown"], self.root, self.env).returncode, 1)

    def test_a_stale_pending_file_is_a_note_not_a_finding(self):
        job = self.state / "scribe"
        job.mkdir(parents=True)
        old = job / "pending-finished-subagent"
        old.write_text("a stretch from a session that ended")
        day_and_more = time.time() - (self.sd.STALE_HOURS + 1) * 3600
        os.utime(old, (day_and_more, day_and_more))
        self.assertEqual(self.sd.pending(self.root), [])
        self.assertTrue(any("pending-finished-subagent" in n and "not counted" in n for n in self.sd.notes(self.root)))
        fresh = job / "pending-live"
        fresh.write_text("a stretch from this session")
        found = self.sd.pending(self.root)
        self.assertEqual(len(found), 1)
        self.assertIn("pending-live", found[0])
        self.assertNotIn("pending-finished-subagent", found[0])

    def test_night_shift(self):
        folder = self.root / "docs" / "night-shift"
        self.assertEqual(self.sd.night_shift(self.root), [])
        h.write(folder / "README.md", "# reports\n")
        self.assertEqual(self.sd.night_shift(self.root), [])
        h.write(folder / "2026-10-16.md", "# Night shift\n\nPlan: 1 items\n")
        self.assertIn("mid-plan", self.sd.night_shift(self.root)[0])
        h.write(folder / "2026-10-17.md", "# N\n\nPlan: 1\nResult: Done 1 · Ended 00:50, done\n\n### 1. x t: done\n")
        self.assertEqual(self.sd.night_shift(self.root), [])  # only the newest report counts
        h.write(folder / "2026-10-18.md", "# N\n\nPlan: 2\nResult: Done 1 · Ended 02:00, cap\n\n### 2. y t: planned\n")
        self.assertIn("still planned", self.sd.night_shift(self.root)[0])

    def test_output_has_one_line_per_finding(self):
        self.commit("b.txt")
        h.write(self.root / "scratch.txt", "x\n")
        done = h.run(["shutdown"], self.root, self.env)
        self.assertEqual(done.returncode, 1)
        lines = [line for line in done.stdout.splitlines() if line.startswith("NOT READY")]
        self.assertEqual(len(lines), 2, done.stdout)
        self.assertIn("2 finding(s)", done.stdout)


if __name__ == "__main__":
    unittest.main()
