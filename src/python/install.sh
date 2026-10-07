#!/usr/bin/env bash
set -euo pipefail

INSTALLPIP="${INSTALLPIP:-true}"
if [[ "$(id -u)" != "0" ]]; then
    echo "This feature must be installed as root." >&2
    exit 1
fi
case "$INSTALLPIP" in
    true|false) ;;
    *) echo "installPip must be true or false." >&2; exit 1 ;;
esac

source /etc/os-release
case "$ID" in
    debian|ubuntu) ;;
    *) echo "Only Debian and Ubuntu are supported." >&2; exit 1 ;;
esac

packages=(python3 python3-venv)
if [[ "$INSTALLPIP" == "true" ]]; then
    packages+=(python3-pip)
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends "${packages[@]}"
rm -rf /var/lib/apt/lists/*
python3 --version
