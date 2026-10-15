#!/usr/bin/env bash
# az-setup: the az Feature's postCreateCommand, run as the remote user from
# the workspace folder after every create/rebuild; also behind
# `task az:setup`. Idempotent, never fatal: a problem is reported, not
# allowed to abort the rest of post-create.
#
# 1. dcf-persist makes AZURE_CONFIG_DIR (the Feature's named volume, or a
#    bind mount a repo put on the same target) exist and belong to the
#    remote user, so `az login` can store its tokens there and keep them
#    across rebuilds.
# 2. With bicepFromPath (default true) and a bicep binary on PATH (the
#    azure-cli Feature's installBicep), `az config set
#    bicep.use_binary_from_path=true` so `az bicep` / `az deployment` use it
#    instead of asking to download their own copy into AZURE_CONFIG_DIR.
# 3. Reports the az version, whether a login is present (exit code of
#    `az account show` only; its output names the subscription and user)
#    and the next step when it is not.
set -u

# Defaults baked by install.sh from the Feature options. AZ_SETUP_* in the
# environment (containerEnv) override them without a rebuild.
# shellcheck disable=SC1091  # written by install.sh at image build
[ -f /usr/local/share/az-feature/options.env ] && source /usr/local/share/az-feature/options.env
bicep_from_path="${AZ_SETUP_BICEP_FROM_PATH-${BICEPFROMPATH:-true}}"
dir="${AZURE_CONFIG_DIR:-$HOME/.azure}"

dcf-persist --label az "$dir"

if ! command -v az >/dev/null 2>&1; then
  echo "az: not found on PATH; add ghcr.io/devcontainers/features/azure-cli:1 before this Feature in devcontainer.json" >&2
  exit 0
fi

if [ "$bicep_from_path" != "true" ]; then
  echo "az: bicep.use_binary_from_path not configured (bicepFromPath=false)"
elif ! command -v bicep >/dev/null 2>&1; then
  echo "az: no bicep on PATH, bicep.use_binary_from_path left alone (az bicep installs its own copy on first use)"
else
  if [ "$(az config get bicep.use_binary_from_path --query value -o tsv --only-show-errors 2>/dev/null || true)" = "true" ]; then
    echo "az: bicep.use_binary_from_path=true ($(command -v bicep), kept)"
  elif az config set bicep.use_binary_from_path=true --only-show-errors 2>/dev/null; then
    echo "az: bicep.use_binary_from_path=true ($(command -v bicep), set)"
  else
    echo "az: could not set bicep.use_binary_from_path (is $dir writable?)" >&2
  fi
fi

echo "az: azure-cli $(az version -o tsv --only-show-errors 2>/dev/null | cut -f1 || echo '?') at $(command -v az)"
if az account show >/dev/null 2>&1; then
  echo "az: logged in (state in $dir)"
else
  echo "az: no login yet; run 'az login --use-device-code' (or task az:login) once, it persists in $dir"
fi
exit 0
