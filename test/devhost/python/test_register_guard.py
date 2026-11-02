"""register_guard.py: the guard of an agentic-register register, run as agentic-register runs it
(a body on stdin, no environment of the writer, cwd elsewhere, the repository named by --root)."""
from __future__ import annotations

import json
import os
import subprocess
import sys

import helpers as h

NAME = "Guinevere Pendragon"
BODY = {"title": "Plant the seed", "data": {"friction": "none"}}
# Assembled at run time so no secret-shaped literal sits in this file.
TOKEN = "ghp_" + "a1B2" * 9


class RegisterGuard(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        (self.root / ".devhost").mkdir(exist_ok=True)
        (self.root / ".devhost" / "redact-names.txt").write_text(f"# names\n{NAME}\nZed\n", encoding="utf-8")

    def guard(self, body, *args, env=None, root=True):
        text = body if isinstance(body, str) else json.dumps(body, separators=(",", ":"), sort_keys=True)
        argv = ([f"--root={self.root}"] if root else []) + list(args)
        # What agentic-register gives a guard: a fixed environment (here without even PATH's extras), cwd elsewhere.
        clean = {"PATH": "/usr/local/bin:/usr/bin:/bin", "AGENTIC_REGISTER_GUARD_REGISTER": "ledger", **(env or {})}
        return subprocess.run([sys.executable, "-I", str(h.script("register_guard")), *argv], input=text,
                              capture_output=True, text=True, encoding="utf-8", env=clean, cwd=str(self.base))

    def test_a_clean_body_passes(self):
        done = self.guard(BODY)
        self.assertEqual((done.returncode, done.stderr), (0, ""))

    def test_a_redact_name_is_refused_by_rule_in_any_case_and_inside_json_escapes(self):
        for body in ({**BODY, "title": f"Asked {NAME.upper()} about it"}, {**BODY, "title": "met zed today"}):
            done = self.guard(body)
            self.assertEqual(done.returncode, 1)
            self.assertTrue(done.stderr.startswith("refused: redact name #"), done.stderr)
        (self.root / ".devhost" / "redact-names.txt").write_text("Zoë\n", encoding="utf-8")
        done = self.guard('{"title":"Zo\\u00eb"}')
        self.assertEqual(done.returncode, 1, "a name written as a JSON escape is found when decoded")

    def test_a_forbidden_word_from_the_argument_or_the_environment_is_refused(self):
        done = self.guard({**BODY, "title": "for Acme Corp"}, "--forbidden=nothing,acme corp")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stderr.strip(), "refused: forbidden word #2")
        done = self.guard({**BODY, "title": "for Acme Corp"}, env={"DEVHOST_FORBIDDEN_WORDS": "Acme"})
        self.assertEqual(done.returncode, 1)
        self.assertTrue(done.stderr.startswith("refused: forbidden word #"))

    def test_a_secret_is_refused_unless_it_is_allowed(self):
        done = self.guard({**BODY, "data": {"note": f"token {TOKEN}"}})
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stderr.strip(), "refused: looks like a GitHub token")
        (self.root / ".devhost" / "allowed-secrets.txt").write_text(f"# published\n{TOKEN}\n", encoding="utf-8")
        self.assertEqual(self.guard({**BODY, "data": {"note": f"token {TOKEN}"}}).returncode, 0)
        done = self.guard({**BODY, "data": {"k": "-----BEGIN " + "OPENSSH PRIVATE KEY-----\nabc"}})
        self.assertEqual(done.returncode, 1)
        self.assertIn("private key block", done.stderr)

    def test_no_matched_text_is_ever_written(self):
        cases = [({**BODY, "title": f"x {NAME} y"}, ()), ({**BODY, "title": "Acme Corp"}, ("--forbidden=Acme Corp",)),
                 ({**BODY, "data": {"n": TOKEN}}, ())]
        for body, args in cases:
            done = self.guard(body, *args)
            self.assertEqual(done.returncode, 1)
            for leaked in (NAME, NAME.split()[0], "Acme", TOKEN, TOKEN[:8]):
                self.assertNotIn(leaked, done.stderr + done.stdout)

    def test_no_name_list_means_no_names_but_an_unreadable_one_stops_the_guard(self):
        (self.root / ".devhost" / "redact-names.txt").unlink()
        self.assertEqual(self.guard({**BODY, "title": NAME}).returncode, 0)
        if os.name != "nt" and os.geteuid() != 0:
            path = self.root / ".devhost" / "redact-names.txt"
            path.write_text(NAME + "\n", encoding="utf-8")
            path.chmod(0)
            try:
                done = self.guard(BODY)
                self.assertEqual(done.returncode, 2, "unreadable names must never let an entry through")
                self.assertNotIn(NAME, done.stderr)
            finally:
                path.chmod(0o600)

    def test_misuse_cannot_run(self):
        for args, root in (((), False), (("--root=relative/path",), False), (("--bogus",), True)):
            done = self.guard(BODY, *args, root=root)
            self.assertEqual(done.returncode, 2, args)
            self.assertTrue(done.stderr.startswith("guard cannot run"))

    def test_it_does_not_need_the_writers_environment_or_working_directory(self):
        done = self.guard(BODY, env={"DEVHOST_ROOT": "/nonexistent"})
        self.assertEqual(done.returncode, 0)
