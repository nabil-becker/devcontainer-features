#!/usr/bin/env bash
# The agentic-register Feature (SPEC.md, README.md). Installs:
#   /usr/local/lib/agentic-register/register/     the core, the adapters, the command, the MCP server
#   /usr/local/lib/agentic-register/options.env  this Feature's options, read by the command
#   /usr/local/bin/agentic-register              the one command (tasks and MCP tools call it)
#   /usr/local/bin/agentic-register-setup        the post-create hook
#   /usr/local/libexec/agentic-register/dcf-persist   the state-folder helper, this Feature's own copy
#   /usr/local/share/go-task/includes.d/agentic-register.yml   the Taskfile (installTaskfile)
# Options arrive as upper-cased environment variables: INSTALLTASKFILE, REGISTERS, ANCHORS, REGISTERMCP, MCPTOOLS.
# DESTDIR (tests only) installs under another root, as a user, and skips the system steps.
set -euo pipefail

INSTALLTASKFILE="${INSTALLTASKFILE:-true}"
REGISTERS="${REGISTERS:-}"
ANCHORS="${ANCHORS:-}"
REGISTERMCP="${REGISTERMCP:-true}"
MCPTOOLS="${MCPTOOLS:-}"
DESTDIR="${DESTDIR:-}"

if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then
  echo "agentic-register: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
  exit 1
fi

feature_dir="$(cd "$(dirname "$0")" && pwd)"
version="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$feature_dir/devcontainer-feature.json" | head -n1)"

need_python() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'
}
if [ -z "$DESTDIR" ] && { ! need_python || ! command -v ssh-keygen >/dev/null 2>&1; }; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends python3 openssh-client
    rm -rf /var/lib/apt/lists/*
  fi
fi
if ! need_python; then
  echo "agentic-register: needs Python 3.11 or later (add ghcr.io/devcontainers/features/python, or a newer base image)." >&2
  exit 1
fi
if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "agentic-register: needs ssh-keygen (OpenSSH 8.1 or later), and apt-get is not available to install it." >&2
  exit 1
fi

lib="$DESTDIR/usr/local/lib/agentic-register"
bin="$DESTDIR/usr/local/bin"
libexec="$DESTDIR/usr/local/libexec/agentic-register"
mkdir -p "$lib/register" "$bin" "$libexec"
rm -f "$lib"/register/*.py
for f in "$feature_dir"/register/*.py; do install -m 0644 "$f" "$lib/register/"; done
install -m 0644 "$feature_dir/SPEC.md" "$lib/SPEC.md"
cat > "$lib/options.env" <<OPTIONS
VERSION=$version
ANCHORS=$ANCHORS
REGISTERMCP=$REGISTERMCP
MCPTOOLS=$MCPTOOLS
OPTIONS
if ! python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from register import mcp; mcp.exposed()' "$lib"; then
  echo "agentic-register: the mcpTools option names a tool there is not (see above)." >&2
  exit 1
fi
rm -f "$lib/registers.json"
# The option arrives through the devcontainer CLI's env file (NAME="value", nothing escaped), so it is
# either the quote-free form or JSON whose quotes survived; either way registers.json gets JSON.
if [ -n "$REGISTERS" ]; then
  # Parsed into a file beside it, then moved: the command reads registers.json for the installed guards.
  if ! AGENTIC_REGISTER_REGISTERS="$REGISTERS" python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); from register import cli; print(json.dumps(cli.registers()))' "$lib" > "$lib/registers.json.new"; then
    rm -f "$lib/registers.json.new"
    echo "agentic-register: the registers option is not a valid list of registers (see above)." >&2
    exit 1
  fi
  mv "$lib/registers.json.new" "$lib/registers.json"
fi
install -m 0755 "$feature_dir/bin/agentic-register" "$bin/agentic-register"
install -m 0755 "$feature_dir/agentic-register-setup.sh" "$bin/agentic-register-setup"
install -m 0755 "$feature_dir/dcf-persist.sh" "$libexec/dcf-persist"

includes="$DESTDIR/usr/local/share/go-task/includes.d"
if [ "$INSTALLTASKFILE" = "true" ]; then
  mkdir -p "$includes"
  install -m 0644 "$feature_dir/taskfile.yml" "$includes/agentic-register.yml"
  if [ -z "$DESTDIR" ] && command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
else
  rm -f "$includes/agentic-register.yml"
fi

echo "agentic-register $version installed (registers: ${REGISTERS:-ledger}; taskfile: $INSTALLTASKFILE; MCP: $REGISTERMCP${MCPTOOLS:+, tools: $MCPTOOLS})"
