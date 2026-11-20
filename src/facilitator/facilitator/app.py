"""The facilitator application's deterministic core (proposal 4.3): intake, guard, router, dispatcher,
collector, signer, over the record (register-engine) and the transport (SLIM). It runs in whichever
process writes: the MCP server of a participant or of a person, and the model wrapper. No model is
called in this version; nothing here starts or stops a participant."""
from __future__ import annotations

import datetime as dt
import json
import time
from dataclasses import dataclass, field

from . import __version__, collector, directory, guard, participants, router, transport
from .infra import Infra
from .record import FACILITATOR, Record, RecordError, new_id
from .settings import Settings
from .signer import Signer
from .state import State


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
        self._record: Record | None = None
        self._list = None

    # ------------------------------------------------------------ parts, made when first needed

    @property
    def record(self) -> Record:
        if self._record is None:
            self.state.ensure()
            self._record = Record(self.state, self.signer)
        return self._record

    def participants(self):
        if self._list is None:
            parts, cfg, warnings, path = participants.load(self.s)
            self._list = (parts, cfg, warnings, path)
        return self._list

    def humans(self) -> list[str]:
        return self.participants()[1].humans

    def infra(self) -> Infra:
        return Infra(self.s, self.state, self.signer)

    def directory(self) -> directory.Directory:
        return directory.Directory(self.infra().binary("dir"), self.s.int("FACILITATOR_DIR_PORT", 1))

    def transport_for(self, me: str):
        sec = self.infra().slim_secrets() if self.s["FACILITATOR_TRANSPORT"] == "slim" else None
        t = transport.make(self.s, sec, me)
        t.start()
        return t

    def known(self) -> set[str]:
        return set(self.state.roster()) - {FACILITATOR}

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
        members = [creator] + [o for o in dict.fromkeys(others) if o != creator]
        if len(members) < 2:
            raise FacilitatorError("a conversation needs at least one other member")
        known = self.known() | set(self.humans())
        for m in members:
            if m not in known:
                raise FacilitatorError(f"{m} is not registered (facilitator register {m}; facilitator participants lists them)")
        for h in [x for x in members if x in self.humans()]:
            self.ensure_identity(h)
        kind = "direct" if len(members) == 2 else "group"
        return self.record.create(kind, members, self.humans(), title)

    def conversations_of(self, handle: str) -> list[str]:
        out = []
        for c in self.record.conversations():
            try:
                _, proj, _ = self.record.read(c)
            except RecordError:
                continue
            if proj["thread"] and handle in proj["thread"]["members"]:
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
        if author not in th["members"]:
            raise FacilitatorError(f"{author} is not a member of {conv} (its members: {', '.join(th['members'])})")
        human = author in th["humans"]
        if not human and not guard.rate_ok(proj, author, self.limits, time.time()):
            raise FacilitatorError(f"rate limit: {author} wrote {self.limits.rate_limit} messages in the last minute; "
                                   "this one was not written")
        mid = new_id("m")
        data = {"thread": conv, "message_id": mid, "parts": [{"kind": "text", "text": text}],
                "root": mid if hops == 0 else root, "hops": hops}
        if reply_to:
            data["reply_to"] = reply_to
        ms = router.mentions(text)
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

    # ------------------------------------------------------------ the dispatcher

    def dispatch(self, conv: str, mid: str, tr=None) -> dict:
        """Route one message: the guard's verdict, the router's choice, a route entry with one A2A task per
        participant it goes to, notices for what is held, then a SLIM delivery to every attached one."""
        _, proj, _ = self.record.read(conv)
        th, m = proj["thread"], proj["messages"][mid]
        humans = set(th["humans"])
        verdict = guard.check(proj, m["from"], m["from"] in humans, m["hops"], m["root"], self.limits)
        dec = router.route(th, proj["messages"], m["from"], m["text"], m.get("to"), m.get("reply_to"),
                           self.participants()[1].fallback, self.known() | humans)
        notices = list(dec.notices)
        tasks, held, live = [], [], []
        if not verdict.deliver:
            held = [{"principal": h, "reason": verdict.code} for h in dec.to]
            notices.append((verdict.code, verdict.text))
        else:
            now = time.time()
            for h in dec.to:
                if h in humans:
                    continue                   # a person reads it with the mail tool (no task, no delivery)
                t = new_id("t")
                tasks.append({"task": t, "assignee": h})
                if self.state.attached(h, self.stale, now):
                    live.append(h)
                else:
                    held.append({"principal": h, "reason": "stale"})
                    notices.append(("stale", f"`{h}` has not been attached since {_ago(self.state.last_seen(h))}; "
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
                tr = tr or self.transport_for(transport.ephemeral_name(m["from"]))
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
        if not conv or conv == "new":
            named = [h for h in dict.fromkeys([*(to or []), *router.mentions(text)]) if h not in ("all", author)]
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
                if t["assignee"] == handle and t["state"] == "submitted":
                    m = proj["messages"][t["message_id"]]
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
        mid = self.write(turn.conv, handle, text, to, turn.message_id, turn.root, turn.root_thread, turn.hops + 1)
        self.finish(handle, turn)
        return self.dispatch(turn.conv, mid, tr)

    def say(self, handle: str, turn: Turn | None, conv: str | None, text: str, to: list[str] | None = None, tr=None) -> dict:
        if turn is None:
            raise FacilitatorError("a chain begins with a human: say needs a message you received (call receive first)")
        if not conv or conv == "new":
            named = [h for h in dict.fromkeys([*(to or []), *router.mentions(text)]) if h not in ("all", handle)]
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
        for p in parts:
            r = recs.get(p.name, {})
            rows.append({"handle": p.name, "kind": "agent", "cli": p.cli,
                         "description": r.get("description") or p.description,
                         "skills": [s.get("name") for s in r.get("skills", [])] or p.skills,
                         "registered": p.name in roster, "attached": self.state.attached(p.name, self.stale, now),
                         "last_seen": _ago(self.state.last_seen(p.name)), "in_directory": p.name in recs})
        listed = {p.name for p in parts}
        for h, ident in sorted(roster.items()):          # registered, and not in the list this process reads
            if ident.get("kind") == "agent" and h not in listed:
                r = recs.get(h, {})
                rows.append({"handle": h, "kind": "agent", "description": r.get("description") or ident.get("description", ""),
                             "skills": [s.get("name") for s in r.get("skills", [])] or ident.get("skills", []),
                             "registered": True, "attached": self.state.attached(h, self.stale, now),
                             "last_seen": _ago(self.state.last_seen(h)), "in_directory": h in recs})
        humans = list(cfg.humans) + [h for h, i in sorted(roster.items()) if i.get("kind") == "human" and h not in cfg.humans]
        for h in humans:
            rows.append({"handle": h, "kind": "human", "registered": h in roster})
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
            for mid in proj["order"]:
                m = proj["messages"][mid]
                if m["from"] == handle or mid in seen:
                    continue
                routes = proj["routes"].get(mid, [])
                held = sorted({h["reason"] for r in routes for h in r["held"] if h["reason"] != "stale"})
                msgs.append({"conversation": c, "message_id": mid, "from": m["from"], "text": m["text"],
                             "hops": m["hops"], "at": m["at"], "for_you": any(handle in r["to"] for r in routes),
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
        if mark:
            read: dict[str, list[str]] = {}
            for m in out:
                read.setdefault(m["conversation"], []).append(m["message_id"])
            self.state.mark_read(handle, read)
        return {"messages": out, "more": len(rest), "conversations": convs,
                "paused": [c["conversation"] for c in convs if c["paused"]]}

    def mail_notice(self, handle: str) -> str:
        """The turn hook's one line ('' when nothing is unread), read only. A fingerprint of the
        conversations and of what was read lets a turn with nothing new skip reading the record."""
        fp = [self.state.conversations_stamp(), self.state.marks_stamp(handle)]
        cache = self.state.mail / f"{handle}.notice"
        try:
            c = json.loads(cache.read_text())
            if c.get("fp") == fp:
                return c.get("line", "")
        except (OSError, ValueError):
            pass
        msgs, convs = self.unread(handle)
        line = notice_line(msgs, convs)
        try:
            self.state.write_private(cache, json.dumps({"fp": fp, "line": line}) + "\n")
        except OSError:
            pass
        return line


def notice_line(msgs: list[dict], convs: list[dict]) -> str:
    if not msgs:
        return ""
    ids = list(dict.fromkeys(m["conversation"] for m in msgs))
    paused = [c["conversation"] for c in convs if c["paused"] and c["conversation"] in ids]
    n = len(msgs)
    line = f"Facilitator: {n} new message{'s' if n != 1 else ''} in {', '.join(ids)}"
    if paused:
        line += f" ({', '.join(paused)} paused: continue it to let the agents go on)"
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
