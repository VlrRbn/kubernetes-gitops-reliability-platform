#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-dev}"
RELEASE_NAME="${RELEASE_NAME:-reliability-demo}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
PORT_FORWARD_LOG="$(mktemp)"
RESPONSE_FILE="$(mktemp)"
HEALTHCHECK_PASSED=false

cleanup() {
  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    wait "$PORT_FORWARD_PID" 2>/dev/null || true
  fi
  rm -f "$PORT_FORWARD_LOG" "$RESPONSE_FILE"
}
trap cleanup EXIT

kubectl rollout status \
  --namespace "$NAMESPACE" \
  "deployment/${RELEASE_NAME}" \
  --timeout=120s

kubectl port-forward \
  --namespace "$NAMESPACE" \
  "service/${RELEASE_NAME}" \
  "${LOCAL_PORT}:80" \
  >"$PORT_FORWARD_LOG" 2>&1 &
PORT_FORWARD_PID=$!

for _ in {1..30}; do
  if curl --silent --fail \
    "http://127.0.0.1:${LOCAL_PORT}/healthz" \
    > "$RESPONSE_FILE" 2>/dev/null; then
    HEALTHCHECK_PASSED=true
    break
  fi
  sleep 1
done

if [[ "$HEALTHCHECK_PASSED" != "true" ]]; then
  echo "Health endpoint did not become reachable within 30 seconds" >&2
  curl --silent --show-error --fail \
    "http://127.0.0.1:${LOCAL_PORT}/healthz" \
    >/dev/null || true
  cat "$PORT_FORWARD_LOG" >&2
  exit 1
fi

grep -Fq '"status":"healthy"' "$RESPONSE_FILE" || {
  echo "Health response was not healthy" >&2
  cat "$PORT_FORWARD_LOG" >&2
  exit 1
}

curl --silent --show-error --fail \
  "http://127.0.0.1:${LOCAL_PORT}/readyz" |
  grep -Fq '"status":"ready"'

curl --silent --show-error --fail \
  "http://127.0.0.1:${LOCAL_PORT}/" |
  grep -Fq '"service":"reliability-demo"'

METRICS="$(curl --silent --show-error --fail \
  "http://127.0.0.1:${LOCAL_PORT}/metrics")"

grep -Fq 'reliability_demo_http_requests_total{code="200"}' <<< "$METRICS"
grep -Fq 'reliability_demo_http_request_duration_seconds_bucket' <<< "$METRICS"
grep -Fq 'reliability_demo_build_info{' <<< "$METRICS"

echo "Smoke test passed for namespace ${NAMESPACE}"
