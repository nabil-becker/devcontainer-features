"""The way in for a person (proposal 4.9): `facilitator chat` (one line in, the transcript followed live)
and the transcript itself, as text or JSON (`transcript --json`, for scripts)."""
from __future__ import annotations

import sys
import threading
import time

from . import router
from .app import FacilitatorError

HELP = """/new group <handle> <handle>...   start a group with them (you are in it)
/new direct <handle>              start a direct conversation
/conv <id>                        switch to a conversation; /convs lists them
/continue                         let a paused chain run another hop limit
/who                              the handles, and who is attached
/quit                             leave (the conversations stay in the record)
anything else is a message; @handle addresses someone (with no conversation yet, one is made with them)"""


def hms(at: str) -> str:
    return at[11:19]


def events(proj: dict, led) -> list[tuple[str, str]]:
    """(entry id, one line) for each message, route and notice, in the register's order."""
    out = []
    routes_by_entry = {r["entry"]: r for rs in proj["routes"].values() for r in rs}
    msgs_by_entry = {m["entry"]: m for m in proj["messages"].values()}
    notices_by_entry = {n["entry"]: n for n in proj["notices"]}
    conts = {c["entry"]: c for c in proj["continues"]}
    for i in led.order:
        if i in msgs_by_entry:
            m = msgs_by_entry[i]
            hop = f" [{m['hops']} hop{'s' if m['hops'] != 1 else ''}]" if m["hops"] else ""
            out.append((i, f"{hms(m['at'])} @{m['from']}{hop}: {m['text']}"))
        elif i in routes_by_entry:
            r = routes_by_entry[i]
            held = {h["principal"]: h["reason"] for h in r["held"]}
            to = ", ".join(f"@{h}" + (f" (held: {held[h]})" if h in held else "") for h in r["to"]) or "nobody"
            out.append((i, f"           -> {to}  [{r['rule']}]"))
        elif i in notices_by_entry:
            out.append((i, f"           ! {notices_by_entry[i]['text']}"))
        elif i in conts:
            out.append((i, f"{hms(conts[i]['at'])} @{conts[i]['from']} continued the conversation"))
    return out


def transcript(fac, conv: str) -> dict:
    led, proj, flags = fac.record.read(conv)
    if proj["thread"] is None:
        raise FacilitatorError(f"no conversation {conv}")
    msgs = []
    for mid in proj["order"]:
        m = proj["messages"][mid]
        msgs.append({"message_id": mid, "from": m["from"], "at": m["at"], "text": m["text"], "hops": m["hops"],
                     "root": m["root"], "reply_to": m.get("reply_to"), "refs": m.get("refs", []), "entry": m["entry"],
                     "routes": [{"rule": r["rule"], "to": r["to"], "held": r["held"],
                                 "tasks": [{**t, "state": proj["tasks"][t["task"]]["state"]} for t in r["tasks"]]}
                                for r in proj["routes"].get(mid, [])]})
    return {"conversation": conv, "kind": proj["thread"]["kind"], "members": proj["thread"]["members"],
            "humans": proj["thread"]["humans"], "messages": msgs,
            "notices": [{"code": n["code"], "text": n["text"], "at": n["at"]} for n in proj["notices"]],
            "flags": flags}


class Chat:
    def __init__(self, fac, me: str, conv: str | None, out=sys.stdout):
        self.fac, self.me, self.conv, self.out = fac, me, conv, out
        self.seen: set[str] = set()
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.tr = None

    def say(self, line: str) -> None:
        with self.lock:
            print(line, file=self.out, flush=True)

    def show(self) -> None:
        if not self.conv:
            return
        try:
            led, proj, _ = self.fac.record.read(self.conv)
        except Exception:                      # noqa: BLE001 - shown next round
            return
        for i, line in events(proj, led):
            if i not in self.seen:
                self.seen.add(i)
                self.say(line)

    def follow(self) -> None:
        while not self.stop.is_set():
            self.show()
            self.stop.wait(0.5)

    def switch(self, conv: str) -> None:
        self.conv = conv
        self.seen = set()
        self.say(f"-- conversation {conv}")
        self.show()

    def command(self, line: str) -> bool:
        parts = line.split()
        cmd = parts[0]
        if cmd == "/quit":
            return False
        if cmd == "/help":
            self.say(HELP)
        elif cmd == "/new" and len(parts) >= 3 and parts[1] in ("group", "direct"):
            handles = [h.lstrip("@").lower() for h in parts[2:]]
            if parts[1] == "direct" and len(handles) != 1:
                self.say("! /new direct takes one handle")
            else:
                if parts[1] == "group" and len(handles) < 2:
                    self.say("! a group takes two or more handles besides you (/new direct for one)")
                    return True
                self.switch(self.fac.new_conversation(self.me, handles))
        elif cmd == "/conv" and len(parts) == 2:
            self.switch(parts[1])
        elif cmd == "/convs":
            self.say("\n".join(self.fac.conversations_of(self.me)) or "no conversations yet")
        elif cmd == "/continue":
            if not self.conv:
                self.say("! no conversation yet")
            else:
                r = self.fac.continue_(self.me, self.conv, self.tr)
                self.say(f"! continued {r['message_id']}")
        elif cmd == "/who":
            for p in self.fac.who(self.me)["participants"]:
                state = "attached" if p.get("attached") else f"last seen {p.get('last_seen', 'n/a')}"
                self.say(f"  @{p['handle']} ({p['kind']}{', ' + state if p['kind'] == 'agent' else ''})"
                         + (f": {p['description']}" if p.get("description") else ""))
        else:
            self.say(f"! unknown command {cmd} (/help)")
        return True

    def run(self, inp=sys.stdin) -> int:
        self.say(f"facilitator chat as @{self.me}; /help for the commands")
        if self.fac.s["FACILITATOR_TRANSPORT"] == "slim":
            try:
                self.tr = self.fac.transport_for(f"{self.me}-chat-{int(time.time()) % 100000}")
            except Exception as e:             # noqa: BLE001
                self.say(f"! SLIM is not reachable ({e}); messages are kept and delivered when receive reads the record")
        if self.conv:
            self.switch(self.conv)
        t = threading.Thread(target=self.follow, daemon=True)
        t.start()
        try:
            for line in inp:
                line = line.strip()
                if not line:
                    continue
                try:
                    if line.startswith("/"):
                        if not self.command(line):
                            break
                        continue
                    if not self.conv and not router.mentions(line):
                        self.say("! no conversation yet: @handle someone, or /new")
                        continue
                    r = self.fac.send(self.me, line, self.conv, tr=self.tr)
                    if r["conversation"] != self.conv:
                        self.switch(r["conversation"])
                except Exception as e:         # noqa: BLE001 - one line, the chat goes on
                    self.say(f"! {e}")
        except KeyboardInterrupt:
            pass
        finally:
            self.stop.set()
            if self.tr:
                self.tr.close()
        return 0
