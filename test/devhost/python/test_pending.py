"""pending.py: the scribe's PENDING items are counted per run and dropped at the third."""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import helpers as h


class Carry(unittest.TestCase):
    def setUp(self) -> None:
        self.p = h.load("pending")

    def test_split_ignores_none_empties_and_spacing(self):
        self.assertEqual(self.p.split_items("none"), [])
        self.assertEqual(self.p.split_items(" a  b ;; c ; none"), ["a b", "c"])

    def test_an_item_carried_three_runs_is_dropped_on_the_third(self):
        counts = {}
        kept, dropped, counts = self.p.carry(counts, "fix the build; write the ADR")
        self.assertEqual((kept, dropped), (["fix the build", "write the ADR"], []))
        kept, dropped, counts = self.p.carry(counts, "Fix the build ; write the ADR; a new one")
        self.assertEqual((kept, dropped), (["Fix the build", "write the ADR", "a new one"], []))
        kept, dropped, counts = self.p.carry(counts, "fix the build; write the ADR; a new one")
        self.assertEqual(dropped, ["fix the build", "write the ADR"])
        self.assertEqual(kept, ["a new one"])

    def test_an_item_that_leaves_and_returns_starts_again(self):
        _, _, counts = self.p.carry({}, "a; b")
        _, _, counts = self.p.carry(counts, "b")
        kept, dropped, counts = self.p.carry(counts, "a; b")
        self.assertEqual((kept, dropped), (["a"], ["b"]))

    def test_the_cli_keeps_counts_beside_the_file(self):
        with tempfile.TemporaryDirectory() as d:
            pending = Path(d) / "pending-s1"
            outs = [h.run(["pending", str(pending), "x; y"], Path(d)) for _ in range(3)]
            self.assertEqual([o.stdout for o in outs], ["x; y", "x; y", ""])
            self.assertIn("dropped a pending item carried 3 runs: x", outs[2].stderr)
            self.assertTrue((Path(d) / "pending-s1.counts").is_file())
            self.assertEqual(h.run(["pending", str(pending), "none"], Path(d)).stdout, "")


if __name__ == "__main__":
    unittest.main()
