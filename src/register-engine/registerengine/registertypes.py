"""Register types, given by the capability Features (AOF ADR 0028; SPEC.md, "Register types").

A type is what the entries of a register may say (its kinds and their checks), what they add up
to (`project`), and how they are shown (`views`, `index`, `render`). The engine knows one type of
its own, `log` (any kind, its data unchecked). Every other type comes from a capability Feature
(agentic-memory, agentic-communication, agentic-trust, agentic-agents), which installs one Python
module into the engine's types folder:

    /usr/local/lib/register-engine/types.d/<feature>.py      TYPES = [RegisterType(...), ...]

The installed folder is read only when (the security review of 0.1.0, F1 and F2):
- it, each module, and every folder above it and above the library, up to /, are owned by root
  and writable by no one else (a sticky folder does not pass), and none is a symlink;
- the process runs isolated (python3 -I), so nothing in the working folder or PYTHONPATH can stand
  in for a module a type imports.
An environment variable, a working folder or a store never adds, moves or replaces a type. A
folder given to load() explicitly (a source tree, a test) may instead be the running user's own.

Every module in the folder is trusted as fully as the engine itself: it runs in the same process.
What the folder rules keep out is anyone who is not root. Between capability Features, a type's
kinds are frozen when it is accepted, and two modules giving one type name are refused, not merged.
"""
from __future__ import annotations

import dataclasses
import importlib.util
import os
import stat
import sys
from types import MappingProxyType
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import core

TYPES_DIR = Path(__file__).resolve().parents[1] / "types.d"
NAME_RE = core.REGISTER_RE


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
    feature: str = "register-engine"  # who gives it


LOG = RegisterType("log", {}, "", "any kind, its data unchecked")


class TypesError(ValueError):
    pass


def _safe(p: Path, what: str, owners: tuple[int, ...]) -> None:
    """Owned by one of `owners`, writable by no one else, never a symlink."""
    st = os.lstat(p)
    if stat.S_ISLNK(st.st_mode):
        raise TypesError(f"{what} {p} is a symlink")
    if st.st_uid not in owners:
        who = "root" if owners == (0,) else "root or this user"
        raise TypesError(f"{what} {p} is owned by uid {st.st_uid}, not {who}")
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise TypesError(f"{what} {p} is writable by its group or others")


def _chain(p: Path) -> None:
    """Every folder above `p`, up to /, owned by root and writable by no one else."""
    for d in p.parents:
        _safe(d, "the folder", (0,))


def installed_ready() -> None:
    """The checks the installed folder must pass; raises TypesError, saying which part fails."""
    if not sys.flags.isolated:
        raise TypesError("the types are read only by an isolated process (python3 -I): run the "
                         "installed command, not the library from a working folder")
    _chain(TYPES_DIR)
    _chain(Path(__file__).resolve().parent)
    _safe(Path(__file__).resolve().parent, "the library folder", (0,))


def load(folder: Path | None = None) -> dict[str, RegisterType]:
    """Every type: `log`, and each one a module in the types folder gives. Raises TypesError when the
    folder or a module is not safe, a module cannot be loaded, or two give one name. With no
    `folder`, the installed one, under the installed rules (the module's text)."""
    installed = folder is None
    folder = TYPES_DIR if installed else Path(folder)
    owners = (0,) if installed else (0, os.geteuid())
    out = {"log": LOG}
    where = {"log": "the engine"}
    if installed:
        if not folder.exists():
            return out
        installed_ready()
    elif not folder.exists():
        return out
    _safe(folder, "the types folder", owners)
    for f in sorted(folder.glob("*.py")):
        _safe(f, "the type module", owners)
        spec = importlib.util.spec_from_file_location(f"registerengine_types_{f.stem.replace('-', '_')}", f)
        mod = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(mod)
        except Exception as e:                    # a broken module is refused, by name, never half-loaded
            raise TypesError(f"the type module {f} cannot be loaded: {e}") from None
        given = getattr(mod, "TYPES", None)
        if not isinstance(given, (list, tuple)) or not all(isinstance(t, RegisterType) for t in given):
            raise TypesError(f"the type module {f} has no TYPES list of RegisterType")
        for t in given:
            if not NAME_RE.fullmatch(t.name):
                raise TypesError(f"{f}: {t.name!r} is not a plain type name")
            if t.name in out:
                raise TypesError(f"two give the type {t.name}: {where[t.name]} and {f}")
            out[t.name] = dataclasses.replace(t, kinds=MappingProxyType(dict(t.kinds)))   # frozen once accepted
            where[t.name] = str(f)
    return out


def get(name: str, types: dict[str, RegisterType] | None = None) -> RegisterType:
    types = load() if types is None else types
    if name not in types:
        raise ValueError(f"no register type {name!r}; the types installed are {', '.join(sorted(types))} "
                         "(a type comes from its capability Feature)")
    return types[name]
