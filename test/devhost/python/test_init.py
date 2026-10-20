"""init.py: a fresh directory gets every file; a second run keeps them; --force rewrites a
template but never a record; settings and the hook are merged by hand when present."""
from __future__ import annotations

import json
import tempfile
from pathlib import Path

import helpers as h

EXPECTED = [
    "LEXICON.md", "PROCESS.md", "TODO.md", "docs/ledger/README.md", "docs/adr/0000-template.md", "docs/adr/README.md",
    "docs/night-shift/README.md", ".claude/skills/close-session/SKILL.md", ".claude/skills/ledger-review/SKILL.md",
    ".claude/skills/plant-a-seed/SKILL.md", ".claude/skills/plant-a-seed/INTERVIEW.md",
    ".claude/skills/drop-a-seed/SKILL.md", ".claude/skills/drop-a-seed/journalist.md",
    ".claude/skills/night-shift/SKILL.md", ".claude/skills/new-adr/SKILL.md", ".claude/skills/publish-site/SKILL.md",
    ".claude/skills/shutdown-devhost/SKILL.md", ".claude/skills/restart-devhost/SKILL.md",
    ".devhost/.gitignore",
    ".devhost/CLAUDE.devhost.md", ".claude/settings.json", ".githooks/pre-commit", ".githooks/pre-push", ".gitignore",
]


class Init(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.init = h.load("init")

    def test_a_fresh_directory_gets_every_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            fresh = Path(tmp).resolve() / "fresh-repo"
            fresh.mkdir()
            h.git(fresh, "init", "-q")
            h.git(fresh, "config", "user.name", h.PERSON)  # the git identity, the channel a name could come through
            with h.devhost_env(fresh) as env:
                done = h.run(["init"], fresh, env)
            self.assertEqual(done.returncode, 0, done.stderr)
            for target in EXPECTED:
                self.assertTrue((fresh / target).exists(), target)
                self.assertIn(f"wrote     {target}", done.stdout)
            self.assertNotIn("kept", done.stdout)
            self.assertIn("Add this line to CLAUDE.md", done.stdout)
            self.assertIn("{{", "{{x}}")  # sanity: the next line checks placeholders were filled
            self.assertNotIn("{{", (fresh / "LEXICON.md").read_text(encoding="utf-8"))
            self.assertIn("fresh-repo", (fresh / "LEXICON.md").read_text(encoding="utf-8"))
            self.assertIn("## Decisions for the Operator", (fresh / "TODO.md").read_text(encoding="utf-8"))
            self.assertEqual((fresh / ".gitignore").read_text(encoding="utf-8"), ".devhost/redact-names.txt\n")
            self.assertEqual((fresh / ".githooks" / "pre-commit").read_text(encoding="utf-8").splitlines()[-1], "exec devhost-verify --quiet")
            settings = json.loads((fresh / ".claude" / "settings.json").read_text(encoding="utf-8"))
            self.assertEqual(settings["hooks"]["SessionStart"][0]["hooks"][0], {"type": "command", "command": "devhost-briefing", "timeout": 30})
            stop = [hk["command"] for hk in settings["hooks"]["Stop"][0]["hooks"]]
            self.assertEqual(stop, ["devhost-run-job scribe", "devhost-run-job librarian", "devhost-run-job secretary", "devhost-run-job tester"])
            self.assertTrue(all(hk["async"] and hk["timeout"] == 600 for hk in settings["hooks"]["Stop"][0]["hooks"]))
            self.assertEqual([hk["command"] for hk in settings["hooks"]["SubagentStop"][0]["hooks"]],
                             ["devhost-run-job scribe", "devhost-run-job librarian"])
            self.assertIn("Bash(task *)", settings["permissions"]["allow"])
            self.assertEqual(settings["permissions"]["deny"], ["Read(./.env)", "Read(./.env.*)"])
            # the git identity's name is nowhere in what was written
            for target in EXPECTED:
                self.assertNotIn(h.PERSON, (fresh / target).read_text(encoding="utf-8"), target)

    def test_a_second_run_keeps_everything(self):
        self.init.scaffold(self.root)
        out, extra = self.init.scaffold(self.root)
        self.assertTrue(all(line.startswith("  kept") for line in out), out)
        self.assertEqual(len(out), len(EXPECTED))

    def test_force_rewrites_a_template_but_not_a_record(self):
        self.init.scaffold(self.root)
        h.write(self.root / "LEXICON.md", "edited\n")
        h.write(self.root / "TODO.md", "my backlog\n")
        h.write(self.root / "docs" / "adr" / "README.md", "my index\n")
        h.write(self.root / ".claude" / "settings.json", '{"mine": true}\n')
        out, extra = self.init.scaffold(self.root, force=True)
        self.assertIn("  wrote     LEXICON.md", out)
        self.assertIn("  kept      TODO.md (exists)", out)
        self.assertNotEqual((self.root / "LEXICON.md").read_text(encoding="utf-8"), "edited\n")
        self.assertEqual((self.root / "TODO.md").read_text(encoding="utf-8"), "my backlog\n")
        self.assertEqual((self.root / "docs" / "adr" / "README.md").read_text(encoding="utf-8"), "my index\n")
        self.assertEqual((self.root / ".claude" / "settings.json").read_text(encoding="utf-8"), '{"mine": true}\n')

    def test_existing_settings_and_hooks_are_merged_by_hand(self):
        # the fake repository already has .claude/settings.json; give it a .githooks/ too
        h.write(self.root / ".githooks" / "pre-commit", "#!/bin/sh\nexit 0\n")
        h.write(self.root / ".gitignore", "*.log\n")
        out, extra = self.init.scaffold(self.root)
        self.assertIn("  kept      .claude/settings.json (exists; merge the block printed below by hand)", out)
        self.assertTrue(any(text.startswith("Merge into .claude/settings.json:") and "devhost-run-job scribe" in text for text in extra), extra)
        self.assertIn("  kept      .githooks/pre-commit (.githooks/ exists; add 'devhost-verify --quiet' to your hook)", out)
        self.assertEqual((self.root / ".githooks" / "pre-commit").read_text(encoding="utf-8"), "#!/bin/sh\nexit 0\n")
        self.assertEqual((self.root / ".gitignore").read_text(encoding="utf-8"), "*.log\n.devhost/redact-names.txt\n")
        out, _ = self.init.scaffold(self.root)
        self.assertIn("  kept      .gitignore (has the devhost lines)", out)
