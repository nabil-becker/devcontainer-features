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
        os.environ["DEVHOST_REVIEW_EVERY"] = "5"
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

    def test_the_review_threshold_is_25_and_a_setting(self):
        ledger = self.root / "docs" / "ledger" / "2026-10.md"
        h.write(ledger, ledger.read_text(encoding="utf-8") + "".join(
            h.entry(f"2026-10-{d:02d}", f"Thing {d}") for d in range(4, 8)))
        self.assertIn("6 entries since the start", self.b.briefing(self.root, refresh=False))
        self.assertNotIn("Review due", self.b.briefing(self.root, refresh=False))
        os.environ["DEVHOST_REVIEW_EVERY"] = "6"
        self.assertIn("Review due", self.b.briefing(self.root, refresh=False))
        os.environ["DEVHOST_REVIEW_EVERY"] = "junk"
        self.assertNotIn("Review due", self.b.briefing(self.root, refresh=False))
        h.write(ledger, ledger.read_text(encoding="utf-8") + "".join(
            h.entry(f"2026-10-{d:02d}", f"More {d}") for d in range(8, 27)))
        self.assertIn("25 entries since", self.b.briefing(self.root, refresh=False))
        self.assertIn("Review due", self.b.briefing(self.root, refresh=False))

    def test_below_the_threshold_no_review_is_due(self):
        text = self.b.briefing(self.root, refresh=False)
        self.assertIn("2 entries since the start (no review yet), 1 with friction.", text)
        self.assertNotIn("Review due", text)
        self.assertNotIn("pending", text)
        self.assertFalse(list((self.root / "docs" / "ledger").glob("costs-*")))

    def test_branches_line_is_quiet_when_all_is_in_order_and_says_what_is_left(self):
        h.git(self.root, "branch", "-q", "-m", "feature/first-item/1")
        self.assertNotIn("Branches:", self.b.briefing(self.root, refresh=False))
        h.write(self.root / "a.txt", "x\n")
        h.git(self.root, "add", "-A")
        h.git(self.root, "commit", "-q", "-m", "work")
        h.git(self.root, "branch", "-q", "oldname", "main")
        h.fake_gh(self.base, {})
        text = self.b.briefing(self.root, refresh=False)
        self.assertIn("Branches: 1 with work and no pull request, 1 named against the rule (task devhost:branches).", text)
        h.fake_gh(self.base, {"feature/first-item/1": ["MERGED"]})
        self.assertIn("Branches: 1 merged and not deleted, 1 named against the rule", self.b.briefing(self.root, refresh=False))

    def test_branches_line_survives_a_missing_gh_and_says_so(self):
        text = self.b.briefing(self.root, refresh=False)  # the test branch `work` breaks the rule
        self.assertIn("Branches: 1 named against the rule (task devhost:branches); pull requests not checked (gh unavailable).", text)

    def _gh(self, auth_ok: bool, helper: bool):
        """A fake gh whose `auth status` succeeds or fails, and a global git config with or without the helper."""
        import os
        import stat
        import sys
        from unittest import mock
        fake = self.base / "fake-gh-auth"
        fake.write_text(f"#!{sys.executable}\nimport sys\nsys.exit({0 if auth_ok else 1})\n", encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        config = self.base / "gitconfig"
        config.write_text('[credential "https://github.com"]\n\thelper = !gh auth git-credential\n' if helper else "", encoding="utf-8")
        patch = mock.patch.dict(os.environ, {"DEVHOST_GH": str(fake), "GIT_CONFIG_GLOBAL": str(config), "GIT_CONFIG_NOSYSTEM": "1"})
        patch.start()
        self.addCleanup(patch.stop)
        return self.b.briefing(self.root, refresh=False)

    def test_gh_auth_line_is_quiet_when_all_is_well_or_gh_is_absent(self):
        self.assertNotIn("GitHub writes", self.b.briefing(self.root, refresh=False))  # no gh: the test default
        self.assertNotIn("GitHub writes", self._gh(auth_ok=True, helper=True))

    def test_gh_auth_line_names_the_two_commands_when_login_or_helper_is_missing(self):
        for auth_ok, helper, what in ((False, True, "gh is not logged in to GitHub"),
                                       (True, False, "git has no credential helper for github.com"),
                                       (False, False, "gh is not logged in to GitHub and git has no credential helper for github.com")):
            text = self._gh(auth_ok, helper)
            self.assertIn(f"GitHub writes (push, pull requests) will fail: {what}. In a container terminal run", text)
            self.assertIn("`gh auth login --web --git-protocol https`", text)
            self.assertIn("`gh auth setup-git`", text)

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

    def test_the_entry_rate_and_the_target_line(self):
        ledger = self.root / "docs" / "ledger" / "2026-10.md"
        h.write(ledger, "".join(h.entry(d, f"T{i}") for i, d in enumerate(
            ["2026-10-05", "2026-10-05", "2026-10-06", "2026-10-06", "2026-10-06", "2026-10-13"])))
        text = self.report.render(self.root, "2026-10")
        self.assertIn("Entry rate: 6 entries on 3 days with entries, 2.0 per day, 3.0 per week (over 2 weeks with entries). "
                      "A review every 25 entries (DEVHOST_REVIEW_EVERY) comes every 12.5 days at this rate.", text)
        self.assertNotIn("target", text.split("## By model")[0])
        self.assertIn("no ledger entries in 2026-11", self.report.render(self.root, "2026-11"))
        os.environ["DEVHOST_MONTHLY_TARGET"] = "200"
        os.environ["DEVHOST_REVIEW_EVERY"] = "10"
        text = self.report.render(self.root, "2026-10")
        self.assertIn("Spend $0.02 of the $200 target (0%), a tracking point, not a cap.", text)
        self.assertIn("A review every 10 entries (DEVHOST_REVIEW_EVERY) comes every 5.0 days", text)
        self.assertIn("list-price estimate: $0.02 of the $200 target (inters", self.report.summary(self.root, "2026-10"))

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

    def test_a_rebuild_loses_no_history(self):
        before = self.report.summary(self.root, "2026-10")
        self.report.write_report(self.root, "2026-10")
        store = self.root / "docs" / "ledger" / "costs-2026-10-tester.jsonl"
        self.assertEqual(len(store.read_text(encoding="utf-8").splitlines()), 3, "two replies and one run stored")
        self.assertNotIn(h.PERSON, store.read_text(encoding="utf-8"))
        # the volumes are emptied: no transcripts, no run records
        for p in h.project_folder(self.root).rglob("*.jsonl"):
            p.unlink()
        (self.base / "state" / "runs.jsonl").unlink()
        self.report.write_report(self.root, "2026-10")
        self.assertEqual(self.report.summary(self.root, "2026-10"), before, "the store keeps what the volumes lost")
        self.assertEqual(len(store.read_text(encoding="utf-8").splitlines()), 3, "regenerating stores nothing twice")

    def test_a_baseline_adds_to_every_table(self):
        tables = {
            "sessions": {"sess-0": {"models": ["claude-opus-5-5"], "replies": 10, "cost": 2.0, "first": "2026-10-01T09:00", "last": "2026-10-01T10:00"}},
            "cons": {"general-purpose|claude-sonnet-5-5": {"runs": 2, "replies": 8, "cost": 1.0}},
            "backs": {"scribe": {"models": ["haiku"], "runs": 4, "changed": 2, "nothing": 2, "cost": 0.4, "duration_s": 40.0, "stretch_chars": 400}},
            "models": {"opus": {"inters": 2.0, "n": 10, "out": 500}},
            "days": {"2026-10-01": {"inters": 2.0, "cons": 1.0, "backs": 0.4}},
        }
        # a local reply at or before `until` is already counted in the baseline
        h.write(self.root / "docs" / "ledger" / "costs-2026-10-tester.jsonl",
                json.dumps({"baseline": {"until": "2026-10-05T10:00:01.000Z", "tables": tables}}) + "\n")
        text = self.report.render(self.root, "2026-10")
        self.assertIn("Total: $3.40. Inter sessions: $2.00 in 1 sessions. Cons: $1.00 in 3 runs. Backs: $0.40 in 4 runs", text)
        self.assertIn("| sess-0 | claude-opus-5-5 | 10 | $2.00 |", text)
        self.assertNotIn("| sess-1 |", text)  # 10:00:01, not after `until`
        self.assertIn("| Explore | claude-haiku-5 | 1 | 1 |", text)  # 2026-10-06, after it
        self.assertIn("| general-purpose | claude-sonnet-5-5 | 2 | 8 | $1.00 | $0.50 |", text)
        self.assertIn("| scribe | haiku | 4 | 2 | 2 |", text)
        self.assertIn("| 2026-10-01 | $2.00 | $1.00 | $0.40 | $3.40 |", text)
