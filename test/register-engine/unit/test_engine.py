#!/usr/bin/env python3
"""The register engine (SPEC.md; AOF ADR 0028): a building block with no register types of its own but
`log`, given its types by the capability Features through a root-owned types folder.

    the types folder      log alone; a module's types; a module anyone else can change, a symlink,
                          two giving one name, one that cannot load: each refused, by name
    writing and reading   a roster by an operator, entries by an agent, the type's checks; refused:
                          another register's entry, a key no roster lists, a roster by an agent
    forks                 reported, the writer stopped, an operator's ruling settles it, a prune
    sync and the guard    stores merge; a guard refuses an entry and what descends from it
    views                 the index and the change feed
    the same format       entries agentic-register 0.18.0 wrote read here unchanged
    the command           types and verify

Keys and stores are made fresh in a throwaway folder; no real register is read.
"""
import contextlib
import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parents[2] / "src"
sys.path[:0] = [str(SRC / "register-engine"), str(SRC / "sign-packet")]
from registerengine import adapters, cli, core  # noqa: E402
from registerengine import registertypes as types  # noqa: E402

FAILED: list[str] = []
PASSED = 0
REG = "notes"

NOTES_MODULE = '''
from registerengine import core
from registerengine.registertypes import RegisterType

def _check_note(d):
    if not isinstance(d.get("text"), str) or not d["text"].strip():
        raise core.Refused("bad-field", "a note has text")

TYPES = [RegisterType("notes", {"note": _check_note}, description="short notes", feature="test-capability")]
'''


def check(desc: str, ok: bool, got=None) -> None:
    global PASSED
    if ok:
        PASSED += 1
    else:
        FAILED.append(desc)
        print(f"FAIL: {desc}" + (f"\n  got: {got!r}"[:900] if got is not None else ""))


def keygen(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(path)], check=True)
    return core.public_key(path)


def refused_code(fn) -> str | None:
    try:
        fn()
    except core.Refused as e:
        return e.code
    return None


def run(*argv) -> tuple[int, str]:
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = cli.main(list(argv))
    except SystemExit as e:
        code = e.code if isinstance(e.code, int) else 1
        out.write(str(e.code))
    return code, out.getvalue()


def types_folder(tmp: Path) -> None:
    check("types: with no types folder, the engine knows log alone", sorted(types.load(tmp / "none")) == ["log"])
    d = tmp / "types.d"
    d.mkdir(mode=0o755)
    (d / "test-capability.py").write_text(NOTES_MODULE)
    os.chmod(d / "test-capability.py", 0o644)
    ts = types.load(d)
    check("types: a capability's module gives its types", sorted(ts) == ["log", "notes"]
          and ts["notes"].feature == "test-capability" and "note" in ts["notes"].kinds, sorted(ts))

    def refused(desc, setup, undo, want):
        setup()
        try:
            types.load(d)
            check(desc, False)
        except types.TypesError as e:
            check(desc, want in str(e) and (want != "other.py and" or "test-capability.py" in str(e)), str(e))
        finally:
            undo()
    m = d / "test-capability.py"
    refused("types: a module its group can change is refused", lambda: os.chmod(m, 0o664), lambda: os.chmod(m, 0o644),
            "writable by its group")
    refused("types: a folder others can change is refused", lambda: os.chmod(d, 0o757), lambda: os.chmod(d, 0o755),
            "writable by its group or others")
    link = d / "linked.py"
    refused("types: a symlinked module is refused", lambda: link.symlink_to(m), lambda: link.unlink(), "symlink")
    dup = d / "other.py"

    def put_dup():
        dup.write_text(NOTES_MODULE.replace("test-capability", "another-capability"))
        os.chmod(dup, 0o644)
    refused("types: two modules giving one type name are refused, naming both files", put_dup, lambda: dup.unlink(),
            "other.py and")
    broken = d / "broken.py"

    def put_broken():
        broken.write_text("raise RuntimeError('half-built')\n")
        os.chmod(broken, 0o644)
    refused("types: a module that cannot load is refused, by name", put_broken, lambda: broken.unlink(), "broken.py")
    try:
        ts["notes"].kinds["note"] = lambda d: None
        check("types: a type's kinds are frozen once accepted (no module swaps another's checks)", False)
    except TypeError:
        check("types: a type's kinds are frozen once accepted (no module swaps another's checks)", True)
    code = ("import sys; sys.path[:0] = [%r, %r]\n"
            "from registerengine import registertypes as t\n"
            "t.TYPES_DIR = __import__('pathlib').Path(%r)\n"
            "try:\n    t.load(); print('loaded')\nexcept t.TypesError as e:\n    print('refused:', e)\n"
            % (str(SRC / "register-engine"), str(SRC / "sign-packet"), str(d)))
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    check("types: the installed folder is read only by an isolated process (python3 -I)",
          "refused" in r.stdout and "isolated" in r.stdout, r.stdout + r.stderr)
    r = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, text=True)
    check("types: and even isolated, a folder below one that is not root's all the way up is refused",
          "refused" in r.stdout and ("not root" in r.stdout or "writable" in r.stdout), r.stdout + r.stderr)
    os.environ["REGISTER_ENGINE_TYPES"] = str(tmp / "elsewhere")
    check("types: the environment never points the engine at another folder", types.TYPES_DIR != tmp / "elsewhere")
    del os.environ["REGISTER_ENGINE_TYPES"]


def write_and_read(tmp: Path, kinds: dict) -> dict:
    op, agent, stranger = tmp / "keys" / "op", tmp / "keys" / "scribe", tmp / "keys" / "stranger"
    op_pub, agent_pub, _ = keygen(op), keygen(agent), keygen(stranger)
    af = tmp / "anchors"
    af.write_text(f"operator-1 {op_pub}\n")
    anchors = adapters.load_anchors(af)
    store = adapters.DirStore(tmp / "store")

    def add(key, who, kind, data, register=REG):
        return adapters.add(store, key, who, kind, data, anchors, register=register, kinds=kinds)
    add(op, "operator-1", "roster", {"add": [{"key": agent_pub, "as": "scribe", "role": "agent"}]})
    first = add(agent, "scribe", "note", {"text": "first"})
    led = core.read(adapters.raws(store), anchors, None, REG, kinds)
    check("write: an operator's roster, then an agent's entry, both valid", len(led.valid) == 2 and first in led.valid, led.refused)
    check("write: the type's check refuses a bad entry before it is signed",
          refused_code(lambda: add(agent, "scribe", "note", {"text": " "})) == "bad-field")
    check("write: a kind the type does not know is kept, its data unchecked (format v2)",
          refused_code(lambda: add(agent, "scribe", "later_kind", {"anything": 1})) is None)
    check("write: a key no roster lists is refused", refused_code(lambda: add(stranger, "stranger", "note", {"text": "hi"}))
          == "unknown-key")
    check("write: an agent may not change the roster",
          refused_code(lambda: add(agent, "scribe", "roster", {"add": [{"key": core.public_key(stranger), "as": "x", "role": "agent"}]}))
          == "not-operator")
    other = adapters.DirStore(tmp / "other-register")
    adapters.add(other, op, "operator-1", "roster", {"add": [{"key": agent_pub, "as": "scribe", "role": "agent"}]},
                 anchors, register="elsewhere", kinds={})
    for i in other.ids():
        store.put(i, other.get(i))
    led = core.read(adapters.raws(store), anchors, None, REG, kinds)
    check("read: an entry of another register is refused", sorted(c for c, _ in led.refused.values()) == ["wrong-register"],
          led.refused)
    sample = core.parse(store.get(first), kinds)
    v3 = core.sp.sign({**sample.value, "v": 3}, agent, versions=(1, 2, 3))   # a writer that knows v3
    led = core.read(list(adapters.raws(store)) + [v3], anchors, None, REG, kinds)
    check("format v3: a v3 entry is refused here (bad-version), never read by v2's rules",
          [c for c, _ in led.refused.values()].count("bad-version") == 1, led.refused)
    for what, fn in (("read", lambda: core.read(adapters.raws(store), anchors, None, REG)),
                     ("add", lambda: adapters.add(store, agent, "scribe", "note", {"text": "x"}, anchors, register=REG)),
                     ("sync", lambda: adapters.sync([adapters.raws(store)], adapters.MemoryStore(), anchors, None, REG))):
        try:
            fn()
            check(f"kinds: {what} without the type's kinds fails, never reads unchecked", False)
        except TypeError as e:
            check(f"kinds: {what} without the type's kinds fails, never reads unchecked", "kinds is required" in str(e), str(e))
    return {"op": op, "agent": agent, "anchors": anchors, "store": store, "agent_pub": agent_pub}


def forks_and_prunes(tmp: Path, w: dict, kinds: dict) -> None:
    store, anchors, agent = w["store"], w["anchors"], w["agent"]
    led = core.read(adapters.raws(store), anchors, None, REG, kinds)
    last = max((e for e in led.valid.values() if e.principal == "scribe"), key=lambda e: e.seq)
    twins = []
    for text in ("one way", "the other way"):
        value = {"v": core.VERSION, "reg": REG, "key": w["agent_pub"], "as": "scribe", "seq": last.seq + 1,
                 "prev": last.id, "saw": [], "at": "2026-11-11T10:00:00Z", "kind": "note", "data": {"text": text}}
        raw = core.sign(value, agent, kinds)
        i = core.entry_id(raw.split(b"\n", 1)[0])
        store.put(i, raw)
        twins.append(i)
    led = core.read(adapters.raws(store), anchors, None, REG, kinds)
    check("fork: one key writing two entries as one seq is reported, both kept",
          led.unruled_forks and set(twins) <= set(led.valid), led.unruled_forks)
    check("fork: the forked writer is stopped until an operator rules",
          refused_code(lambda: adapters.add(store, agent, "scribe", "note", {"text": "and on"}, anchors,
                                            register=REG, kinds=kinds)) == "bad-chain")
    ruling = adapters.add(store, w["op"], "operator-1", "ruling", {"keep": twins[0]}, anchors, register=REG, kinds=kinds)
    led = core.read(adapters.raws(store), anchors, None, REG, kinds)
    check("ruling: an operator's ruling settles the fork, the other side ruled out",
          not led.unruled_forks and twins[1] in led.ruled_out, (led.unruled_forks, led.ruled_out))
    check("ruling: the writer goes on from the side kept",
          refused_code(lambda: adapters.add(store, agent, "scribe", "note", {"text": "and on"}, anchors,
                                            register=REG, kinds=kinds)) is None)
    adapters.add(store, w["op"], "operator-1", "prune", {"ruling": ruling, "pruned": [twins[1]]}, anchors,
                 register=REG, kinds=kinds)
    (store.path / f"{twins[1]}.entry").unlink()
    led = core.read(adapters.raws(store), anchors, None, REG, kinds)
    check("prune: the ruled-out entry left out of the store, counted as pruned, nothing held",
          twins[1] in led.pruned and not led.held, (led.pruned, led.held))


def sync_and_views(tmp: Path, w: dict, kinds: dict) -> None:
    store, anchors = w["store"], w["anchors"]
    copy = adapters.DirStore(tmp / "copy")
    r = adapters.sync([adapters.raws(store)], copy, anchors, None, REG, kinds)
    check("sync: a fresh store takes every valid entry, none of another register", len(r.put) == len(
        core.read(adapters.raws(store), anchors, None, REG, kinds).valid) and "wrong-register" in
        {c for c, _ in r.refused.values()}, str(r))
    r = adapters.sync([adapters.raws(store)], copy, anchors, None, REG, kinds)
    check("sync: a second time puts nothing", not r.put and r.already, str(r))
    adapters.add(store, w["agent"], "scribe", "note", {"text": "SECRET-WORD inside"}, anchors, register=REG, kinds=kinds)
    adapters.add(store, w["agent"], "scribe", "note", {"text": "after it"}, anchors, register=REG, kinds=kinds)
    g = tmp / "guard.sh"
    g.write_text("#!/bin/sh\n! grep -q SECRET-WORD\n")
    g.chmod(0o755)
    guard = adapters.Guard((str(g),), REG, 5)
    r = adapters.sync([adapters.raws(store)], copy, anchors, None, REG, kinds, guard=guard)
    check("guard: an entry the guard refuses is not put, nor what descends from it",
          not r.put and len([i for i, (c, _) in r.refused.items() if c == "guarded"]) == 2, str(r))

    led = core.read(adapters.raws(store), anchors, None, REG, kinds)
    db = tmp / "index.db"
    adapters.write_sqlite(led, db)
    n = sqlite3.connect(db).execute("SELECT count(*) FROM entries").fetchone()[0]
    check("index: every valid entry is in the index", n == len(led.valid), n)
    cursor = led.heads
    adapters.add(store, w["agent"], "scribe", "note", {"text": "new since"}, anchors, register=REG, kinds=kinds)
    led = core.read(adapters.raws(store), anchors, None, REG, kinds)
    new = adapters.since(led, cursor)
    check("feed: since a cursor, exactly the new entry, even with a pruned entry behind it", len(new) == 1
          and adapters.feed_line(led, new[0], REG)["data"] == {"text": "new since"}, new)


def same_format(tmp: Path) -> None:
    """Entries agentic-register 0.18.0 wrote (its own code) read here unchanged, ledger kinds and all.
    Run only where src/agentic-register is in the same tree (this collection once both are in it)."""
    if not (SRC / "agentic-register" / "register").is_dir():
        print("skip: same format (src/agentic-register is not in this tree)")
        return
    sys.path.insert(0, str(SRC / "agentic-register"))
    from register import adapters as old_adapters, core as old_core  # noqa: E402
    op = tmp / "old" / "op"
    op_pub = keygen(op)
    anchors = {op_pub: "operator-1"}
    old_store = old_adapters.DirStore(tmp / "old" / "ledger")
    for t in ("one", "two"):
        old_adapters.add(old_store, op, "operator-1", "work", {"title": t}, anchors, register="ledger")
    anchors_new = {op_pub: "operator-1"}
    old = old_core.read(old_adapters.raws(old_store), anchors, None, "ledger")   # agentic-register's ledger kinds
    new = core.read(adapters.raws(adapters.DirStore(tmp / "old" / "ledger")), anchors_new, None, "ledger", {})
    check("same format: agentic-register's entries read here as valid, with the same ids and order",
          list(new.order) == list(old.order) and len(new.valid) == 2 and not new.refused, (new.refused, new.order))


def command(tmp: Path) -> None:
    # In this process (not isolated, the folder the user's): the command reads the test's folder.
    real = types.load
    types.load = lambda folder=None: real(tmp / "types.d" if folder is None else folder)
    code, out = run("types", "--json")
    check("command: types lists log and the capability's type, with who gave it",
          code == 0 and {(r["name"], r["feature"]) for r in json.loads(out)} == {("log", "register-engine"), ("notes", "test-capability")}, out)
    code, out = run("verify", str(tmp / "store"), "--register", REG, "--type", "notes", "--anchors", str(tmp / "anchors"))
    check("command: verify reports the store, and exits 1 on the refused entry of another register",
          code == 1 and "wrong-register" in out, out)
    code, out = run("verify", str(tmp / "copy"), "--register", REG, "--type", "notes", "--anchors", str(tmp / "anchors"))
    check("command: a clean store verifies", code == 0 and "0 refused" in out, out)
    code, out = run("verify", str(tmp / "copy"), "--register", REG, "--type", "nothing")
    check("command: an unknown type is refused, saying which are installed", code != 0 and "log" in out and "notes" in out, out)
    code, out = run("check", "--json")
    check("command: check says the types folder is ready", any(p["part"] == "types" and p["ready"] for p in json.loads(out)), out)
    types.load = real


def main() -> int:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        os.chmod(tmp, 0o755)
        types_folder(tmp)
        kinds = types.load(tmp / "types.d")["notes"].kinds
        w = write_and_read(tmp, kinds)
        forks_and_prunes(tmp, w, kinds)
        sync_and_views(tmp, w, kinds)
        same_format(tmp)
        command(tmp)
    print(f"register-engine: {PASSED} passed, {len(FAILED)} failed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
