"""The mesh module (proposal facilitator-node, sections 4.1, 7, 8 and 12.1; ADR-0067, ADR-0069, ADR-0071): reads
the node's own `mesh.yml` (FACILITATOR_MESH_FILE, default .devcontainer/mesh.yml) and answers, with no I/O of
its own, every policy question the rest of the application asks: which role the node plays, which trust
domain maps to which level, how wide an agent is exposed, the limits of a level and where each value came
from, whether a caller may reach an agent, which ports the role opens, and lock two's decision on a SPIFFE ID.

    preset: team                 # solo (the default) | team | open (the public level across nodes, slice N5a)
    role: hub                    # standalone (the default) | spoke | hub | peer (no hub: a peers list, slice N5a)
    node:                        # this node's own settings (the brief of slice N3 put them here, not in
      id: hub-1                  #   facilitator.yml): its id (default: the host name), and by role:
      name: hub.corp.example     # hub: the DNS name in its certificate, the spokes' server_name
      listen:                    # hub: one SLIM listener per level, each with that level's CA bundle (lock one)
        private: 0.0.0.0:46358
      join: 0.0.0.0:46359        # hub: the join endpoint, open only while a join token is live
      issuer:                    # hub: who issues the domain's certificates (ADR-0069, ADR-0078); the tiers, in order:
        domain: corp.example
        openbao: http://openbao:8200   #   1. an OpenBao PKI (mount, role, kv, approle), when named
        mount: pki-corp
        role: node
        ssh_agent:                     #   2. else an ssh-agent holds the CA key (an ed25519 key, matched by fingerprint)
          socket: /run/ssh-ca/agent.sock
          key: SHA256:...
                                       #   3. else the built-in CA: a root and an issuing CA, keys in the volume
      hub: hub.corp.example:46358   # spoke: written by `facilitator node join`
      hub_name: hub.corp.example
      hub_node: hub-1
      domain: corp.example
      directory:
        peering: false           # the Directory's libp2p and OCI beyond loopback (SP5: no mDNS switch exists)
      peers:                     # peer (and hub): node id -> host:port of the peer's SLIM listener, or `incoming` (it dials us)
        node-b: b.mesh.test:46358
      public:                    # hub or peer: the public domain this node issues certificates for (1 h, by approval)
        domain: open.example
    trust:                       # SPIFFE trust domain -> level; a domain not listed is refused
      corp.example: private
    expose:                      # handle or full SPIFFE ID -> the widest level it may be reached from
      "*": local
      triage: private
    limits:                      # per level: hops, budget, rate, copy, svid_ttl, max_packet
      private:
        hops: 4

Levels order local (narrowest) < private < public (widest). The reach rule: a caller at level L reaches an
agent exposed E only when E >= L. A domain not in `trust` is refused, not public. The node's own home
domain `<id>.local` is always local. An invalid file makes the node standalone ("fail narrow", 12.2)."""
from __future__ import annotations

import ipaddress
import re
import socket
from dataclasses import dataclass, field
from pathlib import Path

from . import yamlite

LEVELS = ("local", "private", "public")
ORDER = {lv: i for i, lv in enumerate(LEVELS)}
ROLES = ("standalone", "spoke", "hub", "peer")
ISSUING_ROLES = ("hub", "peer")                               # the roles that issue certificates and accept joins
PRESETS = {"solo": "local", "team": "private", "open": "public"}   # preset -> its ceiling
TOP_KEYS = ("preset", "role", "node", "trust", "expose", "limits")
NODE_KEYS = ("id", "name", "listen", "join", "issuer", "hub", "hub_name", "hub_node", "domain", "directory", "peers",
             "public")
PUBLIC_KEYS = ("domain", "join")
ISSUER_KEYS = ("domain", "openbao", "mount", "role", "kv", "approle", "ssh_agent")
SSH_AGENT_KEYS = ("socket", "key")
FINGERPRINT_RE = re.compile(r"SHA256:[A-Za-z0-9+/]{43}")
DIRECTORY_KEYS = ("peering", "firewall", "open_oci")
LIMIT_KEYS = ("hops", "budget", "rate", "copy", "approval", "approval_ttl", "svid_ttl", "max_packet", "http_receive_wait")
COPIES = ("full", "member", "addressed")
APPROVALS = ("none", "first-contact", "every-message", "per-conversation")
MESSAGE_APPROVALS = ("every-message", "per-conversation")      # a person answers for messages, not for a sender
# The defaults of each level (proposal 7, the limits table). hops, budget and rate of local and private come
# from the Feature's options (ruling AD), which set them in Mesh.limit.
DEFAULT_LIMITS = {
    "local": {"hops": 6, "budget": 40, "rate": 10, "copy": "full", "approval": "none", "approval_ttl": "none",
              "svid_ttl": "24h", "max_packet": "1MiB", "http_receive_wait": "300s"},
    "private": {"hops": 6, "budget": 40, "rate": 10, "copy": "member", "approval": "none", "approval_ttl": "none",
                "svid_ttl": "24h", "max_packet": "256KiB", "http_receive_wait": "60s"},
    "public": {"hops": 2, "budget": 10, "rate": 3, "copy": "addressed", "approval": "first-contact", "approval_ttl": "30d",
               "svid_ttl": "1h", "max_packet": "16KiB", "http_receive_wait": "25s"},
}
OPTION_LIMITS = {"hops": "FACILITATOR_HOP_LIMIT", "budget": "FACILITATOR_MESSAGE_BUDGET", "rate": "FACILITATOR_RATE_LIMIT"}
DOMAIN_RE = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*")
NODE_ID_RE = re.compile(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")
HANDLE_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
SPIFFE_RE = re.compile(r"spiffe://(?P<domain>[a-z0-9.-]+)/node/(?P<node>[a-z0-9-]+)(?:/(?P<kind>agent)/(?P<handle>[a-z0-9_-]+))?")
DURATION_RE = re.compile(r"(\d+)([smhd])")
SIZE_RE = re.compile(r"(\d+)(B|KiB|MiB)?")
ADDR_RE = re.compile(r"(?P<host>[A-Za-z0-9.:\[\]-]+):(?P<port>\d{1,5})")


class MeshError(ValueError):
    pass


@dataclass
class Finding:
    line: int
    rule: str
    message: str


@dataclass
class SpiffeId:
    domain: str
    node: str
    handle: str | None = None

    def __str__(self) -> str:
        base = f"spiffe://{self.domain}/node/{self.node}"
        return f"{base}/agent/{self.handle}" if self.handle else base


def parse_id(text: str) -> SpiffeId | None:
    m = SPIFFE_RE.fullmatch(text or "")
    if not m:
        return None
    return SpiffeId(m["domain"], m["node"], m["handle"])


def wider(a: str, b: str) -> str:
    return a if ORDER[a] >= ORDER[b] else b


def reach_ok(caller_level: str, exposure: str) -> bool:
    """The reach rule (proposal 7): a caller at level L may see and message an agent exposed E only when E >= L."""
    return ORDER[exposure] >= ORDER[caller_level]


def seconds(v) -> int:
    if str(v).strip() == "none":
        return 0
    m = DURATION_RE.fullmatch(str(v).strip())
    if not m:
        raise MeshError(f"{v!r}: a duration such as 30s, 15m, 24h or 7d")
    return int(m[1]) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m[2]]


def size(v) -> int:
    m = SIZE_RE.fullmatch(str(v).strip())
    if not m:
        raise MeshError(f"{v!r}: a size such as 16KiB, 256KiB or 1MiB")
    return int(m[1]) * {None: 1, "B": 1, "KiB": 1024, "MiB": 1024 * 1024}[m[2]]


def parse_addr(v) -> tuple[str, int]:
    m = ADDR_RE.fullmatch(str(v or "").strip())
    if not m or not 0 < int(m["port"]) < 65536:
        raise MeshError(f"{v!r}: host:port")
    return m["host"].strip("[]"), int(m["port"])


def is_loopback(host: str) -> bool:
    if host in ("localhost",):
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def default_node_id() -> str:
    h = re.sub(r"[^a-z0-9-]+", "-", socket.gethostname().lower()).strip("-")[:63].strip("-")
    return h or "node"


def _line_of(text: str, *keys: str) -> int:
    """The line of the last of `keys` nested in order (a best effort for findings: yamlite keeps no lines)."""
    lines = text.splitlines()
    start = 0
    found = 0
    for k in keys:
        pat = re.compile(r"^\s*(?:-\s+)?(?:\"" + re.escape(k) + r"\"|'" + re.escape(k) + r"'|" + re.escape(k) + r")\s*:")
        for n in range(start, len(lines)):
            if pat.match(lines[n]):
                found, start = n + 1, n + 1
                break
    return found or 1


@dataclass
class Mesh:
    """A node's mesh.yml, checked. `findings` are what `check` reports; a Mesh with findings is not used
    to open anything (effective() turns it into standalone)."""
    path: Path | None
    preset: str = "solo"
    role: str = "standalone"
    node: dict = field(default_factory=dict)
    trust: dict = field(default_factory=dict)
    expose: dict = field(default_factory=dict)
    limits_file: dict = field(default_factory=dict)
    findings: list = field(default_factory=list)
    exists: bool = False
    text: str = ""

    # ------------------------------------------------------------ identity of this node

    @property
    def node_id(self) -> str:
        return self.node.get("id") or default_node_id()

    @property
    def home_domain(self) -> str:
        return f"{self.node_id}.local"

    @property
    def http_domain(self) -> str:
        """The trust domain of this node's own HTTP clients (slice N4, ADR-0070 decision 5): `http.<home domain>`."""
        return f"http.{self.home_domain}"

    def http_level(self) -> str:
        """The level a bearer-token client gets: public unless mesh.yml maps `http.<home domain>` to private."""
        return self.trust.get(self.http_domain, "public")

    @property
    def ceiling(self) -> str:
        return PRESETS.get(self.preset, "local")

    @property
    def domain(self) -> str | None:
        """The trust domain this node holds a certificate in: the issuer's domain on a hub, the joined one on a
        spoke, none when standalone."""
        if self.role == "hub":
            return (self.node.get("issuer") or {}).get("domain")
        if self.role in ("spoke", "peer"):
            return self.node.get("domain")
        return None

    @property
    def public_domain(self) -> str | None:
        """The public domain this node issues for (node.public.domain; a hub or a peer): its certificates last the public
        level's svid_ttl (1 h) and are issued only after a person approves a join request (ruling AH)."""
        return ((self.node.get("public") or {}).get("domain")) if self.role in ISSUING_ROLES else None

    @property
    def peers(self) -> dict:
        """node id -> host:port of each peer this node dials (a peer's, and a hub's optional seed list)."""
        return dict(self.node.get("peers") or {}) if self.role in ISSUING_ROLES else {}

    def domains_issued(self) -> list[str]:
        """Every domain this node is the issuer of: its own, and its public one."""
        return [d for d in (self.domain if self.role in ISSUING_ROLES else None, self.public_domain) if d]

    def level_of_domain(self, domain: str) -> str | None:
        """The level `trust` maps a domain to; the home domain is local; None for a domain not listed (refused)."""
        if domain == self.home_domain:
            return "local"
        if domain == self.http_domain:
            return self.http_level()
        return self.trust.get(domain)

    def exposure(self, handle: str) -> str:
        """The widest level an agent of this node may be reached from: a full SPIFFE ID of this node's agent
        (any domain), then the handle, then "*", then local (an agent opts outward, never inward; ruling BC)."""
        for k, v in self.expose.items():
            sid = parse_id(k)
            if sid and sid.node == self.node_id and sid.handle == handle:
                return v
        if handle in self.expose:
            return self.expose[handle]
        return self.expose.get("*", "local")

    def limit(self, level: str, key: str, settings=None) -> tuple:
        """(the effective value, where it came from), by ruling AD's order: the preset's default, then the
        Feature option (local and private: hops, budget, rate), then mesh.yml's limits for that level."""
        v, src = DEFAULT_LIMITS[level][key], f"the default of level {level}"
        if settings is not None and key in OPTION_LIMITS and level in ("local", "private"):
            k = OPTION_LIMITS[key]
            v, src = settings.int(k, 1), f"{k} (from {settings.sources[k]})"
        f = (self.limits_file.get(level) or {}).get(key)
        if f is not None:
            v, src = f, f"mesh.yml limits.{level}.{key}"
        if key in ("hops", "budget", "rate"):
            v = int(v)
        return v, src

    def svid_seconds(self, level: str) -> int:
        return seconds(self.limit(level, "svid_ttl")[0])

    # ------------------------------------------------------------ lock two

    def admit(self, claimed: str, ca_domain: str | None, revoked: set | frozenset = frozenset()) -> tuple[bool, str, str]:
        """Lock two (ADR-0069 decision 5, ruling SP1) on one certificate: (admitted, level, why). `claimed` is
        the URI SAN of the certificate; `ca_domain` the trust domain whose CA bundle the certificate chains to
        (identity.chain_domain), None when it chains to none. Lock one (the listener) may have let it in; this
        refuses it all the same when the ID's domain is not the domain whose CA signed it."""
        sid = parse_id(claimed)
        if ca_domain is None:
            return False, "", "its certificate chains to no trust bundle this node holds"
        if sid is None:
            return False, "", f"{claimed!r} is not a node or agent SPIFFE ID (spiffe://<domain>/node/<id>[/agent/<handle>])"
        if sid.domain != ca_domain:
            return False, "", (f"impostor: the certificate claims {sid.domain} but chains to the CA of {ca_domain}")
        level = self.level_of_domain(sid.domain)
        if level is None:
            return False, "", f"the domain {sid.domain} is not in mesh.yml's trust (a domain not listed is refused)"
        if ORDER[level] > ORDER[self.ceiling]:
            return False, "", f"the domain {sid.domain} maps to {level}, above the preset {self.preset}'s ceiling {self.ceiling}"
        if sid.node in revoked:
            return False, "", f"the node {sid.node} is revoked"
        return True, level, f"{sid} admitted at level {level}"

    # ------------------------------------------------------------ ports (ADR-0071)

    def listeners(self) -> dict[str, tuple[str, int]]:
        """The SLIM listeners beyond loopback this node opens: {level: (host, port)}; only a hub or a peer opens any, one
        per level, the public one separate (SP1)."""
        if self.role not in ISSUING_ROLES or self.findings:
            return {}
        out = {}
        for lv, addr in (self.node.get("listen") or {}).items():
            out[lv] = parse_addr(addr)
        return out

    def open_ports(self) -> list[dict]:
        """What this node opens beyond loopback, and why (ADR-0071): `check` prints it. The join port is open
        only while a join token is live; the Directory's only with directory.peering."""
        rows = []
        for lv, (h, p) in self.listeners().items():
            rows.append({"what": f"SLIM listener, level {lv} (lock one: the CA bundle of the {lv} domains)",
                         "address": f"{h}:{p}", "when": f"always (role {self.role})"})
        if self.role in ISSUING_ROLES and self.node.get("join") and not self.findings:
            h, p = parse_addr(self.node["join"])
            rows.append({"what": "join endpoint (HTTPS)", "address": f"{h}:{p}",
                         "when": "only while a join token is live, a request window is open or a join request waits"})
        pj = (self.node.get("public") or {}).get("join") if self.role in ISSUING_ROLES else None
        if pj and not self.findings:
            h, p = parse_addr(pj)
            rows.append({"what": "public join endpoint (HTTPS; join requests, no token)", "address": f"{h}:{p}",
                         "when": "only while a request window is open or a request waits"})
        d = self.node.get("directory") or {}
        if d.get("peering") and not self.findings:
            if self.role in ISSUING_ROLES:
                rows.append({"what": "Directory libp2p (the spokes' bootstrap peer)", "address": "0.0.0.0:<p2p port>",
                             "when": "directory.peering"})
            if self.role in ISSUING_ROLES or (self.role == "spoke" and d.get("open_oci") and self.node.get("name")):
                rows.append({"what": "Directory OCI registry (anonymous pull, and anonymous push: firewall it to the peers)",
                             "address": f"{self.node.get('name')}:<oci port>", "when": "directory.peering"})
        return rows


def _check_ssh_agent(issuer: dict, add) -> None:
    """node.issuer.ssh_agent (ruling K5): the agent's socket and the SHA256 fingerprint of the ed25519 key that is the CA."""
    sa = issuer.get("ssh_agent")
    if sa is None:
        return
    if not isinstance(sa, dict):
        add("bad-value", "node.issuer.ssh_agent: a map of socket and key", "node", "issuer", "ssh_agent")
        return
    for k in sa:
        if k not in SSH_AGENT_KEYS:
            add("unknown-key", f"node.issuer.ssh_agent.{k}: ssh_agent has {', '.join(SSH_AGENT_KEYS)}", "node", "issuer", "ssh_agent", k)
    if not str(sa.get("socket") or "").strip():
        add("role-needs", "node.issuer.ssh_agent.socket: the agent's socket path is needed (or $SSH_AUTH_SOCK)", "node", "issuer", "ssh_agent")
    if not FINGERPRINT_RE.fullmatch(str(sa.get("key") or "")):
        add("bad-value", "node.issuer.ssh_agent.key: the CA key's SHA256 fingerprint (ssh-add -l -E sha256), never 'the first key'",
            "node", "issuer", "ssh_agent")


def _check(m: Mesh, raw: dict, text: str) -> None:
    f = m.findings

    def add(rule: str, message: str, *keys: str) -> None:
        f.append(Finding(_line_of(text, *keys) if keys else 1, rule, message))

    if not isinstance(raw, dict):
        add("bad-file", "mesh.yml is a map of preset, role, node, trust, expose and limits")
        return
    for k in raw:
        if k not in TOP_KEYS:
            add("unknown-key", f"'{k}': mesh.yml has {', '.join(TOP_KEYS)} and nothing else", k)
    p = raw.get("preset") or "solo"
    if p not in PRESETS:
        add("bad-value", f"preset {p!r}: solo, team or open", "preset")
    else:
        m.preset = p
    r = raw.get("role") or "standalone"
    if r not in ROLES:
        add("bad-value", f"role {r!r}: standalone, spoke, hub or peer", "role")
    else:
        m.role = r
    node = raw.get("node") or {}
    if not isinstance(node, dict):
        add("bad-value", "node: a map", "node")
        node = {}
    for k in node:
        if k not in NODE_KEYS:
            add("unknown-key", f"node.{k}: node has {', '.join(NODE_KEYS)}", "node", k)
    m.node = dict(node)
    if node.get("id") is not None and not NODE_ID_RE.fullmatch(str(node["id"])):
        add("bad-value", f"node.id {node['id']!r}: lower-case letters, digits and -", "node", "id")
    for k in ("name", "hub_name", "domain"):
        if node.get(k) is not None and not DOMAIN_RE.fullmatch(str(node[k])):
            add("bad-value", f"node.{k} {node[k]!r}: a DNS name", "node", k)
    trust = raw.get("trust") or {}
    if not isinstance(trust, dict):
        add("bad-value", "trust: a map of trust domain to level", "trust")
        trust = {}
    for d, lv in trust.items():
        if not DOMAIN_RE.fullmatch(str(d)):
            add("bad-value", f"trust: {d!r} is not a trust domain (a DNS-like name)", "trust", d)
        elif d == m.home_domain:
            add("home-domain", f"trust: {d} is this node's home domain, always local; it cannot be mapped", "trust", d)
        elif d == m.http_domain:
            if lv not in ("private", "public"):
                add("bad-value", f"trust: {d}: {lv!r}: the node's HTTP clients are public (the default) or private "
                                 "(an intranet CLI), never local", "trust", d)
            elif m.preset == "solo":
                add("above-ceiling", f"trust: {d}: HTTP clients are refused under the preset solo", "trust", d)
            else:
                m.trust[d] = lv
        elif lv not in LEVELS:
            add("bad-value", f"trust: {d}: {lv!r} is not a level (local, private, public)", "trust", d)
        elif ORDER[lv] > ORDER[m.ceiling]:
            add("above-ceiling", f"trust: {d}: {lv} is above the preset {m.preset}'s ceiling ({m.ceiling})", "trust", d)
        else:
            m.trust[d] = lv
    expose = raw.get("expose") or {}
    if not isinstance(expose, dict):
        add("bad-value", "expose: a map of handle (or SPIFFE ID, or \"*\") to level", "expose")
        expose = {}
    for k, lv in expose.items():
        if k != "*" and not HANDLE_RE.fullmatch(str(k)) and parse_id(str(k)) is None:
            add("bad-value", f"expose: {k!r} is neither a handle, a SPIFFE ID nor \"*\"", "expose", k)
        elif lv == "public" and m.preset == "solo":
            add("above-ceiling", f"expose: {k}: public is above the preset solo's ceiling (local); public means reachable "
                                 "by the node's HTTP clients, which need team", "expose", k)
        elif lv not in LEVELS:
            add("bad-value", f"expose: {k}: {lv!r} is not a level (local, private, public)", "expose", k)
        elif ORDER[lv] > ORDER[m.ceiling] and lv != "public":
            add("above-ceiling", f"expose: {k}: {lv} is above the preset {m.preset}'s ceiling ({m.ceiling})", "expose", k)
        else:
            m.expose[str(k)] = lv
    limits = raw.get("limits") or {}
    if not isinstance(limits, dict):
        add("bad-value", "limits: a map of level to its keys", "limits")
        limits = {}
    for lv, keys in limits.items():
        if lv not in LEVELS:
            add("bad-value", f"limits: {lv!r} is not a level", "limits", lv)
            continue
        if not isinstance(keys, dict):
            add("bad-value", f"limits.{lv}: a map of {', '.join(LIMIT_KEYS)}", "limits", lv)
            continue
        good = {}
        for k, v in keys.items():
            try:
                if k in ("hops", "budget", "rate"):
                    if not str(v).isdigit() or int(v) < 1:
                        raise MeshError(f"{v!r}: a whole number, 1 or more")
                    good[k] = int(v)
                elif k == "copy":
                    if v not in COPIES:
                        raise MeshError(f"{v!r}: {', '.join(COPIES)}")
                    if lv == "public" and v != "addressed":
                        raise MeshError(f"{v}: the public level copies only what is addressed to a node (a person who wants "
                                        "more makes that node private)")
                    good[k] = v
                elif k == "approval":
                    if v not in APPROVALS:
                        raise MeshError(f"{v!r}: {', '.join(APPROVALS)}")
                    if lv == "local" and v in MESSAGE_APPROVALS:
                        raise MeshError(f"{v}: the local level is this node's own agents, whose messages never cross; a person "
                                        "approves what comes from another node at private or public, or from an HTTP client")
                    good[k] = v
                elif k == "approval_ttl":
                    if str(v) != "none":
                        seconds(v)
                    good[k] = str(v)
                elif k == "http_receive_wait":
                    s = seconds(v)
                    if not 1 <= s <= 3600:
                        raise MeshError(f"{v!r}: between 1s and 1h")
                    good[k] = str(v)
                elif k == "svid_ttl":
                    s = seconds(v)
                    if not 60 <= s <= 7 * 86400:
                        raise MeshError(f"{v!r}: between 1m and 7d")
                    good[k] = v
                elif k == "max_packet":
                    size(v)
                    good[k] = v
                else:
                    raise MeshError(f"unknown; the keys are {', '.join(LIMIT_KEYS)}")
            except MeshError as e:
                add("bad-value", f"limits.{lv}.{k}: {e}", "limits", lv, k)
        m.limits_file[lv] = good
    # the role's own needs
    issuer = node.get("issuer") or {}
    if m.role in ISSUING_ROLES:
        r_ = m.role
        if r_ == "hub":
            if not isinstance(issuer, dict) or not issuer.get("domain"):
                add("role-needs", "role hub: node.issuer.domain (the trust domain it issues for) is needed", "role")
            else:
                for k in issuer:
                    if k not in ISSUER_KEYS:
                        add("unknown-key", f"node.issuer.{k}: issuer has {', '.join(ISSUER_KEYS)}", "node", "issuer", k)
                if issuer["domain"] not in m.trust:
                    add("role-needs", f"role hub: its issuer's domain {issuer['domain']} must be in trust", "node", "issuer", "domain")
                _check_ssh_agent(issuer, add)
        else:
            # a peer is the issuer of its own domain, with a CA it keeps itself (or an OpenBao PKI when node.issuer says so)
            if not node.get("domain") or not DOMAIN_RE.fullmatch(str(node["domain"])):
                add("role-needs", "role peer: node.domain (the trust domain this node issues its own certificate in) is needed", "role")
            elif m.trust.get(node["domain"]) != "private":
                add("role-needs", f"role peer: its own domain {node['domain']} must be in trust, mapped private", "node", "domain")
            if issuer and (not isinstance(issuer, dict) or issuer.get("domain") not in (None, node.get("domain"))):
                add("bad-value", "node.issuer.domain: a peer issues in its own node.domain", "node", "issuer")
            elif isinstance(issuer, dict):
                _check_ssh_agent(issuer, add)
        if not node.get("name"):
            add("role-needs", f"role {r_}: node.name (the DNS name its peers dial, in its certificate) is needed", "role")
        listen = node.get("listen") or {}
        if not isinstance(listen, dict) or (r_ == "hub" and not listen):
            add("role-needs", "role hub: node.listen (a SLIM listener per level, e.g. private: 0.0.0.0:46358)"
                if r_ == "hub" else "node.listen: a map of level to host:port", "role" if r_ == "hub" else "node")
        else:
            for lv, addr in listen.items():
                try:
                    parse_addr(addr)
                except MeshError as e:
                    add("bad-value", f"node.listen.{lv}: {e}", "node", "listen", lv)
                    continue
                if lv not in m.trust.values() or lv not in LEVELS:
                    add("role-needs", f"node.listen.{lv}: no domain in trust maps to {lv}, so no CA bundle for it",
                        "node", "listen", lv)
                if lv == "public" and not m.public_domain:
                    add("role-needs", "node.listen.public: a public listener needs node.public.domain (the public domain it "
                                      "presents a certificate in)", "node", "listen", "public")
                if lv == "local":
                    add("bad-value", "node.listen.local: nothing local is dialled from another machine", "node", "listen", "local")
        if node.get("join"):
            try:
                parse_addr(node["join"])
            except MeshError as e:
                add("bad-value", f"node.join: {e}", "node", "join")
            if node.get("public") and (node.get("public") or {}).get("join") == node["join"]:
                add("bad-value", "node.public.join: the public join endpoint is separate from node.join (SP1)", "node", "public", "join")
        pub = node.get("public")
        if pub is not None:
            if not isinstance(pub, dict) or any(k not in PUBLIC_KEYS for k in pub) or not pub.get("domain"):
                add("bad-value", "node.public: {domain: <the public trust domain this node issues for>, join: <host:port of the "
                                 "separate public join endpoint>}", "node", "public")
            elif m.trust.get(pub["domain"]) != "public":
                add("role-needs", f"node.public.domain {pub['domain']} must be in trust, mapped public (preset open)",
                    "node", "public", "domain")
            elif m.ceiling != "public":
                add("above-ceiling", f"node.public: the preset {m.preset} does not allow public (open does)", "node", "public")
            elif pub.get("join"):
                try:
                    parse_addr(pub["join"])
                except MeshError as e:
                    add("bad-value", f"node.public.join: {e}", "node", "public", "join")
        peers = node.get("peers") or {}
        if not isinstance(peers, dict):
            add("bad-value", "node.peers: a map of node id to host:port", "node", "peers")
        else:
            for pid, addr in peers.items():
                if not NODE_ID_RE.fullmatch(str(pid)) or pid == m.node_id:
                    add("bad-value", f"node.peers: {pid!r} is not another node's id", "node", "peers", pid)
                    continue
                if addr == "incoming":
                    continue                    # the peer dials this node (written by `node invite` and the pairing)
                try:
                    parse_addr(addr)
                except MeshError as e:
                    add("bad-value", f"node.peers.{pid}: {e} (or `incoming`: the peer dials this node)", "node", "peers", pid)
        if r_ == "peer" and not peers and not node.get("join"):
            add("role-needs", "role peer: node.peers (the nodes it dials) or node.join (so that a peer can pair with it) "
                              "is needed", "role")
    elif m.role == "spoke":
        if node.get("peers"):
            add("role-needs", "role spoke: a spoke dials its one hub: remove node.peers (role peer links nodes without a hub)",
                "node", "peers")
        if node.get("listen"):
            add("role-needs", "role spoke: a spoke opens nothing (it dials its hub): remove node.listen", "node", "listen")
        if node.get("hub"):
            try:
                parse_addr(node["hub"])
            except MeshError as e:
                add("bad-value", f"node.hub: {e}", "node", "hub")
            if not node.get("domain") or node["domain"] not in m.trust:
                add("role-needs", "role spoke: node.domain (the joined domain) must be in trust", "node", "domain")
    if m.role != "standalone" and m.ceiling == "local":
        add("above-ceiling", f"role {m.role}: the preset {m.preset} allows only this machine (solo); use team", "role")
    d = node.get("directory") or {}
    if d and not isinstance(d, dict):
        add("bad-value", "node.directory: a map", "node", "directory")
    elif d:
        for k in d:
            if k not in DIRECTORY_KEYS:
                add("unknown-key", f"node.directory.{k}: directory has {', '.join(DIRECTORY_KEYS)}", "node", "directory", k)
        if d.get("firewall") not in (None, "auto", "external"):
            add("bad-value", "node.directory.firewall: auto (iptables, needs NET_ADMIN) or external", "node", "directory", "firewall")
        if d.get("peering") and "public" in m.trust.values():
            add("role-needs", "node.directory.peering: not with a public domain in trust: the Directory's libp2p would admit any "
                              "dialer into its gossip (R3); a public node is reached through the register (copy addressed)",
                "node", "directory", "peering")


def parse(text: str, path: Path | None = None) -> Mesh:
    m = Mesh(path, exists=True, text=text)
    try:
        raw = yamlite.parse(text, str(path or "mesh.yml"))
    except yamlite.YamlError as e:
        m.findings.append(Finding(e.line, "bad-yaml", str(e).split(": ", 1)[-1]))
        return m
    _check(m, raw if raw is not None else {}, text)
    return m


def mesh_file(settings) -> Path:
    return settings.path("FACILITATOR_MESH_FILE")


def load(settings) -> Mesh:
    """The node's mesh.yml as written (with its findings); a missing file is solo and standalone."""
    p = mesh_file(settings)
    try:
        text = p.read_text()
    except FileNotFoundError:
        return Mesh(p)
    except OSError as e:
        m = Mesh(p, exists=True)
        m.findings.append(Finding(1, "unreadable", f"{p}: {e.strerror or e}"))
        return m
    return parse(text, p)


def effective(m: Mesh) -> Mesh:
    """What the node runs: the file when it has no findings, else standalone and solo with the node id kept
    ("fail narrow": an invalid mesh.yml never opens anything, 12.2)."""
    if not m.findings:
        return m
    return Mesh(m.path, node={"id": m.node.get("id")} if m.node.get("id") else {}, exists=m.exists,
                findings=list(m.findings), text=m.text)


def write_node(path: Path, updates: dict, role: str | None = None, trust: dict | None = None,
               preset: str | None = None) -> None:
    """Writes keys into mesh.yml's node section (and role, trust) keeping everything else as written: used by
    `node join`. The file is small and in the subset yamlite reads; the sections touched are rewritten."""
    try:
        text = path.read_text()
    except FileNotFoundError:
        text = ""
    raw = yamlite.parse(text, str(path)) if text.strip() else {}
    raw = raw or {}
    if role:
        raw["role"] = role
    if preset:
        raw["preset"] = preset
    raw.setdefault("preset", "team")
    node = dict(raw.get("node") or {})
    node.update({k: v for k, v in updates.items() if v is not None})
    raw["node"] = node
    if trust:
        t = dict(raw.get("trust") or {})
        t.update(trust)
        raw["trust"] = t
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(dump(raw))


def _scalar(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    s = str(v)
    if s == "" or not re.fullmatch(r"[A-Za-z0-9_./:@-]+", s) or s in ("true", "false", "null"):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def _key(k: str) -> str:
    return k if re.fullmatch(r"[A-Za-z0-9_.-]+", k) else '"' + k + '"'


def dump(d: dict, indent: int = 0) -> str:
    """A map in the subset yamlite reads, sections in mesh.yml's order."""
    order = [k for k in TOP_KEYS if k in d] + [k for k in d if k not in TOP_KEYS] if indent == 0 else list(d)
    out = []
    for k in order:
        v = d[k]
        pad = " " * indent
        if isinstance(v, dict):
            out.append(f"{pad}{_key(k)}:")
            out.append(dump(v, indent + 2).rstrip("\n"))
        elif isinstance(v, list):
            out.append(f"{pad}{_key(k)}: [{', '.join(_scalar(x) for x in v)}]")
        elif v is None:
            continue
        else:
            out.append(f"{pad}{_key(k)}: {_scalar(v)}")
    return "\n".join(x for x in out if x != "") + "\n"
