"""package.py: byte-for-byte copying, the refusals, the index, front matter only where missing."""
from __future__ import annotations

import hashlib

import helpers as h

PNG = bytes(range(256)) + b"\r\n\x00end"  # not text: must survive byte for byte


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Package(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.pkg = h.load("package")
        self.out = self.root / "out"
        h.write(self.root / "LEXICON.md", "# Lexicon\n\nWords.\n")
        h.write(self.root / "docs" / "model" / "ontology.toml", "[a]\nname = 'x'\n")
        (self.root / "docs" / "model" / "figure.png").write_bytes(PNG)
        h.write(self.root / "docs" / "marked.md", "# Marked\r\nkeep me\r\n")
        h.write(self.root / "docs" / "front.md", "---\ntitle: mine\n---\nbody\n")
        h.write(self.root / "docs" / "iterations" / "foundation.txt",
                "# the foundation\nLEXICON.md\n\ndocs/model/ontology.toml\ndocs/model/figure.png\n"
                "!docs/marked.md\ndocs/front.md\n")
        h.write(self.root / "docs" / "iterations" / "papers" / "iteration-3.md", "# Iteration 3\n\nThe story.\n")
        h.write(self.root / "docs" / "iterations" / "seed" / "README.md", "# The seed\r\nPoint an agent here.\r\n")
        (self.root / "docs" / "iterations" / "starter").mkdir(parents=True)
        (self.root / "docs" / "iterations" / "starter" / "devcontainer.json").write_bytes(b'{"a": 1}\r\n')
        (self.root / "docs" / "iterations" / "starter" / "pic.png").write_bytes(PNG)
        for name in ("plant-a-seed", "drop-a-seed", "ledger-review", "shutdown-devhost", "restart-devhost"):
            skill = self.root / ".claude" / "skills" / name
            h.write(skill / "SKILL.md", f"---\nname: {name}\n---\nBody.\r\n")
        (self.root / ".claude" / "skills" / "drop-a-seed" / "journalist.md").write_bytes(PNG)

    def run_cli(self, *extra: str):
        args = ["package", "--iteration", "3", "--date", "2026-10-19", "--out", "out",
                "--paper", "docs/iterations/papers/iteration-3.md", *extra]
        return h.run(args, self.root, self.env)

    def rows(self, folder=None) -> dict:
        folder = folder or self.out
        rows = {}
        for line in (folder / "PACKAGE.md").read_text(encoding="utf-8").splitlines():
            m = self.pkg.ROW.match(line)
            if m:
                rows[m.group(1)] = (m.group(2), m.group(3))
        return rows

    def test_the_first_package_from_nothing_received(self):
        done = self.run_cli()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("wrote 15 files", done.stdout)
        self.assertIn("(`drop-a-seed`, `ledger-review`, `plant-a-seed`, `restart-devhost`, `shutdown-devhost`): "
                      "`plant-a-seed` imports the seed", (self.out / "PACKAGE.md").read_text(encoding="utf-8"))
        rows = self.rows()
        self.assertEqual(rows["papers/iteration-3.md"][1], "paper")
        self.assertEqual(rows["foundation/LEXICON.md"][1], "derived")
        self.assertEqual(rows["foundation/docs/model/ontology.toml"][1], "original")
        self.assertEqual(rows["foundation/docs/marked.md"][1], "original")
        self.assertEqual(rows["foundation/docs/front.md"][1], "foundation")
        for name, (digest, _) in rows.items():
            self.assertEqual(sha((self.out / name).read_bytes()), digest, name)
        index = (self.out / "PACKAGE.md").read_text(encoding="utf-8")
        self.assertIn("iteration: 3\ndate: 2026-10-19\n", index)
        self.assertIn("must not be deleted", index)

    def test_originals_are_copied_byte_for_byte(self):
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual((self.out / "foundation/docs/model/figure.png").read_bytes(), PNG)
        self.assertEqual((self.out / "foundation/docs/marked.md").read_bytes(), b"# Marked\r\nkeep me\r\n")
        self.assertEqual((self.out / "foundation/docs/front.md").read_bytes(), b"---\ntitle: mine\n---\nbody\n")

    def test_front_matter_only_where_there_is_none(self):
        self.assertEqual(self.run_cli().returncode, 0)
        lexicon = (self.out / "foundation/LEXICON.md").read_text(encoding="utf-8")
        self.assertEqual(lexicon, "---\niteration: 3\ndate: 2026-10-19\nsources:\n  - LEXICON.md\n---\n# Lexicon\n\nWords.\n")
        paper = (self.out / "papers/iteration-3.md").read_text(encoding="utf-8")
        self.assertTrue(paper.startswith("---\niteration: 3\n"))
        self.assertEqual(paper.count("---\n"), 2)

    def test_a_second_package_carries_every_paper_unchanged(self):
        self.assertEqual(self.run_cli().returncode, 0)
        received = self.root / "docs" / "iterations" / "package"
        received.mkdir(parents=True)
        for src in self.out.rglob("*"):
            if src.is_file():
                (received / src.relative_to(self.out)).parent.mkdir(parents=True, exist_ok=True)
                (received / src.relative_to(self.out)).write_bytes(src.read_bytes())
        old_paper = (received / "papers/iteration-3.md").read_bytes()
        h.write(self.root / "iteration-4.md", "---\niteration: 4\n---\nNext story.\n")
        out2 = self.root / "out2"
        done = h.run(["package", "--iteration", "4", "--out", "out2", "--paper", "iteration-4.md",
                      "--papers", "nowhere", "--date", "2026-11-01"], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((out2 / "papers/iteration-3.md").read_bytes(), old_paper)
        self.assertEqual((out2 / "papers/iteration-4.md").read_bytes(), b"---\niteration: 4\n---\nNext story.\n")
        self.assertEqual(self.rows(out2)["papers/iteration-3.md"][0], sha(old_paper))

    def test_a_received_paper_that_changed_is_refused(self):
        self.assertEqual(self.run_cli().returncode, 0)
        received = self.root / "docs" / "iterations" / "package"
        received.mkdir(parents=True)
        (received / "papers").mkdir()
        (received / "PACKAGE.md").write_bytes((self.out / "PACKAGE.md").read_bytes())
        (received / "papers/iteration-3.md").write_bytes(b"edited\n")
        done = h.run(["package", "--iteration", "4", "--out", "out2", "--paper", "docs/front.md", "--papers", "nowhere"],
                     self.root, self.env)
        self.assertEqual(done.returncode, 2)
        self.assertIn("papers/iteration-3.md", done.stderr)
        self.assertIn("unchanged", done.stderr)
        self.assertFalse((self.root / "out2").exists())

    def test_a_received_folder_without_an_index_is_refused(self):
        (self.root / "docs" / "iterations" / "package").mkdir(parents=True)
        done = self.run_cli()
        self.assertEqual(done.returncode, 2)
        self.assertIn("has no PACKAGE.md", done.stderr)

    def test_a_missing_manifest_entry_is_refused_and_nothing_is_written(self):
        h.write(self.root / "docs" / "iterations" / "foundation.txt", "LEXICON.md\nnot/there.md\n../outside.md\n")
        done = self.run_cli()
        self.assertEqual(done.returncode, 2)
        self.assertIn("foundation.txt:2: not/there.md is listed but is not a file", done.stderr)
        self.assertIn("foundation.txt:3: ../outside.md is not a repository-relative path", done.stderr)
        self.assertFalse(self.out.exists())

    def test_a_missing_manifest_is_refused(self):
        done = self.run_cli("--foundation", "docs/iterations/none.txt")
        self.assertEqual(done.returncode, 2)
        self.assertIn("manifest", done.stderr)

    def test_an_output_folder_that_is_not_empty_is_refused(self):
        h.write(self.out / "old.md", "x")
        done = self.run_cli()
        self.assertEqual(done.returncode, 2)
        self.assertIn("is not empty", done.stderr)
        self.assertEqual([p.name for p in self.out.iterdir()], ["old.md"])

    def test_an_empty_output_folder_is_fine(self):
        self.out.mkdir()
        self.assertEqual(self.run_cli().returncode, 0)

    def test_the_new_paper_may_already_sit_in_the_papers_folder(self):
        # the papers folder holds the new paper too; it must not clash with its own front-mattered copy
        done = self.run_cli()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(len(list((self.out / "papers").iterdir())), 1)

    def test_a_missing_new_paper_is_refused(self):
        done = h.run(["package", "--iteration", "3", "--out", "out", "--paper", "nope.md"], self.root, self.env)
        self.assertEqual(done.returncode, 2)
        self.assertIn("nope.md is missing", done.stderr)

    def test_the_seed_readme_is_copied_untouched_to_the_root(self):
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual((self.out / "README.md").read_bytes(), b"# The seed\r\nPoint an agent here.\r\n")
        self.assertEqual(self.rows()["README.md"][1], "original")
        self.assertEqual(self.rows()["README.md"][0], sha((self.out / "README.md").read_bytes()))

    def test_a_missing_seed_readme_is_refused(self):
        done = self.run_cli("--readme", "docs/iterations/seed/none.md")
        self.assertEqual(done.returncode, 2)
        self.assertIn("none.md", done.stderr)
        self.assertFalse(self.out.exists())

    def test_the_starter_is_copied_untouched(self):
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual((self.out / "starter/devcontainer.json").read_bytes(), b'{"a": 1}\r\n')
        self.assertEqual((self.out / "starter/pic.png").read_bytes(), PNG)
        rows = self.rows()
        self.assertEqual(rows["starter/devcontainer.json"][1], "original")
        self.assertEqual(rows["starter/pic.png"][0], sha(PNG))

    def test_a_missing_starter_is_refused(self):
        done = self.run_cli("--starter", "docs/iterations/nostarter")
        self.assertEqual(done.returncode, 2)
        self.assertIn("nostarter", done.stderr)
        self.assertFalse(self.out.exists())

    def test_the_skills_are_copied_whole_and_untouched(self):
        self.assertEqual(self.run_cli().returncode, 0)
        for name in ("plant-a-seed", "drop-a-seed", "ledger-review", "shutdown-devhost", "restart-devhost"):
            self.assertEqual((self.out / "skills" / name / "SKILL.md").read_bytes(),
                             f"---\nname: {name}\n---\nBody.\r\n".encode())
        self.assertEqual((self.out / "skills/drop-a-seed/journalist.md").read_bytes(), PNG)
        rows = self.rows()
        self.assertEqual(rows["skills/drop-a-seed/journalist.md"], (sha(PNG), "original"))
        self.assertEqual(rows["skills/ledger-review/SKILL.md"][1], "original")

    def test_the_skills_list_can_be_changed(self):
        self.assertEqual(self.run_cli("--skills", "ledger-review").returncode, 0)
        self.assertFalse((self.out / "skills/plant-a-seed").exists())
        self.assertTrue((self.out / "skills/ledger-review/SKILL.md").is_file())

    def test_a_missing_skill_is_refused(self):
        done = self.run_cli("--skills", "plant-a-seed,nope")
        self.assertEqual(done.returncode, 2)
        self.assertIn("nope", done.stderr)
        self.assertFalse(self.out.exists())

    def test_usage(self):
        self.assertEqual(h.run(["package"], self.root, self.env).returncode, 2)
