#!/usr/bin/env python3
"""Format v3, identity and permission (SPEC.md, "Format v3"; AOF's aof/tooling/design/register-v3-identity-permission.md,
ruled 2026-11-11): identity attested once by an anchor in an agents register, carried byte for byte
into each register that grants it.

    the register entry      first, an anchor's, naming the agents registers it accepts identity from
    grants                  a carried attestation, by an anchor, from an accepted register, of this principal
    refused                 a forged or foreign attestation, an agent granted as an operator, an anchor's key,
                            a writer with no grant, a v2 entry, a roster
    rekey and revocation    bind with the old key's revocation; a revoke; what was written concurrently
    ungrant                 a principal no longer granted; a grant and an ungrant at once
    a retired anchor        its attestations count only for carriers before its checkpoint (Break 1)
    two formats             a v2 reader refuses every v3 entry

Keys and stores are made fresh in a throwaway folder; no real register is read.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parents[2] / "src"
sys.path[:0] = [str(SRC / "register-engine"), str(SRC / "sign-packet")]
from registerengine import adapters, core  # noqa: E402

FAILED: list[str] = []
PASSED = 0
AGENTS, OTHER_AGENTS, R = "agents-x", "agents-y", "notes-v3"


def check(desc: str, ok: bool, got=None) -> None:
    global PASSED
    if ok:
        PASSED += 1
    else:
        FAILED.append(desc)
        print(f"FAIL: {desc}" + (f"\n  got: {got!r}"[:1200] if got is not None else ""))


def keygen(path: Path) -> str:
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(path)], check=True)
    return core.public_key(path)


class World:
    def __init__(self, tmp: Path):
        self.tmp = tmp
        tmp.mkdir(parents=True, exist_ok=True)
        self.k = {n: tmp / n for n in ("op", "op2", "scribe", "scribe2", "stranger", "lead")}
        self.pub = {n: keygen(p) for n, p in self.k.items()}
        self.anchors = {self.pub["op"]: "operator-1", self.pub["op2"]: "operator-2"}
        self.agents = adapters.DirStore(tmp / "agents")
        self.other_agents = adapters.DirStore(tmp / "other-agents")
        self.r = adapters.DirStore(tmp / "r")

    def add(self, store, who, principal, kind, data, register, anchors=None):
        return adapters.add(store, self.k[who], principal, kind, data, anchors or self.anchors,
                            register=register, kinds={}, fmt=3)

    def attest(self, principal, key, type_="agent", by="op", register=AGENTS, store=None):
        i = self.add(store or self.agents, by, {"op": "operator-1", "op2": "operator-2"}[by], "identity",
                     {"principal": principal, "key": self.pub[key], "type": type_}, register)
        return (store or self.agents).get(i).decode()

    def revocation(self, key, ends=(), by="op"):
        i = self.add(self.agents, by, {"op": "operator-1", "op2": "operator-2"}[by], "identity_revoke",
                     {"key": self.pub[key], "ends": list(ends), "reason": "rotated"}, AGENTS)
        return self.agents.get(i).decode()

    def read(self, anchors=None, fmt=3):
        return core.read(adapters.raws(self.r), anchors or self.anchors, None, R, {}, fmt)

    def code(self, fn) -> str | None:
        try:
            fn()
        except core.Refused as e:
            return e.code
        return None


def review_fixes(tmp: Path) -> None:
    """The 0.2.0 security review's findings, each shown fixed."""
    w = World(tmp)
    w.add(w.r, "op", "operator-1", "register", {"identity_from": [AGENTS]}, R)
    check("F4: a register entry is the first, with no parents",
          w.code(lambda: w.add(w.r, "op2", "operator-2", "register", {"identity_from": [AGENTS]}, R)) == "bad-field")

    # F2: an agent's identity never bound to an operator's grant.
    lead_op = w.attest("lead", "lead", type_="operator")
    w.add(w.r, "op", "operator-1", "grant", {"principal": "lead", "role": "operator", "identity": lead_op}, R)
    lead_as_agent = w.attest("lead", "scribe2", type_="agent")
    check("F2: binding an agent-type identity to an operator's grant is refused (not-operator)",
          w.code(lambda: w.add(w.r, "op", "operator-1", "bind", {"identity": lead_as_agent}, R)) == "not-operator")

    # F5: a re-grant after an ungrant brings back no earlier key.
    s1 = w.attest("scribe", "scribe")
    w.add(w.r, "op", "operator-1", "grant", {"principal": "scribe", "role": "agent", "identity": s1}, R)
    w.add(w.r, "op", "operator-1", "ungrant", {"principal": "scribe"}, R)
    s2 = w.attest("scribe", "stranger")
    w.add(w.r, "op", "operator-1", "grant", {"principal": "scribe", "role": "agent", "identity": s2}, R)
    check("F5: after an ungrant and a re-grant, the new key writes",
          w.code(lambda: w.add(w.r, "stranger", "scribe", "note", {"text": "new"}, R)) is None)
    check("F5: and the key from before the ungrant does not come back (not-granted)",
          w.code(lambda: w.add(w.r, "scribe", "scribe", "note", {"text": "old"}, R)) == "not-granted")

    # F1: an anchor retired in the agents register only, read from R.
    agents_cp = core.sp.parse(s2.encode(), versions=(3,)).id         # a checkpoint in the agents register
    af = tmp / "anchors"
    af.write_text(f"operator-1 {w.pub['op']} until={AGENTS}:{agents_cp}\noperator-2 {w.pub['op2']}\n")
    retired = adapters.load_anchors(af)
    check("anchors file: until=<register>:<id> is a checkpoint for that register alone",
          core.as_anchor(retired[w.pub["op"]]).checkpoint(AGENTS) == agents_cp
          and core.as_anchor(retired[w.pub["op"]]).checkpoint(R) is None)
    led = w.read(anchors=retired)
    check("F1: retired in the agents register, an anchor's grants in R still stand (not cut off everywhere)",
          not led.refused, led.refused)
    later = w.attest("helper", "scribe2")
    rev_raw = core.sp.sign({"v": 3, "reg": AGENTS, "key": w.pub["op2"], "as": "operator-2", "seq": 1, "prev": None,
                            "saw": [], "at": "2026-11-12T10:00:00Z", "kind": "identity_revoke",
                            "data": {"key": w.pub["op"], "ends": [], "reason": "retired"}},
                           w.k["op2"], versions=(3,)).decode()
    check("F1: an anchor's key revoked in R by another anchor needs it retired by this reader",
          w.code(lambda: w.add(w.r, "op2", "operator-2", "revoke", {"revocation": rev_raw}, R)) == "anchor-key")
    w.add(w.r, "op2", "operator-2", "revoke", {"revocation": rev_raw}, R, anchors=retired)
    check("F1: once its revocation is carried into R, its attestations count no more there (bad-carried)",
          w.code(lambda: w.add(w.r, "op2", "operator-2", "grant",
                               {"principal": "helper", "role": "agent", "identity": later}, R, anchors=retired)) == "bad-carried")
    check("F1: and its own entries there are refused (retired-anchor)",
          w.code(lambda: w.add(w.r, "op", "operator-1", "note", {"text": "still me"}, R, anchors=retired)) == "retired-anchor")

    check("guard: an ungrant passes without the guard, a revoke never does",
          adapters.unguarded("ungrant", {"principal": "scribe"}) and not adapters.unguarded("revoke", {"revocation": rev_raw}))


def main() -> int:
    with tempfile.TemporaryDirectory() as t:
        w = World(Path(t))
        scribe_id = w.attest("scribe", "scribe")
        check("agents register: an anchor attests an identity", scribe_id.startswith("{"))
        check("agents register: an attestation is an anchor's alone",
              w.code(lambda: w.add(w.agents, "scribe", "scribe", "identity",
                                   {"principal": "scribe", "key": w.pub["scribe"], "type": "agent"}, AGENTS))
              == "unknown-key")

        # Before the register entry, nothing is granted.
        check("register entry: a grant before it is refused (no-register)",
              w.code(lambda: w.add(w.r, "op", "operator-1", "grant",
                                   {"principal": "scribe", "role": "agent", "identity": scribe_id}, R)) == "no-register")
        check("register entry: only an anchor writes it",
              w.code(lambda: w.add(w.r, "scribe", "scribe", "register", {"identity_from": [AGENTS]}, R)) == "unknown-key")
        w.add(w.r, "op", "operator-1", "register", {"identity_from": [AGENTS]}, R)
        check("register entry: one per register",
              w.code(lambda: w.add(w.r, "op", "operator-1", "register", {"identity_from": [AGENTS]}, R)) == "bad-field")

        # Grants.
        w.add(w.r, "op", "operator-1", "grant", {"principal": "scribe", "role": "agent", "identity": scribe_id}, R)
        note = w.add(w.r, "scribe", "scribe", "note", {"text": "hello"}, R)
        led = w.read()
        check("grant: the granted agent writes, through the carried identity", note in led.valid and not led.refused,
              led.refused)
        check("refused: a key no grant carries (unknown-key)",
              w.code(lambda: w.add(w.r, "stranger", "stranger", "note", {"text": "x"}, R)) == "unknown-key")
        check("refused: an agent may not grant (not-operator)",
              w.code(lambda: w.add(w.r, "scribe", "scribe", "grant",
                                   {"principal": "scribe", "role": "agent", "identity": scribe_id}, R)) == "not-operator")
        forged = w.attest("lead", "lead")
        forged_v = core.sp.parse(forged.encode(), versions=(3,)).value
        by_stranger = core.sp.sign({**forged_v, "key": w.pub["stranger"], "as": "stranger", "seq": 1, "prev": None},
                                   w.k["stranger"], versions=(3,)).decode()
        check("refused: an attestation no anchor signed (bad-carried)",
              w.code(lambda: w.add(w.r, "op", "operator-1", "grant",
                                   {"principal": "lead", "role": "agent", "identity": by_stranger}, R)) == "bad-carried")
        foreign = w.attest("lead", "lead", register=OTHER_AGENTS, store=w.other_agents)
        check("refused: an attestation from an agents register this register does not accept",
              w.code(lambda: w.add(w.r, "op", "operator-1", "grant",
                                   {"principal": "lead", "role": "agent", "identity": foreign}, R)) == "bad-carried")
        check("refused: an identity carried in another principal's grant (wrong-principal)",
              w.code(lambda: w.add(w.r, "op", "operator-1", "grant",
                                   {"principal": "someone", "role": "agent", "identity": forged}, R)) == "wrong-principal")
        check("refused: an agent's identity granted as an operator (not-operator)",
              w.code(lambda: w.add(w.r, "op", "operator-1", "grant",
                                   {"principal": "lead", "role": "operator", "identity": forged}, R)) == "not-operator")
        check("refused: a carried packet above 8 KiB",
              w.code(lambda: w.add(w.r, "op", "operator-1", "grant",
                                   {"principal": "lead", "role": "agent", "identity": forged + " " * 9000}, R)) == "bad-field")
        anchor_attest = core.sp.sign({**forged_v, "data": {"principal": "operator-2", "key": w.pub["op2"], "type": "operator"}},
                                     w.k["op"], versions=(3,)).decode()
        check("refused: an anchor's key is never attested or granted by an entry (anchor-key)",
              w.code(lambda: w.add(w.r, "op", "operator-1", "grant",
                                   {"principal": "operator-2", "role": "operator", "identity": anchor_attest}, R)) == "anchor-key")
        check("refused: a roster is format 2's",
              w.code(lambda: w.add(w.r, "op", "operator-1", "roster",
                                   {"add": [{"key": w.pub["lead"], "as": "lead", "role": "agent"}]}, R)) == "bad-field")

        # A granted operator who is no anchor grants, but never attests.
        lead_op = w.attest("lead", "lead", type_="operator")
        w.add(w.r, "op", "operator-1", "grant", {"principal": "lead", "role": "operator", "identity": lead_op}, R)
        s2 = w.attest("scribe2-agent", "stranger")
        check("a granted operator (no anchor) may grant",
              w.code(lambda: w.add(w.r, "lead", "lead", "grant",
                                   {"principal": "scribe2-agent", "role": "agent", "identity": s2}, R)) is None)
        check("but never attests: an identity is an anchor's alone",
              w.code(lambda: w.add(w.r, "lead", "lead", "identity",
                                   {"principal": "x", "key": w.pub["scribe2"], "type": "agent"}, R)) == "not-operator")

        # Rekey: bind the new key, carrying the old one's revocation, in one entry.
        new_id = w.attest("scribe", "scribe2")
        rev = w.revocation("scribe", ends=[core.sp.parse(scribe_id.encode(), versions=(3,)).id])
        before_rekey = w.read().heads
        w.add(w.r, "op", "operator-1", "bind", {"identity": new_id, "revocation": rev}, R)
        check("rekey: the new key writes", w.code(lambda: w.add(w.r, "scribe2", "scribe", "note", {"text": "new key"}, R)) is None)
        check("rekey: the old key is refused after it (revoked-key)",
              w.code(lambda: w.add(w.r, "scribe", "scribe", "note", {"text": "old key"}, R)) == "revoked-key")
        # The old key writes concurrently with the rekey: valid (it did not see it), and flagged.
        led = w.read()
        last_old = max((e for e in led.valid.values() if e.key == w.pub["scribe"]), key=lambda e: e.seq)
        concurrent = core.sign({"v": 3, "reg": R, "key": w.pub["scribe"], "as": "scribe", "seq": last_old.seq + 1,
                                "prev": last_old.id, "saw": sorted(set(before_rekey) - {last_old.id}),
                                "at": "2026-11-12T10:00:00Z", "kind": "note", "data": {"text": "meanwhile"}},
                               w.k["scribe"], {}, 3)
        w.r.put(core.entry_id(concurrent.split(b"\n", 1)[0]), concurrent)
        led = w.read()
        cid = core.entry_id(concurrent.split(b"\n", 1)[0])
        check("revocation: an entry written concurrently stays valid, flagged concurrent-with-revocation",
              cid in led.valid and "concurrent-with-revocation" in led.flags.get(cid, []), (led.refused.get(cid), led.flags.get(cid)))

        # Ungrant; and a grant and an ungrant at once: the ungrant wins, both flagged.
        heads = w.read().heads
        g2 = w.attest("helper", "scribe2")
        old_again = w.attest("helper", "scribe")
        check("a revoked key is never bound again (revoked-key)",
              w.code(lambda: w.add(w.r, "op", "operator-1", "grant",
                                   {"principal": "helper", "role": "agent", "identity": old_again}, R)) == "revoked-key")
        w.add(w.r, "op", "operator-1", "ungrant", {"principal": "scribe"}, R)
        check("ungrant: the principal no longer writes (not-granted)",
              w.code(lambda: w.add(w.r, "scribe2", "scribe", "note", {"text": "after"}, R)) == "not-granted")
        grant_c = core.sign({"v": 3, "reg": R, "key": w.pub["op2"], "as": "operator-2", "seq": 1, "prev": None,
                             "saw": sorted(heads), "at": "2026-11-12T10:00:00Z", "kind": "grant",
                             "data": {"principal": "scribe", "role": "agent", "identity": new_id}}, w.k["op2"], {}, 3)
        w.r.put(core.entry_id(grant_c.split(b"\n", 1)[0]), grant_c)
        led = w.read()
        gid = core.entry_id(grant_c.split(b"\n", 1)[0])
        uid = next(i for i, e in led.valid.items() if e.kind == "ungrant")
        check("a grant and an ungrant at once: both flagged concurrent-grant",
              "concurrent-grant" in led.flags.get(gid, []) and "concurrent-grant" in led.flags.get(uid, []),
              (led.refused.get(gid), led.flags.get(gid), led.flags.get(uid)))
        check("and the ungrant wins",
              w.code(lambda: w.add(w.r, "scribe2", "scribe", "note", {"text": "still no"}, R)) == "not-granted")

        # Two formats never mix; a v2 reader refuses every v3 entry.
        v2 = adapters.DirStore(w.tmp / "v2")
        adapters.add(v2, w.k["op"], "operator-1", "note", {"text": "v2"}, w.anchors, register=R, kinds={})
        for i in v2.ids():
            w.r.put(i, v2.get(i))
        led = w.read()
        check("one format per register: a v2 entry in a v3 register is refused (bad-version)",
              [c for c, _ in led.refused.values()].count("bad-version") == 1, led.refused)
        led2 = w.read(fmt=2)
        check("a v2 reader refuses every v3 entry, reading only the v2 one",
              len(led2.valid) == 1 and all(c == "bad-version" for c, _ in led2.refused.values()) and led2.refused,
              (len(led2.valid), set(c for c, _ in led2.refused.values())))

        # A retired anchor (Break 1): its attestation counts in a carrier before its checkpoint, never after.
        w2 = World(w.tmp / "retired")
        w2.add(w2.r, "op", "operator-1", "register", {"identity_from": [AGENTS]}, R)
        a_old = w2.attest("scribe", "scribe", by="op")
        early = w2.add(w2.r, "op2", "operator-2", "grant", {"principal": "scribe", "role": "agent", "identity": a_old}, R)
        a_late = w2.attest("lead", "lead", by="op")
        late = w2.add(w2.r, "op2", "operator-2", "grant", {"principal": "lead", "role": "agent", "identity": a_late}, R)
        retired = {w2.pub["op"]: core.Anchor("operator-1", early), w2.pub["op2"]: "operator-2"}
        led = w2.read(anchors=retired)
        check("retired anchor: its attestation counts in a grant up to its checkpoint",
              early in led.valid, led.refused.get(early))
        check("retired anchor: and not in a grant after it (bad-carried)",
              led.refused.get(late, ("",))[0] == "bad-carried", led.refused.get(late))
        review_fixes(w.tmp / "fixes")
    print(f"register-engine v3: {PASSED} passed, {len(FAILED)} failed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
