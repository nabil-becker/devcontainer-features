"""The `agentic-register` command: the one place the Feature's behaviour lives (REQUIREMENTS.md, R6).

The Taskfile's tasks and the MCP server's tools call this, so the three never differ.

The registers are the Feature's `registers` option (or $AGENTIC_REGISTER_REGISTERS): entries
`name:type[:store][:mirror=<folder>]` separated by `;`, or a JSON list of {"name", "type", "store",
"mirror"} (parse_registers); with none, one register named ledger, of type ledger. A command works
on one register: --register, $AGENTIC_REGISTER_DEFAULT, else the first in the list.

Where things are, first match wins:
  the store    --store, the register's `store`, $AGENTIC_REGISTER_HOME/registers/<name>
  the mirror   the register's `mirror`, a folder `mirror` copies the store to and from (none: no mirror)
  the anchors  --anchors, $AGENTIC_REGISTER_ANCHORS, the `anchors` option, $AGENTIC_REGISTER_HOME/anchors
  who writes   --as, $AGENTIC_REGISTER_AS
  their key    $AGENTIC_REGISTER_HOME/keys/<principal> (made by `agentic-register key new <principal>`)
  the guard    the register's `guard` (a command run on every entry before it is written), else none;
               a guard the installed option sets is kept even when $AGENTIC_REGISTER_REGISTERS overrides it
A relative store, mirror or anchors path is taken from the top of the git repository you are in, else
from the current folder.
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

from . import adapters, core, types

LIB = Path(__file__).resolve().parents[1]
DEFAULT_HOME = "/var/lib/devcontainer-features/agentic-register"


# ---------------------------------------------------------------- configuration

def options() -> dict[str, str]:
    """The Feature's options as install.sh wrote them (KEY=value lines), or nothing."""
    out: dict[str, str] = {}
    f = LIB / "options.env"
    if f.is_file():
        for line in f.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip().strip('"')
    return out


def home() -> Path:
    return Path(os.environ.get("AGENTIC_REGISTER_HOME") or DEFAULT_HOME)


def base() -> Path:
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip() else Path.cwd()


def resolve(flag: str | None, env: str, option: str, default: Path) -> Path:
    value = flag or os.environ.get(env) or options().get(option) or ""
    if not value:
        return default
    p = Path(value)
    return p if p.is_absolute() else base() / p


DEFAULT_REGISTERS = [{"name": "ledger", "type": "ledger"}]


REGISTERS_HINT = ("write them without quotes, one register per entry separated by ';', each "
                  "name:type[:store][:mirror=<folder>][:guard=<command>][:guard_timeout=<seconds>], for example "
                  "'ledger:ledger:mirror=docs/ledger/entries;notes:log' (README.md, \"The registers option\")")


def parse_registers(raw: str) -> list:
    """The registers option, in either of its two forms (README.md, "The registers option").

    The quote-free form, `name:type[:store][:mirror=<folder>][:guard=<command>][:guard_timeout=<s>]`
    entries separated by `;`, survives
    the devcontainer CLI, which writes each option into a shell file as NAME="value" without
    escaping, so a bare `"` inside the value is lost when the file is sourced. A value starting with
    `[` is read as JSON, as before (it survives only when each `"` reaches the shell as `\\"`).
    """
    text = raw.strip()
    if not text:
        return [dict(r) for r in DEFAULT_REGISTERS]   # copies: registers() fills them in
    if text.startswith("["):
        try:
            return json.loads(text)
        except ValueError as e:
            stripped = "{" in text and '"' not in text
            why = ("its double quotes were stripped on the way in (the devcontainer CLI writes options into "
                   "a shell file without escaping them)") if stripped else f"it is not JSON ({e})"
            raise SystemExit(f"agentic-register: the registers option cannot be read: {why}.\n"
                             f"  received: {text}\n  hint: {REGISTERS_HINT}")
    regs = []
    for entry in (e.strip() for e in text.split(";")):
        if not entry:
            continue
        name, _, rest = entry.partition(":")
        fields = rest.split(":") if rest else []
        reg: dict = {"name": name.strip()}
        if fields:
            t = fields.pop(0).strip()
            if t:
                reg["type"] = t
        for f in fields:
            key, eq, value = f.partition("=")
            key, value = key.strip(), value.strip()
            if not eq:
                key, value = "store", key
            if key not in ("store", "mirror", "guard", "guard_timeout") or key in reg or not value:
                raise SystemExit(f"agentic-register: the registers option cannot be read: in {entry!r}, {f!r} is "
                                 f"not a store, mirror=, guard= or guard_timeout= (each at most once).\n"
                                 f"  received: {text}\n  hint: {REGISTERS_HINT}")
            if key == "guard_timeout":
                try:
                    value = float(value)
                except ValueError:
                    raise SystemExit(f"agentic-register: the registers option cannot be read: in {entry!r}, "
                                     f"guard_timeout is a number of seconds: {value!r}\n  received: {text}") from None
            reg[key] = value
        regs.append(reg)
    return regs


def _installed_guards() -> dict[str, dict]:
    """The guards the installed registers option sets, by register: an environment cannot drop them."""
    f = LIB / "registers.json"
    try:
        regs = json.loads(f.read_text()) if f.is_file() else []
    except (OSError, ValueError) as e:   # fail closed: an unreadable list must not drop the guards silently
        raise SystemExit(f"agentic-register: cannot read the installed registers ({f}), so cannot keep their guards: {e}")
    return {r["name"]: {k: r[k] for k in ("guard", "guard_timeout") if k in r}
            for r in regs if isinstance(r, dict) and isinstance(r.get("name"), str) and "guard" in r}


def _check_guard(r: dict) -> None:
    g = r.get("guard")
    if g is not None:
        argv = shlex.split(g) if isinstance(g, str) else g
        if not (isinstance(argv, list) and argv and all(isinstance(x, str) and x for x in argv)):
            raise SystemExit(f"agentic-register: register {r['name']}: a guard is a command, a string or a list of "
                             f"strings: {g!r}")
        if not Path(argv[0]).is_absolute():   # never found on a writer's PATH or in a writer's checkout
            raise SystemExit(f"agentic-register: register {r['name']}: a guard's command is an absolute path, "
                             f"e.g. /usr/local/bin/ledger-guard: {argv[0]!r}")
    t = r.get("guard_timeout")
    if t is not None and (isinstance(t, bool) or not isinstance(t, (int, float))
                          or not 0 < t <= adapters.GUARD_TIMEOUT_MAX):
        raise SystemExit(f"agentic-register: register {r['name']}: guard_timeout is a number of seconds "
                         f"(0 to {adapters.GUARD_TIMEOUT_MAX:g}): {t!r}")
    if t is not None and g is None:
        raise SystemExit(f"agentic-register: register {r['name']}: guard_timeout without a guard")


def registers() -> list[dict]:
    """The registers this Feature keeps, checked: plain unique names, known types, a guard that is a command."""
    raw = os.environ.get("AGENTIC_REGISTER_REGISTERS")
    overridden = raw is not None
    if raw is None:
        f = LIB / "registers.json"
        raw = f.read_text() if f.is_file() else ""
    regs = parse_registers(raw)
    if not isinstance(regs, list) or not regs:
        raise SystemExit("agentic-register: the registers are a non-empty JSON list of {name, type, store}")
    seen = set()
    for r in regs:
        if not isinstance(r, dict) or not isinstance(r.get("name"), str) or not core.REGISTER_RE.fullmatch(r["name"]):
            raise SystemExit(f"agentic-register: a register needs a plain name ([a-z][a-z0-9-]*): {r!r}")
        if r["name"] in seen:
            raise SystemExit(f"agentic-register: two registers are named {r['name']}")
        seen.add(r["name"])
        r.setdefault("type", "ledger" if r["name"] == "ledger" else "log")
        try:
            t = types.get(r["type"])
        except ValueError as e:
            raise SystemExit(f"agentic-register: register {r['name']}: {e}")
        m = r.get("mirror")
        if m is not None and (not isinstance(m, str) or not m.strip()):
            raise SystemExit(f"agentic-register: register {r['name']}: a mirror is a folder: {m!r}")
        if m and t.outside_git:
            raise SystemExit(f"agentic-register: register {r['name']} ({r['type']}) is never stored in git, "
                             f"so it has no mirror")
        _check_guard(r)
    if overridden:
        installed = _installed_guards()
        for r in regs:
            if r["name"] in installed:      # the installed guard stands; an override cannot drop or replace it
                r.pop("guard_timeout", None)
                r.update(installed[r["name"]])
    return regs


def selected(a) -> dict:
    regs = registers()
    name = getattr(a, "register", None) or os.environ.get("AGENTIC_REGISTER_DEFAULT") or regs[0]["name"]
    for r in regs:
        if r["name"] == name:
            return r
    raise SystemExit(f"agentic-register: no register {name!r}; the registers are {', '.join(r['name'] for r in regs)}")


def rtype(a) -> types.RegisterType:
    return types.get(selected(a)["type"])


def guard_of(a) -> adapters.Guard | None:
    """The selected register's guard, or None. Its command is an absolute path (checked in registers())."""
    reg = selected(a)
    g = reg.get("guard")
    if g is None:
        return None
    argv = shlex.split(g) if isinstance(g, str) else list(g)
    return adapters.Guard(tuple(argv), reg["name"], float(reg.get("guard_timeout", adapters.GUARD_TIMEOUT)))


def store_path(a) -> Path:
    reg = selected(a)
    value = getattr(a, "store", None) or reg.get("store") or ""
    if not value:
        p = home() / "registers" / reg["name"]
    else:
        p = Path(value)
        p = p if p.is_absolute() else base() / p
    if types.get(reg["type"]).outside_git and in_git(p):
        raise SystemExit(f"agentic-register: register {reg['name']} ({reg['type']}) is never stored in git, and {p} is "
                         f"inside a git repository; leave its store unset (the Feature's volume) or point it outside")
    return p


def mirror_path(a) -> Path | None:
    """The register's mirror: a folder, usually in the repository, that `mirror` keeps level with
    the live store, so the store itself can stay where a branch switch never reaches it."""
    reg = selected(a)
    if not reg.get("mirror"):
        return None
    p = Path(reg["mirror"])
    p = p if p.is_absolute() else base() / p
    if p.resolve() == store_path(a).resolve():
        raise SystemExit(f"agentic-register: register {reg['name']}: its mirror is its store ({p}); "
                         f"leave the store unset (the Feature's volume) or give the mirror another folder")
    return p


def in_git(p: Path) -> bool:
    """Whether a path, or the nearest folder above it that exists, is inside a git work tree."""
    q = p
    while not q.exists() and q.parent != q:
        q = q.parent
    r = subprocess.run(["git", "-C", str(q if q.is_dir() else q.parent), "rev-parse", "--is-inside-work-tree"],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "true"


def anchors_path(a) -> Path:
    return resolve(getattr(a, "anchors", None), "AGENTIC_REGISTER_ANCHORS", "ANCHORS", home() / "anchors")


def principal(a) -> str:
    p = getattr(a, "as_", None) or os.environ.get("AGENTIC_REGISTER_AS") or ""
    if not p:
        raise SystemExit("agentic-register: who writes? Give --as <principal> or set AGENTIC_REGISTER_AS.")
    return p


def key_path(p: str) -> Path:
    return home() / "keys" / p


def anchors_of(a) -> dict[str, str]:
    f = anchors_path(a)
    return adapters.load_anchors(f) if f.is_file() else {}


def checked() -> adapters.CheckedFile:
    return adapters.CheckedFile(home() / "checked")


def version() -> str:
    return options().get("VERSION", "dev")


def emit(a, value, text: str) -> None:
    print(json.dumps(value, indent=2, sort_keys=True) if getattr(a, "json", False) else text)


def read_ledger(a) -> core.Ledger:
    c = checked()
    led = core.read(adapters.raws(adapters.DirStore(store_path(a))), anchors_of(a), c,
                    selected(a)["name"], rtype(a).kinds)
    if rtype(a).project is not None:   # what the entries add up to may disagree: those are flags too
        _, more = rtype(a).project(led)
        for i, fs in more.items():
            led.flags.setdefault(i, []).extend(f for f in fs if f not in led.flags.get(i, []))
    try:
        c.save()
    except OSError:
        pass  # a read-only home still reads; it only checks again next time
    return led


# ---------------------------------------------------------------- commands

def cmd_version(a) -> int:
    ssh = shutil.which("ssh-keygen") or "not found"
    emit(a, {"version": version(), "format": core.VERSION, "python": sys.version.split()[0], "ssh_keygen": ssh,
             "command": str(Path(sys.argv[0]).resolve()) if sys.argv and sys.argv[0] else ""},
         f"agentic-register {version()} (format v{core.VERSION})\npython    : {sys.version.split()[0]}\n"
         f"ssh-keygen: {ssh}\nlibrary   : {LIB}")
    return 0


def _writable(p: Path) -> bool:
    """The folder is writable, or the nearest folder above it that exists is (it can be made)."""
    while not p.exists():
        if p.parent == p:
            return False
        p = p.parent
    return p.is_dir() and os.access(p, os.W_OK)


def cmd_check(a) -> int:
    rows: list[tuple[str, bool, str]] = []   # part, ready, detail
    rows.append(("python", sys.version_info >= (3, 11), sys.version.split()[0] + " (3.11 or later)"))
    rows.append(("ssh-keygen", shutil.which("ssh-keygen") is not None, shutil.which("ssh-keygen") or "not found"))
    h = home()
    rows.append(("home", h.is_dir() and os.access(h, os.W_OK), f"{h} " + ("writable" if os.access(h, os.W_OK) else "not writable or missing; run agentic-register setup")))
    sp = store_path(a)
    n = len(adapters.DirStore(sp).ids())
    rows.append(("store", _writable(sp), f"{sp}, {n} entries"))
    try:
        an = anchors_of(a)
        rows.append(("anchors", bool(an), f"{anchors_path(a)}, {len(an)} operator key(s)" + ("" if an else "; add one: agentic-register key new <operator>")))
    except ValueError as e:
        rows.append(("anchors", False, str(e)))
    who = getattr(a, "as_", None) or os.environ.get("AGENTIC_REGISTER_AS")
    if who:
        kp = key_path(who)
        rows.append(("key", kp.is_file(), f"{who}: {kp}" + ("" if kp.is_file() else f" missing; agentic-register key new {who}")))
    else:
        rows.append(("key", True, "no writer set (AGENTIC_REGISTER_AS): reading only"))
    g = guard_of(a)
    if g is not None:
        cmd = g.argv[0]
        found = (Path(cmd).is_file() and os.access(cmd, os.X_OK)) if "/" in cmd else shutil.which(cmd) is not None
        rows.append(("guard", found, f"{cmd}, {g.timeout:g}s" + ("" if found else ": not found or not executable; "
                                                                  "every write is refused until it is")))
    ready = all(ok for _, ok, _ in rows)
    emit(a, {"ready": ready, "parts": [{"part": p, "ready": ok, "detail": d} for p, ok, d in rows]},
         "\n".join(f"agentic-register: {p:<10} {'ready' if ok else 'NOT READY'}  {d}" for p, ok, d in rows))
    return 0 if ready else 1


def cmd_setup(a) -> int:
    """Idempotent and never fatal: one line per thing, and the rest goes on."""
    h = home()
    lines = []
    for d, mode in ((h, 0o755), (h / "keys", 0o700)):
        try:
            d.mkdir(parents=True, exist_ok=True)
            os.chmod(d, mode)
            lines.append(f"agentic-register: {d} ready")
        except OSError as e:
            lines.append(f"agentic-register: cannot prepare {d}: {e}")
    an = anchors_path(a)
    if not an.exists():
        try:
            an.parent.mkdir(parents=True, exist_ok=True)
            an.write_text("# The operators' keys this reader trusts: <principal> ssh-ed25519 <base64>, one per line.\n"
                          "# Never read from a store. Add one with: agentic-register key new <operator>, then paste its line.\n")
            lines.append(f"agentic-register: {an} made (no operator yet)")
        except OSError as e:
            lines.append(f"agentic-register: cannot make {an}: {e}")
    opts = options()
    if "REGISTERMCP" not in opts:
        lines.append("agentic-register: MCP registration off (no options.env: not an installed Feature)")
    elif opts["REGISTERMCP"] != "true":
        lines.append("agentic-register: MCP registration off (registerMcp=false)")
    elif not shutil.which("claude"):
        lines.append("agentic-register: no agent harness found; MCP server not registered")
    elif subprocess.run(["claude", "mcp", "get", "agentic-register"], capture_output=True).returncode == 0:
        lines.append("agentic-register: MCP server already registered")
    else:
        r = subprocess.run(["claude", "mcp", "add", "--scope", "user", "agentic-register", "--", "agentic-register", "mcp"],
                           capture_output=True, text=True)
        lines.append("agentic-register: MCP server registered (user scope)" if r.returncode == 0
                     else f"agentic-register: MCP registration failed: {(r.stderr or r.stdout).strip()[:200]}")
    print("\n".join(lines))
    return 0


def cmd_key(a) -> int:
    kp = key_path(a.principal)
    if not core.PRINCIPAL_RE.fullmatch(a.principal):
        raise SystemExit(f"agentic-register: {a.principal!r} is not a principal ([a-z0-9][a-z0-9_.-]*)")
    if a.action == "new":
        if kp.exists():
            raise SystemExit(f"agentic-register: {kp} exists; a key is never replaced (remove it from the roster, then make a new principal key)")
        kp.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(kp.parent, 0o700)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(kp)], check=True)
    elif not kp.is_file():
        raise SystemExit(f"agentic-register: no key for {a.principal}; agentic-register key new {a.principal}")
    pub = core.public_key(kp)
    emit(a, {"principal": a.principal, "key": pub, "anchor_line": f"{a.principal} {pub}"},
         f"{a.principal} {pub}\n# an operator: paste this line into the anchors file, or have an operator add it:\n"
         f"#   agentic-register roster --as <operator> --add-key '{pub}' --principal {a.principal} --role agent")
    return 0


def signing_key(a, who: str) -> Path:
    """--key (a private key, or a .pub whose private half an SSH agent holds), else the volume's key."""
    kp = Path(a.key) if getattr(a, "key", None) else key_path(who)
    if not kp.is_file():
        raise SystemExit(f"agentic-register: no key for {who} at {kp}; agentic-register key new {who}, or --key <file>")
    if kp.suffix == ".pub" and not os.environ.get("SSH_AUTH_SOCK"):
        raise SystemExit("agentic-register: --key names a public key, so the private key must be in an SSH agent, "
                         "and SSH_AUTH_SOCK is not set")
    try:
        core.public_key(kp)
    except core.NoPublicKey as e:
        raise SystemExit(f"agentic-register: {e}")
    return kp


def _add(a, kind: str, data: dict) -> int:
    who = principal(a)
    kp = signing_key(a, who)
    try:
        i = adapters.add(adapters.DirStore(store_path(a)), kp, who, kind, data, anchors_of(a), checked=checked(),
                         register=selected(a)["name"], kinds=rtype(a).kinds, guard=guard_of(a))
    except core.Refused as r:
        emit(a, {"refused": r.code, "detail": r.detail}, f"agentic-register: refused, {r}")
        return 1
    emit(a, {"id": i}, i)
    return 0


def cmd_add(a) -> int:
    if a.data and a.file:
        raise SystemExit("agentic-register: give --data or --file, not both")
    if a.file:
        data = json.loads(Path(a.file).read_text())
    elif a.data:
        data = json.loads(a.data)
    else:
        data = {}
    if a.title:
        data["title"] = a.title
    if not isinstance(data, dict):
        raise SystemExit("agentic-register: the data is a JSON object")
    return _add(a, a.kind, data)


def cmd_roster(a) -> int:
    data: dict = {}
    if a.add_key:
        if not (a.principal and a.role):
            raise SystemExit("agentic-register: --add-key needs --principal <name> and --role agent "
                             "(or --role operator)")
        data["add"] = [{"key": a.add_key, "as": a.principal, "role": a.role}]
    if a.remove_key:
        data["remove"] = [{"key": a.remove_key}]
    if not data:
        raise SystemExit("agentic-register: give --add-key or --remove-key")
    return _add(a, "roster", data)


def cmd_rule(a) -> int:
    """An operator settles a fork by naming the entry to keep (SPEC.md, "Forks and rulings")."""
    led = read_ledger(a)
    keep = next((i for i in led.valid if i == a.keep or (len(a.keep) >= 12 and i.startswith(a.keep))), None)
    if keep is None:
        raise SystemExit(f"agentic-register: no valid entry {a.keep} in {selected(a)['name']}")
    if not any(keep in f for f in led.forks):
        raise SystemExit(f"agentic-register: {keep[:12]} is not part of a fork (agentic-register forks lists them)")
    return _add(a, "ruling", {"keep": keep})


def cmd_prune(a) -> int:
    """An operator lets a store leave out what a ruling ruled out (SPEC.md, "Pruning")."""
    led = read_ledger(a)
    ruling = next((i for i in led.valid if i == a.ruling or (len(a.ruling) >= 12 and i.startswith(a.ruling))), None)
    if ruling is None or led.valid[ruling].kind != "ruling":
        raise SystemExit(f"agentic-register: no valid ruling {a.ruling} in {selected(a)['name']}")
    out = core.ruled_out_by(led, ruling)
    if not out:
        raise SystemExit(f"agentic-register: ruling {ruling[:12]} settles no fork, so it rules nothing out")
    if a.ids:
        want = sorted({i.strip() for i in a.ids.split(",") if i.strip()})
        named = sorted(x for w in want for x in led.valid if x == w or (len(w) >= 12 and x.startswith(w)))
        if len(named) != len(want) or not set(named) <= set(out):
            raise SystemExit(f"agentic-register: only what ruling {ruling[:12]} ruled out can be pruned: "
                             + ", ".join(i[:12] for i in out))
        out = named
    kept_kinds = sorted({led.valid[i].kind for i in out} & set(core.UNIVERSAL))
    if kept_kinds:
        raise SystemExit(f"agentic-register: a {', '.join(kept_kinds)} entry is never pruned: the reader needs it")
    return _add(a, "prune", {"ruling": ruling, "pruned": out})


def cmd_forks(a) -> int:
    led = read_ledger(a)
    rows = []
    for n, f in enumerate(led.forks):
        members = []
        for i in f:
            e = led.valid[i]
            summary = e.data.get("title") or e.data.get("item") or e.kind
            members.append({"id": i, "principal": e.principal, "seq": e.seq, "at": e.at, "kind": e.kind,
                            "summary": str(summary)[:80],
                            "followed_by": sum(1 for x in led.valid.values() if x.key == e.key and x.seq > e.seq)})
        rows.append({"fork": n, "kept": led.rulings.get(n), "entries": members})
    lines = []
    for r in rows:
        state = f"ruled: kept {r['kept'][:12]}" if r["kept"] else "NOT RULED"
        lines.append(f"agentic-register: fork {r['fork']} of {r['entries'][0]['principal']} at seq {r['entries'][0]['seq']}, {state}")
        lines += [f"  {m['id'][:16]}  {m['at']}  {m['kind']:<7} {m['summary']}" for m in r["entries"]]
    if any(not r["kept"] for r in rows):
        lines.append("agentic-register: an operator keeps one: agentic-register rule --as <operator> --key <their .pub> --keep <id>")
    emit(a, rows, "\n".join(lines) or f"agentic-register: no forks in {selected(a)['name']}")
    return 0


def _summary(led: core.Ledger) -> dict:
    return {"valid": len(led.valid), "held": led.held, "refused": {i: list(c) for i, c in led.refused.items()},
            "forks": led.unruled_forks, "ruled_forks": [{"fork": f, "kept": led.rulings[n]} for n, f in enumerate(led.forks)
                                                         if n in led.rulings],
            "flags": led.flags, "heads": led.heads, "pruned": sorted(led.pruned), "still_there": sorted(led.still_there)}


def cmd_verify(a) -> int:
    led = read_ledger(a)
    wrong_prunes = sorted(i for i, fs in led.flags.items() if "prunes-not-ruled-out" in fs)
    bad = bool(led.refused or led.held or led.unruled_forks or led.still_there or wrong_prunes)
    s = _summary(led)
    s["ok"] = not bad
    lines = [f"agentic-register: {len(led.valid)} valid, {len(led.held)} held, {len(led.refused)} refused, "
             f"{len(led.unruled_forks)} fork(s), {len(led.rulings)} ruled, {len(led.pruned)} pruned, {len(led.flags)} flagged, "
             f"{len(led.heads)} head(s) in {store_path(a)}"]
    lines += [f"  refused {i[:16]}: {c}" + (f" ({d})" if d else "") for i, (c, d) in sorted(led.refused.items())]
    lines += [f"  held {i[:16]}: waiting for {', '.join(p[:12] for p in ps)}" for i, ps in sorted(led.held.items())]
    lines += [f"  fork: {', '.join(i[:12] for i in f)} (rule on it: agentic-register forks)" for f in led.unruled_forks]
    lines += [f"  pruned, still in the store: {i[:16]} (delete it: {i}.entry)" for i in sorted(led.still_there)]
    lines += [f"  prune {i[:16]} names entries that are not ruled out: do NOT delete them; an operator corrects it"
              for i in wrong_prunes]
    lines += [f"  flagged {i[:16]}: {', '.join(fs)}" for i, fs in sorted(led.flags.items())]
    emit(a, s, "\n".join(lines))
    return 1 if bad else 0


def cmd_sync(a) -> int:
    sink = adapters.DirStore(Path(a.to) if a.to else store_path(a))
    sources = [adapters.raws(adapters.DirStore(Path(f))) for f in a.source]
    c = checked()
    r = adapters.sync(sources, sink, anchors_of(a), c, selected(a)["name"], rtype(a).kinds, guard=guard_of(a))
    try:
        c.save()
    except OSError:
        pass
    guarded = sorted(i for i, (code, _) in r.refused.items() if code == "guarded")
    emit(a, {"put": r.put, "already": r.already, "held": r.held, "refused": {i: list(c) for i, c in r.refused.items()},
             "guarded": guarded},
         f"agentic-register: into {sink.path}: {r}" + (f" ({len(guarded)} by the guard)" if guarded else ""))
    return 1 if guarded else 0


def cmd_mirror(a) -> int:
    """Copy each way between a register's live store and its mirror: what the mirror has that the
    store lacks (an entry merged on main, a fresh volume), then what the store has that the mirror
    lacks. Only valid entries move, nothing is ever removed, and an entry a counted prune names is
    never copied back (SPEC.md, "Pruning")."""
    if a.all and a.store:
        raise SystemExit("agentic-register: mirror --all takes each register's own store; leave out --store")
    names = [r["name"] for r in registers() if r.get("mirror")] if a.all else [selected(a)["name"]]
    c = checked()
    rows = []
    for n in names:
        a.register = n
        m = mirror_path(a)
        if m is None:
            raise SystemExit(f"agentic-register: register {n} has no mirror; give it one in the registers option")
        store, mirror = adapters.DirStore(store_path(a)), adapters.DirStore(m)
        anchors, kinds, guard = anchors_of(a), rtype(a).kinds, guard_of(a)
        into_store = adapters.sync([adapters.raws(mirror)], store, anchors, c, n, kinds, guard=guard)
        into_mirror = adapters.sync([adapters.raws(store)], mirror, anchors, c, n, kinds, guard=guard)
        r = into_mirror.ledger
        guarded = sum(code == "guarded" for x in (into_store, into_mirror) for code, _ in x.refused.values())
        rows.append({"register": n, "store": str(store.path), "mirror": str(mirror.path),
                     "into_store": len(into_store.put), "into_mirror": len(into_mirror.put),
                     "held": len(r.held), "refused": len(r.refused), "guarded": guarded})
    try:
        c.save()
    except OSError:
        pass
    emit(a, rows, "\n".join(f"agentic-register: {x['register']:<12} {x['into_store']} into the store, "
                             f"{x['into_mirror']} into {x['mirror']}, {x['held']} held, {x['refused']} refused"
                             + (f", {x['guarded']} kept out by the guard" if x["guarded"] else "")
                             for x in rows) or "agentic-register: no register has a mirror")
    return 1 if any(x["guarded"] for x in rows) else 0


def cmd_show(a) -> int:
    led = read_ledger(a)
    text = rtype(a).render(led) if rtype(a).render is not None else adapters.render_markdown(led)
    if a.out:
        out = Path(a.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_name(out.name + ".tmp")
        tmp.write_text(text)
        os.replace(tmp, out)
        print(f"agentic-register: written {a.out}")
    else:
        sys.stdout.write(text)
    return 0


def cmd_query(a) -> int:
    led = read_ledger(a)
    db_path = home() / "index" / f"{selected(a)['name']}.db"
    adapters.write_sqlite(led, db_path, rtype(a).views, rtype(a).index)
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        rows = [dict(r) for r in db.execute(a.sql)]
    except sqlite3.Error as e:
        print(f"agentic-register: query failed: {e}", file=sys.stderr)
        return 1
    finally:
        db.close()
    print(json.dumps(rows, indent=2, sort_keys=True, default=str))
    return 0


def cmd_import(a) -> int:
    """Backfill records kept before the ledger (ledger/backfill.py). Importing twice adds nothing."""
    from . import backfill
    if a.todo:
        return _import_todo(a)
    if selected(a)["type"] != "ledger":
        raise SystemExit(f"agentic-register: --markdown and --runs backfill a ledger; {selected(a)['name']} is a {selected(a)['type']}")
    src = Path(a.markdown or a.runs)
    text = src.read_text()
    name = backfill.source_name(src)
    records, warned = backfill.markdown_scan(text, name) if a.markdown else (backfill.run_records(text, name), [])
    kind = "work" if a.markdown else "run"
    notes = "".join(f"\nagentic-register: {name}:{w['line']}: {w['detail']}" for w in warned)
    led = read_ledger(a)
    done = backfill.already(led)
    titles = {k: i for i in led.order for e in [led.valid[i]] if e.kind == "work"
              for k in backfill.title_keys(e.data, e.at)}
    todo = [d for d in records if d["backfill"]["sha256"] not in done]
    if a.dry_run:
        emit(a, {"source": name, "records": len(records), "new": len(todo), "already": len(records) - len(todo),
                 "warnings": warned},
             f"agentic-register: {name}: {len(records)} records, {len(todo)} to import, {len(records) - len(todo)} already in"
             + notes)
        return 0
    who = principal(a)
    kp = signing_key(a, who)
    store = adapters.DirStore(store_path(a))
    added = []
    c = checked()
    for d in todo:
        backfill.resolve_corrects([d], titles)
        try:
            i = adapters.add(store, kp, who, kind, d, anchors_of(a), checked=c,
                             register=selected(a)["name"], kinds=rtype(a).kinds, guard=guard_of(a))
        except core.Refused as r:
            emit(a, {"refused": r.code, "detail": r.detail, "line": d["backfill"]["line"], "imported": added,
                     "warnings": warned},
                 f"agentic-register: refused at {name}:{d['backfill']['line']}, {r}; {len(added)} imported before it"
                 + notes)
            return 1
        added.append(i)
        if kind == "work":
            titles.update({k: i for k in backfill.title_keys(d)})
    emit(a, {"source": name, "imported": added, "already": len(records) - len(todo), "warnings": warned},
         f"agentic-register: {name}: {len(added)} imported, {len(records) - len(todo)} already in" + notes)
    return 0


def _import_todo(a) -> int:
    """Backfill a TODO.md into a backlog register: an add per item, a tick per item done."""
    from . import backfill, backlog
    if selected(a)["type"] != "backlog":
        raise SystemExit(f"agentic-register: --todo backfills a backlog; {selected(a)['name']} is a {selected(a)['type']}")
    src = Path(a.todo)
    name = backfill.source_name(src)
    records = backlog.todo_records(src.read_text(), name)
    led = read_ledger(a)
    done = backlog.already(led)
    todo = [(k, d) for k, d in records if backlog.backfill_key(d) not in done]
    if a.dry_run:
        emit(a, {"source": name, "records": len(records), "new": len(todo)},
             f"agentic-register: {name}: {len(records)} records, {len(todo)} to import, {len(records) - len(todo)} already in")
        return 0
    who = principal(a)
    kp = signing_key(a, who)
    store = adapters.DirStore(store_path(a))
    added, c = [], checked()
    for kind, d in todo:
        try:
            added.append(adapters.add(store, kp, who, kind, d, anchors_of(a), checked=c,
                                      register=selected(a)["name"], kinds=rtype(a).kinds, guard=guard_of(a)))
        except core.Refused as r:
            emit(a, {"refused": r.code, "detail": r.detail, "line": d["backfill"]["line"], "imported": added},
                 f"agentic-register: refused at {name}:{d['backfill']['line']}, {r}; {len(added)} imported before it")
            return 1
    emit(a, {"source": name, "imported": added, "already": len(records) - len(todo)},
         f"agentic-register: {name}: {len(added)} imported, {len(records) - len(todo)} already in")
    return 0


def _roster_state(led: core.Ledger) -> tuple[dict[str, tuple[str, str]], set[str]]:
    """key -> (principal, role) added, and the keys removed, in a register's valid roster entries."""
    added, removed = {}, set()
    for i in led.order:
        e = led.valid[i]
        if e.kind == "roster":
            for x in e.data.get("add", []):
                added[x["key"]] = (x["as"], x["role"])
            for x in e.data.get("remove", []):
                removed.add(x["key"])
    return added, removed


def cmd_rekey(a) -> int:
    """New keys for agents whose key is lost (or, with --replace, to be replaced), and the roster
    entries that let them write, in every register (or --register), signed by one operator.
    A key that is still there and on the roster is left alone. A replaced key is removed from the
    rosters in the same entry: what it signed before stays valid; nothing it signs after is."""
    who = principal(a)
    op_key = signing_key(a, who)
    names = [a.register] if a.register else [r["name"] for r in registers()]
    report = []
    for p in a.principals:
        if not core.PRINCIPAL_RE.fullmatch(p):
            raise SystemExit(f"agentic-register: {p!r} is not a principal")
        kp = key_path(p)
        old = None
        if kp.is_file() and a.replace:
            old = core.public_key(kp)
            retired = home() / "keys" / "retired"
            retired.mkdir(parents=True, exist_ok=True)
            stamp = adapters.now().replace(":", "")
            for f in (kp, Path(str(kp) + ".pub")):
                if f.exists():   # a key whose .pub is gone is still retired, and still taken off the rosters
                    f.rename(retired / f"{f.name}.{stamp}")
        made = not kp.is_file()
        if made:
            kp.parent.mkdir(parents=True, exist_ok=True)
            os.chmod(kp.parent, 0o700)
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(kp)], check=True)
        new = core.public_key(kp)
        for name in names:
            a.register = name
            led = read_ledger(a)
            added, removed = _roster_state(led)
            known_as = {pr for k, (pr, _) in added.items() if k not in removed}
            if new in added and new not in removed and not old:
                report.append({"principal": p, "register": name, "done": "already on the roster"})
                continue
            if not (a.role or p in known_as or old):
                report.append({"principal": p, "register": name, "done": "skipped: not on this roster; give --role agent to add it"})
                continue
            role = a.role or next((r for k, (pr, r) in added.items() if pr == p), "agent")
            data = {"add": [{"key": new, "as": p, "role": role}]}
            if old and old in added and old not in removed:
                data["remove"] = [{"key": old}]
            try:
                adapters.add(adapters.DirStore(store_path(a)), op_key, who, "roster", data, anchors_of(a),
                             checked=checked(), register=name, kinds=rtype(a).kinds, guard=guard_of(a))
                report.append({"principal": p, "register": name,
                               "done": "added" + (", old key removed" if "remove" in data else "")})
            except core.Refused as r:
                report.append({"principal": p, "register": name, "done": f"refused: {r}"})
        report.append({"principal": p, "register": "-", "done": ("new key made" if made else "key kept")
                       + (" (the old one is in keys/retired/)" if old else "")})
    failed = any(x["done"].startswith("refused") for x in report)
    emit(a, report, "\n".join(f"agentic-register: {x['principal']:<10} {x['register']:<10} {x['done']}" for x in report))
    return 1 if failed else 0


def cmd_registers(a) -> int:
    rows = []
    for r in registers():
        a.register = r["name"]
        m = mirror_path(a)
        rows.append({"name": r["name"], "type": r["type"], "store": str(store_path(a)),
                     "entries": len(adapters.DirStore(store_path(a)).ids()), "mirror": str(m) if m else None,
                     "about": types.get(r["type"]).description})
    emit(a, rows, "\n".join(f"agentic-register: {x['name']:<12} {x['type']:<8} {x['entries']:>5} entries  {x['store']}"
                             + (f"  (mirror {x['mirror']})" if x["mirror"] else "") for x in rows))
    return 0


# ---------------------------------------------------------------- conversations (a messages register)

def _conversations(a):
    """Select a messages register (--register, else the first of type messages) and read it."""
    from . import messages
    if not getattr(a, "register", None):
        regs = [r for r in registers() if r["type"] == "messages"]
        if not regs:
            raise SystemExit("agentic-register: no register of type messages; add one to the registers option")
        a.register = regs[0]["name"]
    if selected(a)["type"] != "messages":
        raise SystemExit(f"agentic-register: {selected(a)['name']} is a {selected(a)['type']}, not a messages register")
    led = read_ledger(a)
    conv, _ = messages.project(led)
    return messages, conv


def _new_id(prefix: str) -> str:
    import secrets
    import time
    return f"{prefix}{time.time_ns():x}{secrets.token_hex(2)}"


def _csv(v: str | None) -> list[str]:
    return [x.strip() for x in (v or "").split(",") if x.strip()]


def cmd_threads(a) -> int:
    messages, conv = _conversations(a)
    who = principal(a)
    box = {r["thread"]: r for r in messages.inbox(conv, who)["threads"]}
    rows = []
    for t, x in conv["threads"].items():
        if who in x["members"]:
            r = box.get(t)
            rows.append({"thread": t, "title": x["title"], "kind": x["kind"], "parent": x["parent"],
                         "members": sorted(x["members"]), "messages": len(x["messages"]),
                         "unread": r["unread"] if r else 0, "unread_in_sub_threads": r["unread_in_sub_threads"] if r else 0})
    emit(a, rows, "\n".join(f"agentic-register: {r['thread']:<24} {r['kind']:<6} {r['unread']:>3} unread"
                             + (f" (+{r['unread_in_sub_threads']} in sub-threads)" if r["unread_in_sub_threads"] else "")
                             + (f"  under {r['parent']}" if r["parent"] else "") for r in rows)
         or f"agentic-register: {who} is in no thread")
    return 0


def cmd_thread(a) -> int:
    messages, conv = _conversations(a)
    who = principal(a)
    x = conv["threads"].get(a.thread)
    if x is None or who not in x["members"]:
        raise SystemExit(f"agentic-register: no thread {a.thread} that {who} is in")
    out = {"thread": a.thread, "title": x["title"], "kind": x["kind"], "parent": x["parent"], "from": x["from"],
           "members": sorted(x["members"]), "sub_threads": [c for c in x["children"] if who in conv["threads"][c]["members"]],
           "unread": messages.unread(conv, who, a.thread),
           "messages": [{"message_id": m["message_id"], "from": m["from"], "at": m["at"], "text": messages.text_of(m),
                         "parts": m["parts"], "reply_to": m["reply_to"], "mentions": m["mentions"],
                         "refs": messages.visible_refs(conv, who, m["refs"]), "task_id": m["task_id"]}
                        for m in x["messages"]],
           "tasks": [{"task": k["task"], "title": k["title"], "assignee": k["assignee"], "state": k["state"]}
                     for k in conv["tasks"].values() if k["thread"] == a.thread]}
    lines = [f"agentic-register: {out['title']} ({a.thread}, {out['kind']}: {', '.join(out['members'])})"]
    lines += [f"  {m['at']} {m['from']}: {m['text']}" + (f"  [re {m['reply_to']}]" if m["reply_to"] else "")
              for m in out["messages"]]
    lines += [f"  task {k['task']} ({k['state']}, for {k['assignee']}): {k['title']}" for k in out["tasks"]]
    lines += [f"  sub-thread: {c}" for c in out["sub_threads"]]
    emit(a, out, "\n".join(lines))
    if a.mark_read and x["messages"]:
        return _quiet_add(a, "read", {"thread": a.thread, "upto": x["messages"][-1]["message_id"]})
    return 0


def _quiet_add(a, kind: str, data: dict) -> int:
    """Write an entry without printing its id (for a write that follows a read's output)."""
    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = _add(argparse.Namespace(**{**vars(a), "json": False}), kind, data)
    if code:
        sys.stderr.write(buf.getvalue())
    return code


def notice_line(box: dict) -> str:
    """One line for a turn hook: what is unread and which tasks are open, or nothing."""
    parts = []
    for r in box["threads"]:
        bit = f"{r['unread']} unread in {r['thread']}" if r["unread"] else f"0 unread in {r['thread']}"
        if r["unread_in_sub_threads"]:
            bit += f" (+{r['unread_in_sub_threads']} in sub-threads)"
        parts.append(bit)
    if box["tasks"]:
        k = box["tasks"][0]
        more = f" (+{len(box['tasks']) - 1} more)" if len(box["tasks"]) > 1 else ""
        parts.append(f"{len(box['tasks'])} open task{'s' if len(box['tasks']) > 1 else ''}: {k['title']} from {k['from']}{more}")
    if not parts:
        return ""
    return f"Mail for {box['principal']}: " + "; ".join(parts) + ". (agentic-register inbox)"


def cmd_inbox(a) -> int:
    if getattr(a, "notice", False):
        # For a turn hook: one line or nothing, and never a failure that breaks a turn.
        try:
            messages, conv = _conversations(a)
            line = notice_line(messages.inbox(conv, principal(a)))
        except (SystemExit, Exception) as e:  # noqa: BLE001
            print(f"agentic-register: no notice: {e}", file=sys.stderr)
            return 0
        if line:
            print(line)
        return 0
    messages, conv = _conversations(a)
    box = messages.inbox(conv, principal(a))
    lines = [f"agentic-register: {box['principal']}: {box['unread']} unread"]
    lines += [f"  {r['thread']}: {r['unread']}" + (f" (+{r['unread_in_sub_threads']} in sub-threads)" if r["unread_in_sub_threads"] else "")
              + (f", last from {r['last']['from']}: {r['last']['text'][:60]}" if r["last"] else "") for r in box["threads"]]
    lines += [f"  task {k['task']} ({k['state']}, from {k['from']}): {k['title']}" for k in box["tasks"]]
    emit(a, box, "\n".join(lines))
    return 0


def cmd_new_thread(a) -> int:
    _conversations(a)
    data = {"thread": a.thread, "kind": a.kind}
    if a.members:
        data["members"] = _csv(a.members)
    for f in ("title", "parent"):
        if getattr(a, f):
            data[f] = getattr(a, f)
    if a.from_entry:
        data["from"] = a.from_entry
    return _add(a, "thread", data)


def _member_of(a, conv, verb: str) -> None:
    """Refuse to write into a thread that does not exist or that the writer is not in: a reader
    would keep the entry but never show it, so it would be lost to every member."""
    who = principal(a)
    x = conv["threads"].get(a.thread)
    if x is None:
        raise SystemExit(f"agentic-register: no thread {a.thread}; open it first with new-thread, then {verb}")
    if who not in x["members"]:
        raise SystemExit(f"agentic-register: {who} is not in thread {a.thread}, so no member would see it; "
                         f"a member invites {who} first")


def cmd_send(a) -> int:
    _, conv = _conversations(a)
    _member_of(a, conv, "send")
    parts = []
    if a.text:
        parts.append({"kind": "text", "text": a.text})
    if a.data:
        parts.append({"kind": "data", "data": json.loads(a.data)})
    if not parts:
        raise SystemExit("agentic-register: give --text, --data or both")
    data = {"thread": a.thread, "message_id": a.message_id or _new_id("m"), "parts": parts}
    if a.reply_to:
        data["reply_to"] = a.reply_to
    if a.mention:
        data["mentions"] = _csv(a.mention)
    if a.ref:
        data["refs"] = [dict(zip(("thread", "message_id"), r.split(":", 1))) for r in a.ref]
    if a.task_id:
        data["task_id"] = a.task_id
    return _add_reporting(a, "message", data, {"message_id": data["message_id"]})


def _write(a, kind: str, data: dict) -> tuple[int, dict]:
    """Write an entry without printing: (exit code, {"id"} or {"refused", "detail"})."""
    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = _add(argparse.Namespace(**{**vars(a), "json": True}), kind, data)
    return code, json.loads(buf.getvalue() or "{}")


def _add_reporting(a, kind: str, data: dict, extra: dict) -> int:
    """Write an entry; report its id and the ids the caller will need next (message_id, task)."""
    code, result = _write(a, kind, data)
    if code:
        emit(a, result, f"agentic-register: refused, {result.get('refused')}: {result.get('detail')}")
        return code
    emit(a, {**result, **extra}, " ".join(str(v) for v in extra.values()))
    return 0


def cmd_mark_read(a) -> int:
    messages, conv = _conversations(a)
    x = conv["threads"].get(a.thread)
    if x is None or not x["messages"]:
        raise SystemExit(f"agentic-register: no message to mark read in {a.thread}")
    return _add(a, "read", {"thread": a.thread, "upto": a.upto or x["messages"][-1]["message_id"]})


def cmd_invite(a) -> int:
    _conversations(a)
    return _add(a, "invite", {"thread": a.thread, "principal": a.principal})


def cmd_leave(a) -> int:
    _conversations(a)
    return _add(a, "leave", {"thread": a.thread})


def cmd_tasks(a) -> int:
    messages, conv = _conversations(a)
    who = principal(a)
    rows = [{"task": k["task"], "thread": k["thread"], "title": k["title"], "assignee": k["assignee"],
             "from": k["created_by"], "state": k["state"], "at": k["at"]}
            for k in conv["tasks"].values()
            if (who in (k["assignee"], k["created_by"])) and (a.all or k["state"] not in messages.TERMINAL)]
    emit(a, rows, "\n".join(f"agentic-register: {r['task']:<20} {r['state']:<15} {r['from']} -> {r['assignee']}: {r['title']}"
                             for r in rows) or "agentic-register: no open tasks")
    return 0


def cmd_ask(a) -> int:
    """A request: a message to the thread and an A2A task for the assignee, in one go."""
    messages, conv = _conversations(a)
    _member_of(a, conv, "ask")
    mid, tid = _new_id("m"), a.task or _new_id("t")
    for kind, data in (("message", {"thread": a.thread, "message_id": mid, "task_id": tid,
                                    "parts": [{"kind": "text", "text": a.text or a.title}]}),
                       ("task", {"task": tid, "thread": a.thread, "assignee": a.to, "title": a.title, "message_id": mid})):
        code, result = _write(a, kind, data)
        if code:
            emit(a, result, f"agentic-register: refused, {result.get('refused')}: {result.get('detail')}")
            return code
    emit(a, {"task": tid, "message_id": mid}, f"{tid} {mid}")
    return 0


def cmd_task_status(a) -> int:
    _conversations(a)
    data = {"task": a.task, "state": a.state}
    if a.text:
        data["text"] = a.text
    return _add(a, "status", data)


def cmd_watch(a) -> int:
    """The change feed: every valid entry new since a cursor, one JSON line each, then the next cursor.

    Without --follow it prints what is new and stops. With --follow it goes on, checking the store
    every --interval seconds, for --for seconds (default: until stopped).
    """
    import time
    cursor = [c for c in (a.since or "").split(",") if c]
    name = selected(a)["name"]
    deadline = None if a.for_ is None else time.monotonic() + a.for_
    while True:
        led = read_ledger(a)
        new = adapters.since(led, cursor)
        for i in new:
            print(json.dumps(adapters.feed_line(led, i, name), sort_keys=True), flush=True)
        if new or not cursor or not a.follow:
            cursor = led.heads
            print(json.dumps({"cursor": ",".join(cursor)}), flush=True)
        if not a.follow or (deadline is not None and time.monotonic() >= deadline):
            return 0
        time.sleep(max(0.2, a.interval))


def cmd_mcp(a) -> int:
    from . import mcp
    return mcp.serve()


# ---------------------------------------------------------------- arguments

def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="agentic-register", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    def command(name: str, fn, help_: str, store=True, writer=False) -> argparse.ArgumentParser:
        c = sub.add_parser(name, help=help_, description=help_)
        c.set_defaults(fn=fn)
        c.add_argument("--json", action="store_true", help="output for machines")
        if store:
            c.add_argument("--register", help="the register to work on (default: $AGENTIC_REGISTER_DEFAULT, else the first)")
            c.add_argument("--store", help="the store folder (default: the register's)")
            c.add_argument("--anchors", help="the anchors file")
        if writer:
            c.add_argument("--as", dest="as_", help="the principal who writes (or AGENTIC_REGISTER_AS)")
            c.add_argument("--key", help="sign with this key file instead of the volume's: a private key, "
                                         "or a .pub whose private half an SSH agent holds (an operator's key)")
        return c

    command("version", cmd_version, "what is installed, and which binary runs it", store=False)
    command("check", cmd_check, "say what is ready and what is not; exit 1 when not ready", writer=True)
    command("setup", cmd_setup, "prepare the home folder and the anchors file; register the MCP server")
    k = command("key", cmd_key, "make or show a principal's signing key", store=False)
    k.add_argument("action", choices=["new", "show"])
    k.add_argument("principal")
    c = command("add", cmd_add, "sign an entry as the next in your chain and put it in the store", writer=True)
    c.add_argument("--kind", default="work", help="work (default), run, or another kind")
    c.add_argument("--title", help="the title of a work entry")
    c.add_argument("--data", help="the entry's data, a JSON object")
    c.add_argument("--file", help="a file holding the entry's data")
    r = command("roster", cmd_roster, "an operator adds or removes a key", writer=True)
    r.add_argument("--add-key")
    r.add_argument("--principal")
    r.add_argument("--role", choices=["operator", "agent"])
    r.add_argument("--remove-key")
    command("verify", cmd_verify, "check every entry in the store; exit 1 on a refusal, a held entry or a fork")
    s = command("sync", cmd_sync, "merge entries from other store folders into this one (or --to)")
    s.add_argument("--from", dest="source", action="append", required=True, help="a store folder to read")
    s.add_argument("--to", help="the store folder to write (default: the store)")
    mi = command("mirror", cmd_mirror, "copy each way between a register's live store and its mirror; only adds")
    mi.add_argument("--all", action="store_true", help="every register that has a mirror")
    sh = command("show", cmd_show, "the ledger as Markdown, to standard output or --out")
    sh.add_argument("--out")
    q = command("query", cmd_query, "run read-only SQL on a freshly built index (tables: entries, parents, heads, flags, forks, held, refused; views: costs, items)")
    q.add_argument("sql")
    im = command("import", cmd_import, "backfill records kept before the register, marked as backfill: --markdown <ledger.md> or --runs <runs.jsonl> (a ledger), --todo <TODO.md> (a backlog)", writer=True)
    g = im.add_mutually_exclusive_group(required=True)
    g.add_argument("--markdown", help="a Markdown ledger (### YYYY-MM-DD <title>, then - **Field:** lines)")
    g.add_argument("--runs", help="model runs, one JSON object a line (ts, member, model, outcome, cost_usd, tokens)")
    g.add_argument("--todo", help="a TODO.md, into a backlog register (- [ ] **`id`** [owner: x]: text, under ## sections)")
    im.add_argument("--dry-run", action="store_true", help="say what would be imported; write nothing")
    rk = command("rekey", cmd_rekey, "an operator gives agents new keys (lost, or --replace) and adds them to every register's roster (or --register)", writer=True)
    rk.add_argument("principals", nargs="+", help="the agents, for example butler scribe")
    rk.add_argument("--replace", action="store_true", help="replace a key that is still there; the old one is removed from the rosters")
    rk.add_argument("--role", choices=["agent", "operator"], help="the role, for a principal not yet on a roster")
    command("forks", cmd_forks, "list the forks (two entries of one key with one seq), each with its entries and whether it is ruled")
    ru = command("rule", cmd_rule, "an operator settles a fork: --keep <entry id> (the side the key goes on from)", writer=True)
    ru.add_argument("--keep", required=True, help="the entry to keep: its id, or its first 12 characters or more")
    pr = command("prune", cmd_prune, "an anchor lets a store leave out what a ruling ruled out: --ruling <entry id>", writer=True)
    pr.add_argument("--ruling", required=True, help="the ruling: its id, or its first 12 characters or more")
    pr.add_argument("--ids", help="only these of what it ruled out, comma-separated (default: all of it)")
    command("registers", cmd_registers, "list the registers: name, type, store, how many entries", store=False)
    th = command("threads", cmd_threads, "a messages register: the threads you are in, with unread counts", writer=True)
    t1 = command("thread", cmd_thread, "a messages register: one thread's messages, members, sub-threads and tasks", writer=True)
    t1.add_argument("thread")
    t1.add_argument("--mark-read", action="store_true", help="also move your read marker to its last message")
    ib = command("inbox", cmd_inbox, "a messages register: what is unread for you, and your open tasks", writer=True)
    ib.add_argument("--notice", action="store_true",
                    help="one line for a turn hook (or nothing); never fails: a problem goes to stderr, exit 0")
    nt = command("new-thread", cmd_new_thread, "a messages register: start a thread (group or direct), or a sub-thread", writer=True)
    nt.add_argument("thread", help="its id, a plain id")
    nt.add_argument("--kind", choices=["group", "direct"], default="group")
    nt.add_argument("--members", help="principals, comma-separated (you are always one); a sub-thread without them takes its parent's")
    nt.add_argument("--title")
    nt.add_argument("--parent", help="the thread this one branches off")
    nt.add_argument("--from-entry", dest="from_entry", help="the entry id of the parent's message it branches from")
    se = command("send", cmd_send, "a messages register: post a message to a thread", writer=True)
    se.add_argument("--thread", required=True)
    se.add_argument("--text")
    se.add_argument("--data", help="a data part, a JSON value")
    se.add_argument("--message-id", dest="message_id", help="default: a new one")
    se.add_argument("--reply-to", dest="reply_to", help="the message_id it answers")
    se.add_argument("--mention", help="principals, comma-separated")
    se.add_argument("--ref", action="append", help="a thread it is about, thread or thread:message_id (repeatable)")
    se.add_argument("--task-id", dest="task_id", help="the task it belongs to")
    mr = command("mark-read", cmd_mark_read, "a messages register: move your read marker (default: to the last message)", writer=True)
    mr.add_argument("--thread", required=True)
    mr.add_argument("--upto", help="a message_id")
    iv = command("invite", cmd_invite, "a messages register: a member invites a principal to a thread", writer=True)
    iv.add_argument("--thread", required=True)
    iv.add_argument("--principal", required=True)
    lv = command("leave", cmd_leave, "a messages register: leave a thread", writer=True)
    lv.add_argument("--thread", required=True)
    tk = command("tasks", cmd_tasks, "a messages register: tasks you asked for or were given; open ones unless --all", writer=True)
    tk.add_argument("--all", action="store_true")
    ak = command("ask", cmd_ask, "a messages register: ask a member for something, as a message and an A2A task", writer=True)
    ak.add_argument("--thread", required=True)
    ak.add_argument("--to", required=True, help="the assignee")
    ak.add_argument("--title", required=True)
    ak.add_argument("--text", help="the request in full (default: the title)")
    ak.add_argument("--task", help="the task id (default: a new one)")
    ts = command("task-status", cmd_task_status, "a messages register: move a task on (the assignee), or cancel it (its creator)", writer=True)
    ts.add_argument("--task", required=True)
    ts.add_argument("--state", required=True, choices=["working", "input_required", "auth_required", "completed", "failed",
                                                        "canceled", "rejected"])
    ts.add_argument("--text")
    wa = command("watch", cmd_watch, "the change feed: entries new since a cursor, one JSON line each, then the next cursor")
    wa.add_argument("--since", help="the cursor a previous watch printed (heads, comma-separated); none: everything")
    wa.add_argument("--follow", action="store_true", help="keep going, printing new entries as they arrive")
    wa.add_argument("--interval", type=float, default=2.0, help="with --follow: seconds between checks (default 2)")
    wa.add_argument("--for", dest="for_", type=float, help="with --follow: stop after this many seconds")
    command("mcp", cmd_mcp, "serve the tools over MCP on standard input and output", store=False)
    return p


def main(argv: list[str] | None = None) -> int:
    a = parser().parse_args(argv)
    try:
        return a.fn(a)
    except ValueError as e:
        print(f"agentic-register: {e}", file=sys.stderr)
        return 1
