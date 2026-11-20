"""The participant list (E4 of the participant component, ADR-0061) and facilitator.yml.

`.devcontainer/participants.yml` (PARTICIPANTS_FILE), or its alias `.devcontainer/agents.yml`
(AGENTS_FILE): the participant component's one list, under `participants:` or `agents:`. The keys
are the component's (`name`, `cli` and `kind` required; `folder`, `args`, `lifecycle`, `identity`,
`lease`, `definition`, `default`, `session-name`) and the three the facilitator adds:
`attachment` (mcp | pump), `description` and `skills`. The component's own reader warns on those
three as unknown keys until it learns them; it does not refuse them.

`.devcontainer/facilitator.yml` (FACILITATOR_FILE): the application's own settings, under
`facilitator:`: `humans` (the people, each attached over MCP with their own token; default [you]), `fallback` (the participant that
gets what is addressed to no one in a group), `model` (read and shown; no model is used before
slice 6)."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from . import yamlite

HANDLE_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
RESERVED = ("facilitator", "all")
COMPONENT_KEYS = ("name", "cli", "kind", "folder", "args", "lifecycle", "identity", "lease", "definition",
                  "default", "session-name")
FACILITATOR_KEYS = ("attachment", "description", "skills")
ATTACHMENTS = ("mcp", "pump")


class ListError(ValueError):
    pass


@dataclass
class Participant:
    name: str
    cli: str
    kind: str
    attachment: str = "mcp"
    description: str = ""
    skills: list[str] = field(default_factory=list)
    definition: str = ""
    args: list[str] = field(default_factory=list)
    line: int = 0

    def json(self) -> dict:
        return {"name": self.name, "cli": self.cli, "kind": self.kind, "attachment": self.attachment,
                "description": self.description, "skills": list(self.skills), "definition": self.definition}


@dataclass
class FacilitatorConfig:
    humans: list[str] = field(default_factory=lambda: ["you"])
    fallback: str | None = None
    model: dict | None = None


def _text(v) -> str:
    return "" if v is None else str(v)


def parse_participants(text: str, where: str) -> tuple[list[Participant], list[str]]:
    """(participants, warnings). Raises ListError naming every problem with its line."""
    try:
        doc = yamlite.parse(text, where)
    except yamlite.YamlError as e:
        raise ListError(str(e)) from None
    if not isinstance(doc, dict):
        raise ListError(f"{where}: expected participants: (or agents:) at the top level")
    warnings, errors = [], []
    keys = [k for k in ("participants", "agents") if k in doc]
    if not keys:
        raise ListError(f"{where}: no participants: (or agents:) list in the file")
    if len(keys) == 2:
        raise ListError(f"{where}: both participants: and agents: (one list, not two)")
    for k in doc:
        if k not in ("participants", "agents"):
            warnings.append(f"{where}: unknown top-level key '{k}' (ignored)")
    items = doc[keys[0]] or []
    if not isinstance(items, list):
        raise ListError(f"{where}: {keys[0]} must be a list of entries, one '- name: ...' each")
    lines = _entry_lines(text)
    out: list[Participant] = []
    for n, it in enumerate(items, 1):
        at = f"{where}:{lines[n - 1] if n - 1 < len(lines) else '?'}: entry {n}"
        if not isinstance(it, dict):
            errors.append(f"{at}: expected '- name: ...'")
            continue
        for k in it:
            if k not in COMPONENT_KEYS + FACILITATOR_KEYS:
                warnings.append(f"{at}: unknown key '{k}' (ignored)")
        missing = [k for k in ("name", "cli", "kind") if not it.get(k)]
        if missing:
            errors.append(f"{at}: has no {', '.join(missing)} (name, cli and kind are required)")
            continue
        name = _text(it["name"])
        if not HANDLE_RE.fullmatch(name):
            errors.append(f"{at}: name '{name}' must be lowercase letters, digits, - and _ (it is a principal in "
                          "the record, which is lowercase)")
            continue
        if name in RESERVED:
            errors.append(f"{at}: name '{name}' is reserved")
            continue
        if any(p.name == name for p in out):
            errors.append(f"{at}: name '{name}' is already used")
            continue
        kind = _text(it["kind"])
        if kind not in ("resident", "on-demand"):
            errors.append(f"{at}: kind '{kind}' is neither resident nor on-demand")
            continue
        att = _text(it.get("attachment") or "mcp")
        if att not in ATTACHMENTS:
            errors.append(f"{at}: attachment '{att}' is neither mcp nor pump")
            continue
        if att == "pump":
            warnings.append(f"{at}: attachment pump is not in this version (the pump is a later slice); "
                            "it is listed, and gets no turns until it attaches over MCP")
        skills = it.get("skills") or []
        if isinstance(skills, str):
            skills = [skills]
        if not isinstance(skills, list) or not all(isinstance(s, str) and s for s in skills):
            errors.append(f"{at}: skills must be a list of words: skills: [humour]")
            continue
        args = it.get("args") or []
        args = args if isinstance(args, list) else str(args).split()
        out.append(Participant(name, _text(it["cli"]), kind, att, _text(it.get("description")), list(skills),
                               _text(it.get("definition")), [str(a) for a in args], lines[n - 1] if n - 1 < len(lines) else 0))
    if errors:
        raise ListError("\n".join(errors))
    return out, warnings


def _entry_lines(text: str) -> list[int]:
    """The line of each list entry (for messages): lines whose first non-space is '-' at the list's indent."""
    out, ind = [], None
    for n, raw in enumerate(text.splitlines(), 1):
        s = raw.lstrip(" ")
        if s.startswith("-") and (s == "-" or s.startswith("- ")) and not s.startswith("---"):
            i = len(raw) - len(s)
            if ind is None:
                ind = i
            if i == ind:
                out.append(n)
    return out


def parse_facilitator(text: str, where: str, names: list[str]) -> tuple[FacilitatorConfig, list[str]]:
    try:
        doc = yamlite.parse(text, where) or {}
    except yamlite.YamlError as e:
        raise ListError(str(e)) from None
    warnings: list[str] = []
    if not isinstance(doc, dict) or not isinstance(doc.get("facilitator", {}), (dict, type(None))):
        raise ListError(f"{where}: expected facilitator: with key: value lines below it")
    f = doc.get("facilitator") or {}
    cfg = FacilitatorConfig()
    for k, v in f.items():
        if k == "humans":
            hs = v if isinstance(v, list) else [v]
            for h in hs:
                if not isinstance(h, str) or not HANDLE_RE.fullmatch(h) or h in RESERVED:
                    raise ListError(f"{where}: humans: '{h}' is not a lowercase handle")
                if h in names:
                    raise ListError(f"{where}: humans: '{h}' is also a participant's name")
            cfg.humans = list(hs)
        elif k == "fallback":
            if v not in names:
                raise ListError(f"{where}: fallback: '{v}' is not a participant in the list")
            cfg.fallback = v
        elif k == "model":
            cfg.model = v if isinstance(v, dict) else {"value": v}
            warnings.append(f"{where}: model: is read and not used in this version (the AI facilitator is slice 6)")
        else:
            warnings.append(f"{where}: unknown key facilitator.{k} (ignored)")
    return cfg, warnings


def load(settings) -> tuple[list[Participant], FacilitatorConfig, list[str], Path]:
    """Read both files. A missing participant list is an empty list with a warning (the humans can still
    talk to each other); a broken one raises ListError."""
    path, source = settings.participants_file()
    warnings: list[str] = []
    if path.is_file():
        parts, w = parse_participants(path.read_text(), str(path))
        warnings += w
    else:
        parts = []
        warnings.append(f"no participant list at {path} (from {source})")
    fpath = settings.path("FACILITATOR_FILE")
    if fpath.is_file():
        cfg, w = parse_facilitator(fpath.read_text(), str(fpath), [p.name for p in parts])
        warnings += w
    else:
        cfg = FacilitatorConfig()
    return parts, cfg, warnings, path
