"""`facilitator model --as <handle> --endpoint <url> --model <name> --definition <file>`: the local-model
wrapper (proposal D8: the `openai-compatible` adapter's receive loop). It runs `receive`, sends the
definition (as the system prompt) and the conversation so far to an OpenAI-compatible
`/v1/chat/completions` endpoint (Ollama, llama.cpp's server, ...), and `reply`s with the answer. The
endpoint keeps no state, so the conversation is rebuilt from the record each turn. A harness keeps it
running; the Feature never starts it. The answer is parsed for nothing: a model that wants another
recipient starts its text with @handle (the one text rule)."""
from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.request

MAX_HISTORY = 30


class ModelError(RuntimeError):
    pass


def chat_url(endpoint: str) -> str:
    e = endpoint.rstrip("/")
    if e.endswith("/chat/completions"):
        return e
    if not e.endswith("/v1"):
        e += "/v1"
    return e + "/chat/completions"


def complete(endpoint: str, model: str, messages: list[dict], timeout: float = 300, api_key: str | None = None) -> str:
    body = json.dumps({"model": model, "messages": messages, "stream": False}).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(chat_url(endpoint), data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read())
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise ModelError(f"{chat_url(endpoint)}: {e}") from None
    try:
        text = d["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise ModelError(f"{chat_url(endpoint)}: no choices[0].message.content in the answer") from None
    if not isinstance(text, str) or not text.strip():
        raise ModelError(f"{chat_url(endpoint)}: an empty answer")
    return text.strip()


def history(fac, handle: str, conv: str) -> list[dict]:
    """The conversation so far as chat messages: the participant's own as assistant, the others' as user."""
    _, proj, _ = fac.record.read(conv)
    out = []
    for mid in proj["order"][-MAX_HISTORY:]:
        m = proj["messages"][mid]
        if m["from"] == handle:
            out.append({"role": "assistant", "content": m["text"]})
        else:
            out.append({"role": "user", "content": f"@{m['from']}: {m['text']}"})
    return out


def run(session, endpoint: str, model: str, definition: str, wait: int, once: bool = False,
        api_key: str | None = None, log=sys.stderr) -> int:
    fac, handle = session.fac, session.handle
    system = (definition.strip() + "\n\n" if definition.strip() else "") + (
        f"You are @{handle}. Each user message starts with the sender's @handle. Answer in a few sentences. "
        "To address someone other than the sender, start your answer with their @handle.")
    while True:
        got = session.receive(wait)
        if got is None:
            if once:
                print(f"{handle}: nothing yet", file=log)
                return 0
            continue
        msgs = [{"role": "system", "content": system}] + history(fac, handle, got["conversation"])
        try:
            answer = complete(endpoint, model, msgs, api_key=api_key)
        except ModelError as e:
            print(f"{handle}: the model did not answer: {e}", file=log)
            time.sleep(2)
            if once:
                return 1
            continue
        r = session.reply(answer)
        print(f"{handle}: answered {got['message_id']} with {r['message_id']} (rule {r['rule']}, to "
              f"{', '.join(r['to']) or 'nobody'})", file=log, flush=True)
        if once:
            return 0
