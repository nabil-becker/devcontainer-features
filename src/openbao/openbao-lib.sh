# shellcheck shell=bash
# openbao-feature/openbao-lib.sh: sourced (never run) by openbao-server and openbao-onboard, so the
# two share one definition of what must not drift apart: the refusal inside an agent's job and
# without a terminal, the prompts, and the AppRole role settings. The caller sets `prog` first.

# shellcheck disable=SC2154  # prog is the caller's
say() { echo "$prog: $*" >&2; }
die() { # <exit code> <line>
  local code="$1"
  shift
  say "$*"
  exit "$code"
}

# An agent's job: the devhost's backs run their CLI with DEVHOST_JOB_CHILD, and Claude Code sets
# CLAUDECODE on every process it starts (its tool calls, subagents and headless runs).
# OPENBAO_AGENT_JOB_VARS names more variables (space separated) for another agent CLI.
guard() { # <task> <why>
  local v
  # shellcheck disable=SC2086  # a list of names
  for v in DEVHOST_JOB_CHILD CLAUDECODE ${OPENBAO_AGENT_JOB_VARS:-}; do
    if [ -n "${!v:-}" ]; then
      die 3 "task openbao:$1 refuses to run inside an agent's job ($v is set): $2. Run it yourself in a plain terminal in the devcontainer"
    fi
  done
}
# Bracketed paste off (ESC [ ? 2004 l). A shell such as pwsh (PSReadLine) leaves it on while a child
# runs, so a pasted share arrives as ESC[200~<share>ESC[201~ and bao's hidden prompt, which reads
# raw bytes, sends the markers with the key ("'key' must be a valid hex or base64 string"). Only
# to a terminal; the shell sets it again at its next prompt.
paste_off() {
  if [ -t 1 ]; then printf '\033[?2004l'; elif [ -t 2 ]; then printf '\033[?2004l' >&2; fi
  return 0
}
need_tty() { # <task>
  { [ -t 0 ] && [ -t 1 ]; } || die 3 "task openbao:$1 needs a terminal on stdin and stdout (it asks for secrets and prints them only to a terminal); run it in a plain terminal, not through a pipe or a script"
  paste_off # every prompt that follows takes a paste as typed
}
ask() { # <prompt> -> $REPLY, echoed input
  printf '%s ' "$1" >&2
  IFS= read -r REPLY || die 3 "no answer (the input ended)"
}
ask_secret() { # <prompt> -> $REPLY, input hidden
  paste_off
  printf '%s ' "$1" >&2
  IFS= read -rs REPLY || die 3 "no answer (the input ended)"
  printf '\n' >&2
}

# The one definition of an AppRole role of this Feature, with the token of the environment: only
# from inside this container (loopback-bound secret ids and tokens), 5 minute tokens (at most 15),
# secret ids that do not expire, so the backs do not stop on a date nobody watches (they are
# reissued instead).
role_write() { # <role> <comma separated policies>
  bao write "auth/approle/role/$1" token_policies="$2" token_ttl=5m token_max_ttl=15m \
    secret_id_ttl=0 secret_id_num_uses=0 secret_id_bound_cidrs=127.0.0.1/32 token_bound_cidrs=127.0.0.1/32 >/dev/null
}
