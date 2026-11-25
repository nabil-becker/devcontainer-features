"""The peers module (proposal facilitator-node, sections 4, 5.3, 8, 10 and 12; slices N3 and N5a): what crosses from one
node to another, and the long-running part that carries it (`facilitator node peers`, the infrastructure part
`peers`, started by `infra up` when the role is spoke or hub).

    node A (spoke)                         hub                                node B (spoke)
      peers  -- SLIM, mTLS (lock one) -->  SLIM listener per level  <-- SLIM --  peers
       |  hello: A's card                   peers: lock two on the card, the roster of cards
       |  <- roster: every admitted card, the revoked nodes, signed by the hub
       |  entries of a conversation A and B share ------- routed by the hub's SLIM ------->  lock two on every
       |                                                                                      entry, then the replica

Every envelope is a JSON object signed with the sending node's certificate key; its receiver checks lock two
(mesh.Mesh.admit, through identity.check_card) on the sender's card, then on every entry: its signer's key must
be the key a card binds to the principal it writes as (a participant of that node, or that node's facilitator),
and every local member of the conversation must be exposed at least as wide as the sender's level (the reach
rule). Refusals are written to mesh/refused.log, which `check` reads. A conversation's replica is complete on
every node one of its members is on (copy `member`, level private; `full` at local): each write is queued for
the other member nodes (outbox) and the whole register is sent again until it is delivered (sync is idempotent:
an entry's id is its hash), so a node that was away catches up, and a held message waits (12.2). An @handle on
another node is reached through the hub: the spokes' SLIM nodes link only to the hub, which routes between them
(static `peer` links, SP3), and the hub's own application holds no copy unless one of its participants is a member.

Slice N5a adds, to the same parts:
- role `peer` (no hub): each node is the issuer of its own domain (a CA it keeps, identity.LocalIssuer) and lists the nodes
  it links to (node.peers); `node invite` on one and `node peer --token` on the other pair them (the two exchange CA
  bundles, so each one's listener trusts the other's domain, and the accepter hands over the mesh secret); the peers
  exchange cards by `hello` and `card` envelopes, with no roster to relay.
- the public level across nodes: a node that issues for a public domain (node.public) opens a separate join endpoint for
  join *requests* (a key, no token) and a separate public SLIM listener; a person's `node approve` issues the requester's
  certificate (1 h); the requester is a spoke of that domain, and what it is shown is the issuer's card alone, restricted to
  what is exposed public (copy `addressed`: it replicates only the conversations it is a member of, in which every message
  is addressed to it or written by it, enforced when written and checked again before sending, Net.addressed_ok).
- cut-off: `node revoke` stops renewal, drops the card, and rotates the mesh's SLIM app secret (ruling H4): the rotation
  is handed, by the nodes that remain, to the nodes that remain (the `secret` envelope), each of which restarts its peers
  part on the new secret; a revoked node holds the old one and can no longer connect.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import hashlib
import http.server
import json
import os
import signal
import socket
import ssl
import sys
import threading
import time
from pathlib import Path

from . import identity, mesh as mesh_mod, router
from .identity import IdentityError

ORG, NODE_NS = "agntcy", "facilitator-node"
HELLO_SECONDS = 30
RETRY_SECONDS = 5
FACILITATOR = "facilitator"


class PeersError(RuntimeError):
    pass


def local_ns(m: "mesh_mod.Mesh") -> str:
    """The SLIM namespace of this node's participants: unchanged when standalone; per node in a mesh, so two
    nodes' participants of the same handle never share a name (SLIM syncs subscriptions across peer links)."""
    return "facilitator" if m.role == "standalone" else f"facilitator-{m.node_id}"


def hmac_ok(want_hash: str, secret: str) -> bool:
    import hmac
    return hmac.compare_digest(want_hash, hashlib.sha256(secret.encode()).hexdigest())


def _log_refusal(store: identity.Store, what: str, why: str) -> None:
    store.ensure()
    line = json.dumps({"at": identity.now_utc(), "what": what, "why": why}, sort_keys=True)
    with open(store.refused_log, "a") as f:
        f.write(line + "\n")


def refusals(store: identity.Store, n: int = 20) -> list[dict]:
    try:
        lines = store.refused_log.read_text().splitlines()[-n:]
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


class Net:
    """The application's view of the mesh: the admitted cards, the conversations shared with other nodes, the
    outbox, and lock two on entries. Used by the application (in any process) and by the peers daemon."""

    def __init__(self, fac):
        self.fac = fac
        self.mesh = fac.mesh
        self.store = identity.Store(fac.state.home)

    @property
    def active(self) -> bool:
        return self.mesh.role in ("spoke", "hub", "peer")

    # ------------------------------------------------------------ cards

    def cards(self, history: bool = False) -> dict[str, dict]:
        """node -> {card, level}: the cards this node's peers daemon admitted (lock two). A revoked node's card is
        kept, marked, only so that what it signed before stays readable (history=True: the register's anchors, the
        signer names verify shows); it never admits anything new."""
        out = {}
        d = self.store.cards
        if not d.is_dir():
            return out
        for f in sorted(d.glob("*.json")):
            try:
                c = json.loads(f.read_text())
            except (OSError, ValueError):
                continue
            if c.get("revoked") and not history:
                continue
            if c.get("card", {}).get("node") and c["card"]["node"] != self.mesh.node_id:
                out[c["card"]["node"]] = c
        return out

    def card_at(self, node: str) -> str:
        """When the card of a node now kept was made (its signed `at`): an older one is a replay."""
        c = self.cards(history=True).get(node)
        return c["card"].get("at", "") if c else ""

    def save_card(self, card: dict, level: str) -> None:
        self.store.ensure()
        p = self.store.cards / f"{card['node']}.json"
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps({"card": card, "level": level, "admitted": identity.now_utc()}, sort_keys=True))
        os.replace(tmp, p)

    def revoke_card(self, node: str) -> None:
        """Marks a node's card revoked: nothing new from it is admitted; what it signed before stays readable."""
        p = self.store.cards / f"{node}.json"
        try:
            c = json.loads(p.read_text())
        except (OSError, ValueError):
            return
        c["revoked"] = identity.now_utc()
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps(c, sort_keys=True))
        os.replace(tmp, p)

    def drop_card(self, node: str) -> None:
        try:
            (self.store.cards / f"{node}.json").unlink()
        except FileNotFoundError:
            pass

    def remote(self) -> dict[str, dict]:
        """`handle.node` -> {handle, node, key, kind, exposure, level, domain, description, skills} of every
        participant another node's admitted card lists (ruling H5: two nodes may announce one handle; each is
        reachable by its qualified name)."""
        out: dict[str, dict] = {}
        for node, c in sorted(self.cards().items()):
            for p in c["card"].get("participants", []):
                if p["handle"] == FACILITATOR:
                    continue
                out[router.qualify(p["handle"], node)] = {**p, "node": node, "level": c["level"],
                                                          "domain": c["card"]["domain"]}
        return out

    def local_names(self) -> set[str]:
        return (set(self.fac.state.roster()) | set(self.fac.humans())) - {FACILITATOR}

    def resolve(self, name: str) -> list[str]:
        """What a name given by a person or an agent names: this node's own handle (bare), or `handle.node` of
        another node's participant. A bare handle names every reachable one with that handle, this node's and other
        nodes' alike (several: the caller refuses, listing them; no precedence for this node's own)."""
        name = name.lower().lstrip("@")
        local, remote = self.local_names(), self.remote()
        h, n = router.split(name)
        if n is not None:
            if n == self.mesh.node_id:
                return [h] if h in local else []
            return [name] if name in remote else []
        out = [name] if name in local else []
        return out + sorted(q for q, r in remote.items() if r["handle"] == name)

    def display(self, handle: str, node: str | None = None) -> str:
        """How `who` names a participant: its bare handle, or `handle.node` where another reachable participant
        has that handle too."""
        node = node or self.mesh.node_id
        if len(self.resolve(handle)) > 1:
            return router.qualify(handle, node)
        return handle

    def shared_handles(self) -> dict[str, list[str]]:
        """handle -> its qualified names, for every handle more than one reachable participant has."""
        names: dict[str, list[str]] = {}
        for h in self.local_names():
            names.setdefault(h, []).append(router.qualify(h, self.mesh.node_id))
        for q, r in self.remote().items():
            names.setdefault(r["handle"], []).append(q)
        return {h: sorted(v) for h, v in names.items() if len(v) > 1}

    def binding(self, key: str) -> tuple[str, str, str] | None:
        """(node, principal, level) a card binds this packet key to, or None (revoked nodes' too: history)."""
        for node, c in self.cards(history=True).items():
            if c["card"].get("facilitator") == key:
                return node, FACILITATOR, c["level"]
            for p in c["card"].get("participants", []):
                if p.get("key") == key:
                    return node, p["handle"], c["level"]
        return None

    def local_keys(self) -> dict[str, str]:
        """key -> principal of this node's own identities (its facilitator, its participants)."""
        out = {}
        for h in list(self.fac.state.roster()) + [FACILITATOR]:
            k = self.fac.signer.public(h)
            if k:
                out[k] = h
        return out

    # ------------------------------------------------------------ conversations shared with other nodes

    def approvals(self) -> dict:
        """`handle.node` -> {at, by}: another node's agents a person approved at first contact (ruling AH, approval_ttl)."""
        try:
            return json.loads((self.store.root / "approved.json").read_text())
        except (OSError, ValueError):
            return {}

    def approve(self, principal: str, by: str) -> None:
        self.store.ensure()
        d = self.approvals()
        d[principal] = {"at": identity.now_utc(), "by": by}
        identity._private(self.store.root / "approved.json", json.dumps(d, sort_keys=True))

    def copy_of(self, node: str) -> str:
        """What this node replicates to `node`: the `copy` of the level its card puts it at (ruling AH: addressed at public)."""
        c = self.cards().get(node)
        return self.mesh.limit(c["level"], "copy")[0] if c else "member"

    def addressed_ok(self, conv: str, node: str) -> tuple[bool, str]:
        """Copy `addressed` (proposal 10), checked before a register is sent to a node that gets only what is addressed to it:
        every message in it is by a member on that node, or its route names one (and the members are only this node's and
        that node's). register-engine cannot hold a sub-DAG (an entry whose `prev` is absent is refused, sign-packet
        graph.order), so the policy is on the conversation: the write refuses what is not addressed (Facilitator.write),
        and this refuses to send a register that holds more."""
        try:
            _, proj, _ = self.fac.record.read(conv)
        except Exception as e:           # noqa: BLE001
            return False, f"the register cannot be read: {e}"
        th = proj["thread"]
        if th is None:
            return False, "no thread entry"
        mine = {m for m in th["members"] if self.node_of(m) == node}
        if not mine:
            return False, f"{node} has no member in {conv}"
        for mid in proj["order"]:
            m = proj["messages"][mid]
            if m["from"] in mine:
                continue
            routed = {t for r in proj["routes"].get(mid, []) for t in r["to"]}
            if not (routed & mine):
                return False, (f"the message {mid} is not addressed to {', '.join(sorted(mine))}: a conversation shared with a "
                               f"node at copy addressed carries only what is addressed to it")
        return True, "ok"

    def meta(self, conv: str) -> dict | None:
        try:
            return json.loads((self.store.convs / f"{conv}.json").read_text())
        except (OSError, ValueError):
            return None

    def save_meta(self, conv: str, members: dict[str, str], home: str, copy: str | None = None) -> None:
        """A shared conversation's members and their nodes. Once known, a member's node never changes and no
        member is removed by a later envelope (a member node cannot drop or move another node's members)."""
        self.store.ensure()
        old = self.meta(conv) or {}
        merged = {**members, **old.get("members", {})}
        p = self.store.convs / f"{conv}.json"
        tmp = p.with_suffix(".tmp")
        meta = {"members": merged, "home": old.get("home") or home}
        if copy or old.get("copy"):
            meta["copy"] = copy or old["copy"]       # what the sender replicates to this node: `addressed` makes the replica partial
        tmp.write_text(json.dumps(meta, sort_keys=True))
        os.replace(tmp, p)

    def nodes_of(self, conv: str) -> set[str]:
        m = self.meta(conv)
        return set((m or {}).get("members", {}).values()) - {self.mesh.node_id} if m else set()

    def anchors_extra(self, conv: str) -> dict[str, str]:
        """The facilitator keys of the other nodes a shared conversation's members are on: each may write the
        conversation's routes and notices (its own dispatcher), as `facilitator`."""
        cards = self.cards(history=True)
        return {cards[n]["card"]["facilitator"]: FACILITATOR for n in self.nodes_of(conv) if n in cards}

    def push(self, conv: str) -> None:
        """Queue the conversation for every other node one of its members is on (the daemon sends the whole
        register, so the queue is one marker per node and conversation)."""
        for n in self.nodes_of(conv):
            d = self.store.outbox / n
            d.mkdir(parents=True, exist_ok=True)
            (d / conv).write_text(identity.now_utc() + "\n")

    def level_of(self, principal: str, key: str | None = None) -> str:
        """The level of a writer: local for this node's own, else its card's level."""
        if key is not None:
            b = self.binding(key)
            if b:
                return b[2]
            return "local"
        r = self.remote().get(principal)
        return r["level"] if r else "local"

    def node_of(self, principal: str) -> str:
        """The node a principal of a conversation is on: its qualifier, else this node."""
        return router.split(principal)[1] or self.mesh.node_id

    # ------------------------------------------------------------ lock two on entries

    def check_entries(self, conv: str, members: dict[str, str], raws: list[bytes], sender: str,
                      sender_level: str) -> tuple[bool, str]:
        """Lock two on a conversation's entries from another node: (ok, why). Every signer's key is this node's
        own or bound by an admitted card to the principal it writes as; every key a roster entry adds is bound to
        the principal it is added as; the members map agrees with the cards; and every member on this node is
        exposed at least as wide as the sender's level."""
        from registerengine import core
        cards = self.cards()
        local = self.local_keys()
        me = self.mesh.node_id
        if not core.REGISTER_RE.fullmatch(conv or ""):
            return False, f"{conv!r} is not a conversation id"
        old = (self.meta(conv) or {}).get("members", {})
        for q, n in members.items():
            if q in old and old[q] != n:
                return False, f"the members put {q} on {n}; it is on {old[q]}"
        for q, n in members.items():
            h, qn = router.split(q)
            if qn != n:
                return False, f"the member {q} is not qualified with its node {n} (a shared conversation names handle.node)"
            if n == me:
                if h not in self.fac.state.roster() and h not in self.fac.humans():
                    return False, f"the members name {h} on this node, which has no such participant"
                if not mesh_mod.reach_ok(sender_level, self.mesh.exposure(h)):
                    return False, (f"{h} is exposed {self.mesh.exposure(h)}, narrower than the sender's level "
                                   f"{sender_level} (the reach rule)")
            elif n not in cards:
                return False, f"the members name the node {n}, which has no admitted card here"
            elif not any(p["handle"] == h for p in cards[n]["card"].get("participants", [])):
                return False, f"the members put {h} on {n}, whose card does not list it"
        if sender not in set(members.values()):
            return False, f"the sender {sender} has no member in {conv}"

        def bound(key: str, principal: str) -> bool:
            if principal == FACILITATOR:
                if local.get(key) == FACILITATOR:
                    return True
                return any(c["card"].get("facilitator") == key and n in set(members.values()) for n, c in cards.items())
            h, n = router.split(principal)
            if n is None:
                return False               # in a shared conversation every member is handle.node
            if n == me:
                return local.get(key) == h
            c = cards.get(n)
            return c is not None and any(p.get("key") == key and p["handle"] == h
                                         for p in c["card"].get("participants", []))

        have = set(self.fac.record.store(conv).ids()) if self.fac.record.exists(conv) else set()
        for raw in raws:
            try:
                e = core.parse(raw, self.fac.record.kinds)
            except Exception as ex:            # noqa: BLE001 - a malformed packet refuses the whole envelope
                return False, f"a malformed entry: {ex}"
            if e.id in have:
                continue                      # held already: checked when it came
            if e.register != conv:
                return False, f"an entry of another register ({e.register})"
            if not bound(e.key, e.principal):
                return False, (f"the entry {e.id[:12]} by {e.principal} is signed by a key no admitted card binds to "
                               f"{e.principal} (lock two: no SPIFFE ID for its signer)")
            if e.kind == "roster":
                for a in e.data.get("add", []):
                    if not bound(a.get("key", ""), a.get("as", "")):
                        return False, f"a roster entry adds a key for {a.get('as')} that no card binds to it"
        return True, "ok"


# ---------------------------------------------------------------- the daemon

class Daemon:
    """`facilitator node peers`: connects to the node's own SLIM node as agntcy/facilitator-node/<node id> with the
    mesh's app secret, and serves: hello and roster (the hub's roster of cards), entries (replicas), renew (a
    spoke's certificate at half life) and, on a hub, the join endpoint while a join token is live."""

    def __init__(self, fac):
        self.fac = fac
        self.net = Net(fac)
        self.mesh = fac.mesh
        self.store = self.net.store
        self.domain = self.mesh.domain
        self.issuing = self.mesh.role in mesh_mod.ISSUING_ROLES
        self.reexec = False
        self.app = None
        self.sb = None
        self.stop = False
        self.next_try: dict[tuple, float] = {}
        self.last_hello = 0.0
        self.last_roster = 0.0
        self.roster_stamp = 0.0
        self.status = {"role": self.mesh.role, "node": self.mesh.node_id, "connected": False, "hub_seen": None,
                       "errors": []}
        self.join_servers: dict[str, object] = {}
        self.join_until: dict[str, float] = {}
        self.restart_slim = False

    # ------------------------------------------------------------ helpers

    def err(self, what: str) -> None:
        self.status["errors"] = (self.status["errors"] + [f"{identity.now_utc()} {what}"])[-10:]
        print(f"facilitator-peers: {what}", file=sys.stderr, flush=True)

    def write_status(self) -> None:
        self.status["at"] = identity.now_utc()
        self.status["pid"] = os.getpid()
        self.status["join_open"] = any(v is not None for v in self.join_servers.values())
        self.status["join_open_kinds"] = sorted(k for k, v in self.join_servers.items() if v is not None)
        tmp = self.store.status_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.status, indent=2, sort_keys=True))
        os.replace(tmp, self.store.status_file)

    def bundles(self) -> dict[str, Path]:
        return self.store.bundles(self.mesh.trust)

    def revoked_set(self) -> set[str]:
        """Nodes this node refuses: its roster's revoked, and those a hub told a spoke (revoked.json)."""
        return identity.revoked(identity.roster(self.store)) | self.revoked_here()

    def my_card(self, level: str | None = None, domain: str | None = None) -> dict:
        """This node's card for a receiver at `level` (default: the level of this node's own domain): only the participants
        exposed at least as wide as that level (a public receiver is shown public agents alone) and signed with the
        certificate of `domain` (default: this node's own)."""
        domain = domain or self.domain
        lv = level or self.mesh.level_of_domain(domain)
        parts = []
        roster = self.fac.state.roster()
        for h, ident in sorted(roster.items()):
            if ident.get("kind") not in ("agent", "human") or not ident.get("key"):
                continue
            exp = self.mesh.exposure(h)
            if not mesh_mod.reach_ok(lv, exp):
                continue                        # a local-only participant never leaves this node
            parts.append({"handle": h, "key": ident["key"], "kind": ident["kind"], "exposure": exp,
                          "description": ident.get("description", ""), "skills": ident.get("skills", []),
                          **({"cid": ident["cid"]} if ident.get("cid") else {}),
                          **({"badge": ident["badge"]} if isinstance(ident.get("badge"), str) and ident["badge"] else {})})
        return identity.make_card(self.store, domain, self.mesh.node_id, self.fac.record.facilitator_key(), parts)

    def domain_for(self, node: str) -> str:
        """The domain whose certificate key signs what this node sends to `node`: the public domain for a node that joined it
        (that receiver holds this node's card signed with that certificate, ruling AH), else this node's own."""
        d = (identity.roster(self.store).get("nodes", {}).get(node) or {}).get("domain")
        return d if d and d != self.domain and self.store.key(d).is_file() else self.domain

    def envelope(self, to: str, body: dict, domain: str | None = None) -> bytes:
        at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")     # ordered: a replay is older
        env = {"v": 1, "from": self.mesh.node_id, "to": to, "at": at, **body}
        return json.dumps(identity.sign_envelope(self.store, domain or self.domain_for(to), env), separators=(",", ":")).encode()

    # ------------------------------------------------------------ SLIM

    async def connect(self) -> None:
        import datetime as _dt  # noqa: F401
        import slim_bindings as sb
        self.sb = sb
        if not sb.is_initialized():
            sb.initialize_with_configs(sb.new_runtime_config(), sb.new_tracing_config_with("error", False, False, []),
                                       [sb.new_service_config()])
        svc = sb.get_global_service()
        sec = self.fac.infra().slim_secrets()
        if not sec:
            raise PeersError("SLIM's secrets are not set up: facilitator infra up")
        base = sb.new_insecure_client_config(f"http://127.0.0.1:{self.fac.s['FACILITATOR_SLIM_PORT']}")
        cfg = sb.ClientConfig(**{**vars(base), "auth": sb.ClientAuthenticationConfig.BASIC(
            config=sb.BasicAuth(username="facilitator", password=sec["password"]))})
        self.conn = await svc.connect_async(cfg)
        secret = self.store.mesh_secret(create=self.issuing)
        if not secret:
            raise PeersError("no mesh secret: this spoke has not joined (facilitator node join)")
        self.status["secret_sha"] = hashlib.sha256(secret.encode()).hexdigest()[:16]     # the secret this SLIM app was made with
        name = sb.Name(ORG, NODE_NS, self.mesh.node_id)
        self.app = svc.create_app_with_secret(name, secret)
        await self.app.subscribe_async(name, self.conn)
        self.status["connected"] = True

    async def send(self, node: str, data: bytes) -> bool:
        sb, td = self.sb, dt.timedelta
        cfg = sb.SessionConfig(session_type=sb.SessionType.POINT_TO_POINT, max_retries=3,
                               interval=td(milliseconds=700), metadata={}, mls_settings=None)
        s = None
        try:
            s = await asyncio.wait_for(self.app.create_session_and_wait_async(cfg, sb.Name(ORG, NODE_NS, node)), 6)
            h = await s.publish_async(data, None, None)
            await asyncio.wait_for(h.wait_async(), 6)
            return True
        except Exception:                      # noqa: BLE001 - the peer is unreachable: the outbox retries
            return False
        finally:
            if s is not None:
                try:
                    h = await self.app.delete_session_async(s)
                    await asyncio.wait_for(h.wait_async(), 3)
                except Exception:              # noqa: BLE001
                    pass

    async def listen(self) -> None:
        td = dt.timedelta
        while not self.stop:
            try:
                s = await self.app.listen_for_session_async(td(seconds=5))
            except Exception:                  # noqa: BLE001 - a timeout: listen again
                continue
            asyncio.get_running_loop().create_task(self.read(s))

    async def read(self, s) -> None:
        td = dt.timedelta
        while True:
            try:
                m = await s.get_message_async(td(seconds=30))
            except Exception:                  # noqa: BLE001 - the sender closed the session
                return
            try:
                reply = await asyncio.to_thread(self.handle, bytes(m.payload))
            except Exception as e:             # noqa: BLE001 - one bad envelope never stops the daemon
                self.err(f"an envelope could not be handled: {e}")
                continue
            for node, data in reply or []:
                if not await self.send(node, data):
                    self.err(f"the reply to {node} was not delivered")

    # ------------------------------------------------------------ envelopes

    def sender_card(self, env: dict) -> tuple[dict | None, str]:
        """The admitted card of the node an envelope says it is from, and its level; a hello carries its own."""
        node = env.get("from")
        if env.get("type") in ("hello", "card"):
            card = env.get("card")
            if not isinstance(card, dict) or card.get("node") != node:
                return None, "a hello whose card is not its sender's"
            revoked = self.revoked_set()
            ok, level, why = identity.check_card(card, self.mesh, self.bundles(), revoked)
            if not ok:
                return None, why
            if self.issuing and env.get("type") == "hello" and node not in self.mesh.peers \
                    and node not in identity.roster(self.store).get("nodes", {}):
                return None, f"the node {node} is neither a peer of this node nor joined to it (not in node.peers or the roster)"
            return {"card": card, "level": level}, ""
        c = self.net.cards().get(node)
        if c is None:
            if self.mesh.role == "spoke" and node == self.mesh.node.get("hub_node") and env.get("type") == "roster":
                card = env.get("hub_card") or {}
                ok, level, why = identity.check_card(card, self.mesh, self.bundles(), set())
                return ({"card": card, "level": level}, "") if ok and card.get("node") == node else (None, why or "not the hub")
            return None, f"no admitted card for the node {node!r}"
        return c, ""

    @staticmethod
    def revoked_names(store) -> set[str]:
        try:
            return set(json.loads((store.root / "revoked.json").read_text()))
        except (OSError, ValueError):
            return set()

    def revoked_here(self) -> set[str]:
        try:
            return set(json.loads((self.store.root / "revoked.json").read_text()))
        except (OSError, ValueError):
            return set()

    def handle(self, raw: bytes) -> list[tuple[str, bytes]]:
        try:
            env = json.loads(raw)
        except ValueError:
            _log_refusal(self.store, "an envelope", "not JSON")
            return []
        if not isinstance(env, dict) or env.get("v") != 1 or env.get("to") != self.mesh.node_id:
            _log_refusal(self.store, "an envelope", f"not addressed to this node ({env.get('to') if isinstance(env, dict) else '?'})")
            return []
        what = f"{env.get('type')} from {env.get('from')}"
        c, why = self.sender_card(env)
        if c is None:
            _log_refusal(self.store, what, f"lock two: {why}")
            return []
        if env.get("from") in self.revoked_set():
            _log_refusal(self.store, what, f"lock two: the node {env.get('from')} is revoked")
            return []
        if not identity.check_envelope(env, c["card"]):
            _log_refusal(self.store, what, "lock two: the envelope is not signed by its sender's certificate key")
            return []
        limit = mesh_mod.size(self.mesh.limit(c["level"], "max_packet")[0])
        if len(raw) > limit * 64:            # a whole register travels; max_packet bounds each entry below
            _log_refusal(self.store, what, f"too large ({len(raw)} bytes)")
            return []
        t = env.get("type")
        if t in ("hello", "roster", "card"):
            card = env.get("hub_card") if t == "roster" else env.get("card")
            if card and card.get("at", "") < self.net.card_at(card.get("node", "")):
                _log_refusal(self.store, what, "a replay: a card older than the one this node holds")
                return []
        if t == "roster" and env.get("at", "") <= self.status.get("roster_at", self.last_roster_at()):
            _log_refusal(self.store, what, "a replay: a roster no newer than the last one")
            return []
        if t == "hello" and self.issuing:
            return self.on_hello(env, c)
        if t == "card" and self.mesh.role == "peer":
            return self.on_card(env, c)
        if t == "secret":
            return self.on_secret(env, c)
        if t == "roster" and self.mesh.role == "spoke":
            return self.on_roster(env, c)
        if t == "entries":
            return self.on_entries(env, c)
        if t == "renew" and self.issuing:
            return self.on_renew(env, c)
        if t == "renewed" and self.mesh.role == "spoke":
            return self.on_renewed(env, c)
        _log_refusal(self.store, what, f"a {t!r} envelope is not served by a {self.mesh.role}")
        return []

    def last_roster_at(self) -> str:
        try:
            return (self.store.root / "roster-at").read_text().strip()
        except OSError:
            return ""

    def on_hello(self, env: dict, c: dict) -> list:
        node = env["from"]
        r = identity.roster(self.store)
        n = r.get("nodes", {}).get(node)
        if n is None and not (self.mesh.role == "peer" and node in self.mesh.peers):
            _log_refusal(self.store, f"hello from {node}", "the node has not joined this hub (no roster entry)")
            return []
        self.net.save_card(c["card"], c["level"])
        if n is not None:
            n["seen"] = identity.now_utc()
            identity.save_roster(self.store, r)
        if n is None or self.mesh.role == "hub":
            return [(node, self.roster_envelope(node))] if self.mesh.role == "hub" else \
                [(node, self.envelope(node, {"type": "card", "card": self.my_card(c["level"])}))]
        # a peer's reply to a node that joined it (a spoke of its public or private domain): a roster of its own card alone
        return [(node, self.roster_envelope(node))]

    def roster_envelope(self, to: str) -> bytes:
        if not self.store.cert(self.domain).is_file():
            raise IdentityError("the hub has no certificate yet")
        r = identity.roster(self.store)
        rev = sorted(identity.revoked(r))
        rn = r.get("nodes", {}).get(to) or {}
        dom = rn.get("domain") or self.domain
        lvl = self.mesh.level_of_domain(dom) or "private"
        # a public receiver is shown this node's own card, restricted to what is exposed public, and no other node's
        # (copy addressed: keys and roster, "only the sender's own entry", proposal 10)
        cards = [] if lvl == "public" else [c["card"] for n, c in self.net.cards().items()
                                            if n not in rev and n in r.get("nodes", {})]
        cert_dom = dom if self.store.cert(dom).is_file() else self.domain
        return self.envelope(to, {"type": "roster", "hub_card": self.my_card(lvl, cert_dom), "cards": cards, "revoked": rev,
                                  "hub_directory": {} if lvl == "public" else self.hub_directory()}, cert_dom)

    def hub_directory(self) -> dict:
        """Where a spoke syncs the hub's records from, when the hub's Directory peers: its libp2p peer id and
        address (the spoke's bootstrap peer) and its OCI registry (registry sync; the API stays on loopback)."""
        inf = self.fac.infra()
        if inf.peering() is None:
            return {}
        p = inf.ports["dir"]
        name = self.mesh.node["name"]
        return {"peer_id": inf.dir_peer_id(), "p2p": f"{name}:{p['p2p']}", "oci": f"{name}:{p['oci']}"}

    def on_roster(self, env: dict, c: dict) -> list:
        if env["from"] != self.mesh.node.get("hub_node"):
            _log_refusal(self.store, f"roster from {env['from']}", "only this spoke's hub serves its roster")
            return []
        rev = set(env.get("revoked") or [])
        (self.store.root / "revoked.json").write_text(json.dumps(sorted(rev)))
        (self.store.root / "roster-at").write_text(env["at"] + "\n")
        self.status["roster_at"] = env["at"]
        keep = {env["from"]}
        self.net.save_card(env["hub_card"], c["level"])
        for card in env.get("cards") or []:
            node = card.get("node")
            if node == self.mesh.node_id:
                continue
            ok, level, why = identity.check_card(card, self.mesh, self.bundles(), rev)
            if not ok:
                _log_refusal(self.store, f"the card of {node} (in the hub's roster)", f"lock two: {why}")
                continue
            self.net.save_card(card, level)
            keep.add(node)
        for node in list(self.net.cards()):
            if node in rev:
                self.net.revoke_card(node)       # kept for the history it signed; nothing new from it
            elif node not in keep:
                self.net.drop_card(node)
        self.status["hub_seen"] = identity.now_utc()
        self.last_roster = time.time()
        hd = env.get("hub_directory") or {}
        if hd:
            (self.store.root / "hub-directory.json").write_text(json.dumps(hd, sort_keys=True))
            self.sync_from_hub(hd, env["hub_card"])
        return []

    def on_card(self, env: dict, c: dict) -> list:
        """A peer's answer to our hello: its card, already checked (lock two) by sender_card and by the envelope's
        signature; kept, so its participants are reachable by qualified name."""
        node = env["from"]
        if node not in self.mesh.peers and node not in identity.roster(self.store).get("nodes", {}):
            _log_refusal(self.store, f"card from {node}", "not a peer of this node")
            return []
        self.net.save_card(env["card"], c["level"])
        self.status.setdefault("peers_seen", {})[node] = identity.now_utc()
        return []

    # ------------------------------------------------------------ the mesh secret's rotation (ruling H4)

    def on_secret(self, env: dict, c: dict) -> list:
        """The new SLIM app secret, from an admitted node that revoked one (or passed it on): applied here (after this
        node has passed it on to the nodes it still trusts, with the old secret, which they still hold), never twice."""
        new = env.get("new")
        if not isinstance(new, str) or len(new) < 32 or len(new) > 200 or not isinstance(env.get("rid"), str):
            _log_refusal(self.store, f"secret from {env['from']}", "a damaged rotation")
            return []
        rot = identity.rotation(self.store)
        if rot and rot.get("rid") == env["rid"]:
            return []                                           # passed on already
        if rot and rot.get("at", "") >= env.get("rotated_at", ""):
            _log_refusal(self.store, f"secret from {env['from']}", "a replay: no newer than the last rotation")
            return []
        nodes = [n for n in self.net.cards() if n != env["from"] and n not in self.revoked_set()] if self.mesh.role == "peer" else []
        identity.begin_rotation(self.store, env["rid"], new, env.get("rotated_at", identity.now_utc()), env["from"], nodes,
                                env.get("reason", ""))
        return []

    async def rotation(self) -> None:
        """Hands the new secret to the nodes still owed it (with the secret they hold now), then swaps this node to it:
        when every one has taken it, or after identity.ROTATION_WAIT_SECONDS. The swap restarts this part (exec), because
        a SLIM app's secret is fixed when it is made."""
        while not self.stop:
            rot = identity.rotation(self.store)
            if rot and rot.get("state") == "sending":
                for node in list(rot["pending"]):
                    data = await asyncio.to_thread(lambda n=node: self.envelope(n, {
                        "type": "secret", "rid": rot["rid"], "new": rot["new"], "rotated_at": rot["at"],
                        "reason": rot.get("reason", "")}))
                    if await self.send(node, data):
                        rot["pending"].remove(node)
                if not rot["pending"] or time.time() > rot["deadline"]:
                    if rot["pending"]:
                        self.err(f"the new mesh secret was not delivered to {', '.join(rot['pending'])} before the deadline; "
                                 "they need it by hand (facilitator node secret --show here, --set there)")
                    rot["state"] = "done"
                    identity.save_rotation(self.store, rot)
                    self.store.set_mesh_secret(rot["new"])
                    self.reexec = True
                else:
                    identity.save_rotation(self.store, rot)
            await asyncio.sleep(2)

    def sync_from_hub(self, hd: dict, hub_card: dict) -> None:
        """Ruling BI: a spoke syncs the hub's records (the CIDs its card names) by registry: one-way, pulled through
        the hub's OCI registry, so neither side's API leaves loopback. Each CID once."""
        inf = self.fac.infra()
        if inf.peering() is None or not hd.get("oci"):
            return
        done_f = self.store.root / "synced.json"
        try:
            done = set(json.loads(done_f.read_text()))
        except (OSError, ValueError):
            done = set()
        cids = sorted({p["cid"] for p in hub_card.get("participants", []) if p.get("cid")} - done)
        if not cids:
            return
        import subprocess
        r = subprocess.run([inf.binary("dir") or "dirctl", "--server-addr", f"127.0.0.1:{inf.ports['dir']['api']}", "sync",
                            "create", "--registry", f"http://{hd['oci']}", "--repository", "dir", "--cids", ",".join(cids)],
                           capture_output=True, text=True, timeout=60)
        if r.returncode == 0:
            done_f.write_text(json.dumps(sorted(done | set(cids))))
            self.status["directory_sync"] = f"{identity.now_utc()} {len(cids)} record(s) from {hd['oci']}"
        else:
            self.err(f"directory sync from {hd['oci']}: {(r.stderr or r.stdout).strip()[-200:]}")

    def on_entries(self, env: dict, c: dict) -> list:
        from registerengine import adapters
        conv, members = env.get("conv", ""), env.get("members") or {}
        raws = [e.encode() for e in env.get("entries") or [] if isinstance(e, str)]
        limit = mesh_mod.size(self.mesh.limit(c["level"], "max_packet")[0])
        if any(len(r) > limit for r in raws):
            _log_refusal(self.store, f"entries of {conv} from {env['from']}", f"an entry is over max_packet ({limit} bytes)")
            return []
        ok, why = self.net.check_entries(conv, members, raws, env["from"], c["level"])
        if not ok:
            _log_refusal(self.store, f"entries of {conv} from {env['from']}", f"lock two: {why}")
            return []
        old = self.net.meta(conv)
        self.net.save_meta(conv, members, env.get("home") or env["from"], self.mesh.limit(c["level"], "copy")[0])
        rec = self.fac.record
        store = rec.store(conv)
        rep = adapters.sync([adapters.raws(store), raws], store, rec.anchors_for(conv), rec.checked, conv, rec.kinds)
        if rep.refused:
            self.err(f"{conv}: {len(rep.refused)} entr(y/ies) refused by the register: "
                     + "; ".join(f"{i[:12]} {c_[0]}" for i, c_ in list(rep.refused.items())[:3]))
            if old is None and not any(store.ids()):
                (self.store.convs / f"{conv}.json").unlink(missing_ok=True)
        try:
            self.fac.note_held(conv)           # every-message, per-conversation: mark in the record what waits here
        except Exception as e:                 # noqa: BLE001 - a missing notice is not a lost message: it waits anyway
            self.err(f"{conv}: held notice not written: {e}")
        return []

    def on_renew(self, env: dict, c: dict) -> list:
        node = env["from"]
        r = identity.roster(self.store)
        n = r.get("nodes", {}).get(node)
        if n is None or n.get("revoked") or node in self.revoked_set():
            _log_refusal(self.store, f"renew from {node}", "revoked or not joined: no renewal (node revoke stops renewal)")
            return []
        dom = n.get("domain") or self.domain
        try:
            iss = identity.make_issuer(self.mesh, self.store, dom)
            got = iss.sign(env["csr"], node, f"{node}.{dom}", self.mesh.svid_seconds(c["level"]))
        except (IdentityError, KeyError) as e:
            self.err(f"renewal for {node}: {e}")
            return []
        n.update({"serial": got["serial"], "renewed": identity.now_utc()})
        identity.save_roster(self.store, r)
        self.backup(r)
        return [(node, self.envelope(node, {"type": "renewed", "cert": got["cert"]}))]

    def on_renewed(self, env: dict, c: dict) -> list:
        info = identity.cert_info(env["cert"])
        want = f"spiffe://{self.domain}/node/{self.mesh.node_id}"
        if want not in info["uris"] or identity.chain_domain(env["cert"], self.bundles()) != self.domain:
            _log_refusal(self.store, "a renewed certificate", f"it is not {want} from the domain's CA")
            return []
        if identity.ssh_key(info["raw_key"]) != identity.ssh_key(identity.cert_info(self.store.cert(self.domain).read_text())["raw_key"]):
            _log_refusal(self.store, "a renewed certificate", "it is for another key")
            return []
        self.store.cert(self.domain).write_text(env["cert"])
        self.status["renewed"] = identity.now_utc()
        self.restart_slim = True
        return []

    def backup(self, r: dict) -> None:
        try:
            identity.make_issuer(self.mesh, self.store, self.domain).backup_roster(r)
        except (IdentityError, KeyError) as e:
            self.err(f"the roster was not backed up to OpenBao: {e}")

    # ------------------------------------------------------------ the loops

    def entries_envelope(self, node: str, conv: str) -> bytes | None:
        meta = self.net.meta(conv)
        if not meta:
            return None
        if self.net.copy_of(node) == "addressed":
            ok, why = self.net.addressed_ok(conv, node)
            if not ok:
                _log_refusal(self.store, f"entries of {conv} to {node}", f"withheld, copy addressed: {why}")
                return None
        from registerengine import adapters
        raws = [r.decode() for r in adapters.raws(self.fac.record.store(conv))]
        return self.envelope(node, {"type": "entries", "conv": conv, "members": meta["members"], "home": meta["home"],
                                    "entries": raws})

    async def outbox(self) -> None:
        while not self.stop:
            now = time.time()
            for d in sorted(p for p in self.store.outbox.glob("*") if p.is_dir()):
                for f in sorted(d.iterdir()):
                    key = (d.name, f.name)
                    if self.next_try.get(key, 0) > now:
                        continue
                    stamp = f.stat().st_mtime
                    data = await asyncio.to_thread(self.entries_envelope, d.name, f.name)
                    if data is None:
                        f.unlink(missing_ok=True)
                        continue
                    if await self.send(d.name, data):
                        if f.exists() and f.stat().st_mtime == stamp:
                            f.unlink(missing_ok=True)       # nothing new was queued while it was sent
                        self.next_try.pop(key, None)
                    else:
                        self.next_try[key] = now + RETRY_SECONDS      # held: it waits, and is tried again
            await asyncio.sleep(0.5)

    async def hello(self) -> None:
        while not self.stop:
            if self.mesh.role == "spoke" and (time.time() - self.last_hello > HELLO_SECONDS
                                              or time.time() - self.last_roster > HELLO_SECONDS * 2):
                hub = self.mesh.node.get("hub_node")
                try:
                    data = await asyncio.to_thread(lambda: self.envelope(hub, {"type": "hello", "card": self.my_card()}))
                    if await self.send(hub, data):
                        self.last_hello = time.time()
                    else:
                        self.err(f"the hub {hub} is unreachable; trying again in {RETRY_SECONDS} s")
                        self.last_hello = time.time() - HELLO_SECONDS + RETRY_SECONDS
                except (IdentityError, OSError) as e:
                    self.err(f"hello: {e}")
                    self.last_hello = time.time()
            if self.mesh.role == "peer" and time.time() - self.last_hello > HELLO_SECONDS:
                self.last_hello = time.time()
                for node in sorted(self.mesh.peers):
                    if node in self.revoked_set():
                        continue
                    lvl = (self.net.cards().get(node) or {}).get("level") or self.mesh.level_of_domain(self.domain)
                    try:
                        data = await asyncio.to_thread(lambda n=node, lv=lvl: self.envelope(n, {"type": "hello",
                                                                                              "card": self.my_card(lv)}))
                        if not await self.send(node, data):
                            self.last_hello = time.time() - HELLO_SECONDS + RETRY_SECONDS
                    except (IdentityError, OSError) as e:
                        self.err(f"hello to {node}: {e}")
            if self.issuing:
                try:
                    stamp = self.store.roster_file.stat().st_mtime
                except OSError:
                    stamp = 0.0
                if stamp != self.roster_stamp:      # a join or a revoke: every active spoke gets the roster now
                    self.roster_stamp = stamp
                    r = identity.roster(self.store)
                    for node, n in r.get("nodes", {}).items():
                        if not n.get("revoked") and node in self.net.cards() and self.mesh.role == "hub":
                            data = await asyncio.to_thread(self.roster_envelope, node)
                            await self.send(node, data)
            await asyncio.sleep(1)

    async def renew(self) -> None:
        while not self.stop:
            try:
                if self.mesh.role == "spoke":
                    st = await asyncio.to_thread(self.store.cert_state, self.domain)
                    now_asked = self.store.root / "renew-now"
                    asked = now_asked.exists()
                    if asked:
                        now_asked.unlink(missing_ok=True)
                    if st.get("present") and (st["renew_due"] or asked) \
                            and (asked or time.time() - self.status.get("renew_asked", 0) > 60):
                        req = await asyncio.to_thread(identity.csr, self.store.key(self.domain), self.mesh.node_id)
                        hub = self.mesh.node.get("hub_node")
                        data = await asyncio.to_thread(self.envelope, hub, {"type": "renew", "csr": req})
                        if await self.send(hub, data):
                            self.status["renew_asked"] = time.time()
                elif self.issuing:
                    for dom in self.mesh.domains_issued():
                        st = await asyncio.to_thread(self.store.cert_state, dom)
                        if not st.get("present") or st["renew_due"]:
                            await asyncio.to_thread(ensure_own_cert, self.fac, dom, st.get("present", False))
                            self.restart_slim = True
            except (IdentityError, OSError) as e:
                self.err(f"renewal: {e}")
            if self.restart_slim:
                self.restart_slim = False
                inf = self.fac.infra()
                await asyncio.to_thread(inf.down_one, "slim")
                await asyncio.to_thread(inf.up_one, "slim")
                # this part's connection to its SLIM node died with it, and a SLIM app cannot be re-attached: start again
                # (found running the flow: with certificates renewed at half life, every renewal otherwise left this part
                # deaf and mute until the container restarted)
                self.reexec = True
            await asyncio.sleep(2)

    async def joins(self) -> None:
        """The join endpoints: the private one (tokens: a hub's spokes, a peer's pairing) while a token is live; the public
        one (join requests, no token) while a person's request window is open or a request waits. Each closes 30 s after
        its last reason ends."""
        while not self.stop:
            if self.issuing:
                for kind in ("private", "public"):
                    addr = self.mesh.node.get("join") if kind == "private" else (self.mesh.node.get("public") or {}).get("join")
                    if not addr:
                        continue
                    live = (identity.live_tokens(self.store) if kind == "private"
                            else identity.window_open(self.store) or identity.live_requests(self.store))
                    if live:
                        self.join_until[kind] = time.time() + 30
                    if (live or time.time() < self.join_until.get(kind, 0)) and self.join_servers.get(kind) is None:
                        try:
                            self.open_join(kind)
                        except (OSError, IdentityError, ssl.SSLError) as e:
                            self.err(f"the {kind} join endpoint did not open: {e}")
                    elif not live and time.time() >= self.join_until.get(kind, 0) and self.join_servers.get(kind) is not None:
                        self.close_join(kind)
            self.write_status()
            if self.reexec:
                self.close_join()
                self.write_status()
                os.execv(sys.executable, [sys.executable, *sys.orig_argv[1:]])
            await asyncio.sleep(1)

    # ------------------------------------------------------------ the join endpoint (a hub's; HTTPS)

    def open_join(self, kind: str = "private") -> None:
        public = kind == "public"
        dom = self.mesh.public_domain if public else self.domain
        host, port = mesh_mod.parse_addr((self.mesh.node.get("public") or {}).get("join") if public else self.mesh.node["join"])
        daemon = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, code: int, body, ctype="application/json"):
                data = body if isinstance(body, bytes) else json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if self.path == "/v1/bundle":
                    return self.reply(200, daemon.store.bundle(dom).read_bytes(), "application/x-pem-file")
                return self.reply(404, {"error": "no such path"})

            def do_POST(self):
                paths = ("/v1/request", "/v1/request/status") if public else ("/v1/join", "/v1/pair")
                if self.path not in paths:
                    return self.reply(404, {"error": "no such path"})
                n = int(self.headers.get("Content-Length") or 0)
                if n > 16384:
                    return self.reply(413, {"error": "too large"})
                try:
                    req = json.loads(self.rfile.read(n))
                    fn = {"/v1/join": daemon.join, "/v1/pair": daemon.pair, "/v1/request": daemon.request,
                          "/v1/request/status": daemon.request_status}[self.path]
                    code, body = fn(req)
                except (ValueError, KeyError, TypeError):
                    code, body = 400, {"error": "a malformed request"}
                return self.reply(code, body)

        srv = http.server.ThreadingHTTPServer((host, port), H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(str(self.store.cert(dom)), str(self.store.key(dom)))
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        self.join_servers[kind] = srv
        threading.Thread(target=srv.serve_forever, name=f"join-{kind}", daemon=True).start()
        print(f"facilitator-peers: the {kind} join endpoint is open on {host}:{port}", file=sys.stderr, flush=True)

    def close_join(self, kind: str | None = None) -> None:
        for k in ([kind] if kind else list(self.join_servers)):
            srv = self.join_servers.pop(k, None)
            if srv is not None:
                srv.shutdown()
                srv.server_close()
                print(f"facilitator-peers: the {k} join endpoint is closed", file=sys.stderr, flush=True)

    # ------------------------------------------------------------ pairing two peers (private, a token)

    def pair(self, req: dict) -> tuple[int, dict]:
        """A peer's pairing request (`node peer --token`): the two exchange the bundles of their own domains and the
        accepter hands over the mesh secret; each then lists the other in node.peers and trusts its domain at private."""
        if self.mesh.role != "peer":
            return 400, {"error": "this node is not a peer (a hub's spokes join with a join request: node join)"}
        node, dom = str(req["node"]), str(req["domain"])
        if not mesh_mod.NODE_ID_RE.fullmatch(node) or node == self.mesh.node_id or not mesh_mod.DOMAIN_RE.fullmatch(dom):
            return 400, {"error": "a node id and a domain, not this node's"}
        ok, why = identity.consume_token(self.store, str(req["token_id"]), str(req["secret"]))
        if not ok:
            _log_refusal(self.store, f"a pairing by {node}", why)
            return 403, {"error": why}
        cur = mesh_mod.load(self.fac.s)          # what mesh.yml says now (an earlier pairing may have changed it)
        if dom == self.domain or dom in cur.trust or node in cur.peers:
            return 409, {"error": f"{node} or {dom} is known here already (a second pairing needs a new id and domain)"}
        if not identity.pem_blocks(str(req["bundle"])):
            return 400, {"error": "no CA certificate in the bundle"}
        self.store.write_bundle(dom, str(req["bundle"]))
        mesh_mod.write_node(self.mesh.path, {"peers": {**cur.peers, node: "incoming"}}, trust={dom: "private"})
        pj = self.store.root / "peers.json"
        try:
            d = json.loads(pj.read_text())
        except (OSError, ValueError):
            d = {}
        d[node] = {"domain": dom, "name": str(req.get("name", "")), "paired": identity.now_utc()}
        pj.write_text(json.dumps(d, sort_keys=True))
        (self.store.root / "reload").write_text(identity.now_utc() + "\n")
        self.reexec = True                  # the trust and the peers list changed: SLIM and this part restart on them
        host, port = mesh_mod.parse_addr(self.mesh.node["listen"]["private"])
        try:
            self.fac.audit.append("join-approved", node, "pairing token", f"peer paired in {dom}")
        except Exception:                   # noqa: BLE001
            pass
        return 200, {"domain": self.domain, "node": self.mesh.node_id, "name": self.mesh.node["name"],
                     "bundle": self.store.bundle(self.domain).read_text(), "mesh_secret": self.store.mesh_secret(),
                     "slim": f"{self.mesh.node['name']}:{port}", "level": "private"}

    # ------------------------------------------------------------ public join requests (a key, then a person)

    def request(self, req: dict) -> tuple[int, dict]:
        node = str(req["node"])
        if not mesh_mod.NODE_ID_RE.fullmatch(node) or node == self.mesh.node_id:
            return 400, {"error": f"node id {node!r}: lower-case letters, digits and -, not this node's"}
        try:
            row = identity.add_request(self.store, node, self.mesh.public_domain, str(req["csr"]), str(req["secret_hash"]))
        except IdentityError as e:
            _log_refusal(self.store, f"a join request by {node}", str(e))
            return 403, {"error": str(e)}
        try:
            self.fac.audit.append("join-requested", node, "public request", f"key {row['fp'][:16]}")
        except Exception:                   # noqa: BLE001
            pass
        return 200, {"id": row["id"], "fp": row["fp"], "status": "pending"}

    def request_status(self, req: dict) -> tuple[int, dict]:
        row = identity.get_request(self.store, str(req["id"]))
        if row is None or not hmac_ok(row["secret_hash"], str(req["secret"])):
            return 403, {"error": "no such request"}
        if row["status"] != "approved":
            return 200, {"status": row["status"]}
        dom = self.mesh.public_domain
        host, port = mesh_mod.parse_addr(self.mesh.node["listen"]["public"])
        identity.update_request(self.store, row["id"], status="collected")
        return 200, {"status": "approved", "domain": dom, "level": "public", "cert": row["cert"],
                     "bundle": self.store.bundle(dom).read_text(), "mesh_secret": self.store.mesh_secret(),
                     "hub": {"node": self.mesh.node_id, "name": self.mesh.node["name"], "slim": f"{self.mesh.node['name']}:{port}"},
                     "hub_card": self.my_card("public", dom)}

    def join(self, req: dict) -> tuple[int, dict]:
        node = str(req["node"])
        if not mesh_mod.NODE_ID_RE.fullmatch(node) or node == self.mesh.node_id:
            return 400, {"error": f"node id {node!r}: lower-case letters, digits and -, not the hub's"}
        ok, why = identity.consume_token(self.store, str(req["token_id"]), str(req["secret"]))
        if not ok:
            _log_refusal(self.store, f"a join by {node}", why)
            return 403, {"error": why}
        r = identity.roster(self.store)
        cur = r.setdefault("nodes", {}).get(node)
        if cur and cur.get("revoked"):
            _log_refusal(self.store, f"a join by {node}", "the node is revoked")
            return 403, {"error": f"the node {node} is revoked on this hub"}
        if cur:
            return 409, {"error": f"the node {node} has joined already (a second node needs another id)"}
        level = self.mesh.level_of_domain(self.domain)
        try:
            iss = identity.make_issuer(self.mesh, self.store, self.domain)
            got = iss.sign(str(req["csr"]), node, f"{node}.{self.domain}", self.mesh.svid_seconds(level))
        except IdentityError as e:
            self.err(f"join of {node}: {e}")
            return 503, {"error": f"the hub's issuer: {e}"}
        r["nodes"][node] = {"serial": got["serial"], "joined": identity.now_utc(), "revoked": False, "domain": self.domain}
        identity.save_roster(self.store, r)
        self.backup(r)
        host, port = mesh_mod.parse_addr(self.mesh.node["listen"][level])
        return 200, {"domain": self.domain, "level": level, "cert": got["cert"], "hub_directory": self.hub_directory(),
                     "bundle": self.store.bundle(self.domain).read_text(), "mesh_secret": self.store.mesh_secret(),
                     "hub": {"node": self.mesh.node_id, "name": self.mesh.node["name"],
                             "slim": f"{self.mesh.node['name']}:{port}"},
                     "hub_card": self.my_card()}

    # ------------------------------------------------------------ run

    async def main(self) -> int:
        self.store.ensure()
        marker = self.store.root / "reload"
        if marker.exists():                 # a pairing changed mesh.yml's trust and peers: SLIM re-renders its config
            marker.unlink(missing_ok=True)
            inf = self.fac.infra()
            await asyncio.to_thread(inf.down_one, "slim")
            await asyncio.to_thread(inf.up_one, "slim")
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, self.halt)
        while not self.stop:
            try:
                await self.connect()
                break
            except Exception as e:             # noqa: BLE001 - SLIM not up yet: try again
                self.err(f"connecting to the node's SLIM: {e}")
                self.write_status()
                await asyncio.sleep(2)
        tasks = [loop.create_task(x()) for x in (self.listen, self.outbox, self.hello, self.renew, self.joins, self.rotation)]
        print(f"facilitator-peers: running as {ORG}/{NODE_NS}/{self.mesh.node_id} (role {self.mesh.role})",
              file=sys.stderr, flush=True)
        while not self.stop:
            await asyncio.sleep(0.5)
        for t in tasks:
            t.cancel()
        self.close_join()
        self.status["connected"] = False
        self.write_status()
        return 0

    def halt(self) -> None:
        self.stop = True


def ensure_own_cert(fac, dom: str | None = None, force: bool = False) -> str:
    """This node's own certificate in a domain it issues in (a hub's issuer domain, a peer's own, a public one), from that
    domain's issuer, with this node's DNS name (its dialers' server_name), and the domain's trust bundle; again at half
    life. Returns what it did."""
    m = fac.mesh
    store = identity.Store(fac.state.home)
    dom = dom or m.domain
    st = store.cert_state(dom)
    if st.get("present") and not st["renew_due"] and not force and store.bundle(dom).is_file():
        return "present"
    store.ensure()
    iss = identity.make_issuer(m, store, dom)
    ttl = m.svid_seconds(m.level_of_domain(dom))
    if isinstance(iss, identity.LocalIssuer):
        iss.issue_self(m.node_id, m.node["name"], ttl)
    else:
        store.dom(dom).mkdir(parents=True, exist_ok=True)
        if not store.key(dom).is_file():
            identity.new_key(store.key(dom))
        got = iss.sign(identity.csr(store.key(dom), m.node["name"]), m.node_id, m.node["name"], ttl)
        store.write_bundle(dom, iss.bundle())
        store.cert(dom).write_text(got["cert"])
    store.mesh_secret(create=True)
    return "issued"


def ensure_hub_cert(fac, force: bool = False) -> str:
    return ensure_own_cert(fac, None, force)


def _post_verified(host: str, port: int, name: str, bundle: str, path: str, body: bytes) -> tuple[int, dict]:
    """POST over TLS 1.3 to a server whose certificate must chain to `bundle` and carry the DNS name `name`."""
    ctx = ssl.create_default_context(cadata=bundle)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    try:
        with socket.create_connection((host, port), timeout=30) as raw, \
                ctx.wrap_socket(raw, server_hostname=name) as s:
            req = (f"POST {path} HTTP/1.1\r\nHost: {name}\r\nContent-Type: application/json\r\n"
                   f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body
            s.sendall(req)
            chunks = []
            while True:
                b = s.recv(65536)
                if not b:
                    break
                chunks.append(b)
    except ssl.SSLError as e:
        raise PeersError(f"the hub's certificate is not {name} from the token's domain: {e}") from None
    except OSError as e:
        raise PeersError(f"the hub's join endpoint {host}:{port}: {e}") from None
    head, _, rest = b"".join(chunks).partition(b"\r\n\r\n")
    try:
        status = int(head.split(b" ", 2)[1])
        return status, json.loads(rest or b"{}")
    except (IndexError, ValueError):
        raise PeersError("the hub's join endpoint answered something that is not a join answer") from None


def join(fac, hub: str | None, token: str) -> dict:
    """`facilitator node join <hub> --token`: a spoke gets a certificate from the hub's issuer. The token names
    the join endpoint and the SHA-256 of the domain's trust bundle: the bundle is fetched, checked against it,
    and only then trusted to check the hub's certificate (no trust on first use). Writes the certificate, the
    bundle and the mesh secret into the state folder, and the hub into mesh.yml (role spoke, a static SLIM link
    of type peer is rendered from it at the next infra up)."""
    import urllib.request
    t = identity.parse_token(token)
    if not fac.mesh.path:
        raise PeersError("no mesh file path (FACILITATOR_MESH_FILE)")
    addr = hub or t["j"]
    host, port = mesh_mod.parse_addr(addr)
    m = fac.mesh
    node = m.node.get("id") or mesh_mod.default_node_id()
    store = identity.Store(fac.state.home)
    store.ensure()
    unverified = ssl.create_default_context()
    unverified.check_hostname = False
    unverified.verify_mode = ssl.CERT_NONE       # only to fetch the bundle, which the token's hash then checks
    try:
        with urllib.request.urlopen(f"https://{host}:{port}/v1/bundle", context=unverified, timeout=20) as r:
            bundle = r.read().decode()
    except OSError as e:
        raise PeersError(f"the hub's join endpoint {host}:{port} is not reachable ({e}); a join token opens it for 15 minutes") from None
    if hashlib.sha256(bundle.encode()).hexdigest() != t["b"]:
        raise PeersError("the hub's trust bundle does not match the token's hash: not joining (a wrong hub, or one in between)")
    tmpkey = store.root / f".join-{os.getpid()}.key"
    identity.new_key(tmpkey)
    try:
        body = json.dumps({"token_id": t["i"], "secret": t["s"], "node": node,
                           "csr": identity.csr(tmpkey, node)}).encode()
        status, data = _post_verified(host, port, t["n"], bundle, "/v1/join", body)
        if status != 200:
            raise PeersError(f"the hub refused the join: {data.get('error', status)}")
        dom = data["domain"]
        if hashlib.sha256(data["bundle"].encode()).hexdigest() != t["b"]:
            raise PeersError("the bundle in the hub's answer is not the one the token names")
        store.dom(dom).mkdir(parents=True, exist_ok=True)
        os.chmod(store.dom(dom), 0o700)
        os.replace(tmpkey, store.key(dom))
    finally:
        tmpkey.unlink(missing_ok=True)
    store.write_bundle(dom, data["bundle"])
    store.cert(dom).write_text(data["cert"])
    store.set_mesh_secret(data["mesh_secret"])
    if data.get("hub_directory"):
        (store.root / "hub-directory.json").write_text(json.dumps(data["hub_directory"], sort_keys=True))
    mesh_mod.write_node(m.path, {"id": node, "hub": data["hub"]["slim"], "hub_name": data["hub"]["name"],
                                 "hub_node": data["hub"]["node"], "domain": dom}, role="spoke",
                        trust={dom: data["level"]})
    return {"node": node, "domain": dom, "level": data["level"], "hub": data["hub"],
            "id": f"spiffe://{dom}/node/{node}", "mesh_file": str(m.path)}


def pair_with(fac, addr: str | None, token: str) -> dict:
    """`facilitator node peer --token`: pairs this peer with the one that made the token. The token names its join endpoint
    and the SHA-256 of its CA bundle, which is checked before it is trusted (no trust on first use). Each side then holds
    the other's bundle; this one adopts the accepter's mesh secret and lists it in node.peers with its SLIM address."""
    import urllib.request
    m = fac.mesh
    if m.role != "peer":
        raise PeersError("node peer: this node's role is not peer (mesh.yml role peer, node.name and node.domain first)")
    t = identity.parse_token(token)
    host, port = mesh_mod.parse_addr(addr or t["j"])
    store = identity.Store(fac.state.home)
    store.ensure()
    ensure_own_cert(fac, m.domain)
    unverified = ssl.create_default_context()
    unverified.check_hostname = False
    unverified.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(f"https://{host}:{port}/v1/bundle", context=unverified, timeout=20) as r:
            bundle = r.read().decode()
    except OSError as e:
        raise PeersError(f"the peer's join endpoint {host}:{port} is not reachable ({e}); a token opens it for 15 minutes") from None
    if hashlib.sha256(bundle.encode()).hexdigest() != t["b"]:
        raise PeersError("the peer's CA bundle does not match the token's hash: not pairing (a wrong peer, or one in between)")
    body = json.dumps({"token_id": t["i"], "secret": t["s"], "node": m.node_id, "name": m.node["name"], "domain": m.domain,
                       "bundle": store.bundle(m.domain).read_text()}).encode()
    status, data = _post_verified(host, port, t["n"], bundle, "/v1/pair", body)
    if status != 200:
        raise PeersError(f"the peer refused the pairing: {data.get('error', status)}")
    if hashlib.sha256(data["bundle"].encode()).hexdigest() != t["b"]:
        raise PeersError("the bundle in the peer's answer is not the one the token names")
    dom = data["domain"]
    store.write_bundle(dom, data["bundle"])
    store.set_mesh_secret(data["mesh_secret"])
    pj = store.root / "peers.json"
    try:
        d = json.loads(pj.read_text())
    except (OSError, ValueError):
        d = {}
    d[data["node"]] = {"domain": dom, "name": data["name"], "paired": identity.now_utc()}
    pj.write_text(json.dumps(d, sort_keys=True))
    mesh_mod.write_node(m.path, {"peers": {**m.peers, data["node"]: data["slim"]}}, trust={dom: "private"})
    (store.root / "reload").write_text(identity.now_utc() + "\n")
    return {"node": data["node"], "domain": dom, "slim": data["slim"], "mesh_file": str(m.path)}


def request_public(fac, info: dict) -> dict:
    """`facilitator node request <info>`: asks a node to let this one join its public domain. `info` is what the issuing node's
    `node invite --level public` printed (its public join endpoint, DNS name, CA bundle); the bundle is trusted because a
    person gave it over a channel of their own, and its hash is shown to compare. Sends a key (a request signed by it) and
    keeps a secret to collect the answer; nothing is issued until a person on the other side runs `node approve`."""
    m = fac.mesh
    if m.role not in ("standalone", "spoke"):
        raise PeersError(f"node request: a {m.role} issues its own certificates; a public node is a spoke of the issuer's public domain")
    for k in ("domain", "join", "name", "node", "slim", "bundle"):
        if not info.get(k):
            raise PeersError(f"node request: the info lacks {k!r} (the output of `node invite --level public` on the issuing node)")
    host, port = mesh_mod.parse_addr(info["join"])
    store = identity.Store(fac.state.home)
    store.ensure()
    node = m.node.get("id") or mesh_mod.default_node_id()
    key = store.root / "request.key"
    identity.new_key(key)
    secret = secrets_token()
    body = json.dumps({"node": node, "csr": identity.csr(key, node),
                       "secret_hash": hashlib.sha256(secret.encode()).hexdigest()}).encode()
    status, data = _post_verified(host, port, info["name"], info["bundle"], "/v1/request", body)
    if status != 200:
        raise PeersError(f"the node refused the request: {data.get('error', status)}")
    pend = {"id": data["id"], "secret": secret, "info": {k: info[k] for k in ("domain", "join", "name", "node", "slim", "bundle")},
            "node": node, "fp": data["fp"], "at": identity.now_utc()}
    identity._private(store.root / "pending-request.json", json.dumps(pend, sort_keys=True))
    return {"id": data["id"], "fp": data["fp"], "node": node, "bundle_sha256": hashlib.sha256(info["bundle"].encode()).hexdigest()}


def secrets_token() -> str:
    import secrets as _s
    return _s.token_urlsafe(24)


def collect_public(fac) -> dict:
    """`facilitator node collect`: asks the issuing node whether a person approved this node's request; when it did, installs the
    certificate (1 h; renewed at half life while the issuer allows it), the bundle and the mesh secret, and writes mesh.yml
    (role spoke of the public domain)."""
    store = identity.Store(fac.state.home)
    try:
        pend = json.loads((store.root / "pending-request.json").read_text())
    except (OSError, ValueError):
        raise PeersError("node collect: no pending request (facilitator node request <info>)") from None
    info = pend["info"]
    host, port = mesh_mod.parse_addr(info["join"])
    status, data = _post_verified(host, port, info["name"], info["bundle"], "/v1/request/status",
                                  json.dumps({"id": pend["id"], "secret": pend["secret"]}).encode())
    if status != 200:
        raise PeersError(f"the node refused: {data.get('error', status)}")
    if data["status"] != "approved":
        return {"status": data["status"], "id": pend["id"]}
    dom = data["domain"]
    store.dom(dom).mkdir(parents=True, exist_ok=True)
    os.chmod(store.dom(dom), 0o700)
    os.replace(store.root / "request.key", store.key(dom))
    store.write_bundle(dom, data["bundle"])
    store.cert(dom).write_text(data["cert"])
    store.set_mesh_secret(data["mesh_secret"])
    mesh_mod.write_node(fac.mesh.path, {"id": pend["node"], "hub": data["hub"]["slim"], "hub_name": data["hub"]["name"],
                                        "hub_node": data["hub"]["node"], "domain": dom}, role="spoke", trust={dom: "public"},
                        preset="open")
    (store.root / "pending-request.json").unlink(missing_ok=True)
    return {"status": "approved", "node": pend["node"], "domain": dom, "id": f"spiffe://{dom}/node/{pend['node']}",
            "hub": data["hub"], "mesh_file": str(fac.mesh.path)}
