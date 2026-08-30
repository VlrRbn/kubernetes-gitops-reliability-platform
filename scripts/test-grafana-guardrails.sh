#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
VALUES="${ROOT_DIR}/platform/monitoring/values.yaml"
DASHBOARD="${ROOT_DIR}/platform/monitoring/dashboards/reliability-demo-slo.json"
BOOTSTRAP="${ROOT_DIR}/scripts/bootstrap-monitoring.sh"
MAKEFILE="${ROOT_DIR}/Makefile"

jq empty "$DASHBOARD"

required_values_contracts=(
  'repository: grafana/grafana'
  'tag: 13.2.0'
  'sha: 3fd54ae1214669f8355f065ec9f6445d5279a3d77095ab048ca045685272429b'
  'defaultDashboardsEnabled: false'
  'automountServiceAccountToken: false'
  'url: http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090'
  'uid: prometheus'
  'editable: false'
  'default: reliability-demo-slo-dashboard'
  'check_for_updates: false'
  'reporting_enabled: false'
  'allow_sign_up: false'
  'memory: 512Mi'
)

for contract in "${required_values_contracts[@]}"; do
  grep -Fq -- "$contract" "$VALUES" || {
    echo "Grafana values are missing guardrail: $contract" >&2
    exit 1
  }
done

required_dashboard_contracts=(
  '"uid": "reliability-demo-slos"'
  '"name": "environment"'
  '"noValue": "No traffic"'
  '"axisSoftMax": 0.1'
  'reliability_demo:http_availability:ratio5m'
  'reliability_demo:http_requests:rate5m'
  'reliability_demo:http_errors:rate5m'
  'reliability_demo:http_request_duration:p95_5m'
  'up{service=\"reliability-demo\"'
  'ALERTS{alertstate=\"firing\"'
)

for contract in "${required_dashboard_contracts[@]}"; do
  grep -Fq -- "$contract" "$DASHBOARD" || {
    echo "Grafana dashboard is missing contract: $contract" >&2
    exit 1
  }
done

grep -Eq 'https?://' "$DASHBOARD" && {
  echo "Grafana dashboard must not load external resources" >&2
  exit 1
}

# These entries intentionally match shell and Make expressions literally.
# shellcheck disable=SC2016
required_runtime_contracts=(
  'kubectl create configmap reliability-demo-slo-dashboard'
  '--from-file=reliability-demo-slo.json="$DASHBOARD_FILE"'
  'deployment/${GRAFANA_DEPLOYMENT}'
  '/api/health'
  'Grafana restarted during bootstrap'
  'grafana-password:'
  'grafana-port-forward:'
)

for contract in "${required_runtime_contracts[@]}"; do
  if ! grep -Fq -- "$contract" "$BOOTSTRAP" "$MAKEFILE"; then
    echo "Grafana runtime checks are missing guardrail: $contract" >&2
    exit 1
  fi
done

echo "Grafana provisioning and dashboard guardrails passed"
