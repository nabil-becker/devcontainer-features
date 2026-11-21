"""The peers module (proposal facilitator-node, sections 4, 5.3, 8, 10 and 12; slice N3): what crosses from one
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

from . import identity, mesh as mesh_mod
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
        return self.mesh.role in ("spoke", "hub")

    # ------------------------------------------------------------ cards

    def cards(self) -> dict[str, dict]:
        """node -> {card, level}: the cards this node's peers daemon admitted (lock two), the revoked dropped."""
        out = {}
        d = self.store.cards
        if not d.is_dir():
            return out
        for f in sorted(d.glob("*.json")):
            try:
                c = json.loads(f.read_text())
            except (OSError, ValueError):
                continue
            if c.get("card", {}).get("node") and c["card"]["node"] != self.mesh.node_id:
                out[c["card"]["node"]] = c
        return out

    def save_card(self, card: dict, level: str) -> None:
        self.store.ensure()
        p = self.store.cards / f"{card['node']}.json"
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps({"card": card, "level": level, "admitted": identity.now_utc()}, sort_keys=True))
        os.replace(tmp, p)

    def drop_card(self, node: str) -> None:
        try:
            (self.store.cards / f"{node}.json").unlink()
        except FileNotFoundError:
            pass

    def remote(self) -> dict[str, dict]:
        """handle -> {node, key, kind, exposure, level, description, skills} of every participant another node's
        admitted card lists. A handle this node has too stays this node's (the remote one is not reachable)."""
        local = set(self.fac.state.roster()) | set(self.fac.humans())
        out: dict[str, dict] = {}
        for node, c in sorted(self.cards().items()):
            for p in c["card"].get("participants", []):
                h = p["handle"]
                if h in local or h == FACILITATOR or h in out:
                    continue
                out[h] = {**p, "node": node, "level": c["level"], "domain": c["card"]["domain"]}
        return out

    def binding(self, key: str) -> tuple[str, str, str] | None:
        """(node, principal, level) a card binds this packet key to, or None."""
        for node, c in self.cards().items():
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

    def meta(self, conv: str) -> dict | None:
        try:
            return json.loads((self.store.convs / f"{conv}.json").read_text())
        except (OSError, ValueError):
            return None

    def save_meta(self, conv: str, members: dict[str, str], home: str) -> None:
        self.store.ensure()
        p = self.store.convs / f"{conv}.json"
        tmp = p.with_suffix(".tmp")
        tmp.write_text(json.dumps({"members": members, "home": home}, sort_keys=True))
        os.replace(tmp, p)

    def nodes_of(self, conv: str) -> set[str]:
        m = self.meta(conv)
        return set((m or {}).get("members", {}).values()) - {self.mesh.node_id} if m else set()

    def anchors_extra(self, conv: str) -> dict[str, str]:
        """The facilitator keys of the other nodes a shared conversation's members are on: each may write the
        conversation's routes and notices (its own dispatcher), as `facilitator`."""
        cards = self.cards()
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
        for h, n in members.items():
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
            if local.get(key) == principal:
                return True
            for n, c in cards.items():
                if principal == FACILITATOR and c["card"].get("facilitator") == key and n in set(members.values()):
                    return True
                if any(p.get("key") == key and p["handle"] == principal for p in c["card"].get("participants", [])):
                    return True
            return False

        for raw in raws:
            try:
                e = core.parse(raw, self.fac.record.kinds)
            except Exception as ex:            # noqa: BLE001 - a malformed packet refuses the whole envelope
                return False, f"a malformed entry: {ex}"
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
        self.app = None
        self.sb = None
        self.stop = False
        self.next_try: dict[tuple, float] = {}
        self.last_hello = 0.0
        self.last_roster = 0.0
        self.roster_stamp = 0.0
        self.status = {"role": self.mesh.role, "node": self.mesh.node_id, "connected": False, "hub_seen": None,
                       "errors": []}
        self.join_server = None
        self.join_thread = None
        self.restart_slim = False

    # ------------------------------------------------------------ helpers

    def err(self, what: str) -> None:
        self.status["errors"] = (self.status["errors"] + [f"{identity.now_utc()} {what}"])[-10:]
        print(f"facilitator-peers: {what}", file=sys.stderr, flush=True)

    def write_status(self) -> None:
        self.status["at"] = identity.now_utc()
        self.status["pid"] = os.getpid()
        self.status["join_open"] = self.join_server is not None
        tmp = self.store.status_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.status, indent=2, sort_keys=True))
        os.replace(tmp, self.store.status_file)

    def bundles(self) -> dict[str, Path]:
        return self.store.bundles(self.mesh.trust)

    def my_card(self) -> dict:
        lv = self.mesh.level_of_domain(self.domain)
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
                          **({"cid": ident["cid"]} if ident.get("cid") else {})})
        return identity.make_card(self.store, self.domain, self.mesh.node_id, self.fac.record.facilitator_key(), parts)

    def envelope(self, to: str, body: dict) -> bytes:
        env = {"v": 1, "from": self.mesh.node_id, "to": to, "at": identity.now_utc(), **body}
        return json.dumps(identity.sign_envelope(self.store, self.domain, env), separators=(",", ":")).encode()

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
        secret = self.store.mesh_secret(create=self.mesh.role == "hub")
        if not secret:
            raise PeersError("no mesh secret: this spoke has not joined (facilitator node join)")
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
        if env.get("type") == "hello":
            card = env.get("card")
            if not isinstance(card, dict) or card.get("node") != node:
                return None, "a hello whose card is not its sender's"
            revoked = identity.revoked(identity.roster(self.store)) if self.mesh.role == "hub" else self.revoked_here()
            ok, level, why = identity.check_card(card, self.mesh, self.bundles(), revoked)
            if not ok:
                return None, why
            return {"card": card, "level": level}, ""
        c = self.net.cards().get(node)
        if c is None:
            if self.mesh.role == "spoke" and node == self.mesh.node.get("hub_node") and env.get("type") == "roster":
                card = env.get("hub_card") or {}
                ok, level, why = identity.check_card(card, self.mesh, self.bundles(), set())
                return ({"card": card, "level": level}, "") if ok and card.get("node") == node else (None, why or "not the hub")
            return None, f"no admitted card for the node {node!r}"
        return c, ""

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
        if env.get("from") in (identity.revoked(identity.roster(self.store)) | self.revoked_here()):
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
        if t == "hello" and self.mesh.role == "hub":
            return self.on_hello(env, c)
        if t == "roster" and self.mesh.role == "spoke":
            return self.on_roster(env, c)
        if t == "entries":
            return self.on_entries(env, c)
        if t == "renew" and self.mesh.role == "hub":
            return self.on_renew(env, c)
        if t == "renewed" and self.mesh.role == "spoke":
            return self.on_renewed(env, c)
        _log_refusal(self.store, what, f"a {t!r} envelope is not served by a {self.mesh.role}")
        return []

    def on_hello(self, env: dict, c: dict) -> list:
        node = env["from"]
        r = identity.roster(self.store)
        n = r.get("nodes", {}).get(node)
        if n is None:
            _log_refusal(self.store, f"hello from {node}", "the node has not joined this hub (no roster entry)")
            return []
        self.net.save_card(c["card"], c["level"])
        n["seen"] = identity.now_utc()
        identity.save_roster(self.store, r)
        return [(node, self.roster_envelope(node))]

    def roster_envelope(self, to: str) -> bytes:
        if not self.store.cert(self.domain).is_file():
            raise IdentityError("the hub has no certificate yet")
        r = identity.roster(self.store)
        rev = sorted(identity.revoked(r))
        cards = [c["card"] for n, c in self.net.cards().items() if n not in rev and n in r.get("nodes", {})]
        return self.envelope(to, {"type": "roster", "hub_card": self.my_card(), "cards": cards, "revoked": rev})

    def on_roster(self, env: dict, c: dict) -> list:
        if env["from"] != self.mesh.node.get("hub_node"):
            _log_refusal(self.store, f"roster from {env['from']}", "only this spoke's hub serves its roster")
            return []
        rev = set(env.get("revoked") or [])
        (self.store.root / "revoked.json").write_text(json.dumps(sorted(rev)))
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
            if node not in keep:
                self.net.drop_card(node)
        self.status["hub_seen"] = identity.now_utc()
        self.last_roster = time.time()
        return []

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
        self.net.save_meta(conv, members, env.get("home") or env["from"])
        rec = self.fac.record
        store = rec.store(conv)
        rep = adapters.sync([adapters.raws(store), raws], store, rec.anchors_for(conv), rec.checked, conv, rec.kinds)
        if rep.refused:
            self.err(f"{conv}: {len(rep.refused)} entr(y/ies) refused by the register: "
                     + "; ".join(f"{i[:12]} {c_[0]}" for i, c_ in list(rep.refused.items())[:3]))
            if old is None and not any(store.ids()):
                (self.store.convs / f"{conv}.json").unlink(missing_ok=True)
        return []

    def on_renew(self, env: dict, c: dict) -> list:
        node = env["from"]
        r = identity.roster(self.store)
        n = r.get("nodes", {}).get(node)
        if n is None or n.get("revoked"):
            _log_refusal(self.store, f"renew from {node}", "revoked or not joined: no renewal (node revoke stops renewal)")
            return []
        try:
            iss = identity.Issuer(self.mesh.node["issuer"])
            got = iss.sign(env["csr"], node, f"{node}.{self.domain}", self.mesh.svid_seconds(c["level"]))
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
            identity.Issuer(self.mesh.node["issuer"]).backup_roster(r)
        except (IdentityError, KeyError) as e:
            self.err(f"the roster was not backed up to OpenBao: {e}")

    # ------------------------------------------------------------ the loops

    def entries_envelope(self, node: str, conv: str) -> bytes | None:
        meta = self.net.meta(conv)
        if not meta:
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
            if self.mesh.role == "hub":
                try:
                    stamp = self.store.roster_file.stat().st_mtime
                except OSError:
                    stamp = 0.0
                if stamp != self.roster_stamp:      # a join or a revoke: every active spoke gets the roster now
                    self.roster_stamp = stamp
                    r = identity.roster(self.store)
                    for node, n in r.get("nodes", {}).items():
                        if not n.get("revoked") and node in self.net.cards():
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
                elif self.mesh.role == "hub":
                    st = await asyncio.to_thread(self.store.cert_state, self.domain)
                    if not st.get("present") or st["renew_due"]:
                        await asyncio.to_thread(ensure_hub_cert, self.fac, st.get("present", False))
                        self.restart_slim = True
            except (IdentityError, OSError) as e:
                self.err(f"renewal: {e}")
            if self.restart_slim:
                self.restart_slim = False
                inf = self.fac.infra()
                await asyncio.to_thread(inf.down_one, "slim")
                await asyncio.to_thread(inf.up_one, "slim")
            await asyncio.sleep(2)

    async def joins(self) -> None:
        while not self.stop:
            if self.mesh.role == "hub" and self.mesh.node.get("join"):
                live = identity.live_tokens(self.store)
                if live and self.join_server is None:
                    try:
                        self.open_join()
                    except (OSError, IdentityError, ssl.SSLError) as e:
                        self.err(f"the join endpoint did not open: {e}")
                elif not live and self.join_server is not None:
                    self.close_join()
            self.write_status()
            await asyncio.sleep(1)

    # ------------------------------------------------------------ the join endpoint (a hub's; HTTPS)

    def open_join(self) -> None:
        host, port = mesh_mod.parse_addr(self.mesh.node["join"])
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
                    return self.reply(200, daemon.store.bundle(daemon.domain).read_bytes(), "application/x-pem-file")
                return self.reply(404, {"error": "no such path"})

            def do_POST(self):
                if self.path != "/v1/join":
                    return self.reply(404, {"error": "no such path"})
                n = int(self.headers.get("Content-Length") or 0)
                if n > 16384:
                    return self.reply(413, {"error": "too large"})
                try:
                    req = json.loads(self.rfile.read(n))
                    code, body = daemon.join(req)
                except (ValueError, KeyError, TypeError):
                    code, body = 400, {"error": "a join request is {token_id, secret, node, csr}"}
                return self.reply(code, body)

        srv = http.server.ThreadingHTTPServer((host, port), H)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(str(self.store.cert(self.domain)), str(self.store.key(self.domain)))
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        self.join_server = srv
        self.join_thread = threading.Thread(target=srv.serve_forever, name="join", daemon=True)
        self.join_thread.start()
        print(f"facilitator-peers: the join endpoint is open on {host}:{port} (a join token is live)", file=sys.stderr, flush=True)

    def close_join(self) -> None:
        srv, self.join_server = self.join_server, None
        if srv is not None:
            srv.shutdown()
            srv.server_close()
            print("facilitator-peers: the join endpoint is closed (no join token is live)", file=sys.stderr, flush=True)

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
            iss = identity.Issuer(self.mesh.node["issuer"])
            got = iss.sign(str(req["csr"]), node, f"{node}.{self.domain}", self.mesh.svid_seconds(level))
        except IdentityError as e:
            self.err(f"join of {node}: {e}")
            return 503, {"error": f"the hub's issuer: {e}"}
        r["nodes"][node] = {"serial": got["serial"], "joined": identity.now_utc(), "revoked": False}
        identity.save_roster(self.store, r)
        self.backup(r)
        host, port = mesh_mod.parse_addr(self.mesh.node["listen"][level])
        return 200, {"domain": self.domain, "level": level, "cert": got["cert"],
                     "bundle": self.store.bundle(self.domain).read_text(), "mesh_secret": self.store.mesh_secret(),
                     "hub": {"node": self.mesh.node_id, "name": self.mesh.node["name"],
                             "slim": f"{self.mesh.node['name']}:{port}"},
                     "hub_card": self.my_card()}

    # ------------------------------------------------------------ run

    async def main(self) -> int:
        self.store.ensure()
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
        tasks = [loop.create_task(x()) for x in (self.listen, self.outbox, self.hello, self.renew, self.joins)]
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


def ensure_hub_cert(fac, force: bool = False) -> str:
    """A hub's own certificate in its issuer's domain, issued by that domain's OpenBao PKI with the hub's DNS
    name (the spokes' server_name), and the domain's trust bundle; again at half life. Returns what it did."""
    m = fac.mesh
    store = identity.Store(fac.state.home)
    dom = m.domain
    st = store.cert_state(dom)
    if st.get("present") and not st["renew_due"] and not force and store.bundle(dom).is_file():
        return "present"
    iss = identity.Issuer(m.node["issuer"])
    store.ensure()
    store.dom(dom).mkdir(parents=True, exist_ok=True)
    if not store.key(dom).is_file():
        identity.new_key(store.key(dom))
    got = iss.sign(identity.csr(store.key(dom), m.node["name"]), m.node_id, m.node["name"],
                   m.svid_seconds(m.level_of_domain(dom)))
    store.write_bundle(dom, iss.bundle())
    store.cert(dom).write_text(got["cert"])
    store.mesh_secret(create=True)
    return "issued"


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
    mesh_mod.write_node(m.path, {"id": node, "hub": data["hub"]["slim"], "hub_name": data["hub"]["name"],
                                 "hub_node": data["hub"]["node"], "domain": dom}, role="spoke",
                        trust={dom: data["level"]})
    return {"node": node, "domain": dom, "level": data["level"], "hub": data["hub"],
            "id": f"spiffe://{dom}/node/{node}", "mesh_file": str(m.path)}
