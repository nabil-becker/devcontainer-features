#!/usr/bin/env bash
# The tools the hub's Kubernetes tasks need, each pinned by version and SHA-256 and fetched into a cache folder when it is not
# already on PATH at the pinned version (the kustomize and kubeconform Features put those two on PATH; kind and kubectl are
# only needed by the throwaway-cluster test). Usage:  source test/facilitator/k8s/tools.sh; fac_tools kustomize kubeconform
# After it, the tools are on PATH. The pins below are the releases' own checksums (kind's .sha256sum files, dl.k8s.io's
# .sha256 files, the kustomize checksums.txt and the kubeconform CHECKSUMS), read on 2026-11-24. FACILITATOR_K8S_TOOLS names
# another cache folder.
# shellcheck disable=SC2034  # the pins are read by the scripts that source this file
set -euo pipefail

KIND_VERSION=v0.33.0
KUBECTL_VERSION=v1.37.2
KUSTOMIZE_VERSION=v5.8.3
KUBECONFORM_VERSION=v0.8.0
# the node image kind runs, by digest (kind v0.33.0's own release notes: the Kubernetes 1.37.0 image)
KIND_NODE_IMAGE='kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5'
KUBERNETES_SCHEMA_VERSION=1.34.0   # kubeconform's schema set (the newest the schema repository carries that the base is written for)

fac_arch() {
  case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo "unsupported architecture $(uname -m)" >&2; return 1 ;; esac
}

fac_pin() { # <tool> <arch> -> url sha256 (one line)
  case "$1-$2" in
    kind-amd64) echo "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-amd64 aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d" ;;
    kind-arm64) echo "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-arm64 20022bee6cfcd5086cb7234d218e3454e6090022f2a8f55d1fa7fcf42c3867a2" ;;
    kubectl-amd64) echo "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4" ;;
    kubectl-arm64) echo "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/arm64/kubectl fcc16f63186659d9722014b7e02d5fdd2d4e669cb8c0ab66365d7d3b8ba03509" ;;
    kustomize-amd64) echo "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61" ;;
    kustomize-arm64) echo "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION}_linux_arm64.tar.gz 9867b76482cfc6d25b546abc1d2b5a32bd137505aba640649b4b378f64f6d68f" ;;
    kubeconform-amd64) echo "https://github.com/yannh/kubeconform/releases/download/$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz 9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883" ;;
    kubeconform-arm64) echo "https://github.com/yannh/kubeconform/releases/download/$KUBECONFORM_VERSION/kubeconform-linux-arm64.tar.gz 1f53fc8e81258197a35e8603054162a5af1de8c5af13746c71ab680d9534ed87" ;;
    *) echo "no pin for $1 on $2" >&2; return 1 ;;
  esac
}

fac_version_of() { # <tool> -> the version it reports, empty when absent
  case "$1" in
    kind) kind version 2>/dev/null | sed -n 's/^kind \(v[0-9.]*\).*/\1/p' ;;
    kubectl) kubectl version --client -o json 2>/dev/null | sed -n 's/.*"gitVersion": "\(v[^"]*\)".*/\1/p' | head -1 ;;
    kustomize) kustomize version 2>/dev/null | sed -n 's/^v\?\([0-9][0-9.]*\).*/v\1/p' | head -1 ;;
    kubeconform) kubeconform -v 2>/dev/null | sed -n 's/^\(v[0-9.]*\).*/\1/p' | head -1 ;;
  esac
}

fac_tools() { # <tool>...: each on PATH at its pinned version, fetched (checksum verified) when it is not
  local cache="${FACILITATOR_K8S_TOOLS:-${XDG_CACHE_HOME:-$HOME/.cache}/facilitator-k8s-tools}" arch t want have url sum tmp
  arch="$(fac_arch)"
  mkdir -p "$cache/bin"
  for t in "$@"; do
    case "$t" in kind) want=$KIND_VERSION ;; kubectl) want=$KUBECTL_VERSION ;; kustomize) want=$KUSTOMIZE_VERSION ;; kubeconform) want=$KUBECONFORM_VERSION ;; *) echo "unknown tool $t" >&2; return 1 ;; esac
    have="$(fac_version_of "$t" || true)"
    if [ "$have" = "$want" ]; then continue; fi
    if [ -x "$cache/bin/$t" ] && [ "$(PATH="$cache/bin:$PATH" fac_version_of "$t" || true)" = "$want" ]; then export PATH="$cache/bin:$PATH"; continue; fi
    read -r url sum < <(fac_pin "$t" "$arch")
    tmp="$(mktemp -d "$cache/dl-XXXXXX")"
    echo "fetching $t $want (sha256 checked)" >&2
    curl -fsSL --retry 3 -o "$tmp/asset" "$url"
    echo "$sum  $tmp/asset" | sha256sum -c - >/dev/null || { echo "$t: the download does not match its pinned SHA-256" >&2; rm -rf "$tmp"; return 1; }
    case "$url" in
      *.tar.gz) tar -xzf "$tmp/asset" -C "$tmp" "$t" && install -m 0755 "$tmp/$t" "$cache/bin/$t" ;;
      *) install -m 0755 "$tmp/asset" "$cache/bin/$t" ;;
    esac
    rm -rf "$tmp"
    export PATH="$cache/bin:$PATH"
  done
}
