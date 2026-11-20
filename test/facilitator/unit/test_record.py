"""The record: every message a sign-packet packet signed with its writer's key, in a register-engine
register of the conversation type; and `facilitator verify`: a good chain verifies, and a tampered
packet, a wrong signer and a broken reply_to each fail it."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import helpers  # noqa: E402

import os  # noqa: E402
import stat  # noqa: E402
import subprocess  # noqa: E402

from fake_mcp import facilitator_argv  # noqa: E402


def jester_flow(e):
    fac = e.register_all()
    for h in ("jester", "domain-expert-one"):
        fac.state.seen(h)
    r = fac.send("you", "@jester tell @domain-expert-one a joke")
    j, d = e.session(fac, "jester"), e.session(fac, "domain-expert-one")
    j.receive(0)
    j.reply("@domain-expert-one Why did the packet cross the network? To get signed.")
    d.receive(0)
    d.reply("Ha. Old, but good.")
    j.receive(0)
    j.reply("Thanks.", to=["you"])
    return fac, r["conversation"]


def verify(fac, conv, message=None):
    from facilitator.verify import verify as v
    fac._record = None                      # a fresh reader: every signature checked again
    return v(fac, conv, message)


def test_good_chain_verifies_and_each_packet_is_its_writers():
    e = helpers.Env()
    try:
        fac, conv = jester_flow(e)
        r = verify(fac, conv)
        assert r["ok"], r["problems"]
        assert r["messages"] == 4
        led, proj, _ = fac.record.read(conv)
        for mid in proj["order"]:
            m = proj["messages"][mid]
            assert led.valid[m["entry"]].key == fac.signer.public(m["from"]), m["from"]
        kinds = sorted({led.valid[i].kind for i in led.valid})
        assert kinds == ["message", "roster", "route", "status", "thread"], kinds
        last = proj["messages"][proj["order"][-1]]
        assert last["refs"][-1] == {"thread": conv, "message_id": proj["order"][0]}   # the root, as the last ref
        assert r["chains"][proj["order"][-1]][-1].split()[0] == f"{conv}/{proj['order'][0]}"
    finally:
        e.close()


def test_tampered_packet_fails():
    e = helpers.Env()
    try:
        fac, conv = jester_flow(e)
        _, proj, _ = fac.record.read(conv)
        entry = proj["messages"][proj["order"][1]]["entry"]
        f = e.home / "conversations" / conv / f"{entry}.entry"
        raw = f.read_bytes()
        os.chmod(f, 0o644)
        f.write_bytes(raw.replace(b"To get signed.", b"To get forged."))
        r = verify(fac, conv)
        assert not r["ok"]
        assert any("bad-signature" in p or "held" in p for p in r["problems"]), r["problems"]
    finally:
        e.close()


def test_wrong_signer_fails():
    e = helpers.Env()
    try:
        fac, conv = jester_flow(e)
        from registerengine import adapters, core
        led, proj, _ = fac.record.read(conv)
        jkey = fac.signer.public("jester")
        mine = sorted((x for x in led.valid.values() if x.key == jkey), key=lambda x: x.seq)
        last = proj["order"][-1]
        value = {"v": 2, "reg": conv, "key": jkey, "as": "domain-expert-one", "seq": mine[-1].seq + 1,
                 "prev": mine[-1].id, "saw": sorted(h for h in led.heads if h != mine[-1].id), "at": adapters.now(),
                 "kind": "message", "data": {"thread": conv, "message_id": "m-forged000001",
                                             "parts": [{"kind": "text", "text": "I, the expert, say so"}],
                                             "root": proj["order"][0], "hops": 4, "reply_to": last,
                                             "refs": [{"thread": conv, "message_id": proj["order"][0]}]}}
        raw = core.sign(value, e.home / "keys" / "jester", fac.record.kinds)
        adapters.DirStore(e.home / "conversations" / conv).put(core.entry_id(raw.split(b"\n", 1)[0]), raw)
        r = verify(fac, conv)
        assert not r["ok"]
        assert any("wrong-principal" in p for p in r["problems"]), r["problems"]
    finally:
        e.close()


def test_broken_reply_to_fails():
    e = helpers.Env()
    try:
        fac, conv = jester_flow(e)
        _, proj, _ = fac.record.read(conv)
        fac.record.add(conv, "jester", "message", {"thread": conv, "message_id": "m-orphan000001",
                                                   "parts": [{"kind": "text", "text": "an answer to nothing"}],
                                                   "root": proj["order"][0], "hops": 1, "reply_to": "m-doesnotexist",
                                                   "refs": [{"thread": conv, "message_id": proj["order"][0]}]})
        r = verify(fac, conv, "m-orphan000001")
        assert not r["ok"]
        assert any("does not exist" in p for p in r["problems"]), r["problems"]
        assert any("unknown-message" in p for p in r["problems"]), r["problems"]
    finally:
        e.close()


def test_verify_command_exit_codes():
    e = helpers.Env()
    try:
        fac, conv = jester_flow(e)
        argv = facilitator_argv()
        ok = subprocess.run(argv + ["verify", "--conv", conv], capture_output=True, text=True, env=os.environ)
        assert ok.returncode == 0, ok.stdout + ok.stderr
        assert "every chain verifies back to a human" in ok.stdout
        bad = subprocess.run(argv + ["verify", "--conv", "c-00000000"], capture_output=True, text=True, env=os.environ)
        assert bad.returncode == 1, bad.stdout
        usage = subprocess.run(argv + ["verify"], capture_output=True, text=True, env=os.environ)
        assert usage.returncode == 2
    finally:
        e.close()


def test_fallback_keys_and_tokens_are_private():
    e = helpers.Env()
    try:
        e.register_all().record.facilitator_key()
        for f in ("keys/jester", "keys/you", "keys/facilitator", "tokens/jester", "tokens/you", "keys/FALLBACK"):
            mode = stat.S_IMODE(os.stat(e.home / f).st_mode)
            assert mode == 0o600, (f, oct(mode))
        assert "0.1.0 fallback" in (e.home / "keys" / "FALLBACK").read_text()
        assert not (e.home / "tokens" / "facilitator").exists()   # a person has a token since 0.2.0; the facilitator none
    finally:
        e.close()


if __name__ == "__main__":
    helpers.run_tests(globals())
