"""guards.py: the backlog guard and the docs guard, as functions and as the CLI the jobs call."""
from __future__ import annotations

import helpers as h

BACKLOG = ["# To do", "", "## Now", "", "- [ ] **first-item One** (host). Why. Added 2026-10-01.",
           "- [ ] **second-item Two** (host). Why. Added 2026-10-01.", "", "## Decisions for the Operator", ""]
ADR = ["# ADR-0001: One", "", "| | |", "|---|---|", "| **Status** | proposed |", "| **Date** | 2026-10-01 |", "",
       "## Context", "", "x", "", "## Decision", "", "y", ""]
INDEX = ["# ADRs", "", "| ADR | Title | Status | Date |", "|---|---|---|---|",
         "| [0001](0001-one.md) | One | proposed | 2026-10-01 |"]


class BacklogGuard(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.g = h.load("guards")

    def test_a_tick_and_new_lines_are_fine(self):
        after = BACKLOG[:4] + ["- [x] **first-item One** (host). Why. Added 2026-10-01. Done 2026-10-02."] + BACKLOG[5:6] + [
            "- [ ] **third-item Three** (host). Why. Added 2026-10-02."] + BACKLOG[6:] + ["- [ ] **fourth-item Pick** (the Operator). A or B. Added 2026-10-02."]
        self.assertIsNone(self.g.backlog_guard(BACKLOG, after))

    def test_a_reorder_a_reword_and_a_removal_are_refused(self):
        reordered = BACKLOG[:4] + [BACKLOG[5], BACKLOG[4]] + BACKLOG[6:]
        # first-item is found after second-item; second-item is then the line that cannot follow it, so it is reported
        self.assertTrue(self.g.backlog_guard(BACKLOG, reordered).endswith("changed or lost: " + BACKLOG[5]))
        reworded = BACKLOG[:5] + ["- [ ] **second-item Two reworded** (host). Why. Added 2026-10-01."] + BACKLOG[6:]
        self.assertTrue(self.g.backlog_guard(BACKLOG, reworded).endswith("changed or lost: " + BACKLOG[5]))
        removed = BACKLOG[:5] + BACKLOG[6:]
        self.assertIsNotNone(self.g.backlog_guard(BACKLOG, removed))
        heading_suffixed = BACKLOG[:2] + ["## Now and then"] + BACKLOG[3:]
        self.assertIsNotNone(self.g.backlog_guard(BACKLOG, heading_suffixed), "a heading may not grow a suffix")

    def test_the_finding_names_the_line_and_the_rule(self):
        reworded = BACKLOG[:5] + ["- [ ] **second-item Two reworded** (host). Why. Added 2026-10-01."] + BACKLOG[6:]
        finding = self.g.backlog_guard(BACKLOG, reworded)
        self.assertIn("rule: an existing line may only be ticked", finding)
        self.assertIn("**second-item Two**", finding)

    def test_the_cli_prints_the_finding_then_a_capped_diff(self):
        before, after = self.base / "b.md", self.base / "a.md"
        h.write(before, "\n".join(BACKLOG) + "\n")
        reworded = BACKLOG[:5] + ["- [ ] **second-item Two reworded** (host). Why. Added 2026-10-01."] + BACKLOG[6:]
        h.write(after, "\n".join(reworded) + "\n")
        done = h.run(["guards", "backlog", str(before), str(after)], self.root, self.env)
        self.assertEqual(done.returncode, 1)
        first, _, diff = done.stdout.partition("\n")
        self.assertIn("rule:", first)
        self.assertIn("-- [ ] **second-item Two** (host)", diff)
        self.assertIn("+- [ ] **second-item Two reworded**", diff)

    def test_the_diff_is_capped(self):
        diff = self.g.rejected_diff(["a"], ["b" * 5000], cap=1500)
        self.assertLess(len(diff), 1700)
        self.assertIn("[diff clipped", diff)

    def test_the_cli_exits_one_on_a_change(self):
        before, after = self.base / "before.md", self.base / "after.md"
        h.write(before, "\n".join(BACKLOG) + "\n")
        h.write(after, "\n".join(BACKLOG[:5] + BACKLOG[6:]) + "\n")
        done = h.run(["guards", "backlog", str(before), str(after)], self.root, self.env)
        self.assertEqual(done.returncode, 1)
        self.assertTrue("changed or lost: - [ ] **second-item" in done.stdout)
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


class DocsGuardModel(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.g = h.load("guards")
        self.snapshot = self.base / "snapshot"
        for place in (self.snapshot / "model", self.root / "docs" / "model"):
            h.write(place / "ontology.toml", 'types = [\n  "role",\n]\n\n[host]\ntype = "role"\n')
            h.write(place / "themes" / "a.toml", 'host = "Merlin"\n')

    def test_adding_to_the_model_is_fine(self):
        h.write(self.root / "docs" / "model" / "ontology.toml", 'types = [\n  "role",\n  "place",\n]\n\n[host]\ntype = "role"\n\n[devhost]\ntype = "place"\n')
        h.write(self.root / "docs" / "model" / "c4.md", "new file\n")
        self.assertIsNone(self.g.docs_guard(self.snapshot, self.root))

    def test_a_changed_removed_or_deleted_model_line_is_refused(self):
        h.write(self.root / "docs" / "model" / "themes" / "a.toml", 'host = "Arthur"\n')
        self.assertEqual(self.g.docs_guard(self.snapshot, self.root), 'docs/model/themes/a.toml: changed or lost: host = "Merlin"')
        h.write(self.root / "docs" / "model" / "themes" / "a.toml", 'host = "Merlin"\n')
        (self.root / "docs" / "model" / "themes" / "a.toml").unlink()
        self.assertEqual(self.g.docs_guard(self.snapshot, self.root), "docs/model/themes/a.toml: removed")

    def test_a_model_file_replaced_by_one_word_is_refused(self):
        h.write(self.root / "docs" / "model" / "ontology.toml", "PLACEHOLDER\n")
        self.assertEqual(self.g.docs_guard(self.snapshot, self.root), "docs/model/ontology.toml: changed or lost: types = [")
        h.write(self.root / "docs" / "model" / "ontology.toml", "PLACEHOLDER")  # no newline, as a Write tool leaves it
        self.assertTrue(self.g.docs_guard(self.snapshot, self.root).startswith("docs/model/ontology.toml: changed or lost"))
        h.write(self.root / "docs" / "model" / "ontology.toml", "")
        self.assertTrue(self.g.docs_guard(self.snapshot, self.root).startswith("docs/model/ontology.toml: changed or lost"))

    def test_the_cli_refuses_a_wiped_model_with_the_snapshot_laid_out_as_the_job_does(self):
        # job.sh: cp -pR "$model_dir" "$tmp/snap/model" (the real repository's model, not a toy)
        import shutil
        real = h.HERE.parents[2] / "docs" / "model"
        shutil.rmtree(self.snapshot, ignore_errors=True)
        shutil.copytree(real, self.snapshot / "model")
        shutil.rmtree(self.root / "docs" / "model")
        shutil.copytree(real, self.root / "docs" / "model")
        args = ["guards", "docs", str(self.snapshot), str(self.root)]
        self.assertEqual(h.run(args, self.root, self.env).returncode, 0)
        h.write(self.root / "docs" / "model" / "ontology.toml", "PLACEHOLDER\n")
        done = h.run(args, self.root, self.env)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("docs/model/ontology.toml: changed or lost", done.stdout)

    def test_a_model_file_already_emptied_in_the_snapshot_is_still_refused(self):
        # something else emptied the file before the run's snapshot was taken: the comparison alone passes
        h.write(self.snapshot / "model" / "ontology.toml", "PLACEHOLDER\n")
        h.write(self.root / "docs" / "model" / "ontology.toml", "PLACEHOLDER\n")
        finding = self.g.docs_guard(self.snapshot, self.root)
        self.assertTrue(finding.startswith("docs/model/ontology.toml: not valid TOML"), finding)
