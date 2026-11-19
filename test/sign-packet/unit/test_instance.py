#!/usr/bin/env python3
"""The instance id (SPEC.md, "The instance"; the operator's D93): resolved from AOF_INSTANCE_ID,
then OpenBao (dcf-secret), else made here; recorded once; a different value later refused.

A stand-in dcf-secret answers as the openbao Feature's does (its exit codes); no real OpenBao is used.
"""
import contextlib
import io
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "src" / "sign-packet"))
import signpacket as sp  # noqa: E402
from signpacket import cli, instance  # noqa: E402

FAILED: list[str] = []
PASSED = 0
A = "3f2b9c1e-7a4d-4e8b-9c2a-5d6e7f8a9b0c"
B = "91ab0c2d-1111-4222-8333-944455566677"


def check(desc: str, ok: bool, got=None) -> None:
    global PASSED
    if ok:
        PASSED += 1
    else:
        FAILED.append(desc)
        print(f"FAIL: {desc}" + (f"\n  got: {got!r}"[:700] if got is not None else ""))


def fake_dcf_secret(folder: Path, exit_code: int, value: str = "") -> None:
    """A dcf-secret that answers `get instance --field id` with the given exit code (and value)."""
    folder.mkdir(parents=True, exist_ok=True)
    f = folder / "dcf-secret"
    f.write_text(f"#!/bin/sh\n[ \"$1 $2 $3 $4\" = \"get instance --field id\" ] || exit 2\n"
                 f"printf '%s' '{value}'\nexit {exit_code}\n")
    f.chmod(0o755)


@contextlib.contextmanager
def env(**kv):
    old = {k: os.environ.get(k) for k in kv}
    for k, v in kv.items():
        os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
    try:
        yield
    finally:
        for k, v in old.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)


def main() -> int:
    for p, ok in (("scribe", True), (f"scribe@{A}", True), ("scribe@manor", False), (f"scribe@{A.upper()}", False),
                  ("a@b.invalid", False), (f"x@{A}@{B}", False), (f"@{A}", False)):
        check(f"pattern: {p!r} {'is' if ok else 'is not'} a principal", bool(sp.PRINCIPAL_RE.fullmatch(p)) == ok)

    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        bin_dir = tmp / "bin"
        # The machine's own dcf-secret (a real openbao Feature) is never asked: its folders are left out.
        base_path = ":".join(d for d in os.environ["PATH"].split(":") if d and not (Path(d) / "dcf-secret").exists())
        instance.DCF_SECRET = str(bin_dir / "dcf-secret")       # the stand-in, never the machine's own
        clean = {"AOF_INSTANCE_ID": None, "PATH": f"{tmp / 'nothing'}:{base_path}"}

        with env(**{**clean, "AOF_INSTANCE_ID": A}):
            i, where = instance.resolve(tmp / "h1")
        check("source 1: AOF_INSTANCE_ID is taken and recorded",
              (i, where) == (A, "the environment") and (tmp / "h1" / "instance-id").read_text().strip() == A, (i, where))
        with env(**{**clean, "AOF_INSTANCE_ID": B}):
            try:
                instance.resolve(tmp / "h1")
                check("mismatch: another id in the environment later is refused", False)
            except instance.InstanceError as e:
                check("mismatch: another id in the environment later is refused", "never changed" in str(e), str(e))
            try:
                instance.get(tmp / "h1")
                check("mismatch: and a writer's get() refuses it too", False)
            except instance.InstanceError as e:
                check("mismatch: and a writer's get() refuses it too", A in str(e) and B in str(e), str(e))
        with env(**{**clean, "AOF_INSTANCE_ID": "office-2"}):
            try:
                instance.resolve(tmp / "h2")
                check("a malformed id is refused, not recorded", False)
            except instance.InstanceError as e:
                check("a malformed id is refused, not recorded", not (tmp / "h2" / "instance-id").exists(), str(e))

        fake_dcf_secret(bin_dir, 0, B)
        with env(**{**clean, "PATH": f"{bin_dir}:{base_path}"}):
            i, where = instance.resolve(tmp / "h3")
        check("source 2: OpenBao (dcf-secret get instance --field id) when the environment has none",
              (i, where) == (B, "OpenBao"), (i, where))
        fake_dcf_secret(bin_dir, 0, A)
        with env(**{**clean, "PATH": f"{bin_dir}:{base_path}"}):
            try:
                instance.resolve(tmp / "h3")
                check("mismatch: OpenBao naming another id later is refused", False)
            except instance.InstanceError as e:
                check("mismatch: OpenBao naming another id later is refused", "OpenBao" in str(e), str(e))

        for code, what in ((14, "not set"), (11, "sealed"), (10, "unreachable")):
            fake_dcf_secret(bin_dir, code)
            with env(**{**clean, "PATH": f"{bin_dir}:{base_path}"}):
                h = tmp / f"h-{code}"
                i, where = instance.resolve(h)
                again = instance.resolve(h)
            check(f"source 3: OpenBao {what}, so one is made here, and the same one stays",
                  where == "made here" and instance.GUID_RE.fullmatch(i) is not None and again == (i, "recorded"), (i, where, again))
            check(f"OpenBao {what}: it says so", instance.from_openbao()[1] != "", None)
        (bin_dir / "dcf-secret").unlink()
        with env(**clean):
            check("no dcf-secret at all: OpenBao is skipped, and says why",
                  instance.from_openbao() == (None, "no dcf-secret (the openbao Feature is not installed)"))

        fake_dcf_secret(bin_dir, 0, B)
        with env(**{**clean, "AOF_INSTANCE_ID": A, "PATH": f"{bin_dir}:{base_path}"}):
            try:
                instance.resolve(tmp / "h-disagree")
                check("disagreeing sources are refused before anything is recorded", False)
            except instance.InstanceError as e:
                check("disagreeing sources are refused before anything is recorded",
                      "disagree" in str(e) and not (tmp / "h-disagree" / "instance-id").exists(), str(e))
        hs = tmp / "h-symlink"
        hs.mkdir()
        (hs / "instance-id").symlink_to(tmp / "nowhere")
        with env(**{**clean, "AOF_INSTANCE_ID": A}):
            try:
                instance.resolve(hs)
                check("a symlink at the record is refused, never followed or replaced", False)
            except instance.InstanceError as e:
                check("a symlink at the record is refused, never followed or replaced", "symlink" in str(e), str(e))
        with env(**{**clean, "AOF_INSTANCE_ID": "sk-secret-value-put-here-by-mistake"}):
            try:
                instance.resolve(tmp / "h-echo")
                check("a rejected value is never echoed", False)
            except instance.InstanceError as e:
                check("a rejected value is never echoed", "secret" not in str(e) and "characters" in str(e), str(e))
        h = tmp / "race"
        h.mkdir()
        (h / "instance-id").write_text(A + "\n")                     # another process recorded first
        check("two writers at once: the record written first stands", instance._record(h, B) == A)

        with env(**{**clean, "AOF_INSTANCE_ID": None}):
            os.environ["SIGN_PACKET_HOME"] = str(tmp / "cli")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cli.main(["instance", "--quiet"])
            made = out.getvalue().strip()
            check("command: instance --quiet prints the id alone", code == 0 and instance.GUID_RE.fullmatch(made) is not None, made)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = cli.main(["check", "--json"])
            parts = {p["part"]: p for p in json.loads(out.getvalue())}
            check("command: check says the instance is settled", parts["instance"]["ready"] and parts["instance"]["detail"] == made, parts)
            del os.environ["SIGN_PACKET_HOME"]
    print(f"sign-packet instance: {PASSED} passed, {len(FAILED)} failed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
