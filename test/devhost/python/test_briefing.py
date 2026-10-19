"""briefing.py and report.py: the counts in the briefing, the JSON for the hook, the cost report."""
from __future__ import annotations

import json
import os

import helpers as h


class Briefing(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.b = h.load("briefing")
        self.report = h.load("report")

    def test_counts_review_due_backlog_night_shift_and_pending(self):
        ledger = self.root / "docs" / "ledger" / "2026-10.md"
        h.write(ledger, ledger.read_text(encoding="utf-8") + "## Review 2026-10-03\n\nreviewed.\n\n" + "".join(
            h.entry(f"2026-10-{d:02d}", f"Thing {d}", "[docs] missing" if d % 2 else "none") for d in range(4, 9)))
        h.write(self.root / "TODO.md", "# To do\n\n## Now\n\n- [ ] **first-item A** (host). x. Added 2026-10-01.\n- [x] **second-item B** (host). x. Done.\n"
                "- [ ] **third-item C** (host). x.\n\n## Decisions for the Operator\n\n- [ ] **fourth-item D** (the Operator). x.\n")
        h.write(self.root / "docs" / "night-shift" / "2026-10-07.md", "# Night shift 2026-10-07\n\nPlan: 1\nResult: Done 1\n")
        h.write(self.root / "docs" / "night-shift" / "2026-10-06.md", "# Night shift 2026-10-06\n\nPlan: 1\nReviewed by the Operator 2026-10-07.\n")
        state = self.base / "state"
        h.write(state / "secretary" / "pending-1.txt", "id clash")
        h.write(state / "scribe" / "job.log", "ts=1 status=changed notice=ok\nts=2 status=pending notice=the entry needs a title\n")
        h.write(state / "runs.jsonl", json.dumps({"ts": "2026-10-05T01:00:00Z", "job": "scribe", "model": "claude-haiku-5",
                                                  "status": "changed", "cost_usd": 0.02, "undone": 1, "output_tokens": 50}) + "\n"
                + "not json\n")
        text = self.b.briefing(self.root)
        self.assertIn("Ledger (docs/ledger/): 5 entries since the last review (2026-10-03), 2 with friction.", text)
        self.assertIn("Review due: run /ledger-review", text)
        self.assertIn("The scribe left something pending: the entry needs a title.", text)
        self.assertIn("The secretary left something pending: id clash.", text)
        self.assertIn("TODO.md: 2 open items, 1 decisions for the Operator.", text)
        self.assertIn("Night-shift report not yet reviewed: 2026-10-07 (say 'morning report').", text)
        self.assertIn("Agent spend", text)
        self.assertIn("backs $0.02 in 1 runs, 1 undone by guards", text)
        self.assertIn("Details: devhost-report.", text)
        self.assertNotIn(h.PERSON, text)  # seeded as the repo's git user.name by h.make_repo
        report = self.root / "docs" / "ledger" / f"costs-{self.b.month()}-tester.md"
        self.assertTrue(report.exists(), "the briefing rewrites the month's cost report")

    def test_below_the_threshold_no_review_is_due(self):
        text = self.b.briefing(self.root, refresh=False)
        self.assertIn("2 entries since the start (no review yet), 1 with friction.", text)
        self.assertNotIn("Review due", text)
        self.assertNotIn("pending", text)
        self.assertFalse(list((self.root / "docs" / "ledger").glob("costs-*")))

    def _versions(self, installed, source):
        share = self.base / "share"
        if installed is not None:
            h.write(share / "VERSION", installed + "\n")
        os.environ["DEVHOST_SHARE"] = str(share)
        self.addCleanup(os.environ.pop, "DEVHOST_SHARE", None)
        if source is not None:
            h.write(self.root / "src" / "devhost" / "devcontainer-feature.json", json.dumps({"id": "devhost", "version": source}))
        return self.b.briefing(self.root, refresh=False)

    def test_a_stale_install_is_warned_about_numerically(self):
        text = self._versions("1.2.3", "1.10.0")
        self.assertIn("devhost 1.2.3 is installed, src has 1.10.0: rebuild for the fixes to take effect", text)

    def test_equal_older_or_missing_versions_stay_silent(self):
        for installed, source in (("1.2.3", "1.2.3"), ("1.10.0", "1.9.0"), (None, "1.2.3"), ("1.2.3", None), ("junk", "1.2.3")):
            with self.subTest(installed=installed, source=source):
                self.assertNotIn("rebuild", self._versions(installed, source))
                self.assertNotIn("is installed", self.b.briefing(self.root, refresh=False))

    def test_the_hook_json(self):
        done = h.run(["briefing", "--json", "--no-refresh"], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        payload = json.loads(done.stdout)
        self.assertEqual(payload["hookSpecificOutput"]["hookEventName"], "SessionStart")
        self.assertEqual(payload["systemMessage"], payload["hookSpecificOutput"]["additionalContext"])
        self.assertIn("Ledger (docs/ledger/)", payload["systemMessage"])
        plain = h.run(["briefing", "--no-refresh"], self.root, self.env)
        self.assertEqual(plain.stdout.strip(), payload["systemMessage"])


class Report(h.RepoCase):
    def test_corrects_none_is_not_a_correction(self):
        ledger = self.root / "docs" / "ledger" / "2026-10.md"
        h.write(ledger, ledger.read_text(encoding="utf-8") + "\n### 2026-10-09 A\n- **Corrects:** none\n"
                "\n### 2026-10-10 B\n- **Corrects:** None.\n\n### 2026-10-11 C\n- **Corrects:** NONE  \n"
                "\n### 2026-10-12 D\n- **Corrects:** 2026-10-09 A\n")
        self.assertEqual(self.report.corrections(self.root, "2026-10"), 1)

    def setUp(self) -> None:
        super().setUp()
        self.report = h.load("report")
        folder = h.project_folder(self.root)
        h.write_jsonl(folder / "sess-1.jsonl", [
            h.user(), h.assistant("m1", "claude-opus-5-5", "2026-10-05T10:00:01.000Z", h.usage(1000, 100))])
        sub = folder / "sess-1" / "subagents" / "agent-x1.jsonl"
        h.write_jsonl(sub, [h.assistant("m2", "claude-haiku-5", "2026-10-06T11:00:00.000Z", h.usage(2000, 200))])
        h.write(sub.with_name("agent-x1.meta.json"), '{"agentType": "Explore"}\n')
        h.write(self.base / "state" / "runs.jsonl", json.dumps({"ts": "2026-10-05T01:00:00Z", "job": "scribe", "model": "claude-haiku-5",
                                                               "status": "nothing", "cost_usd": 0.01, "duration_s": 4}) + "\n")

    def test_the_report_uses_the_new_words_and_the_month(self):
        text = self.report.render(self.root, "2026-10")
        self.assertTrue(text.startswith("# Agent costs, 2026-10, tester\n"))
        self.assertIn("| Model | Inters | Cons | Backs | Total | Replies or runs | Tokens out |", text)
        self.assertIn("| opus | $0.01 | $0.00 | $0.00 | $0.01 | 1 | 100 |", text)
        self.assertIn("| haiku | $0.00 | $0.00 | $0.01 | $0.01 | 2 | 200 |", text)
        self.assertIn("## Inter sessions", text)
        self.assertIn("| sess-1 | claude-opus-5-5 | 1 |", text)
        self.assertIn("| Explore | claude-haiku-5 | 1 | 1 |", text)
        self.assertIn("| scribe | claude-haiku-5 | 1 | 0 | 1 | 0 | 0 |", text)
        self.assertIn("decision for the Operator", text)
        self.assertNotIn(h.PERSON, text)  # seeded as the repo's git user.name by h.make_repo
        self.assertEqual(self.report.render(self.root, "2026-11").count("| $"), 0, "another month has no rows")

    def test_summary_and_the_cli_write_the_file(self):
        line = self.report.summary(self.root, "2026-10")
        self.assertTrue(line.startswith("Agent spend 2026-10 to date on this machine (tester), list-price estimate: $0.02 (inters $0.01, cons $0.00, backs $0.01 in 1 runs, 0 undone by guards; 0 ledger corrections)."), line)
        done = h.run(["report", "2026-10"], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), "docs/ledger/costs-2026-10-tester.md")
        self.assertTrue((self.root / "docs" / "ledger" / "costs-2026-10-tester.md").exists())
        self.assertEqual(h.run(["report", "--summary"], self.root, self.env).returncode, 0)
        self.assertEqual(h.run(["report", "nonsense"], self.root, self.env).returncode, 2)
        self.assertTrue(h.run(["report", "--log"], self.root, self.env).stdout.startswith("no job runs recorded under"))
        h.write(self.base / "state" / "scribe" / "job.log", "line 1\nline 2\n")
        self.assertEqual(h.run(["report", "--log", "1"], self.root, self.env).stdout.strip(), "== scribe\nline 2")
