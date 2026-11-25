"""The facilitator application's deterministic core (proposal 4.3): intake, guard, router, dispatcher,
collector, signer, over the record (register-engine) and the transport (SLIM). It runs in whichever
process writes: the MCP server of a participant or of a person, and the model wrapper. No model is
called in this version; nothing here starts or stops a participant."""
from __future__ import annotations

import datetime as dt
import json
import time
from dataclasses import dataclass, field

from . import __version__, clients as clients_mod, collector, directory, guard, mesh as mesh_mod, participants, router, transport
from .infra import Infra
from .record import FACILITATOR, Record, RecordError, new_id
from .settings import Settings
from .signer import Signer
from .state import State


MESSAGE_APPROVALS = mesh_mod.MESSAGE_APPROVALS
HELD_DAYS = 7            # a first-contact message nobody answers is held this long (ruling BG)


class FacilitatorError(RuntimeError):
    pass


def _ago(t: float | None) -> str:
    if t is None:
        return "never"
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")


@dataclass
class Turn:
    """What a participant is answering: the deliveries `receive` handed over (A2A tasks), the last one first
    for the lineage."""
    conv: str
    message_id: str
    root: str
    root_thread: str
    hops: int
    tasks: list[tuple[str, str]] = field(default_factory=list)     # (conversation, task)


class Facilitator:
    def __init__(self, settings: Settings):
        self.s = settings
        settings.backend()            # lean is refused here, by name
        self.state = State(settings.home)
        self.signer = Signer(self.state, settings["FACILITATOR_KEYS"])
        self.limits = guard.Limits(settings.int("FACILITATOR_HOP_LIMIT", 1), settings.int("FACILITATOR_MESSAGE_BUDGET", 1),
                                   settings.int("FACILITATOR_RATE_LIMIT", 1))
        self.stale = settings.int("FACILITATOR_STALE_SECONDS", 1)
        self.mesh_file = mesh_mod.load(settings)          # as written, with its findings (check shows them)
        self.mesh = mesh_mod.effective(self.mesh_file)    # what runs: standalone when the file has findings
        self._record: Record | None = None
        self._list = None
        self._net = None
        self.clients = clients_mod.Clients(self.state)
        from .audit import Audit
        self.audit = Audit(self)
        self.clients.sink = self.audit.on_line          # every enrolment event is also a signed entry (ruling HC3)

    # ------------------------------------------------------------ parts, made when first needed

    @property
    def net(self):
        if self._net is None:
            from .peers import Net
            self._net = Net(self)
        return self._net

    @property
    def record(self) -> Record:
        if self._record is None:
            self.state.ensure()
            self._record = Record(self.state, self.signer, self.net)
        return self._record

    def limits_for(self, level: str) -> guard.Limits:
        """The loop guard's limits at a level (ruling AD: the preset's, then the Feature options, then mesh.yml)."""
        if level == "local" and not self.mesh.limits_file.get("local"):
            return self.limits
        g = lambda k: self.mesh.limit(level, k, self.s)[0]      # noqa: E731
        return guard.Limits(g("hops"), g("budget"), g("rate"))

    # ------------------------------------------------------------ HTTP clients (slice N4)

    def is_http(self, handle: str) -> bool:
        """Whether a handle is one of this node's HTTP clients (a roster entry of kind http)."""
        return self.state.roster().get(handle, {}).get("kind") == "http"

    def caller_level(self, handle: str) -> str:
        """The level a caller reaches from: an HTTP client's is its domain's (http.<home domain>: public unless
        mesh.yml maps it private); everything on this node is local."""
        return self.mesh.http_level() if self.is_http(handle) else "local"

    def visible(self, caller: str, handle: str) -> bool:
        """The reach rule for one name: whether `caller` may see and message `handle`. A local caller sees all; an HTTP
        client sees only what is exposed at its level or wider, never another HTTP client, never another node's."""
        if not self.is_http(caller):
            return True
        if self.is_http(handle) or handle == FACILITATOR:
            return False
        return mesh_mod.reach_ok(self.caller_level(caller), self.mesh.exposure(handle))

    def known_for(self, author: str) -> set[str]:
        """The names the router may meet for a message of `author`: for an HTTP client only what it may see, so a
        mention of an agent it cannot reach reads the same as one that does not exist."""
        k = self.known() | set(self.humans())
        if not self.is_http(author):
            return k
        return {h for h in k if self.visible(author, h)}

    def http_precheck(self, handle: str, text: str) -> None:
        """The abuse limits of an HTTP client, before anything is written (so a refusal leaves no empty conversation):
        the level's max_packet, and its rate counted for the client across all its conversations (proposal 11.3: per
        client, however many conversations or connections it opens)."""
        if not self.is_http(handle):
            return
        level = self.mesh.http_level()
        cap = mesh_mod.size(self.mesh.limit(level, "max_packet")[0])
        n = len((text or "").encode())
        if n > cap:
            raise FacilitatorError(f"message too large: {n} bytes; the {level} level's max_packet is {cap}; "
                                   "this message was not written")
        rate = self.limits_for(level).rate_limit
        now, count = time.time(), 0
        for c in self.conversations_of(handle):
            _, proj, _ = self.record.read(c)
            count += sum(1 for m in proj["messages"].values() if m["from"] == handle and now - guard._t(m["at"]) < 60)
        if count >= rate:
            raise FacilitatorError(f"rate limit: {handle} wrote {count} messages in the last minute; the {level} level allows "
                                   f"{rate} a minute for a client, counted across all its conversations; this one was not written")

    def approval_gate(self, handle: str, now: float, conv: str | None = None, mid: str | None = None,
                      led=None, proj=None) -> guard.Verdict | None:
        """The approval of limits.<level>.approval for an HTTP client's message (proposal 7): a Verdict that holds it
        until a person approves; None when no approval is needed or it stands. first-contact asks once per client
        (and per approval_ttl); every-message asks for each message, per-conversation for the first of each of the
        client's conversations (the person's answer is a notice of this node's facilitator in the conversation)."""
        handle = self.local_of(handle) or handle
        if not self.is_http(handle):
            return None
        level = self.mesh.http_level()
        mode = self.mesh.limit(level, "approval")[0]
        if mode == "none":
            return None
        how = (f"(facilitator approve {mid or '<message>'}, or the approve tool of a person's session); held up to "
               f"{HELD_DAYS} days")
        if mode == "first-contact":
            ttl = mesh_mod.seconds(self.mesh.limit(level, "approval_ttl")[0])
            if self.clients.approved(handle, ttl, now):
                return None
            return guard.Verdict(False, "approval", f"first contact: {handle} is an HTTP client at level {level}; a person "
                                                    f"must approve it before its messages are delivered (facilitator http "
                                                    f"approve {handle}, or the approve tool of a person's session); held up to "
                                                    f"{HELD_DAYS} days")
        if led is None or proj is None or mid is None:
            return None
        state = self.hold_state(conv, led, proj, mid, mode)
        if state == "":
            return None
        if state == "denied":
            return guard.Verdict(False, "approval", f"a person denied this message ({mode} at level {level}); it is not delivered")
        return guard.Verdict(False, "approval", f"{mode}: {handle} is an HTTP client at level {level}; a person must approve "
                                                f"this {'message' if mode == 'every-message' else 'conversation'} before it is "
                                                f"delivered {how}")

    # ------------------------------------------------------------ approval of messages that cross (every-message, per-conversation)

    def sender_of(self, author: str) -> str:
        """Who a message crosses from: its node (another node's agent or person), or this node's HTTP client."""
        h, n = router.split(author)
        return n if n and n != self.mesh.node_id else h

    def message_mode(self, author: str) -> tuple[str, str]:
        """(the approval mode, the level) this node applies to a message by `author` that did not start in this node's own
        agents: another node's by its card's level, an HTTP client's by the HTTP level; ('none', 'local') otherwise. The
        receiving node decides, whatever the sender's node did."""
        local = self.local_of(author)
        if local is not None:
            if self.is_http(local):
                lv = self.mesh.http_level()
                return self.mesh.limit(lv, "approval")[0], lv
            return "none", "local"
        n = router.split(author)[1]
        card = self.net.cards().get(n) if self.net.active else None
        if not card:
            return "none", "local"
        return self.mesh.limit(card["level"], "approval")[0], card["level"]

    def own_answers(self, conv: str, led, proj: dict) -> tuple[set, set, set]:
        """(message ids approved, message ids denied, message ids with a held notice) by notices that THIS node's
        facilitator signed in the conversation: another node's notice never answers for this node."""
        key = self.record.facilitator_key()
        ok, no, held = set(), set(), set()
        for n in proj["notices"]:
            if n["code"] not in ("approved", "denied", "approval") or led.valid[n["entry"]].key != key:
                continue
            for r in n.get("refs", []):
                if r.get("thread") == conv and "message_id" in r:
                    {"approved": ok, "denied": no, "approval": held}[n["code"]].add(r["message_id"])
        return ok, no, held

    def hold_state(self, conv: str, led, proj: dict, mid: str, mode: str | None = None) -> str:
        """'' (delivered or no approval needed), 'held' (waits for a person), 'denied' or 'expired' (held more than
        HELD_DAYS: never delivered) for a message under every-message or per-conversation."""
        m = proj["messages"][mid]
        if mode is None:
            mode = self.message_mode(m["from"])[0]
        if mode not in MESSAGE_APPROVALS:
            return ""
        ok, no, _ = self.own_answers(conv, led, proj)
        if mid in no:
            return "denied"
        if mode == "every-message":
            approved = mid in ok
        else:
            who = self.sender_of(m["from"])
            approved = any(x in proj["messages"] and self.sender_of(proj["messages"][x]["from"]) == who for x in ok)
        if approved:
            return ""
        if time.time() - clients_mod.parse_iso(m["at"]) > HELD_DAYS * 86400:
            return "expired"
        return "held"

    def held_messages(self) -> list[dict]:
        """The messages that wait for a person under every-message or per-conversation, oldest first: from another
        node's agents (with a task for one of this node's) and from this node's HTTP clients. The mail tool shows
        them; `facilitator approve` and `deny` answer them."""
        out = []
        now = time.time()
        for c in self.record.conversations():
            try:
                led, proj, _ = self.record.read(c)
            except RecordError:
                continue
            for mid in proj["order"]:
                m = proj["messages"][mid]
                mode, level = self.message_mode(m["from"])
                if mode not in MESSAGE_APPROVALS:
                    continue
                rs = proj["routes"].get(mid, [])
                if self.local_of(m["from"]) is None:
                    if not any(self.local_of(t["assignee"]) and proj["tasks"][t["task"]]["state"] == "submitted"
                               for r in rs for t in r["tasks"]):
                        continue
                elif not (rs and not any(r["tasks"] for r in rs) and any(h["reason"] == "approval" for h in rs[-1]["held"])):
                    continue
                if self.hold_state(c, led, proj, mid, mode) not in ("held", "expired"):
                    continue
                age = now - clients_mod.parse_iso(m["at"])
                out.append({"conversation": c, "message_id": mid, "from": m["from"], "node": self.sender_of(m["from"]),
                            "level": level, "mode": mode, "line": (m["text"].strip().splitlines() or [""])[0][:80],
                            "at": m["at"], "age": int(age), "expired": age > HELD_DAYS * 86400})
        out.sort(key=lambda h: h["at"])             # stable: a conversation's own order within a second
        return out

    def answer_message(self, target: str, by: str, approve: bool) -> dict:
        """A person's answer to held messages: `target` is a message id (m-...) or a conversation id (c-...: every
        message of it that waits). Each answer is a signed notice of this node's facilitator in the conversation (the
        sender's node sees it in its replica) and an entry of the audit register. Approving delivers: a message of
        another node's agent is handed to the local agent's receive, an HTTP client's is dispatched now. One held longer
        than HELD_DAYS is not delivered, and says so."""
        held = [h for h in self.held_messages() if target in (h["message_id"], h["conversation"])]
        if not held:
            raise FacilitatorError(f"nothing waits for approval under {target} (facilitator mail lists what waits)")
        out = []
        for h in held:
            c, mid = h["conversation"], h["message_id"]
            ref = [{"thread": c, "message_id": mid}]
            what = {"mode": h["mode"], "level": h["level"], "from": h["from"]}
            if not approve:
                self.record.add(c, FACILITATOR, "notice", {"thread": c, "code": "denied", "text":
                                f"denied by {by} at {self.mesh.node_id}: this message from {h['from']} is not delivered "
                                f"({h['mode']} at level {h['level']})", "refs": ref})
                self.audit_event("message-denied", mid, by, f"{c} from {h['from']} ({h['mode']}, {h['level']})")
                out.append({**what, "conversation": c, "message_id": mid, "delivered": False, "answer": "denied"})
                continue
            if h["expired"]:
                self.record.add(c, FACILITATOR, "notice", {"thread": c, "code": "approval", "text":
                                f"{by} approved this message from {h['from']}, but it was held more than {HELD_DAYS} days and "
                                "is not delivered (ruling BG)", "refs": ref})
                out.append({**what, "conversation": c, "message_id": mid, "delivered": False, "answer": "expired"})
                continue
            self.record.add(c, FACILITATOR, "notice", {"thread": c, "code": "approved", "text":
                            f"approved by {by} at {self.mesh.node_id}: this message from {h['from']} is delivered now "
                            f"({h['mode']} at level {h['level']})", "refs": ref})
            self.audit_event("message-approved", mid, by, f"{c} from {h['from']} ({h['mode']}, {h['level']})")
            delivered = True
            if self.local_of(h["from"]) is not None:          # an HTTP client's: it was not routed, so route it now
                delivered = self.dispatch(c, mid)["delivered"]
            out.append({**what, "conversation": c, "message_id": mid, "delivered": delivered, "answer": "approved"})
        return {"target": target, "by": by, "answered": out}

    def audit_event(self, event: str, subject: str, by: str, detail: str) -> None:
        try:
            self.audit.append(event, subject, by, detail)
        except Exception:                      # noqa: BLE001 - the notice in the conversation is the record; audit replay catches up
            pass

    def note_held(self, conv: str) -> int:
        """Marks in the record, with a notice of this node's facilitator, each message of another node that waits here for
        a person (every-message, per-conversation), so the sender's replica shows it is held and why. Once per message."""
        try:
            led, proj, _ = self.record.read(conv)
        except RecordError:
            return 0
        _, _, seen = self.own_answers(conv, led, proj)
        n = 0
        for mid in proj["order"]:
            m = proj["messages"][mid]
            mode, level = self.message_mode(m["from"])
            if mode not in MESSAGE_APPROVALS or self.local_of(m["from"]) is not None or mid in seen:
                continue
            if not any(self.local_of(t["assignee"]) for r in proj["routes"].get(mid, []) for t in r["tasks"]):
                continue
            if self.hold_state(conv, led, proj, mid, mode) != "held":
                continue
            self.record.add(conv, FACILITATOR, "notice", {"thread": conv, "code": "approval", "text":
                            f"held at {self.mesh.node_id}: a person there must approve this message from {m['from']} before it "
                            f"is delivered (limits.{level}.approval: {mode}); held up to {HELD_DAYS} days",
                            "refs": [{"thread": conv, "message_id": mid}]})
            n += 1
        return n

    def enrol_http(self, name: str, by: str, label: str = "") -> dict:
        """A person's act: a client, its token (returned once) and the key the node signs with for it."""
        ok, why = self.http_ready(for_tokens=True)
        if not ok:
            raise FacilitatorError("http token: " + why)
        parts, cfg, _, _ = self.participants()
        if name in [p.name for p in parts] or name in cfg.humans or name in ("facilitator", "all"):
            raise FacilitatorError(f"{name} is already a participant or a person of this node: a client needs a name of its own")
        ident = self.state.roster().get(name)
        if ident and ident.get("kind") != "http":
            raise FacilitatorError(f"{name} is already registered as a {ident.get('kind')}: a client needs a name of its own")
        try:
            token = self.clients.create(name, by, label)
        except clients_mod.ClientError as e:
            raise FacilitatorError(str(e)) from None
        pub, where = self.signer.ensure_key(name)
        self.state.set_identity(name, kind="http", key=pub, keystore=where,
                                registered=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        level = self.mesh.http_level()
        return {"client": name, "token": token, "level": level, "id": self.clients.spiffe_id(self.mesh, name),
                "approval": self.mesh.limit(level, "approval")[0]}

    def oauth_client(self, issuer_name: str, issuer: str, subject: str, client_id: str = "") -> tuple[str, dict]:
        """The HTTP client an OAuth token names (slice N5b), made on its first valid token: (handle, its table entry). A
        new one is enrolled, so its first message is held until a person approves it; a denied or revoked one stays
        refused (the entry says so). The key the node signs with is made at once, as for `http token`."""
        name = self.clients.oauth_handle(issuer_name, issuer, subject)
        parts, cfg, _, _ = self.participants()
        if name in [p.name for p in parts] or name in cfg.humans or name in ("facilitator", "all"):
            raise FacilitatorError(f"{name} is already a participant or a person of this node: the OAuth client needs a name of its own")
        ident = self.state.roster().get(name)
        if ident and ident.get("kind") != "http":
            raise FacilitatorError(f"{name} is already registered as a {ident.get('kind')}: the OAuth client needs a name of its own")
        try:
            c, created = self.clients.ensure_oauth(name, issuer_name, issuer, subject, client_id)
        except clients_mod.ClientError as e:
            raise FacilitatorError(str(e)) from None
        if created or not ident:
            pub, where = self.signer.ensure_key(name)
            self.state.set_identity(name, kind="http", key=pub, keystore=where,
                                    registered=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        return name, c

    def http_ready(self, for_tokens: bool = False) -> tuple[bool, str]:
        """Whether the HTTP endpoint may be used on this node, and why not (ADR-0070 decision 8, ADR-0071)."""
        try:
            _, cfg, _, _ = self.participants()
        except participants.ListError as e:
            return False, str(e)
        if not cfg.http.configured and not cfg.http_errors and not for_tokens:
            return True, "off: facilitator.http.listen is not set"
        if self.mesh_file.findings:
            return False, "mesh.yml has findings, so the node runs standalone (fail narrow); fix them (facilitator check)"
        if self.mesh.preset == "solo":
            return False, ("HTTP is refused under the preset solo (mesh.yml, or none): set preset: team, which allows the "
                           "level HTTP clients are mapped to")
        if cfg.http_errors:
            return False, "; ".join(cfg.http_errors)
        h = cfg.http
        lv = self.mesh.http_level()
        if self.mesh.limit(lv, "approval")[0] != "none" and not cfg.humans:
            return False, ("approval: " + self.mesh.limit(lv, "approval")[0] + " at level " + lv + " needs a person to approve, and facilitator.yml's "
                           "humans names nobody")
        if h.insecure and self.mesh.preset == "open":
            return False, ("http.insecure: true is refused under preset: open (a node reachable by strangers never runs "
                           "OAuth or bearer tokens over plain http); remove it, or use TLS")
        if h.active:
            host, _ = mesh_mod.parse_addr(h.listen)
            if not mesh_mod.is_loopback(host) and not (h.tls_cert and h.tls_key) and not h.behind_proxy and not h.insecure:
                return False, (f"http.listen {h.listen} is beyond loopback: TLS is required (http.tls_cert and "
                               "http.tls_key) or http.behind_proxy: true (a proxy ends TLS), or http.insecure: true for a local machine or a test environment")
            if not mesh_mod.is_loopback(host) and not (h.url or h.allowed_hosts):
                return False, (f"http.listen {h.listen} is beyond loopback: name the address clients use (http.url) or "
                               "http.allowed_hosts, so the Host header can be checked (DNS rebinding)")
        return True, "ok"

    def approve_client(self, name: str, by: str) -> dict:
        """A person approves an HTTP client: its held first-contact messages are delivered (BG: only those younger
        than 7 days)."""
        if self.net.active and router.split(name)[1] in self.net.cards():
            # another node's public agent (`handle.node`): first contact, approved by a person, for approval_ttl
            self.net.approve(name, by)
            try:
                self.audit.append("approved", name.replace("/", "-"), by, "a public node's agent, first contact")
            except Exception:                  # noqa: BLE001
                pass
            return {"client": name, "approved_by": by, "released": []}
        c = self.clients.get(name)
        if c is None or not self.is_http(name):
            raise FacilitatorError(f"no HTTP client {name} (facilitator http list)")
        try:
            self.clients.approve(name, by)
        except clients_mod.ClientError as e:
            raise FacilitatorError(str(e)) from None
        return {"client": name, "approved_by": by, "released": self.release_held(name, by)}

    def deny_client(self, name: str, by: str) -> dict:
        return self._close_client(name, by, "deny")

    def revoke_client(self, name: str, by: str) -> dict:
        return self._close_client(name, by, "revoke")

    def _close_client(self, name: str, by: str, what: str) -> dict:
        if self.clients.get(name) is None:
            raise FacilitatorError(f"no HTTP client {name} (facilitator http list)")
        try:
            getattr(self.clients, what)(name, by)
        except clients_mod.ClientError as e:
            raise FacilitatorError(str(e)) from None
        held = 0
        if what == "deny":
            for c, mid in self.held_for_approval(name):
                self.record.add(c, FACILITATOR, "notice", {"thread": c, "code": "denied", "text":
                                f"{name} was denied by {by}; this message is not delivered",
                                "refs": [{"thread": c, "message_id": mid}]})
                held += 1
        return {"client": name, "status": "denied" if what == "deny" else "revoked", "by": by, "dropped": held}

    def forget_client(self, name: str, by: str) -> dict:
        """A person's act (ruling OA3): let a revoked or denied client back as new; a live one is refused."""
        try:
            c = self.clients.forget(name, by)
        except clients_mod.ClientError as e:
            raise FacilitatorError(str(e)) from None
        return {"client": name, "status": "forgotten", "was": c["status"], "by": by, "auth": c.get("auth", "bearer")}

    def held_for_approval(self, name: str) -> list[tuple[str, str]]:
        """(conversation, message) of an HTTP client's messages held for approval and never delivered since."""
        out = []
        for c in self.conversations_of(name):
            _, proj, _ = self.record.read(c)
            for mid in proj["order"]:
                m = proj["messages"][mid]
                if m["from"] != name:
                    continue
                rs = proj["routes"].get(mid, [])
                if rs and not any(r["tasks"] for r in rs) and rs[-1]["held"] and all(h["reason"] == "approval" for h in rs[-1]["held"]) \
                        and not any(n.get("code") in ("denied",) and {"thread": c, "message_id": mid} in n.get("refs", [])
                                    for n in proj["notices"]):
                    out.append((c, mid))
        return out

    def release_held(self, name: str, by: str) -> list[dict]:
        """After an approval: each held message of the client is delivered, with a notice in its conversation; one held
        longer than HELD_DAYS is not (ruling BG)."""
        out = []
        now = time.time()
        if self.mesh.limit(self.mesh.http_level(), "approval")[0] in MESSAGE_APPROVALS:
            return out                         # these wait per message: facilitator approve <message> (answer_message)
        for c, mid in self.held_for_approval(name):
            _, proj, _ = self.record.read(c)
            age = now - clients_mod.parse_iso(proj["messages"][mid]["at"])
            ref = [{"thread": c, "message_id": mid}]
            if age > HELD_DAYS * 86400:
                self.record.add(c, FACILITATOR, "notice", {"thread": c, "code": "approval", "text":
                                f"{name} was approved by {by}, but this message was held more than {HELD_DAYS} days and is "
                                "not delivered (ruling BG)", "refs": ref})
                out.append({"conversation": c, "message_id": mid, "delivered": False})
                continue
            self.record.add(c, FACILITATOR, "notice", {"thread": c, "code": "approved", "text":
                            f"{name} was approved by {by}; this message is delivered now", "refs": ref})
            r = self.dispatch(c, mid)
            out.append({"conversation": c, "message_id": mid, "delivered": r["delivered"], "to": r["to"]})
        return out

    def remote_first_contact(self, principal: str) -> bool:
        """Whether a message from another node's agent waits for a person's approval (level public, approval first-contact,
        and no unexpired approval of that agent): the receiving node enforces it, whatever the sender's node did."""
        h, n = router.split(principal)
        if not n or n == self.mesh.node_id or not self.net.active:
            return False
        card = self.net.cards().get(n)
        if not card or self.mesh.limit(card["level"], "approval")[0] != "first-contact":
            return False
        ttl = mesh_mod.seconds(self.mesh.limit(card["level"], "approval_ttl")[0])
        ap = self.net.approvals().get(principal)
        return not (ap and (ttl <= 0 or time.time() - clients_mod.parse_iso(ap["at"]) < ttl))

    def pending_approvals(self) -> list[dict]:
        """The HTTP clients whose messages wait for a person: client, how many, where (a person's mail shows them)."""
        out = []
        if self.net.active:
            seen: dict[str, set] = {}
            for c in self.record.conversations():
                try:
                    led, proj, _ = self.record.read(c)
                except RecordError:
                    continue
                for t in proj["tasks"].values():
                    m = proj["messages"].get(t["message_id"])
                    if m and t["state"] == "submitted" and self.local_of(t["assignee"]) and self.remote_first_contact(m["from"]):
                        seen.setdefault(m["from"], set()).add(c)
            for who, convs in sorted(seen.items()):
                out.append({"client": who, "held": len(convs), "conversations": sorted(convs), "id": f"spiffe://{self.net.cards()[router.split(who)[1]]['card']['domain']}/node/{router.split(who)[1]}/agent/{router.split(who)[0]}"})
        for name, c in sorted(self.clients.all().items()):
            if c["status"] not in ("enrolled", "approved") or not self.is_http(name) \
                    or self.mesh.limit(self.mesh.http_level(), "approval")[0] in MESSAGE_APPROVALS:
                continue
            held = self.held_for_approval(name)
            if held:
                out.append({"client": name, "held": len(held), "conversations": sorted({x for x, _ in held}),
                            "id": self.clients.spiffe_id(self.mesh, name)})
        return out

    def remote(self) -> dict:
        """handle -> what another node's admitted card says of it (empty when standalone)."""
        return self.net.remote() if self.net.active else {}

    def level_of_message(self, proj: dict, mid: str, convs: dict | None = None) -> str:
        """A message's origin level (proposal 9): the widest level of the writers of its lineage, by reply_to
        and refs, as far as this node holds it. A writer's level is its card's, or local for this node's own."""
        http = any(i.get("kind") == "http" for i in self.state.roster().values())
        if not self.net.active and not http:
            return "local"
        level, seen, todo = "local", set(), [(None, mid)]
        while todo:
            c, m_id = todo.pop()
            p = proj if c is None else (convs or {}).get(c)
            if p is None and c is not None:
                try:
                    _, p, _ = self.record.read(c)
                except RecordError:
                    continue
                (convs if convs is not None else {}).setdefault(c, p)
            m = (p or {}).get("messages", {}).get(m_id)
            if m is None or (c, m_id) in seen:
                continue
            seen.add((c, m_id))
            if self.is_http(m["from"]):
                level = mesh_mod.wider(level, self.mesh.http_level())
            elif self.net.active:
                level = mesh_mod.wider(level, self.net.level_of(m["from"], m.get("key")))
            if m.get("reply_to"):
                todo.append((c, m["reply_to"]))
            for r in m.get("refs", []):
                if "message_id" in r:
                    todo.append((r["thread"], r["message_id"]))
        return level

    def participants(self):
        if self._list is None:
            parts, cfg, warnings, path = participants.load(self.s)
            self._list = (parts, cfg, warnings, path)
        return self._list

    def humans(self) -> list[str]:
        return self.participants()[1].humans

    def infra(self) -> Infra:
        return Infra(self.s, self.state, self.signer, self.mesh, self)

    def directory(self) -> directory.Directory:
        return directory.Directory(self.infra().binary("dir"), self.s.int("FACILITATOR_DIR_PORT", 1))

    def transport_for(self, me: str):
        sec = self.infra().slim_secrets() if self.s["FACILITATOR_TRANSPORT"] == "slim" else None
        from .peers import local_ns
        t = transport.make(self.s, sec, me, local_ns(self.mesh))
        t.start()
        return t

    def known(self) -> set[str]:
        """Every name the router may meet: this node's handles, and other nodes' participants by qualified name and
        by bare handle."""
        remote = self.remote()
        return (set(self.state.roster()) | set(remote) | {r["handle"] for r in remote.values()}) - {FACILITATOR}

    def nodes(self) -> set[str]:
        """The nodes whose participants this node can name (`handle.node`): itself and every admitted card's."""
        return ({self.mesh.node_id} | set(self.net.cards())) if self.net.active else set()

    def p(self, conv: str, handle: str) -> str:
        """The principal this node's `handle` is in a conversation (qualified in a shared one)."""
        return self.record.as_principal(conv, handle)

    def local_of(self, principal: str) -> str | None:
        """This node's handle for a principal of a conversation, or None when it is another node's."""
        h, n = router.split(principal)
        return h if n is None or n == self.mesh.node_id else None

    def resolve_one(self, name: str) -> str:
        """One participant for a name a caller gives: this node's handle, or another node's `handle.node`. A bare
        handle that names several is refused with their qualified names (ruling H5: no guess, no precedence)."""
        if not self.net.active:
            return name
        got = self.net.resolve(name)
        if len(got) > 1:
            names = [g if router.split(g)[1] else router.qualify(g, self.mesh.node_id) for g in got]
            raise FacilitatorError(f"@{name} names {len(got)} participants: {', '.join('@' + n for n in names)}; "
                                   "name one of them")
        return got[0] if got else name

    # ------------------------------------------------------------ identities (E2, E3)

    def register(self, handle: str, new_key: bool = False, push: bool = True) -> dict:
        """A participant's key (OpenBao, or the fallback file), roster entry, token and OASF record."""
        parts, cfg, _, path = self.participants()
        p = next((x for x in parts if x.name == handle), None)
        human = handle in cfg.humans
        if p is None and not human and handle != FACILITATOR:
            raise FacilitatorError(f"{handle} is not in {path} (nor a human of facilitator.yml)")
        pub, where = self.signer.ensure_key(handle, new=new_key)
        out = {"handle": handle, "key": pub, "keystore": where,
               "kind": "facilitator" if handle == FACILITATOR else "human" if human else "agent"}
        if p is not None or human:
            self.state.make_token(handle)            # a person attaches over MCP too (0.2.0)
            out["token"] = str(self.state.tokens / handle)
        if p is not None:
            if push:
                try:
                    out["cid"] = self.directory().push(directory.record(p, __version__))
                except directory.DirectoryError as e:
                    raise FacilitatorError(f"{handle}: key and token made; the directory refused the record: {e} "
                                           "(facilitator infra up, then register again)") from None
            out["description"], out["skills"] = p.description, list(p.skills)
        self.state.set_identity(handle, **{k: v for k, v in out.items() if k != "handle"},
                                registered=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        return out

    def ensure_identity(self, handle: str) -> None:
        if not self.signer.public(handle) or handle not in self.state.roster():
            self.register(handle, push=False)

    # ------------------------------------------------------------ conversations

    def new_conversation(self, creator: str, others: list[str], title: str | None = None) -> str:
        if self.is_http(creator):
            # the reach rule: an unreachable name reads the same as one that does not exist (unlisted, unreachable)
            for o in others:
                if not self.visible(creator, o.lower().lstrip("@")) or o.lower().lstrip("@") not in self.known_for(creator):
                    raise FacilitatorError(f"@{o} is no participant (who lists the handles)")
        else:
            others = [self.resolve_one(o) for o in others]
        members = [creator] + [o for o in dict.fromkeys(others) if o != creator]
        if len(members) < 2:
            raise FacilitatorError("a conversation needs at least one other member")
        local = (set(self.state.roster()) - {FACILITATOR}) | set(self.humans())
        remote = {m: r for m, r in self.remote().items() if m in members and m not in local}
        for m in members:
            if m not in local and m not in remote:
                raise FacilitatorError(f"{m} is not registered (facilitator register {m}; facilitator participants lists them)")
        for h in [x for x in members if x in self.humans()]:
            self.ensure_identity(h)
        if remote:
            # a conversation shared with another node: each local member must be exposed at least as wide as
            # the widest level of the remote ones (the reach rule, applied again by the receiving node)
            widest = "local"
            for r in remote.values():
                widest = mesh_mod.wider(widest, r["level"])
            for m in members:
                if m not in remote and not mesh_mod.reach_ok(widest, self.mesh.exposure(m)):
                    raise FacilitatorError(f"{m} is exposed {self.mesh.exposure(m)} (mesh.yml expose), so it cannot be in a "
                                           f"conversation with {', '.join(sorted(remote))} at level {widest}")
        kind = "direct" if len(members) == 2 else "group"
        humans = list(self.humans()) + [m for m, r in remote.items() if r.get("kind") == "human"]
        return self.record.create(kind, members, humans, title, remote=remote, node=self.mesh.node_id)

    def conversations_of(self, handle: str) -> list[str]:
        out = []
        for c in self.record.conversations():
            try:
                _, proj, _ = self.record.read(c)
            except RecordError:
                continue
            if proj["thread"] and self.p(c, handle) in proj["thread"]["members"]:
                out.append(c)
        return out

    # ------------------------------------------------------------ writing a message (intake, guard)

    def write(self, conv: str, author: str, text: str, to: list[str] | None, reply_to: str | None,
              root: str | None, root_thread: str | None, hops: int, refs: list[dict] | None = None) -> str:
        """Intake: the writer is a member; the rate guard; the message, signed with the writer's key."""
        text = (text or "").strip()
        if not text:
            raise FacilitatorError("an empty message")
        _, proj, _ = self.record.read(conv)
        th = proj["thread"]
        if th is None:
            raise FacilitatorError(f"no conversation {conv}")
        me = self.p(conv, author)
        if me not in th["members"]:
            raise FacilitatorError(f"{author} is not a member of {conv} (its members: {', '.join(th['members'])})")
        human = me in th["humans"]
        lim = self.limits_for(self.conv_level(th))
        self.addressed_rule(th, proj, me, text, to, reply_to)
        if self.is_http(author):
            for mm in th["members"]:
                if mm != me and not self.visible(author, router.split(mm)[0]):
                    raise FacilitatorError(f"{mm} is no longer reachable from your level; this message was not written")
            self.http_precheck(author, text)
        if not human and not guard.rate_ok(proj, me, lim, time.time()):
            raise FacilitatorError(f"rate limit: {author} wrote {lim.rate_limit} messages in the last minute; "
                                   "this one was not written")
        mid = new_id("m")
        data = {"thread": conv, "message_id": mid, "parts": [{"kind": "text", "text": text}],
                "root": mid if hops == 0 else root, "hops": hops}
        if reply_to:
            data["reply_to"] = reply_to
        ms = router.mentions(text, self.nodes())
        if ms:
            data["mentions"] = ms
        if to:
            data["to"] = list(dict.fromkeys(t.lower().lstrip("@") for t in to))
        r = list(refs or [])
        if hops > 0:
            r = [x for x in r if x != {"thread": root_thread, "message_id": root}] + [{"thread": root_thread, "message_id": root}]
        if r:
            data["refs"] = r
        self.record.add(conv, author, "message", data)
        return mid

    def addressed_members(self, th: dict) -> dict[str, list[str]]:
        """node -> its members of a conversation, for the nodes this node replicates to at copy `addressed` (a public node)."""
        if not self.net.active:
            return {}
        out: dict[str, list[str]] = {}
        for m in th["members"]:
            n = router.split(m)[1]
            if n and n != self.mesh.node_id and self.net.copy_of(n) == "addressed":
                out.setdefault(n, []).append(m)
        return out

    def addressed_rule(self, th: dict, proj: dict, me: str, text: str, to: list[str] | None, reply_to: str | None) -> None:
        """Copy addressed (proposal 10, ruling AH): a conversation with a member on a node that gets only what is addressed
        to it carries only messages addressed to that node's members. The write is refused, not the delivery, because the
        register is what replicates: register-engine cannot hold a part of a register (an entry's chain needs its
        predecessors), so what is not addressed must never be in it."""
        addr = self.addressed_members(th)
        if not addr:
            return
        dec = router.route(th, proj["messages"], me, text, to, reply_to, self.participants()[1].fallback,
                           self.known() | set(th["humans"]), self.mesh.node_id, self.nodes())
        reached = {router.split(t)[1] for t in dec.to}
        if not reached & set(addr):
            names = ", ".join(f"@{m}" for ms in addr.values() for m in ms)
            raise FacilitatorError(f"this conversation has {names}, whose node gets only what is addressed to it (copy addressed): "
                                   f"address the message to them (@handle), or talk to the others in another conversation; "
                                   "this message was not written")

    # ------------------------------------------------------------ the dispatcher

    def dispatch(self, conv: str, mid: str, tr=None) -> dict:
        """Route one message: the guard's verdict, the router's choice, a route entry with one A2A task per
        participant it goes to, notices for what is held, then a SLIM delivery to every attached one."""
        led, proj, _ = self.record.read(conv)
        th, m = proj["thread"], proj["messages"][mid]
        humans = set(th["humans"])
        verdict = self.approval_gate(m["from"], time.time(), conv, mid, led, proj) or guard.check(
            proj, m["from"], m["from"] in humans, m["hops"], m["root"], self.limits_for(self.level_of_message(proj, mid)))
        dec = router.route(th, proj["messages"], m["from"], m["text"], m.get("to"), m.get("reply_to"),
                           self.participants()[1].fallback,
                           self.known_for(m["from"]) if self.is_http(m["from"]) else self.known() | humans,
                           self.mesh.node_id, self.nodes())
        notices = list(dec.notices)
        tasks, held, live = [], [], []
        if not verdict.deliver:
            held = [{"principal": h, "reason": verdict.code} for h in dec.to]
            notices.append((verdict.code, verdict.text))
        else:
            now = time.time()
            for h in dec.to:
                if h in humans:
                    continue                   # a person reads it with the mail tool (no task, no delivery), on
                                               # this node or, from the replica, on theirs
                t = new_id("t")
                tasks.append({"task": t, "assignee": h})
                local = self.local_of(h)
                if local is None:
                    continue                   # on another node: the replica carries the task; its node delivers it
                if self.state.attached(local, self.stale, now):
                    if not self.is_http(local):         # an HTTP client polls the record: there is no SLIM name to tell
                        live.append(local)
                else:
                    held.append({"principal": h, "reason": "stale"})
                    notices.append(("stale", f"`{h}` has not been attached since {_ago(self.state.last_seen(local))}; "
                                             "the message waits and is delivered when it attaches"))
        rid = self.record.add(conv, FACILITATOR, "route", {"thread": conv, "message_id": mid, "rule": dec.rule,
                                                           "to": dec.to, "tasks": tasks, "held": held})
        for code, text in notices:
            self.record.add(conv, FACILITATOR, "notice", {"thread": conv, "code": code, "text": text,
                                                          "refs": [{"thread": conv, "message_id": mid}]})
        delivered = []
        if live:
            store = self.record.store(conv)
            data = transport.payload(conv, mid, [store.get(m["entry"]), store.get(rid)])
            own = tr is None
            try:
                tr = tr or self.transport_for(transport.ephemeral_name(self.local_of(m["from"]) or m["from"]))
                for h in live:
                    if tr.notify(h, data):
                        delivered.append(h)
            except Exception as e:             # noqa: BLE001 - the record holds it; receive finds it there
                notices.append(("stale", f"the transport did not deliver: {e}"))
            finally:
                if own and tr is not None:
                    tr.close()
        return {"conversation": conv, "message_id": mid, "rule": dec.rule, "to": dec.to,
                "tasks": [t["task"] for t in tasks], "held": held, "notified": delivered,
                "notices": [t for _, t in notices], "delivered": verdict.deliver}

    def conv_level(self, thread: dict) -> str:
        """The widest level of a conversation's members (local for this node's own)."""
        level = "local"
        if self.net.active:
            remote = self.remote()
            for m in thread["members"]:
                if self.local_of(m) is None and m in remote:
                    level = mesh_mod.wider(level, remote[m]["level"])
        for m in thread["members"]:
            if self.is_http(router.split(m)[0]):
                level = mesh_mod.wider(level, self.mesh.http_level())
        return level

    def send(self, author: str, text: str, conv: str | None = None, to: list[str] | None = None,
             tr=None) -> dict:
        """A person's message (the MCP tool `say` of a human-kind session). With no conversation (or
        "new"), one is made with the handles it names (direct for one, a group for more) and the message is
        its chain's root, hops 0. In an existing conversation it answers the conversation's last message
        and counts as a hop like any other (option A, the Operator's ruling of 2026-11-20): only
        `continue` lets a held chain run on."""
        if author not in self.humans():
            raise FacilitatorError(f"{author} is not a human of facilitator.yml (humans: {', '.join(self.humans())}); "
                                   "participants write through their MCP server")
        self.ensure_identity(author)
        return self._begin_or_write(author, text, conv, to, tr)

    def send_http(self, client: str, text: str, conv: str | None = None, to: list[str] | None = None, tr=None) -> dict:
        """An HTTP client's `say` with no message received to answer: it begins a conversation (the node vouches for the
        client with `via`; the message is a chain's root, hops 0, held until a person approves at level public) or writes
        in one it is a member of. It never continues a paused one and never counts as a person."""
        if not self.is_http(client):
            raise FacilitatorError(f"{client} is not an HTTP client of this node")
        return self._begin_or_write(client, text, conv, to, tr)

    def _begin_or_write(self, author: str, text: str, conv: str | None, to: list[str] | None, tr=None) -> dict:
        self.http_precheck(author, text)
        if not conv or conv == "new":
            named = [h for h in dict.fromkeys([*(to or []), *router.mentions(text, self.nodes())]) if h not in ("all", author)]
            if not named:
                raise FacilitatorError("a new conversation needs someone to talk to: @handle them, or pass to")
            conv = self.new_conversation(author, named)
        _, proj, _ = self.record.read(conv)
        if proj["thread"] is None:
            raise FacilitatorError(f"no conversation {conv}")
        if proj["order"]:
            last = proj["messages"][proj["order"][-1]]
            root_thread = last["refs"][-1]["thread"] if last["hops"] > 0 and last.get("refs") else conv
            mid = self.write(conv, author, text, to, last["message_id"], last["root"], root_thread, last["hops"] + 1)
        else:
            mid = self.write(conv, author, text, to, None, None, None, 0)
        return self.dispatch(conv, mid, tr)

    def continue_(self, author: str, conv: str, tr=None) -> dict:
        """The person's `continue`: lets the held chain run another hop limit (and resets the budget); the
        latest held message is routed again. The only thing that resets hops (option A)."""
        if author not in self.humans():
            raise FacilitatorError("only a person (a human of facilitator.yml) continues a conversation")
        _, proj, _ = self.record.read(conv)
        held = [mid for mid in proj["order"] if (rs := proj["routes"].get(mid)) and not any(r["tasks"] for r in rs)
                and any(h["reason"] in ("hop-limit", "budget", "paused") for r in rs for h in r["held"])]
        if not held:
            raise FacilitatorError(f"nothing is held in {conv}")
        self.ensure_identity(author)
        self.record.add(conv, author, "continue", {"thread": conv, "upto": held[-1]})
        return self.dispatch(conv, held[-1], tr)

    # ------------------------------------------------------------ a participant's side

    def pending(self, handle: str) -> list[dict]:
        out = []
        for c in self.conversations_of(handle):
            led, proj, _ = self.record.read(c)
            pos = {i: n for n, i in enumerate(led.order)}
            for t in proj["tasks"].values():
                if t["assignee"] == self.p(c, handle) and t["state"] == "submitted":
                    m = proj["messages"][t["message_id"]]
                    if self.remote_first_contact(m["from"]):
                        continue                        # another node's agent a person has not approved: held, shown to them
                    if self.local_of(m["from"]) is None and self.hold_state(c, led, proj, t["message_id"]):
                        continue                        # every-message, per-conversation: held, denied or expired
                    out.append({"conv": c, "task": t["task"], "message": m, "pos": (t["at"], pos.get(t["history"][0][2], 0)),
                                "members": proj["thread"]["members"]})
        out.sort(key=lambda p: p["pos"])
        return out

    def take(self, handle: str, batch: list[dict]) -> Turn:
        for p in batch:
            self.record.add(p["conv"], handle, "status", {"task": p["task"], "state": "working"})
        last = batch[-1]["message"]
        root_thread = last["refs"][-1]["thread"] if last["hops"] > 0 and last.get("refs") else batch[-1]["conv"]
        return Turn(batch[-1]["conv"], last["message_id"], last["root"], root_thread, last["hops"],
                    [(p["conv"], p["task"]) for p in batch])

    def finish(self, handle: str, turn: Turn) -> None:
        for conv, task in turn.tasks:
            _, proj, _ = self.record.read(conv)
            if proj["tasks"].get(task, {}).get("state") not in ("completed", "failed", "canceled", "rejected"):
                self.record.add(conv, handle, "status", {"task": task, "state": "completed"})
        turn.tasks = []

    def reply(self, handle: str, turn: Turn | None, text: str, to: list[str] | None = None, tr=None) -> dict:
        if turn is None:
            raise FacilitatorError("nothing to reply to: call receive first (or say, in a conversation you are in)")
        self.http_precheck(handle, text)
        mid = self.write(turn.conv, handle, text, to, turn.message_id, turn.root, turn.root_thread, turn.hops + 1)
        self.finish(handle, turn)
        return self.dispatch(turn.conv, mid, tr)

    def say(self, handle: str, turn: Turn | None, conv: str | None, text: str, to: list[str] | None = None, tr=None) -> dict:
        if turn is None:
            raise FacilitatorError("a chain begins with a human: say needs a message you received (call receive first)")
        self.http_precheck(handle, text)
        if not conv or conv == "new":
            named = [h for h in dict.fromkeys([*(to or []), *router.mentions(text, self.nodes())]) if h not in ("all", handle)]
            if not named:
                raise FacilitatorError("say in a new conversation needs someone to say it to: to=[handle]")
            conv = self.new_conversation(handle, named)
        refs = [{"thread": turn.conv, "message_id": turn.message_id}]
        mid = self.write(conv, handle, text, to, None, turn.root, turn.root_thread, turn.hops + 1, refs)
        return self.dispatch(conv, mid, tr)

    def ingest(self, raw: bytes) -> None:
        """A SLIM delivery: its packets checked and put in the store (a copy already there is the same id)."""
        from registerengine import adapters
        d = transport.parse_payload(raw)
        if not d:
            return
        store = self.record.store(d["conv"])
        adapters.sync([adapters.raws(store), [e.encode() for e in d["entries"]]], store, self.record.anchors(),
                      self.record.checked, d["conv"], self.record.kinds)

    def who(self, handle: str | None = None) -> dict:
        parts, cfg, _, _ = self.participants()
        roster = self.state.roster()
        recs = {}
        try:
            recs = self.directory().records()
        except Exception:                      # noqa: BLE001 - the directory is optional for who
            recs = {}
        now = time.time()
        rows = []
        disp = self.net.display if self.net.active else (lambda h, n=None: h)
        http = bool(handle) and self.is_http(handle)
        vis = (lambda h: self.visible(handle, h)) if http else (lambda h: True)      # the reach rule: unlisted when unreachable
        parts = [p for p in parts if vis(p.name)]
        for p in parts:
            r = recs.get(p.name, {})
            rows.append({"handle": disp(p.name), "kind": "agent", "cli": p.cli,
                         "description": r.get("description") or p.description,
                         "skills": [s.get("name") for s in r.get("skills", [])] or p.skills,
                         "registered": p.name in roster, "attached": self.state.attached(p.name, self.stale, now),
                         "last_seen": _ago(self.state.last_seen(p.name)), "in_directory": p.name in recs})
        listed = {p.name for p in parts}
        for h, ident in sorted(roster.items()):          # registered, and not in the list this process reads
            if ident.get("kind") == "agent" and h not in listed and vis(h):
                r = recs.get(h, {})
                rows.append({"handle": disp(h), "kind": "agent", "description": r.get("description") or ident.get("description", ""),
                             "skills": [s.get("name") for s in r.get("skills", [])] or ident.get("skills", []),
                             "registered": True, "attached": self.state.attached(h, self.stale, now),
                             "last_seen": _ago(self.state.last_seen(h)), "in_directory": h in recs})
        humans = list(cfg.humans) + [h for h, i in sorted(roster.items()) if i.get("kind") == "human" and h not in cfg.humans]
        for h in [x for x in humans if vis(x)]:
            rows.append({"handle": disp(h), "kind": "human", "registered": h in roster})
        # participants of other nodes: only those their node exposes at least as wide as its domain's level (so a
        # local-only agent of another node is never listed here), through the hub's roster of cards
        for q, r in sorted({} if http else self.remote().items()):
            rows.append({"handle": disp(r["handle"], r["node"]), "kind": r.get("kind", "agent"), "node": r["node"],
                         "level": r["level"], "qualified": q,
                         "description": r.get("description", ""), "skills": r.get("skills", []), "registered": True,
                         "attached": None, "last_seen": "on another node", "in_directory": False})
        out = {"participants": rows}
        if handle:
            out["you"] = handle
            out["conversations"] = self.conversations_of(handle)
        return out


    # ------------------------------------------------------------ a person's side: mail

    def unread(self, handle: str) -> tuple[list[dict], list[dict]]:
        """(the messages `handle` has not read, in each conversation's order; the conversations it is in,
        with how many each holds unread and whether it is paused). A message is unread when another member
        wrote it in a conversation `handle` is in and the mail tool has not handed it over yet."""
        marks = self.state.read_marks(handle)
        msgs, convs = [], []
        for c in self.conversations_of(handle):
            _, proj, _ = self.record.read(c)
            seen = set(marks.get(c, []))
            n = 0
            me = self.p(c, handle)
            for mid in proj["order"]:
                m = proj["messages"][mid]
                if m["from"] == me or mid in seen:
                    continue
                routes = proj["routes"].get(mid, [])
                held = sorted({h["reason"] for r in routes for h in r["held"] if h["reason"] != "stale"})
                msgs.append({"conversation": c, "message_id": mid, "from": m["from"], "text": m["text"],
                             "hops": m["hops"], "at": m["at"], "for_you": any(me in r["to"] for r in routes),
                             "held": held[0] if held else ""})
                n += 1
            convs.append({"conversation": c, "members": proj["thread"]["members"], "unread": n,
                          "paused": guard.paused(proj)})
        first = {}
        for m in msgs:
            first.setdefault(m["conversation"], m["at"])
        msgs.sort(key=lambda m: (first[m["conversation"]], m["conversation"]))      # stable: each conversation's order kept
        return msgs, convs

    def mail(self, handle: str, limit: int = 20, mark: bool = True) -> dict:
        """What came in for a person, never blocking: up to `limit` unread messages, grouped by conversation,
        marked read when `mark`; `more` says how many stay unread."""
        msgs, convs = self.unread(handle)
        out, rest = msgs[:limit], msgs[limit:]
        approvals = self.pending_approvals() if handle in self.humans() else []
        held = self.held_messages() if handle in self.humans() else []
        if mark:
            read: dict[str, list[str]] = {}
            for m in out:
                read.setdefault(m["conversation"], []).append(m["message_id"])
            self.state.mark_read(handle, read)
        return {"messages": out, "more": len(rest), "conversations": convs,
                "paused": [c["conversation"] for c in convs if c["paused"]], "approvals": approvals, "held": held}

    def mail_notice(self, handle: str) -> str:
        """The turn hook's one line ('' when nothing is unread), read only. A fingerprint of the
        conversations and of what was read lets a turn with nothing new skip reading the record."""
        fp = [self.state.conversations_stamp(), self.state.marks_stamp(handle), self.clients.stamp()]
        cache = self.state.mail / f"{handle}.notice"
        try:
            c = json.loads(cache.read_text())
            if c.get("fp") == fp:
                return c.get("line", "")
        except (OSError, ValueError):
            pass
        msgs, convs = self.unread(handle)
        human = handle in self.humans()
        line = notice_line(msgs, convs, self.pending_approvals() if human else [], self.held_messages() if human else [])
        try:
            self.state.write_private(cache, json.dumps({"fp": fp, "line": line}) + "\n")
        except OSError:
            pass
        return line


def notice_line(msgs: list[dict], convs: list[dict], approvals: list[dict] | None = None,
                held: list[dict] | None = None) -> str:
    waits = f"{len(held)} message{'s' if len(held) != 1 else ''} held for your approval" if held else ""
    if not msgs:
        parts = [f"{a['client']} waits for approval ({a['held']} held)" for a in approvals or []]
        if waits:
            parts.append(waits + " (facilitator mail; the approve and deny tools, or facilitator approve <message>)")
        elif parts:
            parts[-1] += " (the approve tool, or facilitator http approve)"
        return ("Facilitator: " + ", ".join(parts)) if parts else ""
    ids = list(dict.fromkeys(m["conversation"] for m in msgs))
    paused = [c["conversation"] for c in convs if c["paused"] and c["conversation"] in ids]
    n = len(msgs)
    line = f"Facilitator: {n} new message{'s' if n != 1 else ''} in {', '.join(ids)}"
    if paused:
        line += f" ({', '.join(paused)} paused: continue it to let the agents go on)"
    if approvals:
        line += "; waiting for approval: " + ", ".join(a["client"] for a in approvals)
    if waits:
        line += "; " + waits
    return line


class Session:
    """One attachment over MCP (or the model wrapper): an agent's (receive, reply, say, who) or, since
    0.2.0, a person's (say, mail, transcript, continue, who). The kind comes from the roster, made by
    `register` from facilitator.yml's humans; the caller only proves its handle with its token, and can
    never choose its kind."""

    def __init__(self, fac: Facilitator, handle: str, token: str | None, tr=None):
        roster = fac.state.roster()
        kind = roster.get(handle, {}).get("kind")
        if kind not in ("agent", "human"):
            raise FacilitatorError(f"{handle} is not a registered participant: facilitator register {handle}")
        if kind == "human" and handle not in fac.humans():
            raise FacilitatorError(f"{handle} was registered as a person but is not in facilitator.yml's humans "
                                   f"({', '.join(fac.humans())})")
        if not fac.state.token_ok(handle, token):
            raise FacilitatorError(f"FACILITATOR_TOKEN does not match the token of {handle} "
                                   f"({fac.state.tokens / handle}); tokens are made again at each container start")
        self.fac, self.handle, self.tr = fac, handle, tr
        self.human = kind == "human"
        self.turn: Turn | None = None
        self.received: list[dict] = []

    def _agent_only(self, what: str) -> None:
        if self.human:
            raise FacilitatorError(f"{what} is an agent's tool; a person reads with mail and writes with say")

    def _human_only(self, what: str) -> None:
        if not self.human:
            raise FacilitatorError(f"{what} is a person's tool: only a human-kind participant (facilitator.yml's "
                                   f"humans) may call it; @{self.handle} is an agent")

    def receive(self, wait: float) -> dict | None:
        """Blocks until a delivery waits for this participant, or `wait` seconds pass (then None)."""
        self._agent_only("receive")
        end = time.time() + max(0.0, wait)
        while True:
            self.fac.state.seen(self.handle)
            pending = self.fac.pending(self.handle)
            if pending:
                batch = collector.group([p for p in pending if p["conv"] == pending[0]["conv"]])
                if self.turn and self.turn.tasks:
                    self.fac.finish(self.handle, self.turn)    # the last turn ends unanswered: its tasks complete
                self.turn = self.fac.take(self.handle, batch)
                last = batch[-1]
                return {"conversation": last["conv"], "message_id": last["message"]["message_id"],
                        "from": last["message"]["from"], "text": collector.join(batch), "members": last["members"],
                        "hops": last["message"]["hops"], "parts": [{"from": p["message"]["from"],
                                                                    "message_id": p["message"]["message_id"],
                                                                    "text": p["message"]["text"]} for p in batch]}
            left = end - time.time()
            if left <= 0:
                return None
            raw = self.tr.wait(min(left, 2.0)) if self.tr else (time.sleep(min(left, 0.5)) or None)
            if raw:
                try:
                    self.fac.ingest(raw)
                except Exception:              # noqa: BLE001 - a bad delivery is dropped; the record is read anyway
                    pass

    def reply(self, text: str, to: list[str] | None = None) -> dict:
        self._agent_only("reply")
        return self.fac.reply(self.handle, self.turn, text, to, self.tr)

    def say(self, conv: str | None, text: str, to: list[str] | None = None) -> dict:
        if self.human:
            return self.fac.send(self.handle, text, conv, to, self.tr)
        return self.fac.say(self.handle, self.turn, conv, text, to, self.tr)

    def who(self) -> dict:
        return self.fac.who(self.handle)

    def mail(self, limit: int = 20) -> dict:
        self._human_only("mail")
        return self.fac.mail(self.handle, limit)

    def transcript(self, conv: str, limit: int | None = None) -> list[str]:
        from .transcript import lines
        self._human_only("transcript")
        if conv not in self.fac.conversations_of(self.handle):
            raise FacilitatorError(f"you are not in {conv} (who lists your conversations)")
        return lines(self.fac, conv, limit)

    def continue_(self, conv: str) -> dict:
        self._human_only("continue")
        if conv not in self.fac.conversations_of(self.handle):
            raise FacilitatorError(f"you are not in {conv} (who lists your conversations)")
        return self.fac.continue_(self.handle, conv, self.tr)

    def approve(self, client: str) -> dict:
        """A person approves an HTTP client or another node's agent (first contact), or a held message or conversation
        (every-message, per-conversation: an id of mail's list): what waits is delivered."""
        self._human_only("approve")
        if client[:2] in ("m-", "c-"):
            return self.fac.answer_message(client, self.handle, True)
        return self.fac.approve_client(client, self.handle)

    def deny(self, target: str) -> dict:
        """A person denies a held message or conversation: it is not delivered, and the sender is told by a signed notice."""
        self._human_only("deny")
        if target[:2] not in ("m-", "c-"):
            raise FacilitatorError(f"deny takes a held message or conversation id ({'facilitator mail lists them'}); "
                                   "a client is denied with facilitator http deny")
        return self.fac.answer_message(target, self.handle, False)


class HttpSession(Session):
    """One HTTP client's attachment (slice N4, ADR-0070): the node signs for it, so there is no token to check here
    (the endpoint authenticated the bearer token). Never `human`: it reads with `mail` and `transcript` (read only),
    writes with `say` and `reply`, waits with `receive`, and sees `who` as its level allows; it has no `continue` and
    no `approve`, which only a person's session has."""

    def __init__(self, fac: Facilitator, handle: str, tr=None):
        if not fac.is_http(handle):
            raise FacilitatorError(f"{handle} is not an HTTP client of this node (facilitator http token)")
        self.fac, self.handle, self.tr = fac, handle, tr
        self.human = False
        self.turn: Turn | None = None
        self.received: list[dict] = []

    def say(self, conv: str | None, text: str, to: list[str] | None = None) -> dict:
        """Begins a conversation (a chain's root, hop 0, which the node vouches for) or writes in one, answering its last
        message; never the lineage of a message received (that is `reply`)."""
        return self.fac.send_http(self.handle, text, conv, to, self.tr)

    def mail(self, limit: int = 20) -> dict:
        r = self.fac.mail(self.handle, limit)
        r["approvals"] = []
        return r

    def transcript(self, conv: str, limit: int | None = None) -> list[str]:
        from .transcript import lines
        if conv not in self.fac.conversations_of(self.handle):
            raise FacilitatorError(f"you are not in {conv} (who lists your conversations)")
        return lines(self.fac, conv, limit)

    def continue_(self, conv: str) -> dict:
        raise FacilitatorError("continue is a person's tool: an HTTP client is never a person, and only a person's local "
                               "session resets the hop count (ADR-0066)")

    def approve(self, client: str) -> dict:
        raise FacilitatorError("approve is a person's tool: an HTTP client cannot approve anything (ADR-0070)")

    def deny(self, target: str) -> dict:
        raise FacilitatorError("deny is a person's tool: an HTTP client cannot answer anything (ADR-0070)")
