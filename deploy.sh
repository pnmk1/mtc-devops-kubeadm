#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/scripts/common.sh"
trap diagnostics ERR
need kubectl; need helm; need envsubst; need sha256sum; need python3
use_kubeconfig
check_files
SERVER_VERSION=$(kubectl version -o json | python3 -c 'import sys,json; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')
[[ "$SERVER_VERSION" == "v$KUBERNETES_VERSION" ]] || die "Expected Kubernetes v$KUBERNETES_VERSION; found $SERVER_VERSION"
[[ $(helm version --short) == "v$HELM_VERSION"* ]] || die "Expected Helm v$HELM_VERSION"
[[ $(kubectl get nodes -l mtc-devops.storage=local -o name | wc -l) == 1 ]] || die 'Run bootstrap.sh to prepare the dedicated storage node.'
if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  API_VERSION=$(kubectl get crd gateways.gateway.networking.k8s.io -o go-template='{{index .metadata.annotations "gateway.networking.k8s.io/bundle-version"}}')
  [[ "$API_VERSION" == "v$GATEWAY_API_VERSION" ]] || die "Existing Gateway API version $API_VERSION is incompatible; refusing automatic upgrade."
fi

log 'Installing Gateway API and Envoy Gateway CRDs.'
helm template eg-crds "$ROOT/vendor/gateway-crds-helm-v${ENVOY_GATEWAY_VERSION}.tgz" \
  --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=true > "$STATE_DIR/crds.yaml"
kubectl apply --server-side -f "$STATE_DIR/crds.yaml"
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/envoyproxies.gateway.envoyproxy.io --timeout=120s
log 'Installing pinned Envoy Gateway chart.'
helm upgrade --install eg "$ROOT/vendor/gateway-helm-v${ENVOY_GATEWAY_VERSION}.tgz" \
  --namespace envoy-gateway-system --create-namespace \
  -f "$ROOT/helm/envoy-values.yaml" --wait --timeout 5m

log 'Applying storage, application and observability manifests.'
kubectl apply -f "$ROOT/manifests/namespace.yaml"
kubectl apply -f "$ROOT/manifests/storage.yaml"
kubectl -n "$NS" create configmap web-config --from-file=nginx.conf="$ROOT/config/nginx.conf" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create configmap fluentd-config --from-file=fluent.conf="$ROOT/config/fluent.conf" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" create configmap prometheus-config --from-file=prometheus.yml="$ROOT/config/prometheus.yml" --dry-run=client -o yaml | kubectl apply -f -
CONFIG_HASH=$(sha256sum "$ROOT/config/"* | sha256sum | cut -d' ' -f1)
export CONFIG_HASH
for name in web prometheus gateway; do
  # envsubst intentionally receives literal variable names.
  # shellcheck disable=SC2016
  envsubst '${NGINX_IMAGE} ${EXPORTER_IMAGE} ${PROMETHEUS_IMAGE} ${FLUENTD_IMAGE} ${CONFIG_HASH}' < "$ROOT/manifests/$name.yaml" > "$STATE_DIR/$name.yaml"
  kubectl apply -f "$STATE_DIR/$name.yaml"
done
kubectl -n "$NS" rollout status deployment/web --timeout=300s
kubectl -n "$NS" rollout status deployment/prometheus --timeout=300s
kubectl -n "$NS" wait gateway/demo --for=condition=Accepted --timeout=180s
kubectl -n "$NS" wait gateway/demo --for=condition=Programmed --timeout=180s
log 'Deployment completed. Running acceptance checks.'
bash "$ROOT/verify.sh"

