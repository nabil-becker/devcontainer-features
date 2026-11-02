"""Register types: what the entries of a register may say, and how they are viewed (SPEC.md, "Registers").

A register is a name, a type and a store. The type gives the kinds and their checks (`roster` is in
every register, from the core), the index's extra views, and the Markdown rendering of an entry.

    ledger   one entry per unit of work (`work`), per model run (`run`) and per merge (`merge`); views costs, items, merges
    messages conversations and requests between agents (A2A 1.0 shaped); never stored in git
    agents   the agent registry: one OASF 1.1.0 record per agent, written by itself
    backlog  changes to items (add, edit, tick, reopen, move, note), and the backlog they add up to
    log      any kind, its data unchecked: a register for records that have no type yet
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

from . import agents, backlog, core, messages

LEDGER_VIEWS = """
CREATE VIEW costs AS
  SELECT id, at, principal, kind, json_extract(data, '$.cost.usd_micro') AS usd_micro,
         COALESCE(json_extract(data, '$.member'), principal) AS who
  FROM entries WHERE json_extract(data, '$.cost') IS NOT NULL;
CREATE VIEW items AS
  SELECT e.id, e.at, json_extract(e.data, '$.title') AS title,
         COALESCE(json_extract(e.data, '$.agent'), e.principal) AS agent,
         json_extract(e.data, '$.item') AS item, json_extract(e.data, '$.pr') AS pr,
         json_extract(e.data, '$.started_at') AS started_at, json_extract(e.data, '$.merged_at') AS merged_at,
         ROUND((julianday(json_extract(e.data, '$.merged_at')) - julianday(json_extract(e.data, '$.started_at'))) * 1440, 1)
           AS lead_minutes,
         json_extract(e.data, '$.conflicts') AS conflicts, json_extract(e.data, '$.checks_red') AS checks_red,
         json_extract(e.data, '$.cost.usd_micro') AS usd_micro,
         EXISTS (SELECT 1 FROM entries c WHERE c.kind = 'work' AND json_extract(c.data, '$.corrects') = e.id) AS corrected,
         json_extract(e.data, '$.backfill') IS NOT NULL AS backfill
  FROM entries e WHERE e.kind = 'work';
CREATE VIEW merges AS
  SELECT e.id, e.at, e.principal, json_extract(e.data, '$.pr') AS pr,
         json_extract(e.data, '$.merge_sha') AS merge_sha, json_extract(e.data, '$.patch_id') AS patch_id,
         json_extract(e.data, '$.base_sha') AS base_sha, json_extract(e.data, '$.merged_at') AS merged_at,
         json_extract(e.data, '$.corrects') AS corrects, json_extract(e.data, '$.reason') AS reason,
         NOT EXISTS (SELECT 1 FROM flags f WHERE f.id = e.id AND f.flag = 'superseded') AS current
  FROM entries e WHERE e.kind = 'merge';
"""


@dataclass(frozen=True)
class RegisterType:
    name: str
    kinds: dict[str, Callable[[dict], None]] = field(default_factory=dict)
    views: str = ""
    description: str = ""
    project: Callable | None = None   # ledger -> (state, flags): what the entries add up to
    index: Callable | None = None     # (sqlite connection, ledger) -> None: extra tables
    render: Callable | None = None    # ledger -> Markdown, in place of the entry-by-entry view
    outside_git: bool = False         # its store must not be inside a git repository


TYPES: dict[str, RegisterType] = {
    "ledger": RegisterType("ledger", dict(core.LEDGER_KINDS), LEDGER_VIEWS,
                           "one entry per unit of work, per model run and per merge"),
    "backlog": RegisterType("backlog", dict(backlog.KINDS), "", "changes to items, and the backlog they add up to",
                            project=backlog.project, index=backlog.index, render=backlog.render),
    "agents": RegisterType("agents", dict(agents.KINDS), "", "the agent registry: an OASF 1.1.0 record per agent",
                           project=agents.project, index=agents.index, render=agents.render),
    "messages": RegisterType("messages", dict(messages.KINDS), "", "conversations and requests between agents, A2A shaped",
                             project=messages.project, index=messages.index, render=messages.render, outside_git=True),
    "log": RegisterType("log", {}, "", "any kind, its data unchecked"),
}


def get(name: str) -> RegisterType:
    if name not in TYPES:
        raise ValueError(f"no register type {name!r}; the types are {', '.join(sorted(TYPES))}")
    return TYPES[name]
