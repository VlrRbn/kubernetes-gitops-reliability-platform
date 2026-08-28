#!/usr/bin/env bash
set -Eeuo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-gitops-reliability}"
EXPECTED_CONTEXT="kind-${CLUSTER_NAME}"
APP_METRICS_API="/api/v1/namespaces/dev/services/reliability-demo:http/proxy/metrics"
ALERTMANAGER_STATEFULSET="alertmanager-monitoring-kube-prometheus-alertmanager"

current_context="$(kubectl config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] || {
  echo "Refusing to test Alertmanager in context '$current_context'; expected '$EXPECTED_CONTEXT'" >&2
  exit 1
}

request_count() {
  kubectl get --raw "$APP_METRICS_API" |
    awk '/^reliability_demo_http_requests_total/ {total += $2} END {print total + 0}'
}

before="$(request_count)"
ends_at="$(date --utc --date='+2 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
alert_name="ReliabilityDemoDeliveryTest_$(date --utc '+%s%N')"

kubectl exec \
  --namespace monitoring \
  "statefulset/${ALERTMANAGER_STATEFULSET}" \
  --container alertmanager \
  -- /bin/amtool \
  --alertmanager.url=http://localhost:9093 \
  alert add \
  --end="$ends_at" \
  --annotation='summary="Alertmanager delivery contract"' \
  "$alert_name" \
  namespace=dev \
  severity=info

for _ in $(seq 1 30); do
  after="$(request_count)"
  if awk -v before="$before" -v after="$after" 'BEGIN {exit !(after > before)}'; then
    echo "Alertmanager delivered the synthetic alert to reliability-demo in dev"
    exit 0
  fi
  sleep 1
done

echo "Alertmanager did not deliver the synthetic alert within 30 seconds" >&2
exit 1
