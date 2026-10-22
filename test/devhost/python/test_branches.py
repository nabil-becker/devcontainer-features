"""branches.py: the naming rule, the next free number, the listing, the prune (merged and empty goes,
anything that adds stays), the leftovers the briefing and the shutdown check count, and the pre-push check.
A temporary repository with a bare "origin" and a fake `gh` that answers from a JSON file."""
from __future__ import annotations

import json
import os
import stat
import sys

import helpers as h

BACKLOG = """# Backlog

## Now

- [ ] **alpha Alpha thing** (host). Open.
- [x] **beta-two Beta thing** (host). Done.
"""

FAKE_GH = """#!{python}
import json, os, sys
data = json.load(open(os.environ["FAKE_GH_DATA"]))
args = sys.argv[1:]
if "--head" in args:
    name = args[args.index("--head") + 1]
    print(json.dumps([{{"number": 1, "state": s}} for s in data.get(name, [])]))
else:
    # a state is "MERGED" or {{"state": "MERGED", "head": "<commit>"}} (headRefOid)
    print(json.dumps([{{"headRefName": n, "state": s["state"], "headRefOid": s["head"]}} if isinstance(s, dict)
                      else {{"headRefName": n, "state": s}} for n, states in data.items() for s in states]))
"""


class Branches(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.br = h.load("branches")
        h.git(self.root, "switch", "-q", "main")
        h.write(self.root / "TODO.md", BACKLOG)
        h.git(self.root, "add", "-A")
        h.git(self.root, "commit", "-q", "-m", "backlog")
        h.git(self.root, "branch", "-q", "-D", "work")
        self.remote = self.base / "origin.git"
        h.git(self.base, "init", "-q", "--bare", "-b", "main", str(self.remote))
        h.git(self.root, "remote", "add", "origin", str(self.remote))
        h.git(self.root, "push", "-q", "-u", "origin", "main")
        self.gh_data = self.base / "gh.json"
        self.set_gh({})
        fake = self.base / "fake-gh"
        fake.write_text(FAKE_GH.format(python=sys.executable), encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        os.environ["DEVHOST_GH"] = str(fake)
        os.environ["FAKE_GH_DATA"] = str(self.gh_data)
        self.env = dict(os.environ)

    def tearDown(self) -> None:
        os.environ.pop("FAKE_GH_DATA", None)
        super().tearDown()

    def set_gh(self, data: dict) -> None:
        self.gh_data.write_text(json.dumps(data), encoding="utf-8")

    def commit(self, branch: str, name: str, push: bool = True, base: str = "main") -> None:
        if h.git(self.root, "branch", "--list", branch).strip():
            h.git(self.root, "switch", "-q", branch)
        else:
            h.git(self.root, "switch", "-q", "-c", branch, base)
        h.write(self.root / name, "x\n")
        h.git(self.root, "add", "-A")
        h.git(self.root, "commit", "-q", "-m", f"add {name}")
        if push:
            h.git(self.root, "push", "-q", "-u", "origin", branch)
        h.git(self.root, "switch", "-q", "main")

    def squash_merge(self, branch: str) -> None:
        """What GitHub's squash merge does: the same changes as one new commit on main."""
        h.git(self.root, "merge", "-q", "--squash", branch)
        h.git(self.root, "commit", "-q", "-m", f"squash {branch}")
        h.git(self.root, "push", "-q", "origin", "main")

    def names(self) -> set[str]:
        return {b.name for b in self.br.gather(self.root)}

    # the rule

    def test_names_follow_the_rule_or_not(self):
        for ok in ("feature/alpha/1", "fix/beta-two/12", "docs/x/3", "chore/records/1"):
            self.assertIsNotNone(self.br.parse(ok), ok)
        for bad in ("work", "feature/alpha", "feature/alpha/x", "feat/alpha/1", "feature/Alpha/1", "feature/alpha/1/2", "devhost/ontology-guard"):
            self.assertIsNone(self.br.parse(bad), bad)

    def test_items_are_the_ids_ticked_or_not(self):
        self.assertEqual(self.br.items(self.root), {"alpha": "Alpha thing", "beta-two": "Beta thing"})

    def test_next_free_n_counts_every_type_and_remote_names(self):
        self.assertEqual(self.br.next_n([], "alpha"), 1)
        self.assertEqual(self.br.next_n(["feature/alpha/1", "fix/alpha/3", "feature/other/9", "work"], "alpha"), 4)

    # new

    def test_new_branches_from_origin_main_with_the_next_n(self):
        code, message = self.br.new_branch(self.root, "alpha")
        self.assertEqual(code, 0, message)
        self.assertEqual(h.git(self.root, "branch", "--show-current").strip(), "feature/alpha/1")
        h.git(self.root, "switch", "-q", "main")
        self.commit("fix/alpha/2", "b.txt")  # remote-only after the local delete
        h.git(self.root, "branch", "-q", "-D", "fix/alpha/2")
        code, message = self.br.new_branch(self.root, "alpha", "docs")
        self.assertEqual((code, h.git(self.root, "branch", "--show-current").strip()), (0, "docs/alpha/3"))

    def test_new_refuses_an_unknown_id_and_a_bad_type(self):
        code, message = self.br.new_branch(self.root, "nope")
        self.assertEqual(code, 2)
        self.assertIn("not an item", message)
        self.assertEqual(self.br.new_branch(self.root, "alpha", "wip")[0], 2)
        self.assertEqual(h.git(self.root, "branch", "--show-current").strip(), "main")

    def test_new_does_not_track_main(self):
        self.br.new_branch(self.root, "alpha")
        done = h.run(["branches"], self.root, self.env)  # smoke: the listing runs
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(h.git(self.root, "for-each-ref", "--format=%(upstream)", "refs/heads/feature/alpha/1").strip(), "")

    # listing

    def test_listing_says_item_pr_and_what_it_adds(self):
        self.commit("feature/alpha/1", "a.txt")
        self.commit("work", "w.txt", push=False)
        self.commit("feature/ghost/1", "g.txt", push=False)
        self.set_gh({"feature/alpha/1": ["OPEN"]})
        done = h.run(["branches", "--no-fetch"], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        out = done.stdout
        alpha = next(line for line in out.splitlines() if line.startswith("feature/alpha/1"))
        self.assertIn("alpha: Alpha thing", alpha)
        self.assertIn("PR open", alpha)
        self.assertIn("1 file changed", alpha)
        self.assertIn("name breaks the rule", next(l for l in out.splitlines() if l.startswith("work")))
        self.assertIn("not an item", next(l for l in out.splitlines() if l.startswith("feature/ghost/1")))
        self.assertIn("Branches: 2 with work and no pull request", out)  # work, ghost
        self.assertIn("1 named against the rule", out)

    def test_a_squash_merged_branch_adds_nothing(self):
        self.commit("feature/alpha/1", "a.txt")
        self.squash_merge("feature/alpha/1")
        by = {b.name: b for b in self.br.gather(self.root)}
        self.assertEqual(by["feature/alpha/1"].adds, "nothing")
        self.assertGreater(by["feature/alpha/1"].ahead, 0)  # git branch --merged would not say so

    def test_without_gh_the_pr_is_unknown_and_nothing_is_counted_as_pr_dependent(self):
        os.environ["DEVHOST_GH"] = "devhost-test-no-gh"
        self.commit("feature/alpha/1", "a.txt")
        found = self.br.leftovers(self.root)
        self.assertEqual((found.unfinished, found.merged, found.pr_known), ([], [], False))
        self.assertIn("unknown", self.br.describe(self.br.gather(self.root)[1], {}))

    # prune

    def test_prune_deletes_merged_and_empty_everywhere_and_keeps_the_rest(self):
        self.commit("feature/alpha/1", "a.txt")      # merged and empty: goes
        self.squash_merge("feature/alpha/1")
        self.commit("fix/alpha/2", "b.txt")          # merged PR but adds more: stays
        self.commit("docs/alpha/3", "c.txt")         # open PR: stays
        self.commit("chore/alpha/4", "d.txt")        # no PR, adds: stays
        h.git(self.root, "switch", "-q", "-c", "fix/beta-two/1", "main")  # current, contained in main
        self.set_gh({"feature/alpha/1": ["MERGED"], "fix/alpha/2": ["MERGED"], "docs/alpha/3": ["OPEN"]})
        out = "\n".join(self.br.prune(self.root))
        self.assertIn("deleted feature/alpha/1 (local, remote): pull request merged, adds nothing", out)
        for kept in ("fix/alpha/2: it still adds", "docs/alpha/3: it still adds", "chore/alpha/4: it still adds",
                     "fix/beta-two/1: it is the current branch"):
            self.assertIn("kept " + kept, out)
        left = self.names()
        self.assertNotIn("feature/alpha/1", left)
        self.assertTrue({"main", "fix/alpha/2", "docs/alpha/3", "chore/alpha/4", "fix/beta-two/1"} <= left)
        self.assertEqual(h.git(self.root, "ls-remote", "--heads", "origin", "feature/alpha/1").strip(), "")

    def edit_on_main(self, name: str, text: str) -> None:
        """Main moves on over a line a squash merge brought in."""
        h.write(self.root / name, text)
        h.git(self.root, "commit", "-q", "-am", f"main edits {name}")
        h.git(self.root, "push", "-q", "origin", "main")

    def tip(self, branch: str) -> str:
        return h.git(self.root, "rev-parse", branch).strip()

    def test_prune_deletes_a_branch_at_its_merged_pr_head_after_main_moved_on(self):
        self.commit("feature/alpha/1", "a.txt")
        self.squash_merge("feature/alpha/1")
        self.edit_on_main("a.txt", "y\n")          # the branch now "still adds" the old line
        self.set_gh({"feature/alpha/1": [{"state": "MERGED", "head": self.tip("feature/alpha/1")}]})
        by = {b.name: b for b in self.br.gather(self.root)}
        self.assertNotEqual(by["feature/alpha/1"].adds, "nothing")
        self.assertTrue(by["feature/alpha/1"].at_merged_head)
        out = "\n".join(self.br.prune(self.root))
        self.assertIn("deleted feature/alpha/1 (local, remote): pull request merged, at its merged pull request's head", out)
        self.assertNotIn("feature/alpha/1", self.names())

    def test_prune_keeps_a_branch_with_a_commit_after_its_merged_pr(self):
        self.commit("feature/alpha/1", "a.txt")
        head = self.tip("feature/alpha/1")
        self.squash_merge("feature/alpha/1")
        self.edit_on_main("a.txt", "y\n")
        self.commit("feature/alpha/1", "later.txt")   # work after the merge
        self.set_gh({"feature/alpha/1": [{"state": "MERGED", "head": head}]})
        out = "\n".join(self.br.prune(self.root))
        self.assertIn("kept feature/alpha/1: it still adds", out)
        self.assertIn("feature/alpha/1", self.names())

    def test_prune_keeps_a_local_branch_behind_or_beside_its_pushed_merged_head(self):
        self.commit("feature/alpha/1", "a.txt")
        self.squash_merge("feature/alpha/1")
        self.edit_on_main("a.txt", "y\n")
        self.commit("feature/alpha/1", "local.txt", push=False)  # local differs from the merged remote head
        self.set_gh({"feature/alpha/1": [{"state": "MERGED", "head": self.tip("origin/feature/alpha/1")}]})
        out = "\n".join(self.br.prune(self.root))
        self.assertIn("kept feature/alpha/1: it still adds", out)

    def test_prune_removes_the_worktree_of_a_deleted_branch(self):
        self.commit("feature/alpha/1", "a.txt")
        self.squash_merge("feature/alpha/1")
        tree = self.base / "wt"
        h.git(self.root, "worktree", "add", "-q", str(tree), "feature/alpha/1")
        self.set_gh({"feature/alpha/1": ["MERGED"]})
        out = "\n".join(self.br.prune(self.root))
        self.assertIn("worktree", out)
        self.assertFalse(tree.exists())
        self.assertNotIn("feature/alpha/1", self.names())

    def test_prune_without_gh_only_takes_what_main_contains(self):
        os.environ["DEVHOST_GH"] = "devhost-test-no-gh"
        self.commit("feature/alpha/1", "a.txt")
        self.squash_merge("feature/alpha/1")        # adds nothing but its PR state is unknown
        h.git(self.root, "branch", "-q", "fix/alpha/2", "main")  # contained in main
        out = "\n".join(self.br.prune(self.root))
        self.assertIn("kept feature/alpha/1: its pull request state is unknown", out)
        self.assertIn("deleted fix/alpha/2", out)

    # leftovers, for the briefing and the shutdown check

    def test_leftovers_count_the_three_kinds(self):
        self.commit("feature/alpha/1", "a.txt")      # work, no PR
        self.commit("fix/alpha/2", "b.txt")
        self.squash_merge("fix/alpha/2")             # merged, still there
        self.commit("oldname", "c.txt", push=False)  # breaks the rule (and has work and no PR)
        self.set_gh({"fix/alpha/2": ["MERGED"]})
        found = self.br.leftovers(self.root)
        self.assertEqual(found.unfinished, ["feature/alpha/1", "oldname"])
        self.assertEqual(found.merged, ["fix/alpha/2"])
        self.assertEqual(found.badnames, ["oldname"])
        self.assertEqual(self.br.summary(found),
                         "Branches: 2 with work and no pull request, 1 merged and not deleted, 1 named against the rule (task devhost:branches).")

    def test_summary_is_empty_when_all_is_in_order(self):
        self.assertEqual(self.br.summary(self.br.leftovers(self.root)), "")

    def test_summary_says_gh_was_unavailable_only_when_something_else_is_reported(self):
        os.environ["DEVHOST_GH"] = "devhost-test-no-gh"
        self.commit("oldname", "c.txt", push=False)
        self.assertIn("pull requests not checked", self.br.summary(self.br.leftovers(self.root)))

    # the push check

    def check(self, line: str, state: str | None = "none") -> list[str]:
        return self.br.check_push(self.root, [line], gh_state=lambda root, name: state)

    def test_push_check_allows_a_good_branch_and_exempt_refs(self):
        sha = "a" * 40
        self.assertEqual(self.check(f"refs/heads/feature/alpha/1 {sha} refs/heads/feature/alpha/1 {'0' * 40}"), [])
        self.assertEqual(self.check(f"refs/heads/main {sha} refs/heads/main {sha}"), [])
        self.assertEqual(self.check(f"refs/tags/v1 {sha} refs/tags/v1 {'0' * 40}"), [])

    def test_push_check_refuses_a_name_that_breaks_the_rule(self):
        sha = "a" * 40
        problems = self.check(f"refs/heads/work {sha} refs/heads/work {'0' * 40}")
        self.assertEqual(len(problems), 1)
        self.assertIn("breaks the rule <type>/<backlog-id>/<n>", problems[0])

    def test_push_check_refuses_an_id_that_is_not_an_item(self):
        sha = "a" * 40
        problems = self.check(f"refs/heads/feature/ghost/1 {sha} refs/heads/feature/ghost/1 {'0' * 40}")
        self.assertIn("'ghost' is not an item", problems[0])

    def test_push_check_refuses_a_merged_branch_and_names_the_next_n(self):
        sha = "a" * 40
        self.commit("feature/alpha/1", "a.txt")
        problems = self.check(f"refs/heads/feature/alpha/1 {sha} refs/heads/feature/alpha/1 {sha}", "merged")
        self.assertIn("its pull request merged", problems[0])
        self.assertIn("feature/alpha/2", problems[0])

    def test_push_check_always_allows_a_delete_and_survives_no_gh(self):
        zero = "0" * 40
        self.assertEqual(self.check(f"(delete) {zero} refs/heads/work {'a' * 40}"), [])
        self.assertEqual(self.check(f"(delete) {zero} refs/heads/feature/alpha/1 {'a' * 40}", "merged"), [])
        self.assertEqual(self.check(f"refs/heads/feature/alpha/1 {'a' * 40} refs/heads/feature/alpha/1 {zero}", None), [])

    def test_the_hook_entry_refuses_with_exit_1_and_one_line(self):
        sha = "a" * 40
        import subprocess
        done = subprocess.run([sys.executable, str(h.script("branches")), "--check-push", "origin", "url"], cwd=str(self.root),
                              env=self.env, input=f"refs/heads/work {sha} refs/heads/work {'0' * 40}\n",
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(len(done.stderr.strip().splitlines()), 1)
        self.assertTrue(done.stderr.startswith("pre-push: refusing to push work"))
        ok = subprocess.run([sys.executable, str(h.script("branches")), "--check-push", "origin", "url"], cwd=str(self.root),
                            env=self.env, input="", capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0)


if __name__ == "__main__":
    import unittest
    unittest.main()
