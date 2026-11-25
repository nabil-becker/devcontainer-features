#!/usr/bin/env bash
# The workstation's Docker as a second context, `host` (docker-host-context, 2026-11-25).
# The internal docker-in-docker daemon stays the default: tests and agents use it, and
# dind-clean.sh empties it. The workstation's daemon socket is bind-mounted, root-owned,
# at /var/run/docker-host.sock; a socat proxy gives the vscode user a socket of its own,
# and `docker --context host ...` (or DOCKER_CONTEXT=host) reaches the workstation's
# Docker. That is full control of the workstation's Docker: choose it on purpose.
# Used by postStartCommand. Never fails the start.
set -uo pipefail

raw=/var/run/docker-host.sock
proxy=/var/run/docker-host-user.sock

if [ ! -S "$raw" ]; then
  echo "docker-host: no workstation Docker socket at $raw; the context host is not set up"
  exit 0
fi

if [ ! -S "$proxy" ]; then
  # shellcheck disable=SC2024 # the log is the vscode user's, written by this shell on purpose
  sudo -n nohup socat "UNIX-LISTEN:$proxy,fork,mode=660,user=$(id -un),group=docker" "UNIX-CONNECT:$raw" \
    >/tmp/docker-host-proxy.log 2>&1 &
  for _ in $(seq 1 10); do [ -S "$proxy" ] && break; sleep 0.5; done
fi

if ! docker context inspect host >/dev/null 2>&1; then
  docker context create host --description "the workstation's Docker (choose it on purpose)" \
    --docker "host=unix://$proxy" >/dev/null || { echo "docker-host: could not create the context host"; exit 0; }
fi

if docker --context host info >/dev/null 2>&1; then
  echo "docker-host: context host reaches the workstation's Docker; the default stays docker-in-docker"
else
  echo "docker-host: context host is set up but the workstation's Docker does not answer (see /tmp/docker-host-proxy.log)"
fi
exit 0
