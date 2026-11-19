#!/usr/bin/env python3
"""packet-relay: reliable, ordered, exactly-once and signed delivery through a shared folder
(SPEC.md; AOF ADR 0024, decision 3). Two parties, three, a party away, a lossy folder, a slow sync
between two machines' copies of the folder, forged and misplaced files, a fork, a gap lost for
good, a lost state, a folder without hard links, and the command.

Keys are made fresh in a throwaway folder; no real folder or key is read.
"""
import contextlib
import errno
import io
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "src" / "packet-relay"))
from packetrelay import Relay, RelayError, cli, load_keys, relay as relay_mod  # noqa: E402
from packetrelay.relay import sp  # noqa: E402

FAILED: list[str] = []
PASSED = 0


def check(desc: str, ok: bool, got=None) -> None:
    global PASSED
    if ok:
        PASSED += 1
    else:
        FAILED.append(desc)
        print(f"FAIL: {desc}" + (f"\n  got: {got!r}"[:900] if got is not None else ""))


class World:
    """Parties with fresh keys, each with its own home; one shared folder unless a test makes more."""

    def __init__(self, tmp: Path, parties=("alice", "bob"), operators=("op",)):
        self.tmp = tmp
        self.keys = {}
        for p in (*parties, *operators):
            k = tmp / "keys" / p
            k.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(k)], check=True)
            self.keys[p] = k
        self.members = {p: sp.public_key(self.keys[p]) for p in parties}
        self.anchors = {p: sp.public_key(self.keys[p]) for p in operators}
        self.root = tmp / "shared"
        self.root.mkdir()

    def relay(self, who: str, root: Path | None = None, home: str | None = None, members=None) -> Relay:
        return Relay(root or self.root, "talk", who, self.keys[who], members or self.members,
                     self.tmp / "homes" / (home or who), self.anchors)


def files(folder: Path) -> list[Path]:
    return sorted(folder.glob("*.entry")) if folder.is_dir() else []


def texts(rep) -> list[str]:
    return [d["data"].get("text") for d in rep.delivered]


def two_parties(tmp: Path) -> None:
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    ids = [alice.send("note", {"text": t}) for t in ("one", "two", "three")]
    mine = w.root / "talk" / "alice" / "packets"
    check("send: each packet is written once into the sender's own folder", len(files(mine)) == 3
          and {f.stem for f in files(mine)} == set(ids), files(mine))
    rep = bob.sync()
    check("sync: the receiver takes them in the sender's order", texts(rep) == ["one", "two", "three"]
          and [d["seq"] for d in rep.delivered] == [1, 2, 3], rep.delivered)
    inbox = sorted((tmp / "homes" / "bob" / "talk" / "bob" / "inbox" / "alice").glob("*.entry"))
    check("sync: what is taken is in the inbox, named by seq, the packet's own bytes",
          len(inbox) == 3 and inbox[0].read_bytes() == (mine / f"{ids[0]}.entry").read_bytes(), inbox)
    check("sync: and is acknowledged, one signed ack in the receiver's own folder",
          rep.ack_written and len(files(w.root / "talk" / "bob" / "acks")) == 1)
    rep = bob.sync()
    check("exactly once: a second sync takes nothing again", rep.delivered == [] and not rep.ack_written, rep.delivered)
    shutil.copy(mine / f"{ids[1]}.entry", mine / f"{ids[1]} (conflicted copy).entry")   # a sync tool's second copy
    rep = bob.sync()
    check("exactly once: a second copy of a packet under another name is the same packet", rep.delivered == [], rep.delivered)
    (mine / f"{ids[1]} (conflicted copy).entry").unlink()
    rep = alice.sync()
    check("removal: once every party has taken them, the sender removes its packets", rep.removed == 3
          and files(mine) == [] and rep.acked == {"bob": 3}, rep.as_dict())
    check("removal: and its outbox is empty", alice.status()["outbox"] == 0)
    rep = bob.sync()
    check("removal: the receiver loses nothing when the sender's files go", rep.delivered == [] and not rep.waiting)


def instance_parties(tmp: Path) -> None:
    """Parties with an instance (`relay@<GUID>`, D85, D93): a field name cannot hold one, so an
    acknowledgement lists what it took (0.3.0); the 0.2 map is still read."""
    a, b = "relay@3f2b9c1e-7a4d-4e8b-9c2a-5d6e7f8a9b0c", "relay@91ab0c2d-1111-4222-8333-944455566677"
    w = World(tmp, parties=(a, b))
    ra, rb = w.relay(a), w.relay(b)
    ids = [ra.send("note", {"text": t}) for t in ("one", "two")]
    rep = rb.sync()
    check("instance parties: taken in order and acknowledged", texts(rep) == ["one", "two"] and rep.ack_written, rep.as_dict())
    ack = sp.parse(files(w.root / "talk" / b / "acks")[0].read_bytes())
    check("instance parties: the acknowledgement is a list naming the sender in `from`",
          ack.data == {"taken": [{"from": a, "seq": 2, "id": ids[1], "key": w.members[a]}]}, ack.data)
    rep = ra.sync()
    check("instance parties: and the sender removes what was taken", rep.removed == 2 and rep.acked == {b: 2}, rep.as_dict())

    w2 = World(tmp / "old")
    alice = w2.relay("alice")
    ids = [alice.send("note", {"text": t}) for t in ("p", "q")]
    old = sp.sign({"v": 2, "reg": "talk-ack", "key": w2.members["bob"], "as": "bob", "seq": 1, "prev": None,
                   "saw": [], "at": "2026-11-05T10:00:00Z", "kind": "ack",
                   "data": {"upto": {"alice": {"seq": 2, "id": ids[1], "key": w2.members["alice"]}}}}, w2.keys["bob"])
    acks = w2.root / "talk" / "bob" / "acks"
    acks.mkdir(parents=True, exist_ok=True)
    (acks / (sp.packet_id(old.split(b"\n", 1)[0]) + ".entry")).write_bytes(old)
    rep = alice.sync()
    check("old acknowledgement: a 0.2 party's map (`upto`) still counts", rep.removed == 2 and rep.acked == {"bob": 2}, rep.as_dict())


def version_three(tmp: Path) -> None:
    """A party's packet in format version 3 (sign-packet 0.5.0 knows it, opt-in): the relay's rules
    are version 2's, so it is never delivered; the refusal is said (the security review of 0.5.0, F2)."""
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    alice.send("note", {"text": "one"})
    first = sp.parse(files(w.root / "talk" / "alice" / "packets")[0].read_bytes())
    v3 = sp.sign({**first.value, "v": 3, "seq": 2, "prev": first.id, "data": {"text": "two"}}, w.keys["alice"],
                 versions=(1, 2, 3))
    (w.root / "talk" / "alice" / "packets" / (sp.packet_id(v3.split(b"\n", 1)[0]) + ".entry")).write_bytes(v3)
    rep = bob.sync()
    check("version 3: a relay never delivers a v3 packet, and says it refused one",
          texts(rep) == ["one"] and any(r["code"] == "bad-version" for r in rep.refused), rep.as_dict())


def lossy(tmp: Path) -> None:
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    ids = [alice.send("note", {"text": f"n{n}"}) for n in range(1, 5)]
    mine = w.root / "talk" / "alice" / "packets"
    (mine / f"{ids[1]}.entry").unlink()                                  # the folder lost #2
    rep = bob.sync()
    check("gap: the receiver takes what comes before it", texts(rep) == ["n1"], texts(rep))
    check("gap: and waits for the missing one, naming its id from the next packet's prev",
          rep.waiting == {"alice": {"next": 2, "have": [3, 4], "missing_id": ids[1]}}, rep.waiting)
    rep = alice.sync()
    check("resend: the sender sees #2 not taken and writes the same file again",
          rep.resent == 1 and (mine / f"{ids[1]}.entry").is_file() and rep.acked == {"bob": 1}, rep.as_dict())
    check("resend: and removes only what was taken", rep.removed == 1 and len(files(mine)) == 3, files(mine))
    rep = bob.sync()
    check("gap: once it is back, the rest is taken in order", texts(rep) == ["n2", "n3", "n4"] and not rep.waiting, texts(rep))
    (w.root / "talk" / "bob" / "acks").joinpath("x").write_text("")      # noise in the folder is no ack
    for f in files(w.root / "talk" / "bob" / "acks"):
        f.unlink()                                                       # the folder lost bob's ack
    rep = alice.sync()
    check("lost ack: the sender keeps its packets, it does not guess", rep.removed == 0 and rep.acked == {"bob": 0}, rep.as_dict())
    rep = bob.sync()
    check("lost ack: the receiver writes it again", rep.ack_written and rep.delivered == [], rep.as_dict())
    rep = alice.sync()
    check("lost ack: then the sender removes", rep.removed == 3 and files(mine) == [], rep.as_dict())


def party_away(tmp: Path) -> None:
    w = World(tmp, parties=("alice", "bob", "carol"))
    alice, bob, carol = w.relay("alice"), w.relay("bob"), w.relay("carol")
    for t in ("a", "b"):
        alice.send("note", {"text": t})
    bob.sync()
    rep = alice.sync()
    mine = w.root / "talk" / "alice" / "packets"
    check("away: a party that has not taken them holds the sender's packets",
          rep.removed == 0 and len(files(mine)) == 2 and rep.acked == {"bob": 2, "carol": 0}, rep.as_dict())
    bob.send("note", {"text": "from bob"})
    rep = carol.sync()
    check("away: back again, it takes everything, each sender in order",
          [(d["from"], d["data"]["text"]) for d in rep.delivered] == [("alice", "a"), ("alice", "b"), ("bob", "from bob")],
          rep.delivered)
    rep = alice.sync()
    check("away: then the sender removes", rep.removed == 2 and files(mine) == [], rep.as_dict())
    rep = alice.sync()
    check("away: and takes bob's in the same rounds", rep.delivered == [] and alice.status()["taken"]["bob"]["seq"] == 1)


def replicate(src: Path, dst: Path, party: str, rng: random.Random, p: float) -> None:
    """A slow, partial sync of one party's subfolders from one machine's copy to another's: each
    new file and each removal goes across with probability p in a round."""
    for sub in ("packets", "acks"):
        s, d = src / "talk" / party / sub, dst / "talk" / party / sub
        d.mkdir(parents=True, exist_ok=True)
        for f in files(s):
            if not (d / f.name).exists() and rng.random() < p:
                shutil.copy(f, d / f.name)
        for f in files(d):
            if not (s / f.name).exists() and rng.random() < p:
                f.unlink()


def slow_sync(tmp: Path) -> None:
    w = World(tmp)
    a_root, b_root = tmp / "machine-a", tmp / "machine-b"
    a_root.mkdir()
    b_root.mkdir()
    alice, bob = w.relay("alice", root=a_root), w.relay("bob", root=b_root)
    rng = random.Random(24)
    sent = []
    taken = []
    for rnd in range(60):
        if rnd < 20 and rnd % 2 == 0:
            sent.append(f"m{len(sent) + 1}")
            alice.send("note", {"text": sent[-1]})
        replicate(a_root, b_root, "alice", rng, 0.4)
        replicate(b_root, a_root, "bob", rng, 0.4)
        taken += texts(bob.sync())
        alice.sync()
    check("slow sync: every packet arrives, once, in order, through a slow and partial copy",
          taken == sent and len(sent) == 10, (sent, taken))
    check("slow sync: and once every copy has caught up, the sender's folder is empty",
          files(a_root / "talk" / "alice" / "packets") == [] and alice.status()["outbox"] == 0,
          (files(a_root / "talk" / "alice" / "packets"), alice.status()))


def forged(tmp: Path) -> None:
    w = World(tmp, parties=("alice", "bob"), operators=("op",))
    alice, bob = w.relay("alice"), w.relay("bob")
    alice.send("note", {"text": "real"})
    outsider_key = w.keys["op"]                                     # a key that is no party
    stranger = {"v": 2, "reg": "talk", "key": sp.public_key(outsider_key), "as": "alice", "seq": 2,
                "prev": None, "saw": [], "at": "2026-11-05T10:00:00Z", "kind": "note", "data": {"text": "forged"}}
    stranger["seq"], stranger["prev"] = 1, None
    raw = sp.sign(stranger, outsider_key)
    mine = w.root / "talk" / "alice" / "packets"
    (mine / "1111111111111111111111111111111111111111111111111111111111111111.entry").write_bytes(raw)
    bob_raw = sp.sign({**stranger, "key": w.members["bob"], "as": "bob"}, w.keys["bob"])
    (mine / "2222222222222222222222222222222222222222222222222222222222222222.entry").write_bytes(bob_raw)                 # bob's own packet, in alice's folder
    real = next(f for f in files(mine) if f.name not in ("1111111111111111111111111111111111111111111111111111111111111111.entry", "2222222222222222222222222222222222222222222222222222222222222222.entry"))
    tampered = real.read_bytes().replace(b'"real"', b'"fake"')
    (mine / "3333333333333333333333333333333333333333333333333333333333333333.entry").write_bytes(tampered)
    rep = bob.sync()
    codes = sorted({(Path(r["file"]).name, r["code"]) for r in rep.refused})
    check("forged: only the party's own key, in its own folder, is taken", texts(rep) == ["real"], texts(rep))
    check("forged: another key, a misplaced packet and a changed body are refused, each named",
          ("1111111111111111111111111111111111111111111111111111111111111111.entry", "not-this-party") in codes and ("2222222222222222222222222222222222222222222222222222222222222222.entry", "not-this-party") in codes
          and ("3333333333333333333333333333333333333333333333333333333333333333.entry", "bad-signature") in codes, codes)
    fake_ack = sp.sign({"v": 2, "reg": "talk-ack", "key": sp.public_key(outsider_key), "as": "bob", "seq": 99,
                        "prev": "0" * 64, "saw": [], "at": "2026-11-05T10:00:00Z", "kind": "ack",
                        "data": {"upto": {"alice": 99}}}, outsider_key)
    acks = w.root / "talk" / "bob" / "acks"
    (acks / "4444444444444444444444444444444444444444444444444444444444444444.entry").write_bytes(fake_ack)
    for f in [f for f in files(acks) if f.name != "4444444444444444444444444444444444444444444444444444444444444444.entry"]:
        f.unlink()                                                   # only the forged ack is left
    rep = alice.sync()
    check("forged ack: an ack another key signed never makes the sender remove", rep.removed == 0
          and rep.acked == {"bob": 0} and any(r["code"] == "not-this-party" for r in rep.refused), rep.as_dict())


def fork(tmp: Path) -> None:
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    alice.send("note", {"text": "first"})
    shutil.copytree(tmp / "homes" / "alice", tmp / "homes" / "alice-copy")   # one key on two machines
    twin = w.relay("alice", home="alice-copy")
    alice.send("note", {"text": "this side"})
    twin.send("note", {"text": "that side"})
    rep = bob.sync()
    check("fork: one key, two packets at one seq: neither is taken, and the fork is named",
          texts(rep) == ["first"] and len(rep.forks.get("alice", {}).get("ids", [])) == 2, rep.as_dict())


def lost_for_good(tmp: Path) -> None:
    w = World(tmp, parties=("alice", "bob", "carol"))
    alice, bob = w.relay("alice"), w.relay("bob")
    ids = [alice.send("note", {"text": t}) for t in ("x", "y", "z")]
    mine = w.root / "talk" / "alice" / "packets"
    (mine / f"{ids[1]}.entry").unlink()
    for f in (tmp / "homes" / "alice" / "talk" / "alice" / "outbox").glob(f"*-{ids[1]}.entry"):
        f.unlink()                                                   # the sender lost it too
    alice.sync()
    rep = bob.sync()
    check("lost: the receiver waits at the gap", texts(rep) == ["x"] and rep.waiting["alice"]["missing_id"] == ids[1], rep.as_dict())
    try:
        w.relay("bob").skip("alice", 2, 2, ids[1])
        check("skip: a party that is no operator may not vouch", False)
    except RelayError as e:
        check("skip: a party that is no operator may not vouch", "only an operator" in str(e), str(e))
    op = Relay(w.root, "talk", "op", w.keys["op"], w.members, tmp / "homes" / "op", w.anchors)
    op.skip("alice", 2, 2, "f" * 64)                                    # a vouch for an id that is not the gap's
    rep = bob.sync()
    check("skip: a vouch whose id is not the next packet's prev skips nothing", rep.delivered == [] and "alice" in rep.waiting,
          rep.as_dict())
    op.skip("alice", 2, 2, ids[1])
    rep = bob.sync()
    check("skip: an operator's vouch for the gap lets the receiver go on, and says so",
          texts(rep) == ["z"] and rep.skipped == [{"from": "alice", "first": 2, "through": 2, "id": ids[1], "by": "op"}], rep.as_dict())
    carol = Relay(w.root, "talk", "carol", w.keys["carol"], w.members, tmp / "homes" / "carol", {})   # trusts no operator
    rep = carol.sync()
    check("skip: a reader that does not trust the operator does not skip", texts(rep) == ["x"] and "alice" in rep.waiting,
          rep.as_dict())


def state_lost(tmp: Path) -> None:
    w = World(tmp)
    alice = w.relay("alice")
    alice.send("note", {"text": "before"})
    shutil.rmtree(tmp / "homes" / "alice")
    try:
        w.relay("alice").send("note", {"text": "after"})
        check("lost state: sending again from seq 1 is refused (it would fork the chain)", False)
    except RelayError as e:
        check("lost state: sending again from seq 1 is refused (it would fork the chain)", "state was lost" in str(e), str(e))


def no_hard_links(tmp: Path) -> None:
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    real = os.link

    def no_link(*a, **k):
        raise OSError(errno.EPERM, "Operation not permitted")
    relay_mod.os.link = no_link
    try:
        alice.send("note", {"text": "on a cloud folder"})
        rep = bob.sync()
    finally:
        relay_mod.os.link = real
    check("no hard links: packets and acks are written by an exclusive create instead",
          texts(rep) == ["on a cloud folder"] and rep.ack_written, rep.as_dict())


def bad_config(tmp: Path) -> None:
    w = World(tmp)
    for what, kw, want in (("a key that is not the party's", {"who": "alice", "key": "bob"}, "not alice's key"),
                           ("a stranger", {"who": "zed", "key": "alice"}, "neither the members file")):
        try:
            Relay(w.root, "talk", kw["who"], w.keys[kw["key"]], w.members, tmp / "h", w.anchors)
            check(f"config: {what} is refused", False)
        except RelayError as e:
            check(f"config: {what} is refused", want in str(e), str(e))
    try:
        Relay(w.root, "x" * 60, "alice", w.keys["alice"], w.members, tmp / "h", w.anchors)
        check("config: a domain too long for its -ack and -skip domains is refused", False)
    except RelayError as e:
        check("config: a domain too long for its -ack and -skip domains is refused", "at most" in str(e), str(e))


def symlinks(tmp: Path) -> None:
    """F1: a symlink in the shared folder is refused, never followed: not for writes, not for removals."""
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    alice.send("note", {"text": "hello"})
    bob.sync()
    decoy = tmp / "decoy"                                            # a store of <id>.entry files elsewhere
    decoy.mkdir()
    for n in range(3):
        (decoy / f"{n:064x}.entry").write_text("a store's entry")
    acks = w.root / "talk" / "bob" / "acks"
    shutil.rmtree(acks)
    acks.symlink_to(decoy)
    alice.send("note", {"text": "more"})
    try:
        bob.sync()
        check("symlink: a symlinked folder of one's own is refused", False)
    except RelayError as e:
        check("symlink: a symlinked folder of one's own is refused", "not a plain folder" in str(e), str(e))
    check("symlink: and nothing behind it is written or removed",
          sorted(f.name for f in decoy.iterdir()) == [f"{n:064x}.entry" for n in range(3)], list(decoy.iterdir()))
    acks.unlink()
    pk = w.root / "talk" / "alice" / "packets"
    moved = tmp / "alice-packets-real"
    pk.rename(moved)
    pk.symlink_to(moved)
    rep = bob.sync()
    check("symlink: another party's symlinked folder is not read, and is named",
          rep.delivered == [] and any(r["code"] == "not-a-folder" for r in rep.refused), rep.as_dict())
    pk.unlink()
    moved.rename(pk)
    target = tmp / "outside.entry"
    target.write_bytes((next(pk.glob("*.entry"))).read_bytes())
    (pk / ("e" * 64 + ".entry")).symlink_to(target)
    rep = bob.sync()
    check("symlink: a symlinked file is not read, and is named",
          any(r["code"] == "not-a-file" for r in rep.refused) and texts(rep) == ["more"], rep.as_dict())


def stale_and_rotated(tmp: Path) -> None:
    """F2: an acknowledgement counts only for the packet it names by seq and id."""
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    alice.send("note", {"text": "a"})
    bob.sync()
    alice.sync()                                                     # all taken, all removed
    shutil.rmtree(tmp / "homes" / "alice")                           # the home is lost after full removal
    try:
        w.relay("alice").send("note", {"text": "again from seq 1"})
        check("lost home after removal: the others' acks show it, so sending is refused", False)
    except RelayError as e:
        check("lost home after removal: the others' acks show it, so sending is refused", "state was lost" in str(e), str(e))

    w2 = World(tmp / "w2")
    alice, bob = w2.relay("alice"), w2.relay("bob")
    ids = [alice.send("note", {"text": t}) for t in ("p", "q")]
    forged = sp.sign({"v": 2, "reg": "talk-ack", "key": w2.members["bob"], "as": "bob", "seq": 50, "prev": "0" * 64,
                      "saw": [], "at": "2026-11-05T10:00:00Z", "kind": "ack",
                      "data": {"upto": {"alice": {"seq": 2, "id": "a" * 64, "key": w2.members["alice"]}}}}, w2.keys["bob"])
    acks = w2.root / "talk" / "bob" / "acks"
    acks.mkdir(parents=True, exist_ok=True)
    (acks / ("b" * 64 + ".entry")).write_bytes(forged)                # bob's key, but naming no packet of alice's
    rep = alice.sync()
    check("stale ack: an ack that names a packet by an id that is not the sender's removes nothing",
          rep.removed == 0 and rep.acked == {"bob": 0} and "bob" in rep.stale_acks, rep.as_dict())

    w3 = World(tmp / "w3", parties=("alice", "bob", "alice2"))
    bob = w3.relay("bob", members={"alice": w3.members["alice"], "bob": w3.members["bob"]})
    alice = w3.relay("alice", members={"alice": w3.members["alice"], "bob": w3.members["bob"]})
    alice.send("note", {"text": "old key"})
    bob.sync()
    rotated = {"alice": w3.members["alice2"], "bob": w3.members["bob"]}   # the operator gives alice a new key
    try:
        Relay(w3.root, "talk", "alice", w3.keys["alice2"], rotated, tmp / "w3" / "homes" / "alice", w3.anchors).send("note", {})
        check("new key: the old home is refused (its chains are the old key's)", False)
    except RelayError as e:
        check("new key: the old home is refused (its chains are the old key's)", "another key" in str(e), str(e))
    shutil.rmtree(w3.root / "talk" / "alice")                         # the old key's folder goes with it
    new_alice = Relay(w3.root, "talk", "alice", w3.keys["alice2"], rotated, tmp / "w3" / "homes" / "alice-new", w3.anchors)
    new_alice.send("note", {"text": "new key"})
    bob_r = Relay(w3.root, "talk", "bob", w3.keys["bob"], rotated, tmp / "w3" / "homes" / "bob", w3.anchors)
    rep = bob_r.sync()
    check("new key: the receiver starts the sender's new chain from seq 1, and says why",
          texts(rep) == ["new key"] and any(r["code"] == "key-changed" for r in rep.refused), rep.as_dict())
    rep = new_alice.sync()
    check("new key: the sender removes its new packet only on an ack of it", rep.removed == 1 and not rep.stale_acks, rep.as_dict())


def domains_and_kinds(tmp: Path) -> None:
    """F3: no domain may end in -ack or -skip; only acks count as acks."""
    w = World(tmp)
    for d in ("talk-ack", "talk-skip", "vouch"):
        try:
            Relay(w.root, d, "alice", w.keys["alice"], w.members, tmp / "h", w.anchors)
            check(f"domain: {d} is refused", False)
        except RelayError as e:
            check(f"domain: {d} is refused", "not ending in" in str(e), str(e))
    alice, bob = w.relay("alice"), w.relay("bob")
    alice.send("note", {"text": "x"})
    note = sp.sign({"v": 2, "reg": "talk-ack", "key": w.members["bob"], "as": "bob", "seq": 9, "prev": "0" * 64,
                    "saw": [], "at": "2026-11-05T10:00:00Z", "kind": "note", "data": {"upto": "not a dict"}}, w.keys["bob"])
    acks = w.root / "talk" / "bob" / "acks"
    acks.mkdir(parents=True, exist_ok=True)
    (acks / ("c" * 64 + ".entry")).write_bytes(note)
    rep = alice.sync()
    check("kinds: a packet of another kind among the acks is no ack, and is named",
          rep.acked == {"bob": 0} and any(r["code"] == "wrong-kind" for r in rep.refused), rep.as_dict())


def old_vouch(tmp: Path) -> None:
    """F4: a vouch skips only the gap it names, from its first seq: hidden packets before it are waited for."""
    w = World(tmp, parties=("alice", "bob", "carol"))
    alice, bob, carol = w.relay("alice"), w.relay("bob"), w.relay("carol")
    ids = [alice.send("note", {"text": t}) for t in ("1", "2", "3", "4")]
    pk = w.root / "talk" / "alice" / "packets"
    op = Relay(w.root, "talk", "op", w.keys["op"], w.members, tmp / "homes" / "op", w.anchors)
    op.skip("alice", 3, 3, ids[2])                                   # #3 lost for good, as the operator says
    hidden = tmp / "hidden"
    hidden.mkdir()
    for i in ids[:3]:                                                # a folder writer hides #1 to #3 from carol
        (pk / f"{i}.entry").rename(hidden / f"{i}.entry")
    rep = carol.sync()
    check("old vouch: a reader before the vouch's first seq does not skip what is only hidden",
          rep.delivered == [] and rep.skipped == [], rep.as_dict())
    for f in hidden.iterdir():
        f.rename(pk / f.name)
    rep = carol.sync()
    check("old vouch: once they are back, they are taken, in order", texts(rep) == ["1", "2", "3", "4"], rep.as_dict())


def hostile_files(tmp: Path) -> None:
    """F5: a FIFO, a huge file, a folder where a packet should be, and many junk files: none hangs or
    crashes a round."""
    import time as _time
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    i = alice.send("note", {"text": "real"})
    pk = w.root / "talk" / "alice" / "packets"
    os.mkfifo(pk / ("d" * 64 + ".entry"))
    with open(pk / ("f" * 64 + ".entry"), "wb") as f:
        f.truncate(10 * 1024 * 1024)
    for n in range(300):
        (pk / f"{n:064x}.entry").write_text("junk")
    t0 = _time.monotonic()
    rep = bob.sync()
    took = _time.monotonic() - t0
    codes = {r["code"] for r in rep.refused}
    check("hostile: a FIFO and a huge file are not read, junk is refused, the real packet is taken, in bounded time",
          texts(rep) == ["real"] and {"not-a-file", "too-large"} <= codes and took < 30, (codes, took))
    check("hostile: refusals reported per folder are capped", len(rep.refused) <= 101 + 2, len(rep.refused))
    mine = w.root / "talk" / "bob" / "packets"
    j = w.relay("bob").send("note", {"text": "bob's"})
    (mine / f"{j}.entry").unlink()
    (mine / f"{j}.entry").mkdir()                                    # a folder planted at a packet's name
    rep = bob.sync()
    check("hostile: a folder at one's own packet's name is refused, not a crash",
          any(r["code"] == "not-a-file" for r in rep.refused), rep.as_dict())
    del i


def sticky_fork(tmp: Path) -> None:
    """F6: a fork stays, even when one side is removed from the folder."""
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    alice.send("note", {"text": "first"})
    shutil.copytree(tmp / "homes" / "alice", tmp / "homes" / "alice-copy")
    twin = w.relay("alice", home="alice-copy")
    a = alice.send("note", {"text": "this side"})
    twin.send("note", {"text": "that side"})
    bob.sync()
    (w.root / "talk" / "alice" / "packets" / f"{a}.entry").unlink()   # a folder writer removes one side
    rep = bob.sync()
    check("sticky fork: with one side gone, the other is still not taken", rep.delivered == [] and "alice" in rep.forks,
          rep.as_dict())


def names(tmp: Path) -> None:
    """F9: names the protocol keeps, and a home inside the shared folder."""
    w = World(tmp)
    (tmp / "members").write_text(f"vouch {w.members['alice']}\n")
    try:
        load_keys(tmp / "members")
        check("names: a party named vouch is refused", False)
    except RelayError as e:
        check("names: a party named vouch is refused", "keeps for itself" in str(e), str(e))
    try:
        Relay(w.root, "talk", "alice", w.keys["alice"], w.members, w.root / "home", w.anchors)
        check("names: a home inside the shared folder is refused (keys would go into it)", False)
    except RelayError as e:
        check("names: a home inside the shared folder is refused (keys would go into it)", "must not hold" in str(e), str(e))


def swap_during_sync(tmp: Path) -> None:
    """R1: a folder swapped for a symlink partway through a round: nothing behind the symlink is
    written or removed, since every write and removal goes through the folder opened at the start."""
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    alice.send("note", {"text": "one"})
    bob.sync()                                                       # bob has an ack in his folder
    alice.send("note", {"text": "two"})
    decoy = tmp / "decoy"
    decoy.mkdir()
    for n in range(3):
        (decoy / f"{n:064x}.entry").write_text("a store's entry")
    acks = w.root / "talk" / "bob" / "acks"
    real = Relay._vouches

    def swap_then_read(self, rep):
        moved = tmp / "acks-moved"
        acks.rename(moved)                                           # the folder writer, mid-round
        acks.symlink_to(decoy)
        return real(self, rep)
    Relay._vouches = swap_then_read
    try:
        rep = bob.sync()
    finally:
        Relay._vouches = real
    check("swap: a folder swapped for a symlink mid-round: nothing behind it is written or removed",
          sorted(f.name for f in decoy.iterdir()) == [f"{n:064x}.entry" for n in range(3)], sorted(decoy.iterdir()))
    check("swap: the round went on through the folder it opened (the ack is in the real one)",
          rep.ack_written and len(list((tmp / "acks-moved").glob("*.entry"))) == 1, rep.as_dict())
    try:
        bob.sync()
        check("swap: the next round refuses the symlink", False)
    except RelayError as e:
        check("swap: the next round refuses the symlink", "not a plain folder" in str(e), str(e))


def planted_at_a_name(tmp: Path) -> None:
    """R2 and R4: something planted at a name of one's own refuses in one line; a key in the folder is refused."""
    w = World(tmp)
    alice, bob = w.relay("alice"), w.relay("bob")
    alice.send("note", {"text": "x"})
    bob.sync()
    acks = w.root / "talk" / "bob" / "acks"
    st = json.loads((tmp / "homes" / "bob" / "talk" / "bob" / "state.json").read_text())
    (acks / f"{st['ack']['id']}.entry").unlink()
    (acks / f"{st['ack']['id']}.entry").symlink_to(tmp / "elsewhere")   # bob's ack's name, now a symlink
    try:
        bob.sync()
        check("planted: a symlink at one's own file name refuses the round in one line (no traceback)", True)
    except RelayError as e:
        check("planted: a symlink at one's own file name refuses the round in one line (no traceback)",
              "\n" not in str(e), str(e))
    check("planted: and nothing is written behind it", not (tmp / "elsewhere").exists())
    inside = w.root / "keys"
    inside.mkdir()
    shutil.copy(w.keys["alice"], inside / "alice")
    shutil.copy(str(w.keys["alice"]) + ".pub", inside / "alice.pub")
    try:
        Relay(w.root, "talk", "alice", inside / "alice", w.members, tmp / "homes" / "alice", w.anchors)
        check("planted: a key file inside the shared folder is refused", False)
    except RelayError as e:
        check("planted: a key file inside the shared folder is refused", "must not hold" in str(e), str(e))


# A stand-in for the phi-check Feature's command, to its documented contract (`-` reads stdin; exit
# 0 clean, 1 on a finding, never the matched text; 2 on a usage error); here, one rule: a US SSN.
FAKE_PHI = f"""#!{sys.executable}
import re, sys
if "-" not in sys.argv[1:]:
    sys.exit(2)
hits = [n for n, line in enumerate(sys.stdin.read().splitlines(), 1) if re.search(r"\\b\\d{{3}}-\\d{{2}}-\\d{{4}}\\b", line)]
if hits:
    print("phi-check: refused (us-ssn)", file=sys.stderr)
sys.exit(1 if hits else 0)
"""


def phi_guard(tmp: Path) -> Path:
    f = tmp / "bin" / "phi-check"
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(FAKE_PHI)
    f.chmod(0o755)
    return f


def guards(tmp: Path) -> None:
    """Guards (SPEC.md, "Guards"): egress refuses before signing; ingress quarantines, and the
    sender's order goes on."""
    phi = phi_guard(tmp)
    chain = sp.guard.Chain.parse(f"{phi} --no-exceptions --stdin-filename packet -")
    w = World(tmp)
    guarded = Relay(w.root, "talk", "alice", w.keys["alice"], w.members, tmp / "homes" / "alice", w.anchors, egress=chain)
    try:
        guarded.send("note", {"text": "patient 123-45-6789"})
        check("egress: a packet the guard refuses is not sent", False)
    except sp.Refused as r:
        check("egress: a packet the guard refuses is not sent", r.code == "guarded" and "123-45-6789" not in str(r), str(r))
    pk = w.root / "talk" / "alice" / "packets"
    check("egress: nothing reaches the folder, and the chain does not move",
          files(pk) == [] and guarded.status()["sent"] == 0, (files(pk), guarded.status()))
    guarded.send("note", {"text": "clean one"})
    plain = w.relay("alice")                                          # the same party, sending without a guard
    plain.send("note", {"text": "patient 123-45-6789"})
    plain.send("note", {"text": "clean two"})
    bob = Relay(w.root, "talk", "bob", w.keys["bob"], w.members, tmp / "homes" / "bob", w.anchors, ingress=chain)
    rep = bob.sync()
    check("ingress: clean packets are delivered, in order, around the refused one",
          texts(rep) == ["clean one", "clean two"] and [d["seq"] for d in rep.delivered] == [1, 3], rep.as_dict())
    q = rep.quarantined
    check("ingress: the refused one is quarantined, with the guard's reason, never the matched text",
          len(q) == 1 and q[0]["seq"] == 2 and "exit 1" in q[0]["reason"] and "123-45-6789" not in json.dumps(q), q)
    qf = Path(q[0]["file"]) if q else Path("/nonexistent")
    check("ingress: kept in the home's quarantine, not in the inbox",
          qf.is_file() and qf.with_suffix(".reason").is_file()
          and not list((tmp / "homes" / "bob" / "talk" / "bob" / "inbox" / "alice").glob("0000000002-*")), qf)
    rep = alice_rep = plain.sync()
    check("ingress: the quarantined packet is acknowledged with the rest, so the sender removes all three",
          alice_rep.removed == 3 and alice_rep.acked == {"bob": 3}, rep.as_dict())
    w2 = World(tmp / "w2")
    broken = sp.guard.Chain.parse(str(tmp / "no-such-guard"))
    w2.relay("alice").send("note", {"text": "anything"})
    bob2 = Relay(w2.root, "talk", "bob", w2.keys["bob"], w2.members, tmp / "w2" / "homes" / "bob", w2.anchors, ingress=broken)
    rep = bob2.sync()
    check("ingress: a guard that cannot run holds the sender: nothing delivered, nothing quarantined, said so",
          rep.delivered == [] and rep.quarantined == [] and "could not run" in rep.guard_failed.get("alice", {}).get("reason", ""),
          rep.as_dict())
    rep = w2.relay("alice").sync()
    check("ingress: and nothing is acknowledged, so the sender keeps its packet", rep.removed == 0 and rep.acked == {"bob": 0},
          rep.as_dict())
    bob3 = Relay(w2.root, "talk", "bob", w2.keys["bob"], w2.members, tmp / "w2" / "homes" / "bob", w2.anchors, ingress=chain)
    rep = bob3.sync()
    check("ingress: once the guard runs again, the held packet is taken", texts(rep) == ["anything"], rep.as_dict())
    qdir = tmp / "homes" / "bob" / "talk" / "bob" / "quarantine"
    check("ingress: the quarantine is the operator's alone (0700 folders, 0600 files)",
          (qdir.stat().st_mode & 0o777) == 0o700 and all((f.stat().st_mode & 0o777) == 0o600 for f in qdir.rglob("*") if f.is_file()),
          [oct(f.stat().st_mode & 0o777) for f in qdir.rglob("*")])


def command(tmp: Path) -> None:
    home = tmp / "home"
    root = tmp / "shared"
    root.mkdir()
    env = {"PACKET_RELAY_HOME": str(home), "PACKET_RELAY_ROOT": str(root)}

    def run(*argv) -> tuple[int, str]:
        out = io.StringIO()
        old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                code = cli.main(list(argv))
        finally:
            for k, v in old.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        return code, out.getvalue()
    run("setup")
    lines = [run("key", "new", p)[1].strip() for p in ("alice", "bob")]
    (home / "members").mkdir(exist_ok=True)
    (home / "members" / "talk").write_text("\n".join(lines) + "\n")
    code, out = run("send", "--domain", "talk", "--as", "alice", "--kind", "note", "--data", '{"text": "by command"}')
    check("command: send prints the packet's id", code == 0 and sp.is_id(out.strip()), out)
    code, out = run("sync", "--domain", "talk", "--as", "bob", "--json")
    rep = json.loads(out) if code == 0 else {}
    check("command: sync takes it, as JSON", [d["data"]["text"] for d in rep.get("delivered", [])] == ["by command"], out)
    code, out = run("status", "--domain", "talk", "--as", "bob")
    check("command: status says what was taken", code == 0 and "taken from alice through #1" in out, out)
    code, out = run("send", "--domain", "talk", "--as", "zed", "--kind", "note")
    check("command: a party with no key is refused in one line", code == 2 and len(out.strip().splitlines()) == 1
          and "no key for zed" in out, out)
    code, out = run("check")
    check("command: check says what is ready", code == 0 and "folder" in out and "ready" in out, out)


def main() -> int:
    for case in (two_parties, instance_parties, version_three, lossy, party_away, slow_sync, forged, fork, lost_for_good, state_lost, no_hard_links,
                 bad_config, symlinks, stale_and_rotated, domains_and_kinds, old_vouch, hostile_files,
                 sticky_fork, names, swap_during_sync, planted_at_a_name, guards, command):
        with tempfile.TemporaryDirectory() as t:
            try:
                case(Path(t))
            except Exception as e:                # a crash is a failure of that case, not of the run
                import traceback
                traceback.print_exc()
                check(f"{case.__name__}: ran to the end", False, repr(e))
    print(f"packet-relay: {PASSED} passed, {len(FAILED)} failed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
