"""hk_fetch_key (share/bin/lib.sh) and its use in the runner: a back's own key from OpenBao through its AppRole,
against a fake bao and a fake dcf-secret (no server, no Docker). Skipped where bash is missing."""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import unittest
from pathlib import Path

import helpers as h

BIN = h.PYTHON_DIR.parent / "bin"
BASH = shutil.which("bash")
TOKEN = "s.faketoken1234"
SECRET_ID = "fake-secret-id-9876"
KEY = "-----BEGIN FAKE KEY-----\nabc\n-----END FAKE KEY-----\n"

FAKE_BAO = r'''#!/usr/bin/env bash
# fake bao: records its argv and answers `write ... auth/approle/login` and `status`.
printf '%s\n' "$*" >> "$FAKE_DIR/bao.argv"
case "$1" in
  write)
    for a in "$@"; do case "$a" in secret_id=@*) sid="$(cat "${a#secret_id=@}")" ;; esac; done
    [ "${FAKE_SEALED:-}" = 1 ] && { echo "Error: server is sealed" >&2; exit 2; }
    [ "${FAKE_DOWN:-}" = 1 ] && { echo "Error: connection refused" >&2; exit 2; }
    [ "$sid" = "'''+SECRET_ID+r'''" ] || { echo "Error: permission denied" >&2; exit 2; }
    printf '%s' "'''+TOKEN+r'''" ;;
  status) [ "${FAKE_SEALED:-}" = 1 ] && exit 2; [ "${FAKE_DOWN:-}" = 1 ] && exit 1; exit 0 ;;
esac
'''
FAKE_DCF = r'''#!/usr/bin/env bash
# fake dcf-secret: the token must arrive in BAO_TOKEN; the exit code is FAKE_DCF_RC.
printf 'token=%s args=%s\n' "${BAO_TOKEN:-}" "$*" >> "$FAKE_DIR/dcf.seen"
[ "${FAKE_DCF_RC:-0}" = 0 ] || { echo "dcf-secret: the token may not read the name" >&2; exit "$FAKE_DCF_RC"; }
[ "${BAO_TOKEN:-}" = "'''+TOKEN+r'''" ] || { echo "dcf-secret: no valid token" >&2; exit 12; }
printf '%s' "$FAKE_KEY"
'''


def _exe(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@unittest.skipUnless(BASH, "needs bash")
class KeyFetch(h.RepoCase):
    def setUp(self) -> None:
        super().setUp()
        self.fake = self.base / "fake"
        self.fake.mkdir()
        self.tfs = self.base / "tmpfs"
        self.tfs.mkdir()
        self.od = self.base / "openbao-state"
        _exe(self.fake / "bao", FAKE_BAO)
        _exe(self.fake / "dcf-secret", FAKE_DCF)
        self.env = dict(os.environ, PATH=f"{self.fake}:{os.environ['PATH']}", FAKE_DIR=str(self.fake), FAKE_KEY=KEY,
                        DEVHOST_BAO=str(self.fake / "bao"), OPENBAO_STATE_DIR=str(self.od),
                        OPENBAO_FEATURE_DIR=str(self.base / "no-feature"), DEVHOST_KEY_TMPFS=str(self.tfs))

    def role(self, job: str = "scribe", secret_id: str = SECRET_ID) -> None:
        h.write(self.od / "approle" / job / "role_id", "role-id-1")
        h.write(self.od / "approle" / job / "secret_id", secret_id)

    def call(self, script: str, **extra: str) -> subprocess.CompletedProcess:
        env = dict(self.env, **extra)
        return subprocess.run([BASH, "-c", f'source "{BIN / "lib.sh"}"\n{script}'], env=env, capture_output=True, text=True)

    def test_fetches_the_key_to_tmpfs_and_the_token_is_not_in_the_environment(self):
        self.role()
        done = self.call('hk_fetch_key scribe; echo "rc=$?"; echo "file=$HK_KEY_FILE"; cat "$HK_KEY_FILE"; echo @@@; env | grep -c "' + TOKEN + '" || true;'
                         ' stat -c "%a" "$HK_KEY_FILE" "$HK_KEY_DIR"')
        self.assertIn("rc=0", done.stdout, done.stderr)
        file = Path(done.stdout.split("file=")[1].splitlines()[0])
        self.assertEqual(file.parent.parent, self.tfs)
        body, rest = done.stdout.split("@@@\n")
        self.assertIn(KEY.strip(), body)
        self.assertEqual(rest.split(), ["0", "600", "700"])  # the token is in no variable of the shell; modes
        # The ids went to bao as files (@path), never as arguments, and the token only to dcf-secret's environment.
        argv = (self.fake / "bao.argv").read_text(encoding="utf-8")
        self.assertNotIn(SECRET_ID, argv)
        self.assertIn("secret_id=@", argv)
        self.assertIn(f"token={TOKEN} args=get register/scribe --field private_key", (self.fake / "dcf.seen").read_text(encoding="utf-8"))

    def test_no_role_is_a_quiet_skip_that_says_how_to_make_one(self):
        done = self.call('hk_fetch_key scribe; echo "rc=$?"; echo "$HK_KEY_ERR"')
        self.assertIn("rc=1", done.stdout)
        self.assertIn("task devhost:approles:setup", done.stdout)
        self.assertEqual(list(self.tfs.iterdir()), [])

    def test_no_bao_or_no_dcf_secret_is_a_skip(self):
        self.role()
        done = self.call('hk_fetch_key scribe; echo "rc=$?"', PATH="/usr/bin:/bin", DEVHOST_BAO="devhost-test-no-bao")
        self.assertIn("rc=1", done.stdout)

    def test_a_sealed_server_unreachable_server_and_refused_login_each_name_their_fix(self):
        self.role()
        sealed = self.call('hk_fetch_key scribe; echo "rc=$? $HK_KEY_RC $HK_KEY_ERR"', FAKE_SEALED="1")
        self.assertIn("rc=2 11 OpenBao is sealed: the Operator runs task openbao:unseal", sealed.stdout)
        down = self.call('hk_fetch_key scribe; echo "rc=$? $HK_KEY_RC $HK_KEY_ERR"', FAKE_DOWN="1", FAKE_SEALED="0")
        self.assertIn("rc=2 10 OpenBao is unreachable", down.stdout)
        self.role(secret_id="a-stale-secret-id")
        refused = self.call('hk_fetch_key scribe; echo "rc=$? $HK_KEY_RC $HK_KEY_ERR"')
        self.assertIn("rc=2 12 the AppRole login of the scribe back was refused", refused.stdout)

    def test_a_denied_read_returns_the_dcf_secret_line_and_leaves_no_key_file(self):
        self.role()
        done = self.call('hk_fetch_key scribe; echo "rc=$? $HK_KEY_RC $HK_KEY_ERR"; ls "$HK_KEY_DIR"', FAKE_DCF_RC="13")
        self.assertIn("rc=2 13 dcf-secret: the token may not read the name", done.stdout)
        self.assertEqual(done.stdout.splitlines()[-1], "rc=2 13 dcf-secret: the token may not read the name")  # ls printed nothing

    # ---- the runner ----------------------------------------------------------------------------------------------

    def run_job(self, job_text: str, **extra: str) -> subprocess.CompletedProcess:
        job = self.base / "job.sh"
        h.write(job, job_text)
        transcript = self.base / "t.jsonl"
        h.write_jsonl(transcript, [h.user()])
        env = dict(self.env, DEVHOST_ROOT=str(self.root), DEVHOST_STATE=str(self.base / "state"),
                   DEVHOST_CONTAINER_MARKERS=str(self.base), DEVHOST_JOB_QUIET_SECS="0", **extra)
        env.pop("DEVHOST_JOB_CHILD", None)
        hook = json.dumps({"session_id": "s1", "transcript_path": str(transcript), "cwd": str(self.root), "hook_event_name": "Stop"})
        return subprocess.run([BASH, str(BIN / "run-job.sh"), str(job)], input=hook, env=env, capture_output=True, text=True)

    JOB = ('JOB_NAME=scribe\nJOB_MIN_CHARS=0\n%s\njob_run() {\n  echo "ran" >> "%s"\n'
           '  { printf "key=%%s\\n" "$(cat "$JOB_KEY_FILE" 2>/dev/null)"; env | grep -c "' + TOKEN + '" || true; stat -c %%a "$JOB_KEY_FILE" 2>/dev/null; echo "dir=$(dirname "$JOB_KEY_FILE")"; } >> "%s"\n'
           '  JOB_STATUS=nothing\n}\n')

    def test_runner_gives_the_job_the_key_file_not_the_token_and_removes_it(self):
        self.role()
        seen = self.base / "seen"
        done = self.run_job(self.JOB % ("", self.base / "marker", seen))
        self.assertEqual(done.returncode, 0, done.stderr)
        text = (self.base / "seen").read_text(encoding="utf-8")
        self.assertIn(KEY.splitlines()[1], text)
        self.assertIn("\n0\n", text)  # the token is not in the job's environment
        key_dir = Path(text.split("dir=")[1].strip())
        self.assertFalse(key_dir.exists(), "the key folder is removed when the runner exits")
        self.assertEqual(list(self.tfs.iterdir()), [])
        self.assertTrue((self.base / "state" / "scribe" / "offsets" / "s1").exists(), "a run that worked marks its stretch read")

    def test_runner_runs_a_job_without_a_role_as_before(self):
        done = self.run_job(self.JOB % ("", self.base / "marker", self.base / "seen"))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue((self.base / "marker").exists())
        self.assertIn("key=\n", (self.base / "seen").read_text(encoding="utf-8"))
        self.assertEqual(done.stderr, "")

    def test_runner_a_job_that_needs_its_key_does_not_run_and_is_not_marked_read_when_sealed(self):
        self.role()
        done = self.run_job(self.JOB % ("JOB_NEEDS_KEY=1", self.base / "marker", self.base / "seen"), FAKE_SEALED="1")
        self.assertEqual(done.returncode, 1)
        self.assertIn("needs its OpenBao key and could not get it: OpenBao is sealed: the Operator runs task openbao:unseal", done.stderr)
        self.assertFalse((self.base / "marker").exists(), "job_run did not run")
        self.assertFalse((self.base / "state" / "scribe" / "offsets" / "s1").exists(), "the stretch is not marked read")
        self.assertIn("key not fetched", (self.base / "state" / "scribe" / "job.log").read_text(encoding="utf-8"))
        self.assertIn('"status": "error"', (self.base / "state" / "runs.jsonl").read_text(encoding="utf-8"))
        self.assertEqual(list(self.tfs.iterdir()), [])

    def test_runner_a_job_that_needs_its_key_and_has_no_role_says_how_to_make_one(self):
        done = self.run_job(self.JOB % ("JOB_NEEDS_KEY=1", self.base / "marker", self.base / "seen"))
        self.assertEqual(done.returncode, 1)
        self.assertIn("task devhost:approles:setup", done.stderr)


if __name__ == "__main__":
    unittest.main()
