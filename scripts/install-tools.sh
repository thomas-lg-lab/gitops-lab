#!/bin/sh
# Installs the pinned validation tools (Linux x86_64) into ${1:-/usr/local/bin}, each checked against the sha256
# its release publishes. Used by CI (.github/workflows/checks.yml) and to run scripts/check.sh in a container.
set -eu
BIN="${1:-/usr/local/bin}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { # url sha256 archive-member
    curl -fsSL -o "$TMP/a.tgz" "$1"
    echo "$2  $TMP/a.tgz" | sha256sum -c - >/dev/null
    tar -xzf "$TMP/a.tgz" -C "$TMP" "$3"
    install -m 0755 "$TMP/$3" "$BIN/$3"
}

fetch https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.8.3/kustomize_v5.8.3_linux_amd64.tar.gz \
    cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61 kustomize
fetch https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz \
    9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883 kubeconform
fetch https://github.com/kyverno/kyverno/releases/download/v1.19.2/kyverno-cli_v1.19.2_linux_x86_64.tar.gz \
    357eaf1df8bc24ddd5a73979fadeaae6a032e8710f11af264229756e4956bf4a kyverno
fetch https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz \
    551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb gitleaks
"$BIN/kustomize" version; "$BIN/kubeconform" -v; "$BIN/kyverno" version | head -1; "$BIN/gitleaks" version
