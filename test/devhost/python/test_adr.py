"""adr.py: the next number, the filled template, the index row."""
from __future__ import annotations

import helpers as h


class Adr(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.adr = h.load("adr")
        h.load("init").scaffold(self.root)

    def test_the_first_record_and_the_next(self):
        record, index = self.adr.create(self.root, "Use a queue, not a table", date="2026-10-15")
        self.assertEqual(record.name, "0001-use-a-queue-not-a-table.md")
        text = record.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("# ADR-0001: Use a queue, not a table\n"))
        self.assertIn("| **Date** | 2026-10-15 |", text)
        self.assertIn("| 2026-10-15 | First draft. |", text)
        self.assertTrue(index.read_text(encoding="utf-8").endswith(
            "| [0001](0001-use-a-queue-not-a-table.md) | Use a queue, not a table | proposed | 2026-10-15 |\n"))
        second, _ = self.adr.create(self.root, "Second")
        self.assertEqual(second.name, "0002-second.md")
        self.assertEqual(h.load("verify").adrs(self.root), [])

    def test_the_cli(self):
        done = h.run(["adr", "Short", "title"], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("created docs/adr/0001-short-title.md and added it to docs/adr/README.md", done.stdout)
        self.assertEqual(h.run(["adr"], self.root, self.env).returncode, 2)
        self.assertEqual(h.run(["adr", "!!!"], self.root, self.env).returncode, 1)

    def test_without_a_template_it_says_so(self):
        (self.root / "docs" / "adr" / "0000-template.md").unlink()
        done = h.run(["adr", "x"], self.root, self.env)
        self.assertEqual(done.returncode, 1)
        self.assertIn("run devhost-init", done.stderr)
