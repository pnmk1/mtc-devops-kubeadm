#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/scripts/common.sh"
need kubectl; need curl; need python3
use_kubeconfig
OUT=${OUT:-"$ROOT/artifacts/$(date -u +%Y%m%dT%H%M%SZ)"}
mkdir -p "$OUT"
PF_PID=''
cleanup() { [[ -z "$PF_PID" ]] || kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT
trap diagnostics ERR
log 'Waiting for the Kubernetes API after boot.'
API_READY=false
for _ in $(seq 1 60); do
  if kubectl --request-timeout=3s get --raw=/readyz > /dev/null 2>&1; then API_READY=true; break; fi
  sleep 2
done
[[ "$API_READY" == true ]] || die 'Kubernetes API did not become ready; check clock synchronization, containerd and kubelet.'
NODE_IP=${NODE_IP:-$(kubectl get nodes -l mtc-devops.storage=local -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}
BASE_URL="http://${NODE_IP}:30080"
MARKER="mtc-$(date +%s)-${RANDOM}"

log 'Checking node, workloads and Gateway conditions.'
kubectl wait nodes -l mtc-devops.storage=local --for=condition=Ready --timeout=120s
kubectl -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=180s
for proxy in $(kubectl -n envoy-gateway-system get deployment -l gateway.envoyproxy.io/owning-gateway-name=demo,gateway.envoyproxy.io/owning-gateway-namespace=mtc-demo -o name); do
  kubectl -n envoy-gateway-system rollout status "$proxy" --timeout=180s
done
kubectl -n "$NS" rollout status deployment/web --timeout=180s
kubectl -n "$NS" rollout status deployment/prometheus --timeout=180s
kubectl -n "$NS" wait gateway/demo --for=condition=Accepted --timeout=120s
kubectl -n "$NS" wait gateway/demo --for=condition=Programmed --timeout=120s
kubectl -n "$NS" get httproute web -o json > "$OUT/route.json"
python3 - "$OUT/route.json" <<'PY'
import json,sys
route=json.load(open(sys.argv[1]))
generation=route['metadata']['generation']
parents=[p for p in route.get('status',{}).get('parents',[]) if p['parentRef']['name']=='demo' and p.get('controllerName')=='gateway.envoyproxy.io/gatewayclass-controller']
if not parents:
    raise SystemExit('No Envoy Gateway parent status for HTTPRoute')
for parent in parents:
    conditions={c['type']:c for c in parent.get('conditions',[])}
    for expected in ['Accepted','ResolvedRefs']:
        c=conditions.get(expected,{})
        if c.get('status')!='True' or c.get('observedGeneration')!=generation:
            raise SystemExit(f'HTTPRoute {expected} is not current/True: {c}')
PY

log 'Checking HTTP through Envoy NodePort.'
curl --fail --silent --show-error --retry 12 --retry-all-errors --retry-delay 2 --retry-max-time 60 --max-time 5 -H 'Host: demo.local' "$BASE_URL/?check=$MARKER" > "$OUT/http-body.txt"
[[ $(cat "$OUT/http-body.txt") == 'Hello World!' ]] || die 'Unexpected HTTP response body.'
WRONG_STATUS=$(curl --silent --show-error --max-time 15 -o "$OUT/wrong-host.txt" -w '%{http_code}' -H 'Host: wrong.invalid' "$BASE_URL/")
[[ "$WRONG_STATUS" == 404 ]] || die "Expected wrong-host 404; received $WRONG_STATUS"
ERROR_STATUS=$(curl --silent --show-error --max-time 15 -o "$OUT/error-body.txt" -w '%{http_code}' -H 'Host: demo.local' "$BASE_URL/missing-$MARKER")
[[ "$ERROR_STATUS" == 404 ]] || die "Expected missing-file 404; received $ERROR_STATUS"

log 'Waiting for Fluentd to flush both access and error records.'
LOGS_OK=false
for _ in $(seq 1 30); do
  kubectl -n "$NS" logs deployment/web -c fluentd --since=5m > "$OUT/fluentd-stdout.txt"
  if grep -F "$MARKER" "$OUT/fluentd-stdout.txt" | grep -F 'demo.access' >/dev/null \
    && grep -F "missing-$MARKER" "$OUT/fluentd-stdout.txt" | grep -F 'demo.error' >/dev/null \
    && kubectl -n "$NS" exec deployment/web -c fluentd -- sh -ec "grep -R -F '$MARKER' /var/log/demo/collected | grep -F '\"source\":\"demo.access\"' >/dev/null && grep -R -F 'missing-$MARKER' /var/log/demo/collected | grep -F '\"source\":\"demo.error\"' >/dev/null"; then
    LOGS_OK=true; break
  fi
  sleep 2
done
[[ "$LOGS_OK" == true ]] || die 'Fluentd access/error records did not arrive in stdout and persistent collected files.'
kubectl -n "$NS" exec deployment/web -c fluentd -- sh -ec "grep -R -F '$MARKER' /var/log/demo/collected" > "$OUT/collected-records.txt"

log 'Checking real Prometheus targets and metric samples.'
kubectl -n "$NS" port-forward --address=127.0.0.1 service/prometheus 19090:9090 > "$OUT/port-forward.log" 2>&1 &
PF_PID=$!
READY=false
for _ in $(seq 1 30); do
  kill -0 "$PF_PID" 2>/dev/null || die 'Prometheus port-forward failed (port 19090 may already be occupied).'
  if curl --fail --silent --max-time 2 http://127.0.0.1:19090/-/ready >/dev/null; then READY=true; break; fi
  sleep 1
done
[[ "$READY" == true ]] || die 'Prometheus API is not ready.'
METRICS_OK=false
for _ in $(seq 1 30); do
  if python3 "$ROOT/scripts/prom_query.py" 'up{job="nginx"}' --require-one > "$OUT/prometheus-up.json" \
    && python3 "$ROOT/scripts/prom_query.py" 'nginx_up{job="nginx"}' --require-one > "$OUT/nginx-up.json" \
    && python3 "$ROOT/scripts/prom_query.py" 'nginx_http_requests_total{job="nginx"}' --positive > "$OUT/nginx-requests.json"; then
    METRICS_OK=true; break
  fi
  sleep 2
done
[[ "$METRICS_OK" == true ]] || die 'Nginx target/metrics were not collected.'
curl --fail --silent --show-error --max-time 10 http://127.0.0.1:19090/api/v1/targets > "$OUT/prometheus-targets.json"
kubectl get nodes -o wide > "$OUT/nodes.txt"
kubectl -n "$NS" get pods,pvc,gateway,httproute -o wide > "$OUT/resources.txt"
python3 - "$OUT/result.json" "$MARKER" "$NODE_IP" <<'PY'
import datetime,json,sys
result={'status':'PASS','time_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'marker':sys.argv[2],'node_ip':sys.argv[3],'checks':['gateway','http','hostname','access_log','error_log','persistent_log_output','prometheus_target','nginx_metrics']}
with open(sys.argv[1],'w') as f: json.dump(result,f,indent=2)
PY
log "PASS. Evidence directory: $OUT"

