"""The collector module, as plain joining (no model before slice 6): when several deliveries wait for one
participant at once and answer the same message (the replies to a question it put to several), they are
handed over as one turn, each part under its writer and message id, so a reference stays exact."""
from __future__ import annotations


def group(pending: list[dict]) -> list[dict]:
    """The first waiting delivery and every other one that answers the same message, in order."""
    if not pending:
        return []
    first = pending[0]
    key = first["message"].get("reply_to")
    if not key:
        return [first]
    return [p for p in pending if p["message"].get("reply_to") == key]


def join(batch: list[dict]) -> str:
    if len(batch) == 1:
        m = batch[0]["message"]
        return f"@{m['from']}: {m['text']}"
    lines = [f"{len(batch)} replies to your message {batch[0]['message']['reply_to']}:"]
    for p in batch:
        m = p["message"]
        lines.append(f"- @{m['from']} ({m['message_id']}): {m['text']}")
    return "\n".join(lines)
