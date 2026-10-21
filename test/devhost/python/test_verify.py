"""verify.py: each guard on a repository that breaks exactly one rule."""
from __future__ import annotations

import helpers as h

ADR_OK = ("# ADR-{n}: Title {n}\n\n| | |\n|---|---|\n| **Status** | proposed |\n| **Date** | 2026-10-01 |\n\n"
          "## Context\n\nx\n\n## Decision\n\ny\n\n## Options considered\n\nz\n\n## Consequences\n\n- a\n\n## Change log\n\n| Date | Change |\n|---|---|\n")


class Verify(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.v = h.load("verify")

    def test_a_clean_repository_passes(self):
        results, notes = self.v.run(self.root)
        self.assertEqual({k: v for k, v in results.items() if v}, {})
        self.assertEqual(notes, [])
        done = h.run(["verify", "--quiet"], self.root, self.env)
        self.assertEqual(done.returncode, 0, done.stdout)
        self.assertEqual(done.stdout, "")
        done = h.run(["verify"], self.root, self.env)
        self.assertIn("ok   ledger_append_only", done.stdout)
        self.assertIn("all guards passed", done.stdout)

    def test_a_changed_ledger_line_on_the_base_is_refused(self):
        path = self.root / "docs" / "ledger" / "2026-10.md"
        text = path.read_text(encoding="utf-8").replace("### 2026-10-01 First thing", "### 2026-10-01 First thing, reworded")
        h.write(path, text + h.entry("2026-10-03", "Third thing"))
        findings = self.v.ledger_append_only(self.root)
        self.assertEqual(len(findings), 1, findings)
        self.assertTrue(findings[0].startswith("docs/ledger/2026-10.md:3: ledger line on main changed"), findings[0])
        done = h.run(["verify", "--quiet"], self.root, self.env)
        self.assertEqual(done.returncode, 1)
        self.assertIn("FAIL ledger_append_only", done.stdout)
        self.assertNotIn("ok   ", done.stdout)

    def test_appending_an_entry_is_fine_and_no_base_ref_is_a_note(self):
        path = self.root / "docs" / "ledger" / "2026-10.md"
        h.write(path, path.read_text(encoding="utf-8") + h.entry("2026-10-03", "Third thing"))
        self.assertEqual(self.v.ledger_append_only(self.root), [])
        notes = []
        with h.devhost_env(self.root, DEVHOST_BASE_REF="no-such-branch"):
            self.assertEqual(self.v.ledger_append_only(self.root, notes), [])
        self.assertEqual(len(notes), 1)
        self.assertIn("NOT RUN", notes[0])

    def _main_gains_an_entry(self):
        h.git(self.root, "switch", "-q", "main")
        path = self.root / "docs" / "ledger" / "2026-10.md"
        h.write(path, path.read_text(encoding="utf-8") + h.entry("2026-10-05", "Added on main by another PR"))
        h.git(self.root, "commit", "-q", "-am", "another PR")
        h.git(self.root, "switch", "-q", "work")

    def test_a_branch_behind_the_base_is_not_blamed_for_its_new_lines(self):
        self._main_gains_an_entry()
        path = self.root / "docs" / "ledger" / "2026-10.md"
        h.write(path, path.read_text(encoding="utf-8") + h.entry("2026-10-03", "Third thing"))
        self.assertEqual(self.v.ledger_append_only(self.root), [])
        self.assertEqual(h.run(["verify", "--quiet"], self.root, self.env).returncode, 0)

    def test_a_branch_behind_the_base_that_edits_a_line_still_fails(self):
        self._main_gains_an_entry()
        path = self.root / "docs" / "ledger" / "2026-10.md"
        h.write(path, path.read_text(encoding="utf-8").replace("### 2026-10-01 First thing", "### 2026-10-01 First thing, reworded"))
        findings = self.v.ledger_append_only(self.root)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("docs/ledger/2026-10.md:3: ledger line on main changed", findings[0])

    def test_the_append_only_guard_runs_when_the_base_ref_exists(self):
        notes = []
        self.assertEqual(self.v.ledger_append_only(self.root, notes), [])
        self.assertEqual(notes, [])
        done = h.run(["verify"], self.root, self.env)
        self.assertIn("ok   ledger_append_only", done.stdout)
        self.assertNotIn("SKIP", done.stderr)
        self.assertNotIn("NOT RUN", done.stdout + done.stderr)

    def test_a_skipped_guard_is_loud_even_when_quiet(self):
        env = dict(self.env, DEVHOST_BASE_REF="no-such-branch")
        for args in (["verify"], ["verify", "--quiet"]):
            done = h.run(args, self.root, env)
            self.assertEqual(done.returncode, 0, done.stdout)
            self.assertIn("WARNING ledger append-only guard NOT RUN", done.stderr)
            self.assertNotIn("ok   ledger_append_only", done.stdout)
        self.assertIn("SKIP ledger_append_only", h.run(["verify"], self.root, env).stderr)

    def test_the_task_runs_in_the_directory_it_was_called_from(self):
        """The root cause: an included Taskfile's tasks run in the include's folder, outside the repository."""
        import re
        from pathlib import Path
        text = (Path(h.__file__).resolve().parents[3] / "src" / "devhost" / "taskfile.yml").read_text(encoding="utf-8")
        for name in ("setup", "briefing", "report", "costs", "adr", "verify", "init"):
            block = re.search(rf"^  {name}:\n(.*?)(?=^  \w|\Z)", text, re.S | re.M).group(1)
            self.assertIn("dir: '{{.USER_WORKING_DIR}}'", block, name)

    def test_ledger_shape(self):
        folder = self.root / "docs" / "ledger"
        h.write(folder / "2026-11.md", "# Ledger, 2026-11\n\n## Notes\n\n### 2026-11-01 Fine\n\n#### deeper is fine\n")
        h.write(folder / "costs-2026-11-tester.md", "# Agent costs, 2026-11, tester\n")
        h.write(folder / "costs-2026-11.md", "# Agent costs, 2026-11\n")
        h.write(folder / "README.md", "# The ledger\n")
        findings = self.v.ledger_shape(self.root)
        self.assertEqual(findings, [
            "docs/ledger/2026-11.md:3: headings are '### YYYY-MM-DD <title>' or '## Review YYYY-MM-DD' only",
            "docs/ledger/costs-2026-11.md:1: the ledger directory holds YYYY-MM.md, costs-YYYY-MM-<engineer>.md and README.md only",
        ])
        h.write(folder / "2026-12.md", "# Ledger\n")
        self.assertIn("docs/ledger/2026-12.md:1: must start with '# Ledger, 2026-12'", self.v.ledger_shape(self.root))

    def test_corrects_none_is_refused_from_2026_10_19_only(self):
        folder = self.root / "docs" / "ledger"
        h.write(folder / "2026-10.md", "# Ledger, 2026-10\n\n"
                "### 2026-10-18 Before the rule\n\n- **Corrects:** none\n\n"
                "### 2026-10-19 After it\n\n- **Corrects:** None.\n\n"
                "### 2026-10-20 A real correction\n\n- **Corrects:** 2026-10-19 After it\n")
        self.assertEqual([f for f in self.v.ledger_shape(self.root) if "2026-10.md" in f],
                         ["docs/ledger/2026-10.md:9: 'Corrects: none'; leave the line out when the entry corrects nothing"])

    def test_secret_patterns_and_the_allow_list(self):
        token = "ghp_" + "a" * 36
        h.write(self.root / "config.md", f"token: {token}\n\nAccountKey={'B' * 64}==\n")
        h.write(self.root / "untracked.md", f"{token}\n")
        h.track(self.root)
        (self.root / "untracked.md").unlink()
        h.write(self.root / "untracked.md", f"{token}\n")  # back as an untracked file
        h.git(self.root, "rm", "-q", "--cached", "untracked.md")
        findings = self.v.secrets(self.root)
        self.assertEqual(findings, ["config.md:1: looks like a GitHub token", "config.md:3: looks like a storage account key"])
        self.assertNotIn(token, "\n".join(findings))
        h.write(self.root / ".devhost" / "allowed-secrets.txt", f"# published values\n{token}\n")
        h.track(self.root)
        self.assertEqual(self.v.secrets(self.root), ["config.md:3: looks like a storage account key"])

    def test_a_tracked_env_file_is_refused_but_templates_are_fine(self):
        h.write(self.root / ".env", "NOTHING=here\n")
        h.write(self.root / "sub" / ".env.local", "NOTHING=here\n")
        h.write(self.root / ".env.example", "NOTHING=\n")
        h.track(self.root)
        findings = self.v.secrets(self.root)
        self.assertEqual(sorted(findings), [
            ".env: a tracked env file; ignore it, keep a .env.example instead",
            "sub/.env.local: a tracked env file; ignore it, keep a .env.example instead"])

    def test_forbidden_words_and_redact_names_are_reported_by_number(self):
        h.write(self.root / "notes.md", "Nothing here.\nThe Zorblat account, and Someone Special's desk.\n")
        h.write(self.root / ".devhost" / "redact-names.txt", "Someone Special\n")
        h.write(self.root / ".gitignore", ".devhost/redact-names.txt\n")
        h.track(self.root)
        with h.devhost_env(self.root, DEVHOST_FORBIDDEN_WORDS="acme;zorblat"):
            findings = self.v.forbidden_words(self.root)
        self.assertEqual(findings, ["notes.md:2: forbidden word #2", "notes.md:2: forbidden word #3"])
        self.assertNotIn("zorblat", "\n".join(findings).lower())
        with h.devhost_env(self.root):
            self.assertEqual(self.v.forbidden_words(self.root), ["notes.md:2: forbidden word #1"], "the redact names alone")

    def test_a_file_the_operator_approved_may_carry_names(self):
        h.write(self.root / "paper.md", "By Someone Special.\n")
        h.write(self.root / "notes.md", "Someone Special again.\n")
        h.write(self.root / ".devhost" / "redact-names.txt", "Someone Special\n")
        h.write(self.root / ".devhost" / "name-exceptions.txt", "# the paper, with its byline\npaper.md\n")
        h.write(self.root / ".gitignore", ".devhost/redact-names.txt\n")
        h.track(self.root)
        with h.devhost_env(self.root):
            self.assertEqual(self.v.forbidden_words(self.root), ["notes.md:1: forbidden word #1"])

    def test_adr_shape_numbering_and_index(self):
        folder = self.root / "docs" / "adr"
        h.write(folder / "0000-template.md", "# ADR-NNNN: Title\n")
        h.write(folder / "README.md", "# ADRs\n\n| ADR | Title | Status | Date |\n|---|---|---|---|\n| [0001](0001-one.md) | One | proposed | 2026-10-01 |\n")
        h.write(folder / "0001-one.md", ADR_OK.format(n="0001"))
        self.assertEqual(self.v.adrs(self.root), [])
        h.write(folder / "0003-three.md", ADR_OK.format(n="0003").replace("| **Status** | proposed |", "| **Status** | maybe |").replace("## Consequences\n\n- a\n\n", ""))
        findings = self.v.adrs(self.root)
        self.assertIn("docs/adr:0: ADR numbers are not consecutive from 0001: [1, 3]", findings)
        self.assertIn("docs/adr/0003-three.md:1: lacks the section '## Consequences'", findings)
        self.assertIn("docs/adr/0003-three.md:1: the status must start with one of ['accepted', 'proposed', 'rejected', 'superseded']", findings)
        self.assertIn("docs/adr/README.md:1: 0003-three.md is not in the index", findings)
        h.write(folder / "0002-two.md", "# Two\n")
        self.assertIn("docs/adr/0002-two.md:1: the title line must be '# ADR-0002: Title'", self.v.adrs(self.root))

    def test_every_task_has_a_desc(self):
        h.write(self.root / "Taskfile.yml", "\n".join([
            "version: '3'", "", "includes:", "  devhost: x.yml", "", "tasks:", "  default:", "    cmds:", "      - task --list", "",
            "  build:", "    desc: Build it", "    cmds:", "      - make", "", "  deploy:prod:", "    cmds:", "      - echo", "",
            "  last:", "    silent: true", "", "other:", "  x: 1", ""]))
        self.assertEqual(self.v.taskfile(self.root), ["Taskfile.yml:16: task 'deploy:prod' has no desc", "Taskfile.yml:20: task 'last' has no desc"])

    def test_skills_have_frontmatter_naming_their_directory(self):
        skills = self.root / ".claude" / "skills"
        h.write(skills / "good" / "SKILL.md", "---\nname: good\ndescription: Does a thing. Use it when asked.\n---\n\n# Good\n")
        h.write(skills / "renamed" / "SKILL.md", "---\nname: other\ndescription: x\n---\n")
        h.write(skills / "silent" / "SKILL.md", "---\nname: silent\n---\n")
        h.write(skills / "bare" / "SKILL.md", "# No frontmatter\n")
        (skills / "empty").mkdir()
        self.assertEqual(self.v.skills(self.root), [
            ".claude/skills/bare/SKILL.md:1: no frontmatter",
            ".claude/skills/empty/SKILL.md:1: missing",
            ".claude/skills/renamed/SKILL.md:2: frontmatter name 'other' is not the directory name 'renamed'",
            ".claude/skills/silent/SKILL.md:2: frontmatter needs a description saying what the skill does and when to use it",
        ])

    def test_a_non_executable_hook_is_refused(self):
        h.write(self.root / ".githooks" / "pre-commit", "#!/bin/sh\nexit 0\n")
        h.git(self.root, "config", "core.hooksPath", ".githooks")
        h.git(self.root, "add", ".githooks/pre-commit")
        self.assertEqual(self.v.hook_modes(self.root), [
            ".githooks/pre-commit:1: hook is mode 100644 in the index, so it never runs on Linux; "
            "fix: git update-index --chmod=+x .githooks/pre-commit && chmod +x .githooks/pre-commit"])

    def test_an_executable_hook_passes(self):
        h.write(self.root / ".githooks" / "pre-commit", "#!/bin/sh\nexit 0\n")
        h.git(self.root, "config", "core.hooksPath", ".githooks")
        h.git(self.root, "add", "--chmod=+x", ".githooks/pre-commit")
        self.assertEqual(self.v.hook_modes(self.root), [])

    def test_no_hooks_path_or_an_untracked_one_passes(self):
        self.assertEqual(self.v.hook_modes(self.root), [])
        h.git(self.root, "config", "core.hooksPath", ".githooks")
        h.write(self.root / ".githooks" / "pre-commit", "x\n")
        self.assertEqual(self.v.hook_modes(self.root), [])

    def test_the_scaffolded_repository_passes_every_guard(self):
        init = h.load("init")
        init.scaffold(self.root)
        h.track(self.root)
        results, _ = self.v.run(self.root)
        self.assertEqual({k: v for k, v in results.items() if v}, {})

    def test_conflict_markers_are_refused_at_the_start_of_a_line_only(self):
        lt, gt = "<" * 7, ">" * 7
        h.write(self.root / "docs" / "notes.md", f"text\n{lt} Updated upstream\nmine\n=======\ntheirs\n{gt} Stashed changes\n")
        h.write(self.root / "docs" / "about.md", f"A marker quoted inline, `{lt}`, is fine.\n")
        h.track(self.root)
        self.assertEqual(self.v.conflict_markers(self.root), [
            "docs/notes.md:2: a merge-conflict marker; resolve the conflict",
            "docs/notes.md:6: a merge-conflict marker; resolve the conflict",
        ])

    def test_the_entrypoint_runs_the_source_guards_in_the_devhost_repository(self):
        import subprocess
        entry = h.PYTHON_DIR.parent / "bin" / "entrypoints" / "verify"
        h.write(self.root / "src" / "devhost" / "share" / "python" / "verify.py", "print('source guards')\n")
        done = subprocess.run(["bash", str(entry)], cwd=str(self.root), capture_output=True, text=True)
        self.assertEqual(done.stdout.strip(), "source guards", done.stderr)


ONTOLOGY = """types = ["role", "record"]
predicates = ["keeps"]

[host]
type = "role"
term = "Host"
summary = "The main session."

[ledger]
type = "record"
term = "Ledger"
summary = "What agents did."

[[relation]]
subject = "host"
predicate = "keeps"
object = "ledger"
"""
LEXICON = "# Lexicon\n\n- **Host** (the main session): x.\n  - **Ledger**: y.\n"
DIAGRAM = ("# View\n\n```mermaid\nflowchart LR\n  subgraph host[\"Host\"]\n    ledger[\"Ledger\"]\n  end\n"
           "  external-github[\"GitHub\"]\n  host -->|keeps| ledger\n  ledger -.-> external-github\n```\n")


class Model(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.v = h.load("verify")
        self.model = self.root / "docs" / "model"
        h.write(self.root / "LEXICON.md", LEXICON)
        h.write(self.model / "ontology.toml", ONTOLOGY)
        h.write(self.model / "themes" / "a.toml", 'host = "Merlin"\nledger = "the Chronicle"\n')
        h.write(self.model / "c4.md", DIAGRAM)

    def ontology(self, old: str, new: str) -> None:
        h.write(self.model / "ontology.toml", ONTOLOGY.replace(old, new))

    def test_a_consistent_model_passes_and_no_model_is_skipped(self):
        self.assertEqual(self.v.model(self.root), [])
        (self.model / "ontology.toml").unlink()
        self.assertEqual(self.v.model(self.root), [], "no ontology.toml: quietly fine, whatever else is in docs/model")

    def test_invalid_toml_is_refused(self):
        self.ontology('type = "role"', 'type = role')
        findings = self.v.model(self.root)
        self.assertEqual(len(findings), 1, findings)
        self.assertTrue(findings[0].startswith("docs/model/ontology.toml:5: not valid TOML"), findings[0])

    def test_a_non_kebab_id_is_refused(self):
        h.write(self.model / "ontology.toml", ONTOLOGY.replace("[ledger]", "[Ledger_X]"))
        findings = [f for f in self.v.model(self.root) if "kebab" in f]
        self.assertEqual(findings, ["docs/model/ontology.toml:9: id 'Ledger_X' is not kebab-case; fix: rename it to lowercase words joined by dashes"])

    def test_a_duplicate_id_is_refused(self):
        h.write(self.model / "ontology.toml", ONTOLOGY + '\n[host]\ntype = "role"\n')
        findings = self.v.model(self.root)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("not valid TOML", findings[0])

    def test_an_unknown_type_is_refused(self):
        self.ontology('type = "record"', 'type = "thing"')
        findings = [f for f in self.v.model(self.root) if "type" in f]
        self.assertEqual(len(findings), 1, findings)
        self.assertTrue(findings[0].startswith("docs/model/ontology.toml:9: id 'ledger' has type 'thing'"), findings[0])

    def test_a_missing_term_or_summary_is_refused(self):
        self.ontology('summary = "The main session."\n', "")
        findings = self.v.model(self.root)
        self.assertEqual(findings, ["docs/model/ontology.toml:4: id 'host' has no summary; fix: add summary = \"...\""])

    def test_a_relation_with_an_unknown_end_or_predicate_is_refused(self):
        self.ontology('object = "ledger"', 'object = "ledgr"')
        findings = self.v.model(self.root)
        self.assertEqual(len(findings), 1, findings)
        self.assertTrue(findings[0].startswith("docs/model/ontology.toml:14: relation object 'ledgr' is not an id; fix:"), findings[0])
        self.ontology('subject = "host"', 'subject = "nobody"')
        self.assertTrue(any("relation subject 'nobody' is not an id" in f for f in self.v.model(self.root)))
        h.write(self.model / "ontology.toml", ONTOLOGY.replace('predicate = "keeps"', 'predicate = "eats"'))
        findings = [f for f in self.v.model(self.root) if "predicate" in f]
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("predicate 'eats' is not in `predicates`", findings[0])

    def test_a_theme_key_that_is_not_an_id_is_refused(self):
        h.write(self.model / "themes" / "a.toml", 'host = "Merlin"\nknight = "x"\n')
        findings = self.v.model(self.root)
        self.assertEqual(len(findings), 1, findings)
        self.assertTrue(findings[0].startswith("docs/model/themes/a.toml:2: theme key 'knight' is not an ontology id; fix:"), findings[0])

    def test_a_lexicon_term_without_an_id_is_refused(self):
        h.write(self.root / "LEXICON.md", LEXICON + "- **Stake**: z.\n")
        findings = [f for f in self.v.model(self.root) if "Stake" in f]
        self.assertEqual(len(findings), 1, findings)
        self.assertTrue(findings[0].startswith("LEXICON.md:5: term 'Stake' has no ontology id; fix:"), findings[0])

    def test_an_ontology_term_missing_from_or_unlike_the_lexicon_is_refused(self):
        self.ontology('term = "Ledger"', 'term = "Chronicle"')
        findings = self.v.model(self.root)
        self.assertTrue(any(f.startswith("docs/model/ontology.toml:9: term 'Chronicle' of 'ledger' is not a bold term of LEXICON.md") for f in findings), findings)
        self.assertTrue(any("LEXICON.md:4: term 'Ledger' has no ontology id" in f for f in findings), findings)

    def test_a_diagram_node_that_is_not_an_id_is_refused(self):
        h.write(self.model / "c4.md", DIAGRAM.replace("host -->|keeps| ledger", "host -->|keeps| knight"))
        findings = [f for f in self.v.model(self.root) if "c4.md" in f]
        self.assertEqual(len(findings), 1, findings)
        self.assertTrue(any(f.startswith("docs/model/c4.md:9: node id 'knight' is not an ontology id; fix:") for f in findings), findings)

    def test_the_guard_runs_in_verify(self):
        results, _ = self.v.run(self.root)
        self.assertEqual(results["model"], [])
        h.write(self.model / "c4.md", DIAGRAM.replace("host -->|keeps| ledger", "host -->|keeps| knight"))
        done = h.run(["verify", "--quiet"], self.root, self.env)
        self.assertEqual(done.returncode, 1)
        self.assertIn("FAIL model", done.stdout)
