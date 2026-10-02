#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=versions.env
source "$ROOT/versions.env"
export NGINX_IMAGE EXPORTER_IMAGE PROMETHEUS_IMAGE FLUENTD_IMAGE
export KUBERNETES_VERSION KUBERNETES_DEB_VERSION CONTAINERD_DEB_VERSION
export HELM_VERSION ENVOY_GATEWAY_VERSION GATEWAY_API_VERSION
NS=mtc-demo
export DATA_ROOT=/var/lib/mtc-devops
STATE_DIR="$ROOT/.state"
mkdir -p "$STATE_DIR"

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Required command not found: $1"; }
download() { curl --fail --location --retry 3 --connect-timeout 15 --max-time 300 "$1" -o "$2"; }
check_files() { (cd "$ROOT" && sha256sum --check vendor/SHA256SUMS); }

use_kubeconfig() {
  if [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -r /etc/kubernetes/admin.conf && $EUID -eq 0 ]]; then
      export KUBECONFIG=/etc/kubernetes/admin.conf
    elif [[ -r "${HOME}/.kube/config" ]]; then
      export KUBECONFIG="${HOME}/.kube/config"
    else
      die 'No readable kubeconfig. Run bootstrap.sh first.'
    fi
  fi
}

diagnostics() {
  local rc=$?
  trap - ERR
  printf '\nCommand failed (exit %s), collecting diagnostics...\n' "$rc" >&2
  if command -v kubectl >/dev/null; then
    kubectl --request-timeout=10s get nodes -o wide >&2 || true
    kubectl --request-timeout=10s get pods -A -o wide >&2 || true
    kubectl --request-timeout=10s get events -A --sort-by=.lastTimestamp >&2 || true
    kubectl --request-timeout=10s -n "$NS" logs deployment/web --all-containers --tail=40 >&2 || true
    kubectl --request-timeout=10s -n envoy-gateway-system logs deployment/envoy-gateway --tail=40 >&2 || true
  fi
  exit "$rc"
}

