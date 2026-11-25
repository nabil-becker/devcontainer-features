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


HTTP_KEYS = ("enabled", "listen", "url", "tls_cert", "tls_key", "behind_proxy", "insecure", "allowed_hosts", "allowed_origins",
             "issuers")


ISSUER_KEYS = ("name", "issuer", "jwks_uri", "algorithms", "scope", "audience")
ASYMMETRIC_ALGS = ("RS256", "RS384", "RS512", "PS256", "PS384", "PS512", "ES256", "ES384", "ES512", "EdDSA")
DEFAULT_ALGS = ("RS256", "ES256")


@dataclass
class Issuer:
    """One entry of `facilitator.http.issuers` (slice N5b, ADR-0070 decision 2, ruling PB3): an OAuth authorization
    server the node accepts access tokens from. The node is a resource server only; it never hosts one."""
    name: str                                   # a short handle: names the server in docs, check and each client's handle
    issuer: str                                 # the `iss` its tokens carry, exactly; also what the protected-resource metadata names
    jwks_uri: str | None = None                 # default: found from the issuer's discovery document
    algorithms: list[str] = field(default_factory=lambda: list(DEFAULT_ALGS))
    scope: str | None = None                    # default: facilitator:participate
    audience: str | None = None                 # default: the node's resource URL (RFC 8707); some servers fix their own

    def json(self) -> dict:
        return {"name": self.name, "issuer": self.issuer, "jwks_uri": self.jwks_uri, "algorithms": list(self.algorithms),
                "scope": self.scope, "audience": self.audience}


@dataclass
class HttpConfig:
    """`facilitator.http:` of facilitator.yml (slice N4, ADR-0070, ADR-0071): the MCP endpoint over HTTP. Off unless
    `listen` is set (a port opens only when configured); `enabled: false` is the kill switch."""
    enabled: bool = True
    listen: str | None = None
    url: str | None = None                    # the address clients use (https://host:port); default from listen
    tls_cert: str | None = None
    tls_key: str | None = None
    behind_proxy: bool = False
    insecure: bool = False                    # plain http on any address, for a local machine or a test environment (ruling OA6)
    allowed_hosts: list[str] = field(default_factory=list)
    allowed_origins: list[str] = field(default_factory=list)
    issuers: list["Issuer"] = field(default_factory=list)     # the OAuth authorization servers whose tokens are accepted (slice N5b)

    @property
    def configured(self) -> bool:
        return bool(self.listen)

    @property
    def active(self) -> bool:
        return self.configured and self.enabled


@dataclass
class FacilitatorConfig:
    humans: list[str] = field(default_factory=lambda: ["you"])
    fallback: str | None = None
    model: dict | None = None
    http: HttpConfig = field(default_factory=HttpConfig)
    http_errors: list[str] = field(default_factory=list)


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
        elif k == "http":
            _parse_http(cfg, v, where)
        else:
            warnings.append(f"{where}: unknown key facilitator.{k} (ignored)")
    return cfg, warnings


def _bool(v, what: str, where: str):
    if isinstance(v, bool):
        return v
    if str(v).lower() in ("true", "yes", "on", "false", "no", "off"):
        return str(v).lower() in ("true", "yes", "on")
    raise ListError(f"{where}: {what}: true or false")


def _list(v) -> list[str]:
    return [str(x) for x in (v if isinstance(v, list) else [v] if v not in (None, "") else [])]


def _parse_http(cfg: FacilitatorConfig, v, where: str) -> None:
    """facilitator.http: problems go to cfg.http_errors (check refuses; the endpoint does not open), not an
    exception: a mistake here must not stop the node's other parts."""
    err = cfg.http_errors
    if not isinstance(v, dict):
        err.append(f"{where}: facilitator.http: a map (listen, tls_cert, tls_key, behind_proxy, ...)")
        return
    h = cfg.http
    for k, x in v.items():
        try:
            if k not in HTTP_KEYS:
                err.append(f"{where}: facilitator.http.{k}: unknown; http has {', '.join(HTTP_KEYS)}")
            elif k in ("enabled", "behind_proxy", "insecure"):
                setattr(h, k, _bool(x, f"facilitator.http.{k}", where))
            elif k in ("listen", "url", "tls_cert", "tls_key"):
                setattr(h, k, str(x) if x not in (None, "") else None)
            elif k in ("allowed_hosts", "allowed_origins"):
                setattr(h, k, _list(x))
            elif k == "issuers":
                h.issuers = _parse_issuers(x, where, err, insecure=str(v.get("insecure")).lower() in ("true", "yes", "on"))
        except ListError as e:
            err.append(str(e))
    if h.listen:
        from .mesh import MeshError, parse_addr
        try:
            parse_addr(h.listen)
        except MeshError as e:
            err.append(f"{where}: facilitator.http.listen: {e}")
    if bool(h.tls_cert) != bool(h.tls_key):
        err.append(f"{where}: facilitator.http: tls_cert and tls_key go together")
    if h.issuers:
        if not h.url:
            err.append(f"{where}: facilitator.http.issuers: needs http.url, the public HTTPS address of this node (a cloud AI "
                       "reaches it there, and the tokens' audience is that address)")
        elif not _https_or_loopback(h.url) and not (h.insecure and _http_url(h.url)):
            err.append(f"{where}: facilitator.http.url {h.url}: with issuers it must be https:// (http:// only for a loopback "
                       "host, or on any address with http.insecure: true, for a local machine or a test environment)")


def _http_url(url: str) -> bool:
    """A plain http:// URL with a host and no query or fragment (what http.insecure admits)."""
    from urllib.parse import urlsplit
    try:
        u = urlsplit(url)
        return u.scheme == "http" and bool(u.hostname) and not u.fragment and not u.query
    except ValueError:
        return False


def _https_or_loopback(url: str) -> bool:
    from urllib.parse import urlsplit
    from .mesh import is_loopback
    try:
        u = urlsplit(url)
        host = u.hostname or ""
    except ValueError:
        return False
    return bool(host) and not u.fragment and not u.query and (u.scheme == "https" or (u.scheme == "http" and is_loopback(host)))


def _parse_issuers(v, where: str, err: list[str], insecure: bool = False) -> list[Issuer]:
    """facilitator.http.issuers: a list of {name, issuer, jwks_uri?, algorithms?, scope?, audience?}; every problem is named."""
    at = f"{where}: facilitator.http.issuers"
    if not isinstance(v, list):
        err.append(f"{at}: a list of entries, each '- name: ..., issuer: https://...'")
        return []
    out: list[Issuer] = []
    for n, it in enumerate(v, 1):
        here = f"{at}[{n}]"
        if not isinstance(it, dict):
            err.append(f"{here}: a map with name and issuer (a bare URL has no name: give it one)")
            continue
        bad = [k for k in it if k not in ISSUER_KEYS]
        if bad:
            err.append(f"{here}: unknown {', '.join(bad)}; an issuer has {', '.join(ISSUER_KEYS)}")
        name, iss = _text(it.get("name")), _text(it.get("issuer"))
        if not HANDLE_RE.fullmatch(name) or len(name) > 24:
            err.append(f"{here}: name '{name}': a lowercase handle of at most 24 characters (it begins every client's handle from this server)")
        if not iss or not _https_or_loopback(iss):
            err.append(f"{here}: issuer '{iss}': an https:// URL (http:// only for a loopback host, for tests)")
        jwks = it.get("jwks_uri")
        if jwks not in (None, "") and not _https_or_loopback(str(jwks)) and not (insecure and _http_url(str(jwks))):
            err.append(f"{here}: jwks_uri '{jwks}': an https:// URL (plain http:// only with http.insecure: true)")
        algs = _list(it["algorithms"]) if "algorithms" in it else list(DEFAULT_ALGS)
        for a in algs:
            if a.lower() == "none" or a.upper().startswith("HS"):
                err.append(f"{here}: algorithms: {a} is refused (none and the shared-secret HS* algorithms are never accepted: "
                           "a token must be signed by the issuer's public key)")
            elif a not in ASYMMETRIC_ALGS:
                err.append(f"{here}: algorithms: {a} is not one of {', '.join(ASYMMETRIC_ALGS)}")
        if not algs:
            err.append(f"{here}: algorithms: at least one")
        scope = _text(it.get("scope")) or None
        if scope and (" " in scope.strip() or not scope.strip()):
            err.append(f"{here}: scope '{scope}': one scope name (the token must carry it)")
        aud = _text(it.get("audience")) or None
        if any(i.name == name for i in out):
            err.append(f"{here}: name '{name}' is used twice")
        if any(i.issuer == iss for i in out):
            err.append(f"{here}: issuer {iss} is listed twice")
        out.append(Issuer(name, iss, str(jwks) if jwks else None, algs, scope, aud))
    return out


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
