"""The facilitator command (the Feature's NOTES, "Commands"; its Taskfile calls it). Exit 0 done, 1 failed
or not ready, 2 bad usage."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

from . import __version__, mcp, settings as settings_mod
from .app import Facilitator, FacilitatorError, Session, _ago
from .directory import DirectoryError
from .infra import COMPONENTS, InfraError
from .participants import ListError
from .record import FACILITATOR, RecordError
from .settings import SettingsError
from .signer import SignerError, openbao_status
from .transcript import TranscriptError

ERRORS = (FacilitatorError, InfraError, ListError, RecordError, SettingsError, SignerError, DirectoryError,
          TranscriptError)


def _emit(a, value, text: str) -> None:
    print(json.dumps(value, indent=2, sort_keys=True, default=str) if getattr(a, "json", False) else text)


def _fac(a) -> Facilitator:
    return Facilitator(settings_mod.load())


def _versions(fac) -> dict:
    out = {"facilitator": __version__, "python": sys.version.split()[0], "library": str(settings_mod.LIB)}
    try:
        from registerengine import __version__ as rv, core
        out["register-engine"] = rv
        out["sign-packet"] = core.sp.__version__
    except Exception:                          # noqa: BLE001
        pass
    inf = fac.infra()
    for c, flag in (("dir", "version"), ("slim", "version")):
        b = inf.binary(c)
        name = "dirctl" if c == "dir" else "slimctl"
        if not b:
            out[name] = "missing"
            continue
        r = subprocess.run([b, flag], capture_output=True, text=True, timeout=30)
        txt = (r.stdout + r.stderr).strip()
        out[name] = next((w.lstrip("v") for line in txt.splitlines() for w in line.replace("\t", " ").split()
                          if w[:1].isdigit() or (w[:1] == "v" and w[1:2].isdigit())), txt[:40])
    try:
        import slim_bindings
        out["slim-bindings"] = slim_bindings.get_version()
    except Exception:                          # noqa: BLE001
        out["slim-bindings"] = "missing"
    return out


def cmd_version(a) -> int:
    fac = _fac(a)
    v = _versions(fac)
    v["backend"] = fac.s["FACILITATOR_BACKEND"]
    _emit(a, v, f"facilitator {v['facilitator']} (backend {v['backend']}; register-engine {v.get('register-engine')}, "
                f"sign-packet {v.get('sign-packet')})\n"
                f"dirctl       : {v['dirctl']}\nslimctl      : {v['slimctl']}\nslim-bindings: {v['slim-bindings']} "
                f"(the node version it speaks)\npython       : {v['python']}\nlibrary      : {v['library']}")
    return 0


def cmd_check(a) -> int:
    fac = _fac(a)
    parts = []

    def part(name, ok, detail, needed=True):
        parts.append({"part": name, "ready": bool(ok), "detail": detail, "needed": needed})

    part("python", sys.version_info >= (3, 11), sys.version.split()[0])
    for tool in ("ssh-keygen", "ssh-agent", "ssh-add"):
        part(tool, shutil.which(tool), shutil.which(tool) or "missing (openssh-client)")
    part("backend", True, f"{fac.s['FACILITATOR_BACKEND']} (from {fac.s.sources['FACILITATOR_BACKEND']})")
    ok, detail = fac.state.writable()
    part("state", ok, detail)
    try:
        fac.record
        part("record", True, "the conversation type loads (register-engine, sign-packet)")
    except RecordError as e:
        part("record", False, str(e))
    v = _versions(fac)
    part("dirctl", v["dirctl"] != "missing", v["dirctl"])
    part("slimctl", v["slimctl"] != "missing", v["slimctl"])
    transport = fac.s["FACILITATOR_TRANSPORT"]
    part("slim-bindings", v["slim-bindings"] != "missing" or transport == "poll",
         v["slim-bindings"] if transport == "slim" else f"{v['slim-bindings']} (transport poll: tests only, no SLIM)")
    st = openbao_status()
    fb = (fac.state.keys / "FALLBACK").exists()
    part("keys", True, f"OpenBao {st}" + ("; some keys are in the 0.1.0 fallback file (keys/FALLBACK)" if fb else ""))
    inf = fac.infra()
    for row in inf.status():
        why = "healthy" if row["healthy"] else "not running: facilitator infra up"
        if row.get("port_owners"):
            why += "; port in use by " + ", ".join(f"{o} ({k})" for k, o in row["port_owners"].items())
        part(row["component"], row["healthy"], f"{why} {' '.join(row.get('ports', {}).values())}".strip())
    try:
        plist, cfg, warnings, path = fac.participants()
        part("participants", True, f"{len(plist)} in {path}" + ("" if path.exists() else " (none yet)"), needed=False)
        roster = fac.state.roster()
        for p in plist:
            reg = p.name in roster
            tok = (fac.state.tokens / p.name).exists()
            seen = fac.state.last_seen(p.name)
            part(f"  {p.name}", reg and tok, f"{'registered' if reg else 'not registered (facilitator register ' + p.name + ')'}"
                 f", token {'made' if tok else 'missing'}, attachment {p.attachment} last seen {_ago(seen)}", needed=False)
        for w in warnings:
            part("  note", True, w, needed=False)
    except ListError as e:
        part("participants", False, str(e))
    _emit(a, parts, "\n".join(f"facilitator: {p['part']:<14} {'ready' if p['ready'] else 'NOT READY'}  {p['detail']}"
                              for p in parts))
    return 0 if all(p["ready"] for p in parts if p["needed"]) else 1


def cmd_setup(a) -> int:
    """Never fatal: each problem is one line."""
    try:
        fac = _fac(a)
        fac.state.ensure()
        fac.record.facilitator_key()
        n = 0
        if a.rotate_tokens:
            for h, ident in fac.state.roster().items():
                if ident.get("kind") in ("agent", "human"):
                    fac.state.make_token(h)
                    n += 1
        if not a.quiet:
            print(f"facilitator: state ready in {fac.state.home}" + (f"; {n} participant token(s) made again" if a.rotate_tokens else ""))
    except Exception as e:                     # noqa: BLE001
        print(f"facilitator: setup: {e}", file=sys.stderr)
    return 0


def cmd_start(a) -> int:
    """postStartCommand: setup (tokens made again: they are valid for this container start), then the
    infrastructure when autostart is on. Never fatal; participants are never started."""
    a.rotate_tokens, a.quiet = True, False
    cmd_setup(a)
    try:
        fac = _fac(a)
        if not fac.s.bool("FACILITATOR_AUTOSTART"):
            print("facilitator: autostart is off; facilitator infra up starts the Directory and SLIM")
            return 0
        for c, word in fac.infra().up():
            print(f"facilitator: {c} {word}")
    except Exception as e:                     # noqa: BLE001
        print(f"facilitator: autostart did not complete: {e} (facilitator check; facilitator infra up)", file=sys.stderr)
    return 0


def cmd_infra(a) -> int:
    fac = _fac(a)
    inf = fac.infra()
    which = [a.component] if a.component else None
    if a.action == "up":
        for c, word in inf.up(which):
            print(f"facilitator: {c} {word}")
        return 0
    if a.action == "down":
        for c, word in inf.down(which):
            print(f"facilitator: {c} {word}")
        return 0
    if a.action == "logs":
        if a.component == "agent":
            print("facilitator: the ssh-agent keeps no log")
            return 0
        print(inf.logs(a.component, a.lines))
        return 0
    rows = [r for r in inf.status() if not a.component or r["component"] == a.component]
    _emit(a, rows, "\n".join(
        f"facilitator: {r['component']:<6} {'healthy' if r['healthy'] else 'running' if r['running'] else 'stopped'}"
        f"{'  pid ' + str(r['pid']) if r['pid'] and r['running'] else ''}  {' '.join(r.get('ports', {}).values())}"
        + (f"  ({r['note']})" if r.get("note") else "") for r in rows))
    return 0 if all(r["healthy"] for r in rows) else 1


def cmd_register(a) -> int:
    fac = _fac(a)
    plist, cfg, _, _ = fac.participants()
    handles = [p.name for p in plist] + list(cfg.humans) if a.all else a.handles
    if not handles:
        raise FacilitatorError("register <handle>... or --all")
    rows = []
    for h in handles:
        rows.append(fac.register(h, new_key=a.new_key, push=not a.no_directory))
    _emit(a, rows, "\n".join(
        f"facilitator: {r['handle']} registered ({r['kind']}, key in {r['keystore']}"
        + (f", token {r['token']}" if r.get("token") else "") + (f", record {r['cid']}" if r.get("cid") else "") + ")"
        for r in rows))
    return 0


def cmd_participants(a) -> int:
    fac = _fac(a)
    plist, cfg, warnings, path = fac.participants()
    roster = fac.state.roster()
    rows = [{**p.json(), "registered": p.name in roster, "cid": roster.get(p.name, {}).get("cid"),
             "keystore": roster.get(p.name, {}).get("keystore")} for p in plist]
    rows += [{"name": h, "kind": "human", "registered": h in roster} for h in cfg.humans]
    text = [f"facilitator: {path}"] + [
        f"  {r['name']:<20} {r.get('cli', '-'):<18} {r['kind']:<10} {'registered' if r['registered'] else 'not registered'}"
        + (f"  {r['description']}" if r.get("description") else "") for r in rows] + [f"  note: {w}" for w in warnings]
    _emit(a, {"file": str(path), "participants": rows, "warnings": warnings}, "\n".join(text))
    return 0


def cmd_status(a) -> int:
    from . import guard
    fac = _fac(a)
    w = fac.who()
    convs = []
    for c in fac.record.conversations():
        _, proj, _ = fac.record.read(c)
        if proj["thread"] is None:
            continue
        last = proj["messages"][proj["order"][-1]] if proj["order"] else None
        convs.append({"conversation": c, "kind": proj["thread"]["kind"], "members": proj["thread"]["members"],
                      "messages": len(proj["order"]), "last_hops": last["hops"] if last else 0,
                      "paused": guard.paused(proj) or "", "budget_used": guard.since_continue(proj),
                      "waiting": sum(1 for t in proj["tasks"].values() if t["state"] == "submitted")})
    out = {"participants": w["participants"], "conversations": convs}
    lines = ["participants:"] + [
        f"  @{p['handle']:<20} " + (f"{'attached' if p.get('attached') else 'not attached'}, last receive {p.get('last_seen')}"
                                    if p["kind"] == "agent" else "human") for p in w["participants"]]
    lines += ["conversations:"] + [
        f"  {c['conversation']} {c['kind']:<6} {', '.join(c['members'])}: {c['messages']} message(s), last hops "
        f"{c['last_hops']}, budget {c['budget_used']}/{fac.limits.message_budget}, {c['waiting']} waiting"
        + (f", PAUSED ({c['paused']}: a person's continue)" if c["paused"] else "") for c in convs]
    _emit(a, out, "\n".join(lines))
    return 0


def _handle(a, required: bool = True) -> str | None:
    """--as, else FACILITATOR_HANDLE (one MCP entry serves every agent whose harness sets it)."""
    h = getattr(a, "as_", None) or os.environ.get("FACILITATOR_HANDLE", "").strip() or None
    if h is None and required:
        raise SettingsError("no handle: set FACILITATOR_HANDLE (with FACILITATOR_TOKEN) in the CLI's environment, "
                            "or pass --as <handle>")
    return h


def cmd_mail(a) -> int:
    """Read only (the mail tool of a person's MCP session marks messages read; this never does)."""
    if a.notice or a.hook:
        # the turn hook: one line or nothing, never a failure, never a wait
        try:
            fac = _fac(a)
            h = _handle(a, required=False)
            line = fac.mail_notice(h) if h else ""
        except Exception:                      # noqa: BLE001 - a hook must never fail a turn
            line = ""
        if line and a.hook:
            print(json.dumps({"systemMessage": line, "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": line + " (the facilitator's mail tool reads them)"}}))
        elif line:
            print(line)
        return 0
    from .mcp import mail_text
    fac = _fac(a)
    h = _handle(a)
    if h not in fac.humans():
        raise FacilitatorError(f"{h} is not a human of facilitator.yml (humans: {', '.join(fac.humans())})")
    r = fac.mail(h, a.limit, mark=False)
    _emit(a, r, mail_text(r))
    return 0


def cmd_transcript(a) -> int:
    from .transcript import lines, transcript
    fac = _fac(a)
    if a.json:
        print(json.dumps(transcript(fac, a.conv, a.limit), indent=2, sort_keys=True))
        return 0
    print("\n".join(lines(fac, a.conv, a.limit)))
    return 0


def cmd_verify(a) -> int:
    from .verify import verify
    fac = _fac(a)
    r = verify(fac, a.conv, a.message)
    if a.format == "json":
        print(json.dumps(r, indent=2, sort_keys=True))
    else:
        for mid, lines in r["chains"].items():
            if a.message or mid == list(r["chains"])[-1]:
                print("\n".join(lines))
        for p in r["problems"]:
            print(f"{a.conv}: {p}")
        print(f"facilitator: {a.conv}: {r['entries']} entries, {r['messages']} message chain(s) walked: "
              f"{'every chain verifies back to a human' if r['ok'] else str(len(r['problems'])) + ' problem(s)'}")
    return 0 if r["ok"] else 1


def cmd_snippet(a) -> int:
    fac = _fac(a)
    plist, cfg, _, _ = fac.participants()
    p = next((x for x in plist if x.name == a.handle), None)
    human = a.handle in cfg.humans
    if p is None and not human:
        raise FacilitatorError(f"{a.handle} is neither in the participant list nor a human of facilitator.yml")
    tokens = fac.state.tokens / a.handle
    cfg_ = {"mcpServers": {"facilitator": {"type": "stdio", "command": "facilitator", "args": ["mcp"]}}}
    env = [f"FACILITATOR_HANDLE={a.handle}", f'FACILITATOR_TOKEN="$(cat {tokens})"']
    shared = "claude mcp add --scope user facilitator -- facilitator mcp"
    if human:
        hook = f"facilitator mail --as {a.handle} --hook 2>/dev/null || true"
        settings = {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": hook, "timeout": 10}]}]}}
        out = {"handle": a.handle, "kind": "human", "mcp_config": cfg_, "add": shared, "env": env,
               "token_file": str(tokens), "hook": settings, "notice": f"facilitator mail --as {a.handle} --notice",
               "instructions": mcp.persona(a.handle, True)}
        lines = [f"# {a.handle}: talk to the agents from your own Claude Code session, over the facilitator's MCP server",
                 "# (the Feature never edits a CLI's settings, NFR-13: run or paste these yourself).",
                 "# 1. The one shared MCP entry (the same for every agent and person; it names no handle):",
                 shared,
                 "# 2. Start your session with your handle and token in its environment (tokens are made again at",
                 "#    each container start, so never put the token in the entry):",
                 f"{' '.join(env)} claude",
                 "# 3. Optional, the turn hook: a line 'Facilitator: N new messages in c-...' at each prompt, or",
                 "#    nothing. Add this to ~/.claude/settings.json (or .claude/settings.local.json); it never",
                 "#    fails a turn:",
                 json.dumps(settings, indent=2),
                 "# Copilot CLI: the same MCP entry (copilot mcp add facilitator -- facilitator mcp) and environment;",
                 "#    it has no hook that can show a line at each turn, so ask it to call mail. In any shell:",
                 f"#    facilitator mail --as {a.handle} --notice",
                 "# Then: 'ask @jester for a joke'; 'any mail?'; 'continue c-...' when a conversation pauses."]
        _emit(a, out, "\n".join(lines))
        return 0
    out = {"handle": a.handle, "kind": "agent", "cli": p.cli, "persona": mcp.persona(a.handle), "mcp_config": cfg_,
           "add": shared, "env": env, "token_file": str(tokens)}
    lines = [f"# {a.handle}: attach its {p.cli} CLI to the facilitator (the Feature never edits a CLI's config, NFR-13)."]
    if p.cli == "claude":
        lines += ["# 1. The one shared MCP entry (once for every agent; it names no handle), through Claude Code's own command:",
                  shared,
                  "#    or, for one run: claude -p --mcp-config '" + json.dumps(cfg_) + "' ..."]
    elif p.cli == "openai-compatible":
        lines += ["# 1. A local model needs no MCP: its harness runs the model wrapper:",
                  f"facilitator model --as {a.handle} --endpoint http://localhost:11434/v1 --model <name> "
                  f"--definition {p.definition or '<persona file>'}"]
    else:
        lines += [f"# 1. The one shared stdio MCP entry (it names no handle), through {p.cli}'s own MCP command:",
                  json.dumps(cfg_)]
    lines += ["# 2. The harness starts the CLI with these two in its environment, never in the MCP entry of step 1",
              "#    (tokens are made again at each container start, so an entry would go stale):",
              *env,
              "# 3. Add this sentence to its definition (system prompt, profile or first message):",
              mcp.persona(a.handle)]
    _emit(a, out, "\n".join(lines))
    return 0


def cmd_mcp(a) -> int:
    proto = mcp.private_stdout()
    fac = _fac(a)
    wait = fac.s.int("FACILITATOR_RECEIVE_WAIT_SECONDS")

    handle = _handle(a)
    human = fac.state.roster().get(handle, {}).get("kind") == "human"

    def make():
        s = Session(fac, handle, os.environ.get("FACILITATOR_TOKEN"))
        try:
            s.tr = fac.transport_for(handle)
        except Exception as e:                 # noqa: BLE001
            raise FacilitatorError(f"SLIM is not reachable ({e}): facilitator infra up") from None
        return s

    server = mcp.Server(handle, make, wait, out=proto, inp=sys.stdin, human=human)
    try:
        return server.serve()
    finally:
        if server.session is not None and server.session.tr is not None:
            server.session.tr.close()


def cmd_model(a) -> int:
    from . import model
    fac = _fac(a)
    s = Session(fac, a.as_, os.environ.get("FACILITATOR_TOKEN"))
    s.tr = fac.transport_for(a.as_)
    definition = ""
    if a.definition:
        with open(a.definition) as f:
            definition = f.read()
    try:
        return model.run(s, a.endpoint, a.model, definition, a.wait or fac.s.int("FACILITATOR_RECEIVE_WAIT_SECONDS"),
                         once=a.once, api_key=os.environ.get("FACILITATOR_MODEL_API_KEY"))
    finally:
        s.tr.close()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="facilitator", description="The facilitator: conversations between agents of "
                                                                  "any vendor, on AGNTCY (the Feature's NOTES).")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def command(name, fn, help_, json_=True):
        c = sub.add_parser(name, help=help_)
        if json_:
            c.add_argument("--json", action="store_true", help="output for machines")
        c.set_defaults(fn=fn)
        return c

    command("version", cmd_version, "what is installed")
    command("check", cmd_check, "what is ready, one line a part; non-zero when not")
    c = command("setup", cmd_setup, "the state folder and the facilitator's key (idempotent, never fatal)", False)
    c.add_argument("--rotate-tokens", action="store_true", help="make every participant's token again")
    c.add_argument("--quiet", action="store_true")
    command("start", cmd_start, "postStartCommand: setup, tokens made again, infra up when autostart (never fatal)", False)
    c = command("infra", cmd_infra, "the Directory, SLIM and the ssh-agent: up, down, status, logs")
    c.add_argument("action", choices=["up", "down", "status", "logs"])
    c.add_argument("component", nargs="?", choices=COMPONENTS)
    c.add_argument("--lines", type=int, default=40)
    c = command("register", cmd_register, "a participant's key, token and OASF record (a person's key and token)")
    c.add_argument("handles", nargs="*")
    c.add_argument("--all", action="store_true", help="every participant of the list and every human")
    c.add_argument("--new-key", action="store_true", help="make a new key (the old one stays valid for what it signed)")
    c.add_argument("--no-directory", action="store_true", help="do not push the OASF record")
    command("participants", cmd_participants, "the participant list and who is registered")
    command("status", cmd_status, "who is attached, and each conversation's hops, budget and pause")
    c = command("mail", cmd_mail, "a person's unread messages, read only (the MCP tool mail marks them read); "
                                  "--notice: one line or nothing, for a turn hook, never failing")
    c.add_argument("--as", dest="as_")
    c.add_argument("--limit", type=int, default=20)
    c.add_argument("--notice", action="store_true", help="one line 'Facilitator: N new messages in ...', or nothing")
    c.add_argument("--hook", action="store_true", help="the same line as Claude Code hook JSON (UserPromptSubmit)")
    c = command("transcript", cmd_transcript, "a conversation, as text or --json (read only)")
    c.add_argument("--conv", required=True)
    c.add_argument("--limit", type=int, help="its last this many messages")
    c = command("verify", cmd_verify, "walk every message back to a human-signed root; exit 0 good, 1 a break", False)
    c.add_argument("--conv", required=True)
    c.add_argument("--message")
    c.add_argument("--format", choices=["text", "json"], default="text")
    c = command("snippet", cmd_snippet, "how to attach a participant's or a person's CLI: the shared MCP entry, the "
                                        "environment, the persona; for a person, the turn hook")
    c.add_argument("handle")
    c = command("mcp", cmd_mcp, "the MCP server (stdio) a participant's or a person's CLI starts; the handle from "
                                "FACILITATOR_HANDLE, or --as", False)
    c.add_argument("--as", dest="as_")
    c = command("model", cmd_model, "the local-model wrapper: receive, /v1/chat/completions, reply", False)
    c.add_argument("--as", dest="as_", required=True)
    c.add_argument("--endpoint", required=True)
    c.add_argument("--model", required=True)
    c.add_argument("--definition")
    c.add_argument("--wait", type=int)
    c.add_argument("--once", action="store_true", help="one turn (or one wait), then exit")
    a = ap.parse_args(argv)
    try:
        return a.fn(a)
    except ERRORS as e:
        print(f"facilitator: {e}", file=sys.stderr)
        return 2 if isinstance(e, SettingsError) and "not yet" not in str(e) else 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
