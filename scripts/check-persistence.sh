#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
use_kubeconfig
need kubectl; need curl; need python3
trap diagnostics ERR
OUT="$ROOT/artifacts/persistence-$(date -u +%Y%m%dT%H%M%SZ)"
export OUT
log 'Running the baseline acceptance check.'
bash "$ROOT/verify.sh"
MARKER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["marker"])' "$OUT/result.json")
PF_PID=''
cleanup() { [[ -z "$PF_PID" ]] || kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

start_forward() {
  kubectl -n "$NS" port-forward --address=127.0.0.1 service/prometheus 19090:9090 > "$OUT/persistence-forward.log" 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 30); do
    kill -0 "$PF_PID" 2>/dev/null || die 'Port-forward process stopped.'
    if curl --fail --silent --max-time 2 http://127.0.0.1:19090/-/ready >/dev/null; then return; fi
    sleep 1
  done
  die 'Prometheus API did not become ready.'
}
start_forward
SAMPLE_TIME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["result"][0]["value"][0])' "$OUT/nginx-requests.json")
python3 "$ROOT/scripts/prom_query.py" 'nginx_http_requests_total{job="nginx"}' --time "$SAMPLE_TIME" > "$OUT/historical-before.json"
kill "$PF_PID"; wait "$PF_PID" 2>/dev/null || true; PF_PID=''
log 'Recreating the application and Prometheus Pods; local PVCs remain.'
kubectl -n "$NS" delete pod -l app=web --wait=true --timeout=120s
kubectl -n "$NS" rollout status deployment/web --timeout=300s
kubectl -n "$NS" exec deployment/web -c fluentd -- sh -ec "grep -R -F '$MARKER' /var/log/demo/collected" > "$OUT/logs-after-restart.txt"
kubectl -n "$NS" delete pod -l app=prometheus --wait=true --timeout=120s
kubectl -n "$NS" rollout status deployment/prometheus --timeout=300s
start_forward
python3 "$ROOT/scripts/prom_query.py" 'nginx_http_requests_total{job="nginx"}' --time "$SAMPLE_TIME" > "$OUT/historical-after.json"
python3 - "$OUT/historical-before.json" "$OUT/historical-after.json" <<'PY'
import json,sys
before=json.load(open(sys.argv[1]))['data']['result']
after=json.load(open(sys.argv[2]))['data']['result']
if before != after:
    raise SystemExit('Historical metric changed/disappeared after Prometheus restart')
print('Historical samples survived Prometheus Pod recreation')
PY
cleanup; PF_PID=''
OUT="$OUT/after" bash "$ROOT/verify.sh"
printf 'PASS\n' > "$OUT/persistence-result.txt"
log "Persistence checks PASS. Evidence: $OUT"

