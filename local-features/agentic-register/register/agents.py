"""The `agents` register type: the agent registry (SPEC.md, "The agents type").

Each agent describes itself in an `agent` entry: a whole record that replaces its last one. The
record is in two parts:

    record   an OASF 1.1.0 agent record (AGNTCY's Open Agentic Schema Framework): name, version,
             schema_version, description, authors, created_at, skills; domains, locators and
             modules where it has them. Pure OASF, so it can be published to an agent directory.
    aof      what OASF has no field for: the principal it writes as, its theme name, the folders
             it owns, the command that starts it, its model.

`authors` holds handles only, never a person's name or an email address (the check refuses
anything but a plain id). An agent writes only its own record: one written as another principal is
flagged `not-own-record` and ignored. Trust comes from the register's roster, so an operator
removes an agent by removing its key; `retire` is the agent's own statement that it has stopped.

    two records of one agent written at the same time, different   concurrent-update (the later shows)
    a record or a retire for another principal                     not-own-record    (ignored)
"""
from __future__ import annotations

import json
import re

from . import core

OASF_VERSION = "1.1.0"
HANDLE_RE = core.PRINCIPAL_RE
SEMVER_RE = re.compile(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?")


def _need(ok, what: str) -> None:
    if not ok:
        raise core.Refused("bad-field", what)


def _str(v) -> bool:
    return isinstance(v, str) and bool(v.strip())


def _named_list(v, what: str) -> None:
    _need(isinstance(v, list) and all(isinstance(x, dict) and _str(x.get("name")) for x in v),
          f"{what}: a list of objects, each with a name")


def check_record(r) -> None:
    """The OASF 1.1.0 record's required fields, and the shapes this register relies on."""
    _need(isinstance(r, dict), "agent.record: an object")
    for f in ("name", "description"):
        _need(_str(r.get(f)), f"agent.record.{f}")
    _need(isinstance(r.get("version"), str) and SEMVER_RE.fullmatch(r["version"]), "agent.record.version: semver")
    _need(r.get("schema_version") == OASF_VERSION, f"agent.record.schema_version: {OASF_VERSION}")
    a = r.get("authors")
    _need(isinstance(a, list) and a and all(isinstance(x, str) and HANDLE_RE.fullmatch(x) for x in a),
          "agent.record.authors: handles only ([a-z0-9][a-z0-9_.-]*), never a name or an email address")
    _need(isinstance(r.get("created_at"), str) and core.AT_RE.fullmatch(r["created_at"]),
          "agent.record.created_at: YYYY-MM-DDTHH:MM:SSZ")
    _named_list(r.get("skills"), "agent.record.skills")
    for f in ("domains", "locators", "modules"):
        if f in r:
            _need(isinstance(r[f], list) and all(isinstance(x, dict) for x in r[f]), f"agent.record.{f}: a list of objects")
    if "domains" in r:
        _named_list(r["domains"], "agent.record.domains")


def check_aof(x) -> None:
    _need(isinstance(x, dict), "agent.aof: an object")
    _need(isinstance(x.get("principal"), str) and core.PRINCIPAL_RE.fullmatch(x["principal"]), "agent.aof.principal")
    for f in ("theme", "start", "model", "role"):
        _need(f not in x or _str(x[f]), f"agent.aof.{f}: a string")
    _need("owns" not in x or (isinstance(x["owns"], list) and all(_str(p) for p in x["owns"])),
          "agent.aof.owns: a list of paths")


def _agent(d: dict) -> None:
    _need(set(d) >= {"record", "aof"}, "agent: {record, aof}")
    check_record(d["record"])
    check_aof(d["aof"])


def _retire(d: dict) -> None:
    _need(isinstance(d.get("principal"), str) and core.PRINCIPAL_RE.fullmatch(d["principal"]), "retire.principal")
    _need("reason" not in d or _str(d["reason"]), "retire.reason: a string")


KINDS = {"agent": _agent, "retire": _retire}


def project(led: core.Ledger) -> tuple[dict, dict[str, list[str]]]:
    """(the registry, flags): {principal: {"record", "aof", "retired", "entry", "at", "updates"}}."""
    from .backlog import ancestors
    anc = ancestors(led)
    flags: dict[str, list[str]] = {}

    def flag(i: str, what: str) -> None:
        if what not in flags.setdefault(i, []):
            flags[i].append(what)

    agents: dict[str, dict] = {}
    updates: dict[str, list[tuple[str, str]]] = {}
    for i in led.order:
        e = led.valid[i]
        if e.kind not in KINDS:
            continue
        who = e.data["aof"]["principal"] if e.kind == "agent" else e.data["principal"]
        if who != e.principal:
            flag(i, "not-own-record")
            continue
        if e.kind == "retire":
            if who in agents:
                agents[who]["retired"] = e.data.get("reason", True)
            continue
        body = json.dumps({"record": e.data["record"], "aof": e.data["aof"]}, sort_keys=True)
        for j, other in updates.get(who, []):
            if other != body and j not in anc[i] and i not in anc[j]:
                flag(i, "concurrent-update")
                flag(j, "concurrent-update")
        updates.setdefault(who, []).append((i, body))
        prev = agents.get(who, {})
        agents[who] = {"record": e.data["record"], "aof": e.data["aof"], "retired": False, "entry": i, "at": e.at,
                       "updates": prev.get("updates", 0) + 1}
    return agents, flags


def index(db, led: core.Ledger) -> None:
    """The registry as tables: agents (one row per principal) and agent_skills."""
    agents, _ = project(led)
    db.executescript("""
        CREATE TABLE agents (principal TEXT PRIMARY KEY, name TEXT, version TEXT, theme TEXT, description TEXT,
                             owns TEXT, start TEXT, model TEXT, retired INTEGER, updated_at TEXT, entry TEXT,
                             record TEXT);
        CREATE TABLE agent_skills (principal TEXT, skill TEXT);
        CREATE VIEW active_agents AS SELECT * FROM agents WHERE retired = 0 ORDER BY principal;
    """)
    for p, a in sorted(agents.items()):
        r, x = a["record"], a["aof"]
        db.execute("INSERT INTO agents VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                   (p, r["name"], r["version"], x.get("theme"), r["description"], json.dumps(x.get("owns", [])),
                    x.get("start"), x.get("model"), int(bool(a["retired"])), a["at"], a["entry"],
                    json.dumps(r, sort_keys=True)))
        db.executemany("INSERT INTO agent_skills VALUES (?,?)", [(p, s["name"]) for s in r["skills"]])


def render(led: core.Ledger) -> str:
    agents, flags = project(led)
    out = ["# Agents", "", "Generated from the agents register; do not edit.", ""]
    if flags:
        out += ["## Needs a person", ""]
        out += [f"- {', '.join(fs)}: `{i[:12]}` by {led.valid[i].principal}" for i, fs in sorted(flags.items())]
        out.append("")
    out += ["| Principal | Name | Version | Owns | Start | Skills |", "|---|---|---|---|---|---|"]
    for p, a in sorted(agents.items()):
        r, x = a["record"], a["aof"]
        name = r["name"] + (f" ({x['theme']})" if x.get("theme") else "") + (", retired" if a["retired"] else "")
        out.append(f"| `{p}` | {name} | {r['version']} | {', '.join(f'`{o}`' for o in x.get('owns', []))} | "
                   f"{('`' + x['start'] + '`') if x.get('start') else ''} | {', '.join(s['name'] for s in r['skills'])} |")
    return "\n".join(out).rstrip() + "\n"
