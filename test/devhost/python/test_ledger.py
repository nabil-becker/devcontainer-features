"""ledger.py and the records outside git: the settings (DEVHOST_RECORDS_DIR and the rest), the register view
the readers share, the scribe's writes (work and run entries), the reviews kept as files, and the briefing,
report, site and verify in register mode. The register is a fake agentic-register (helpers.fake_register);
new entries are parsed by the vendored register library, as the scribe does."""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import unittest
import subprocess
import sys

import helpers as h

# `site` is also a standard-library module, so load ours by path under another name (as test_site does).
_spec = importlib.util.spec_from_file_location("devhost_site_ledger", h.script("site"))
SITE = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(SITE)

BIN = h.PYTHON_DIR.parent / "bin"


class Settings(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.c = h.load("devhost_common")

    def test_unset_the_records_stay_in_the_repository(self):
        self.assertEqual(self.c.backlog_path(self.root), self.root / "TODO.md")
        self.assertEqual(self.c.ledger_dir(self.root), self.root / "docs" / "ledger")
        self.assertEqual(self.c.costs_dir(self.root), self.root / "docs" / "ledger")
        self.assertIsNone(self.c.ledger_register())

    def test_the_records_dir_moves_backlog_ledger_costs_and_reviews(self):
        share = self.base / "share"
        os.environ["DEVHOST_RECORDS_DIR"] = str(share)
        self.assertEqual(self.c.backlog_path(self.root), share / "TODO.md")
        self.assertEqual(self.c.ledger_dir(self.root), share / "ledger")
        self.assertEqual(self.c.costs_dir(self.root), share / "costs")
        self.assertEqual(self.c.reviews_dir(self.root), share / "reviews")
        self.assertFalse(self.c.in_repo(self.root, share / "TODO.md"))
        os.environ["DEVHOST_BACKLOG"] = "Backlog.md"   # an explicit setting still wins
        self.assertEqual(self.c.backlog_path(self.root), self.root / "Backlog.md")

    def test_lib_sh_follows_the_same_settings(self):
        script = (f'source "{BIN / "lib.sh"}"; hk_backlog /r; hk_ledger_dir /r; '
                  'DEVHOST_BACKLOG=B hk_backlog /r; DEVHOST_LEDGER_REGISTER=ledger hk_ledger_register')
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                             env={**os.environ, "DEVHOST_RECORDS_DIR": "/mnt/share"}).stdout.split()
        self.assertEqual(out, ["/mnt/share/TODO.md", "/mnt/share/ledger", "/r/B", "ledger"])


class View(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.ledger = h.load("ledger")
        self.ledger._CACHE.clear()

    def test_register_entries_render_in_the_devhost_shape_by_their_original_date(self):
        old = h.work("Imported thing", date="2026-10-30", friction=[{"tag": "tooling", "text": "a."},
                                                                      {"tag": "docs", "text": "b."}],
                     came_out=["one", "two"], measures="$0.10 (test)")
        new = h.work("New thing", at="2026-11-05T09:00:00Z", corrects=old["id"])
        h.fake_register(self.base, [old, new, {"id": "r" * 64, "at": "2026-11-05T09:00:01Z", "principal": "scribe",
                                               "kind": "run", "data": {"member": "host"}}])
        months = self.ledger.months(self.root)
        self.assertEqual([w for w, _ in months], ["register:ledger/2026-10", "register:ledger/2026-11"])
        october = months[0][1]
        self.assertTrue(october.startswith("# Ledger, 2026-10\n\n### 2026-10-30 Imported thing\n"))
        self.assertIn("- **Friction:** [tooling] a. [docs] b.", october)
        self.assertIn("- **Came out:**\n  - one\n  - two", october)
        self.assertIn("- **Measures:** $0.10 (test)", october)
        self.assertIn("- **Corrects:** 2026-10-30 Imported thing", months[1][1])
        self.assertNotIn("run", months[1][1].split("\n", 1)[1].lower().replace("**", ""))

    def test_reviews_sit_between_the_entries_by_time(self):
        h.fake_register(self.base, [h.work("Before", at="2026-11-05T08:00:00Z"), h.work("After", at="2026-11-05T11:00:00Z"),
                                    h.work("Old one", date="2026-11-04")])
        os.environ["DEVHOST_REVIEWS_DIR"] = str(self.base / "reviews")
        kept = self.ledger.add_review(self.root, "## Review 2026-11-05\n\nReviewed.\n", "2026-11-05T10:00:00Z")
        again = self.ledger.add_review(self.root, "## Review 2026-11-05\n\nSecond.\n", "2026-11-05T12:00:00Z")
        self.assertEqual((kept.name, again.name), ("2026-11-05.md", "2026-11-05-2.md"))
        self.assertIn("At: 2026-11-05T10:00:00Z", kept.read_text(encoding="utf-8"))
        text = self.ledger.months(self.root)[0][1]
        order = [line for line in text.splitlines() if line.startswith(("### ", "## "))]
        self.assertEqual(order, ["### 2026-11-04 Old one", "### 2026-11-05 Before", "## Review 2026-11-05",
                                 "### 2026-11-05 After", "## Review 2026-11-05"])
        with self.assertRaises(self.ledger.RegisterError):
            self.ledger.add_review(self.root, "no heading", "2026-11-05T12:00:00Z")

    def test_carried_reviews_are_copied_once_and_keep_their_place_among_the_imported_entries(self):
        src = "docs/ledger/2026-10.md"
        h.fake_register(self.base, [h.work("Before it", date="2026-10-02", line=5, source=src),
                                    h.work("Same day after it", date="2026-10-02", line=90, source=src),
                                    h.work("Next day", date="2026-10-03", line=95, source=src)])
        os.environ["DEVHOST_REVIEWS_DIR"] = str(self.base / "reviews")
        monthly = self.root / "docs" / "ledger" / "2026-10.md"
        h.write(monthly, monthly.read_text(encoding="utf-8") + "## Review 2026-10-02\n\nThe review.\n\n"
                + h.entry("2026-10-03", "Later"))
        first = self.ledger.carry_reviews(self.root, [monthly])
        second = self.ledger.carry_reviews(self.root, [monthly])
        self.assertEqual(len(first), 1)
        self.assertTrue(second[0].startswith("already kept"))
        self.ledger._CACHE.clear()
        order = [line for line in self.ledger.months(self.root)[0][1].splitlines() if line.startswith(("### ", "## "))]
        self.assertEqual(order, ["### 2026-10-02 Before it", "## Review 2026-10-02", "### 2026-10-02 Same day after it",
                                 "### 2026-10-03 Next day"])
        self.assertIn(f"Source: {src}:", (self.base / "reviews" / "2026-10-02.md").read_text(encoding="utf-8"))

    def test_an_unreadable_register_is_said_never_empty(self):
        fake = h.fake_register(self.base, [h.work("A")])
        (fake / "fail-query").write_text("", encoding="utf-8")
        with self.assertRaises(self.ledger.RegisterError):
            self.ledger.months(self.root)
        text = h.load("briefing").briefing(self.root, refresh=False)
        self.assertIn("Ledger (register ledger (agentic-register)) not readable", text)


class Writes(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.ledger = h.load("ledger")
        self.ledger._CACHE.clear()
        self.fake = h.fake_register(self.base, [h.work("Wrong thing", date="2026-11-01")])

    def calls(self) -> list[list[str]]:
        return [json.loads(line) for line in (self.fake / "calls.jsonl").read_text(encoding="utf-8").splitlines()]

    def entries(self) -> list[dict]:
        return json.loads((self.fake / "entries.json").read_text(encoding="utf-8"))

    def test_the_scribes_markdown_becomes_work_entries_signed_with_its_key(self):
        text = (h.entry("2026-11-05", "Fixed it", "[tooling] one. [docs] two.")
                + "- **Corrects:** 2026-11-01 Wrong thing\n\n" + h.entry("2026-11-05", "Second"))
        ids = self.ledger.add_markdown(text, "scribe", "/dev/shm/key")
        self.assertEqual(len(ids), 2)
        add = [c for c in self.calls() if c[0] == "add"]
        self.assertEqual(len(add), 2)
        self.assertIn("--key", add[0])
        self.assertEqual(add[0][add[0].index("--as") + 1], "scribe")
        self.assertEqual(add[0][add[0].index("--kind") + 1], "work")
        new = self.entries()[1]["data"]
        self.assertNotIn("backfill", new, "an entry written at the time is not a backfill")
        self.assertEqual(new["title"], "Fixed it")
        self.assertEqual(new["friction"], [{"tag": "tooling", "text": "one."}, {"tag": "docs", "text": "two."}])
        self.assertEqual(new["corrects"], self.entries()[0]["id"])
        self.assertEqual(new["engineer"], "tester")

    def test_a_refused_entry_is_an_error_with_the_reason(self):
        with self.assertRaises(self.ledger.RegisterError) as caught:
            self.ledger.add_markdown(h.entry("2026-11-05", "REFUSE me"), "scribe")
        self.assertIn("guarded", str(caught.exception))

    def test_back_runs_become_run_entries_once(self):
        runs = self.base / "runs.jsonl"
        cursor = self.base / "cursor"
        line = {"ts": "2026-11-05T10:00:00Z", "job": "secretary", "model": "haiku", "status": "changed", "cost_usd": 0.0123,
                "input_tokens": 10, "output_tokens": 5, "duration_s": 2.5, "undone": 0, "sid": "s", "engineer": "tester"}
        h.write(runs, json.dumps(line) + "\nnot json\n")
        self.assertEqual(len(self.ledger.back_runs(runs, cursor, "scribe")), 1)
        self.assertEqual(self.ledger.back_runs(runs, cursor, "scribe"), [])
        run = self.entries()[-1]
        self.assertEqual(run["kind"], "run")
        self.assertEqual(run["data"]["member"], "back secretary")
        self.assertEqual(run["data"]["outcome"], "changed")
        self.assertEqual(run["data"]["cost"]["usd_micro"], 12300)
        self.assertEqual(run["data"]["ms"], 2500)
        h.write(runs, runs.read_text(encoding="utf-8") + json.dumps({**line, "job": "tester"}) + "\n")
        self.assertEqual(len(self.ledger.back_runs(runs, cursor, "scribe")), 1)

    def test_the_mirror_is_skipped_when_its_folder_is_missing(self):
        os.environ["FAKE_MIRROR"] = str(self.base / "not-mounted" / "ledger")
        try:
            with self.assertRaises(self.ledger.RegisterError) as caught:
                self.ledger.mirror()
            self.assertIn("not there", str(caught.exception))
            self.assertFalse([c for c in self.calls() if c[0] == "mirror"])
            (self.base / "not-mounted" / "ledger").mkdir(parents=True)
            self.assertIn("mirror ok", self.ledger.mirror())
        finally:
            os.environ.pop("FAKE_MIRROR", None)

    def test_the_stretch_cost_as_run_entries(self):
        sc = h.load("session_cost")
        folder = self.base / "t"
        h.write_jsonl(folder / "main.jsonl", [h.user(), h.assistant("m1", "claude-opus-5", "2026-11-05T10:00:01Z", h.usage(1000, 100)),
                                              h.assistant("m2", "claude-haiku-5", "2026-11-05T10:00:02Z", h.usage(1000, 100))])
        h.write_jsonl(folder / "con.jsonl", [h.assistant("c1", "claude-opus-5", "2026-11-05T10:00:03Z", h.usage(1000, 100))])
        runs = sc.run_records([str(folder / "main.jsonl"), str(folder / "con.jsonl")], main=1, member="host")
        self.assertEqual([r["model"] for r in runs], ["claude-haiku-5", "claude-opus-5"])
        self.assertEqual(runs[1]["cost"]["usd_micro"], 7500)   # 1000 in at $5, 100 out at $25 per million
        self.assertTrue(all(r["member"] == "host" and r["outcome"] == "stretch" for r in runs))


class Readers(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        h.load("ledger")._CACHE.clear()
        self.share = self.base / "share"
        os.environ["DEVHOST_RECORDS_DIR"] = str(self.share)
        h.write(self.share / "TODO.md", "# To do\n\n## Now\n\n- [ ] **share-item A** (host). x. Added 2026-11-01.\n")
        h.fake_register(self.base, [h.work(f"Thing {d}", date=f"2026-10-{d:02d}") for d in range(1, 6)])
        h.write(self.share / "reviews" / "2026-10-03.md", "## Review 2026-10-03\n\nDone.\n")

    def test_the_briefing_reads_the_register_and_the_shared_backlog(self):
        text = h.load("briefing").briefing(self.root, refresh=False)
        self.assertIn("Ledger (register ledger (agentic-register)): 2 entries since the last review (2026-10-03)", text)
        self.assertIn(f"{self.share / 'TODO.md'}: 1 open items", text)

    def test_the_report_counts_the_register_and_writes_to_the_costs_folder(self):
        report = h.load("report")
        self.assertIn("5 entries on 5 days", report.entry_rate(self.root, "2026-10"))
        report.write_report(self.root, "2026-10")
        self.assertTrue((self.share / "costs" / "costs-2026-10-tester.md").is_file())
        self.assertFalse(list((self.root / "docs" / "ledger").glob("costs-*")))

    def test_the_site_reads_records_outside_git(self):
        h.load("report").write_report(self.root, "2026-10")
        data = SITE.collect(self.root)
        self.assertEqual(data["todo"]["sections"][0]["items"][0]["id"], "share-item")
        self.assertEqual(data["ledger"]["last_review"], "2026-10-03")
        self.assertEqual(data["ledger"]["entries_since_review"], 2)
        self.assertEqual(len(data["ledger"]["entries"]), 5)
        self.assertEqual(len(data["costs"]), 1)
        self.assertIn(str(self.share / "TODO.md"), [d["path"] for d in data["docs"]])

    def test_the_site_says_when_the_shared_backlog_is_missing(self):
        (self.share / "TODO.md").unlink()
        data = SITE.collect(self.root)
        self.assertTrue(any("Backlog not found" in n for n in data["meta"]["notes"]))

    def test_verify_checks_the_register_not_the_markdown(self):
        v = h.load("verify")
        h.write(self.root / "docs" / "ledger" / "2026-10.md", "rewritten\n")   # file mode would refuse this
        self.assertEqual(v.ledger_append_only(self.root, []), [])
        self.assertEqual(v.ledger_shape(self.root), [])
        (h.Path(os.environ["FAKE_AR"]) / "verify-rc").write_text("1", encoding="utf-8")
        found = v.ledger_append_only(self.root, [])
        self.assertEqual(len(found), 1)
        self.assertIn("register ledger", found[0])
        os.environ["DEVHOST_AGENTIC_REGISTER"] = str(self.base / "no-such-command")
        notes: list[str] = []
        self.assertEqual(v.ledger_append_only(self.root, notes), [])
        self.assertTrue(notes and notes[0].startswith("ledger register check NOT RUN"))

    def test_the_backlog_outside_git_has_no_union_merge_check(self):
        h.write(self.share / "TODO.md", "- [ ] **dup-item A** (host). x.\n- [x] **dup-item A** (host). x.\n")
        self.assertEqual(h.load("verify").backlog_ids(self.root), [])

    def test_the_ledger_command_shows_the_register(self):
        done = subprocess.run([sys.executable, str(h.script("ledger")), "show", "--month", "2026-10"], capture_output=True,
                              text=True, env=os.environ.copy())
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("### 2026-10-05 Thing 5", done.stdout)
        self.assertIn("## Review 2026-10-03", done.stdout)


class CostArchive(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.ledger = h.load("ledger")
        self.ledger._CACHE.clear()
        self.fake = h.fake_register(self.base, [])
        led = self.root / "docs" / "ledger"
        h.write(led / "costs-2026-10-a.jsonl", '{"run": {"ts": "2026-10-20T01:00:00Z"}}\n{"reply": {"ts": "2026-10-31T02:00:00Z"}}\n')
        h.write(led / "costs-2026-11-a.jsonl", '{"run": {"ts": "2026-11-03T01:00:00Z"}}\n')
        h.write(led / "costs-2026-10-a.md", "# Agent costs, 2026-10, a\n\nTotal: $1.00.\n")
        self.files = sorted(led.glob("costs-*"))
        self.out = self.base / "share" / "costs" / "archive" / "costs-history.jsonl"

    def entries(self) -> list[dict]:
        return json.loads((self.fake / "entries.json").read_text(encoding="utf-8"))

    def test_one_archive_and_one_entry_with_hashes_once(self):
        dry = self.ledger.archive_costs(self.files, self.out, "host", dry_run=True)
        self.assertTrue(dry.startswith("would archive: 3 cost records and 3 files, 2026-10-20 to 2026-11-03"))
        self.assertFalse(self.out.exists())
        done = self.ledger.archive_costs(self.files, self.out, "host", "/tmp/host.pub")
        self.assertIn("recorded in entry", done)
        [e] = self.entries()
        self.assertEqual((e["principal"], e["kind"]), ("host", "work"))
        a = e["data"]["archive"]
        self.assertEqual((a["records"], a["from"], a["to"], a["path"]), (3, "2026-10-20", "2026-11-03", str(self.out)))
        self.assertEqual(a["sha256"], self.ledger._sha256(self.out.read_bytes()))
        self.assertEqual([s["source"] for s in a["sources"]],
                         ["docs/ledger/costs-2026-10-a.jsonl", "docs/ledger/costs-2026-10-a.md", "docs/ledger/costs-2026-11-a.jsonl"])
        back = self.ledger.restore_cost_archive(self.out.read_bytes())
        for f in self.files:
            self.assertEqual(back[f"docs/ledger/{f.name}"], f.read_bytes())
        again = self.ledger.archive_costs(self.files, self.out, "host")
        self.assertTrue(again.startswith("already recorded"))
        self.assertEqual(len(self.entries()), 1)

    def test_an_archive_with_other_contents_is_never_replaced(self):
        h.write(self.out, "something else\n")
        with self.assertRaises(self.ledger.RegisterError):
            self.ledger.archive_costs(self.files, self.out, "host")
        self.assertEqual(self.out.read_text(encoding="utf-8"), "something else\n")
        self.assertEqual(self.entries(), [])


class DeletionsUnderRegisterMode(h.RepoCase):
    """The second pull request of records-out-of-git: the monthly files, the cost reports and TODO.md deleted from
    the tree. devhost 1.12's verify in register mode, with the records folder set, must accept it; file mode must not."""

    def setUp(self) -> None:
        super().setUp()
        h.load("ledger")._CACHE.clear()
        h.write(self.root / "TODO.md", "# To do\n\n## Now\n\n- [ ] **an-item A** (host). x.\n")
        h.write(self.root / "docs" / "ledger" / "costs-2026-10-tester.md", "# Agent costs, 2026-10, tester\n")
        h.write(self.root / "docs" / "ledger" / "costs-2026-10-tester.jsonl", "{}\n")
        h.write(self.root / "docs" / "ledger" / "README.md", "# The ledger\n")
        h.git(self.root, "add", "-A")
        h.git(self.root, "commit", "-q", "-m", "records")
        h.git(self.root, "branch", "-f", "main", "HEAD")   # the base has the records
        for f in ("TODO.md", "docs/ledger/2026-10.md", "docs/ledger/costs-2026-10-tester.md", "docs/ledger/costs-2026-10-tester.jsonl"):
            h.git(self.root, "rm", "-q", f)
        h.write(self.root / "docs" / "ledger" / "README.md", "# The ledger\n\nNow in the register.\n")
        h.git(self.root, "add", "-A")
        os.environ["DEVHOST_BASE_REF"] = "main"

    def findings(self) -> dict[str, list[str]]:
        results, notes = h.load("verify").run(self.root)
        return {k: v for k, v in results.items() if v and k in ("ledger_append_only", "ledger_shape", "backlog_ids")}

    def test_file_mode_refuses_the_deletion(self):
        self.assertIn("ledger_append_only", self.findings())

    def test_register_mode_with_the_records_folder_accepts_it(self):
        h.fake_register(self.base, [h.work("A")])
        os.environ["DEVHOST_RECORDS_DIR"] = str(self.base / "share")
        h.write(self.base / "share" / "TODO.md", "# To do\n\n## Now\n\n- [ ] **an-item A** (host). x.\n")
        self.assertEqual(self.findings(), {})
        results, notes = h.load("verify").run(self.root)
        self.assertFalse([n for n in notes if "NOT RUN" in n])


FAKE_CLAUDE = r"""#!/usr/bin/env bash
# fake claude: the scribe's reply, as claude -p --output-format json prints it.
cat >/dev/null
python3 -c 'import json,os; print(json.dumps({"result": open(os.environ["FAKE_REPLY"]).read(), "total_cost_usd": 0.001}))'
"""


@unittest.skipUnless(shutil.which("bash"), "needs bash")
class ScribeRegister(h.RepoCase):
    """The real scribe job through the real runner, with a fake claude, a fake OpenBao (its key) and a fake register."""

    def setUp(self) -> None:
        super().setUp()
        import test_key_fetch as kf
        self.fake = self.base / "fake"
        self.fake.mkdir()
        for name, text in (("bao", kf.FAKE_BAO), ("dcf-secret", kf.FAKE_DCF), ("claude", FAKE_CLAUDE)):
            kf._exe(self.fake / name, text)
        od = self.base / "openbao-state"
        h.write(od / "approle" / "scribe" / "role_id", "role-id-1")
        h.write(od / "approle" / "scribe" / "secret_id", kf.SECRET_ID)
        (self.base / "tmpfs").mkdir()
        self.ar = h.fake_register(self.base, [])
        self.reply = self.base / "reply.txt"
        h.write(self.reply, "STATUS: logged\nSUMMARY: one entry\nPENDING: none\n---\n" + h.entry("2026-11-05", "Scribed thing"))
        self.env = dict(os.environ, PATH=f"{self.fake}:{os.environ['PATH']}", FAKE_DIR=str(self.fake), FAKE_KEY=kf.KEY,
                        FAKE_REPLY=str(self.reply), DEVHOST_BAO=str(self.fake / "bao"), OPENBAO_STATE_DIR=str(od),
                        OPENBAO_FEATURE_DIR=str(self.base / "no-feature"), DEVHOST_KEY_TMPFS=str(self.base / "tmpfs"),
                        DEVHOST_SHARE=str(h.PYTHON_DIR.parent), DEVHOST_CONTAINER_MARKERS=str(self.base),
                        DEVHOST_JOB_QUIET_SECS="0", FAKE_MIRROR=str(self.base / "not-mounted"))
        self.env.pop("DEVHOST_JOB_CHILD", None)

    def run_scribe(self, **extra: str) -> subprocess.CompletedProcess:
        transcript = self.base / "t.jsonl"
        h.write_jsonl(transcript, [{"type": "user", "uuid": "u-0", "parentUuid": None, "timestamp": "2026-11-05T10:00:00.000Z",
                                    "message": {"role": "user", "content": "please do the thing " * 200}}])
        hook = json.dumps({"session_id": "s1", "transcript_path": str(transcript), "cwd": str(self.root), "hook_event_name": "Stop"})
        return subprocess.run(["bash", str(BIN / "run-job.sh"), str(h.PYTHON_DIR.parent / "jobs" / "scribe" / "job.sh")],
                              input=hook, env=dict(self.env, **extra), capture_output=True, text=True)

    def test_the_scribe_signs_its_entry_into_the_register_and_writes_no_markdown(self):
        before = (self.root / "docs" / "ledger" / "2026-10.md").read_text(encoding="utf-8")
        done = self.run_scribe()
        self.assertEqual(done.returncode, 0, done.stderr)
        entries = json.loads((self.ar / "entries.json").read_text(encoding="utf-8"))
        self.assertEqual([e["data"]["title"] for e in entries if e["kind"] == "work"], ["Scribed thing"])
        self.assertEqual({e["principal"] for e in entries}, {"scribe"})
        adds = [json.loads(line) for line in (self.ar / "calls.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertTrue(all("--key" in c for c in adds if c[0] == "add"), "every write is signed with the fetched key")
        self.assertIn("logged in the register ledger (1 entries)", done.stdout)
        self.assertFalse((self.root / "docs" / "ledger" / "2026-11.md").exists())
        self.assertEqual((self.root / "docs" / "ledger" / "2026-10.md").read_text(encoding="utf-8"), before)
        log = (self.base / "state" / "scribe" / "job.log").read_text(encoding="utf-8")
        self.assertIn("mirror not level", log, "a missing mirror folder is logged, not fatal")
        self.assertEqual(list((self.base / "tmpfs").iterdir()), [])

    def test_without_its_key_the_scribe_does_not_run(self):
        done = self.run_scribe(FAKE_SEALED="1")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(json.loads((self.ar / "entries.json").read_text(encoding="utf-8")), [])

    def test_a_refused_entry_leaves_the_stretch_to_be_read_again(self):
        h.write(self.reply, "STATUS: logged\nSUMMARY: x\nPENDING: none\n---\n" + h.entry("2026-11-05", "REFUSE this"))
        done = self.run_scribe()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("could not write to the register", done.stdout)
        self.assertFalse((self.base / "state" / "scribe" / "offsets" / "s1").exists())


if __name__ == "__main__":
    import unittest
    unittest.main()
