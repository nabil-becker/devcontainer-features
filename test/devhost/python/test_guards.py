"""guards.py: the backlog guard and the docs guard, as functions and as the CLI the jobs call."""
from __future__ import annotations

import helpers as h

BACKLOG = ["# To do", "", "## Now", "", "- [ ] **TD-01 One** (host). Why. Added 2026-10-01.",
           "- [ ] **TD-02 Two** (host). Why. Added 2026-10-01.", "", "## Decisions for the Operator", ""]
ADR = ["# ADR-0001: One", "", "| | |", "|---|---|", "| **Status** | proposed |", "| **Date** | 2026-10-01 |", "",
       "## Context", "", "x", "", "## Decision", "", "y", ""]
INDEX = ["# ADRs", "", "| ADR | Title | Status | Date |", "|---|---|---|---|",
         "| [0001](0001-one.md) | One | proposed | 2026-10-01 |"]


class BacklogGuard(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.g = h.load("guards")

    def test_a_tick_and_new_lines_are_fine(self):
        after = BACKLOG[:4] + ["- [x] **TD-01 One** (host). Why. Added 2026-10-01. Done 2026-10-02."] + BACKLOG[5:6] + [
            "- [ ] **TD-03 Three** (host). Why. Added 2026-10-02."] + BACKLOG[6:] + ["- [ ] **TD-04 Pick** (the Operator). A or B. Added 2026-10-02."]
        self.assertIsNone(self.g.backlog_guard(BACKLOG, after))

    def test_a_reorder_a_reword_and_a_removal_are_refused(self):
        reordered = BACKLOG[:4] + [BACKLOG[5], BACKLOG[4]] + BACKLOG[6:]
        # TD-01 is found after TD-02; TD-02 is then the line that cannot follow it, so it is reported
        self.assertEqual(self.g.backlog_guard(BACKLOG, reordered), "changed or lost: " + BACKLOG[5])
        reworded = BACKLOG[:5] + ["- [ ] **TD-02 Two reworded** (host). Why. Added 2026-10-01."] + BACKLOG[6:]
        self.assertEqual(self.g.backlog_guard(BACKLOG, reworded), "changed or lost: " + BACKLOG[5])
        removed = BACKLOG[:5] + BACKLOG[6:]
        self.assertIsNotNone(self.g.backlog_guard(BACKLOG, removed))
        heading_suffixed = BACKLOG[:2] + ["## Now and then"] + BACKLOG[3:]
        self.assertIsNotNone(self.g.backlog_guard(BACKLOG, heading_suffixed), "a heading may not grow a suffix")

    def test_the_cli_exits_one_on_a_change(self):
        before, after = self.base / "before.md", self.base / "after.md"
        h.write(before, "\n".join(BACKLOG) + "\n")
        h.write(after, "\n".join(BACKLOG[:5] + BACKLOG[6:]) + "\n")
        done = h.run(["guards", "backlog", str(before), str(after)], self.root, self.env)
        self.assertEqual(done.returncode, 1)
        self.assertTrue(done.stdout.startswith("changed or lost: - [ ] **TD-02"))
        h.write(after, "\n".join(BACKLOG) + "\n")
        self.assertEqual(h.run(["guards", "backlog", str(before), str(after)], self.root, self.env).returncode, 0)
        self.assertEqual(h.run(["guards", "nonsense", "a", "b"], self.root, self.env).returncode, 2)


class DocsGuard(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.g = h.load("guards")
        self.snapshot = self.base / "snapshot"
        h.write(self.snapshot / "LEXICON.md", "# Lexicon\n\n- **A**: one.\n")
        h.write(self.snapshot / "adr" / "0001-one.md", "\n".join(ADR) + "\n")
        h.write(self.snapshot / "adr" / "README.md", "\n".join(INDEX) + "\n")
        h.write(self.root / "LEXICON.md", "# Lexicon\n\n- **A**: one.\n")
        h.write(self.root / "docs" / "adr" / "0001-one.md", "\n".join(ADR) + "\n")
        h.write(self.root / "docs" / "adr" / "README.md", "\n".join(INDEX) + "\n")

    def test_adding_and_a_status_change_are_fine(self):
        h.write(self.root / "LEXICON.md", "# Lexicon\n\n- **A**: one.\n- **B**: two.\n")
        adr = ADR[:]
        adr[4] = "| **Status** | superseded by ADR-0002 |"
        h.write(self.root / "docs" / "adr" / "0001-one.md", "\n".join(adr) + "\n")
        h.write(self.root / "docs" / "adr" / "0002-two.md", "# ADR-0002: Two\n")
        h.write(self.root / "docs" / "adr" / "README.md", "\n".join(INDEX[:4] + [
            "| [0001](0001-one.md) | One | superseded by ADR-0002 | 2026-10-01 |",
            "| [0002](0002-two.md) | Two | proposed | 2026-10-02 |"]) + "\n")
        self.assertIsNone(self.g.docs_guard(self.snapshot, self.root))

    def test_a_removed_adr_line_is_refused(self):
        h.write(self.root / "docs" / "adr" / "0001-one.md", "\n".join(ADR[:9] + ADR[10:]) + "\n")
        self.assertEqual(self.g.docs_guard(self.snapshot, self.root), "docs/adr/0001-one.md: changed or lost: x")

    def test_a_changed_lexicon_line_and_a_removed_adr_are_refused(self):
        h.write(self.root / "LEXICON.md", "# Lexicon\n\n- **A**: changed.\n")
        self.assertEqual(self.g.docs_guard(self.snapshot, self.root), "LEXICON.md: changed or lost: - **A**: one.")
        h.write(self.root / "LEXICON.md", "# Lexicon\n\n- **A**: one.\n")
        (self.root / "docs" / "adr" / "0001-one.md").unlink()
        self.assertEqual(self.g.docs_guard(self.snapshot, self.root), "docs/adr/0001-one.md: removed")

    def test_an_index_row_may_only_change_its_status(self):
        h.write(self.root / "docs" / "adr" / "README.md", "\n".join(INDEX[:4] + ["| [0001](0001-one.md) | Renamed | proposed | 2026-10-01 |"]) + "\n")
        self.assertIsNone(self.g.docs_guard(self.snapshot, self.root), "the guard sees the row's number, not its text")
        h.write(self.root / "docs" / "adr" / "README.md", "\n".join(INDEX[:4]) + "\n")
        self.assertTrue(self.g.docs_guard(self.snapshot, self.root).startswith("docs/adr/README.md: changed or lost"))

    def test_the_cli(self):
        self.assertEqual(h.run(["guards", "docs", str(self.snapshot), str(self.root)], self.root, self.env).returncode, 0)
        h.write(self.root / "LEXICON.md", "# Lexicon\n")
        done = h.run(["guards", "docs", str(self.snapshot), str(self.root)], self.root, self.env)
        self.assertEqual(done.returncode, 1)
        self.assertIn("LEXICON.md: changed or lost", done.stdout)
