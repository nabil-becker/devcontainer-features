"""site.py: the data collected from a temporary repository, the name guard over everything embedded,
a document that cannot break out of the data script, fragment versus standalone."""
from __future__ import annotations

import importlib.util
import json
import re
import unittest

import helpers as h

# `site` is also a standard-library module, so load ours by path under another name.
_spec = importlib.util.spec_from_file_location("devhost_site", h.script("site"))
site = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(site)

NAME = "Lancelot Fakename"  # a placeholder seeded in the redact file; no output may carry it

TODO = """# To do

## Now

- [ ] **alpha-item Alpha thing** (host). Do alpha. Added 2026-10-01.
- [x] **beta-item Beta thing** (the Operator). Done beta. Added 2026-10-01. Done 2026-10-02: shipped.
- [ ] **gamma-item Gamma thing** (the Operator). Needs a login. Added 2026-10-03.
- [ ] **delta-item Delta thing** (host, the Operator reviews). Not an operator item. Added 2026-10-03.

## Decisions for the Operator

- [ ] **pick-one Pick one** (the Operator). A or B? Added 2026-10-04.
- [x] **picked Picked** (the Operator). Done. Added 2026-10-04. Done 2026-10-05.
"""


def doc_data(html: str) -> dict:
    m = re.search(r'<script type="application/json" id="site-data">(.*?)</script>', html, re.S)
    assert m, "no data script"
    return json.loads(m.group(1))


class Site(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        r = self.root
        h.write(r / "TODO.md", TODO)
        h.write(r / "README.md", "# The court\n\nHello.\n")
        h.write(r / "src" / "feat" / "devcontainer-feature.json", json.dumps({"id": "feat", "version": "1.2.3", "name": "Feat", "description": "Does a thing."}))
        h.write(r / "src" / "feat" / "README.md", "# feat\n")
        h.write(r / "docs" / "adr" / "0001-first.md", "# ADR-0001: First choice\n\n| | |\n|---|---|\n| **Status** | accepted |\n| **Date** | 2026-10-02 |\n")
        h.write(r / "docs" / "adr" / "0000-template.md", "# ADR-0000: Template\n")
        h.write(r / "docs" / "proposals" / "idea.md", "# Proposal: an idea\n\nStatus: draft 2026-10-05, open.\n")
        h.write(r / "docs" / "proposals" / "old.md", "# Proposal: old\n\nStatus: accepted 2026-10-01.\n")
        h.write(r / "docs" / "night-shift" / "2026-10-06.md", "# Night shift\n\nPlan.\n")
        h.write(r / "docs" / "night-shift" / "2026-10-05.md", "# Night shift\n\nReviewed by the Operator 2026-10-06.\n")
        h.write(r / "docs" / "journal" / "2026-10-06.md", "# Journal\n")
        h.write(r / "docs" / "ledger" / f"costs-{h.LEDGER_MONTH}-tester.md", "# Costs\n\nTotal: $1.23. Inter sessions: $1.\n")
        h.track(r)

    def collect(self, **kw) -> dict:
        return site.collect(self.root, **kw)

    def test_the_schema_keys(self):
        d = self.collect()
        self.assertEqual(d["schema"], 1)
        self.assertEqual(set(d), {"schema", "meta", "attention", "todo", "ledger", "costs", "features", "records", "prs", "docs"})
        self.assertEqual(set(d["meta"]), {"repo", "generated", "branch", "commit", "dirty", "remote_url", "notes"})
        self.assertEqual(set(d["records"]), {"adrs", "proposals", "night_shift", "journal"})
        self.assertEqual(d["meta"]["branch"], "work")
        self.assertIsNone(d["prs"])
        self.assertEqual(d["features"][0]["id"], "feat")
        self.assertEqual(d["features"][0]["docs"], ["src/feat/README.md"])
        self.assertEqual(d["costs"], [{"path": f"docs/ledger/costs-{h.LEDGER_MONTH}-tester.md", "engineer": "tester",
                                       "month": h.LEDGER_MONTH, "headline": "Total: $1.23. Inter sessions: $1."}])
        docs = {x["path"]: x for x in d["docs"]}
        self.assertEqual(docs["README.md"]["title"], "The court")
        self.assertEqual(docs["README.md"]["group"], "Product")
        self.assertEqual(docs["TODO.md"]["group"], "Way of working")
        self.assertEqual(docs["docs/adr/0001-first.md"]["group"], "Records")
        self.assertEqual(docs["docs/proposals/idea.md"]["group"], "Proposals")

    def test_the_records(self):
        r = self.collect()["records"]
        self.assertEqual(r["adrs"], [{"number": "0001", "title": "First choice", "status": "accepted", "date": "2026-10-02", "path": "docs/adr/0001-first.md"}])
        self.assertEqual({p["path"]: p["status"] for p in r["proposals"]},
                         {"docs/proposals/idea.md": "draft 2026-10-05, open.", "docs/proposals/old.md": "accepted 2026-10-01."})
        self.assertEqual([(n["date"], n["reviewed"]) for n in r["night_shift"]], [("2026-10-05", True), ("2026-10-06", False)])
        self.assertEqual(r["journal"], [{"date": "2026-10-06", "path": "docs/journal/2026-10-06.md"}])

    def test_the_backlog_parsing(self):
        todo = self.collect()["todo"]
        self.assertEqual([s["name"] for s in todo["sections"]], ["Now", "Decisions for the Operator"])
        now = {i["id"]: i for i in todo["sections"][0]["items"]}
        self.assertEqual(list(now), ["alpha-item", "beta-item", "gamma-item", "delta-item"])
        self.assertEqual((now["alpha-item"]["title"], now["alpha-item"]["owner"], now["alpha-item"]["done"], now["alpha-item"]["added"]),
                         ("Alpha thing", "host", False, "2026-10-01"))
        self.assertTrue(now["beta-item"]["done"])
        self.assertEqual(now["beta-item"]["done_on"], "2026-10-02")
        self.assertEqual(now["beta-item"]["owner"], "the Operator")
        self.assertIsNone(now["alpha-item"]["done_on"])
        self.assertIn("Needs a login.", now["gamma-item"]["text"])

    def test_attention_order_and_content(self):
        ledger = self.root / "docs" / "ledger" / f"{h.LEDGER_MONTH}.md"
        h.write(ledger, ledger.read_text(encoding="utf-8") + "\n".join(h.entry(f"2026-10-{d:02d}", f"Extra {d}") for d in range(3, 6)))
        h.track(self.root)
        att = self.collect()["attention"]
        self.assertEqual([a["kind"] for a in att], ["decision", "operator-item", "night-report", "review-due", "proposal"])
        self.assertEqual(att[0]["title"], "Pick one")
        self.assertEqual(att[1]["title"], "Gamma thing")  # not the done one, not "host, the Operator reviews"
        self.assertEqual(att[2]["target"], "d~docs~night-shift~2026-10-06.md")
        self.assertIn("5 entries", att[3]["detail"])
        self.assertEqual(att[4]["target"], "d~docs~proposals~idea.md")

    def test_ledger_parsing_and_corrections(self):
        ledger = self.root / "docs" / "ledger" / f"{h.LEDGER_MONTH}.md"
        fixed = h.entry("2026-10-03", "Fixed entry").replace("- **Decisions needed:** none", "- **Corrects:** 2026-10-02 Second thing\n- **Decisions needed:** none")
        h.write(ledger, ledger.read_text(encoding="utf-8") + "## Review 2026-10-02\n\nreviewed.\n\n" + fixed)
        h.track(self.root)
        lg = self.collect()["ledger"]
        self.assertEqual(lg["last_review"], "2026-10-02")
        self.assertEqual(lg["entries_since_review"], 1)
        self.assertEqual([e["title"] for e in lg["entries"]], ["Fixed entry", "Second thing", "First thing"])  # newest first
        fixed_e, second, first = lg["entries"]
        self.assertEqual(second["corrected_by"], "Fixed entry")
        self.assertIsNone(first["corrected_by"])
        self.assertEqual(second["fields"]["Friction"], "[tooling] a missing task")
        self.assertEqual(second["cost"], 0.01)
        self.assertEqual(second["path"], f"docs/ledger/{h.LEDGER_MONTH}.md")
        self.assertEqual(len({e["anchor"] for e in lg["entries"]}), 3)
        self.assertEqual(fixed_e["fields"]["Corrects"], "2026-10-02 Second thing")

    def test_the_name_guard_is_applied_to_everything_embedded(self):
        h.write(self.root / ".devhost" / "redact-names.txt", NAME + "\n")
        h.write(self.root / "NOTES.md", f"# Notes by {NAME}\n\n{NAME}'s idea; ask {NAME.upper()}.\n")
        h.write(self.root / "TODO.md", TODO + f"- [ ] **named Ask {NAME}** (the Operator). {NAME} wants it.\n")
        h.track(self.root)
        done = h.run(["site", "--out", str(self.base / "out")], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        page = (self.base / "out" / "index.html").read_text(encoding="utf-8")
        self.assertNotIn(NAME.lower(), page.lower())
        data = doc_data(page)
        notes = {d["path"]: d for d in data["docs"]}["NOTES.md"]
        self.assertEqual(notes["title"], "Notes by the Operator")
        self.assertIn("the Operator's idea", notes["text"])
        self.assertIn("Ask the Operator", [a["title"] for a in data["attention"]])

    def test_the_name_guard_check_can_fail(self):
        """AP-4: with the guard off, the same assertion must catch the name."""
        h.write(self.root / ".devhost" / "redact-names.txt", NAME + "\n")
        h.write(self.root / "NOTES.md", f"# Notes by {NAME}\n")
        h.track(self.root)
        raw = site.collect(self.root)  # not passed through site.redacted
        self.assertIn(NAME.lower(), site.render(raw).lower())
        self.assertNotIn(NAME.lower(), site.render(site.redacted(raw, self.root)).lower())

    def test_forbidden_words_are_removed_too(self):
        h.write(self.root / "NOTES.md", "# Notes\n\nthe SecretWord appears\n")
        h.track(self.root)
        env = dict(self.env, DEVHOST_FORBIDDEN_WORDS="secretword")
        done = h.run(["site", "--out", str(self.base / "out")], self.root, env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("secretword", (self.base / "out" / "index.html").read_text(encoding="utf-8").lower())

    def test_a_document_cannot_break_out_of_the_data_script(self):
        evil = "# Evil\n\n</script><script>window.pwned=1</script> <!-- <!--SITE-DATA--> -->\n"
        h.write(self.root / "docs" / "evil.md", evil)
        h.track(self.root)
        done = h.run(["site", "--out", str(self.base / "out")], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        page = (self.base / "out" / "index.html").read_text(encoding="utf-8")
        self.assertEqual(page.count('id="site-data"'), 1)
        start = page.index('id="site-data">') + len('id="site-data">')
        blob = page[start:page.index("</script>", start)]
        self.assertNotIn("<", blob)
        self.assertEqual(page.count("</script>"), 4)  # two libraries, the data and the app: none from the document
        self.assertEqual({d["path"]: d for d in doc_data(page)["docs"]}["docs/evil.md"]["text"], evil)  # round-trips intact

    def test_fragment_and_standalone(self):
        out = self.base / "out"
        done = h.run(["site", "--out", str(out)], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("index.html", done.stdout)
        frag = (out / "index.html").read_text(encoding="utf-8")
        self.assertTrue(frag.startswith("<title>Court Dashboard</title>\n<style>"))
        for tag in ("<!doctype", "<html", "<head", "<body"):
            self.assertNotIn(tag, frag.lower())
        self.assertNotIn(site.PLACEHOLDER, frag)
        done = h.run(["site", "--out", str(out), "--standalone"], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        full = (out / "index.html").read_text(encoding="utf-8")
        self.assertTrue(full.startswith('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport"'))
        self.assertIn("</style></head><body>", full)
        self.assertTrue(full.rstrip().endswith("</body></html>"))
        self.assertEqual(doc_data(full)["schema"], 1)

    def test_the_default_output_is_under_dot_devhost_and_is_deterministic(self):
        first = h.run(["site"], self.root, self.env)
        self.assertEqual(first.returncode, 0, first.stderr)
        path = self.root / ".devhost" / "site" / "index.html"
        a = path.read_text(encoding="utf-8")
        h.run(["site"], self.root, self.env)
        b = path.read_text(encoding="utf-8")
        strip = lambda t: re.sub(r'"generated":"[^"]*"', "", t)
        self.assertEqual(strip(a), strip(b))

    def test_prs_fail_quietly(self):
        env = dict(self.env, PATH=str(self.base))  # no gh on the path
        done = h.run(["site", "--prs", "--out", str(self.base / "out")], self.root, env)
        self.assertEqual(done.returncode, 0, done.stderr)
        data = doc_data((self.base / "out" / "index.html").read_text(encoding="utf-8"))
        self.assertIsNone(data["prs"])
        self.assertTrue(any("pull requests" in n for n in data["meta"]["notes"]))

    def test_the_remote_url_is_https_and_without_credentials(self):
        h.git(self.root, "remote", "add", "origin", "https://user:tok@github.com/acme/thing.git")
        self.assertEqual(self.collect()["meta"]["remote_url"], "https://github.com/acme/thing")
        h.git(self.root, "remote", "set-url", "origin", "git@github.com:acme/thing.git")
        self.assertEqual(self.collect()["meta"]["remote_url"], "https://github.com/acme/thing")


class Summary(unittest.TestCase):
    def test_summary_is_the_first_whole_sentence(self):
        self.assertEqual(site.summary_of("Installs it. Then more."), "Installs it.")
        self.assertEqual(site.summary_of("Augments the CLI (no Node.js), e.g. `x`. Then more."), "Augments the CLI (no Node.js), e.g. `x`.")
        self.assertEqual(site.summary_of("Keeps state, i.e. a volume. More."), "Keeps state, i.e. a volume.")
        self.assertEqual(site.summary_of("No full stop"), "No full stop")

    def test_every_feature_here_gets_a_whole_sentence(self):
        import pathlib
        root = pathlib.Path(h.script("site")).resolve().parents[4]
        features = sorted(root.glob("src/*/devcontainer-feature.json"))
        self.assertGreater(len(features), 10)
        for p in features:
            s = site.summary_of(json.loads(p.read_text()).get("description", ""))
            with self.subTest(feature=p.parent.name):
                self.assertTrue(s.endswith("."), s[-40:])
                self.assertFalse(re.search(r"\b(e\.g|i\.e|etc)\.$", s), s[-40:])

