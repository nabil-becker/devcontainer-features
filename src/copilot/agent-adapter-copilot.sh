#!/usr/bin/env bash
# agent-adapter-copilot: the GitHub Copilot CLI adapter of the participant component's contract
# (src/agents/NOTES.md "The adapter contract", ADR-0037). Installed on PATH by the copilot Feature;
# the participant component (the agents command) and the facilitator's pump call it, nothing else
# does. The second real adapter beside agent-adapter-claude (NFR-12).
#
#   agent-adapter-copilot <verb> <name> <folder> [-- copilot args...]
#     (<name> is the participant's handle. The session's own name is $AGENT_SESSION_NAME when the
#     caller sets it and it is one line, else the handle: "session name" below)
#     new        cd <folder> && copilot --name <session name> <args>   (a terminal is needed)
#     resume     cd <folder> && copilot --resume <session name> <args> (its own picker is not
#                used: a name that no session has fails in Copilot with its own message)
#     hint       how to find and resume the participant by hand
#     run-once   one non-interactive turn: the prompt on stdin, the reply on stdout, exit when done:
#                cd <folder> && copilot -p <prompt> --silent --no-ask-user --no-auto-update <args>.
#                With no one to ask, a tool the CLI would ask about is refused; to let a turn use
#                tools, pass --allow-tool '<rule>' after -- (or set AGENT_ADAPTER_COPILOT_ALLOW_ALL_TOOLS=1
#                for --allow-all-tools; off by default, since an unattended turn is a trust decision
#                the engineer makes). AGENT_ADAPTER_COPILOT_CONTINUE=1 keeps one conversation per
#                (name, folder) across turns with --session-id <a UUID derived from both>; unset,
#                every turn is a fresh session and carries its own context (the facilitator sends
#                the conversation with each message). The prompt travels as an argument (-p), so
#                other processes of the same Linux user can read it in the process list; it is
#                refused above 100000 bytes (the kernel's limit on one argument is 128 KiB).
#     mcp-attach facilitator       (<target> instead of <name> <folder>)
#                register the facilitator's MCP entry through Copilot's own command:
#                copilot mcp add facilitator -- sh -c 'exec facilitator mcp --as "$FACILITATOR_HANDLE"'.
#                The entry holds no token and no handle: the harness starts copilot with
#                FACILITATOR_HANDLE and FACILITATOR_TOKEN in its environment and the MCP server
#                inherits them (the facilitator refuses a start without the token). Replaces an
#                entry of that name, so it is idempotent. Needs no login. With no facilitator on PATH
#                it registers nothing and says so (exit 0). Not a verb of the contract yet (the
#                contract's own `attach` opens a running session); other targets exit 2.
#   AGENT_MODEL (0.2.0): new and resume run with --model <it>, in place of any --model in the args
#     (the component registry's agent definition wins, handed over by the participant component;
#     Copilot CLI 1.0.114 `copilot --help`: "--model <model>  Set the AI model to use (use 'auto'
#     to let Copilot pick automatically)"); run-once is left as its caller sends it
#   agent-adapter-copilot supports   the verbs above that work, one per line
# Exit: 0 done, 1 failed, 2 bad use, 3 not supported.
#
# Not supported (exit 3), and why: start-bg, wake, attach, list, stop, logs, record and the
# session-* verbs, because Copilot CLI has no documented local background session, session list or
# stop (its --cloud and --connect sessions are GitHub-hosted); so a copilot participant is
# on-demand or ephemeral, never resident, and has no lease liveness from a list. trust, because
# the CLI keeps trusted folders in its own config.json, which a Feature never edits (NFR-13), and
# --trust-folder trusts one prompt-mode session only.
#
# COPILOT_HOME is the CLI's, set by the Feature to its volume; the adapter reads and writes nothing
# there but through `copilot mcp`. Telemetry, login and tokens are never touched: the token the CLI
# uses comes from its own login or COPILOT_GITHUB_TOKEN, GH_TOKEN, GITHUB_TOKEN in the environment.
set -u

die() { local rc="$1"; shift; printf 'agent-adapter-copilot: %s\n' "$*" >&2; exit "$rc"; }
note() { printf 'agent-adapter-copilot: %s\n' "$*" >&2; }

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
  supports) printf '%s\n' new resume hint run-once supports; exit 0 ;;
  '') die 2 "usage: agent-adapter-copilot <verb> <name> <folder> [-- copilot args]" ;;
  start-bg | wake | attach | list | stop | logs | record | trust | session-busy | session-stop | session-remove)
    die 3 "'$verb' is not supported (Copilot CLI has no local background session, list or stop, and keeps its trusted folders itself)" ;;
  mcp-attach)
    target="${1:-}"
    [ "$target" = facilitator ] || die 2 "mcp-attach takes a target: facilitator (others are reserved)"
    command -v copilot >/dev/null 2>&1 || die 1 "copilot is not on PATH; the copilot Feature gets it from ghcr.io/devcontainers/features/copilot-cli"
    if ! command -v facilitator >/dev/null 2>&1; then
      echo "agent-adapter-copilot: the facilitator Feature is not installed; there is no entry to register (add it, then run task copilot:attach)"
      exit 0
    fi
    # shellcheck disable=SC2174  # only the last folder needs the mode
    if [ -n "${COPILOT_HOME:-}" ] && [ ! -d "$COPILOT_HOME" ]; then mkdir -p -m 0700 "$COPILOT_HOME" || die 1 "cannot create $COPILOT_HOME"; fi
    # remove then add: the CLI refuses a name that exists, and a stale entry must not stay
    copilot mcp remove facilitator </dev/null >/dev/null 2>&1 || true
    # shellcheck disable=SC2016  # the $ is for the sh that Copilot starts
    copilot mcp add facilitator </dev/null -- sh -c 'exec facilitator mcp --as "${FACILITATOR_HANDLE:?start copilot with FACILITATOR_HANDLE and FACILITATOR_TOKEN set}"' >/dev/null \
      || die 1 "'copilot mcp add facilitator' failed (is COPILOT_HOME private to its owner? Copilot refuses one writable by group or other)"
    echo "agent-adapter-copilot: registered the facilitator MCP entry (no token in it; start copilot with FACILITATOR_HANDLE and FACILITATOR_TOKEN set)"
    exit 0 ;;
  new | resume | hint | run-once) ;;
  *) die 3 "'$verb' is not supported" ;;
esac

[ $# -ge 2 ] || die 2 "$verb needs <name> <folder>"
NAME="$1" FOLDER="$2"; shift 2
# --extras (the contract's flag for stop) means nothing here; what follows the first -- is copilot's
while [ "${1:-}" = --extras ]; do shift; done
if [ "${1:-}" = -- ]; then shift; fi
SNAME="$NAME"
case "${AGENT_SESSION_NAME-}" in
  '') ;;
  *$'\n'* | *$'\r'* | *$'\t'*) note "$NAME: AGENT_SESSION_NAME has a line break or a tab; using the handle as the session name." ;;
  *) SNAME="$AGENT_SESSION_NAME" ;;
esac
[ -d "$FOLDER" ] || die 1 "$NAME: folder $FOLDER does not exist"
# The model (0.2.0): AGENT_MODEL, the model of the agent's definition in the component registry
# (participant 1.3.0), is passed as --model on new and resume, in place of any --model the args hold
# (the registry wins, the Operator's ruling of 2026-11-21; one line says what it replaced). A value
# that is not one word is left out with a note and the args are used as they are.
if [ -n "${AGENT_MODEL-}" ]; then
  case "$verb" in new | resume)
    model_re='^[][A-Za-z0-9._:/@-]+$'
    if [ "${#AGENT_MODEL}" -gt 100 ] || ! [[ "$AGENT_MODEL" =~ $model_re ]]; then
      note "$NAME: AGENT_MODEL is not one word; starting without it."
    else
      model_args=() model_was='' skip=0
      for a in "$@"; do
        if [ "$skip" -eq 1 ]; then model_was="$a"; skip=0; continue; fi
        case "$a" in
          --model) skip=1 ;;
          --model=*) model_was="${a#--model=}" ;;
          *) model_args+=("$a") ;;
        esac
      done
      [ -z "$model_was" ] || note "$NAME: the component registry's model $AGENT_MODEL replaces --model $model_was from the args."
      set -- --model "$AGENT_MODEL" ${model_args[@]+"${model_args[@]}"}
    fi ;;
  esac
fi

case "$verb" in
  hint)
    echo "$NAME has no list to read (Copilot CLI has none); resume its conversation by hand: cd '$FOLDER' && copilot --resume '$SNAME'"
    exit 0 ;;
  new)
    command -v copilot >/dev/null 2>&1 || die 1 "copilot is not on PATH"
    cd "$FOLDER" && exec copilot --name "$SNAME" "$@" ;;
  resume)
    command -v copilot >/dev/null 2>&1 || die 1 "copilot is not on PATH"
    cd "$FOLDER" && exec copilot --resume "$SNAME" "$@" ;;
  run-once)
    prompt="$(cat)"
    case "$prompt" in *[![:space:]]*) ;; *) die 2 "run-once reads the prompt from stdin and got none" ;; esac
    [ "${#prompt}" -le 100000 ] || die 2 "run-once: the prompt is ${#prompt} bytes; the limit is 100000 (it travels as one argument)"
    command -v copilot >/dev/null 2>&1 || die 1 "copilot is not on PATH"
    args=(-p "$prompt" --silent --no-ask-user --no-auto-update)
    case "${AGENT_ADAPTER_COPILOT_ALLOW_ALL_TOOLS:-}" in 1 | true | yes) args+=(--allow-all-tools) ;; esac
    case "${AGENT_ADAPTER_COPILOT_CONTINUE:-}" in
      1 | true | yes)
        # a UUID that is the same for one (name, folder): sha256 of both, shaped as a version 5 UUID
        h="$(printf '%s\0%s' "$NAME" "$FOLDER" | sha256sum | cut -c1-32)"
        v="$(printf '%x' $(( (0x${h:16:1} & 3) | 8 )))"
        args+=(--session-id "${h:0:8}-${h:8:4}-5${h:13:3}-${v}${h:17:3}-${h:20:12}") ;;
    esac
    cd "$FOLDER" && exec copilot "${args[@]}" "$@" </dev/null ;;
esac
