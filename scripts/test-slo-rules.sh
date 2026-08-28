#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
RULES="${ROOT_DIR}/platform/monitoring/slo-rules.yaml"

required_contracts=(
  'kind: PrometheusRule'
  'namespace: monitoring'
  'observability.reliability-platform.io/rules: "true"'
  'record: reliability_demo:http_requests:rate5m'
  'record: reliability_demo:http_errors:rate5m'
  'record: reliability_demo:http_availability:ratio5m'
  'record: reliability_demo:http_request_duration:p95_5m'
  'code=~"5.."'
  'histogram_quantile(0.95'
  'alert: ReliabilityDemoAvailabilitySLOBreach'
  'reliability_demo:http_availability:ratio5m < 0.99'
  'alert: ReliabilityDemoLatencySLOBreach'
  'reliability_demo:http_request_duration:p95_5m > 0.5'
  'reliability_demo:http_requests:rate5m > 0.01'
  'for: 10m'
)

for contract in "${required_contracts[@]}"; do
  grep -Fq -- "$contract" "$RULES" || {
    echo "SLO rules are missing required contract: $contract" >&2
    exit 1
  }
done

[[ "$(grep -c '^        - alert:' "$RULES")" -eq 2 ]] || {
  echo "Expected exactly two reviewed SLO alerts" >&2
  exit 1
}

grep -Eq 'for:[[:space:]]+(0m|[0-9]+s)$' "$RULES" && {
  echo "SLO alerts must not fire without a sustained breach" >&2
  exit 1
}

echo "SLO recording and alerting rule guardrails passed"
