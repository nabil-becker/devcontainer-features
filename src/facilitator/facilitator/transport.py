"""The transport part of the backend interface (proposal 4.8): in `agntcy` mode, SLIM, through
`slim-bindings` directly (ruling E: no slim-mcp).

Each running MCP server (and the model wrapper) is a SLIM app named agntcy/facilitator/<handle> (in a mesh,
agntcy/facilitator-<node id>/<handle>: SLIM syncs names across peer links, so a node's names are its own),
subscribed to its own name and listening for sessions. A delivery opens a point-to-point session to
the recipient's name, publishes the signed packets (the message and its route) and closes it. The
recipient checks the packets and puts them in its store before it hands the message over. When the
recipient is not attached, the session cannot be made: the delivery stays waiting in the record (rule 4),
and `receive` finds it there when the participant attaches. The record is read again every few seconds
in `receive` as well, so a lost notification delays a message and never loses it.

`poll` (FACILITATOR_TRANSPORT=poll) carries nothing and reads the record only: for the Docker-free
tests, never a silent fallback (check says which is in use).
"""
from __future__ import annotations

import asyncio
import datetime
import json
import os
import queue
import threading
import time

ORG, NS = "agntcy", "facilitator"


def payload(conv: str, message_id: str, entries: list[bytes]) -> bytes:
    return json.dumps({"v": 1, "conv": conv, "message_id": message_id,
                       "entries": [e.decode("utf-8") for e in entries]}, separators=(",", ":")).encode()


def parse_payload(raw: bytes) -> dict | None:
    try:
        d = json.loads(raw)
        if d.get("v") == 1 and isinstance(d.get("entries"), list) and isinstance(d.get("conv"), str):
            return d
    except (ValueError, AttributeError):
        pass
    return None


class PollTransport:
    name = "poll"

    def __init__(self, *a, **k):
        pass

    def start(self) -> None:
        pass

    def notify(self, handle: str, data: bytes) -> bool:
        return True

    def wait(self, timeout: float) -> bytes | None:
        time.sleep(min(timeout, 0.5))
        return None

    def close(self) -> None:
        pass


class SlimTransport:
    """SLIM in a background thread with its own asyncio loop, so the synchronous core can call it."""
    name = "slim"

    def __init__(self, endpoint: str, username: str, password: str, secret: str, me: str, ns: str = NS):
        self.endpoint, self.username, self.password, self.secret, self.me = endpoint, username, password, secret, me
        self.ns = ns
        self.inbox: queue.Queue[bytes] = queue.Queue()
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, name="slim", daemon=True)
        self.app = None
        self.conn = None

    def _credentials(self) -> dict:
        """SLIM's basic auth: the node's user and the secret generated at infra up (never printed)."""
        return {"username": self.username, "password": self.password}

    def _run(self, coro, timeout: float):
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(timeout)

    def start(self) -> None:
        self.thread.start()
        self._run(self._start(), 20)

    async def _start(self) -> None:
        import slim_bindings as sb       # the native client, installed in the Feature's venv
        self.sb = sb
        if not sb.is_initialized():
            # SLIM's tracing writes to standard output, which is the MCP channel: errors only.
            sb.initialize_with_configs(sb.new_runtime_config(), sb.new_tracing_config_with("error", False, False, []),
                                       [sb.new_service_config()])
        svc = sb.get_global_service()
        base = sb.new_insecure_client_config(self.endpoint)
        basic = sb.BasicAuth(**self._credentials())
        cfg = sb.ClientConfig(**{**vars(base), "auth": sb.ClientAuthenticationConfig.BASIC(config=basic)})
        self.conn = await svc.connect_async(cfg)
        name = sb.Name(ORG, self.ns, self.me)
        self.app = svc.create_app_with_secret(name, self.secret)     # the blocking form: the _async one panics in 3.3.9
        await self.app.subscribe_async(name, self.conn)
        self.loop.create_task(self._listen())

    async def _listen(self) -> None:
        td = datetime.timedelta
        while True:
            try:
                s = await self.app.listen_for_session_async(td(seconds=3600))
            except Exception:       # noqa: BLE001 - a timeout or a closed app: listen again, or stop when closed
                if self.app is None:
                    return
                await asyncio.sleep(0.2)
                continue
            self.loop.create_task(self._read(s))

    async def _read(self, s) -> None:
        td = datetime.timedelta
        while True:
            try:
                m = await s.get_message_async(td(seconds=3600))
            except Exception:       # noqa: BLE001 - the sender closed the session
                return
            self.inbox.put(bytes(m.payload))

    async def _notify(self, handle: str, data: bytes) -> bool:
        sb, td = self.sb, datetime.timedelta
        cfg = sb.SessionConfig(session_type=sb.SessionType.POINT_TO_POINT, max_retries=2,
                               interval=td(milliseconds=400), metadata={}, mls_settings=None)
        try:
            s = await asyncio.wait_for(self.app.create_session_and_wait_async(cfg, sb.Name(ORG, self.ns, handle)), 4)
        except Exception:           # noqa: BLE001 - nobody listens under that name: not attached
            return False
        try:
            h = await s.publish_async(data, None, None)
            await h.wait_async()
            return True
        except Exception:           # noqa: BLE001
            return False
        finally:
            try:
                h = await self.app.delete_session_async(s)
                await h.wait_async()
            except Exception:       # noqa: BLE001
                pass

    def notify(self, handle: str, data: bytes) -> bool:
        try:
            return self._run(self._notify(handle, data), 10)
        except Exception:           # noqa: BLE001
            return False

    def wait(self, timeout: float) -> bytes | None:
        try:
            return self.inbox.get(timeout=max(0.0, timeout))
        except queue.Empty:
            return None

    def close(self) -> None:
        app, self.app = self.app, None
        if app is not None:
            try:
                self._run(app.unsubscribe_async(self.sb.Name(ORG, self.ns, self.me), self.conn), 3)
            except Exception:       # noqa: BLE001
                pass
        async def _stop():
            for t in asyncio.all_tasks(self.loop):
                if t is not asyncio.current_task():
                    t.cancel()
        try:
            self._run(_stop(), 3)
        except Exception:           # noqa: BLE001
            pass
        self.loop.call_soon_threadsafe(self.loop.stop)


def make(settings, secrets_: dict | None, me: str, ns: str = NS):
    kind = settings["FACILITATOR_TRANSPORT"]
    if kind == "poll":
        return PollTransport()
    if kind != "slim":
        raise ValueError(f"FACILITATOR_TRANSPORT={kind!r}: slim (the default) or poll (tests)")
    if not secrets_:
        raise ValueError("SLIM's secrets are not set up: facilitator infra up")
    return SlimTransport(f"http://127.0.0.1:{settings['FACILITATOR_SLIM_PORT']}", "facilitator",
                         secrets_["password"], secrets_["secret"], me, ns)


def ephemeral_name(handle: str) -> str:
    return f"{handle}-{os.getpid():x}"
