"""Docker-free unit tests of phi-check (src/phi-check). All data is synthetic
and assembled here from parts, never a real record. PHI_CHECK_SRC points the
tests at another copy of the Feature folder (the mutation check)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("PHI_CHECK_SRC") or os.path.join(HERE, "..", "..", "..", "src", "phi-check")
SRC = os.path.abspath(SRC)
CLI = os.path.join(SRC, "phi-check.py")
sys.path.insert(0, SRC)
import phi_patterns  # noqa: E402

SSN = "-".join(["123", "45", "6789"])
SSN_PARTS = ("123", "45", "6789")
MBI = "1EG4TE5MK73"
MBI_DASHED = "1EG4-TE5-MK73"


def rules(text):
    return [r for _, r in phi_patterns.scan(text)]


def has(text, fragment):
    return any(fragment in r for r in rules(text))


def ssn(area="123", group="45", serial="6789"):
    return "%s-%s-%s" % (area, group, serial)


def fhir(extra_lines=0, key='"birthDate": "1990-01-01"', rtype="Patient"):
    body = ['{', '  "resourceType": "%s",' % rtype]
    body += ['  "x%d": 0,' % i for i in range(extra_lines)]
    body += ['  %s' % key, '}']
    return "\n".join(body)


class Tier1(unittest.TestCase):
    def test_ssn_dashed(self):
        self.assertTrue(has("id " + ssn() + " end", "Social Security"))
        self.assertTrue(has(ssn(), "Social Security"))

    def test_ssn_never_issued_ranges_pass(self):
        for bad in (ssn("000"), ssn("666"), ssn("900"), ssn("987"), ssn("999"),
                    ssn(group="00"), ssn(serial="0000")):
            self.assertEqual(rules(bad), [], bad)

    def test_ssn_must_be_a_whole_token(self):
        for text in ("1" + ssn(), ssn() + "0", "a-" + ssn(), ssn() + "-1", "x" + ssn()):
            self.assertEqual(rules(text), [], text)

    def test_ssn_labelled_nine_digits(self):
        for label in ("SSN", "ssn:", "Social Security Number", "social security no.",
                      "social security #", "SSN #", "Social Security Number:"):
            self.assertTrue(has("%s 123456789" % label, "Social Security"), label)

    def test_nine_digits_alone_or_wrong_length_pass(self):
        self.assertEqual(rules("123456789"), [])
        self.assertEqual(rules("order 123456789"), [])
        self.assertEqual(rules("SSN: 12345678"), [])
        self.assertEqual(rules("SSN: 1234567890"), [])

    def test_mbi(self):
        self.assertTrue(has("mbi " + MBI, "Medicare"))
        self.assertTrue(has("mbi " + MBI_DASHED, "Medicare"))
        self.assertTrue(has("1EG4-TE5MK73", "Medicare"))

    def test_mbi_near_misses(self):
        for text in (MBI.lower(),                 # lower case
                     "1SG4TE5MK73",               # S is never used
                     "1LG4TE5MK73", "1OG4TE5MK73", "1IG4TE5MK73", "1BG4TE5MK73", "1ZG4TE5MK73",
                     "0EG4TE5MK73",               # first character not 0
                     "1EG4TE5MK7",                # 10 characters
                     "1EG4TE5MK733",              # 12 characters
                     "x" + MBI, MBI + "x",        # not a whole token
                     "1EG4TE5M373",               # position 9 a digit
                     "1EGATE5MK73"):              # position 4 a letter
            self.assertEqual(rules(text), [], text)

    def test_x12_segments_positive(self):
        cases = {
            "NM1 person": "NM1*IL*1*LASTNAME*FIRST****MI*X~",
            "NM1 patient": "ST*837~NM1*QC*1*LASTNAME*FIRST~",
            "DMG": "DMG*D8*19800101*F~",
            "INS": "INS*Y*18*001*20~",
            "HI BK": "HI*BK:E1165~",
            "HI ABK": "HI*ABK:E1165*ABF:J45909~",
            "CLM": "CLM*ABC123*125.50***11:B:1~",
        }
        for name, text in cases.items():
            self.assertTrue(has(text, "X12"), name)

    def test_x12_near_misses(self):
        for text in ("NM1*IL*2*ORGANISATION~",      # an organisation, not a person
                     "NM1*PR*1*PAYER~",              # entity not IL or QC
                     "NM1*IL*1*~",                   # no value
                     "DMG*D8*1980~",                 # not 8 digits
                     "DMG*D9*19800101~",
                     "INS*Y*1*",                     # one digit
                     "INS*X*18*",
                     "HI*BK:~",                      # no code
                     "HI*BG:E1165~",
                     "CLM*ABC123*~",                 # no amount
                     "CLM*ABC123*abc~",
                     "nm1*il*1*lastname~"):          # lower case
            self.assertEqual(rules(text), [], text)

    def test_hl7(self):
        self.assertTrue(has("PID|1||ABC^^^X||LAST^FIRST", "HL7"))
        self.assertTrue(has("MSH|^~\\&|A\nNK1|1|LAST^FIRST|", "HL7"))
        self.assertTrue(has("MSH|a\rPID|1|x", "HL7"))

    def test_hl7_near_misses(self):
        for text in ("PID", "PID|", "PID|1", "a PID|1|2", "PIDGEON|1|2", "pid|1|2", "OBX|1|2|3"):
            self.assertEqual(rules(text), [], text)

    def test_fhir_patient(self):
        for key in ('"birthDate": "1990-01-01"', '"identifier": []', '"name": []'):
            self.assertTrue(has(fhir(key=key), "FHIR"), key)
        self.assertTrue(has(fhir(extra_lines=15), "FHIR"))
        self.assertTrue(has('{"resourceType":"Patient","name":[]}', "FHIR"))

    def test_fhir_near_misses(self):
        self.assertEqual(rules(fhir(rtype="Observation")), [])
        self.assertEqual(rules(fhir(key='"gender": "x"')), [])
        self.assertEqual(rules(fhir(extra_lines=30)), [])      # key out of the 20-line window
        self.assertEqual(rules('{"resourceType": "Patient", "id": "x"}'), [])


class Tier2(unittest.TestCase):
    ID = "MRN: AB12345"

    def test_identifier_with_each_signal(self):
        self.assertTrue(has(self.ID + "\ndx E11.65", "identifier near ICD-10-CM code"))
        self.assertTrue(has(self.ID + "\nthe patient was admitted", "identifier near diagnosis word"))
        self.assertTrue(has(self.ID + "\nPatient: Jane", "identifier near person-name label"))
        self.assertTrue(has(self.ID + "\nDOB: 01/02/1980", "identifier near date of birth"))
        self.assertTrue(has("Mrs Smith\n" + self.ID, "identifier near person-name label"))

    def test_identifier_labels(self):
        for label in ("MRN", "medical record number", "Medical Record No.", "medical record #",
                      "member id", "Member Number", "subscriber ID", "patient id", "patient number",
                      "account #", "claim #", "claim id"):
            self.assertTrue(has("%s: AB12345\ndiagnosed" % label, "identifier"), label)

    def test_identifier_needs_a_token_with_a_digit(self):
        for value in ("pending", "ABCDEFG", "A123", "12-3"):
            self.assertEqual(rules("MRN: %s\ndiagnosed" % value), [], value)

    def test_dob_forms(self):
        for date in ("1/2/1980", "01.02.1980", "01-02-80", "1980-02-01", "19800201",
                     "February 1, 1980", "Feb 1st, 1980", "1 February 1980", "1st of Feb 1980"):
            for label in ("DOB", "D.O.B.", "date of birth", "birth date", "born", "born on"):
                self.assertTrue(has("%s: %s\nPatient: X" % (label, date), "date of birth near"),
                                "%s %s" % (label, date))

    def test_dob_near_misses(self):
        for text in ("DOB: unknown\nPatient: X", "DOB: 1980\nPatient: X", "born in 1980\nPatient: X",
                     "Dobson 01/02/1980\nPatient: X", "01/02/1980\nPatient: X",
                     "DOB: 12345\nPatient: X"):
            self.assertEqual(rules(text), [], text)

    def test_another_anchor_counts(self):
        text = "MRN: AB12345\nDOB: 01/02/1980"
        self.assertEqual(len(rules(text)), 2)
        self.assertTrue(has("MRN: AB12345 and member id: ZX99881", "identifier near identifier"))

    def test_signals_alone_pass(self):
        for text in ("E11.65, I10, J45.909, Z79.4",       # an ICD code list
                     "NPI: 1234567893",                    # an NPI
                     "visited on 2020-01-02 and 03/04/2021",  # plain dates
                     "Patient: Jane Doe", "Mr Smith", "Member: Ann",   # names
                     "was diagnosed and prescribed", "admitted", "discharged",
                     "MRN: AB12345", "DOB: 01/02/1980",    # an anchor alone
                     "diagnosed with E11.65 Patient: Jane"):  # signals together, no anchor
            self.assertEqual(rules(text), [], text)

    def test_window_is_three_lines_centred_on_the_anchor(self):
        self.assertTrue(has(self.ID + "\nadmitted", "identifier"))          # one below
        self.assertTrue(has("admitted\n" + self.ID, "identifier"))          # one above
        self.assertEqual(rules(self.ID + "\n\nadmitted"), [])               # two away
        self.assertEqual(rules(self.ID + "\n\n\nadmitted"), [])             # three away
        self.assertEqual(rules("admitted\n\n\n" + self.ID), [])

    def test_icd_shape(self):
        self.assertTrue(has(self.ID + "\nE11", "ICD"))
        self.assertTrue(has(self.ID + "\nA1B.2345", "ICD"))
        for text in (self.ID + "\ne11.65", self.ID + "\nU07.1",       # lower case; U is not used
                     self.ID + "\nE1", self.ID + "\nE11.65432"):
            self.assertEqual(rules(text), [], text)

    def test_anchor_own_token_is_not_its_signal(self):
        self.assertEqual(rules("MRN: B2B1234"), [])
        self.assertEqual(rules("DOB: 19800201"), [])

    def test_line_is_the_anchors(self):
        self.assertEqual([l for l, _ in phi_patterns.scan("x\nMRN: AB12345\nE11.65")], [2])

    def test_scan_and_find(self):
        text = "SSN %s\nMRN: AB12345\nadmitted\nSSN %s" % (SSN, SSN)
        self.assertEqual([l for l, _ in phi_patterns.scan(text)], [1, 2, 4])
        self.assertEqual(len(phi_patterns.find(text)), 2)
        self.assertEqual(phi_patterns.find("nothing here"), [])
        self.assertEqual(phi_patterns.scan(""), [])


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, content, mode="w"):
        path = os.path.join(self.d, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode + ("b" if isinstance(content, bytes) else "")) as fh:
            fh.write(content)
        return path

    def run_cli(self, *args, stdin=None, cwd=None, env=None):
        e = dict(os.environ)
        e.pop("PHI_CHECK_EXCEPTIONS", None)
        e.update(env or {})
        p = subprocess.run([sys.executable, CLI, *args], input=stdin, capture_output=True,
                           cwd=cwd or self.d, env=e)
        return p.returncode, p.stdout.decode(), p.stderr.decode()

    # --- exit codes and output ------------------------------------------------
    def test_clean(self):
        self.write("a.txt", "nothing here\n")
        rc, out, _ = self.run_cli("a.txt")
        self.assertEqual((rc, out), (0, "phi-check: clean, 1 file(s)\n"))

    def test_findings_text_format(self):
        self.write("a.txt", "ok\nSSN %s\n" % SSN)
        rc, out, _ = self.run_cli("a.txt")
        self.assertEqual(rc, 1)
        self.assertEqual(out.splitlines(), [
            "a.txt:2: PHI tier 1: US Social Security number",
            "phi-check: refused, 1 finding(s) in 1 file(s)"])

    def test_folder_is_every_file_sorted(self):
        self.write("dir/b.txt", "SSN %s\n" % SSN)
        self.write("dir/a/z.txt", "SSN %s\n" % SSN)
        self.write("dir/a.txt", "clean\n")
        self.write("dir/.git/x", "SSN %s\n" % SSN)
        rc, out, _ = self.run_cli("dir")
        self.assertEqual(rc, 1)
        lines = out.splitlines()
        self.assertEqual([l.split(":")[0] for l in lines[:-1]],
                         [os.path.join("dir", "a", "z.txt"), os.path.join("dir", "b.txt")])
        self.assertEqual(lines[-1], "phi-check: refused, 2 finding(s) in 3 file(s)")

    def test_no_output_ever_holds_the_matched_value(self):
        text = "\n".join([
            "SSN: " + SSN, "social security number 987654321", "mbi " + MBI,
            "NM1*IL*1*SECRETLAST*SECRETFIRST~", "DMG*D8*19710203~", "CLM*SECRETCLAIM1*987.65~",
            "PID|1||SECRETPID||SECRETNAME", "MRN: SECRETMRN77", "DOB: 04/05/1966", "admitted",
            fhir(key='"name": "SECRETFHIR"'),
        ])
        secrets = [SSN, "987654321", MBI, "SECRETLAST", "SECRETFIRST", "19710203", "SECRETCLAIM1",
                   "987.65", "SECRETPID", "SECRETNAME", "SECRETMRN77", "04/05/1966", "SECRETFHIR",
                   "1966"]
        self.write("a.txt", text)
        for fmt in ("text", "json", "github"):
            rc, out, err = self.run_cli("--format", fmt, "a.txt")
            self.assertEqual(rc, 1)
            for s in secrets:
                self.assertNotIn(s, out + err, "%s leaked in %s" % (s, fmt))
        rc, out, err = self.run_cli("--format", "text", "-", stdin=text.encode())
        for s in secrets:
            self.assertNotIn(s, out + err)
        # the module's rules never carry it either
        for rule in phi_patterns.find(text):
            for s in secrets:
                self.assertNotIn(s, rule)

    def test_json_and_github_formats(self):
        self.write("a.txt", "x\nSSN %s\n" % SSN)
        rc, out, _ = self.run_cli("--format", "json", "a.txt")
        data = json.loads(out)
        self.assertEqual((rc, data["clean"], data["files"]), (1, False, 1))
        self.assertEqual(data["findings"], [{"path": "a.txt", "line": 2,
                                             "rule": "PHI tier 1: US Social Security number"}])
        rc, out, _ = self.run_cli("--format", "github", "a.txt")
        self.assertEqual(out.splitlines()[0],
                         "::error file=a.txt,line=2::PHI tier 1: US Social Security number")
        self.write("c.txt", "fine\n")
        rc, out, _ = self.run_cli("--format", "json", "c.txt")
        self.assertEqual((rc, json.loads(out)["clean"]), (0, True))

    # --- fail closed ----------------------------------------------------------
    def test_binary_and_undecodable_files_are_findings(self):
        self.write("nul.bin", b"abc\0def")
        self.write("late-nul.bin", b"a" * 9000 + b"\xff\xfe")   # decode error beyond 8 KiB
        self.write("pdf.pdf", b"%PDF-1.4\n\xe2\x28\xa1\n")
        rc, out, _ = self.run_cli("nul.bin", "late-nul.bin", "pdf.pdf")
        self.assertEqual(rc, 1)
        for n in ("nul.bin", "late-nul.bin", "pdf.pdf"):
            self.assertIn("%s: not text; cannot be checked" % n, out)

    def test_missing_path_is_a_finding(self):
        rc, out, _ = self.run_cli("nope.txt")
        self.assertEqual(rc, 1)
        self.assertIn("nope.txt: not found; cannot be checked", out)

    def test_usage_errors_exit_2(self):
        self.write("a.txt", "x\n")
        for args in ([], ["--format", "xml", "a.txt"], ["--bogus", "a.txt"], ["--cwd", "nodir", "a.txt"],
                     ["--exceptions", "nofile.txt", "a.txt"], ["--stdin-filename", "n", "a.txt"],
                     ["--exceptions", "a.txt", "--no-exceptions", "a.txt"], ["-", "-"]):
            rc, out, err = self.run_cli(*args, stdin=b"")
            self.assertEqual(rc, 2, args)
            self.assertEqual(out, "", args)
            self.assertIn("usage error", err)

    def test_version(self):
        rc, out, _ = self.run_cli("--version")
        self.assertEqual((rc, out), (0, "phi-check %s\n" % phi_patterns.VERSION))

    def test_version_matches_the_feature(self):
        with open(os.path.join(SRC, "devcontainer-feature.json")) as fh:
            self.assertEqual(json.load(fh)["version"], phi_patterns.VERSION)

    # --- standard input -------------------------------------------------------
    def test_stdin_with_filename(self):
        rc, out, _ = self.run_cli("--stdin-filename", "staged/x.txt", "-",
                                  stdin=("SSN %s\n" % SSN).encode())
        self.assertEqual(rc, 1)
        self.assertIn("staged/x.txt:1: PHI tier 1", out)
        rc, out, _ = self.run_cli("-", stdin=b"fine\n")
        self.assertEqual((rc, out), (0, "phi-check: clean, 1 file(s)\n"))
        rc, out, _ = self.run_cli("-", stdin=b"\0\1")
        self.assertIn("<stdin>: not text; cannot be checked", out)

    # --- exceptions -----------------------------------------------------------
    def fixtures(self):
        self.write("fix/a.txt", "SSN %s\n" % SSN)
        self.write("other/a.txt", "SSN %s\n" % SSN)
        self.write("b.txt", "SSN %s\n" % SSN)

    def test_exceptions_skip_only_the_listed_path(self):
        self.fixtures()
        self.write(".phi-exceptions.txt", "# synthetic\nfix/a.txt 2026-10-29 synthetic fixture\n")
        rc, out, _ = self.run_cli("fix/a.txt", "other/a.txt", "b.txt")
        self.assertEqual(rc, 1)
        self.assertNotIn("fix/a.txt:1", out)
        self.assertIn("other/a.txt:1:", out)
        self.assertIn("b.txt:1:", out)
        self.assertIn("phi-check: skipped fix/a.txt (listed in .phi-exceptions.txt, 2026-10-29)", out)
        self.assertIn("2 finding(s) in 2 file(s)", out)

    def test_all_listed_is_clean_with_a_note(self):
        self.fixtures()
        self.write(".phi-exceptions.txt", "./fix/a.txt 2026-10-29 why\n")
        rc, out, _ = self.run_cli("fix")
        self.assertEqual(rc, 0)
        self.assertIn("skipped", out)
        self.assertIn("phi-check: clean, 0 file(s)", out)

    def test_explicit_exceptions_file_cwd_and_env(self):
        self.fixtures()
        self.write("elsewhere.txt", "b.txt 2026-10-29 why\n")
        rc, _, _ = self.run_cli("--exceptions", "elsewhere.txt", "b.txt")
        self.assertEqual(rc, 0)
        rc, _, _ = self.run_cli("--cwd", self.d, "--exceptions", "elsewhere.txt", "b.txt", cwd="/")
        self.assertEqual(rc, 0)
        rc, _, _ = self.run_cli("b.txt", env={"PHI_CHECK_EXCEPTIONS": "elsewhere.txt"})
        self.assertEqual(rc, 0)
        self.write(".phi-exceptions.txt", "b.txt 2026-10-29 why\n")
        rc, out, _ = self.run_cli("--cwd", self.d, "b.txt", cwd="/")     # default name via --cwd
        self.assertEqual(rc, 0)

    def test_malformed_lines_are_reported_and_non_zero(self):
        self.write("clean.txt", "fine\n")
        for line in ("onlypath", "p 2026-10-29", "p 2026-13-45 why", "p yesterday why", "p 20261029 why"):
            self.write(".phi-exceptions.txt", "ok.txt 2026-10-29 fine\n" + line + "\n")
            rc, out, _ = self.run_cli("clean.txt")
            self.assertEqual(rc, 1, line)
            self.assertIn(".phi-exceptions.txt:2: malformed exception line", out)

    def test_a_malformed_line_does_not_skip_its_file(self):
        self.write("b.txt", "SSN %s\n" % SSN)
        self.write(".phi-exceptions.txt", "b.txt 2026-13-45 why\n")
        rc, out, _ = self.run_cli("b.txt")
        self.assertEqual(rc, 1)
        self.assertIn("b.txt:1:", out)

    def test_no_exceptions_ignores_the_file(self):
        self.fixtures()
        self.write(".phi-exceptions.txt", "fix/a.txt 2026-10-29 why\nbroken\n")
        rc, out, _ = self.run_cli("--no-exceptions", "fix/a.txt")
        self.assertEqual(rc, 1)
        self.assertIn("fix/a.txt:1:", out)
        self.assertNotIn("malformed", out)
        self.assertNotIn("skipped", out)

    def test_exceptions_in_json(self):
        self.fixtures()
        self.write(".phi-exceptions.txt", "fix/a.txt 2026-10-29 why\n")
        rc, out, _ = self.run_cli("--format", "json", "fix/a.txt")
        data = json.loads(out)
        self.assertEqual((rc, data["clean"]), (0, True))
        self.assertEqual(data["skipped"][0]["path"], "fix/a.txt")

    def test_module_imports_from_elsewhere(self):
        code = ("import sys; sys.path.insert(0, %r); import phi_patterns as p;"
                "print(p.find('SSN 123456789'))" % SRC)
        out = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, cwd="/")
        self.assertIn("Social Security", out.stdout.decode())


if __name__ == "__main__":
    unittest.main(verbosity=1)
