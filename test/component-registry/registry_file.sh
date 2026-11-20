#!/bin/bash
# Scenario 'registry_file' (see scenarios.json): registryFile=config/layers.yml. dcf-registry reads
# the layer list there, and COMPONENT_REGISTRY_FILE still overrides it.
set -e
# shellcheck disable=SC1091  # provided by the devcontainer CLI at test time
source dev-container-features-test-lib

check "the option is baked" grep -qx 'REGISTRYFILE=config/layers.yml' /usr/local/share/component-registry-feature/options.env
check "dcf-registry uses the option" bash -c "cd \"\$(mktemp -d)\" && mkdir .devcontainer && dcf-registry version | grep -F 'config/layers.yml (from the Feature option registryFile)'"
check "COMPONENT_REGISTRY_FILE overrides it" bash -c "cd \"\$(mktemp -d)\" && mkdir .devcontainer && COMPONENT_REGISTRY_FILE=other.yml dcf-registry version | grep -F 'other.yml (from COMPONENT_REGISTRY_FILE in the environment)'"

reportResults
