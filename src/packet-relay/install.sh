#!/usr/bin/env bash
# The packet-relay Feature (SPEC.md, README.md), on the sign-packet Feature. Installs:
#   /usr/local/lib/packet-relay/packetrelay/   the library: the relay, the command
#   /usr/local/lib/packet-relay/signpacket/    sign-packet's library, this Feature's own verbatim copy
#   /usr/local/lib/packet-relay/options.env    this Feature's options, read by the command
#   /usr/local/lib/packet-relay/SPEC.md        the protocol
#   /usr/local/bin/packet-relay                the one command (tasks call it)
#   /usr/local/bin/packet-relay-setup          the post-create hook
#   /usr/local/libexec/packet-relay/dcf-persist   the state-folder helper, this Feature's own copy
#   /usr/local/share/go-task/includes.d/packet-relay.yml   the Taskfile (installTaskfile)
# Options arrive as upper-cased environment variables: INSTALLTASKFILE, ROOT, GUARD, INGRESSGUARD, GUARDTIMEOUT.
# DESTDIR (tests only) installs under another root, as a user, and skips the system steps.
set -euo pipefail

INSTALLTASKFILE="${INSTALLTASKFILE:-true}"
ROOT="${ROOT:-}"
GUARD="${GUARD:-}"
INGRESSGUARD="${INGRESSGUARD:-}"
GUARDTIMEOUT="${GUARDTIMEOUT:-10}"
DESTDIR="${DESTDIR:-}"

if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then
  echo "packet-relay: install.sh must run as root (the devcontainer Feature lifecycle does this)." >&2
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
  echo "packet-relay: needs Python 3.11 or later (add ghcr.io/devcontainers/features/python, or a newer base image)." >&2
  exit 1
fi
if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "packet-relay: needs ssh-keygen (OpenSSH 8.1 or later), and apt-get is not available to install it." >&2
  exit 1
fi

lib="$DESTDIR/usr/local/lib/packet-relay"
bin="$DESTDIR/usr/local/bin"
libexec="$DESTDIR/usr/local/libexec/packet-relay"
mkdir -p "$lib/packetrelay" "$lib/signpacket" "$bin" "$libexec"
rm -f "$lib"/packetrelay/*.py "$lib"/signpacket/*.py
for f in "$feature_dir"/packetrelay/*.py; do install -m 0644 "$f" "$lib/packetrelay/"; done
# Built on sign-packet (AOF ADR 0024), through this Feature's own copy of its library (signpacket/, kept
# equal to src/sign-packet by `task signpacket:sync`): the command finds it first, so this Feature needs
# no other one installed, in any order, and a separate sign-packet Feature never changes it.
for f in "$feature_dir"/signpacket/*.py; do install -m 0644 "$f" "$lib/signpacket/"; done
install -m 0644 "$feature_dir/SPEC.md" "$lib/SPEC.md"
printf 'VERSION=%s\nROOT=%s\nGUARD=%s\nINGRESS_GUARD=%s\nGUARD_TIMEOUT=%s\n' \
  "$version" "$ROOT" "$GUARD" "$INGRESSGUARD" "$GUARDTIMEOUT" > "$lib/options.env"
# The guards are checked now, so a bad one fails the install, not the first send.
if ! python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from packetrelay import cli; cli.guards()' "$lib" 2>/dev/null; then
  echo "packet-relay: the guard, ingressGuard or guardTimeout option cannot be used (each command's first word an absolute path; a timeout 0 to 300)." >&2
  exit 1
fi
install -m 0755 "$feature_dir/bin/packet-relay" "$bin/packet-relay"
install -m 0755 "$feature_dir/packet-relay-setup.sh" "$bin/packet-relay-setup"
install -m 0755 "$feature_dir/dcf-persist.sh" "$libexec/dcf-persist"

includes="$DESTDIR/usr/local/share/go-task/includes.d"
if [ "$INSTALLTASKFILE" = "true" ]; then
  mkdir -p "$includes"
  install -m 0644 "$feature_dir/taskfile.yml" "$includes/packet-relay.yml"
  if [ -z "$DESTDIR" ] && command -v task-features-registry >/dev/null 2>&1; then task-features-registry; fi
else
  rm -f "$includes/packet-relay.yml"
fi

guards=""
[ -z "$GUARD" ] || guards="egress"
[ -z "$INGRESSGUARD" ] || guards="${guards:+$guards, }ingress"
echo "packet-relay $version installed (root: ${ROOT:-none}; guards: ${guards:-none}; taskfile: $INSTALLTASKFILE)"
