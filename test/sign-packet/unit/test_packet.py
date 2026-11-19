#!/usr/bin/env python3
"""sign-packet: the packet, its checks, the order, forks and the vouched-absent rule (SPEC.md).

Keys are made fresh in a throwaway folder; no real store is read.
"""
import contextlib
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "src" / "sign-packet"))
import signpacket as sp  # noqa: E402
from signpacket import cli  # noqa: E402

FAILED: list[str] = []
PASSED = 0


def check(desc: str, ok: bool, got=None) -> None:
    global PASSED
    if ok:
        PASSED += 1
    else:
        FAILED.append(desc)
        print(f"FAIL: {desc}" + (f"\n  got: {got!r}"[:700] if got is not None else ""))


def refused(raw: bytes, check_=None) -> str:
    try:
        sp.parse(raw, check_)
        return "valid"
    except sp.Refused as r:
        return r.code


def refused_sign(fn) -> str | None:
    try:
        fn()
    except sp.Refused as e:
        return e.code
    return None


def run_cli(*argv) -> tuple[int, str]:
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = cli.main(list(argv))
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 1
    return code, out.getvalue()


# A stand-in for the phi-check Feature's command, to its documented contract: `-` reads standard
# input; exit 0 clean, 1 on a finding (one line per hit on stdout, never the matched text), 2 on a
# usage error. Its one rule here: something shaped like a US Social Security number.
FAKE_PHI = f"""#!{sys.executable}
import re, sys
if "-" not in sys.argv[1:]:
    print("phi-check: usage: phi-check [options] <path>... (- reads stdin)", file=sys.stderr)
    sys.exit(2)
text = sys.stdin.read()
hits = [n for n, line in enumerate(text.splitlines(), 1) if re.search(r"\\b\\d{{3}}-\\d{{2}}-\\d{{4}}\\b", line)]
for n in hits:
    print(f"packet:{{n}}: us-ssn")
print(f"phi-check: refused, {{len(hits)}} finding(s) in 1 file(s)" if hits else "phi-check: clean, 1 file(s)")
if hits:
    print("phi-check: refused (us-ssn)", file=sys.stderr)
sys.exit(1 if hits else 0)
"""


def write_guard(folder: Path, name: str, text: str) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    f = folder / name
    f.write_text(text)
    f.chmod(0o755)
    return f


def main() -> int:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        keys = {}
        for name in ("a", "b"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(tmp / name)], check=True)
            keys[name] = (tmp / name, sp.public_key(tmp / name))

        def body(who, seq, prev=None, saw=(), at="2026-11-05T10:00:00Z", domain="notes", **data):
            return {"v": 2, "reg": domain, "key": keys[who][1], "as": who, "seq": seq, "prev": prev,
                    "saw": sorted(saw), "at": at, "kind": "note", "data": data}

        def make(who, seq, prev=None, **kw):
            raw = sp.sign(body(who, seq, prev, **kw), keys[who][0])
            return raw, sp.packet_id(raw.split(b"\n", 1)[0])

        # The packet alone.
        a1, a1_id = make("a", 1, text="one")
        p = sp.parse(a1)
        check("packet: its id is the SHA-256 of its body line",
              p.id == hashlib.sha256(a1.split(b"\n", 1)[0]).hexdigest() == a1_id, p.id)
        check("packet: the body is canonical JSON", sp.canonical(p.value) == p.body)
        check("packet: its domain is reg, and a version-1 packet's is ledger",
              p.domain == "notes" and sp.Packet("x", b"", "", {"v": 1}).domain == "ledger")
        check("packet: the signature is good", sp.signature_ok(p))
        body_line, armour = a1.split(b"\n", 1)
        check("format: not UTF-8", refused(b"\xff\n" + armour) == "bad-format")
        check("format: no signature", refused(body_line + b"\n") == "bad-format")
        check("format: a body too large", refused(b'{"a":"' + b"x" * 70000 + b'"}\n' + armour) == "too-large")
        deep = b'{"a":' + b"[" * 30000 + b"]" * 30000 + b"}\n" + armour
        check("format: a body nested too deeply is refused, never a crash", refused(deep) == "bad-format")
        found, ref = sp.collect([a1, deep], "notes")
        check("format: and a store holding one still reads the rest", list(found) == [a1_id] and len(ref) == 1, ref)
        check("format: not canonical", refused(body_line.replace(b",", b", ", 1) + b"\n" + armour) == "not-canonical")
        for what, change, code in (("a version not known", {"v": 4}, "bad-version"),
                                   ("a field missing", {"at": None}, "bad-field"),
                                   ("a float", {"seq": 1.5}, "bad-field"),
                                   ("seq 2 with no prev", {"seq": 2}, "bad-chain"),
                                   ("saw not sorted", {"saw": ["f" * 64, "0" * 64]}, "bad-field")):
            v = {**p.value, **change}
            if change.get("at", 1) is None:
                del v["at"]
            raw = json.dumps(v, sort_keys=True, separators=(",", ":")).encode() + b"\n" + armour
            check(f"fields: {what} is refused ({code})", refused(raw) == code, refused(raw))

        # Version 3 (AOF ADR 0028): version 2's fields, its own namespace, opt-in; a chain never crosses into it.
        V3 = (1, 2, 3)
        v3 = sp.sign({**body("a", 1, domain="notes-v3"), "v": 3}, keys["a"][0], versions=V3)
        p3 = sp.parse(v3, versions=V3)
        check("version 3: a layer that asks for it signs and checks a v3 packet, in the namespace aof-register-v3",
              p3.value["v"] == 3 and p3.namespace == "aof-register-v3" and sp.signature_ok(p3))
        check("version 3: by default it is refused (bad-version), on reading and on signing",
              refused(v3) == "bad-version"
              and refused_sign(lambda: sp.sign({**body("a", 1), "v": 3}, keys["a"][0])) == "bad-version")
        relabelled = json.dumps({**p.value, "v": 3}, sort_keys=True, separators=(",", ":")).encode() + b"\n" + armour
        check("version 3: a version-2 signature never passes as version 3 (another namespace)",
              not sp.signature_ok(sp.parse(relabelled, versions=V3)))
        v3_body, v3_armour = v3.split(b"\n", 1)
        as_v2 = json.dumps({**p3.value, "v": 2}, sort_keys=True, separators=(",", ":")).encode() + b"\n" + v3_armour
        check("version 3: and a version-3 signature never passes as version 2",
              not sp.signature_ok(sp.parse(as_v2)))
        a2v2 = sp.sign(body("a", 2, prev=a1_id, domain="notes", text="two"), keys["a"][0])
        a2v3 = sp.sign({**body("a", 2, prev=a1_id, domain="notes", text="two"), "v": 3}, keys["a"][0], versions=V3)
        g = sp.read([a1, a2v3], "notes", versions=V3)
        check("version 3: a key's chain never continues from version 2 into version 3",
              [c for c, _ in g.refused.values()] == ["bad-chain"] and len(g.valid) == 1, g.refused)
        b1v3 = sp.sign({**body("b", 1, domain="notes"), "v": 3}, keys["b"][0], versions=V3)
        b1v3_id = sp.packet_id(b1v3.split(b"\n", 1)[0])
        b2v2 = sp.sign(body("b", 2, prev=b1v3_id, domain="notes", text="two"), keys["b"][0])
        g = sp.read([b1v3, b2v2], "notes", versions=V3)
        check("version 3: nor from version 3 back into version 2",
              g.refused.get(sp.packet_id(b2v2.split(b"\n", 1)[0]), ("",))[0] == "bad-chain", g.refused)
        g = sp.read([b1v3, b2v2], "notes")
        check("version 3: refused by a v2 reader under its id, so what follows it is refused, not held",
              g.refused.get(b1v3_id, ("",))[0] == "bad-version" and not g.held
              and g.refused.get(sp.packet_id(b2v2.split(b"\n", 1)[0]), ("",))[0] == "refused-parent", (g.refused, g.held))
        check("version 3: and version 2 to version 2 still chains", len(sp.read([a1, a2v2], "notes").valid) == 2)
        legacy = {k: v for k, v in body("a", 1).items() if k != "reg"}
        l1 = sp.sign({**legacy, "v": 1}, keys["a"][0])
        l1_id = sp.packet_id(l1.split(b"\n", 1)[0])
        l2 = sp.sign(body("a", 2, prev=l1_id, domain="ledger", text="two"), keys["a"][0])
        check("version 1 into version 2 still chains", len(sp.read([l1, l2], "ledger").valid) == 2,
              sp.read([l1, l2], "ledger").refused)

        def no_x(v):
            if "x" in v["data"]:
                raise sp.Refused("layer-says-no", "x")
        check("a layer's check runs last, with its own code", refused(make("a", 1, x=1)[0], no_x) == "layer-says-no")
        try:
            sp.sign(body("a", 1), keys["b"][0])
            check("sign: refuses a key that is not the body's", False)
        except ValueError as e:
            check("sign: refuses a key that is not the body's", "not the signing key" in str(e), str(e))

        # Many packets: collect (alone), then order (with ancestors).
        a2, a2_id = make("a", 2, a1_id, at="2026-11-05T10:01:00Z")
        b1, b1_id = make("b", 1, saw=[a2_id], at="2026-11-05T09:00:00Z")    # an earlier clock, a later place
        other, other_id = make("a", 1, domain="elsewhere")
        forged = a2.split(b"\n", 1)[0] + b"\n" + b1.split(b"\n", 1)[1]
        found, ref = sp.collect([b1, a2, a1, a1, other, forged], "notes")
        check("collect: a packet of another domain is refused (wrong-domain)", ref.get(other_id, ("",))[0] == "wrong-domain", ref)
        check("collect: a good copy outweighs a bad one; duplicates count once",
              set(found) == {a1_id, a2_id, b1_id} and a2_id not in ref, (sorted(found), ref))
        found2, ref2 = sp.collect([forged], "notes")
        check("collect: another key's signature on a body is refused (bad-signature)",
              ref2.get(a2_id, ("",))[0] == "bad-signature" and not found2, ref2)
        g = sp.order(found, sp.Graph(refused=ref))
        check("order: parents first, whatever the clock says", g.order == [a1_id, a2_id, b1_id], g.order)
        check("order: the heads are what no packet names", g.heads == [b1_id], g.heads)
        same = sp.read([a1, b1, a2], "notes")
        check("order: the same packets in any order read the same", same.order == g.order)

        held = sp.read([a2, b1], "notes")
        check("held: a packet whose parent is missing waits, and so does what follows it",
              held.held == {a2_id: [a1_id], b1_id: [a2_id]} and not held.valid, held.held)
        bad_chain_raw, bad_chain_id = make("b", 2, a1_id)                  # b's seq 2 naming a's packet as prev
        g2 = sp.read([a1, b1, a2, bad_chain_raw], "notes")
        check("chain: a prev of another key is refused (bad-chain)", g2.refused.get(bad_chain_id, ("",))[0] == "bad-chain", g2.refused)
        child_raw, child_id = make("b", 3, bad_chain_id)
        g3 = sp.read([a1, b1, a2, bad_chain_raw, child_raw], "notes")
        check("parents: a packet after a refused one is refused (refused-parent)",
              g3.refused.get(child_id, ("",))[0] == "refused-parent", g3.refused)

        def b_may_not(e, out):
            if e.principal == "b":
                raise sp.Refused("not-allowed", "b may not write here")
        found, ref = sp.collect([a1, a2, b1], "notes")
        g4 = sp.order(found, sp.Graph(refused=ref), decide=b_may_not)
        check("decide: the layer's check runs once parents and chain are good",
              set(g4.valid) == {a1_id, a2_id} and g4.refused[b1_id][0] == "not-allowed", g4.refused)

        # Forks: one key, one seq, two packets.
        a2b, a2b_id = make("a", 2, a1_id, at="2026-11-05T10:02:00Z", text="the other side")
        g5 = sp.read([a1, a2, a2b, b1], "notes")
        check("forks: both sides stay valid and the fork is found",
              {a2_id, a2b_id} <= set(g5.valid) and sp.forks(g5.valid) == [sorted([a2_id, a2b_id])], sp.forks(g5.valid))
        check("forks: a side left out is no fork", sp.forks(g5.valid, {a2b_id}) == [])

        # Vouched absent.
        g6 = sp.read([a1, b1], "notes", vouched={a2_id})
        check("vouched absent: a packet that saw it is not held for it",
              b1_id in g6.valid and not g6.held and g6.absent == {a2_id}, (g6.held, g6.absent))
        a3, a3_id = make("a", 3, a2_id)
        g7 = sp.read([a1, b1, a3], "notes", vouched={a2_id})
        check("vouched absent: a packet whose prev is absent, not vouched for, is refused",
              g7.refused.get(a3_id, ("",))[0] == "refused-parent", g7.refused)
        g8 = sp.read([a1, b1, a3], "notes", vouched={a2_id, a3_id})
        check("vouched absent: a packet whose prev is absent, vouched for, is absent too",
              a3_id in g8.absent and a3_id not in g8.valid and a3_id not in g8.refused, (g8.absent, g8.refused))
        g9 = sp.read([a1, a2, b1], "notes", vouched={a2_id})
        check("vouched absent: one still here is read as it is, and named as still there",
              a2_id in g9.valid and g9.still_there == {a2_id} and not g9.absent, (g9.still_there, g9.absent))
        g10 = sp.read([b1], "notes")
        check("not vouched: a missing parent is waited for", g10.held == {b1_id: [a2_id]})


        # Guards (SPEC.md, "Guards").
        gdir = tmp / "guards"
        phi = write_guard(gdir, "phi-check", FAKE_PHI)
        chain = sp.Chain.parse(f"{phi} --no-exceptions --stdin-filename packet -; {phi} -")
        check("guard: an option's value is commands separated by ;", len(chain.guards) == 2
              and chain.guards[0].argv[-1] == "-", chain)
        for bad, want in (("phi-check -", "absolute path"), ("relative/phi -", "absolute path"), (" ; ", "names no command")):
            try:
                sp.Chain.parse(bad)
                check(f"guard: {bad!r} is refused ({want})", False)
            except ValueError as e:
                check(f"guard: {bad!r} is refused ({want})", want in str(e), str(e))
        check("guard: an empty option is no guard", not sp.Chain.parse(""))
        try:
            sp.Guard((str(phi), "-"), 301)
            check("guard: a timeout above 300 seconds is refused", False)
        except ValueError:
            check("guard: a timeout above 300 seconds is refused", True)
        ssn = body("a", 1, text="patient 123-45-6789 seen")
        try:
            sp.sign(ssn, keys["a"][0], guard=chain)
            check("guard: egress, a packet the guard refuses is never signed", False)
        except sp.Refused as r:
            check("guard: egress, a packet the guard refuses is never signed",
                  r.code == "guarded" and "exit 1" in r.detail and "123-45-6789" not in r.detail, r.detail)
        check("guard: egress, a clean packet is signed", sp.parse(sp.sign(body("a", 1, text="all well"), keys["a"][0],
                                                                         guard=chain)).data["text"] == "all well")
        check("guard: an empty chain lets everything through", not sp.Chain() and sp.parse(sp.sign(ssn, keys["a"][0], guard=sp.Chain())))
        seen = tmp / "guard-saw"
        dump = write_guard(gdir, "dump", f"#!/bin/sh\nenv > {seen}\ncat >/dev/null\nexit 0\n")
        os_env_secret = "SIGN_PACKET_TEST_TOKEN"
        import os as _os
        _os.environ[os_env_secret] = "synthetic-token-value"
        try:
            sp.Guard((str(dump),)).check(b"{}", "notes", "ingress")
        finally:
            del _os.environ[os_env_secret]
        env_seen = seen.read_text()
        check("guard: it is given a fixed PATH, the domain and the direction, and nothing of the caller's",
              "SIGN_PACKET_GUARD_DOMAIN=notes" in env_seen and "SIGN_PACKET_GUARD_DIRECTION=ingress" in env_seen
              and "PATH=/usr/local/sbin:" in env_seen and "synthetic-token-value" not in env_seen, env_seen)
        check("guard: a Python guard runs with no user site and no script folder on its path",
              "PYTHONNOUSERSITE=1" in env_seen and "PYTHONSAFEPATH=1" in env_seen, env_seen)
        check("guard: a layer's own names never replace PATH", sp.guard.env("d", "egress", (("PATH", "/tmp"),))["PATH"].startswith("/usr/local/sbin"))
        for what, cmd, want in (("no answer in time", write_guard(gdir, "slow", "#!/bin/sh\nsleep 30\n"), "no answer within 1s"),
                                ("a command that cannot run", tmp / "no-such-guard", "could not run"),
                                ("a usage error (exit 2)", phi, "exit 2")):
            argv = (str(cmd),) if cmd != phi else (str(phi),)          # phi without "-": its usage error
            try:
                sp.Guard(argv, 1).check(b"{}", "notes")
                check(f"guard: fails closed on {what}", False)
            except sp.Refused as r:
                failed = isinstance(r, sp.GuardFailed)
                check(f"guard: fails closed on {what}, and says whether it answered about the content",
                      r.code == "guarded" and want in r.detail and failed == (what != "a usage error (exit 2)"), (r.detail, failed))
        # The command.
        store = tmp / "store"
        store.mkdir()
        for raw, i in ((a1, a1_id), (a2, a2_id), (b1, b1_id)):
            (store / f"{i}.entry").write_bytes(raw)
        code, out = run_cli("verify", "--domain", "notes", str(store))
        check("command: verify passes a folder of good packets", code == 0 and "3 valid, 0 refused" in out, out)
        (store / "bad.entry").write_bytes(forged)
        code, out = run_cli("verify", "--domain", "notes", str(store), "--json")
        rows = json.loads(out) if out.strip().startswith("[") else []
        check("command: verify fails on a forged packet and names its file",
              code == 1 and any(r["file"] == "bad.entry" and r["outcome"] == "bad-signature" for r in rows), out)
        code, out = run_cli("verify", "--domain", "elsewhere", str(store / f"{a1_id}.entry"))
        check("command: verify refuses a packet of another domain", code == 1 and "wrong-domain" in out, out)
        code, out = run_cli("version", "--json")
        check("command: version names the format and the library", code == 0 and json.loads(out)["format"] == 2, out)
        os.environ["SIGN_PACKET_HOME"] = str(tmp / "sp-home")          # a throwaway home, never the machine's
        code, out = run_cli("check")
        check("command: check says what is ready, and that the instance id is not settled yet",
              code == 1 and "python" in out and "ssh-keygen" in out and "not settled" in out, out)
        (tmp / "sp-home").mkdir()
        (tmp / "sp-home" / "instance-id").write_text("3f2b9c1e-7a4d-4e8b-9c2a-5d6e7f8a9b0c\n")
        code, out = run_cli("check")
        check("command: check is ready once the instance id is recorded", code == 0 and "3f2b9c1e" in out, out)
        del os.environ["SIGN_PACKET_HOME"]
    print(f"sign-packet: {PASSED} passed, {len(FAILED)} failed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
